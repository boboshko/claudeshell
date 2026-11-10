#!/usr/bin/env bash
# Shared helper for tests/entrypoint.bats and tests/init-firewall.bats.
#
# SAFETY: the real /usr/local/bin/init-firewall.sh is installed in this sandbox
# and `sudo` to it is passwordless. These tests must NEVER reach the real sudo,
# the real init-firewall.sh, or real iptables/ipset. We build a stub directory
# and run everything under PATH="$STUBS:/usr/bin:/bin"; enf_assert_stub_wins
# proves our stub resolves first for every privileged/enforcing name before any
# script is executed. The firewall script is tested only as a temp copy whose
# one hardcoded library path has been redirected (enf_make_fw_copy).

enf_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT

  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  ENF_PATH="$STUBS:/usr/bin:/bin"
  export STUBS ENF_PATH

  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  : > "$STUB_LOG"; : > "$CLAUDE_LOG"; : > "$SUDO_LOG"
  export STUB_LOG CLAUDE_LOG SUDO_LOG

  # A clean HOME so entrypoint.sh's .claude.json handling has somewhere to work.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"

  # Defaults the stubs read from the environment; a test overrides them.
  # Under the pass-2 key-scoped parser only CIDRs under git/api/web/packages are
  # taken, so the default /meta body must sit under a WANTED key (git+api here =
  # 2 CIDRs) for the happy path to actually add ranges. (The pass-1 default,
  # {"ranges":[…]}, is under a non-wanted key and would now yield zero.)
  export CURL_BODY='{"git":["192.0.2.0/24"],"api":["198.51.100.0/24"]}'
  export DIG_OUT='192.0.2.10'
  export SAVE_OUT=''
  unset FAIL_MATCH FAIL_RC SUDO_RC CLAUDE_RC || true

  _enf_write_stubs
}

_enf_write_stubs() {
  # One generic logging stub for iptables and ipset. It appends "<name> <args>"
  # to $STUB_LOG and, if $FAIL_MATCH is set and the logged line matches it as a
  # glob, exits with $FAIL_RC (default 4).
  cat > "$STUBS/iptables" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
line="$name $*"
printf '%s\n' "$line" >> "$STUB_LOG"
if [ -n "${FAIL_MATCH:-}" ]; then
  case "$line" in
    $FAIL_MATCH) exit "${FAIL_RC:-4}" ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUBS/iptables"
  cp "$STUBS/iptables" "$STUBS/ipset"

  # iptables-save: prints $SAVE_OUT (empty by default, so no Docker DNS rules).
  cat > "$STUBS/iptables-save" <<'STUB'
#!/usr/bin/env bash
[ -n "${SAVE_OUT:-}" ] && printf '%s\n' "$SAVE_OUT"
exit 0
STUB
  chmod +x "$STUBS/iptables-save"

  # dig: prints $DIG_OUT (one documentation address by default; empty to force
  # the "could not resolve" path).
  cat > "$STUBS/dig" <<'STUB'
#!/usr/bin/env bash
[ -n "${DIG_OUT:-}" ] && printf '%s\n' "$DIG_OUT"
exit 0
STUB
  chmod +x "$STUBS/dig"

  # curl: logs its argv to $STUB_LOG (so the /meta fetch is orderable against the
  # iptables/ipset lines) and prints $CURL_BODY (a JSON fragment with wanted-key
  # CIDRs by default). Never reaches the network.
  cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
printf '%s' "${CURL_BODY:-}"
exit 0
STUB
  chmod +x "$STUBS/curl"

  # sleep: logs and exits non-zero. In the background refresh subshell the
  # script runs under `set -e`, so a failing sleep ends the 300 s loop at once
  # instead of leaving it running; the ERR trap stays silent there because
  # BASH_SUBSHELL != 0.
  cat > "$STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$STUB_LOG"
exit 1
STUB
  chmod +x "$STUBS/sleep"

  # sudo: logs its arguments. It refuses anything but the firewall script. With
  # $SUDO_RC set it just returns that code (firewall "fails" without running
  # anything); otherwise it execs the patched copy, exercising the real chain.
  cat > "$STUBS/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$SUDO_LOG"
