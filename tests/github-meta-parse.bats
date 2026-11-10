#!/usr/bin/env bats
#
# Item 6 (S4), BF-P2-AC1/AC4: the GitHub /meta parser in docker/init-firewall.sh
# must emit IPv4 CIDRs ONLY from the top-level keys git/api/web/packages and
# NEVER from actions/hooks/pages/dependabot/importer/copilot/actions_macos/
# domains, regardless of whether /meta is pretty-printed or minified, and must
# exit 0 (not 1) on a body with no wanted CIDRs so the pipeline never trips
# pipefail. It uses only awk — no jq, no python3.
#
# The awk program is EXTRACTED VERBATIM from docker/init-firewall.sh at test time
# (between the `| awk '` and the closing `')"` markers) so these tests track the
# real production parser, not a copy. It is run under the system awk, which in
# this sandbox (and the image) is mawk; gawk is absent here (noted limit).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FW_SRC="$REPO_ROOT/docker/init-firewall.sh"
  FIX="$REPO_ROOT/tests/fixtures"
  PROG="$BATS_TEST_TMPDIR/parser.awk"

  # Extract the parser's awk program verbatim from the production script.
  awk "/[|] awk '/{f=1; next} /^  ')\"/{f=0} f" "$FW_SRC" > "$PROG"
  [ -s "$PROG" ] || { echo "failed to extract the awk parser from $FW_SRC"; return 1; }
}

# Run the extracted parser on a fixture file; stdout is the emitted CIDRs.
_parse() { awk -f "$PROG" "$1"; }

# --- BF-P2-AC1: only wanted-key CIDRs; zero actions/excluded-key CIDRs ---

@test "BF-P2-AC1: pretty /meta emits exactly the 8 wanted-key CIDRs (git/api/web/packages), in order" {
  run _parse "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]

  local expected=(
    "203.0.113.0/24" "203.0.113.128/25"
    "198.51.100.0/24" "198.51.100.128/25"
    "192.0.2.0/24" "192.0.2.128/25"
    "185.11.76.0/22" "140.82.121.0/24"
  )
  [ "${#lines[@]}" -eq "${#expected[@]}" ] \
    || { echo "expected ${#expected[@]} CIDRs, got ${#lines[@]}: $output"; return 1; }
  local i
  for i in "${!expected[@]}"; do
    [ "${lines[$i]}" = "${expected[$i]}" ] \
      || { echo "line $i: expected ${expected[$i]}, got ${lines[$i]}"; return 1; }
  done
}

@test "BF-P2-AC1: ZERO actions CIDRs are emitted (grep -x each of the 15 actions entries)" {
  run _parse "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]

  local actions=(
    "4.148.0.0/16" "4.149.0.0/18" "4.150.0.0/15" "4.152.0.0/14" "4.156.0.0/15"
    "4.175.0.0/16" "4.180.0.0/16" "4.207.0.0/16" "4.208.0.0/15" "4.210.0.0/17"
    "4.231.0.0/17" "4.236.0.0/17" "9.163.0.0/16" "13.64.0.0/11" "20.1.128.0/17"
  )
  local c
  for c in "${actions[@]}"; do
    printf '%s\n' "$output" | grep -qxF "$c" \
      && { echo "actions CIDR leaked into output: $c"; return 1; }
  done
  return 0
}

@test "BF-P2-AC1: ZERO CIDRs from the other excluded keys (hooks/pages/dependabot/importer/copilot/actions_macos)" {
  run _parse "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]

  local excluded=(
    "192.30.252.0/22" "185.199.108.0/22" "140.82.112.0/20"   # hooks
    "192.30.252.153/32" "192.30.252.154/32"                   # pages
    "100.20.0.0/14" "54.185.0.0/16"                           # dependabot
    "10.1.2.0/24" "10.1.3.0/24"                               # importer
    "140.82.113.0/24"                                         # copilot
    "13.64.0.0/16" "20.33.0.0/16"                             # actions_macos
  )
  local c
  for c in "${excluded[@]}"; do
    printf '%s\n' "$output" | grep -qxF "$c" \
      && { echo "excluded-key CIDR leaked into output: $c"; return 1; }
  done
  return 0
}

@test "BF-P2-AC1: a non-CIDR string under a wanted key (packages: ghcr-not/real) is dropped; no key name is printed as a value" {
  run _parse "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghcr-not/real"* ]] || { echo "bogus non-CIDR emitted"; return 1; }
  # key names must never be emitted as values
  local k
  for k in git api web packages hooks actions domains; do
    printf '%s\n' "$output" | grep -qxF "$k" && { echo "key name '$k' printed as a value"; return 1; }
  done
  return 0
}

# --- BF-P2-AC1/AC4: pretty and minified /meta give IDENTICAL output ---

@test "BF-P2-AC1: minified /meta yields output IDENTICAL to the pretty twin (formatting-agnostic)" {
  local pretty min
  pretty="$(_parse "$FIX/meta-pretty.json")"
  min="$(_parse "$FIX/meta-min.json")"
  [ "$pretty" = "$min" ] || { echo "pretty vs min differ:"; diff <(echo "$pretty") <(echo "$min"); return 1; }
}

