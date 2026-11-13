#!/usr/bin/env bats
#
# docker/fix-docker-sock.sh — grants the 'claude' group access to the mounted
# host Docker socket, but ONLY when a socket is actually present. Runs a copy of
# the real helper with its single hardcoded socket path rewritten to a temp path
# (the production path is hardcoded on purpose — the helper is invoked via sudo
# with env_reset, so no env override would survive in production). chgrp/chmod
# are intercepted by PATH stubs that record their arguments; no real ownership
# or mode is changed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR"
  STUBDIR="$TMP/bin"
  mkdir -p "$STUBDIR"
  CALLS="$TMP/calls.log"
  : > "$CALLS"

  # Recording stubs for the two privileged ops. CHGRP_RC lets a test force a
  # failure to check that the helper propagates it (set -e).
  cat > "$STUBDIR/chgrp" <<EOF
#!/bin/sh
echo "chgrp \$*" >> "$CALLS"
exit \${CHGRP_RC:-0}
EOF
  cat > "$STUBDIR/chmod" <<EOF
#!/bin/sh
echo "chmod \$*" >> "$CALLS"
exit \${CHMOD_RC:-0}
EOF
  chmod +x "$STUBDIR/chgrp" "$STUBDIR/chmod"
}

# Write a copy of the real helper with the socket path pointed at $1.
_helper_with_sock() {
  local sock="$1"
  sed "s#/var/run/docker.sock#${sock}#g" \
    "$REPO_ROOT/docker/fix-docker-sock.sh" > "$TMP/helper.sh"
  echo "$TMP/helper.sh"
}

@test "no socket present -> no-op, exit 0, neither chgrp nor chmod called" {
  local helper; helper="$(_helper_with_sock "$TMP/nope.sock")"
  run env PATH="$STUBDIR:$PATH" sh "$helper"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "socket present -> chgrp claude + chmod g+rw on that socket, exit 0" {
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$TMP/docker.sock"
  local helper; helper="$(_helper_with_sock "$TMP/docker.sock")"

  run env PATH="$STUBDIR:$PATH" sh "$helper"
  [ "$status" -eq 0 ]
  grep -qx "chgrp claude $TMP/docker.sock" "$CALLS" || { echo "calls:"; cat "$CALLS"; return 1; }
  grep -qx "chmod g+rw $TMP/docker.sock" "$CALLS"   || { echo "calls:"; cat "$CALLS"; return 1; }
}

@test "chgrp failure propagates (set -e) and chmod is not reached" {
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$TMP/docker.sock"
  local helper; helper="$(_helper_with_sock "$TMP/docker.sock")"

  run env PATH="$STUBDIR:$PATH" CHGRP_RC=1 sh "$helper"
  [ "$status" -ne 0 ]
  grep -q "^chgrp " "$CALLS"
  ! grep -q "^chmod " "$CALLS"
}
