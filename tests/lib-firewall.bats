#!/usr/bin/env bats

setup() {
  TEST_TMP="$(mktemp -d)"
  export SCRIPT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/scripts"
  FIREWALL_CONF="$TEST_TMP/scripts/firewall.conf"
  export FIREWALL_CONF
  LIB="$BATS_TEST_DIRNAME/../scripts/lib-firewall.sh"
  source "$LIB"
}

teardown() {
  rm -rf "$TEST_TMP"
}

write_conf() {
  printf '%s\n' "$@" > "$FIREWALL_CONF"
}

# A file as the previous version could have written it.
write_legacy_conf() {
  write_conf "MODE=$1" \
    "SERVICE_NPM=on" "SERVICE_GITHUB=off" "SERVICE_GITLAB=on" "SERVICE_PYPI=on" \
    "SERVICE_DOCKERHUB=on" "SERVICE_HUGGINGFACE=off" "SERVICE_MICROSOFT=off" \
    "SERVICE_APPLE=off" "SERVICE_GO=on" "SERVICE_RUST=on" \
    "CUSTOM_1=example.com" "CUSTOM_2=10.0.0.0/24"
}

# Checks the result of `run firewall_mode`: one warning, then exactly "recommended".
assert_warned_recommended() {
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  case "${lines[0]}" in
    *WARNING*) ;;
    *) return 1 ;;
  esac
  [ "${lines[1]}" = "recommended" ]
}

@test "conf_ensure creates a file holding only MODE=recommended when missing" {
  firewall_conf_ensure
  [ -f "$FIREWALL_CONF" ]
  printf 'MODE=recommended\n' > "$TEST_TMP/expected"
  cmp "$TEST_TMP/expected" "$FIREWALL_CONF"
  run firewall_mode
  [ "$status" -eq 0 ]
  [ "$output" = "recommended" ]
}

@test "valid MODE and SERVICE lines are accepted" {
  write_conf "MODE=recommended" "SERVICE_NPM=on" "SERVICE_GO=off"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 0 ]
}

@test "valid CUSTOM domain and CIDR lines are accepted" {
  write_conf "MODE=recommended" "CUSTOM_1=example.com" "CUSTOM_2=10.0.0.0/24"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 0 ]
}

