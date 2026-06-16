"""cc_backup — shared CrossCode save snapshot + git-backup helper for cc-tailsync.

Used by BOTH `tools/save-manager.py` (the desktop CLI) and `servers/save-server.py` (the hub), so a
save can be versioned into the private **cc-tailsync-backups** repo in one consistent layout from any
device — including the phone, whose saves reach the hub and get committed there automatically:

    snapshots/<UTC-stamp>-<label>/cc.save   # immutable point-in-time snapshot
    snapshots/<UTC-stamp>-<label>/meta.json # {source, label, sha256, size, mtimes}
    latest/cc.save                          # always the most recent snapshot
    latest/meta.json

Pure Python 3 stdlib; only the `git` CLI is needed for committing/pushing. No third-party packages.
This module deliberately has **no dependency on save-manager or save-server** so both can import it.
"""
import hashlib
import json
import os
import shutil
import subprocess
import threading
from datetime import datetime, timezone

CO_AUTHOR = "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

# Serializes git operations so concurrent callers (e.g. the threaded save-server) never interleave
# commits/pushes against the same repo.
_GIT_LOCK = threading.Lock()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def stamp_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mtime_iso(mtime):
    return datetime.fromtimestamp(mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if mtime else ""


def is_git_repo(d):
    return os.path.isdir(os.path.join(os.path.expanduser(d), ".git"))


def _git(d, *args):
    return subprocess.run(["git", "-C", os.path.expanduser(d), *args],
                          capture_output=True, text=True)


def git_pull(d):
    """Best-effort fast-forward pull (no-op if not a git repo)."""
    if is_git_repo(d):
        _git(d, "pull", "--ff-only", "--quiet")


def git_commit_push(d, message, push=True):
    """Commit staged changes; optionally pull --rebase then push. Returns a short status string.

    Never force-pushes (multi-agent safe). Tolerates 'nothing to commit' and a missing remote.
    """
    if not is_git_repo(d):
        return "saved locally (not a git repo)"
    with _GIT_LOCK:
        _git(d, "add", "-A")
        r = _git(d, "commit", "-m", message)
        if r.returncode != 0:
            if "nothing to commit" in (r.stdout + r.stderr):
                return "no change — nothing to commit"
            return f"commit skipped ({(r.stderr or r.stdout).strip()[:120]})"
        if not push:
            return "committed locally"
        if _git(d, "remote").stdout.strip() == "":
            return "committed locally (no remote configured)"
        _git(d, "pull", "--rebase", "--quiet")
        p = _git(d, "push", "--quiet")
        return "committed + pushed" if p.returncode == 0 else "committed locally (push failed — check remote/auth)"


def write_snapshot(backups_dir, data, label, mtime=0, source=""):
    """Write `snapshots/<stamp>-<label>/{cc.save,meta.json}` + refresh `latest/`. Returns (dir, meta)."""
    base = os.path.expanduser(backups_dir)
    sha = sha256(data)
    snap = os.path.join(base, "snapshots", f"{stamp_utc()}-{label}")
    os.makedirs(snap, exist_ok=True)
    with open(os.path.join(snap, "cc.save"), "wb") as f:
        f.write(data)
    meta = {"source": source or label, "label": label, "file": "cc.save",
            "size_bytes": len(data), "sha256": sha,
            "save_mtime_utc": _mtime_iso(mtime), "captured_utc": _now_iso()}
    json.dump(meta, open(os.path.join(snap, "meta.json"), "w"), indent=2)
    latest = os.path.join(base, "latest")
    os.makedirs(latest, exist_ok=True)
    shutil.copy2(os.path.join(snap, "cc.save"), os.path.join(latest, "cc.save"))
    json.dump(meta, open(os.path.join(latest, "meta.json"), "w"), indent=2)
    return snap, meta


def latest_sha(backups_dir):
    """sha256 of `latest/cc.save`, or '' — lets callers skip a no-op snapshot."""
    p = os.path.join(os.path.expanduser(backups_dir), "latest", "cc.save")
    if os.path.isfile(p):
        return sha256(open(p, "rb").read())
    return ""


def backup(backups_dir, data, label, mtime=0, source="", push=False, dedupe=True):
    """Snapshot `data` into the backups repo and (optionally) git commit+push.

    Returns a dict: {"skipped": bool, "sha": str, "git": status, ["snapshot","meta"]}.
    With `dedupe`, a save identical to `latest/cc.save` is a no-op (no snapshot, no commit) — this
    is what keeps the hub from committing the same save twice.
    """
    if not data:
        return {"skipped": True, "sha": "", "git": "empty save — skipped"}
    sha = sha256(data)
    if dedupe and latest_sha(backups_dir) == sha:
        return {"skipped": True, "sha": sha, "git": "unchanged — skipped"}
    if push:
        git_pull(backups_dir)  # start from latest so our commit is additive
    snap, meta = write_snapshot(backups_dir, data, label, mtime, source)
    msg = f"backup({label}): cc.save {os.path.basename(snap)} ({len(data)}b, sha {sha[:12]})\n\n{CO_AUTHOR}"
    git = git_commit_push(backups_dir, msg, push=push)
    return {"skipped": False, "snapshot": snap, "sha": sha, "git": git, "meta": meta}
