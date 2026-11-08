#!/usr/bin/env bash

: "${XCODE_BRIDGE_PIDFILE:=${SCRIPT_ROOT:+$SCRIPT_ROOT/scripts/platform/macos/.bridge.pid}}"
: "${XCODE_BRIDGE_PIDFILE:=/tmp/claude-shell-xcode-bridge.pid}"
: "${XCODE_BRIDGE_HELPER:=${SCRIPT_ROOT:+$SCRIPT_ROOT/scripts/platform/macos/xcode-bridge-helper.py}}"
: "${XCODE_BRIDGE_LOG:=$HOME/.claude-shell/xcode-bridge.log}"
: "${XCODE_BRIDGE_PORT:=47870}"

xcode_bridge_detect() {
  if ! command -v xcode-select >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are not installed on this host."
    return 1
  fi

  local clt_path
  if ! clt_path="$(xcode-select -p 2>/dev/null)"; then
    echo "Xcode Command Line Tools are not installed on this host."
    return 1
  fi

  local version
  if ! version="$(xcodebuild -version 2>/dev/null | head -n1)"; then
    echo "Xcode Command Line Tools are installed ($clt_path) but 'xcodebuild -version' failed."
    return 1
  fi

  echo "$version ($clt_path)"
  return 0
}

_xcode_bridge_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

xcode_bridge_recorded_pid() {
  [ -f "$XCODE_BRIDGE_PIDFILE" ] || return 1
  sed -n '1p' "$XCODE_BRIDGE_PIDFILE"
}

xcode_bridge_recorded_port() {
  if [ -f "$XCODE_BRIDGE_PIDFILE" ]; then
    sed -n '2p' "$XCODE_BRIDGE_PIDFILE"
  fi
}

xcode_bridge_is_running() {
  local pid
  pid="$(xcode_bridge_recorded_pid 2>/dev/null || true)"
  _xcode_bridge_pid_alive "$pid"
}

xcode_bridge_start() {
  local port="${1:-$XCODE_BRIDGE_PORT}"

  if xcode_bridge_is_running; then
    echo "Xcode bridge already running (pid $(xcode_bridge_recorded_pid), port $(xcode_bridge_recorded_port))."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is not available on this host — cannot start the Xcode bridge helper." >&2
    return 1
  fi

  if ! xcode_bridge_detect >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are not installed on this host — the bridge would be a no-op." >&2
    return 1
  fi

  mkdir -p "$(dirname "$XCODE_BRIDGE_LOG")" 2>/dev/null || true
  mkdir -p "$(dirname "$XCODE_BRIDGE_PIDFILE")" 2>/dev/null || true

  nohup python3 "$XCODE_BRIDGE_HELPER" --port "$port" >>"$XCODE_BRIDGE_LOG" 2>&1 &
  disown

  local pid=$!
  printf '%s\n%s\n' "$pid" "$port" > "$XCODE_BRIDGE_PIDFILE"
  echo "Xcode bridge started (pid $pid, port $port). Log: $XCODE_BRIDGE_LOG"
}

xcode_bridge_stop() {
  local pid
  pid="$(xcode_bridge_recorded_pid 2>/dev/null || true)"
  if [ -n "$pid" ] && _xcode_bridge_pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$XCODE_BRIDGE_PIDFILE"
}

xcode_bridge_install_login_item() {
  local plist="$HOME/Library/LaunchAgents/com.claudeshell.xcode-bridge.plist"
  local python_bin
  python_bin="$(command -v python3)"

  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claudeshell.xcode-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$python_bin</string>
    <string>$XCODE_BRIDGE_HELPER</string>
    <string>--port</string>
    <string>$XCODE_BRIDGE_PORT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$XCODE_BRIDGE_LOG</string>
  <key>StandardErrorPath</key>
  <string>$XCODE_BRIDGE_LOG</string>
</dict>
</plist>
EOF

  echo "Login-item written: $plist"
  echo "Run 'launchctl load -w \"$plist\"' to enable auto-start at login."
}

xcode_bridge_uninstall_login_item() {
  local plist="$HOME/Library/LaunchAgents/com.claudeshell.xcode-bridge.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "Login-item removed: $plist"
  fi
}
