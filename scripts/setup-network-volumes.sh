#!/bin/bash
set -e

echo "Checking network claude-shell..."
if docker network inspect claude-shell >/dev/null 2>&1; then
  echo "  already exists, skipping."
else
  docker network create claude-shell
  echo "  created."
fi

for vol in claude-shell-config claude-shell-npm-cache; do
  echo "Checking volume ${vol}..."
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "  already exists, skipping."
  else
    docker volume create "$vol"
    echo "  created."
  fi
done

echo
echo "Done."
