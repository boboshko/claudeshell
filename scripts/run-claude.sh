#!/bin/bash
set -e

source "$SCRIPT_ROOT/scripts/lib-mounts.sh"
source "$SCRIPT_ROOT/scripts/lib-firewall.sh"
source "$SCRIPT_ROOT/scripts/lib-tools.sh"
[ -f "$SCRIPT_ROOT/scripts/lib-platform.sh" ] && source "$SCRIPT_ROOT/scripts/lib-platform.sh"

trap 'docker stop claudeshell >/dev/null 2>&1 || true' EXIT INT TERM HUP

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

HASH_FILE="$SCRIPT_ROOT/docker/.build-hash"

compute_build_hash() {
  local claude_code_version=""
  [ -f "$SCRIPT_ROOT/docker/.env" ] && claude_code_version="$(grep -m1 '^CLAUDE_CODE_VERSION=' "$SCRIPT_ROOT/docker/.env" | cut -d= -f2-)"

  { cat \
    "$SCRIPT_ROOT/docker/Dockerfile" \
    "$SCRIPT_ROOT/docker/entrypoint.sh" \
    "$SCRIPT_ROOT/docker/init-firewall.sh" \
    2>/dev/null
    grep -Ev '^TOOL_(XCODE|DOCKER_SOCKET)=' "$SCRIPT_ROOT/scripts/tools.conf" 2>/dev/null || true
    echo "CLAUDE_CODE_VERSION=${claude_code_version:-latest}"
  } | _sha256
}

image_exists() {
  docker image inspect claudeshell:latest >/dev/null 2>&1
}

firewall_conf_ensure
tools_conf_ensure

current_hash="$(compute_build_hash)"
stored_hash=""
[ -f "$HASH_FILE" ] && stored_hash="$(cat "$HASH_FILE")"

if ! image_exists || [ "$current_hash" != "$stored_hash" ]; then
  if image_exists; then
    echo "Dockerfile/entrypoint.sh/init-firewall.sh changed since the last build — rebuilding image..."
  else
    echo "The claudeshell image doesn't exist yet — building..."
  fi
  bash "$SCRIPT_ROOT/scripts/build-image.sh"
  echo "$current_hash" > "$HASH_FILE"
fi

bash "$SCRIPT_ROOT/scripts/setup-network-volumes.sh" >/dev/null

mounts_generate_override

cd "$SCRIPT_ROOT/docker"

ENV_FLAG=()
[ -f .env ] && ENV_FLAG=(--env-file .env)

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.mounts.yml)
[ -f docker-compose.docker-socket.yml ] && COMPOSE_FILES+=(-f docker-compose.docker-socket.yml)

export XCODE_BRIDGE_ENABLED=0
export XCODE_BRIDGE_PORT="${XCODE_BRIDGE_PORT:-47870}"
if tools_enabled XCODE 2>/dev/null; then
  XCODE_BRIDGE_ENABLED=1
  if command -v platform_is_macos >/dev/null 2>&1 && platform_is_macos; then
    bridge_lib="$SCRIPT_ROOT/scripts/platform/macos/lib-xcode-bridge.sh"
    if [ -f "$bridge_lib" ]; then
      source "$bridge_lib"
      recorded_port="$(xcode_bridge_recorded_port 2>/dev/null || true)"
      [ -n "$recorded_port" ] && XCODE_BRIDGE_PORT="$recorded_port"
    fi
  fi
fi
export XCODE_BRIDGE_ENABLED
export XCODE_BRIDGE_PORT

if [ "$(firewall_mode 2>/dev/null)" = "disabled" ]; then
  DISABLE_FIREWALL=1
else
  DISABLE_FIREWALL=0
fi
export DISABLE_FIREWALL

if [ -f .env ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?DISABLE_FIREWALL([^A-Za-z0-9_]|$)' .env; then
  echo "[firewall] NOTE: the DISABLE_FIREWALL line in docker/.env is ignored — the Firewall menu decides." >&2
fi

docker compose -p claudeshell "${ENV_FLAG[@]}" \
  "${COMPOSE_FILES[@]}" \
  run --rm --name claudeshell -e "DISABLE_FIREWALL=$DISABLE_FIREWALL" \
  claudeshell "${ADD_DIR_ARGS[@]}" "$@"
