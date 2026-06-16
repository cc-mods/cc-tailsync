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

HERE = os.path.dirname(os.path.abspath(__file__))
MANAGER = os.path.join(HERE, "save-manager.py")
SERVER = os.path.join(HERE, "..", "servers", "save-server.py")
PY = sys.executable

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
