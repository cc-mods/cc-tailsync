#!/usr/bin/env bash
# Two-way CrossCode save sync between this Mac (Steam copy) and a USB-connected iPhone running
# cc-ios, using `xcrun devicectl device copy`. Last-writer-wins by modification time.
#
# Part of cc-tailsync. The cc-ios app keeps its save at Documents/cc.save inside its app container;
# that file is byte-identical to the desktop save the Steam game reads/writes. Steam Cloud then
# distributes the desktop copy across PCs automatically.
#
# Usage:
#   tools/save-sync.sh                 # sync newer → older, both directions
#   tools/save-sync.sh --to-phone      # force desktop → phone
#   tools/save-sync.sh --from-phone    # force phone → desktop
#   tools/save-sync.sh --device <udid> # target a specific device
#   tools/save-sync.sh --bundle-id ID  # cc-ios app bundle id (default com.example.ccios)
set -euo pipefail

bundle_id="${CCIOS_BUNDLE_ID:-com.example.ccios}"
container_path="Documents/cc.save"
desktop_save="$HOME/Library/Application Support/CrossCode/Default/cc.save"
device_udid="${CCIOS_DEVICE_UDID:-}"
mode="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-phone)   mode="to"; shift;;
    --from-phone) mode="from"; shift;;
    --device)     device_udid="$2"; shift 2;;
    --bundle-id)  bundle_id="$2"; shift 2;;
    -h|--help)    grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# --- locate device ---------------------------------------------------------------
if [[ -z "$device_udid" ]]; then
  tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 || true
  device_udid="$(python3 - "$tmp" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get('result',{}).get('devices',[]):
    cp=dev.get('connectionProperties',{})
    if cp.get('tunnelState')=='connected':
        print(dev.get('hardwareProperties',{}).get('udid') or dev.get('identifier',''))
        break
PY
)"
  rm -f "$tmp"
fi
if [[ -z "$device_udid" ]]; then
  echo "error: no connected device found. Plug in the iPhone and unlock it." >&2
  exit 1
fi
echo "Device: $device_udid"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
phone_pulled="$work/phone-cc.save"

# Warm up the device tunnel + developer disk image services. The FIRST devicectl file operation
# after connecting can stall while these initialise; this absorbs that delay so the copies run fast.
xcrun devicectl device info details --device "$device_udid" --timeout 60 >/dev/null 2>&1 || true

epoch() { stat -f %m "$1" 2>/dev/null || echo 0; }

pull_phone() {
  xcrun devicectl device copy from --device "$device_udid" --timeout 120 \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --source "$container_path" --destination "$phone_pulled" >/dev/null 2>&1 || return 1
  [[ -s "$phone_pulled" ]]
}

push_phone() {  # $1 = local file to send
  xcrun devicectl device copy to --device "$device_udid" --timeout 120 \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --source "$1" --destination "$container_path" >/dev/null 2>&1
}

phone_has=0; pull_phone && phone_has=1 || true
desk_has=0; [[ -s "$desktop_save" ]] && desk_has=1 || true

case "$mode" in
  to)
    [[ "$desk_has" == 1 ]] || { echo "no desktop save to push"; exit 1; }
    push_phone "$desktop_save"; echo "Pushed desktop → phone."; exit 0;;
  from)
    [[ "$phone_has" == 1 ]] || { echo "no phone save to pull"; exit 1; }
    cp "$phone_pulled" "$desktop_save"; echo "Pulled phone → desktop."; exit 0;;
esac

# --- auto: last-writer-wins -------------------------------------------------------
if [[ "$phone_has" == 0 && "$desk_has" == 0 ]]; then
  echo "No save on either side; nothing to do."; exit 0
elif [[ "$phone_has" == 0 ]]; then
  push_phone "$desktop_save"; echo "Phone had no save → pushed desktop → phone."
elif [[ "$desk_has" == 0 ]]; then
  mkdir -p "$(dirname "$desktop_save")"; cp "$phone_pulled" "$desktop_save"
  echo "Desktop had no save → pulled phone → desktop."
else
  if cmp -s "$phone_pulled" "$desktop_save"; then
    echo "Saves already identical; nothing to do."
  elif [[ "$(epoch "$desktop_save")" -ge "$(epoch "$phone_pulled")" ]]; then
    push_phone "$desktop_save"; echo "Desktop newer → pushed desktop → phone."
  else
    cp "$phone_pulled" "$desktop_save"; echo "Phone newer → pulled phone → desktop."
  fi
fi

echo "Done. (Launch CrossCode on Steam to upload the desktop save to Steam Cloud.)"
