#!/usr/bin/env bash
# Manage the cc-tailsync save-server as a persistent macOS launchd service, so wireless
# (Tailscale) save sync keeps working across logins/reboots without a terminal open.
#
# Wraps servers/save-server.py. The service mirrors the desktop CrossCode save and serves it on
# 0.0.0.0:<port>, reachable over your tailnet.
#
# Usage:
#   servers/macos/save-server.sh install [--port N] [--save PATH]   # install + load (starts now)
#   servers/macos/save-server.sh uninstall                          # stop + remove
#   servers/macos/save-server.sh status                             # is it loaded/running?
#   servers/macos/save-server.sh logs                               # tail the service log
#
# Auth: set CC_SYNC_TOKEN in the environment when installing to require a bearer token.
#
# Note: `install` copies save-server.py into ~/.cc-tailsync and runs that copy — both so the
# service is independent of the repo path and to avoid macOS TCC denying launchd access to files
# under ~/Documents / ~/Desktop / ~/Downloads. Re-run `install` after editing the script.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="com.cc-mods.tailsync-server"
plist="$HOME/Library/LaunchAgents/${label}.plist"
log_dir="$HOME/.cc-tailsync"
log_out="$log_dir/save-server.out.log"
log_err="$log_dir/save-server.err.log"

port=8765
save_path=""
cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="$2"; shift 2;;
    --save) save_path="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

python_bin="$(command -v python3 || echo /usr/bin/python3)"
server_py="$repo_root/servers/save-server.py"
token="${CC_SYNC_TOKEN:-}"

install() {
  [[ -f "$server_py" ]] || { echo "error: $server_py not found" >&2; exit 1; }
  mkdir -p "$log_dir" "$(dirname "$plist")"

  # launchd agents are subject to macOS TCC and are DENIED read access to files under
  # ~/Documents, ~/Desktop and ~/Downloads. If the repo lives in one of those (common!),
  # launchd can't read save-server.py from the worktree ("Operation not permitted"). So install
  # a copy into ~/.cc-tailsync (a dotfolder, not TCC-protected) and run that.
  local installed_py="$log_dir/save-server.py"
  cp "$server_py" "$installed_py"

  # Build the ProgramArguments + optional --save.
  local args="    <string>${installed_py}</string>
    <string>--port</string>
    <string>${port}</string>"
  if [[ -n "$save_path" ]]; then
    args="${args}
    <string>--save</string>
    <string>${save_path}</string>"
  fi

  # Optional token via EnvironmentVariables.
  local env_block=""
  if [[ -n "$token" ]]; then
    env_block="  <key>EnvironmentVariables</key>
  <dict>
    <key>CC_SYNC_TOKEN</key>
    <string>${token}</string>
  </dict>"
  fi

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${python_bin}</string>
${args}
  </array>
${env_block}
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_out}</string>
  <key>StandardErrorPath</key>
  <string>${log_err}</string>
</dict>
</plist>
PLIST

  # Reload cleanly if already installed, then wait for the old process to release the port so the
  # fresh instance doesn't fail to bind (Address already in use).
  launchctl unload "$plist" 2>/dev/null || true
  local i=0
  while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && [[ "$i" -lt 20 ]]; do
    sleep 0.25; i=$((i+1))
  done
  launchctl load "$plist"
  echo "Installed and loaded $label (port $port)."
  echo "  script: $installed_py  (copied from $server_py)"
  echo "  plist:  $plist"
  echo "  logs:   $log_out / $log_err"
}

uninstall() {
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist" "$log_dir/save-server.py"
  echo "Uninstalled $label."
  echo "  (logs kept in $log_dir; remove them with: rm -rf $log_dir)"
}

status() {
  if launchctl list 2>/dev/null | grep -q "$label"; then
    echo "loaded:"
    launchctl list | grep "$label"
  else
    echo "not loaded."
  fi
}

case "$cmd" in
  install)   install;;
  uninstall) uninstall;;
  status)    status;;
  logs)      tail -n 40 -f "$log_out" "$log_err" 2>/dev/null;;
  *) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 2;;
esac
