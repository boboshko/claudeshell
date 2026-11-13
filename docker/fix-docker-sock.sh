#!/bin/sh
# fix-docker-sock.sh — grant the in-container 'claude' user access to the
# bind-mounted host Docker socket, but ONLY when the "Docker socket access"
# tool actually mounted one.
#
# Why this exists: the container runs Claude Code as the unprivileged 'claude'
# user (USER claude), while the host socket is bind-mounted as root:root 0660,
# so 'claude' gets "permission denied" even with the socket present. This helper
# hands the socket to the 'claude' group so the in-container docker CLI works.
#
# It is run as root through a narrow NOPASSWD sudoers entry — the exact same
# pattern already used for init-firewall.sh. It takes no arguments and operates
# on a single fixed path, so there is no argument/injection surface. The result
# is root:claude 0660 — access is limited to the 'claude' group, never world.
#
# SECURITY: access to the host Docker socket is root-equivalent on the host.
# This only runs when the socket is mounted, i.e. when the user has enabled the
# "Docker socket access" tool and accepted its warning. No socket => no-op.
set -eu

sock=/var/run/docker.sock

# No mounted socket (feature off) => nothing to do; harmless no-op so the
# entrypoint can call this unconditionally.
[ -S "$sock" ] || exit 0

chgrp claude "$sock"
chmod g+rw "$sock"
