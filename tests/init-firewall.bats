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

# --- BF-P2-AC2/AC3: the GitHub /meta enrichment is now BEST-EFFORT ---
# This REPLACES the pass-1 "a GitHub meta body with no CIDR fails the script"
# test, which asserted the now-obsolete abort-on-no-CIDR behaviour (item 7 made
# the foreground fetch genuinely run, and the owner decision Q-B makes the
# enrichment warn+continue so a transient GitHub blip cannot brick container
# start). Named GitHub domains are already in the set; the 300 s loop retries.

@test "BF-P2-AC3: a no-wanted-CIDR /meta body WARNs and still EXITs 0 (best-effort), container not aborted" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  # a non-empty body with CIDRs only under NON-wanted keys (hooks/actions) -> the
  # key-scoped parser emits nothing -> WARNING + exit 0, no abort.
  run --separate-stderr env PATH="$ENF_PATH" \
    CURL_BODY='{"hooks":["192.30.252.0/22"],"actions":["4.148.0.0/16"]}' \
    bash "$FW_UNDER_TEST"

  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status"; printf '%s\n' "$stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] WARNING:')" -ge 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  [[ "$output" == *"not yet added; retrying"* ]]
  [[ "$output" != *"GitHub range(s)"* ]]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

@test "BF-P2-AC3: an EMPTY /meta body WARNs and still EXITs 0 (best-effort)" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  run --separate-stderr env PATH="$ENF_PATH" CURL_BODY='' bash "$FW_UNDER_TEST"

  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status"; printf '%s\n' "$stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] WARNING:')" -ge 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  [[ "$output" != *"GitHub range(s)"* ]]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

@test "BF-P2-AC3: a rate-limit JSON error /meta body (no CIDR) WARNs and still EXITs 0 (best-effort)" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  local ratelimit
  ratelimit="$(cat "$REPO_ROOT/tests/fixtures/meta-ratelimit.json")"
  run --separate-stderr env PATH="$ENF_PATH" CURL_BODY="$ratelimit" bash "$FW_UNDER_TEST"

  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status"; printf '%s\n' "$stderr"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] WARNING:')" -ge 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  [[ "$output" != *"GitHub range(s)"* ]]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

# --- BF-P2-AC2: /meta fetch ordering (item 7) ---

@test "BF-P2-AC2: set-match ACCEPT and both REJECT rules are emitted BEFORE the first api.github.com/meta curl; REJECT are the last iptables lines; no iptables after the curl" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  run env PATH="$ENF_PATH" bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  local curl_line setrule_line reject_first reject_last
  curl_line="$(grep -n 'api.github.com/meta' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "$curl_line" ] || { echo "no /meta curl logged"; cat "$STUB_LOG"; return 1; }

  # set-match ACCEPT precedes the /meta curl
  setrule_line="$(grep -n -- '-m set --match-set allowed-domains dst -j ACCEPT' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "$setrule_line" ] && [ "$setrule_line" -lt "$curl_line" ] \
    || { echo "set-match ACCEPT ($setrule_line) not before /meta curl ($curl_line)"; cat "$STUB_LOG"; return 1; }

  # both REJECT rules precede the /meta curl
  [ "$(grep -n 'REJECT' "$STUB_LOG" | awk -F: -v c="$curl_line" '$1 < c' | wc -l)" -eq 2 ] \
    || { echo "expected both REJECT before the /meta curl"; cat "$STUB_LOG"; return 1; }

  # the two REJECT lines are the last iptables lines logged
  [ "$(grep '^iptables ' "$STUB_LOG" | tail -2 | grep -c 'REJECT')" -eq 2 ] \
    || { echo "REJECT not the last two iptables lines"; cat "$STUB_LOG"; return 1; }

  # no iptables call appears AFTER the /meta curl (step 3 issues only curl/ipset)
  [ "$(grep -n '^iptables ' "$STUB_LOG" | awk -F: -v c="$curl_line" '$1 > c' | wc -l)" -eq 0 ] \
    || { echo "an iptables line appears after the /meta curl"; cat "$STUB_LOG"; return 1; }

  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

# --- BF-P2-AC2/AC3: Done-line claims ranges only when N>0 ---

