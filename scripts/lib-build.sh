#!/bin/bash

BUILD_HASH_FILE="$SCRIPT_ROOT/docker/.build-hash"

build_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

build_compute_hash() {
  local claude_code_version=""
  [ -f "$SCRIPT_ROOT/docker/.env" ] && claude_code_version="$(grep -m1 '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" | cut -d= -f2-)"

  { cat \
    "$SCRIPT_ROOT/docker/Dockerfile" \
    "$SCRIPT_ROOT/docker/entrypoint.sh" \
    "$SCRIPT_ROOT/docker/init-firewall.sh" \
    2>/dev/null
    grep -Ev '^TOOL_(XCODE|DOCKER_SOCKET)=' "$SCRIPT_ROOT/scripts/tools.conf" 2>/dev/null || true
    echo "CLAUDE_CODE_VERSION=${claude_code_version:-latest}"
  } | build_sha256
}

build_image_exists() {
  docker image inspect claudeshell:latest >/dev/null 2>&1
}
