#!/bin/bash
set -e

source "$SCRIPT_ROOT/scripts/lib-mounts.sh"

trap 'docker stop claude-shell >/dev/null 2>&1 || true' EXIT INT TERM HUP

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
  cat \
    "$SCRIPT_ROOT/docker/Dockerfile" \
    "$SCRIPT_ROOT/docker/entrypoint.sh" \
    "$SCRIPT_ROOT/docker/init-firewall.sh" \
    2>/dev/null | _sha256
}

image_exists() {
  docker image inspect claude-shell:latest >/dev/null 2>&1
}

current_hash="$(compute_build_hash)"
stored_hash=""
[ -f "$HASH_FILE" ] && stored_hash="$(cat "$HASH_FILE")"

if ! image_exists || [ "$current_hash" != "$stored_hash" ]; then
  if image_exists; then
    echo "Dockerfile/entrypoint.sh/init-firewall.sh changed since the last build — rebuilding image..."
  else
    echo "The claude-shell image doesn't exist yet — building..."
  fi
  bash "$SCRIPT_ROOT/scripts/build-image.sh"
  echo "$current_hash" > "$HASH_FILE"
fi

bash "$SCRIPT_ROOT/scripts/setup-network-volumes.sh" >/dev/null

mounts_generate_override

cd "$SCRIPT_ROOT/docker"

ENV_FLAG=()
[ -f .env ] && ENV_FLAG=(--env-file .env)

docker compose -p claude-shell "${ENV_FLAG[@]}" \
  -f docker-compose.yml \
  -f docker-compose.mounts.yml \
  run --rm --name claude-shell claude-shell "${ADD_DIR_ARGS[@]}" "$@"
