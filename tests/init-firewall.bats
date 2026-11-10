#!/usr/bin/env bats
#
# Item 6 (S2): docker/init-firewall.sh must exit non-zero and name the failed
# step whenever any enforcing command fails, and exit 0 only when the whole
# allow-list policy was installed. Runs a temp copy whose one hardcoded library
# path is redirected (enf_make_fw_copy); real iptables/ipset/sudo are never run.

bats_require_minimum_version 1.5.0

load helpers/enforcement

setup() {
  enf_setup
}

# --- BF6-AC2: every enforcing command, if it fails, fails the script loudly ---

@test "BF6-AC2: a failure at any enforcing step exits non-zero with exactly one named [init-firewall] ERROR and no Done." {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  local patterns=(
    'iptables -F'
    'iptables -X'
    'iptables -P INPUT DROP'
    'iptables -P FORWARD DROP'
    'iptables -P OUTPUT DROP'
    'iptables -A INPUT -i lo*'
    'iptables -A OUTPUT -m state*'
    'iptables -A OUTPUT -p udp*--dport 53*'
    'ipset create*'
    'iptables -A OUTPUT -m set*'
    'iptables -A OUTPUT -j REJECT*'
    'iptables -A INPUT -j REJECT*'
  )

  local pat n
  for pat in "${patterns[@]}"; do
    run --separate-stderr env PATH="$ENF_PATH" FAIL_MATCH="$pat" FAIL_RC=4 \
      bash "$FW_UNDER_TEST"

    [ "$status" -ne 0 ] || { echo "[$pat] expected non-zero exit, got 0"; echo "$output"; return 1; }
    n="$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')"
    [ "$n" -eq 1 ] || { echo "[$pat] expected exactly one ERROR line, got $n"; printf '%s\n' "$stderr"; return 1; }
    [[ "$stderr" =~ line\ [0-9]+ ]] || { echo "[$pat] ERROR line names no line number: $stderr"; return 1; }
    [[ "$output" != *"Done."* ]] || { echo "[$pat] reached Done. despite a failure"; return 1; }
  done
}

@test "BF6-AC2: a GitHub meta body with no CIDR fails the script with one named ERROR" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl

  run --separate-stderr env PATH="$ENF_PATH" CURL_BODY='{"x":1}' \
    bash "$FW_UNDER_TEST"

  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 1 ]
  [[ "$stderr" =~ line\ [0-9]+ ]]
  [[ "$output" != *"Done."* ]]
}

# --- BF6-AC2: tolerated (narrowing) failures stay tolerated ---

@test "BF6-AC2: tolerated failures (ipset destroy/add, DNS-rule restore, empty dig) do not fail the script" {
  enf_assert_stub_wins iptables ipset dig curl iptables-save

  # ipset destroy fails -> || true
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" FAIL_MATCH='ipset destroy*' FAIL_RC=4 bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "ipset destroy: $stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]

  # ipset add fails -> || true
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" FAIL_MATCH='ipset add*' FAIL_RC=4 bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "ipset add: $stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]

  # a Docker-DNS restore rule that fails to re-apply -> || true
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" \
    SAVE_OUT='-A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT' \
    FAIL_MATCH='iptables -A OUTPUT -d 127.0.0.11*' FAIL_RC=4 bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "dns restore: $stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]

  # dig resolves nothing -> the existing "could not resolve" warning, still rc 0
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" DIG_OUT='' bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "empty dig: $stderr"; return 1; }
  [[ "$output" == *"could not resolve"* ]]
}

# --- BF6-AC2 / BF6-AC4: happy path, ordering, and no leftover refresh loop ---

@test "BF6-AC2/AC4: with no injected failure the policy is DROP-first, REJECT-last, exits 0, and leaves no refresh loop" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  run env PATH="$ENF_PATH" bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Done."* ]]

  # exactly the three default-deny policies, all before the first ACCEPT rule
  [ "$(grep -c -- '-P .* DROP' "$STUB_LOG")" -eq 3 ]
  local drop_last accept_first
  drop_last="$(grep -n -- '-P .* DROP' "$STUB_LOG" | tail -1 | cut -d: -f1)"
  accept_first="$(grep -n 'ACCEPT' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ "$drop_last" -lt "$accept_first" ]

  # the two REJECT rules are the last iptables lines logged
  [ "$(grep '^iptables ' "$STUB_LOG" | tail -2 | grep -c 'REJECT')" -eq 2 ]
  # and the set-ACCEPT rule precedes them
  local setrule_line reject_first
  setrule_line="$(grep -n -- '-m set --match-set allowed-domains' "$STUB_LOG" | head -1 | cut -d: -f1)"
  reject_first="$(grep -n 'REJECT' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ "$setrule_line" -lt "$reject_first" ]

  # the 300 s refresh loop started once and then terminated (no leftover process)
  enf_wait_log "sleep 300"
  [ "$(grep -c '^sleep 300' "$STUB_LOG")" -ge 1 ]
  enf_assert_no_leftover
}

# --- Disabled mode: only the mandatory Anthropic group, still a clean exit 0 ---

@test "BF6-AC2: MODE=disabled installs the policy, exits 0, and leaves no refresh loop" {
  enf_make_fw_copy disabled
  enf_assert_stub_wins iptables ipset dig curl sleep

  run env PATH="$ENF_PATH" bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Done."* ]]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}
