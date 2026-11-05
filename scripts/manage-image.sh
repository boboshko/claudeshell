#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"

BUILD_LOG="$SCRIPT_ROOT/docker/.build-log"
BUILD_STATUS="$SCRIPT_ROOT/docker/.build-status"
BUILD_LOCK="$SCRIPT_ROOT/docker/.build.lock"
HASH_FILE="$SCRIPT_ROOT/docker/.build-hash"

_img_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

_img_compute_build_hash() {
  local forced_version="${1:-}"
  local claude_code_version=""
  [ -f "$SCRIPT_ROOT/docker/.env" ] && claude_code_version="$(grep -m1 '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" | cut -d= -f2-)"
  [ -n "$forced_version" ] && claude_code_version="$forced_version"

  { cat \
    "$SCRIPT_ROOT/docker/Dockerfile" \
    "$SCRIPT_ROOT/docker/entrypoint.sh" \
    "$SCRIPT_ROOT/docker/init-firewall.sh" \
    2>/dev/null
    grep -Ev '^TOOL_(XCODE|DOCKER_SOCKET)=' "$SCRIPT_ROOT/scripts/tools.conf" 2>/dev/null || true
    echo "CLAUDE_CODE_VERSION=${claude_code_version:-latest}"
  } | _img_sha256
}

image_exists() {
  docker image inspect claude-shell:latest >/dev/null 2>&1
}

previous_exists() {
  docker image inspect claude-shell:previous >/dev/null 2>&1
}

_img_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

_img_write_status() {
  {
    echo "ACTION=$1"
    echo "STARTED_AT=$2"
    echo "FINISHED_AT=$3"
    echo "RESULT=$4"
  } > "$BUILD_STATUS"
}

_img_lock_is_stale() {
  local pid
  pid="$(sed -n '1p' "$BUILD_LOCK" 2>/dev/null)"
  if [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

_img_status_get() {
  local key="$1"
  [ -f "$BUILD_STATUS" ] || return 1
  grep -m1 "^${key}=" "$BUILD_STATUS" | cut -d= -f2-
}

_img_tools_summary() {
  if [ -f "$SCRIPT_ROOT/scripts/tools.conf" ]; then
    local on
    on="$(grep '=on$' "$SCRIPT_ROOT/scripts/tools.conf" 2>/dev/null | cut -d= -f1 | sed 's/^TOOL_//' | tr '\n' ' ')"
    [ -n "$on" ] && printf '%s\n' "$on" || printf '%s\n' "(none selected)"
  else
    printf '%s\n' "(none selected)"
  fi
}

_img_run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return $?
  fi

  "$@" &
  local cmd_pid=$!
  (
    sleep "$seconds"
    kill -0 "$cmd_pid" 2>/dev/null && kill "$cmd_pid" 2>/dev/null
  ) &
  local watchdog_pid=$!

  local rc=0
  wait "$cmd_pid" || rc=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  return "$rc"
}

_img_run_pipeline() {
  local action="$1" pull="$2" force_latest="$3"
  local started finished confirm

  echo
  echo "Tools currently selected: $(_img_tools_summary)"
  if [ -f "$SCRIPT_ROOT/scripts/firewall.conf" ]; then
    echo "Firewall mode (informational — not applied at build time): $(grep -m1 '^MODE=' "$SCRIPT_ROOT/scripts/firewall.conf" 2>/dev/null | cut -d= -f2-)"
  fi
  echo

  if [ -f "$BUILD_LOCK" ]; then
    if _img_lock_is_stale; then
      echo "A stale docker/.build.lock was found (the process that created it is no longer running) — clearing it."
      rm -f "$BUILD_LOCK"
    else
      echo "A build/update is already in progress — see Build Status."
      press_enter_to_continue
      return
    fi
  fi

  if [ "$force_latest" = "1" ] && [ -f "$SCRIPT_ROOT/docker/.env" ] && grep -q '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" 2>/dev/null; then
    local pinned
    pinned="$(grep -m1 '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" | cut -d= -f2-)"
    read -rep "A pinned Claude Code version (${pinned}) was found in docker/.env — update to latest anyway? [y/N] " confirm
  else
    read -rep "Proceed with this image rebuild? [y/N] " confirm
  fi

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    press_enter_to_continue
    return
  fi

  started="$(_img_now)"
  printf '%s\n%s\n' "$$" "$started" > "$BUILD_LOCK"
  _img_write_status "$action" "$started" "" "in-progress"
  trap 'rm -f "$BUILD_LOCK"' INT TERM

  if image_exists; then
    docker tag claude-shell:latest claude-shell:previous > "$BUILD_LOG" 2>&1 || true
  else
    : > "$BUILD_LOG"
  fi

  {
    echo "=== ClaudeShell image '$action' started at $started ==="
  } >> "$BUILD_LOG"

  local build_rc=0
  if [ "$pull" = "1" ]; then
    IMAGE_BUILD_PULL=1 CLAUDE_CODE_VERSION=latest bash "$SCRIPT_ROOT/scripts/build-image.sh" >> "$BUILD_LOG" 2>&1 || build_rc=$?
  else
    bash "$SCRIPT_ROOT/scripts/build-image.sh" >> "$BUILD_LOG" 2>&1 || build_rc=$?
  fi

  if [ "$build_rc" -ne 0 ]; then
    echo "Build failed (exit $build_rc). See docker/.build-log for details." | tee -a "$BUILD_LOG"
    finished="$(_img_now)"
    _img_write_status "$action" "$started" "$finished" "failed"
    trap - INT TERM
    rm -f "$BUILD_LOCK"
    press_enter_to_continue
    return
  fi

  echo "Build succeeded. Running smoke test: docker run --rm claude-shell:latest claude --version"
  local smoke_out smoke_file smoke_rc
  smoke_file="$(mktemp)"
  _img_run_with_timeout 30 docker run --rm claude-shell:latest claude --version > "$smoke_file" 2>&1
  smoke_rc=$?
  smoke_out="$(cat "$smoke_file")"
  rm -f "$smoke_file"

  {
    echo "--- smoke test: docker run --rm claude-shell:latest claude --version ---"
    echo "$smoke_out"
    echo "--- smoke test exit code: $smoke_rc ---"
  } >> "$BUILD_LOG"

  if [ "$smoke_rc" -ne 0 ] || [ -z "$smoke_out" ]; then
    echo "Smoke test failed (exit $smoke_rc, output: '${smoke_out:-<empty>}')." | tee -a "$BUILD_LOG"
    if previous_exists; then
      docker tag claude-shell:previous claude-shell:latest >> "$BUILD_LOG" 2>&1 || true
      echo "claude-shell:latest has been rolled back to the previous working image." | tee -a "$BUILD_LOG"
    else
      echo "WARNING: no claude-shell:previous image exists to roll back to." | tee -a "$BUILD_LOG"
    fi
    finished="$(_img_now)"
    _img_write_status "$action" "$started" "$finished" "failed"
    trap - INT TERM
    rm -f "$BUILD_LOCK"
    press_enter_to_continue
    return
  fi

  echo "Smoke test passed: $smoke_out" | tee -a "$BUILD_LOG"

  local new_hash
  if [ "$force_latest" = "1" ]; then
    new_hash="$(_img_compute_build_hash latest)"
  else
    new_hash="$(_img_compute_build_hash)"
  fi
  echo "$new_hash" > "$HASH_FILE"

  finished="$(_img_now)"
  _img_write_status "$action" "$started" "$finished" "success"
  trap - INT TERM
  rm -f "$BUILD_LOCK"
  echo "Image '$action' completed successfully."
  press_enter_to_continue
}

