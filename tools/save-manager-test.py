#!/usr/bin/env python3
"""Integration tests for save-manager.py — runnable on macOS, Windows, or Linux (stdlib only).

Exercises the manager end-to-end as a real CLI against a real save-server.py subprocess:
local<->file force push, server push/pull, newest-wins sync (both directions + tiebreak), the
sha short-circuit no-op, and CrossCode-save validation. No device / network needed.

    python3 tools/save-manager-test.py        # prints PASS/FAIL per case; exits non-zero on any fail
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
MANAGER = os.path.join(HERE, "save-manager.py")
SERVER = os.path.join(HERE, "..", "servers", "save-server.py")
PY = sys.executable

# A fake `scp`: operates on local files so the SSH endpoint's read/write/mtime/exists logic can be
# tested with no real server. Maps a remote spec `user@host:/path` to the local `/path`; honors -p
# (preserve mtime) so newest-wins is exercised; emits a missing-file error like real scp.
FAKE_SCP = r'''#!/usr/bin/env python3
import os, sys, shutil
args = sys.argv[1:]
preserve = False
pos = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-q":
        i += 1; continue
    if a == "-p":
        preserve = True; i += 1; continue
    if a in ("-P", "-i", "-o"):
        i += 2; continue
    pos.append(a); i += 1
src, dst = pos[0], pos[1]
def rp(p):
    return p.split(":", 1)[1] if ":" in p else p
s, d = rp(src), rp(dst)
if not os.path.exists(s):
    sys.stderr.write("scp: %s: No such file or directory\n" % s)
    sys.exit(1)
os.makedirs(os.path.dirname(d) or ".", exist_ok=True)
shutil.copy2(s, d) if preserve else shutil.copyfile(s, d)
'''

_fails = []
_passes = 0


def check(name, cond, detail=""):
    global _passes
    if cond:
        _passes += 1
        print(f"  PASS  {name}")
    else:
        _fails.append(name)
        print(f"  FAIL  {name}  {detail}")


def save_blob(tag):
    """A minimally-valid CrossCode save (top-level 'slots'), unique per tag."""
    return json.dumps({"slots": [f"slot-{tag}"], "autoSlot": None,
                       "lastSlot": 0, "globals": tag}).encode("utf-8")


def blob_sha(tag):
    return hashlib.sha256(save_blob(tag)).hexdigest()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def manager(*args, env=None):
    e = dict(os.environ)
    e["CC_ENDPOINTS"] = os.devnull  # ignore any real config on the dev box (override per-test)
    if env:
        e.update(env)
    args = [a for a in args if not isinstance(a, dict)]
    return subprocess.run([PY, MANAGER, *args], capture_output=True, text=True, env=e, timeout=60)


def main():
    work = tempfile.mkdtemp(prefix="sm-test-")
    server_save = os.path.join(work, "server-cc.save")
    local_save = os.path.join(work, "local-cc.save")
    port = free_port()
    url = f"http://127.0.0.1:{port}"

    # Start a real save-server mirroring server_save.
    server = subprocess.Popen([PY, SERVER, "--host", "127.0.0.1", "--port", str(port),
                               "--save", server_save],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # wait for it to bind
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

        # 1. status: empty server + empty local -> no crash, reports no saves
        r = manager("status", "local", url)
        check("status on empty endpoints", r.returncode == 0 and "no save" in r.stdout, r.stdout + r.stderr)

        # 2. force push local -> server (seed local first)
        open(local_save, "wb").write(save_blob("A"))
        r = manager("push", local_save, url, "-y")
        check("push local->server ok", r.returncode == 0 and "MATCH" in r.stdout, r.stdout + r.stderr)
        check("server received save", os.path.isfile(server_save) and open(server_save, "rb").read() == save_blob("A"))

        # 3. sha short-circuit: pushing the same bytes again is a no-op
        r = manager("push", local_save, url, "-y")
        check("push no-op on identical sha", "Nothing to do" in r.stdout, r.stdout)

        # 4. newest-wins sync: make the SERVER newer -> local should receive server's save
        open(server_save, "wb").write(save_blob("B"))
        os.utime(server_save, (time.time() + 50, time.time() + 50))
        os.utime(local_save, (time.time() - 50, time.time() - 50))
        r = manager("sync", local_save, url, "-y")
        check("sync pulls newer server", r.returncode == 0 and open(local_save, "rb").read() == save_blob("B"),
              r.stdout + r.stderr)

        # 5. newest-wins the other way: make LOCAL newer -> server should receive local's save
        open(local_save, "wb").write(save_blob("C"))
        os.utime(local_save, (time.time() + 100, time.time() + 100))
        r = manager("sync", local_save, url, "-y")
        check("sync pushes newer local", open(server_save, "rb").read() == save_blob("C"), r.stdout + r.stderr)

        # 6. sync no-op when already identical
        r = manager("sync", local_save, url, "-y")
        check("sync no-op when in sync", "already in sync" in r.stdout, r.stdout)

        # 7. validation: refuse to push garbage
        junk = os.path.join(work, "junk.save")
        open(junk, "wb").write(b"not a save")
        r = manager("push", junk, url, "-y")
        check("validation rejects non-save", r.returncode != 0 and "not a valid" in (r.stdout + r.stderr),
              r.stdout + r.stderr)

        # 8. --no-validate bypass writes anyway
        r = manager("push", junk, url, "-y", "--no-validate")
        check("--no-validate bypass writes", r.returncode == 0 and open(server_save, "rb").read() == b"not a save",
              r.stdout + r.stderr)

        # 9. safety backup created before an overwrite
        bdir = os.path.expanduser("~/.cc-tailsync/manager-backups")
        before = set(os.listdir(bdir)) if os.path.isdir(bdir) else set()
        open(local_save, "wb").write(save_blob("D"))
        os.utime(local_save, (time.time() + 200, time.time() + 200))
        manager("push", local_save, url, "-y")
        after = set(os.listdir(bdir)) if os.path.isdir(bdir) else set()
        check("safety backup written before overwrite", len(after - before) >= 1)

        # 10. backup + list + restore round-trip (local snapshots)
        snapdir = os.path.join(work, "snaps")
        r = manager("--dir", snapdir, "backup", local_save, "--label", "test")
        check("backup creates snapshot", r.returncode == 0 and os.path.isfile(os.path.join(snapdir, "latest", "cc.save")),
              r.stdout + r.stderr)
        r = manager("--dir", snapdir, "list")
        check("list shows snapshot", r.returncode == 0 and "test" in r.stdout, r.stdout)
        dst = os.path.join(work, "restored.save")
        r = manager("--dir", snapdir, "restore", "latest", dst, "-y")
        check("restore latest -> file", r.returncode == 0 and open(dst, "rb").read() == save_blob("D"),
              r.stdout + r.stderr)

        # 11. sync validates: a corrupt-but-non-empty newer save must NOT propagate
        good = os.path.join(work, "good.save")
        bad = os.path.join(work, "bad.save")
        open(good, "wb").write(save_blob("E"))
        open(bad, "wb").write(b"{not json")
        os.utime(bad, (time.time() + 300, time.time() + 300))   # bad is "newer"
        os.utime(good, (time.time() - 300, time.time() - 300))
        r = manager("sync", good, bad, "-y")
        check("sync rejects corrupt newer save", r.returncode != 0 and "not a valid" in (r.stdout + r.stderr),
              r.stdout + r.stderr)
        check("sync did not overwrite good with corrupt", open(good, "rb").read() == save_blob("E"))

        # 12. config alias: name -> name -> URL resolves
        cfg = os.path.join(work, "cc-endpoints.json")
        json.dump({"endpoints": {"hub": url, "main": "hub"}}, open(cfg, "w"))
        r = manager("status", "main", env={"CC_ENDPOINTS": cfg})
        check("config alias name->name->url resolves",
              r.returncode == 0 and ("724" in r.stdout or "not a save" in r.stdout or "b  " in r.stdout
                                     or "server" in r.stdout),
              r.stdout + r.stderr)

        # 13. git-backed backups: --push commits into a git repo with a bare remote (no network)
        gitwork = os.path.join(work, "gitbackups")
        bare = os.path.join(work, "backups.git")
        subprocess.run(["git", "init", "--bare", "-q", bare], check=True)
        subprocess.run(["git", "init", "-q", gitwork], check=True)
        for kv in (("user.email", "t@e.st"), ("user.name", "Test"), ("commit.gpgsign", "false")):
            subprocess.run(["git", "-C", gitwork, "config", *kv], check=True)
        subprocess.run(["git", "-C", gitwork, "remote", "add", "origin", bare], check=True)
        # seed an initial commit + upstream so pull/push have a branch
        open(os.path.join(gitwork, "README"), "w").write("backups")
        subprocess.run(["git", "-C", gitwork, "add", "-A"], check=True)
        subprocess.run(["git", "-C", gitwork, "commit", "-qm", "init"], check=True)
        br = subprocess.run(["git", "-C", gitwork, "rev-parse", "--abbrev-ref", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
        subprocess.run(["git", "-C", gitwork, "push", "-q", "-u", "origin", br], check=True)
        open(local_save, "wb").write(save_blob("F"))
        r = manager("--dir", gitwork, "backup", local_save, "--label", "mac", "--push")
        check("git backup --push commits + pushes", r.returncode == 0 and "pushed" in r.stdout, r.stdout + r.stderr)
        committed = subprocess.run(["git", "-C", gitwork, "log", "--oneline"],
                                   capture_output=True, text=True).stdout
        check("snapshot committed to git", "backup(mac)" in committed, committed)
        check("snapshot file tracked by git",
              subprocess.run(["git", "-C", gitwork, "ls-files"], capture_output=True, text=True
                             ).stdout.count("cc.save") >= 2)  # snapshots/.../cc.save + latest/cc.save

        # 14. restore --pull from the git-backed repo, then restore latest to a file
        dst2 = os.path.join(work, "from-git.save")
        r = manager("--dir", gitwork, "restore", "latest", dst2, "-y", "--pull")
        check("restore latest from git-backed repo", r.returncode == 0 and open(dst2, "rb").read() == save_blob("F"),
              r.stdout + r.stderr)

        # 15-19. SSH endpoint via a fake-scp shim (no real server needed)
        fake_scp = os.path.join(work, "fake-scp.py")
        open(fake_scp, "w").write(FAKE_SCP)
        os.chmod(fake_scp, 0o755)
        remote_root = os.path.join(work, "remoteroot")
        os.makedirs(remote_root, exist_ok=True)
        remote_save = os.path.join(remote_root, "cc.save")
        sshcfg = os.path.join(work, "ssh-endpoints.json")
        json.dump({"endpoints": {"win": {"type": "ssh", "host": "dummy", "user": "me", "path": remote_save}}},
                  open(sshcfg, "w"))
        sshenv = {"CC_ENDPOINTS": sshcfg, "CC_SCP": fake_scp}

        r = manager("status", "win", env=sshenv)
        check("ssh status: no save when remote missing", "no save" in r.stdout, r.stdout + r.stderr)

        open(local_save, "wb").write(save_blob("S"))
        r = manager("push", local_save, "win", "-y", env=sshenv)
        check("push local->ssh ok", r.returncode == 0 and "MATCH" in r.stdout, r.stdout + r.stderr)
        check("ssh remote received save",
              os.path.isfile(remote_save) and open(remote_save, "rb").read() == save_blob("S"))

        r = manager("status", "win", env=sshenv)
        check("ssh status shows correct sha after push", blob_sha("S")[:12] in r.stdout, r.stdout)

        out_ssh = os.path.join(work, "from-ssh.save")
        r = manager("push", "win", out_ssh, "-y", env=sshenv)
        check("push ssh->local ok", r.returncode == 0 and open(out_ssh, "rb").read() == save_blob("S"),
              r.stdout + r.stderr)

        # newest-wins: make the ssh remote newer -> local receives it
        open(remote_save, "wb").write(save_blob("T"))
        os.utime(remote_save, (time.time() + 500, time.time() + 500))
        open(local_save, "wb").write(save_blob("S"))
        os.utime(local_save, (time.time() - 500, time.time() - 500))
        r = manager("sync", local_save, "win", "-y", env=sshenv)
        check("sync pulls newer ssh remote", open(local_save, "rb").read() == save_blob("T"), r.stdout + r.stderr)

        # ssh:// URL form resolves (remote_save is an absolute unix path)
        r = manager("status", f"ssh://me@dummy{remote_save}",
                    env={"CC_ENDPOINTS": os.devnull, "CC_SCP": fake_scp})
        check("ssh:// url form resolves", r.returncode == 0 and blob_sha("T")[:12] in r.stdout,
              r.stdout + r.stderr)

    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    print(f"\n{_passes} passed, {len(_fails)} failed")
    if _fails:
        print("FAILED: " + ", ".join(_fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
