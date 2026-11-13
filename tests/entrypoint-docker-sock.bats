#!/usr/bin/env bats
#
# docker/entrypoint.sh — the Docker-socket block added for the "Docker socket
# access" tool. Runs a copy of the real entrypoint with the socket path and the
# firewall branch rewritten so the test exercises only the new block:
#   - the firewall call is forced into the Disabled branch (DISABLE_FIREWALL=1),
#     so no sudo/iptables is needed and we land straight at the socket block;
#   - the hardcoded /var/run/docker.sock is pointed at a temp path.
# sudo and claude are PATH stubs that record their arguments.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR"
  STUBDIR="$TMP/bin"; mkdir -p "$STUBDIR"
  SUDO_LOG="$TMP/sudo.log"; CLAUDE_LOG="$TMP/claude.log"
  : > "$SUDO_LOG"; : > "$CLAUDE_LOG"

  # sudo stub: record the command, honor FIX_RC for the fix-docker-sock call.
  cat > "$STUBDIR/sudo" <<EOF
#!/bin/sh
echo "\$*" >> "$SUDO_LOG"
case "\$*" in
  *fix-docker-sock.sh) exit \${FIX_RC:-0} ;;
esac
exit 0
EOF
  # claude stub: record that it was exec'd (success path must still reach it).
  cat > "$STUBDIR/claude" <<EOF
#!/bin/sh
echo "claude \$*" >> "$CLAUDE_LOG"
EOF
  chmod +x "$STUBDIR/sudo" "$STUBDIR/claude"

  # Entrypoint copy with the socket path redirected to $TMP.
  sed "s#/var/run/docker.sock#$TMP/docker.sock#g" \
    "$REPO_ROOT/docker/entrypoint.sh" > "$TMP/entrypoint.sh"
}

_mk_sock() {
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$TMP/docker.sock"
}

@test "no socket -> fix helper not called, claude still starts" {
  run env PATH="$STUBDIR:$PATH" HOME="$TMP" DISABLE_FIREWALL=1 \
    bash "$TMP/entrypoint.sh"
  [ "$status" -eq 0 ]
  ! grep -q "fix-docker-sock.sh" "$SUDO_LOG"
  [ -s "$CLAUDE_LOG" ]
}

@test "socket present + helper ok -> calls sudo fix-docker-sock, prints access line, starts claude" {
  _mk_sock
  run env PATH="$STUBDIR:$PATH" HOME="$TMP" DISABLE_FIREWALL=1 \
    bash "$TMP/entrypoint.sh"
  [ "$status" -eq 0 ]
  grep -q "fix-docker-sock.sh" "$SUDO_LOG"
  [[ "$output" == *"Docker socket access"* ]]
  [[ "$output" == *"root-equivalent"* ]]
  [ -s "$CLAUDE_LOG" ]
}

@test "socket present + helper fails -> WARNING, but claude still starts" {
  _mk_sock
  run env PATH="$STUBDIR:$PATH" HOME="$TMP" DISABLE_FIREWALL=1 FIX_RC=1 \
    bash "$TMP/entrypoint.sh"
  [ "$status" -eq 0 ]
  grep -q "fix-docker-sock.sh" "$SUDO_LOG"
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"permission denied"* ]]
  [ -s "$CLAUDE_LOG" ]
}
