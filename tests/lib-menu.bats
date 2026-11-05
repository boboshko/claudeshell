#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  MS_TEST_SCRIPT="$(mktemp)"
  cat > "$MS_TEST_SCRIPT" <<'EOS'
#!/bin/bash
source "$1/scripts/lib-menu.sh"
MS_STATE=(0 0 0)
MS_SLUGS=(ALPHA BETA GAMMA)
_toggle_log() { echo "TOGGLE $1 $2"; }
MS_ON_TOGGLE="_toggle_log"
menu_multiselect "Test Menu" "##Header" "Alpha|desc a" "Beta|desc b" "Gamma|desc g"
rc=$?
echo "RC=$rc"
echo "STATE=${MS_STATE[@]}"
EOS
  chmod +x "$MS_TEST_SCRIPT"
}

teardown() {
  rm -f "$MS_TEST_SCRIPT"
}

@test "menu_multiselect: Space toggles the first selectable item, header is skipped" {
  run bash -c "printf ' \r' | bash '$MS_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOGGLE ALPHA 1"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"STATE=1 0 0"* ]]
}

@test "menu_multiselect: arrow-down navigation skips the header and reaches later items" {
  run bash -c "printf ' \x1b[B \x1b[B \r' | bash '$MS_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOGGLE ALPHA 1"* ]]
  [[ "$output" == *"TOGGLE BETA 1"* ]]
  [[ "$output" == *"TOGGLE GAMMA 1"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"STATE=1 1 1"* ]]
}

@test "menu_multiselect: q restores the entry-time snapshot and returns 255" {
  run bash -c "printf ' \x1b[B q' | bash '$MS_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=255"* ]]
  [[ "$output" == *"STATE=0 0 0"* ]]
}

@test "menu_multiselect: Enter commits and keeps toggled state as-is" {
  run bash -c "printf ' \x1b[B \r' | bash '$MS_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"STATE=1 1 0"* ]]
}

@test "menu_select: existing behavior is unaffected by the menu_multiselect addition" {
  run bash -c "source '$DIR/scripts/lib-menu.sh'; printf '\r' | menu_select 'T' 'one' 'two' 'three'; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0"* ]]
}
