#!/bin/bash
set -e

source "$SCRIPT_ROOT/scripts/lib-tools.sh"

cd "$SCRIPT_ROOT/docker"

export CACHE_BUST="$(date +%s)"

tools_export_build_args

if [ -f .env ]; then
  docker compose -p claude-shell --env-file .env -f docker-compose.yml build
else
  docker compose -p claude-shell -f docker-compose.yml build
fi

echo
echo "Image built."
