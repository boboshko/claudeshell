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

  MS_ACTION_TEST_SCRIPT="$(mktemp)"
  cat > "$MS_ACTION_TEST_SCRIPT" <<'EOS'
#!/bin/bash
source "$1/scripts/lib-menu.sh"
MS_STATE=(0 0 0)
MS_SLUGS=(ALPHA BETA GAMMA)
_toggle_log() { echo "TOGGLE $1 $2"; }
MS_ON_TOGGLE="_toggle_log"
menu_multiselect "Test Menu" "##Header" "Alpha|desc a" "Beta|desc b" "Gamma|desc g" "@@<- Back"
rc=$?
echo "RC=$rc"
echo "STATE=${MS_STATE[@]}"
EOS
  chmod +x "$MS_ACTION_TEST_SCRIPT"

  PTY_LOG="$(mktemp)"
}

teardown() {
  rm -f "$MS_TEST_SCRIPT" "$MS_ACTION_TEST_SCRIPT" "$PTY_LOG"
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

@test "menu_multiselect: '@@' action row renders without a checkbox, both unselected and under cursor" {
  run bash -c "script -qec \"bash '$MS_ACTION_TEST_SCRIPT' '$DIR' <<< ' \x1b[B \x1b[B \x1b[B\r'\" '$PTY_LOG' >/dev/null; cat -v '$PTY_LOG'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[ ] <- Back"* ]]
  [[ "$output" != *"[*] <- Back"* ]]
  [[ "$output" == *"<- Back"* ]]
}

@test "menu_multiselect: Space on the '@@' action row is a no-op and does not corrupt the last real item's state" {
  run bash -c "printf '\x1b[B\x1b[B\x1b[B \r' | bash '$MS_ACTION_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"TOGGLE"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"STATE=0 0 0"* ]]
}

@test "menu_multiselect: Space on the '@@' action row does not corrupt a real toggle made earlier in the same session" {
  run bash -c "printf '\x1b[B\x1b[B \x1b[B \r' | bash '$MS_ACTION_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"STATE=0 0 1"* ]]
  [[ "$(grep -c '^TOGGLE' <<< "$output")" -eq 1 ]]
  [[ "$output" == *"TOGGLE GAMMA 1"* ]]
}

@test "menu_multiselect: Enter confirms (rc=0) with the cursor sitting on the '@@' action row" {
  run bash -c "printf '\x1b[B\x1b[B\x1b[B\r' | bash '$MS_ACTION_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=0"* ]]
}

@test "menu_multiselect: arrow navigation wraps through the '@@' action row without getting stuck" {
  run bash -c "printf '\x1b[B\x1b[B\x1b[B\x1b[B \r' | bash '$MS_ACTION_TEST_SCRIPT' '$DIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOGGLE ALPHA 1"* ]]
  [[ "$output" == *"STATE=1 0 0"* ]]
}

@test "menu_multiselect: smcup/civis are emitted once at entry and cnorm/rmcup once at exit, correctly paired" {
  run bash -c "script -qec \"bash '$MS_TEST_SCRIPT' '$DIR' <<< ' \x1b[B \r'\" '$PTY_LOG' >/dev/null; cat -v '$PTY_LOG'"
  [ "$status" -eq 0 ]
  local smcup_count rmcup_count civis_count cnorm_count
  smcup_count="$(grep -o '\[?1049h' <<< "$output" | wc -l)"
  rmcup_count="$(grep -o '\[?1049l' <<< "$output" | wc -l)"
  civis_count="$(grep -o '\[?25l' <<< "$output" | wc -l)"
  cnorm_count="$(grep -o '\[?25h\|\[?12l\[?25h\|\[34h\[?25h' <<< "$output" | wc -l)"
  [ "$smcup_count" -eq 1 ]
  [ "$rmcup_count" -eq 1 ]
  [ "$civis_count" -eq 1 ]
  [ "$cnorm_count" -ge 1 ]
  local smcup_pos rmcup_pos
  smcup_pos="$(grep -bo '\[?1049h' <<< "$output" | head -1 | cut -d: -f1)"
  rmcup_pos="$(grep -bo '\[?1049l' <<< "$output" | head -1 | cut -d: -f1)"
  [ "$smcup_pos" -lt "$rmcup_pos" ]
}

@test "menu_multiselect: every redraw uses absolute cup(0,0)+ed, never relative cursor-up sequences" {
  run bash -c "script -qec \"bash '$MS_TEST_SCRIPT' '$DIR' <<< ' \x1b[B \x1b[A \r'\" '$PTY_LOG' >/dev/null; cat -v '$PTY_LOG'"
  [ "$status" -eq 0 ]
  local cup_count ed_count cuu_count
  cup_count="$(grep -o '\[1;1H' <<< "$output" | wc -l)"
  ed_count="$(grep -o '\[J' <<< "$output" | wc -l)"
  cuu_count="$(grep -o '\[1A' <<< "$output" | wc -l)"
  [ "$cup_count" -ge 4 ]
  [ "$ed_count" -ge 4 ]
  [ "$cuu_count" -eq 0 ]
}

@test "_tools_build_items-style count-mismatch guard fires on a mismatched items/slugs pair" {
  local fixture
  fixture="$(mktemp)"
  cat > "$fixture" <<'EOS'
#!/bin/bash
_build_items() {
  TOOLS_ITEMS=()
  TOOLS_SLUGS=()
  TOOLS_ITEMS+=("##Header")
  TOOLS_ITEMS+=("Row One")
  TOOLS_SLUGS+=("ROW_ONE")
  TOOLS_ITEMS+=("Row Two")
  TOOLS_ITEMS+=("@@<- Back")

  local row_count=0
  local item
  for item in "${TOOLS_ITEMS[@]}"; do
    case "$item" in
      "##"*|"@@"*) ;;
      *) row_count=$((row_count + 1)) ;;
    esac
  done
  if [ "$row_count" -ne "${#TOOLS_SLUGS[@]}" ]; then
    echo "[tools] INTERNAL ERROR: TOOLS_ITEMS/TOOLS_SLUGS count mismatch ($row_count vs ${#TOOLS_SLUGS[@]}) — a tool row is missing its slug or vice versa." >&2
    return 1
  fi
}
if ! _build_items; then
  exit 1
fi
echo "GUARD DID NOT FIRE"
EOS
  chmod +x "$fixture"
  run bash "$fixture"
  rm -f "$fixture"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTERNAL ERROR"* ]]
  [[ "$output" == *"count mismatch (2 vs 1)"* ]]
  [[ "$output" != *"GUARD DID NOT FIRE"* ]]
}