@test "BF-P2-AC2: a good wanted-key /meta body adds CIDRs and the Done line claims '+ N GitHub range(s)'" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  # three CIDRs across wanted keys git/api/web
  run env PATH="$ENF_PATH" \
    CURL_BODY='{"git":["192.0.2.0/24"],"api":["198.51.100.0/24"],"web":["203.0.113.0/24"]}' \
    bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"+ 3 GitHub range(s) from api.github.com/meta"* ]] \
    || { echo "Done line did not claim 3 ranges: $output"; return 1; }
  # the three wanted CIDRs were added to the ipset
  [ "$(grep -c 'ipset add allowed-domains 192.0.2.0/24' "$STUB_LOG")" -ge 1 ]
  [ "$(grep -c 'ipset add allowed-domains 198.51.100.0/24' "$STUB_LOG")" -ge 1 ]
  [ "$(grep -c 'ipset add allowed-domains 203.0.113.0/24' "$STUB_LOG")" -ge 1 ]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

# --- BF-P2-AC6 (MINOR-1): a forged catch-all in a /meta body never reaches ipset ---

@test "BF-P2-AC6: a good body with a mixed-in 0.0.0.0/0 adds only the legit CIDRs; Done count excludes the catch-all; no ipset add of 0.0.0.0/0" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  # two legitimate wanted-key CIDRs plus a forged catch-all mixed into git, and
  # an actions catch-all that the key scope already excludes.
  run env PATH="$ENF_PATH" \
    CURL_BODY='{"git":["192.0.2.0/24","0.0.0.0/0"],"api":["198.51.100.0/24"],"actions":["0.0.0.0/0"]}' \
    bash "$FW_UNDER_TEST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # Done claims exactly the 2 legitimate ranges (catch-all not counted)
  [[ "$output" == *"+ 2 GitHub range(s) from api.github.com/meta"* ]] \
    || { echo "Done line did not claim exactly 2 ranges: $output"; return 1; }

  # the two legit CIDRs were added
  [ "$(grep -c 'ipset add allowed-domains 192.0.2.0/24' "$STUB_LOG")" -ge 1 ]
  [ "$(grep -c 'ipset add allowed-domains 198.51.100.0/24' "$STUB_LOG")" -ge 1 ]

  # the catch-all was NEVER added to the set
  [ "$(grep -c 'ipset add allowed-domains 0.0.0.0/0' "$STUB_LOG")" -eq 0 ] \
    || { echo "forged 0.0.0.0/0 reached ipset add"; grep 'ipset add' "$STUB_LOG"; return 1; }

  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

@test "BF-P2-AC6: a catch-all-only body under a wanted key adds 0 ranges and still EXITs 0 (best-effort intact, no catch-all in set)" {
  enf_make_fw_copy recommended
  enf_assert_stub_wins iptables ipset dig curl iptables-save sleep

  run --separate-stderr env PATH="$ENF_PATH" \
    CURL_BODY='{"git":["0.0.0.0/0"]}' \
    bash "$FW_UNDER_TEST"

  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status"; printf '%s\n' "$stderr"; return 1; }
  # nothing added; parser emitted nothing -> best-effort WARNING, no ERROR
  [ "$(grep -c 'ipset add allowed-domains 0.0.0.0/0' "$STUB_LOG")" -eq 0 ] \
    || { echo "forged 0.0.0.0/0 reached ipset add"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 0 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] WARNING:')" -ge 1 ]
  [[ "$output" == *"Done."* ]]
  [[ "$output" == *"not yet added; retrying"* ]]
  [[ "$output" != *"GitHub range(s)"* ]]
  enf_wait_log "sleep 300"
  enf_assert_no_leftover
}

# --- BF-P2-AC3: an injected ENFORCING failure is STILL fatal (unchanged) ---

@test "BF-P2-AC3: an injected ipset/iptables ENFORCING failure still exits non-zero with one ERROR and no Done (meta best-effort did NOT relax this)" {
  enf_assert_stub_wins iptables ipset dig curl iptables-save

  # ipset create (enforcing) fails -> fatal
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" FAIL_MATCH='ipset create*' FAIL_RC=4 bash "$FW_UNDER_TEST"
  [ "$status" -ne 0 ] || { echo "ipset create failure did not abort"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 1 ]
  [[ "$stderr" =~ line\ [0-9]+ ]]
  [[ "$output" != *"Done."* ]]

  # the set-match ACCEPT rule (enforcing) fails -> fatal
  enf_make_fw_copy recommended
  run --separate-stderr env PATH="$ENF_PATH" FAIL_MATCH='iptables -A OUTPUT -m set*' FAIL_RC=4 bash "$FW_UNDER_TEST"
  [ "$status" -ne 0 ] || { echo "set-match ACCEPT failure did not abort"; return 1; }
  [ "$(printf '%s\n' "$stderr" | grep -c '^\[init-firewall\] ERROR:')" -eq 1 ]
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
