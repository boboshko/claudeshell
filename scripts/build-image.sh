#!/bin/bash
set -e

source "$SCRIPT_ROOT/scripts/lib-tools.sh"

cd "$SCRIPT_ROOT/docker"

export CACHE_BUST="$(date +%s)"

tools_export_build_args

BUILD_ARGS=()
[ "${IMAGE_BUILD_PULL:-0}" = "1" ] && BUILD_ARGS+=(--pull)

if [ -f .env ]; then
  docker compose -p claude-shell --env-file .env -f docker-compose.yml build "${BUILD_ARGS[@]}"
else
  docker compose -p claude-shell -f docker-compose.yml build "${BUILD_ARGS[@]}"
fi

echo
echo "Image built."
