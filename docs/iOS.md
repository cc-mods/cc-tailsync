# cc-tailsync on iOS (cc-ios)

Add wireless save sync to the **[cc-ios](https://github.com/cc-mods/cc-ios)** app. cc-ios works
without this — it persists saves to a file and offers a Files-app backup folder. cc-tailsync adds
**push-on-save / pull-at-launch** sync with a PC save-server.

## Prerequisites

- A working cc-ios checkout that builds (see its README).
- A **save-server** running on an always-on PC — see [`macOS.md`](macOS.md) or
  [`Windows.md`](Windows.md).
- Both devices on the same **[Tailscale](https://tailscale.com)** tailnet (`tailscale up`).

## 1. Wire the package into cc-ios

From this cc-tailsync checkout:

```bash
tools/integrate-ios.sh --ios-repo /path/to/cc-ios
```

This is idempotent and does three things:

1. Adds the `CCTailsync` Swift package to `cc-ios/app/project.yml`. By default it uses a **local
   path** to this checkout (great for the flat `cc-mods` layout — no tags or network needed). To
   pin to GitHub instead: `--remote` (branch `main`) or `--remote --version 0.1.0`.
2. Replaces `cc-ios/app/Sources/SaveSyncBootstrap.swift` with a version that conforms
   `TailscaleSyncClient` to cc-ios's `SaveSyncProvider` and registers it (using the app's
   `Documents/cc.save`).
3. Runs `xcodegen generate` (unless `--no-generate`).

Rebuild cc-ios (`make sim` / `make device`). To undo and return cc-ios to standalone:

```bash
tools/integrate-ios.sh --ios-repo /path/to/cc-ios --remove
```

> **Heads-up for auto-build setups:** the integration edits files **inside your cc-ios checkout**
> (`project.yml`, `SaveSyncBootstrap.swift`). They are local changes. If a watcher auto-pulls cc-ios
> and rebuilds, either commit these two files on your own branch, or re-run `integrate-ios.sh` after
> each pull. cc-ios upstream intentionally stays standalone (no hard dependency on cc-tailsync).

## 2. Point the app at your server

The app reads `Documents/cc-sync.json`:

```json
{ "url": "http://100.x.y.z:8765", "token": "optional-bearer" }
```

The easiest way to write + push it (with the iPhone connected over USB):

```bash
tools/setup-sync.sh --ip 100.x.y.z            # your PC's Tailscale IPv4
tools/setup-sync.sh --url http://my-pc:8765   # …or a MagicDNS hostname
tools/setup-sync.sh --token SECRET            # require Authorization: Bearer SECRET
```

`setup-sync.sh` detects the Mac's own Tailscale IP if you omit `--ip/--url`, writes a (git-ignored)
`cc-sync.json`, and pushes it into the app container via `xcrun devicectl device copy`. If no device
is connected it writes the file locally so you can drop it in via **Finder → Files → cc-ios**.

> Pass `--bundle-id com.you.ccios` if you build cc-ios with a custom bundle id.

## 3. Verify

Relaunch the app. On launch it pulls a newer PC save (bounded to a few seconds); on every in-game
save it pushes. Native logs show `[cc-tailsync] pulled …` / `[cc-tailsync] pushed …`. Because the
hub mirrors the real desktop `cc.save`, **Steam Cloud** then carries it to your other PCs.

## How it stays safe

- Sync is **fail-safe**: no `cc-sync.json`, or an unreachable server, → silent no-op; it never
  blocks boot.
- Conflicts resolve **newest-wins** (mtime), with a SHA-256 short-circuit to skip no-op transfers
  and avoid echo loops.
- Pull happens **only at launch** (relaunch to pick up a PC session); push happens on every save.

## No Tailscale / no server?

`tools/save-sync.sh` does a one-shot **USB** sync between a connected iPhone and the desktop save
(newest-wins, or `--to-phone` / `--from-phone`). No server, no network.