# --- BF-P2-AC1/AC3: no-wanted-CIDR bodies emit nothing and EXIT 0 ---

@test "BF-P2-AC1: a rate-limit JSON error body emits nothing and exits 0 (awk 0-on-no-match, not grep's 1)" {
  run _parse "$FIX/meta-ratelimit.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected no output, got: $output"; return 1; }
}

@test "BF-P2-AC1: an empty body emits nothing and exits 0" {
  run _parse "$FIX/meta-empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected no output, got: $output"; return 1; }
}

# --- BF-P2-AC6 (MINOR-1): CIDR bounding — a forged/MITM catch-all or malformed
# CIDR under a WANTED key is dropped before emit (cidr_ok: 4 octets <=255, prefix
# 8..32). A /8 floor cannot drop a legitimate GitHub range (real wanted ranges
# are /20..32) but kills 0.0.0.0/0 and anything broader than /8. ---

@test "BF-P2-AC6: under wanted keys, the two in-bound CIDRs (10.0.0.0/8 edge, 140.82.112.0/20) are emitted and nothing else" {
  run _parse "$FIX/meta-cidr-bounds.json"
  [ "$status" -eq 0 ]

  # exactly the two valid CIDRs, nothing more (every invalid one dropped)
  local valid=( "10.0.0.0/8" "140.82.112.0/20" )
  [ "${#lines[@]}" -eq "${#valid[@]}" ] \
    || { echo "expected ${#valid[@]} valid CIDRs, got ${#lines[@]}: $output"; return 1; }
  local c
  for c in "${valid[@]}"; do
    printf '%s\n' "$output" | grep -qxF "$c" \
      || { echo "expected valid CIDR missing from output: $c ($output)"; return 1; }
  done
}

@test "BF-P2-AC6: every out-of-bound / too-broad CIDR under a wanted key is DROPPED (grep -xF absent)" {
  run _parse "$FIX/meta-cidr-bounds.json"
  [ "$status" -eq 0 ]

  # 0.0.0.0/0, 0.0.0.0/1, 10.0.0.0/7 -> below the /8 floor (catch-all / too broad)
  # 256.1.2.3/24, 999.0.0.0/8        -> octet > 255
  # 1.2.3.4/33                       -> prefix > 32
  local bad=(
    "0.0.0.0/0" "0.0.0.0/1" "10.0.0.0/7"
    "256.1.2.3/24" "999.0.0.0/8" "1.2.3.4/33"
  )
  local c
  for c in "${bad[@]}"; do
    printf '%s\n' "$output" | grep -qxF "$c" \
      && { echo "out-of-bound/too-broad CIDR leaked into output: $c"; return 1; }
  done
  return 0
}

@test "BF-P2-AC6: NO REGRESSION — the 8 legitimate meta-pretty.json CIDRs all still pass the new bound" {
  run _parse "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]

  local expected=(
    "203.0.113.0/24" "203.0.113.128/25"
    "198.51.100.0/24" "198.51.100.128/25"
    "192.0.2.0/24" "192.0.2.128/25"
    "185.11.76.0/22" "140.82.121.0/24"
  )
  [ "${#lines[@]}" -eq "${#expected[@]}" ] \
    || { echo "regression: expected ${#expected[@]} CIDRs, got ${#lines[@]}: $output"; return 1; }
  local c
  for c in "${expected[@]}"; do
    printf '%s\n' "$output" | grep -qxF "$c" \
      || { echo "regression: legitimate CIDR dropped by the new bound: $c"; return 1; }
  done
}

# --- BF-P2-AC4: no jq / python3 dependency; parser is pure awk ---

@test "BF-P2-AC4: init-firewall.sh references neither jq nor python3 as a command (only a comment mentions them)" {
  # strip full-line comments, then no remaining line may mention jq/python3
  run bash -c "grep -vE '^[[:space:]]*#' '$FW_SRC' | grep -cE '(jq|python3)'"
  [ "$output" -eq 0 ] || { echo "jq/python3 referenced outside a comment"; return 1; }
}

@test "BF-P2-AC4: the extracted parser invokes no external command (no awk system()/getline cmd) and runs on a PATH without jq/python3" {
  # the awk program must not shell out
  ! grep -qE 'system\(|getline[^;]*"' "$PROG" || { echo "parser shells out"; return 1; }

  # and it produces the expected output even on a PATH that contains neither
  # jq nor python3 (a directory holding only awk/grep) -> pure-awk proof
  local bindir="$BATS_TEST_TMPDIR/minbin"
  mkdir -p "$bindir"
  ln -sf "$(command -v awk)" "$bindir/awk"
  run env PATH="$bindir" awk -f "$PROG" "$FIX/meta-pretty.json"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 8 ] || { echo "expected 8 CIDRs on a jq/python3-free PATH, got ${#lines[@]}"; return 1; }
}
