#!/usr/bin/env python3
"""cc-tailsync save-server — the "store my CrossCode saves on a PC" hub, reachable over Tailscale.

Serves the CrossCode desktop save over HTTP so the cc-ios app (or another PC) can pull/push it
wirelessly from anywhere on your tailnet. The file it mirrors is the same one the desktop game
reads/writes, so Steam Cloud then distributes it across your PCs automatically.

Cross-platform: the default save path is detected per-OS (Windows / macOS / Linux). Run it on an
always-on machine that has the CrossCode save (and Steam):

    save-server.py                      # binds 0.0.0.0:8765, mirrors the default save
    save-server.py --port 9000
    CC_SYNC_TOKEN=secret save-server.py # require Authorization: Bearer secret

Endpoints:
    GET  /status     -> {"exists","size","mtime","sha256"}
    GET  /cc.save    -> raw save bytes (+ Last-Modified, ETag)
    PUT  /cc.save    -> write save (atomic, keeps one .backup); last-writer-wins by mtime

Bind to your Tailscale IP (or 0.0.0.0 and rely on tailnet ACLs). Pair with a `cc-sync.json` on the
iPhone pointing at http://<tailscale-ip-or-magicdns-host>:<port>.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Shared snapshot+git helper (lives next to this file; the install wrappers copy both). Optional:
# the server runs fine without it — auto-backup just stays disabled.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import cc_backup
except Exception:
    cc_backup = None


def default_save_path():
    """The canonical desktop CrossCode save location for the current OS."""
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "CrossCode", "cc.save")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CrossCode/Default/cc.save")
    # Linux / other: respect XDG_CONFIG_HOME, else ~/.config
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(xdg, "CrossCode", "Default", "cc.save")


DEFAULT_SAVE = default_save_path()
# Accept the new token var; fall back to the legacy cc-ios name for continuity.
TOKEN = os.environ.get("CC_SYNC_TOKEN") or os.environ.get("CCIOS_SYNC_TOKEN", "")
SAVE_PATH = DEFAULT_SAVE

# Optional auto-backup of every received save into a cc-tailsync-backups git checkout. Configured in
# main(); when BACKUP_REPO is set, each new save (deduped by sha) is snapshotted + committed (+pushed
# if BACKUP_PUSH). This is how the PHONE's saves reach GitHub — they flow through this hub.
BACKUP_REPO = ""
BACKUP_LABEL = "hub"
BACKUP_PUSH = False
BACKUP_DEDUPE = True


def _auto_backup(data):
    """Run a backup of `data` in a daemon thread so it never blocks the HTTP response."""
    if not (BACKUP_REPO and cc_backup):
        return

    def work():
        try:
            r = cc_backup.backup(BACKUP_REPO, data, BACKUP_LABEL, source="hub",
                                 push=BACKUP_PUSH, dedupe=BACKUP_DEDUPE)
            if not r.get("skipped"):
                sys.stderr.write(f"[save-server] backup: {r['git']} ({r['sha'][:12]})\n")
        except Exception as e:  # never let a backup failure affect serving
            sys.stderr.write(f"[save-server] backup error: {e}\n")

    threading.Thread(target=work, daemon=True).start()




def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def status():
    if not os.path.isfile(SAVE_PATH):
        return {"exists": False, "size": 0, "mtime": 0, "sha256": ""}
    st = os.stat(SAVE_PATH)
    return {
        "exists": True,
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "sha256": sha256(SAVE_PATH),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "cc-tailsync/1.0"

    def _auth_ok(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _guard(self):
        if not self._auth_ok():
            self._send_json(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._guard():
            return
        if self.path == "/status":
            self._send_json(200, status())
            return
        if self.path == "/cc.save":
            if not os.path.isfile(SAVE_PATH):
                self._send_json(404, {"error": "no save"})
                return
            data = open(SAVE_PATH, "rb").read()
            st = status()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("ETag", st["sha256"])
            self.send_header("X-Save-Mtime", str(st["mtime"]))
            self.end_headers()
            self.wfile.write(data)
            return
        self._send_json(404, {"error": "not found"})

    def do_PUT(self):
        if not self._guard():
            return
        if self.path != "/cc.save":
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            self._send_json(400, {"error": "empty body"})
            return
        data = self.rfile.read(length)
        os.makedirs(os.path.dirname(SAVE_PATH), exist_ok=True)
        if os.path.isfile(SAVE_PATH):
            shutil.copy2(SAVE_PATH, SAVE_PATH + ".backup")
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(SAVE_PATH))
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, SAVE_PATH)
        # Version this save into the backups repo (off the response path). This is what carries the
        # phone's saves to GitHub — they arrive here as a PUT, then get committed+pushed.
        _auto_backup(data)
        self._send_json(200, status())

    def log_message(self, fmt, *args):
        sys.stderr.write("[save-server] " + (fmt % args) + "\n")


def main():
    global SAVE_PATH, BACKUP_REPO, BACKUP_LABEL, BACKUP_PUSH, BACKUP_DEDUPE
    ap = argparse.ArgumentParser(description="cc-tailsync save-server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--save", default=DEFAULT_SAVE, help="path to cc.save to mirror")
    ap.add_argument("--backup-repo", default=os.environ.get("CC_BACKUP_REPO", ""),
                    help="path to a cc-tailsync-backups git checkout; every received save is "
                         "snapshotted + committed there (this is how the phone's saves reach GitHub)")
    ap.add_argument("--backup-label", default="hub",
                    help="snapshot label for auto-backups (default: hub)")
    ap.add_argument("--backup-push", action="store_true",
                    help="also git push each auto-backup to the remote (else commit locally)")
    ap.add_argument("--no-backup-dedupe", action="store_true",
                    help="snapshot every received save even if identical to the last")
    args = ap.parse_args()
    SAVE_PATH = os.path.expanduser(args.save)
    BACKUP_REPO = os.path.expanduser(args.backup_repo) if args.backup_repo else ""
    BACKUP_LABEL = args.backup_label
    BACKUP_PUSH = args.backup_push
    BACKUP_DEDUPE = not args.no_backup_dedupe

    print(f"[save-server] platform: {sys.platform}")
    print(f"[save-server] mirroring: {SAVE_PATH}")
    print(f"[save-server] listening on http://{args.host}:{args.port}")
    print(f"[save-server] auth: {'token required' if TOKEN else 'open (rely on tailnet ACLs)'}")
    if BACKUP_REPO:
        if not cc_backup:
            print("[save-server] WARNING: --backup-repo set but cc_backup.py not found next to "
                  "this script; auto-backup DISABLED.")
        elif not cc_backup.is_git_repo(BACKUP_REPO):
            print(f"[save-server] WARNING: {BACKUP_REPO} is not a git repo; saves will be "
                  "snapshotted locally but not committed/pushed.")
        else:
            print(f"[save-server] auto-backup: {BACKUP_REPO} "
                  f"(label={BACKUP_LABEL}, push={'yes' if BACKUP_PUSH else 'no'})")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
