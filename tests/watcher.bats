#!/usr/bin/env bats
#
# Pass 9: the session watcher. Two units, both runnable without a Docker daemon:
#   - scripts/lib-watcher.sh : watcher.conf parse / fallback / set-mode
#   - docker/supervise-claude.sh : exit-code policy + restart loop, driven by a
#     stub `claude` (scriptable exit code + call counter) and a no-op `sleep`.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export SCRIPT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$SCRIPT_ROOT/scripts"
  export WATCHER_CONF="$SCRIPT_ROOT/scripts/watcher.conf"

  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls"
  ARGV="$BATS_TEST_TMPDIR/argv"
  export STUBS CALLS ARGV
  mkdir -p "$STUBS"

  printf '#!/bin/sh\nexit 0\n' > "$STUBS/sleep"
  chmod +x "$STUBS/sleep"

  cat > "$STUBS/claude" <<'STUB'
#!/bin/sh
n=0; [ -f "$CALLS" ] && n=$(cat "$CALLS"); n=$((n + 1)); echo "$n" > "$CALLS"
echo "$*" >> "$ARGV"
exit "${CLAUDE_RC:-0}"
STUB
  chmod +x "$STUBS/claude"

  PATH="$STUBS:$PATH"
  export PATH
}

_calls() { local n=0; [ -f "$CALLS" ] && n=$(cat "$CALLS"); printf '%s' "$n"; }

# --- lib-watcher.sh ---

@test "watcher_conf_ensure writes MODE=disabled by default" {
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_conf_ensure; cat "$WATCHER_CONF"'
  [ "$status" -eq 0 ]
  [ "$output" = "MODE=disabled" ]
}

@test "watcher_mode reads enabled and disabled" {
  printf 'MODE=enabled\n' > "$WATCHER_CONF"
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_mode'
  [ "$output" = "enabled" ]
  printf 'MODE=disabled\n' > "$WATCHER_CONF"
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_mode'
  [ "$output" = "disabled" ]
}

@test "an invalid conf falls back to disabled with a warning" {
  printf 'MODE=sometimes\n' > "$WATCHER_CONF"
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_mode 2>/dev/null'
  [ "$output" = "disabled" ] || { echo "got: $output"; return 1; }
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_mode 2>&1 1>/dev/null'
  [[ "$output" == *"falling back to Disabled"* ]]
}

@test "watcher_set_mode toggles the stored mode" {
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_set_mode enabled; watcher_mode'
  [ "$output" = "enabled" ]
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_set_mode disabled; watcher_mode'
  [ "$output" = "disabled" ]
}

@test "watcher_set_mode rejects an invalid mode" {
  run bash -c '. "$REPO_ROOT/scripts/lib-watcher.sh"; watcher_set_mode bogus'
  [ "$status" -ne 0 ]
}

# --- supervise-claude.sh ---

@test "clean exit 0 does not resume" {
  CLAUDE_RC=0 run bash "$REPO_ROOT/docker/supervise-claude.sh" --model x
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
}

@test "exit 130 (Ctrl-C) and 143 (SIGTERM) do not resume" {
  CLAUDE_RC=130 run bash "$REPO_ROOT/docker/supervise-claude.sh"
  [ "$status" -eq 130 ]
  [ "$(_calls)" -eq 1 ]

  : > "$CALLS"
  CLAUDE_RC=143 run bash "$REPO_ROOT/docker/supervise-claude.sh"
  [ "$status" -eq 143 ]
  [ "$(_calls)" -eq 1 ]
}

@test "an abnormal exit restarts up to 3 times then stops with the last code" {
  CLAUDE_RC=1 run bash "$REPO_ROOT/docker/supervise-claude.sh" --model x
  [ "$status" -eq 1 ]
  [ "$(_calls)" -eq 4 ]
  [[ "$output" == *"resuming (attempt 1/3)"* ]]
  [[ "$output" == *"resuming (attempt 3/3)"* ]]
  [[ "$output" == *"restart limit reached"* ]]
}

@test "restarts resume with --continue plus the original args" {
  CLAUDE_RC=1 run bash "$REPO_ROOT/docker/supervise-claude.sh" --model x
  run cat "$ARGV"
  [ "$(sed -n '1p' "$ARGV")" = "--model x" ]
  [ "$(sed -n '2p' "$ARGV")" = "--continue --model x" ]
}
