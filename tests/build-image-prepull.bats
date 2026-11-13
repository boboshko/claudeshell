#!/usr/bin/env bats
#
# Pass 4 — base-image FROM resolution resilience. BuildKit resolves the
# Dockerfile's `FROM` ("load metadata for ...") over the network BEFORE any RUN
# step, so the in-Dockerfile retry helpers (apt-retry/fetch-retry/run-retry)
# cannot cover a slow/unreachable registry: the build fails at line 1 with
# "context deadline exceeded". scripts/build-image.sh now pre-pulls the base
# image on the host, with retries, so the FROM then resolves from the local
# image store. These tests exercise that prepull_base_image function.
#
# No Docker daemon: the function under test is EXTRACTED from the real
# scripts/build-image.sh text (never a copy that can drift) and run with a
# scriptable stub `docker` plus a no-op `sleep` on a PATH where the stubs win
# the lookup, so nothing here reaches a daemon or the network.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BUILD_IMAGE_SH="$REPO_ROOT/scripts/build-image.sh"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  WORK="$BATS_TEST_TMPDIR/work"
  PULLCOUNT="$BATS_TEST_TMPDIR/pullcount"
  FUNC="$BATS_TEST_TMPDIR/func.sh"
  mkdir -p "$STUBS" "$WORK/docker"
  export STUBS WORK PULLCOUNT REPO_ROOT

  # Stubs win the PATH lookup for docker/sleep; awk and the shell come from the
  # system dirs that follow.
  PATH="$STUBS:$PATH"
  export PATH

  # The function under test, lifted verbatim from the real build script.
  awk '/^prepull_base_image\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "$BUILD_IMAGE_SH" > "$FUNC"
  # Guard: extraction actually captured a complete function.
  grep -q '^prepull_base_image() {' "$FUNC"
  grep -q '^}' "$FUNC"

  # No-op sleep so the 5+10+15+20s back-off never delays the suite.
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/sleep"
  chmod +x "$STUBS/sleep"

  # Scriptable docker stub, controlled by env read at call time:
  #   DOCKER_INSPECT_RC  : exit code of `docker image inspect` (0=present)
  #   DOCKER_PULL_FAILS  : N leading `docker pull` failures before success,
  #                        or "never" to always fail.
  # Every `docker pull` bumps the counter file so tests can assert attempts.
  cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
state="$PULLCOUNT"
case "$1 $2" in
  "image inspect")
    exit "${DOCKER_INSPECT_RC:-1}" ;;
  "pull "*)
    n=0; [ -f "$state" ] && n=$(cat "$state"); n=$((n + 1)); echo "$n" > "$state"
    if [ "${DOCKER_PULL_FAILS:-0}" = "never" ]; then echo "pull failed" >&2; exit 1; fi
    if [ "$n" -le "${DOCKER_PULL_FAILS:-0}" ]; then echo "pull transient fail" >&2; exit 1; fi
    echo "pull ok"; exit 0 ;;
  *)
    exit 0 ;;
esac
STUB
  chmod +x "$STUBS/docker"
}

# Write a Dockerfile into the sandbox build context ($WORK/docker).
_dockerfile() {
  printf '%s\n' "$@" > "$WORK/docker/Dockerfile"
}

# Run the extracted function from inside the sandbox build context, exactly as
# build-image.sh calls it (after `cd "$SCRIPT_ROOT/docker"`, under `set -e`).
_run_prepull() {
  run bash -c 'set -e; . "$FUNC"; cd "$WORK/docker"; prepull_base_image'
}

_pulls() {
  local n=0
  [ -f "$PULLCOUNT" ] && n=$(cat "$PULLCOUNT")
  printf '%s' "$n"
}

@test "image absent, pull succeeds on first try: exit 0, exactly one pull" {
  _dockerfile 'FROM node:20-slim'
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=0
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 1 ]
}

@test "transient pull failures are retried then succeed: exit 0, back-off reported" {
  _dockerfile 'FROM node:20-slim'
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=3
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 4 ]
  [[ "$output" == *"attempt 1/5 failed"* ]]
  [[ "$output" == *"attempt 3/5 failed"* ]]
  [[ "$output" == *"retrying in 15s"* ]]
}

@test "pull never succeeds: gives up after 5 attempts, fails loud, non-zero" {
  _dockerfile 'FROM node:20-slim'
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=never
  _run_prepull
  [ "$status" -ne 0 ]
  [ "$(_pulls)" -eq 5 ]
  [[ "$output" == *"after 5 attempts"* ]]
  [[ "$output" == *"registry-1.docker.io"* ]]
}

@test "image already local: no pull is attempted, exit 0" {
  _dockerfile 'FROM node:20-slim'
  export DOCKER_INSPECT_RC=0 DOCKER_PULL_FAILS=never
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 0 ]
}

@test "pull exhausted but a local copy appears: continues with cached image" {
  # inspect FAILS up front (absent), so the pull loop runs; after it gives up the
  # function re-inspects. A docker stub whose inspect flips to present on the 2nd
  # call models a copy that arrived meanwhile — the build should proceed (exit 0).
  _dockerfile 'FROM node:20-slim'
  cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
state="$PULLCOUNT"; iflag="$BATS_TEST_TMPDIR/inspected"
case "$1 $2" in
  "image inspect")
    if [ -f "$iflag" ]; then exit 0; fi   # 2nd+ inspect: present
    : > "$iflag"; exit 1 ;;               # 1st inspect: absent
  "pull "*)
    n=0; [ -f "$state" ] && n=$(cat "$state"); n=$((n + 1)); echo "$n" > "$state"
    exit 1 ;;                             # every pull fails
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBS/docker"
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 5 ]
  [[ "$output" == *"continuing with the cached image"* ]]
}

@test "base image is parsed from FROM, ignoring --platform and AS" {
  _dockerfile 'FROM --platform=$BUILDPLATFORM node:20-slim AS base'
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=0
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 1 ]
  # The pull target in the message is the bare reference, not the flag or stage.
  [[ "$output" != *"--platform"* ]]
}

@test "non-literal FROM (ARG variable) is skipped, build left to resolve it" {
  _dockerfile 'ARG BASE=node:20-slim' 'FROM ${BASE}'
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=never
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 0 ]
  [[ "$output" == *"skipping pre-pull"* ]]
}

@test "the real repo Dockerfile resolves to a plain, pullable base reference" {
  cp "$REPO_ROOT/docker/Dockerfile" "$WORK/docker/Dockerfile"
  export DOCKER_INSPECT_RC=1 DOCKER_PULL_FAILS=0
  _run_prepull
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 1 ]
}
