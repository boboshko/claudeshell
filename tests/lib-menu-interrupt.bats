#!/usr/bin/env bats

set -m

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SIG_TEST_SCRIPT="$(mktemp)"
  cat > "$SIG_TEST_SCRIPT" <<'EOS'
#!/bin/bash
source "$1/scripts/lib-menu.sh"
MS_STATE=(0 0 0)
MS_SLUGS=(ALPHA BETA GAMMA)
_sig_hook() { : > "$MARKER_FILE"; }
MENU_ON_INTERRUPT="_sig_hook"
menu_multiselect "Test Menu" "##Header" "Alpha|desc a" "Beta|desc b" "Gamma|desc g"
echo "RC=$?"
EOS
  chmod +x "$SIG_TEST_SCRIPT"

  OUT_LOG="$(mktemp)"
  MARKER_FILE="$(mktemp -u)"
  rm -f "$MARKER_FILE"
  FIFO="$(mktemp -u)"
  mkfifo "$FIFO"
  export MARKER_FILE
}

teardown() {
  [ -n "${TARGET_PID:-}" ] && kill -9 "$TARGET_PID" 2>/dev/null
  [ -n "${HOLDER_PID:-}" ] && kill -9 "$HOLDER_PID" 2>/dev/null
  wait 2>/dev/null
  rm -f "$SIG_TEST_SCRIPT" "$OUT_LOG" "$MARKER_FILE" "$FIFO"
}

_poll_until() {
  local cond="$1" timeout="${2:-50}" i
  for ((i = 0; i < timeout; i++)); do
    eval "$cond" && return 0
    sleep 0.1
  done
  return 1
}

_run_signal_scenario() {
  local sig="$1"

  ( exec 3<>"$FIFO"; sleep 30 ) &
  HOLDER_PID=$!

  bash "$SIG_TEST_SCRIPT" "$DIR" < "$FIFO" > "$OUT_LOG" 2>&1 &
  TARGET_PID=$!

  # shellcheck disable=SC2016
  _poll_until '[ -s "$OUT_LOG" ]' 50

  kill -s "$sig" "$TARGET_PID"

  # shellcheck disable=SC2016
  _poll_until '! kill -0 "$TARGET_PID" 2>/dev/null' 50
  local exited=$?

  kill "$HOLDER_PID" 2>/dev/null
  wait "$HOLDER_PID" 2>/dev/null || true
  wait "$TARGET_PID" 2>/dev/null || true

  [ "$exited" -eq 0 ]
  [ -f "$MARKER_FILE" ]
  ! kill -0 "$TARGET_PID" 2>/dev/null
}

@test "menu_multiselect: SIGTERM while blocked on read runs MENU_ON_INTERRUPT and actually terminates the process" {
  _run_signal_scenario TERM
}

@test "menu_multiselect: SIGHUP (dropped-session signal) while blocked on read runs MENU_ON_INTERRUPT and actually terminates the process" {
  _run_signal_scenario HUP
}
