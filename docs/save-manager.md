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
| `/path/to/cc.save` | an explicit file | everywhere |
| `<name>` | an alias from `cc-endpoints.json` (resolves to one of the above) | everywhere |

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
check), `--token` (bearer for server endpoints), `--dir` (snapshot dir; default
`~/.cc-tailsync/backups`).

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
- **Reaching another desktop** needs its `save-server.py` running and reachable (Tailscale). Start it
  persistently with `servers/macos/save-server.sh install` or `servers\windows\save-server.ps1 install`.
- **Reaching iOS** needs the iPhone connected by **USB to a Mac** with Xcode tools (`xcrun devicectl`)
  and unlocked. So **iOS ↔ Windows** transfers route through the Mac, or through the phone's own
  wireless sync to a hub.
- iOS mtime is read from the on-device file's `lastModDate`; desktop mtime from the filesystem; the
  server reports `mtime` in `/status`. All are epoch-comparable for newest-wins.

## Tests

```bash
python3 tools/save-manager-test.py
```

Stdlib-only integration tests: they spin up a real `save-server.py` subprocess and exercise force
push, server push/pull, newest-wins both directions, the sha short-circuit no-op, validation, and
backup/list/restore. No device or network required — safe to run anywhere.
