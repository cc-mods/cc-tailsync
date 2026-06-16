#!/usr/bin/env python3
"""cc-tailsync save-manager — move a CrossCode save between your platforms.

A tiny, zero-dependency CLI (Python 3 stdlib only, like ``save-server.py``) that lets you
**force a save from any one of your platforms to any other**, or sync them newest-wins. It meshes
with the rest of cc-tailsync: it speaks the **exact same HTTP protocol** as ``save-server.py``
(``GET /status``, ``GET/PUT /cc.save``) and reuses the same per-OS save-path detection and the
``cc-sync.json`` ``{"url","token"}`` config shape.

Each platform is an **endpoint** the manager can read and write:

  local                  this machine's desktop CrossCode save (direct file; auto-detected per OS)
  ios                    a USB-connected iPhone running cc-ios (via ``xcrun devicectl``; macOS only)
  http://host:port       another desktop running save-server.py, reachable over your tailnet
  <name>                 a friendly name from cc-endpoints.json (resolves to one of the above)
  /path/to/cc.save       an explicit file (handy for backups / scratch)

Commands:

  save-manager.py status [endpoint ...]      show each endpoint's save (size / mtime / sha) + verdict
  save-manager.py push   <src> <dst>         FORCE: overwrite dst's save with src's (safety-backs dst)
  save-manager.py sync   <a> <b>             newest-wins both ways (sha short-circuit, mtime tiebreak)
  save-manager.py backup <endpoint>          snapshot an endpoint into the backups layout
  save-manager.py list                       list local snapshots
  save-manager.py restore <which> <dst>      restore a snapshot (sha / stamp / 'latest') to dst
  save-manager.py endpoints                  show configured endpoints

Examples (run on the Mac, iPhone plugged in; 'windows' is a save-server on the Win box):

  save-manager.py push ios local             # phone  -> this Mac
  save-manager.py push local ios             # this Mac -> phone
  save-manager.py push ios windows           # phone  -> the Windows desktop (via its save-server)
  save-manager.py push windows ios           # Windows desktop -> phone
  save-manager.py sync local windows         # reconcile Mac <-> Windows, newest wins

Safety: every overwrite first copies the destination's current save to
``~/.cc-tailsync/manager-backups/`` so a forced push is always recoverable. Saves are validated as
CrossCode JSON before writing (``--no-validate`` to bypass).
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


# --------------------------------------------------------------------------- save path / model

def default_save_path():
    """Canonical desktop CrossCode save for this OS (identical logic to save-server.py)."""
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "CrossCode", "cc.save")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CrossCode/Default/cc.save")
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(xdg, "CrossCode", "Default", "cc.save")


MANAGER_BACKUPS = os.path.expanduser("~/.cc-tailsync/manager-backups")
IOS_BUNDLE_ID = os.environ.get("CCIOS_BUNDLE_ID", "com.example.ccios")
IOS_CONTAINER_SAVE = "Documents/cc.save"


def default_backups_dir():
    """Where snapshots live for backup/list/restore.

    Prefers a checkout of the private **cc-tailsync-backups** org repo (so snapshots are durable,
    versioned, and off-device) if one is found next to this repo or under ~/.cc-tailsync; otherwise
    falls back to a plain local folder. Override with $CC_BACKUPS_DIR or --dir.
    """
    env = os.environ.get("CC_BACKUPS_DIR")
    if env:
        return os.path.expanduser(env)
    here = os.path.dirname(os.path.abspath(__file__))          # .../cc-tailsync/tools
    repo_root = os.path.dirname(here)                          # .../cc-tailsync
    for c in [os.path.join(os.path.dirname(repo_root), "cc-tailsync-backups"),
              os.path.expanduser("~/.cc-tailsync/cc-tailsync-backups")]:
        if os.path.isdir(os.path.join(c, ".git")):
            return c
    return os.path.expanduser("~/.cc-tailsync/backups")


# --------------------------------------------------------------------------- git (backups repo)

def is_git_repo(d):
    return os.path.isdir(os.path.join(os.path.expanduser(d), ".git"))


def _git(d, *args, check=True):
    r = subprocess.run(["git", "-C", os.path.expanduser(d), *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        raise EndpointError(f"git {' '.join(args)} failed: {(r.stderr or r.stdout).strip()[:200]}")
    return r


def git_pull(d):
    """Best-effort fast-forward pull (no-op if not a git repo or no remote)."""
    if is_git_repo(d):
        _git(d, "pull", "--ff-only", "--quiet", check=False)


def git_commit_push(d, message):
    """Commit new snapshots and push. Coordinates with other agents (rebase) and never force-pushes.

    Returns a short status string for printing. Tolerates 'nothing to commit' and a missing remote.
    """
    if not is_git_repo(d):
        return "not a git repo — snapshot saved locally only (point --dir at a cc-tailsync-backups clone to version it)"
    _git(d, "add", "-A")
    r = _git(d, "commit", "-m", message, check=False)
    if r.returncode != 0:
        if "nothing to commit" in (r.stdout + r.stderr):
            return "nothing new to commit"
        return f"commit skipped ({(r.stderr or r.stdout).strip()[:120]})"
    # Pull-rebase before push (multi-agent safe), then push if a remote exists.
    has_remote = _git(d, "remote", check=False).stdout.strip() != ""
    if has_remote:
        _git(d, "pull", "--rebase", "--quiet", check=False)
        p = _git(d, "push", "--quiet", check=False)
        return "committed + pushed" if p.returncode == 0 else "committed locally (push failed — check the remote/auth)"
    return "committed locally (no remote configured)"



class EndpointError(Exception):
    """A user-facing problem reaching or using an endpoint."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def is_valid_save(data):
    """A CrossCode save is JSON with a top-level ``slots`` array (true on desktop AND cc-ios)."""
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception:
        return False
    return isinstance(obj, dict) and "slots" in obj


