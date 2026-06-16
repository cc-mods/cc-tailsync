# cc-tailsync

Wireless **CrossCode save sync** over your own network — built for
**[cc-ios](https://github.com/cc-mods/cc-ios)** but useful for any PC↔PC setup.

> ### ⚠️ You must own CrossCode. This repo contains **no game code or assets** — only sync code.

Part of the [**cc-mods**](https://github.com/cc-mods) suite. It keeps your iPhone's CrossCode save
in step with your desktop's, so you can put the game down on one device and pick it up on another.

## How it works

CrossCode stores its entire save in one file, `cc.save`, that is **byte-identical** between the
desktop game and the browser-mode `localStorage` cc-ios uses. cc-tailsync just moves those bytes,
**newest-wins**:

```
   iPhone (cc-ios)                     PC "save hub"                 your other PCs
  ┌────────────────┐   HTTP pull/push  ┌──────────────────┐  Steam   ┌──────────────┐
  │ Documents/     │◀────────────────▶│ save-server.py    │◀────────▶│ CrossCode    │
  │   cc.save      │   (Tailscale)     │ mirrors the real  │  Cloud   │ desktop save │
  └────────────────┘                   │ desktop cc.save   │          └──────────────┘
                                       └──────────────────┘
```

- The **save-server** runs on an always-on PC and serves the real desktop `cc.save` over HTTP
  (`GET/PUT /cc.save`, `GET /status`). Bind it to your **[Tailscale](https://tailscale.com)** IP so
  it's reachable from your phone anywhere, privately.
- The **iOS client** (`CCTailsync`, a Swift package) pushes on every in-game save and pulls a newer
  save at app launch. It's **fail-safe**: with no config or an unreachable server it's a silent
  no-op and never blocks the game.
- **PC↔PC** needs nothing extra — **Steam Cloud** already distributes the desktop `cc.save`.

Everything resolves by modification time with a SHA-256 short-circuit, so neither side clobbers
progress made offline on the other.

## Components

```
cc-tailsync/
  Package.swift                      SwiftPM: the CCTailsync library (iOS + macOS)
  Sources/CCTailsync/
    TailscaleSyncClient.swift        the iOS sync client (consumed by cc-ios's SaveSyncProvider seam)
  servers/
    save-server.py                   the HTTP save hub (Windows / macOS / Linux save paths)
    macos/save-server.sh             run it persistently on macOS (launchd)
    windows/save-server.ps1          run it persistently on Windows (Scheduled Task)
  tools/
    save-manager.py                  cross-platform CLI: FORCE/sync a save between any of your
                                     platforms (local file / USB iPhone / a save-server URL)
    save-manager-test.py             stdlib integration tests for save-manager (no device needed)
    setup-sync.sh                    detect this Mac's Tailscale IP + push cc-sync.json to the phone
    save-sync.sh                     one-shot USB sync (no network), newest-wins
    integrate-ios.sh                 wire CCTailsync into a cc-ios checkout (one command)
  cc-endpoints.example.json          template for naming your machines (copy -> cc-endpoints.json)
  docs/
    iOS.md  macOS.md  Windows.md     per-platform setup
    save-manager.md                  the save-manager CLI: endpoints, commands, recipes
    Tailscale.md                     MagicDNS / tailscale serve / Taildrop / key-expiry setup
```

## Quick start

You need two things: a **save-server** on an always-on PC, and the **iOS client** wired into cc-ios.

### 1. Run the save-server on your PC

- **Windows:** `servers\windows\save-server.ps1 install` — installs a Scheduled Task that serves
  `%LOCALAPPDATA%\CrossCode\cc.save` on port 8765 and restarts on failure. See
  [`docs/Windows.md`](docs/Windows.md).
- **macOS:** `servers/macos/save-server.sh install` — installs a launchd service that serves
  `~/Library/Application Support/CrossCode/Default/cc.save`. See [`docs/macOS.md`](docs/macOS.md).

Put the host on your tailnet (`tailscale up`) so the phone can reach it.

### 2. Add sync to cc-ios

From this repo, with a cc-ios checkout nearby:

```bash
tools/integrate-ios.sh --ios-repo /path/to/cc-ios   # adds the CCTailsync package + wiring
# then point the app at your server (USB-connected iPhone):
tools/setup-sync.sh --ip <your-tailscale-ip>        # writes + pushes cc-sync.json
```

Rebuild cc-ios. It now pushes on every save and pulls a newer PC save at launch. See
[`docs/iOS.md`](docs/iOS.md) for the full walkthrough, MagicDNS hostnames, and bearer-token auth.

> **No Tailscale? No network?** `tools/save-sync.sh` does a one-shot **USB** sync between a
> connected iPhone and the desktop save via `devicectl` — newest-wins, both directions.

## Force a save between platforms (save-manager)

The push-on-save / pull-at-launch client above keeps things in sync automatically. When you instead
want to **deliberately force one device's save onto another** — "make my Windows save match what I
just played on the phone" — use the **`tools/save-manager.py`** CLI. It's pure Python 3 (stdlib
only) and speaks the same protocol as the save-server, so it runs on **macOS and Windows** alike.

Each platform is an **endpoint**:

| token | what it is | where it works |
|---|---|---|
| `local` | this machine's desktop CrossCode save (auto-detected per OS) | anywhere |
| `ios` | a USB-connected iPhone running cc-ios (`xcrun devicectl`) | macOS only |
| `http://host:port` | another desktop running `save-server.py`, over your tailnet | anywhere |
| `<name>` | a friendly alias from `cc-endpoints.json` | anywhere |

```bash
# see every device's save side-by-side and which is newest
tools/save-manager.py status local ios windows

# FORCE (overwrite) — "any platform to any other"
tools/save-manager.py push ios local       # phone   -> this Mac
tools/save-manager.py push local windows    # this Mac -> the Windows desktop (its save-server)
tools/save-manager.py push windows ios       # Windows  -> phone   (run on the Mac; routes via USB)

# or let it pick the newer side
tools/save-manager.py sync local windows
```

Name your machines once so you can say `windows` instead of an IP — copy
[`cc-endpoints.example.json`](cc-endpoints.example.json) to `cc-endpoints.json` (git-ignored):

```json
{ "endpoints": { "windows": "http://100.100.0.21:8765",
                 "mac":     "http://100.100.0.10:8765" } }
```

## Durable backups (the private cc-tailsync-backups org repo)

`backup` / `list` / `restore` snapshot a save with a `sha`+`meta.json`, in the same layout as the
private **[cc-tailsync-backups](https://github.com/cc-mods/cc-tailsync-backups)** org repo
(`snapshots/<stamp>-<source>/cc.save` + `latest/cc.save`). If a checkout of that repo sits next to
this one (or at `~/.cc-tailsync/cc-tailsync-backups`, or `$CC_BACKUPS_DIR`), the manager uses it
automatically — so backups are versioned and off-device:

```bash
save-manager.py backup ios --push          # snapshot the phone's save AND git commit+push to the org repo
save-manager.py list --pull                 # pull latest, then list every snapshot
save-manager.py restore latest local --pull # pull, then restore newest snapshot to this desktop
save-manager.py restore 3f547698 ios        # restore a specific snapshot (by sha) to the phone
```

`--push` is multi-agent safe (it pulls --rebase before pushing and never force-pushes). Without a
git checkout it falls back to a plain local folder (`~/.cc-tailsync/backups`); `--dir` overrides.

## Stable names instead of IPs (MagicDNS)

Endpoints take any URL, so prefer **MagicDNS hostnames** over `100.x` Tailscale IPs — they're stable
and keep IPs out of your configs. With MagicDNS on (admin console → DNS), bare tailnet names resolve:

```json
{ "endpoints": { "windows": "http://small:8765",
                 "mac":     "http://milively-mbp-work:8765" } }
```

Even better, run `tailscale serve --bg localhost:8765` on the save-server host to get an
auto-TLS **HTTPS** endpoint with a stable name (`https://<host>.<tailnet>.ts.net`), then point the
config there — no port, encrypted, tailnet-only. See [`docs/save-manager.md`](docs/save-manager.md)
and [`docs/Tailscale.md`](docs/Tailscale.md).

## Relationship to cc-ios

cc-ios is **standalone**: it persists saves to a file and offers a Files-app backup folder with
**zero** dependency on cc-tailsync. cc-ios only exposes a small `SaveSyncProvider` protocol +
`SaveSync.provider` registry. `integrate-ios.sh` adds this package to cc-ios's Xcode project and
drops in a 3-line bootstrap that conforms `TailscaleSyncClient` to that protocol and registers it.
Run `integrate-ios.sh --remove` to cleanly return cc-ios to its standalone state. **cc-tailsync
never depends on cc-ios** — the dependency only goes one way.

## Security & privacy

- `cc-sync.json` (your server URL + optional token) is **git-ignored** — never commit an IP or
  token. Set a bearer token with `--token` / `CC_SYNC_TOKEN` to require `Authorization: Bearer …`.
- The server binds `0.0.0.0` but you rely on **tailnet ACLs** for access control; only devices on
  your tailnet can reach it. The save file never leaves your machines.

## Legal

Unofficial fan project, **not affiliated with, authorized, or endorsed by Radical Fish Games**.
Contains no CrossCode code or assets. cc-tailsync's own source is MIT (see [`LICENSE`](LICENSE)).
CrossCode and Tailscale belong to their respective owners.
