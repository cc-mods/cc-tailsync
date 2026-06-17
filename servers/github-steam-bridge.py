#!/usr/bin/env python3
"""github-steam-bridge — mirror the desktop CrossCode Steam save <-> the GitHub cc-saves hub.

This is the PC side of the GitHub-hub sync. The iPhone talks to the GitHub repo directly (always
online, versioned). This bridge keeps a PC's **Steam** save file in sync with that same hub, so phone
progress reaches Steam Cloud (launch CrossCode afterwards to let Steam upload) and desktop progress
reaches the phone. It is the GitHub analogue of the Tailscale save-server, minus the always-on server.

WHY content-SHA, never mtime: the file's identity is the git blob SHA (SHA1 of "blob <len>\\0"+bytes)
— exactly what `git hash-object` and the GitHub Contents API report. We compare those, never wall
clocks, so there is no cross-device clock-skew data-loss path. A persisted `last_synced_sha` lets us
tell "who moved" since the last run and resolve safely:

    local == remote                      -> in sync, nothing
    local changed, remote unchanged      -> PUT local to the hub
    remote moved, local unchanged        -> write hub -> local Steam save
    both diverged                        -> CONFLICT: do nothing, print both shas (never auto-clobber)

Run it one-shot (no daemon/polling): before and after a play session, from cron/launchd/Task
Scheduler, or a file watcher. Steam Auto-Cloud uploads cc.save on the next CrossCode launch/exit.

Config (no secrets in argv): set CC_GITHUB_TOKEN (a fine-grained PAT with Contents:read/write on the
one repo), or put {"repo","path","token"} in ~/.cc-tailsync/cc-github.json. The Steam save path is
auto-detected per-OS (override with --save).

Pure Python 3 stdlib. No third-party packages.
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request


def steam_save_path():
    """The canonical desktop CrossCode (Steam) save location for the current OS."""
    if sys.platform.startswith("win"):
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "CrossCode", "cc.save")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CrossCode/Default/cc.save")
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(xdg, "CrossCode", "Default", "cc.save")


def git_blob_sha(data: bytes) -> str:
    h = hashlib.sha1()
    h.update(b"blob " + str(len(data)).encode() + b"\0")
    h.update(data)
    return h.hexdigest()


def load_config(args):
    cfg = {}
    cfg_path = os.path.expanduser(args.config or "~/.cc-tailsync/cc-github.json")
    if os.path.isfile(cfg_path):
        try:
            cfg = json.load(open(cfg_path))
        except Exception as e:
            sys.exit("error: bad config %s: %s" % (cfg_path, e))
    repo = args.repo or cfg.get("repo") or os.environ.get("CC_GITHUB_REPO")
    path = args.path or cfg.get("path") or "cc.save"
    token = os.environ.get("CC_GITHUB_TOKEN") or cfg.get("token")
    if not repo or not token:
        sys.exit("error: need a repo and a token (CC_GITHUB_TOKEN env or ~/.cc-tailsync/cc-github.json).")
    return repo, path, token


def state_path():
    return os.path.expanduser("~/.cc-tailsync/cc-github-state.json")


def load_last_synced():
    p = state_path()
    if os.path.isfile(p):
        try:
            return json.load(open(p)).get("lastSyncedSha")
        except Exception:
            return None
    return None


def save_last_synced(sha):
    p = state_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump({"lastSyncedSha": sha}, open(p, "w"))


def api(method, repo, path, token, body=None):
    url = "https://api.github.com/repos/%s/contents/%s" % (repo, path)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, (json.loads(e.read() or b"{}") if e.headers.get("Content-Type", "").startswith("application/json") else {})


def main():
    ap = argparse.ArgumentParser(description="Mirror the Steam CrossCode save <-> the GitHub cc-saves hub.")
    ap.add_argument("--repo", help='owner/name, e.g. "cc-mods/cc-saves"')
    ap.add_argument("--path", help='file path in the repo (default "cc.save")')
    ap.add_argument("--save", help="path to the local Steam cc.save (default: auto-detect per OS)")
    ap.add_argument("--config", help="config JSON path (default ~/.cc-tailsync/cc-github.json)")
    ap.add_argument("--dry-run", action="store_true", help="print the decision, change nothing")
    args = ap.parse_args()

    repo, path, token = load_config(args)
    save = os.path.expanduser(args.save) if args.save else steam_save_path()

    local = open(save, "rb").read() if os.path.isfile(save) else None
    local_sha = git_blob_sha(local) if local is not None else None

    status, obj = api("GET", repo, path, token)
    remote_sha = obj.get("sha") if status == 200 else None
    last = load_last_synced()

    print("local:  %s (%s)" % (local_sha or "—", save))
    print("remote: %s (%s/%s)" % (remote_sha or "—", repo, path))
    print("last:   %s" % (last or "—"))

    # Decision — mirrors GitHubSaveSyncClient.resolveCheck (content identity, never mtime).
    if local_sha is None and remote_sha is None:
        print("=> nothing (no save on either side)"); return
    if local_sha == remote_sha:
        if remote_sha:
            save_last_synced(remote_sha)
        print("=> in sync"); return
    if local_sha is not None and remote_sha is None:
        action = "push"   # seed the hub
    elif remote_sha == last:
        action = "push"   # remote unchanged since last sync -> local is ahead
    elif local_sha == last:
        action = "pull"   # remote moved, local unchanged -> adopt remote
    else:
        # Both moved since the last sync -> genuine divergence. Never auto-clobber.
        print("=> CONFLICT: both local and remote changed since the last sync.")
        print("   Resolve manually: keep one, then re-run. (Nothing was changed.)")
        sys.exit(3)

    if args.dry_run:
        print("=> %s (dry-run, no change)" % action); return

    if action == "push":
        body = {
            "message": "bridge: cc.save from %s" % (os.uname().nodename if hasattr(os, "uname") else "pc"),
            "content": base64.b64encode(local).decode(),
            "committer": {"name": "cc-saves bridge", "email": "ccsync@users.noreply.github.com"},
        }
        if remote_sha:
            body["sha"] = remote_sha
        st, resp = api("PUT", repo, path, token, body)
        if st in (200, 201):
            new_sha = resp.get("content", {}).get("sha")
            if new_sha:
                save_last_synced(new_sha)
            print("=> pushed local -> hub (sha %s)" % new_sha)
        else:
            sys.exit("error: push failed (HTTP %s): %s" % (st, resp.get("message")))
    else:  # pull
        content = base64.b64decode(obj.get("content", "").replace("\n", ""))
        os.makedirs(os.path.dirname(save), exist_ok=True)
        if os.path.isfile(save):
            shutil.copy2(save, save + ".backup")
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(save))
        with os.fdopen(fd, "wb") as f:
            f.write(content)
        os.replace(tmp, save)
        save_last_synced(remote_sha)
        print("=> pulled hub -> local Steam save (%d bytes). Launch CrossCode so Steam Cloud uploads it." % len(content))


if __name__ == "__main__":
    main()
