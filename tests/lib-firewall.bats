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

@test "conf_ensure creates curated Recommended defaults when missing" {
  firewall_conf_ensure
  [ -f "$FIREWALL_CONF" ]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"recommended"* ]]
}

@test "unreadable file falls back to Recommended defaults, never disabled" {
  write_conf "MODE=disabled"
  chmod 000 "$FIREWALL_CONF"
  run firewall_mode
  [[ "$output" == *"recommended"* ]]
  chmod 644 "$FIREWALL_CONF"
}

@test "malformed file falls back to Recommended defaults, never disabled" {
  write_conf "MODE=yolo"
  run firewall_mode
  [[ "$output" == *"recommended"* ]]
}

@test "a valid file with MODE=disabled is honored exactly" {
  write_conf "MODE=disabled" "SERVICE_NPM=on"
  run firewall_mode
  [ "$output" = "disabled" ]
}

@test "firewall_set_mode and firewall_set_service persist and are read back" {
  firewall_conf_ensure
  firewall_set_mode disabled
  run firewall_mode
  [ "$output" = "disabled" ]
  firewall_set_service go on
  run firewall_service_enabled go
  [ "$status" -eq 0 ]
}

@test "firewall_custom_add rejects an invalid value" {
  firewall_conf_ensure
  run firewall_custom_add "; rm -rf /"
  [ "$status" -eq 1 ]
}

@test "firewall_custom_add/remove round-trip" {
  firewall_conf_ensure
  firewall_custom_add example.com
  firewall_custom_add 10.0.0.0/24
  run firewall_custom_list
  [ "$status" -eq 0 ]
  firewall_custom_remove 1
  run firewall_custom_list
  [ "$output" = "10.0.0.0/24" ]
}

@test "firewall_restore_defaults resets to curated baseline" {
  firewall_conf_ensure
  firewall_set_mode disabled
  firewall_set_service npm off
  firewall_restore_defaults
  run firewall_mode
  [ "$output" = "recommended" ]
  run firewall_service_enabled npm
  [ "$status" -eq 0 ]
}

@test "REGRESSION: firewall_set_service preserves firewall.conf's existing permission bits" {
  firewall_conf_ensure
  chmod 644 "$FIREWALL_CONF"
  firewall_set_service npm off
  mode="$(stat -c '%a' "$FIREWALL_CONF")"
  [ "$mode" = "644" ]
}

@test "REGRESSION: firewall_set_mode preserves firewall.conf's existing permission bits" {
  firewall_conf_ensure
  chmod 644 "$FIREWALL_CONF"
  firewall_set_mode disabled
  mode="$(stat -c '%a' "$FIREWALL_CONF")"
  [ "$mode" = "644" ]
}

@test "REGRESSION: firewall_custom_remove preserves firewall.conf's existing permission bits" {
  firewall_conf_ensure
  firewall_custom_add 10.0.0.0/24
  chmod 644 "$FIREWALL_CONF"
  firewall_custom_remove 1
  mode="$(stat -c '%a' "$FIREWALL_CONF")"
  [ "$mode" = "644" ]
}
