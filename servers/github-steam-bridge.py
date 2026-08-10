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


# --- Keep-both merge (optional; mirrors cc-tailsync's SaveMerge / CCSaveCrypto) ----------------------
# CrossCode's cc.save is JSON {slots:[<enc>...], autoSlot:<enc>?, globals:<enc>, lastSlot:int}; each
# <enc> is "[-!_0_!-]" + base64(CryptoJS.AES "Salted__" envelope) under the constant passphrase
# ":_.NaN0" (see CCSave.swift for the derivation). The per-slot key ignores the slot index, so an
# encrypted blob is portable between files — the merge only ever MOVES existing blobs (never
# re-encrypts), so it can't corrupt a slot. We decrypt solely to dedup by content and to label saves.
#
# Decryption needs AES, which the stdlib lacks. We try pycryptodome then cryptography; if NEITHER is
# present the bridge falls back to the safe manual-conflict behavior (changes nothing).
CC_PASSPHRASE = b":_.NaN0"
CC_MARKER = "[-!_0_!-]"


def _aes_cbc_decrypt(key: bytes, iv: bytes, ct: bytes):
    try:
        from Crypto.Cipher import AES  # pycryptodome
        return AES.new(key, AES.MODE_CBC, iv).decrypt(ct)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        return d.update(ct) + d.finalize()
    except ImportError:
        return None


def crypto_available() -> bool:
    return _aes_cbc_decrypt(b"\0" * 32, b"\0" * 16, b"\0" * 16) is not None


def _evp_bytes_to_key(passphrase: bytes, salt: bytes, key_len=32, iv_len=16):
    d = b""
    prev = b""
    while len(d) < key_len + iv_len:
        prev = hashlib.md5(prev + passphrase + salt).digest()
        d += prev
    return d[:key_len], d[key_len:key_len + iv_len]


def cc_decrypt(field):
    """Decrypt one '[-!_0_!-]…' field to raw JSON bytes, or None if malformed/undecodable."""
    if not isinstance(field, str) or not field.startswith(CC_MARKER):
        return None
    try:
        raw = base64.b64decode(field[len(CC_MARKER):].replace("\n", ""))
    except Exception:
        return None
    if len(raw) <= 16 or raw[:8] != b"Salted__":
        return None
    key, iv = _evp_bytes_to_key(CC_PASSPHRASE, raw[8:16])
    pt = _aes_cbc_decrypt(key, iv, raw[16:])
    if not pt:
        return None
    pad = pt[-1]
    # Full PKCS7 check (every padding byte must equal the pad length) — matches Swift's CommonCrypto,
    # so the two platforms agree on exactly which blobs are decodable.
    if pad < 1 or pad > 16 or pt[-pad:] != bytes([pad]) * pad:
        return None
    return pt[:-pad]


def cc_content_key(field):
    """Stable identity for a slot's decrypted content (dedup across files). None if undecodable."""
    plain = cc_decrypt(field)
    return hashlib.sha256(plain).hexdigest() if plain is not None else None


