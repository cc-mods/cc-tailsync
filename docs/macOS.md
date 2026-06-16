# cc-tailsync save-server on macOS

Run the save hub on a Mac so your iPhone (and other PCs) can sync CrossCode saves over Tailscale.

## Prerequisites

- Python 3 (preinstalled on macOS, or `brew install python`).
- CrossCode installed (Steam/GOG/itch). The default save is
  `~/Library/Application Support/CrossCode/Default/cc.save`.
- [Tailscale](https://tailscale.com) up (`tailscale up`).

## Run it once (foreground)

```bash
servers/save-server.py                 # binds 0.0.0.0:8765, mirrors the default save
servers/save-server.py --port 9000     # custom port
servers/save-server.py --save "/path/to/cc.save"
CC_SYNC_TOKEN=secret servers/save-server.py    # require Authorization: Bearer secret
```

Endpoints: `GET /status`, `GET /cc.save`, `PUT /cc.save`.

## Run it persistently (launchd)

```bash
servers/macos/save-server.sh install              # install + start now; runs at login, restarts on crash
servers/macos/save-server.sh install --port 9000
CC_SYNC_TOKEN=secret servers/macos/save-server.sh install   # with auth
servers/macos/save-server.sh status               # is it loaded?
servers/macos/save-server.sh logs                 # tail the logs
servers/macos/save-server.sh uninstall            # stop + remove
```

The service is labelled `com.cc-mods.tailsync-server` and logs to `~/.cc-tailsync/`.

### Why it copies the script to `~/.cc-tailsync`

launchd agents are denied read access to `~/Documents`, `~/Desktop`, and `~/Downloads` by macOS
**TCC** — so a service can't run `save-server.py` straight from a clone in one of those folders
(`Operation not permitted`, even though an interactive shell can). `install` therefore copies the
script to `~/.cc-tailsync/` (a dotfolder, not TCC-protected) and points the plist there. **Re-run
`install` after editing the server.** The desktop save under `~/Library` is not TCC-protected, so
the service can read/write it fine.

## Make it reachable from the phone

Find this Mac's Tailscale IP and point the app at it:

```bash
tailscale ip -4                      # e.g. 100.x.y.z
```

Then on the iOS side, `tools/setup-sync.sh --ip 100.x.y.z` (see [`iOS.md`](iOS.md)). With **MagicDNS**
you can use the hostname instead: `--url http://my-mac:8765`.

## Tailscale notes

- Binding `0.0.0.0` is fine — access is gated by your **tailnet ACLs**; only your own devices can
  reach it. For a single-user tailnet the default policy already allows your devices to talk.
- `tailscale serve` can add HTTPS in front, but it's GET-only (it can't proxy the `PUT` this server
  needs), so stick with the raw HTTP server over the tailnet.