class Blob:
    """A save's bytes plus its source mtime (epoch seconds; 0 if unknown)."""

    def __init__(self, data, mtime):
        self.data = data
        self.mtime = int(mtime or 0)

    @property
    def sha(self):
        return sha256(self.data)

    @property
    def size(self):
        return len(self.data)


def stamp_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")


def iso_to_epoch(s):
    """'2026-06-15T23:36:48.000Z' -> epoch int (best-effort; 0 on failure)."""
    if not s:
        return 0
    try:
        s = s.replace("Z", "+0000")
        if "." in s:
            return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z").timestamp())
        return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception:
        return 0


# --------------------------------------------------------------------------- endpoints

class LocalEndpoint:
    """This machine's desktop save (or any explicit file path)."""

    kind = "local"

    def __init__(self, path, name="local"):
        self.path = os.path.expanduser(path)
        self.name = name

    def describe(self):
        return f"{self.name} (file {self.path})"

    def info(self):
        if not os.path.isfile(self.path):
            return {"exists": False, "size": 0, "mtime": 0, "sha256": ""}
        data = open(self.path, "rb").read()
        return {"exists": True, "size": len(data),
                "mtime": int(os.stat(self.path).st_mtime), "sha256": sha256(data)}

    def read(self):
        if not os.path.isfile(self.path):
            raise EndpointError(f"{self.describe()}: no save file")
        data = open(self.path, "rb").read()
        if not data:
            raise EndpointError(f"{self.describe()}: save file is empty")
        return Blob(data, int(os.stat(self.path).st_mtime))

    def write(self, blob):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        if os.path.isfile(self.path):
            shutil.copy2(self.path, self.path + ".backup")
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path) or ".")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(blob.data)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)


