#!/usr/bin/env bash
#
# github-bridge.sh — install the cc.save GitHub-hub bridge as a macOS launchd agent that runs at
# login and stays out of your way. It keeps THIS Mac's CrossCode (Steam) save in sync with the
# private GitHub hub (cc-mods/cc-saves) so phone progress reaches Steam Cloud and vice-versa.
#
# Mirrors servers/macos/save-server.sh: `install` copies servers/github-steam-bridge.py into
# ~/.cc-tailsync and runs that copy (a worktree copy under ~/Documents/Desktop/Downloads would hit
# macOS TCC "Operation not permitted" from launchd). Re-run `install` after editing the bridge.
#
# Usage:
#   servers/macos/github-bridge.sh install            # push-on-change (safe) + a periodic check
#   servers/macos/github-bridge.sh install --pull-interval 0   # push-on-change ONLY (no auto-pull)
#   servers/macos/github-bridge.sh uninstall
#   servers/macos/github-bridge.sh status
#   servers/macos/github-bridge.sh run                # one-shot, in the foreground (manual sync)
#
# Config: needs ~/.cc-tailsync/cc-github.json ({ "repo","path","token" } — a fine-grained PAT with
# Contents:R/W on the one repo). Created by the cc-ios wiring; this script does NOT take a token on
# the command line (so it never lands in shell history / the plist).
#
# SAFETY DESIGN — two directions, different risk:
#   • PUSH (Steam save -> hub): always safe. We trigger it whenever the Steam cc.save CHANGES
#     (launchd WatchPaths), i.e. after you play on this Mac and the game writes a save.
#   • PULL (hub -> Steam save): writing the Steam path while Steam thinks its cloud copy is newer can
#     make Steam silently overwrite it on next launch. So auto-pull is a *periodic, conflict-safe
#     check* (the bridge does nothing on a genuine divergence) and is **gated to when CrossCode is
#     NOT running**. Set --pull-interval 0 to disable auto-pull entirely and only ever pull by hand
#     (`run`). The bridge never auto-clobbers; a real conflict always waits for you.
set -euo pipefail

label="com.cc-tailsync.github-bridge"
plist="$HOME/Library/LaunchAgents/${label}.plist"
install_dir="$HOME/.cc-tailsync"
installed_py="$install_dir/github-steam-bridge.py"
installed_sh="$install_dir/github-bridge-run.sh"
log_out="$install_dir/github-bridge.out.log"
log_err="$install_dir/github-bridge.err.log"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bridge_py="$script_dir/../github-steam-bridge.py"

python_bin="$(command -v python3 || true)"
[[ -n "$python_bin" ]] || { echo "error: python3 not found in PATH." >&2; exit 1; }

steam_save="$HOME/Library/Application Support/CrossCode/Default/cc.save"
pull_interval=300   # seconds between conflict-safe pull checks (0 = push-on-change only)

cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-interval) pull_interval="$2"; shift 2;;
    --save)          steam_save="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# A small wrapper the agent actually runs: always push if the save moved; pull only when the pull
# interval has elapsed AND CrossCode isn't running (so we never fight a live game / Steam sync).
write_runner() {
  cat > "$installed_sh" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
PY="$python_bin"
BRIDGE="$installed_py"
SAVE="$steam_save"
PULL_INTERVAL=$pull_interval
STAMP="$install_dir/.last-pull"

# PUSH side (safe): mirror local -> hub. The bridge is a no-op when already in sync, and never
# auto-clobbers on divergence.
"\$PY" "\$BRIDGE" --save "\$SAVE" || true

# PULL side (gated): only every PULL_INTERVAL seconds, and only when CrossCode is NOT running.
if [[ "\$PULL_INTERVAL" -gt 0 ]] && ! pgrep -x "CrossCode" >/dev/null 2>&1 && ! pgrep -x "nwjs" >/dev/null 2>&1; then
  now=\$(date +%s)
  last=0; [[ -f "\$STAMP" ]] && last=\$(cat "\$STAMP" 2>/dev/null || echo 0)
  if [[ \$((now - last)) -ge "\$PULL_INTERVAL" ]]; then
    "\$PY" "\$BRIDGE" --save "\$SAVE" || true   # bridge decides push/pull/in-sync/conflict, safely
    echo "\$now" > "\$STAMP"
  fi
fi
RUNNER
  chmod +x "$installed_sh"
}

install() {
  [[ -f "$bridge_py" ]] || { echo "error: $bridge_py not found." >&2; exit 1; }
  [[ -f "$install_dir/cc-github.json" ]] || {
    echo "error: $install_dir/cc-github.json missing (needs { repo, path, token })." >&2; exit 1; }
  mkdir -p "$install_dir"
  cp "$bridge_py" "$installed_py"
  write_runner

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${installed_sh}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>WatchPaths</key>
  <array>
    <string>${steam_save}</string>
  </array>
  <key>StartInterval</key>
  <integer>${pull_interval:-300}</integer>
  <key>StandardOutPath</key>
  <string>${log_out}</string>
  <key>StandardErrorPath</key>
  <string>${log_err}</string>
</dict>
</plist>
PLIST

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  echo "Installed and loaded $label."
  echo "  bridge: $installed_py  (copied from $bridge_py)"
  echo "  runner: $installed_sh"
  echo "  plist:  $plist"
  echo "  push:   on every change to $steam_save"
  echo "  pull:   every ${pull_interval}s, only when CrossCode is closed (0 = disabled)"
  echo "  logs:   $log_out / $log_err"
}

uninstall() {
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist" "$installed_sh"
  echo "Uninstalled $label. (left $installed_py + config in $install_dir)"
}

status() {
  # The job is run-to-completion (fires on save-change + on the interval), so it normally has no PID
  # between runs — `launchctl list <label>` still shows it with its LastExitStatus when registered.
  if launchctl list "$label" >/dev/null 2>&1; then
    echo "registered (runs at login, on save change, and every ${pull_interval}s):"
    launchctl list "$label" 2>/dev/null | grep -E '"Label"|LastExitStatus' | sed 's/^/  /'
    echo "  last sync log:"; tail -4 "$log_out" 2>/dev/null | sed 's/^/    /'
  else
    echo "not installed."
  fi
}

case "$cmd" in
  install)   install ;;
  uninstall) uninstall ;;
  status)    status ;;
  run)       exec "$python_bin" "$bridge_py" --save "$steam_save" ;;
  *) echo "usage: $0 {install [--pull-interval N] [--save PATH] | uninstall | status | run}" >&2; exit 2;;
esac
