# save-manager — force/sync a CrossCode save between your platforms

`tools/save-manager.py` is a tiny, zero-dependency CLI (Python 3 stdlib only — same footprint as
`save-server.py`) for **deliberately moving a save between devices**. It complements the automatic
push-on-save / pull-at-launch client (`TailscaleSyncClient`): use that for hands-off sync, use this
when you want to *force* "make device B's save match device A's."

It reuses the rest of cc-tailsync:

- it speaks the **same HTTP protocol** as `save-server.py` (`GET /status`, `GET/PUT /cc.save`),
- the **same per-OS save-path** detection, and
- the **same `cc-sync.json` shape** (`{"url","token"}`) for tokens.

## Endpoints

An *endpoint* is any place a save lives. Pass these as `save-manager.py` arguments:

| token | meaning | available |
|---|---|---|
| `local` (`desktop`, `this`) | this machine's desktop CrossCode save | everywhere |
| `ios` (`iphone`, `phone`) | a USB-connected iPhone running cc-ios, via `xcrun devicectl` | **macOS only** |
| `http://host:port` | another desktop running `save-server.py` (reach it over Tailscale) | everywhere |
| `ssh://user@host/path` | another desktop reached over SSH (scp the save) — **no save-server needed** | everywhere |
| `/path/to/cc.save` | an explicit file | everywhere |
| `<name>` | an alias from `cc-endpoints.json` (resolves to one of the above) | everywhere |

### SSH endpoints (serverless desktop ↔ desktop)

An `ssh` endpoint moves the save with **scp** — no long-running save-server required on the other
desktop, just an SSH server it can reach over Tailscale (Windows **OpenSSH Server**, or macOS/Linux
**Remote Login**). Give the **literal** remote save path so there's no remote shell expansion:

```json
{
  "endpoints": {
    "windows-ssh": { "type": "ssh", "host": "small", "user": "you",
                     "path": "C:/Users/you/AppData/Local/CrossCode/cc.save" }
  }
}
```

or inline as a URL: `ssh://you@small/C:/Users/you/AppData/Local/CrossCode/cc.save`. Optional
`port` and `identity` (private-key path) are supported. Then:

```bash
save-manager.py push ios windows-ssh     # phone -> Windows, straight over scp (run on the Mac)
save-manager.py push windows-ssh local    # Windows -> this Mac
save-manager.py sync local windows-ssh     # newest-wins
```