def cc_slot_summary(field):
    plain = cc_decrypt(field)
    if plain is None:
        return None
    try:
        o = json.loads(plain)
    except Exception:
        return None
    pt = o.get("playtime", 0) or 0
    area = (o.get("area", {}) or {}).get("en_US") if isinstance(o.get("area"), dict) else o.get("map")
    lvl = (o.get("player", {}) or {}).get("level")
    return "%s · Lv%s · %dh%02dm" % (area or "?", lvl if lvl is not None else "?",
                                     int(pt // 3600), int(pt % 3600 // 60))


def cc_content_keys(save_bytes):
    """The set of decrypted-content identities of every save in a cc.save (slots + autoSlot). Lets two
    files that hold the same saves compare equal even when their bytes / active autoslot differ — the
    basis for cross-device convergence. None if the file can't be parsed."""
    try:
        o = json.loads(save_bytes)
    except Exception:
        return None
    keys = set()
    for s in (o.get("slots") or []):
        ck = cc_content_key(s)
        if ck:
            keys.add(ck)
    if o.get("autoSlot"):
        ck = cc_content_key(o["autoSlot"])
        if ck:
            keys.add(ck)
    return keys


def merge_saves(local_bytes, remote_bytes):
    """Append remote's divergent manual slots + its autoSlot into local's slots[] (keep-both). Reuses
    encrypted blobs verbatim (no re-encryption); local autoSlot/globals/lastSlot win. Returns
    (merged_bytes, [summaries]) or (None, []) if inputs are malformed, ANY remote slot can't be decoded
    (we refuse to silently drop — then erase from the hub — a save we can't read), or the result fails
    validation."""
    try:
        local = json.loads(local_bytes)
        remote = json.loads(remote_bytes)
    except Exception:
        return None, []
    if not isinstance(local.get("slots"), list):
        return None, []
    slots = list(local["slots"])
    seen = set()
    for s in slots:
        ck = cc_content_key(s)
        if ck:
            seen.add(ck)
    if local.get("autoSlot"):
        ck = cc_content_key(local["autoSlot"])
        if ck:
            seen.add(ck)
    added = []
    added_blobs = []

    def take(field, label):
        ck = cc_content_key(field)
        if not ck:
            return False  # undecodable remote save -> abort keep-both (never drop-and-push)
        if ck not in seen:
            seen.add(ck)
            slots.append(field)
            added_blobs.append(field)
            added.append(label(field))
        return True

    for s in (remote.get("slots") or []):
        if not take(s, lambda f: cc_slot_summary(f) or "manual save"):
            return None, []
    auto = remote.get("autoSlot")
    if auto:
        if not take(auto, lambda f: "Autosave · " + (cc_slot_summary(f) or "?")):
            return None, []
    merged = dict(local)
    merged["slots"] = slots
    out = json.dumps(merged).encode()
    # Validate before returning: structure sound + every slot WE ADDED still decrypts.
    if not _validate_save(out, added_blobs):
        return None, []
    return out, added


def _validate_save(data, added_blobs):
    try:
        o = json.loads(data)
    except Exception:
        return False
    if not isinstance(o.get("slots"), list):
        return False
    if not isinstance(o.get("lastSlot"), int):
        return False
    added = set(added_blobs)
    for s in o["slots"]:
        if s in added:  # only re-validate the blobs we appended (local's existing slots are untouched)
            p = cc_decrypt(s)
            if p is None:
                return False
            try:
                json.loads(p)
            except Exception:
                return False
    return True


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
    ap.add_argument("--no-merge", action="store_true",
                    help="on a conflict, do NOT keep-both merge; just report and change nothing")
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
        # Both moved since the last sync. First: are these actually the SAME saves, just different
        # bytes (encoding / which save is the active autoslot)? That routinely happens after a
        # cross-device keep-both. If the content sets match it's not a real conflict — record the sha so
        # we converge and stop here, instead of re-merging/re-prompting forever.
        if crypto_available() and not args.no_merge:
            remote_content_peek = base64.b64decode(obj.get("content", "").replace("\n", ""))
            lk, rk = cc_content_keys(local), cc_content_keys(remote_content_peek)
            if lk is not None and rk is not None and lk == rk:
                if remote_sha:
                    save_last_synced(remote_sha)
                print("=> in sync (same saves, different bytes/autoslot)"); return
        # Otherwise it's a genuine divergence. Default: KEEP BOTH (merge the hub's divergent saves into
        # the local Steam save as extra slots) so you pick/delete the bad one in CrossCode's own Load
        # menu — same as the phone. Falls back to safe manual-conflict when disabled, the crypto lib is
        # missing, or a safe merge isn't possible.
        if args.no_merge:
            print("=> CONFLICT: both local and remote changed since the last sync.")
            print("   Resolve manually: keep one, then re-run. (Nothing was changed.)")
            sys.exit(3)
        if not crypto_available():
            print("=> CONFLICT: both sides changed. Keep-both merge needs an AES lib.")
            print("   Install one (`pip install pycryptodome`) for auto keep-both, or pass --no-merge.")
            print("   Nothing was changed.")
            sys.exit(3)
        remote_content = base64.b64decode(obj.get("content", "").replace("\n", ""))
        merged, added = merge_saves(local, remote_content)
        if merged is None:
            print("=> CONFLICT: both sides changed, but a safe merge wasn't possible.")
            print("   (A save in the hub couldn't be read; nothing was changed so it's preserved.)")
            print("   Resolve manually: keep one, then re-run.")
            sys.exit(3)
        if args.dry_run:
            print("=> keep-both merge (dry-run, no change): would add %d save(s):" % len(added))
            for a in added:
                print("     + " + a)
            return
        action = "merge"

    if args.dry_run:
        print("=> %s (dry-run, no change)" % action); return

    if action == "merge":
        # Write the merged save locally (back up first), then push it to the hub so BOTH saves are
        # preserved everywhere and the next sync is clean. Idempotent: re-running adds nothing.
        if os.path.isfile(save):
            shutil.copy2(save, save + ".backup")
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(save))
        with os.fdopen(fd, "wb") as f:
            f.write(merged)
        os.replace(tmp, save)
        body = {
            "message": "bridge: keep-both merge from %s" % (os.uname().nodename if hasattr(os, "uname") else "pc"),
            "content": base64.b64encode(merged).decode(),
            "committer": {"name": "cc-saves bridge", "email": "ccsync@users.noreply.github.com"},
        }
        if remote_sha:
            body["sha"] = remote_sha
        st, resp = api("PUT", repo, path, token, body)
        if st in (200, 201):
            new_sha = resp.get("content", {}).get("sha")
            if new_sha:
                save_last_synced(new_sha)
            print("=> kept both: merged %d hub save(s) into the local Steam save and pushed (sha %s)."
                  % (len(added), new_sha))
            for a in added:
                print("     + " + a)
            print("   Launch CrossCode and delete any save you don't want from the Load menu.")
        else:
            sys.exit("error: merge push failed (HTTP %s): %s" % (st, resp.get("message")))
    elif action == "push":
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
