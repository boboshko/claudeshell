#!/bin/bash
set -e

if [ ! -e "$HOME/.claude.json" ] || [ ! -L "$HOME/.claude.json" ]; then
  if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then
    mv "$HOME/.claude.json" "$HOME/.claude/.claude.json"
  fi
  ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"
fi

if sudo /usr/local/bin/init-firewall.sh; then
  echo "[entrypoint] Firewall active: egress restricted to the allow-list."
else
  echo "[entrypoint] WARNING: firewall not started (missing NET_ADMIN/NET_RAW?). Egress is not restricted."
fi

exec claude "$@"
