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

# If the "Docker socket access" tool mounted the host Docker socket, hand it to
# the 'claude' group so the in-container docker CLI can actually use it (the
# socket arrives root:root 0660 and 'claude' is unprivileged). No socket => the
# helper is a no-op. Access to the host daemon is root-equivalent on the host —
# it only happens because the user enabled that tool and accepted its warning.
if [ -S /var/run/docker.sock ]; then
  if sudo /usr/local/bin/fix-docker-sock.sh; then
    echo "[entrypoint] Docker socket access: host daemon socket is now usable from this container (root-equivalent host access — enabled via the 'Docker socket access' tool)."
  else
    echo "[entrypoint] WARNING: a Docker socket is mounted but adjusting its permissions failed — 'docker' may report permission denied inside the container." >&2
  fi
fi

exec claude "$@"
