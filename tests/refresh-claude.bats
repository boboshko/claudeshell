#!/usr/bin/env bats
#
# Pass 8 (Open #9): scripts/refresh-claude.sh forces a --pull rebuild and only
# records the build-hash on success; scripts/build-image.sh adds --pull iff
# BUILD_PULL=1. No Docker daemon: a recording `docker` stub captures the
# `compose ... build` argv and returns a scriptable exit code; the real
# build-image.sh / refresh-claude.sh / lib-*.sh run against a sandbox SCRIPT_ROOT.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ROOT="$BATS_TEST_TMPDIR/root"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  ARGV="$BATS_TEST_TMPDIR/compose-argv"
  mkdir -p "$STUBS" "$ROOT/scripts" "$ROOT/docker"
  export REPO_ROOT ROOT STUBS ARGV

  cp "$REPO_ROOT/scripts/build-image.sh" \
     "$REPO_ROOT/scripts/refresh-claude.sh" \
     "$REPO_ROOT/scripts/lib-tools.sh" \
     "$REPO_ROOT/scripts/lib-build.sh" \
     "$ROOT/scripts/"
  printf 'v9.9.9\n' > "$ROOT/VERSION"
  printf 'FROM node:20-slim\n' > "$ROOT/docker/Dockerfile"
  printf '#!/bin/sh\n' > "$ROOT/docker/entrypoint.sh"
  printf '#!/bin/sh\n' > "$ROOT/docker/init-firewall.sh"

  printf '#!/bin/sh\nexit 0\n' > "$STUBS/sleep"
  chmod +x "$STUBS/sleep"

  cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "image inspect") exit 0 ;;
  "pull "*)        exit 0 ;;
  "compose "*)
    shift
    for a in "$@"; do
      if [ "$a" = "build" ]; then printf 'build-seen\n' >> "$ARGV"; fi
      if [ "$a" = "--pull" ]; then printf 'pull-seen\n' >> "$ARGV"; fi
    done
    exit "${COMPOSE_BUILD_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBS/docker"

  PATH="$STUBS:$PATH"
  export PATH
}

_run_refresh() {
  run env SCRIPT_ROOT="$ROOT" PATH="$PATH" bash "$ROOT/scripts/refresh-claude.sh"
}

_run_build_image() {
  run env SCRIPT_ROOT="$ROOT" PATH="$PATH" "$@" bash "$ROOT/scripts/build-image.sh"
}

@test "build-image.sh adds --pull only when BUILD_PULL=1" {
  _run_build_image
  [ "$status" -eq 0 ]
  grep -q 'build-seen' "$ARGV"
  ! grep -q 'pull-seen' "$ARGV"

  : > "$ARGV"
  _run_build_image BUILD_PULL=1
  [ "$status" -eq 0 ]
  grep -q 'build-seen' "$ARGV"
  grep -q 'pull-seen' "$ARGV"
}

@test "refresh drives a --pull build and records a non-empty build-hash on success" {
  printf 'stale\n' > "$ROOT/docker/.build-hash"
  _run_refresh
  [ "$status" -eq 0 ]
  grep -q 'pull-seen' "$ARGV"
  [ -s "$ROOT/docker/.build-hash" ]
  [ "$(cat "$ROOT/docker/.build-hash")" != "stale" ]
}

@test "refresh recomputes the SAME hash run-claude.sh would, so no needless rebuild follows" {
  _run_refresh
  [ "$status" -eq 0 ]
  expected="$(env SCRIPT_ROOT="$ROOT" bash -c '. "$ROOT/scripts/lib-build.sh"; build_compute_hash')"
  [ "$(cat "$ROOT/docker/.build-hash")" = "$expected" ]
}

@test "a failed build aborts refresh under set -e and records NO hash" {
  rm -f "$ROOT/docker/.build-hash"
  COMPOSE_BUILD_RC=1 _run_refresh
  [ "$status" -ne 0 ]
  [ ! -e "$ROOT/docker/.build-hash" ]
}