_img_show_info() {
  clear
  echo "Image Information"
  echo

  local cs_version
  cs_version="$(cat "$SCRIPT_ROOT/VERSION" 2>/dev/null || echo "unknown")"
  echo "ClaudeShell version: $cs_version"

  if image_exists; then
    local cc_version
    cc_version="$(docker run --rm claude-shell:latest claude --version 2>/dev/null || echo "unavailable")"
    echo "Installed Claude Code version: $cc_version"
  else
    echo "Installed Claude Code version: (image missing)"
  fi

  local from_line pinned
  from_line="$(grep -m1 '^FROM' "$SCRIPT_ROOT/docker/Dockerfile" 2>/dev/null | awk '{print $2}')"
  pinned=""
  [ -f "$SCRIPT_ROOT/docker/.env" ] && pinned="$(grep -m1 '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" 2>/dev/null | cut -d= -f2-)"
  [ -z "$pinned" ] && pinned="latest"
  echo "Base image: ${from_line:-unknown}"
  echo "Claude Code version configured: $pinned"

  local last_result last_finished
  last_result="$(_img_status_get RESULT 2>/dev/null || true)"
  last_finished="$(_img_status_get FINISHED_AT 2>/dev/null || true)"
  if [ "$last_result" = "success" ] && [ -n "$last_finished" ]; then
    echo "Last successful build: $last_finished"
  else
    echo "Last successful build: (none recorded)"
  fi

  if ! image_exists; then
    echo "Image status: missing"
  else
    local stored_hash current_hash
    stored_hash=""
    [ -f "$HASH_FILE" ] && stored_hash="$(cat "$HASH_FILE")"
    current_hash="$(_img_compute_build_hash)"
    if [ "$stored_hash" = "$current_hash" ]; then
      echo "Image status: up to date"
    else
      echo "Image status: stale — rebuild recommended"
    fi
  fi

  local size
  size="$(docker images claude-shell:latest --format '{{.Size}}' 2>/dev/null)"
  echo "Image size: ${size:-unknown}"

  press_enter_to_continue
}

_img_show_build_status() {
  clear
  echo "Build Status"
  echo

  if [ -f "$BUILD_LOCK" ]; then
    echo "A build/update is currently in progress."
    echo
    echo "--- live log tail (press any key to stop watching) ---"
    tail -n 50 -f "$BUILD_LOG" 2>/dev/null &
    local tail_pid=$!
    read -rsn1 -p ""
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
    echo
    return
  fi

  if [ -f "$BUILD_STATUS" ]; then
    echo "Last recorded build/update:"
    cat "$BUILD_STATUS"
  else
    echo "No build/update has been recorded yet."
  fi

  echo
  echo "--- last 50 lines of docker/.build-log ---"
  if [ -f "$BUILD_LOG" ]; then
    tail -n 50 "$BUILD_LOG"
  else
    echo "(no log yet)"
  fi

  if [ -f "$BUILD_STATUS" ] && grep -q '^RESULT=failed$' "$BUILD_STATUS" 2>/dev/null; then
    echo
    echo "*** The last build/update FAILED — see the log above. ***"
  fi

  press_enter_to_continue
}

while true; do
  clear
  options=("Rebuild Local Image" "Update Claude Code Image" "Image Information" "Build Status" "← Back")
  menu_select "Image" "${options[@]}"
  choice=$?

  case "$choice" in
    0) _img_run_pipeline "rebuild" 0 0 ;;
    1) _img_run_pipeline "update" 1 1 ;;
    2) _img_show_info ;;
    3) _img_show_build_status ;;
    4|255) break ;;
  esac
done
