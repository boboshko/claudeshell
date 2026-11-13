#!/bin/bash
set -e

echo "Checking network claudeshell..."
if docker network inspect claudeshell >/dev/null 2>&1; then
  echo "  already exists, skipping."
else
  docker network create claudeshell
  echo "  created."
fi

for vol in claudeshell-config claudeshell-npm-cache; do
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