class ServerEndpoint:
    """A desktop running save-server.py, reached over HTTP/Tailscale."""

    kind = "server"

    def __init__(self, url, token=None, name=None):
        self.url = url.rstrip("/")
        self.token = token
        self.name = name or self.url

    def describe(self):
        return f"{self.name} (server {self.url})"

    def _req(self, path, method="GET", body=None):
        req = urllib.request.Request(self.url + path, data=body, method=method)
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            req.add_header("Content-Type", "application/octet-stream")
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), e.read()
        except (urllib.error.URLError, OSError) as e:
            raise EndpointError(f"{self.describe()}: unreachable ({e})")

    def info(self):
        code, _, body = self._req("/status")
        if code == 401:
            raise EndpointError(f"{self.describe()}: unauthorized (bad/missing token)")
        if code != 200:
            raise EndpointError(f"{self.describe()}: /status returned HTTP {code}")
        try:
            return json.loads(body.decode("utf-8"))
        except Exception:
            raise EndpointError(f"{self.describe()}: bad /status JSON")

    def read(self):
        code, headers, body = self._req("/cc.save")
        if code == 404:
            raise EndpointError(f"{self.describe()}: server has no save")
        if code != 200:
            raise EndpointError(f"{self.describe()}: GET /cc.save returned HTTP {code}")
        mtime = int(headers.get("X-Save-Mtime", 0) or 0)
        return Blob(body, mtime)

    def write(self, blob):
        code, _, _ = self._req("/cc.save", method="PUT", body=blob.data)
        if code == 401:
            raise EndpointError(f"{self.describe()}: unauthorized (bad/missing token)")
        if code != 200:
            raise EndpointError(f"{self.describe()}: PUT /cc.save returned HTTP {code}")


