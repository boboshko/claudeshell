#!/bin/bash
set -e

if [ ! -e "$HOME/.claude.json" ] || [ ! -L "$HOME/.claude.json" ]; then
  if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then
    mv "$HOME/.claude.json" "$HOME/.claude/.claude.json"
  fi
  ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"
fi

if [ "${DISABLE_FIREWALL:-0}" = "1" ]; then
  echo "[entrypoint] WARNING: firewall disabled for this session — egress is unrestricted."
elif sudo /usr/local/bin/init-firewall.sh; then
  echo "[entrypoint] Firewall active: egress restricted to the allow-list."
else
  {
    echo "[entrypoint] ERROR: firewall setup failed — Claude Code was not started."
    echo "[entrypoint] Check that the container has the NET_ADMIN and NET_RAW capabilities (cap_add in docker/docker-compose.yml) and that iptables/ipset work on this Docker host. An [init-firewall] ERROR line above names the step that failed."
    echo "[entrypoint] Fix the cause and run again, or select Firewall -> Disabled in the ClaudeShell menu to run with unrestricted egress."
  } >&2
  exit 1
fi

exec claude "$@"
