#!/usr/bin/env bash
# Configure wireless (Tailscale) save sync between this Mac and the cc-ios app on a connected
# iPhone — no hand-editing JSON, no hard-coded IPs. Part of cc-tailsync.
#
# It:
#   1. detects this Mac's Tailscale IPv4 (or takes --url / --ip),
#   2. writes a cc-sync.json pointing the app at this Mac's save-server, and
#   3. pushes it into the app's Documents via `xcrun devicectl device copy`.
#
# Pair it with the server (servers/save-server.py): run `tools/setup-sync.sh --serve` to also start
# the server now, or `--install-service` to run it persistently via launchd.
#
# Usage:
#   tools/setup-sync.sh                         # detect IP, write+push cc-sync.json
#   tools/setup-sync.sh --port 9000             # non-default port
#   tools/setup-sync.sh --token SECRET          # require Authorization: Bearer SECRET
#   tools/setup-sync.sh --ip 100.x.y.z          # override detected Tailscale IP
#   tools/setup-sync.sh --url http://host:8765  # set the full URL explicitly (e.g. MagicDNS host)
#   tools/setup-sync.sh --serve                 # also start the server in this terminal
#   tools/setup-sync.sh --install-service       # also install a launchd service (persistent)
#   tools/setup-sync.sh --device <identifier>   # target a specific device
#   tools/setup-sync.sh --bundle-id ID          # cc-ios app bundle id (default com.example.ccios)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="${CCIOS_BUNDLE_ID:-com.example.ccios}"
port=8765
token="${CC_SYNC_TOKEN:-}"
ip=""
url=""
device=""
do_serve=0
do_service=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)            port="$2"; shift 2;;
    --token)           token="$2"; shift 2;;
    --ip)              ip="$2"; shift 2;;
    --url)             url="$2"; shift 2;;
    --device)          device="$2"; shift 2;;
    --bundle-id)       bundle_id="$2"; shift 2;;
    --serve)           do_serve=1; shift;;
    --install-service) do_service=1; shift;;
    -h|--help)         grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# --- 1. Resolve the server URL --------------------------------------------------------
tailscale_bin=""
for c in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
  [[ -x "$c" ]] && { tailscale_bin="$c"; break; }
done

if [[ -z "$url" ]]; then
  if [[ -z "$ip" ]]; then
    [[ -n "$tailscale_bin" ]] || { echo "error: Tailscale CLI not found; pass --ip or --url." >&2; exit 1; }
    ip="$("$tailscale_bin" ip -4 2>/dev/null | head -1)"
    [[ -n "$ip" ]] || { echo "error: couldn't detect a Tailscale IPv4 (is Tailscale up?). Pass --ip or --url." >&2; exit 1; }
  fi
  url="http://${ip}:${port}"
fi
echo "Server URL: $url"

# --- 2. Write cc-sync.json (to the gitignored repo root; never committed) -------------
cfg="$repo_root/cc-sync.json"
if [[ -n "$token" ]]; then
  printf '{ "url": "%s", "token": "%s" }\n' "$url" "$token" > "$cfg"
else
  printf '{ "url": "%s" }\n' "$url" > "$cfg"
fi
echo "Wrote $cfg"

# --- 3. Locate the device (identifier, used by devicectl copy) ------------------------
if [[ -z "$device" ]]; then
  tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 || true
  device="$(python3 - "$tmp" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    if dev.get("connectionProperties", {}).get("tunnelState") in ("connected", "connecting"):
        print(dev.get("identifier", ""))
        break
PY
)"
  rm -f "$tmp"
fi

# --- 4. Push the config into the app container ----------------------------------------
if [[ -n "$device" ]]; then
  echo "Pushing cc-sync.json to device $device …"
  xcrun devicectl device copy to --device "$device" --timeout 120 \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --source "$cfg" --destination "Documents/cc-sync.json" >/dev/null
  echo "Pushed. The app will pull/push saves on next launch."
else
  echo "note: no connected device found — cc-sync.json written but not pushed." >&2
  echo "      Connect+unlock the iPhone and re-run, or copy it via Finder → Files → cc-ios." >&2
fi

# --- 5. Optionally run / install the server -------------------------------------------
if [[ "$do_service" -eq 1 ]]; then
  CC_SYNC_TOKEN="$token" "$repo_root/servers/macos/save-server.sh" install --port "$port"
elif [[ "$do_serve" -eq 1 ]]; then
  echo "Starting save-server (Ctrl-C to stop)…"
  exec env ${token:+CC_SYNC_TOKEN="$token"} python3 "$repo_root/servers/save-server.py" --port "$port"
else
  echo
  echo "Next: start the save-server so the Mac is reachable:"
  echo "  servers/save-server.py --port $port            # foreground"
  echo "  tools/setup-sync.sh --install-service          # persistent (launchd)"
fi
