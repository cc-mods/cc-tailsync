#!/usr/bin/env python3
"""Tests for the shared cc_backup helper and the save-server's auto-backup of received saves.

Stdlib-only; no network/device. Spins up a real save-server.py subprocess pointed at a git-backed
backups repo (with a bare remote), PUTs saves to it, and asserts they get snapshotted + committed +
pushed — the path that carries the phone's saves to GitHub.

    python3 tools/save-manager-backup-test.py
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "servers", "save-server.py")
CCB_DIR = os.path.join(HERE, "..", "servers")
PY = sys.executable

sys.path.insert(0, CCB_DIR)
import cc_backup  # noqa: E402

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
    return json.dumps({"slots": [f"slot-{tag}"], "lastSlot": 0, "globals": tag}).encode("utf-8")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def git(d, *a):
    return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True)


def make_git_backups(work):
    """A git checkout with a bare remote (so push works offline)."""
    repo = os.path.join(work, "backups")
    bare = os.path.join(work, "backups.git")
    subprocess.run(["git", "init", "--bare", "-q", bare], check=True)
    subprocess.run(["git", "init", "-q", repo], check=True)
    for k, v in (("user.email", "t@e.st"), ("user.name", "Test"), ("commit.gpgsign", "false")):
        git(repo, "config", k, v)
    git(repo, "remote", "add", "origin", bare)
    open(os.path.join(repo, "README"), "w").write("backups")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "init")
    br = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    git(repo, "push", "-q", "-u", "origin", br)
    return repo


def put(url, data):
    req = urllib.request.Request(url + "/cc.save", data=data, method="PUT")
    req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def main():
    work = tempfile.mkdtemp(prefix="ccbk-")

    # --- Part A: cc_backup unit behavior ---
    repoA = make_git_backups(work)
    # Force a hostile global-style config IN the repo: gpgsign on + no user identity. The helper must
    # still commit (it passes -c commit.gpgsign=false + a pinned identity). Regression for the
    # "cannot run gpg" failure seen under launchd.
    git(repoA, "config", "commit.gpgsign", "true")
    git(repoA, "config", "--unset", "user.name")
    git(repoA, "config", "--unset", "user.email")
    r = cc_backup.backup(repoA, save_blob("A"), "mac", source="unit", push=True)
    check("cc_backup: first backup commits+pushes (gpgsign forced on)", not r["skipped"] and "pushed" in r["git"], r)
    check("cc_backup: latest/cc.save written", open(os.path.join(repoA, "latest", "cc.save"), "rb").read() == save_blob("A"))
    r = cc_backup.backup(repoA, save_blob("A"), "mac", push=True, dedupe=True)
    check("cc_backup: dedupe skips identical save", r["skipped"] and "skipped" in r["git"], r)
    r = cc_backup.backup(repoA, save_blob("B"), "mac", push=True)
    check("cc_backup: new content commits again", not r["skipped"] and "pushed" in r["git"], r)
    commits = git(repoA, "log", "--oneline").stdout
    check("cc_backup: two backup commits (A,B; dup skipped)", commits.count("backup(mac)") == 2, commits)

    # --- Part B: save-server auto-backup of received PUTs ---
    repoB = make_git_backups(work)
    server_save = os.path.join(work, "hub-cc.save")
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    server = subprocess.Popen(
        [PY, SERVER, "--host", "127.0.0.1", "--port", str(port), "--save", server_save,
         "--backup-repo", repoB, "--backup-label", "hub", "--backup-push"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

        code = put(url, save_blob("PHONE1"))
        check("server PUT returns 200", code == 200)
        # auto-backup runs in a daemon thread — poll for the commit to land
        ok = False
        for _ in range(50):
            if os.path.isfile(os.path.join(repoB, "latest", "cc.save")) and \
               open(os.path.join(repoB, "latest", "cc.save"), "rb").read() == save_blob("PHONE1"):
                ok = True
                break
            time.sleep(0.1)
        check("hub auto-backed-up the received save", ok)
        # commit + push happen in the daemon thread after the snapshot file appears — poll for them
        branch = git(repoB, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        committed = pushed = False
        for _ in range(80):
            if "backup(hub)" in git(repoB, "log", "--oneline").stdout:
                committed = True
            if "backup(hub)" in git(repoB, "log", "origin/" + branch, "--oneline").stdout:
                pushed = True
            if committed and pushed:
                break
            time.sleep(0.1)
        check("hub backup was committed", committed)
        check("hub backup was pushed to remote", pushed)

        # identical PUT -> deduped (no second commit)
        put(url, save_blob("PHONE1"))
        time.sleep(1.0)
        n1 = git(repoB, "log", "--oneline").stdout.count("backup(hub)")
        check("hub dedupes identical received save", n1 == 1, f"{n1} hub commits")

        # new save -> new commit
        put(url, save_blob("PHONE2"))
        ok2 = False
        for _ in range(50):
            if git(repoB, "log", "--oneline").stdout.count("backup(hub)") == 2:
                ok2 = True
                break
            time.sleep(0.1)
        check("hub commits a new received save", ok2)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    print(f"\n{_passes} passed, {len(_fails)} failed")
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
