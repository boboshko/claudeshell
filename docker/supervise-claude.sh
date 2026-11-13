#!/bin/bash
set -u

WATCHER_WINDOW=600
WATCHER_MAX=3

args=("$@")
window_start=0
restarts=0

while true; do
  claude "${args[@]}"
  rc=$?

  case "$rc" in
    0|130|143) exit "$rc" ;;
  esac

  now="$(date +%s)"
  if [ "$restarts" -eq 0 ] || [ "$((now - window_start))" -ge "$WATCHER_WINDOW" ]; then
    window_start="$now"
    restarts=0
  fi
  restarts="$((restarts + 1))"

  if [ "$restarts" -gt "$WATCHER_MAX" ]; then
    echo "[watcher] Claude Code exited abnormally (code $rc); restart limit reached (${WATCHER_MAX} within ${WATCHER_WINDOW}s) — stopping." >&2
    exit "$rc"
  fi

  echo "[watcher] Claude Code exited abnormally (code $rc) — resuming (attempt ${restarts}/${WATCHER_MAX})..." >&2
  sleep "$((restarts * 2))"
  args=(--continue "$@")
done