if [ "$1" != "/usr/local/bin/init-firewall.sh" ]; then
  echo "STUB-SUDO: refusing unexpected command: $*" >&2
  exit 99
fi
if [ -n "${SUDO_RC:-}" ]; then
  exit "$SUDO_RC"
fi
exec bash "$FW_UNDER_TEST"
STUB
  chmod +x "$STUBS/sudo"

  # claude: logs its arguments (each bracketed, so "a b" as one argument is
  # distinguishable from two) and exits $CLAUDE_RC (default 0). Reaching this
  # stub means the entrypoint decided to start Claude Code.
  cat > "$STUBS/claude" <<'STUB'
#!/usr/bin/env bash
{ printf 'claude'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$CLAUDE_LOG"
exit "${CLAUDE_RC:-0}"
STUB
  chmod +x "$STUBS/claude"
}

# Prove our stub is the one that resolves first for every given name, under the
# exact PATH the scripts will run with.
enf_assert_stub_wins() {
  local name resolved
  for name in "$@"; do
    resolved="$(PATH="$ENF_PATH" command -v "$name" 2>/dev/null || true)"
    if [ "$resolved" != "$STUBS/$name" ]; then
      echo "SAFETY: stub for '$name' did not win PATH lookup (got: ${resolved:-none})" >&2
      return 1
    fi
  done
}

# Build the temp copy of init-firewall.sh with its one hardcoded library path
# redirected to the repo's real lib-firewall.sh, and write a firewall.conf.
# $1 = mode (default recommended).
enf_make_fw_copy() {
  local src="$REPO_ROOT/docker/init-firewall.sh" count
  count="$(grep -c '/etc/claude-shell/lib-firewall.sh' "$src")"
  if [ "$count" -ne 2 ]; then
    echo "enf_make_fw_copy: expected the hardcoded lib path exactly twice, found $count" >&2
    return 1
  fi
  FW_UNDER_TEST="$BATS_TEST_TMPDIR/init-firewall.sh"
  sed "s#/etc/claude-shell/lib-firewall.sh#$REPO_ROOT/scripts/lib-firewall.sh#g" \
    "$src" > "$FW_UNDER_TEST"
  FIREWALL_CONF="$BATS_TEST_TMPDIR/firewall.conf"
  printf 'MODE=%s\n' "${1:-recommended}" > "$FIREWALL_CONF"
  export FW_UNDER_TEST FIREWALL_CONF
}

# A sub-second wait that does not use the (stubbed / foreground-blocked) sleep
# binary: read with a timeout from a fifo that nobody writes to.
enf_nap() {
  local fifo="$BATS_TEST_TMPDIR/.nap.fifo" fd
  [ -p "$fifo" ] || mkfifo "$fifo"
  exec {fd}<>"$fifo"
  read -t "${1:-0.1}" -u "$fd" _ 2>/dev/null || true
  exec {fd}>&-
}

# Poll $STUB_LOG until it contains $1 (fixed string) or we give up.
enf_wait_log() {
  local pat="$1" i=0
  while [ "$i" -lt 40 ]; do
    grep -qF "$pat" "$STUB_LOG" && return 0
    enf_nap 0.05
    i=$((i + 1))
  done
  return 1
}

# Fail if any process is still running the firewall copy (the 300 s refresh
# loop must not survive). ps/pgrep are absent here, so scan /proc.
enf_assert_no_leftover() {
  enf_nap 0.2
  local p hits=""
  for p in /proc/[0-9]*/cmdline; do
    [ -r "$p" ] || continue
    if tr '\0' ' ' < "$p" 2>/dev/null | grep -qF "$FW_UNDER_TEST"; then
      hits="${p%/cmdline} $hits"
    fi
  done
  if [ -n "$hits" ]; then
    echo "leftover firewall process(es) still running: $hits" >&2
    return 1
  fi
}