@test "a single bad MODE value rejects the whole file" {
  write_conf "MODE=yolo" "SERVICE_NPM=on"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "a single bad SERVICE value rejects the whole file" {
  write_conf "MODE=recommended" "SERVICE_NPM=maybe"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "an unknown SERVICE slug rejects the whole file" {
  write_conf "MODE=recommended" "SERVICE_NOTREAL=on"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "SECURITY: a SERVICE_* key containing a command substitution is rejected without being executed" {
  write_conf "MODE=recommended" 'SERVICE_NPM$(touch /tmp/fw_bats_pwned)=on'
  rm -f /tmp/fw_bats_pwned
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
  [ ! -e /tmp/fw_bats_pwned ]
}

@test "SECURITY: a SERVICE_* key containing a shell metacharacter (semicolon) is rejected without being executed" {
  write_conf "MODE=recommended" 'SERVICE_NPM;touch /tmp/fw_bats_pwned2=on'
  rm -f /tmp/fw_bats_pwned2
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
  [ ! -e /tmp/fw_bats_pwned2 ]
}

@test "SECURITY: MODE=disabled plus a CUSTOM value containing a command substitution stays Recommended and is not executed" {
  local marker="$TEST_TMP/pwned"
  write_conf "MODE=disabled" "CUSTOM_1=\$(touch $marker)"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
  run firewall_mode
  assert_warned_recommended
  [ ! -e "$marker" ]
}

@test "a bad CUSTOM value (neither domain nor CIDR) rejects the whole file" {
  write_conf "MODE=recommended" "CUSTOM_1=not a domain!!"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "an unknown top-level key rejects the whole file" {
  write_conf "MODE=recommended" "FOO=bar"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "a line not matching KEY=VALUE shape rejects the whole file" {
  write_conf "MODE=recommended" "not_an_assignment"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
}

@test "missing file falls back to Recommended defaults, never disabled" {
  rm -f "$FIREWALL_CONF"
  run firewall_mode
  assert_warned_recommended
}

@test "unreadable file falls back to Recommended defaults, never disabled" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode 000 file"
  write_conf "MODE=disabled"
  chmod 000 "$FIREWALL_CONF"
  run firewall_mode
  chmod 644 "$FIREWALL_CONF"
  assert_warned_recommended
}

@test "malformed file falls back to Recommended defaults, never disabled" {
  write_conf "MODE=yolo"
  run firewall_mode
  assert_warned_recommended
}

@test "a file without MODE, or MODE=disabled plus any invalid line, falls back to Recommended with a warning" {
  write_conf "SERVICE_NPM=on"
  run firewall_mode
  assert_warned_recommended

  local bad
  for bad in "FOO=bar" "not_an_assignment" "SERVICE_NPM=maybe" "SERVICE_NOTREAL=on" \
    "CUSTOM_1=not a domain!!" "CUSTOM_0=example.com"; do
    write_conf "MODE=disabled" "$bad"
    run firewall_mode
    assert_warned_recommended
  done
}

@test "a valid file with MODE=disabled is honored exactly" {
  write_conf "MODE=disabled" "SERVICE_NPM=on"
  run firewall_mode
  [ "$output" = "disabled" ]
}

@test "a legacy file keeps its MODE without any warning" {
  local m
  for m in disabled recommended; do
    write_legacy_conf "$m"
    run firewall_parse_strict "$FIREWALL_CONF"
    [ "$status" -eq 0 ]
    run firewall_mode
    [ "$status" -eq 0 ]
    [ "$output" = "$m" ]
  done
}

@test "firewall_set_mode changes only the MODE line of a legacy file and keeps its permission bits" {
  write_legacy_conf recommended
  chmod 644 "$FIREWALL_CONF"
  cp "$FIREWALL_CONF" "$TEST_TMP/before"
  firewall_set_mode disabled
  run diff "$TEST_TMP/before" "$FIREWALL_CONF"
  [ "$status" -eq 1 ]
  [ "$output" = $'1c1\n< MODE=recommended\n---\n> MODE=disabled' ]
  mode="$(stat -c '%a' "$FIREWALL_CONF" 2>/dev/null || stat -f '%Lp' "$FIREWALL_CONF")"
  [ "$mode" = "644" ]
}

@test "firewall_set_mode persists and is read back" {
  firewall_conf_ensure
  firewall_set_mode disabled
  run firewall_mode
  [ "$output" = "disabled" ]
  firewall_set_mode recommended
  run firewall_mode
  [ "$output" = "recommended" ]
}

@test "REGRESSION: firewall_set_mode preserves firewall.conf's existing permission bits" {
  firewall_conf_ensure
  chmod 644 "$FIREWALL_CONF"
  firewall_set_mode disabled
  mode="$(stat -c '%a' "$FIREWALL_CONF" 2>/dev/null || stat -f '%Lp' "$FIREWALL_CONF")"
  [ "$mode" = "644" ]
}

# Lists the temp files _firewall_set_key could have left next to the config.
leftover_temp_files() {
  find "$TEST_TMP/scripts" -name 'firewall.conf.*'
}

@test "REGRESSION: a directory at the config path is rejected and falls back to Recommended under set -u" {
  rm -f "$FIREWALL_CONF"
  mkdir "$FIREWALL_CONF"
  run firewall_parse_strict "$FIREWALL_CONF"
  [ "$status" -eq 1 ]

  # shellcheck disable=SC2016 # expanded by the inner bash, which receives $1 and $2
  run bash -c 'set -euo pipefail
    source "$1"
    rc=0
    firewall_parse_strict "$FIREWALL_CONF" 2>/dev/null || rc="$?"
    [ "$rc" -eq 1 ]
    m="$(firewall_mode 2>"$2")"
    printf "%s\n" "$m"' _ "$LIB" "$TEST_TMP/stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "recommended" ]
  grep -q 'WARNING' "$TEST_TMP/stderr"
}

@test "REGRESSION: a read-only config is rewritten whole, stays read-only, and leaves no temp file" {
  write_legacy_conf disabled
  chmod 444 "$FIREWALL_CONF"
  sed 's/^MODE=.*/MODE=recommended/' "$FIREWALL_CONF" > "$TEST_TMP/expected"
  firewall_set_mode recommended
  cmp "$TEST_TMP/expected" "$FIREWALL_CONF"
  mode="$(stat -c '%a' "$FIREWALL_CONF" 2>/dev/null || stat -f '%Lp' "$FIREWALL_CONF")"
  [ "$mode" = "444" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "REGRESSION: writing through a symlinked config takes the target's mode and leaves the target's mode alone" {
  printf 'MODE=disabled\n' > "$TEST_TMP/real"
  chmod 640 "$TEST_TMP/real"
  ln -s "$TEST_TMP/real" "$FIREWALL_CONF"
  firewall_set_mode recommended
  run firewall_mode
  [ "$output" = "recommended" ]
  # -L here too, so this keeps working if the link is ever preserved.
  mode="$(stat -L -c '%a' "$FIREWALL_CONF" 2>/dev/null || stat -L -f '%Lp' "$FIREWALL_CONF")"
  [ "$mode" = "640" ]
  mode="$(stat -c '%a' "$TEST_TMP/real" 2>/dev/null || stat -f '%Lp' "$TEST_TMP/real")"
  [ "$mode" = "640" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "REGRESSION: a failed temp-file write keeps the config byte-for-byte, returns non-zero, and removes the temp file" {
  write_legacy_conf disabled
  chmod 444 "$FIREWALL_CONF"
  cp -p "$FIREWALL_CONF" "$TEST_TMP/before"
  # The stub leaves a partial write behind, as a full disk would.
  # shellcheck disable=SC2329 # called by the library, not by the test body
  sed() { echo partial; return 1; }
  run firewall_set_mode recommended
  unset -f sed
  [ "$status" -ne 0 ]
  cmp "$TEST_TMP/before" "$FIREWALL_CONF"
  [ -z "$(leftover_temp_files)" ]
}

@test "REGRESSION: a failed mv keeps the config byte-for-byte, returns non-zero, and removes the temp file" {
  write_legacy_conf disabled
  cp -p "$FIREWALL_CONF" "$TEST_TMP/before"
  # shellcheck disable=SC2329 # called by the library, not by the test body
  mv() { return 1; }
  run firewall_set_mode recommended
  unset -f mv
  [ "$status" -ne 0 ]
  cmp "$TEST_TMP/before" "$FIREWALL_CONF"
  [ -z "$(leftover_temp_files)" ]
}

@test "REGRESSION: a read-only directory keeps the config byte-for-byte and returns non-zero" {
  [ "$(id -u)" -ne 0 ] || skip "root can create files in a mode 555 directory, so mktemp would not fail"
  write_legacy_conf disabled
  chmod 444 "$FIREWALL_CONF"
  cp -p "$FIREWALL_CONF" "$TEST_TMP/before"
  chmod 555 "$TEST_TMP/scripts"
  run firewall_set_mode recommended
  chmod 755 "$TEST_TMP/scripts"
  [ "$status" -ne 0 ]
  cmp "$TEST_TMP/before" "$FIREWALL_CONF"
  [ -z "$(leftover_temp_files)" ]
}

@test "#10: firewall_warn_unsupported notes CUSTOM_* entries and returns 0" {
  write_conf "MODE=recommended" "CUSTOM_1=example.com"
  run firewall_warn_unsupported
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE"* ]]
  [[ "$output" == *"ignored"* ]]
}

@test "#10: firewall_warn_unsupported notes SERVICE_* entries" {
  write_conf "MODE=recommended" "SERVICE_NPM=on"
  run firewall_warn_unsupported
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE"* ]]
}

@test "#10: firewall_warn_unsupported is silent for a MODE-only config" {
  write_conf "MODE=recommended"
  run firewall_warn_unsupported
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "#10: firewall_warn_unsupported ignores commented-out CUSTOM_/SERVICE_ lines" {
  write_conf "MODE=recommended" "# CUSTOM_1=example.com" "#SERVICE_NPM=on"
  run firewall_warn_unsupported
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "#10: firewall_warn_unsupported is a silent no-op when the config is missing" {
  rm -f "$FIREWALL_CONF"
  run firewall_warn_unsupported
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
