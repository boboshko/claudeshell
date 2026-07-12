#!/bin/bash
set -e

cd "$SCRIPT_ROOT/docker"

if [ -f .env ]; then
  docker compose -p claude-shell --env-file .env -f docker-compose.yml build
else
  docker compose -p claude-shell -f docker-compose.yml build
fi

echo
echo "Image built."