scp is binary-safe and `-p` carries the remote mtime so newest-wins works. It is **not atomic on the
remote**, so a forced push leans on the pre-write safety backup + `push`'s post-write sha verify
(which it always does). **Enable Windows OpenSSH Server** (one-time, admin PowerShell):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
```

Then `ssh you@small` works over Tailscale and the `ssh` endpoint is live. (Set up key auth so scp
runs unattended — `BatchMode` is on, so password-only servers will fail fast rather than hang.)

### Naming your machines

Copy [`../cc-endpoints.example.json`](../cc-endpoints.example.json) to `cc-endpoints.json` (it's
git-ignored — it holds tailnet IPs) in the repo root or `~/.cc-tailsync/`:

```json
{
  "endpoints": {
    "windows": "http://100.100.0.21:8765",
    "mac":     "http://100.100.0.10:8765",
    "phone":   { "type": "ios", "bundle_id": "com.example.ccios" }
  }
}
```

Now `windows`, `mac`, `phone` work as tokens. `save-manager.py endpoints` prints what's configured.

## Commands

```
save-manager.py status [endpoint ...]     # show each save (size / mtime / sha) + which is newest
save-manager.py push   <src> <dst>        # FORCE: overwrite dst's save with src's
save-manager.py sync   <a> <b>            # newest-wins both ways (sha short-circuit, mtime tiebreak)
save-manager.py backup <endpoint>         # snapshot an endpoint into the backups layout
save-manager.py list                      # list local snapshots
save-manager.py restore <which> <dst>     # restore a snapshot (stamp / sha / 'latest') to an endpoint
save-manager.py endpoints                 # show configured endpoints
```

Flags: `-y/--yes` (no prompt), `--dry-run` (sync only), `--no-validate` (skip the CrossCode-save
check), `--token` (bearer for server endpoints), `--dir` (snapshot dir), `--push` (backup: git
commit+push), `--pull` (list/restore: git pull first).

## Durable backups via the cc-tailsync-backups org repo

`backup` / `list` / `restore` use the **same layout** as the private
[**cc-tailsync-backups**](https://github.com/cc-mods/cc-tailsync-backups) org repo
(`snapshots/<UTC-stamp>-<label>/cc.save` + `meta.json`, and `latest/cc.save`). The snapshot dir
**auto-resolves** to a checkout of that repo if one is found — a sibling of this repo, or
`~/.cc-tailsync/cc-tailsync-backups`, or `$CC_BACKUPS_DIR` — otherwise it falls back to
`~/.cc-tailsync/backups`. With a git checkout you get versioned, off-device history:

```bash
save-manager.py backup ios --push            # snapshot the phone, then git commit + push to the org
save-manager.py backup local --label mac --push
save-manager.py list --pull                   # pull, then list all snapshots
save-manager.py restore latest local --pull   # pull, then restore newest to this desktop
save-manager.py restore 3f547698 ios           # restore a specific snapshot (by sha prefix) to the phone
```

`--push` pulls `--rebase` before pushing and **never force-pushes** (safe alongside other agents).
That backups repo is **private** and deliberately commits `*.save` (the one place saves belong in
git); every other cc-mods repo git-ignores saves.

## Recipes (the "any platform to any other" matrix)

Run these on the **Mac** with the iPhone plugged in (the Mac is the only box with USB access to the
phone; `windows` is the Windows desktop running its `save-server.py`):

```bash
save-manager.py push ios local        # phone    -> Mac
save-manager.py push local ios         # Mac      -> phone
save-manager.py push ios windows        # phone    -> Windows
save-manager.py push windows ios         # Windows  -> phone
save-manager.py push local windows        # Mac      -> Windows
save-manager.py push windows local         # Windows  -> Mac
```

On the **Windows** box (no USB tooling for iOS there — reach the phone via the Mac, or via the
phone's own wireless sync), with `mac` = the Mac's `save-server.py`:

```bash
py tools\save-manager.py status local mac
py tools\save-manager.py push local mac      # Windows -> Mac
py tools\save-manager.py sync local mac       # reconcile, newest wins
```

> After writing to `ios`, **relaunch cc-ios** on the phone — the app injects `Documents/cc.save`
> into the game's `localStorage` at launch (the file is authoritative), so the new save takes effect
> on the next boot.

## Safety

- **Every overwrite is backed up first.** Before `push`/`sync`/`restore` writes a destination, the
  destination's current save is copied to `~/.cc-tailsync/manager-backups/<stamp>-<kind>-<sha>.save`.
- **Saves are validated** as CrossCode JSON (a top-level `slots`) before writing; `--no-validate`
  bypasses.
- **Writes are atomic** for local files (temp + rename, plus a `.backup`), and the save-server does
  the same on its side.
- **Newest-wins never clobbers blindly** — identical hashes short-circuit, otherwise the newer mtime
  wins, matching `TailscaleSyncClient`.

## Requirements & limits

- **Python 3** on PATH (`python3` on macOS/Linux, `python`/`py` on Windows). No third-party packages.
- **Reaching another desktop** — two ways: run its `save-server.py` and use an `http://` endpoint, or
  enable its SSH server and use an `ssh://` endpoint (no server process needed). `scp`/`ssh` must be
  on PATH for SSH endpoints (built in on macOS/Linux and Windows 10+).
- **Reaching iOS** needs the iPhone connected by **USB to a Mac** with Xcode tools (`xcrun devicectl`)
  and unlocked — iOS can't be an SSH/HTTP *server*. So **iOS ↔ Windows** transfers route through the
  Mac (e.g. `push ios windows-ssh` run on the Mac), or through the phone's own wireless sync to a hub.
- iOS mtime is read from the on-device file's `lastModDate`; desktop mtime from the filesystem; the
  server reports `mtime` in `/status`; SSH mtime comes from `scp -p`. All are epoch-comparable.

## Tests

```bash
python3 tools/save-manager-test.py
```

Stdlib-only integration tests: they spin up a real `save-server.py` subprocess and exercise force
push, server push/pull, newest-wins both directions, the sha short-circuit no-op, validation, and
backup/list/restore. No device or network required — safe to run anywhere.
