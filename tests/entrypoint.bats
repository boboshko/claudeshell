#!/usr/bin/env bats
#
# Item 6 (S2): docker/entrypoint.sh must refuse to start Claude Code when the
# firewall is in Recommended mode and init-firewall.sh fails. Runs the real,
# unmodified docker/entrypoint.sh under a stub PATH; the real sudo /
# init-firewall.sh / iptables are never reached (see helpers/enforcement.bash).

load helpers/enforcement

setup() {
  enf_setup
}

# --- BF6-AC1: Recommended + firewall failure -> exit 1, no Claude, right text ---

@test "BF6-AC1: firewall failure in Recommended refuses to start Claude for every non-'1' DISABLE_FIREWALL and both sudo failure codes" {
  enf_assert_stub_wins sudo claude iptables ipset

  local dfw rc
  for rc in 1 127; do
    for dfw in __unset__ 0 __empty__ true; do
      : > "$CLAUDE_LOG"
      case "$dfw" in
        __unset__) run env -u DISABLE_FIREWALL PATH="$ENF_PATH" SUDO_RC="$rc" \
                     bash "$REPO_ROOT/docker/entrypoint.sh" ;;
        __empty__) run env PATH="$ENF_PATH" DISABLE_FIREWALL="" SUDO_RC="$rc" \
                     bash "$REPO_ROOT/docker/entrypoint.sh" ;;
        *)         run env PATH="$ENF_PATH" DISABLE_FIREWALL="$dfw" SUDO_RC="$rc" \
                     bash "$REPO_ROOT/docker/entrypoint.sh" ;;
      esac

      local ctx="DISABLE_FIREWALL=$dfw SUDO_RC=$rc"
      [ "$status" -eq 1 ] || { echo "[$ctx] expected exit 1, got $status"; echo "$output"; return 1; }
      [ ! -s "$CLAUDE_LOG" ] || { echo "[$ctx] claude was invoked: $(cat "$CLAUDE_LOG")"; return 1; }
      [[ "$output" == *"[entrypoint] ERROR:"* ]] || { echo "[$ctx] missing ERROR prefix"; echo "$output"; return 1; }
      [[ "$output" == *"not started"* ]]         || { echo "[$ctx] missing 'not started'"; return 1; }
      [[ "$output" == *"NET_ADMIN"* ]]           || { echo "[$ctx] missing NET_ADMIN"; return 1; }
      [[ "$output" == *"NET_RAW"* ]]             || { echo "[$ctx] missing NET_RAW"; return 1; }
      [[ "$output" == *"Firewall -> Disabled"* ]] || { echo "[$ctx] missing 'Firewall -> Disabled'"; return 1; }
      [[ "$output" != *"not restricted"* ]]      || { echo "[$ctx] still says 'not restricted'"; return 1; }
    done
  done
}

# --- BF6-AC3a: Disabled mode unchanged ---

@test "BF6-AC3a: DISABLE_FIREWALL=1 keeps the old warning line, never calls sudo, passes args to claude, returns claude's code" {
  enf_assert_stub_wins sudo claude

  run env PATH="$ENF_PATH" DISABLE_FIREWALL=1 CLAUDE_RC=7 \
    bash "$REPO_ROOT/docker/entrypoint.sh" --foo "a b"

  [ "$status" -eq 7 ]
  [[ "$output" == *"[entrypoint] WARNING: firewall disabled for this session — egress is unrestricted."* ]]
  [ ! -s "$SUDO_LOG" ]
  [ "$(cat "$CLAUDE_LOG")" = "claude [--foo] [a b]" ]
}

# --- BF6-AC3b: success path unchanged (chained to the real firewall copy) ---

@test "BF6-AC3b: firewall success prints the active line and starts claude with the args" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins sudo claude iptables ipset

  run env -u DISABLE_FIREWALL PATH="$ENF_PATH" \
    bash "$REPO_ROOT/docker/entrypoint.sh" --model x

  [ "$status" -eq 0 ]
  [[ "$output" == *"[entrypoint] Firewall active: egress restricted to the allow-list."* ]]
  [[ "$output" != *"not restricted"* ]]
  [ "$(cat "$CLAUDE_LOG")" = "claude [--model] [x]" ]
  enf_assert_no_leftover
}

# --- BF6-AC2 (chain): a late firewall failure stops the entrypoint too ---

@test "BF6-AC2 chain: an injected iptables failure makes init-firewall.sh and the entrypoint both error, and claude is never started" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins sudo claude iptables ipset

  run env -u DISABLE_FIREWALL PATH="$ENF_PATH" \
    FAIL_MATCH='iptables -P OUTPUT DROP' FAIL_RC=4 \
    bash "$REPO_ROOT/docker/entrypoint.sh" --foo

  [ "$status" -eq 1 ]
  [ ! -s "$CLAUDE_LOG" ]
  [[ "$output" == *"[init-firewall] ERROR:"* ]]
  [[ "$output" == *"[entrypoint] ERROR:"* ]]
  # the firewall's own diagnosis must come before the entrypoint's
  [[ "$output" == *"[init-firewall] ERROR:"*"[entrypoint] ERROR:"* ]]
  enf_assert_no_leftover
}