class IosEndpoint:
    """A USB-connected iPhone running cc-ios (via xcrun devicectl). macOS only."""

    kind = "ios"

    def __init__(self, bundle_id=IOS_BUNDLE_ID, device=None, name="ios"):
        self.bundle_id = bundle_id
        self._device = device
        self.name = name

    def describe(self):
        return f"{self.name} (iPhone {self.bundle_id})"

    def _xcrun(self, *args, timeout=150):
        try:
            return subprocess.run(["xcrun", *args], capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            raise EndpointError("ios: 'xcrun' not found — iOS sync needs macOS + Xcode tools")
        except subprocess.TimeoutExpired:
            raise EndpointError("ios: devicectl timed out (is the iPhone unlocked?)")

    def device(self):
        if self._device:
            return self._device
        tmp = tempfile.mktemp(suffix=".json")
        self._xcrun("devicectl", "list", "devices", "--json-output", tmp, timeout=60)
        try:
            d = json.load(open(tmp))
        except Exception:
            raise EndpointError("ios: no connected device found (plug in + unlock the iPhone)")
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        # Only consider phones with an ACTIVE connection — pairingState=="paired" is true for any
        # previously-paired phone even when unplugged, which could target the wrong/absent device.
        connected = []
        for dev in d.get("result", {}).get("devices", []):
            if dev.get("connectionProperties", {}).get("tunnelState") == "connected":
                connected.append(dev.get("identifier", ""))
        if not connected:
            raise EndpointError("ios: no connected device found (plug in + unlock the iPhone)")
        if len(connected) > 1:
            raise EndpointError(
                "ios: multiple connected devices — pass --device <identifier> to pick one: "
                + ", ".join(connected))
        self._device = connected[0]
        return self._device

    def _device_file(self):
        """Return the cc.save entry dict from the device's Documents listing, or None if absent.

        Raises EndpointError if the device itself can't be queried (so callers don't mistake an
        unreachable/locked phone for 'no save' and overwrite it without a backup)."""
        tmp = tempfile.mktemp(suffix=".json")
        r = self._xcrun("devicectl", "device", "info", "files", "--device", self.device(),
                        "--domain-type", "appDataContainer", "--domain-identifier", self.bundle_id,
                        "--subdirectory", "Documents", "--json-output", tmp, timeout=90)
        try:
            d = json.load(open(tmp))
        except Exception:
            raise EndpointError("ios: could not list Documents (is the iPhone unlocked?)")
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        if r.returncode != 0:
            raise EndpointError("ios: could not list device files (is the iPhone unlocked?)")
        for f in d.get("result", {}).get("files", []):
            if f.get("name") == "cc.save":
                return f
        return None

    def read(self):
        dest = tempfile.mktemp(suffix=".save")
        r = self._xcrun("devicectl", "device", "copy", "from", "--device", self.device(),
                        "--domain-type", "appDataContainer", "--domain-identifier", self.bundle_id,
                        "--source", IOS_CONTAINER_SAVE, "--destination", dest)
        try:
            if r.returncode != 0 or not os.path.exists(dest) or os.path.getsize(dest) == 0:
                raise EndpointError("ios: could not pull save (no save on device, or it's locked)")
            data = open(dest, "rb").read()
        finally:
            if os.path.exists(dest):
                os.remove(dest)
        mtime = iso_to_epoch((self._device_file() or {}).get("metadata", {}).get("lastModDate"))
        return Blob(data, mtime)

    def info(self):
        # Distinguish "device reachable but no save" (-> exists False) from "device unreachable"
        # (-> raise), so safety_backup can never silently skip a real save.
        entry = self._device_file()  # raises if the device can't be queried
        if entry is None:
            return {"exists": False, "size": 0, "mtime": 0, "sha256": ""}
        blob = self.read()
        return {"exists": True, "size": blob.size, "mtime": blob.mtime, "sha256": blob.sha}

    def write(self, blob):
        src = tempfile.mktemp(suffix=".save")
        with open(src, "wb") as f:
            f.write(blob.data)
        try:
            r = self._xcrun("devicectl", "device", "copy", "to", "--device", self.device(),
                            "--domain-type", "appDataContainer", "--domain-identifier", self.bundle_id,
                            "--source", src, "--destination", IOS_CONTAINER_SAVE)
            if r.returncode != 0:
                raise EndpointError(f"ios: copy to device failed: {r.stderr.strip()[:200]}")
        finally:
            if os.path.exists(src):
                os.remove(src)


# --------------------------------------------------------------------------- config / resolution

def find_config():
    env = os.environ.get("CC_ENDPOINTS")
    here = os.path.dirname(os.path.abspath(__file__))
    for p in [env, os.path.join(os.getcwd(), "cc-endpoints.json"),
              os.path.join(here, "..", "cc-endpoints.json"),
              os.path.expanduser("~/.cc-tailsync/cc-endpoints.json")]:
        if p and os.path.isfile(p):
            try:
                return json.load(open(p)), os.path.abspath(p)
            except Exception:
                pass
    return {}, None


def resolve(token, config, global_token=None):
    """Turn an endpoint token (CLI arg) into an Endpoint instance."""
    eps = config.get("endpoints", {}) if isinstance(config, dict) else {}
    cfg_token = global_token or (config.get("token") if isinstance(config, dict) else None)

    # Named endpoint from config (string URL/path/bareword, or object).
    if token in eps:
        spec = eps[token]
        if isinstance(spec, str):
            # A string value is itself an endpoint token: another config name (alias) or a
            # bareword/URL/path. Recurse (keeping the config) so aliases resolve; fall through
            # to bareword handling otherwise.
            if spec in eps and spec != token:
                return resolve(spec, config, cfg_token)
            return _bareword(spec, cfg_token)
        if isinstance(spec, dict):
            t = spec.get("type")
            if t == "server" or spec.get("url"):
                return ServerEndpoint(spec["url"], spec.get("token", cfg_token), name=token)
            if t == "ios":
                return IosEndpoint(spec.get("bundle_id", IOS_BUNDLE_ID), spec.get("device"), name=token)
            if t == "local" or spec.get("path"):
                return LocalEndpoint(spec.get("path", default_save_path()), name=token)
        raise EndpointError(f"endpoint '{token}' in config is malformed")

    return _bareword(token, cfg_token)


def _bareword(token, cfg_token):
    low = token.lower()
    if low in ("local", "desktop", "this", "self"):
        return LocalEndpoint(default_save_path(), name="local")
    if low in ("ios", "iphone", "ipad", "phone"):
        return IosEndpoint(name="ios")
    if token.startswith("http://") or token.startswith("https://"):
        return ServerEndpoint(token, cfg_token)
    if token.startswith(("/", "./", "../", "~")) or token.endswith(".save"):
        return LocalEndpoint(token, name=token)
    raise EndpointError(
        f"unknown endpoint '{token}'. Use: local, ios, an http://host:port URL, a file path, "
        f"or a name from cc-endpoints.json.")


# --------------------------------------------------------------------------- helpers

def human_mtime(m):
    if not m:
        return "—"
    return datetime.fromtimestamp(m, timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def safety_backup(ep):
    """Copy an endpoint's current save into ~/.cc-tailsync/manager-backups/ before overwrite.

    Returns the backup path, or None ONLY when the endpoint genuinely has no save to back up.
    Raises EndpointError if the endpoint *should* have a save (or can't be read) — callers must
    treat that as a hard stop so a forced write never proceeds without a recoverable backup.
    """
    info = ep.info()  # may raise EndpointError -> caller aborts the write (correct: don't clobber blind)
    if not info.get("exists"):
        return None
    blob = ep.read()
    os.makedirs(MANAGER_BACKUPS, exist_ok=True)
    name = f"{stamp_utc()}-{ep.kind}-{blob.sha[:8]}.save"
    path = os.path.join(MANAGER_BACKUPS, name)
    with open(path, "wb") as f:
        f.write(blob.data)
    return path


def confirm(prompt, assume_yes):
    if assume_yes:
        return True
    try:
        return input(prompt + " [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


# --------------------------------------------------------------------------- commands

def cmd_status(args, config):
    tokens = args.endpoints or (["local", "ios"] + list((config.get("endpoints") or {}).keys()))
    seen, rows = set(), []
    for tok in tokens:
        if tok in seen:
            continue
        seen.add(tok)
        try:
            ep = resolve(tok, config, args.token)
            info = ep.info()
            rows.append((tok, ep.describe(), info, None))
        except EndpointError as e:
            rows.append((tok, tok, None, str(e)))
    print(f"{'ENDPOINT':<12} {'SIZE':>8}  {'MODIFIED (UTC)':<21} {'SHA':<12} WHERE")
    newest = None
    for tok, desc, info, err in rows:
        if err:
            print(f"{tok:<12} {'—':>8}  {'(error)':<21} {'—':<12} {err}")
            continue
        if not info.get("exists"):
            print(f"{tok:<12} {'—':>8}  {'(no save)':<21} {'—':<12} {desc}")
            continue
        print(f"{tok:<12} {info['size']:>8}  {human_mtime(info['mtime']):<21} "
              f"{info['sha256'][:12]:<12} {desc}")
        if newest is None or info["mtime"] > newest[1]:
            newest = (tok, info["mtime"], info["sha256"])
    if newest:
        shas = {r[2]["sha256"] for r in rows if r[2] and r[2].get("exists")}
        verdict = "all in sync ✓" if len(shas) == 1 else f"NEWEST = {newest[0]} ({human_mtime(newest[1])})"
        print(f"\n{verdict}")
    return 0


def cmd_push(args, config):
    src = resolve(args.src, config, args.token)
    dst = resolve(args.dst, config, args.token)
    blob = src.read()
    if not args.no_validate and not is_valid_save(blob.data):
        raise EndpointError(f"{src.describe()}: not a valid CrossCode save (use --no-validate to force)")
    dinfo = {}
    try:
        dinfo = dst.info()
    except EndpointError:
        pass
    if dinfo.get("exists") and dinfo.get("sha256") == blob.sha:
        print(f"{dst.describe()} already has this exact save ({blob.sha[:12]}). Nothing to do.")
        return 0
    print(f"FORCE push: {src.describe()}")
    print(f"        ->  {dst.describe()}")
    print(f"   save: {blob.size} bytes, sha {blob.sha[:12]}, modified {human_mtime(blob.mtime)}")
    if dinfo.get("exists"):
        print(f"   overwriting dst: {dinfo['size']} bytes, sha {dinfo['sha256'][:12]} "
              f"(modified {human_mtime(dinfo['mtime'])})")
    if not confirm("Proceed?", args.yes):
        print("aborted.")
        return 1
    bk = safety_backup(dst)
    if bk:
        print(f"   safety backup of dst -> {bk}")
    dst.write(blob)
    try:
        after = dst.info()
        ok = after.get("sha256") == blob.sha
        print(f"   verified dst sha {after.get('sha256','')[:12]} {'✓ MATCH' if ok else '✗ MISMATCH'}")
        if not ok:
            return 2
    except EndpointError:
        print("   (could not re-read dst to verify)")
    if dst.kind == "ios":
        print("   note: relaunch cc-ios on the phone to load the new save into the game.")
    print("done.")
    return 0


def cmd_sync(args, config):
    a = resolve(args.a, config, args.token)
    b = resolve(args.b, config, args.token)
    ia, ib = a.info(), b.info()
    if not ia.get("exists") and not ib.get("exists"):
        print("neither endpoint has a save; nothing to do.")
        return 0
    if ia.get("exists") and ib.get("exists") and ia["sha256"] == ib["sha256"]:
        print(f"already in sync (sha {ia['sha256'][:12]}).")
        return 0
    if not ib.get("exists"):
        src, dst, why = a, b, f"{b.describe()} has no save"
    elif not ia.get("exists"):
        src, dst, why = b, a, f"{a.describe()} has no save"
    elif ia["mtime"] >= ib["mtime"]:
        src, dst, why = a, b, f"{a.describe()} is newer ({human_mtime(ia['mtime'])} ≥ {human_mtime(ib['mtime'])})"
    else:
        src, dst, why = b, a, f"{b.describe()} is newer ({human_mtime(ib['mtime'])} > {human_mtime(ia['mtime'])})"
    blob = src.read()
    if not args.no_validate and not is_valid_save(blob.data):
        raise EndpointError(f"{src.describe()}: not a valid CrossCode save (use --no-validate to force)")
    print(f"sync: {why}")
    print(f"  -> copy {src.describe()}  ->  {dst.describe()}  ({blob.size} b, sha {blob.sha[:12]})")
    if args.dry_run:
        print("  (dry-run; nothing written)")
        return 0
    if not confirm("Proceed?", args.yes):
        print("aborted.")
        return 1
    bk = safety_backup(dst)
    if bk:
        print(f"  safety backup of dst -> {bk}")
    dst.write(blob)
    print("done." + ("  relaunch cc-ios to load it." if dst.kind == "ios" else ""))
    return 0


def cmd_backup(args, config):
    ep = resolve(args.endpoint, config, args.token)
    blob = ep.read()
    base = os.path.expanduser(args.dir)
    if args.push:
        git_pull(base)  # start from latest so our commit is additive
    label = args.label or ep.kind
    snap = os.path.join(base, "snapshots", f"{stamp_utc()}-{label}")
    os.makedirs(snap, exist_ok=True)
    with open(os.path.join(snap, "cc.save"), "wb") as f:
        f.write(blob.data)
    meta = {"source": label, "endpoint": ep.describe(), "file": "cc.save",
            "size_bytes": blob.size, "sha256": blob.sha,
            "save_mtime_utc": human_mtime(blob.mtime),
            "captured_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    json.dump(meta, open(os.path.join(snap, "meta.json"), "w"), indent=2)
    latest = os.path.join(base, "latest")
    os.makedirs(latest, exist_ok=True)
    shutil.copy2(os.path.join(snap, "cc.save"), os.path.join(latest, "cc.save"))
    json.dump(meta, open(os.path.join(latest, "meta.json"), "w"), indent=2)
    print(f"backed up {ep.describe()} -> {snap}  ({blob.size} b, sha {blob.sha[:12]})")
    if args.push:
        status = git_commit_push(base, f"backup({label}): cc.save {os.path.basename(snap)} "
                                       f"({blob.size}b, sha {blob.sha[:12]})\n\n"
                                       f"Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>")
        print(f"  git: {status}")
    elif is_git_repo(base):
        print("  (this is a git-backed backups repo — add --push to commit + push the snapshot)")
    return 0


def _snapshots(base):
    sdir = os.path.join(os.path.expanduser(base), "snapshots")
    out = []
    if os.path.isdir(sdir):
        for name in sorted(os.listdir(sdir)):
            f = os.path.join(sdir, name, "cc.save")
            if os.path.isfile(f):
                data = open(f, "rb").read()
                out.append((name, f, len(data), sha256(data)))
    return out


def cmd_list(args, config):
    if args.pull:
        git_pull(os.path.expanduser(args.dir))
    snaps = _snapshots(args.dir)
    if not snaps:
        print(f"no snapshots under {os.path.expanduser(args.dir)}/snapshots")
        return 0
    for name, _f, size, sha in snaps:
        print(f"  {name:<34} {size:>8} b  {sha[:12]}")
    return 0


def cmd_restore(args, config):
    if args.pull:
        git_pull(os.path.expanduser(args.dir))
    snaps = _snapshots(args.dir)
    pick = None
    if args.which == "latest":
        latest = os.path.join(os.path.expanduser(args.dir), "latest", "cc.save")
        if os.path.isfile(latest):
            data = open(latest, "rb").read()
            pick = ("latest", latest, len(data), sha256(data))
    if pick is None:
        for s in snaps:
            if args.which in (s[0], s[3], s[3][:12]):
                pick = s
                break
    if pick is None:
        raise EndpointError(f"no snapshot matches '{args.which}' (try: save-manager.py list)")
    dst = resolve(args.dst, config, args.token)
    blob = Blob(open(pick[1], "rb").read(), int(os.stat(pick[1]).st_mtime))
    if not args.no_validate and not is_valid_save(blob.data):
        raise EndpointError("snapshot is not a valid CrossCode save (use --no-validate to force)")
    print(f"restore snapshot {pick[0]} ({blob.size} b, sha {blob.sha[:12]}) -> {dst.describe()}")
    if not confirm("Proceed?", args.yes):
        print("aborted.")
        return 1
    bk = safety_backup(dst)
    if bk:
        print(f"  safety backup of dst -> {bk}")
    dst.write(blob)
    print("done." + ("  relaunch cc-ios to load it." if dst.kind == "ios" else ""))
    return 0


def cmd_endpoints(args, config):
    eps = config.get("endpoints", {}) if isinstance(config, dict) else {}
    print("Built-in: local, ios, <http://host:port>, <file path>")
    if not eps:
        print("No cc-endpoints.json found. Create one to name your remotes, e.g.:")
        print('  { "endpoints": { "windows": "http://100.100.0.21:8765",')
        print('                   "mac":     "http://100.100.0.10:8765" } }')
        return 0
    print("Configured (cc-endpoints.json):")
    for k, v in eps.items():
        print(f"  {k:<12} {v}")
    return 0


# --------------------------------------------------------------------------- main

def build_parser():
    p = argparse.ArgumentParser(
        prog="save-manager.py",
        description="Force/sync a CrossCode save between desktop(s) and a USB iPhone (cc-tailsync).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Endpoints: local | ios | http://host:port | /path/to/cc.save | <name from cc-endpoints.json>")
    p.add_argument("--token", help="bearer token for server endpoints (overrides config)")
    p.add_argument("--dir", default=default_backups_dir(),
                   help="snapshot dir for backup/list/restore (default: a cc-tailsync-backups "
                        "checkout if found, else ~/.cc-tailsync/backups)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="show each endpoint's save + verdict")
    s.add_argument("endpoints", nargs="*", help="endpoints to inspect (default: local, ios, + config)")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("push", help="FORCE overwrite dst's save with src's")
    s.add_argument("src")
    s.add_argument("dst")
    s.add_argument("-y", "--yes", action="store_true", help="don't prompt")
    s.add_argument("--no-validate", action="store_true", help="skip CrossCode-save validation")
    s.set_defaults(func=cmd_push)

    s = sub.add_parser("sync", help="newest-wins between two endpoints")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("-y", "--yes", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--no-validate", action="store_true", help="skip CrossCode-save validation")
    s.set_defaults(func=cmd_sync)

    s = sub.add_parser("backup", help="snapshot an endpoint into the backups layout")
    s.add_argument("endpoint")
    s.add_argument("--label", help="snapshot label (default: endpoint kind)")
    s.add_argument("--push", action="store_true",
                   help="commit + push the snapshot (when --dir is a cc-tailsync-backups git clone)")
    s.set_defaults(func=cmd_backup)

    s = sub.add_parser("list", help="list local snapshots")
    s.add_argument("--pull", action="store_true", help="git pull the backups repo first")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("restore", help="restore a snapshot to an endpoint")
    s.add_argument("which", help="snapshot stamp, sha, or 'latest'")
    s.add_argument("dst")
    s.add_argument("-y", "--yes", action="store_true")
    s.add_argument("--no-validate", action="store_true")
    s.add_argument("--pull", action="store_true", help="git pull the backups repo first")
    s.set_defaults(func=cmd_restore)

    s = sub.add_parser("endpoints", help="show configured endpoints")
    s.set_defaults(func=cmd_endpoints)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    config, _path = find_config()
    try:
        return args.func(args, config)
    except EndpointError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
