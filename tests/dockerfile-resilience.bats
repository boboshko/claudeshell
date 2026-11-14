#!/usr/bin/env bats
# Pass 3 — docker build network resilience. Static + behavioural tests for the
# three retry helpers (apt-retry, fetch-retry, run-retry) and the rewritten RUN
# step bodies in docker/Dockerfile. No Docker daemon: the code under test is
# extracted from the Dockerfile's own text and run under dash with stubs. See
# tests/helpers/dockerfile.bash (safety rules D-6.5) and dev-plan sections 5.1-5.3.
#
# Expected package / URL lists below are literals taken from dev-plan section 4
# and verified against the current Dockerfile.

load helpers/dockerfile

bats_require_minimum_version 1.5.0

setup() { df_setup; }

# Expected apt package multiset across the 21 apt-retry call sites (31 tokens;
# gnupg x4 = the 4 third-party-repo tool steps). Sorted for a stable compare.
EXPECTED_PKGS="build-essential ca-certificates clang cmake curl default-jdk dnsutils docker-ce-cli docker-compose-plugin gh git gnupg gnupg gnupg gnupg iproute2 ipset iptables jq make mongodb-mongosh openssh-client postgresql-client python3 python3-pip python3-venv redis-tools rsync sudo unzip wget"

# Expected https URL set (sorted-unique, as `grep -oE 'https://[^ "]+'` yields;
# $(dpkg ...) truncates at the space, which is fine and stable).
EXPECTED_URLS="https://astral.sh/uv/install.sh
https://bun.sh/install
https://cli.github.com/packages
https://cli.github.com/packages/githubcli-archive-keyring.gpg
https://download.docker.com/linux/debian
https://download.docker.com/linux/debian/gpg
https://github.com/boboshko/claudeshell
https://github.com/mikefarah/yq/releases/latest/download/yq_linux_\$(dpkg
https://go.dev/dl/go1.23.4.linux-\$(dpkg
https://pgp.mongodb.com/server-7.0.asc
https://repo.mongodb.org/apt/debian
https://sh.rustup.rs"

# ===========================================================================
# 5.1 Static checks (Q-2)
# ===========================================================================

@test "AC1[S]: apt-get is invoked only inside the apt-retry helper definition" {
  # Exactly one joined instruction mentions apt-get, and it is the apt-retry def.
  run grep -c 'apt-get' "$DF_INSTR"
  [ "$output" -eq 1 ]
  run grep -F 'apt-get' "$DF_INSTR"
  [[ "$output" == *"> /usr/local/bin/apt-retry"* ]]
}

@test "AC1[S]: exactly 21 apt-retry call sites in the Dockerfile" {
  run grep -cE '^(RUN )?[[:space:]]*apt-retry ' "$DOCKERFILE"
  [ "$output" -eq 21 ]
}

@test "AC1[S]: installed package multiset equals the fixed expected list" {
  actual="$(grep -v '> /usr/local/bin/' "$DF_INSTR" \
    | grep -oE 'apt-retry [^&;]*' | sed 's/^apt-retry //' \
    | tr ' ' '\n' | grep -vE '^$' | sort | tr '\n' ' ' | sed 's/ $//')"
  expected="$(printf '%s' "$EXPECTED_PKGS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$actual" = "$expected" ]
}

@test "AC1[S]: --no-install-recommends in the helper and 17 apt-list cleanups" {
  run grep -F -- '--no-install-recommends' "$DF_INSTR"
  [[ "$output" == *"> /usr/local/bin/apt-retry"* ]]
  run grep -c 'rm -rf /var/lib/apt/lists/\*' "$DOCKERFILE"
  [ "$output" -eq 17 ]
}

@test "AC3[S]: no fetch-retry output is piped; every call site redirects with >" {
  # No `fetch-retry ... |` anywhere in the Dockerfile.
  run grep -nE 'fetch-retry[^>]*\|' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  # 9 call sites (fetch-retry URL), and every one of them redirects with `>`.
  run grep -cE 'fetch-retry "?https' "$DOCKERFILE"
  [ "$output" -eq 9 ]
  n_redir="$(grep -E 'fetch-retry "?https' "$DOCKERFILE" | grep -c '>')"
  [ "$n_redir" -eq 9 ]
}

@test "AC5[S]: RUST step keeps args, run-retry and cargo/rustc post-conditions" {
  body="$(df_tool_body RUST)"
  [[ "$body" == *"-y --no-modify-path --default-toolchain stable"* ]]
  [[ "$body" == *"run-retry "* ]]
  [[ "$body" == *"/usr/local/cargo/bin/cargo --version"* ]]
  [[ "$body" == *"/usr/local/cargo/bin/rustc --version"* ]]
}

@test "AC5[S]: BUN step uses bash, run-retry and the bun post-condition" {
  body="$(df_tool_body BUN)"
  [[ "$body" == *"run-retry "* ]]
  [[ "$body" == *'bash "$tmp"'* ]]
  [[ "$body" == *"/usr/local/bun/bin/bun --version"* ]]
}

@test "AC5[S]: UV step keeps UV_INSTALL_DIR, run-retry and the uv post-condition" {
  body="$(df_tool_body UV)"
  [[ "$body" == *"UV_INSTALL_DIR=/usr/local/bin"* ]]
  [[ "$body" == *"run-retry "* ]]
  [[ "$body" == *"/usr/local/bin/uv --version"* ]]
}

@test "AC6[S]: both npm loops keep 5 attempts, the fetch-retry flags and exit 1" {
  run grep -c 'for attempt in 1 2 3 4 5' "$DOCKERFILE"
  [ "$output" -eq 2 ]
  run grep -c -- '--fetch-retries=5' "$DOCKERFILE"
  [ "$output" -eq 2 ]
  run grep -c -- '--fetch-retry-mintimeout=10000' "$DOCKERFILE"
  [ "$output" -eq 2 ]
  run grep -c -- '--fetch-retry-maxtimeout=60000' "$DOCKERFILE"
  [ "$output" -eq 2 ]
}

@test "AC6[S]: fetch-retry body keeps mktemp, curl -f, retry flags, trap, cleanup" {
  body="$(df_helper_body fetch-retry)"
  [[ "$body" == *"mktemp"* ]]
  [[ "$body" == *"curl -fsSL"* ]]
  [[ "$body" == *"--retry 5"* ]]
  [[ "$body" == *"--retry-all-errors"* ]]
  [[ "$body" == *"--connect-timeout 30"* ]]
  [[ "$body" == *"trap cleanup EXIT"* ]]
  [[ "$body" == *"rm -f"* ]]
}

@test "AC8[S]: no pipefail/[[/function/<(/arrays and no SHELL instruction" {
  run grep -nE 'pipefail|\[\[|function |<\(' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  run grep -nE '^[[:space:]]*[A-Za-z_]+=\(' "$DOCKERFILE"
  [ "$status" -ne 0 ]
  run grep -nE '^SHELL ' "$DOCKERFILE"
  [ "$status" -ne 0 ]
}

@test "AC8[S]: each generated helper passes dash -n (syntax)" {
  df_behaviour_init
  for name in apt-retry fetch-retry run-retry; do
    run "$DF_SH" -n "$HELPERS/$name"
    [ "$status" -eq 0 ]
  done
}

@test "AC9[S]: ARG TOOL_* set equals lib-tools slugs and compose args (21 each)" {
  df_tool="$(grep -oE '^ARG TOOL_[A-Z_]+=0' "$DOCKERFILE" | sed 's/^ARG TOOL_//; s/=0$//' | sort | tr '\n' ' ')"
  slugs="$(sed -n 's/^TOOLS_BUILD_ARG_SLUGS=(\(.*\))/\1/p' "$REPO_ROOT/scripts/lib-tools.sh" | tr ' ' '\n' | sort | tr '\n' ' ')"
  compose="$(grep -oE '^[[:space:]]+TOOL_[A-Z_]+:' "$REPO_ROOT/docker/docker-compose.yml" | sed 's/.*TOOL_//; s/:$//' | sort | tr '\n' ' ')"
  [ "$df_tool" = "$slugs" ]
  [ "$df_tool" = "$compose" ]
  run grep -cE '^ARG TOOL_[A-Z_]+=0' "$DOCKERFILE"
  [ "$output" -eq 21 ]
}

@test "AC9[S]: ordering helper-defs < base apt < CACHE_BUST < claude npm; 5 COPY" {
  l_apt="$(grep -n '> /usr/local/bin/apt-retry' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  l_fetch="$(grep -n '> /usr/local/bin/fetch-retry' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  l_run="$(grep -n '> /usr/local/bin/run-retry' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  l_base="$(grep -nE '^RUN apt-retry ' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  l_bust="$(grep -n '^ARG CACHE_BUST' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  l_npm="$(grep -n 'claude-code@' "$DOCKERFILE" | head -1 | cut -d: -f1)"
  [ "$l_apt" -lt "$l_fetch" ]
  [ "$l_fetch" -lt "$l_run" ]
  [ "$l_run" -lt "$l_base" ]
  [ "$l_base" -lt "$l_bust" ]
  [ "$l_bust" -lt "$l_npm" ]
  run grep -cE '^COPY ' "$DOCKERFILE"
  [ "$output" -eq 5 ]
}

@test "AC10[S]: extracted https URL set equals the fixed expected set" {
  actual="$(grep -oE 'https://[^ "]+' "$DOCKERFILE" | sort -u)"
  expected="$(printf '%s\n' "$EXPECTED_URLS")"
  [ "$actual" = "$expected" ]
}

@test "AC10[S]: no insecure flags, no http://, no || true after a command" {
  run grep -nE -- '--insecure| -k |allow-unauthenticated|AllowInsecure|trusted=yes|http://|\|\| true' "$DOCKERFILE"
  [ "$status" -ne 0 ]
}

@test "AC8: the shell under test is dash by absolute path (reported)" {
  [ -x "$DF_SH" ]
  case "$DF_SH" in /*) : ;; *) false ;; esac
  echo "shell under test: $DF_SH ($DF_SH_NAME)" >&3
}

# ===========================================================================
# 5.2 Behavioural helper tests (Q-3) — apt-retry
# ===========================================================================

@test "AC2[B]-a: apt-retry install fails twice then succeeds -> rc0, 3 updates" {
  df_behaviour_init
  APT_FAIL_INSTALLS=2 run df_run_helper apt-retry gitpkg
  [ "$status" -eq 0 ]
  [ "$(df_log_count '^apt-get .*update')" -eq 3 ]
  [ "$(df_log_count '^apt-get .*install')" -eq 3 ]
  [ "$(df_log_count 'attempt [0-9]/5 failed')" -eq 0 ] # retry lines go to stderr
  [[ "$output" == *"attempt 1/5 failed"* ]]
  [[ "$output" == *"attempt 2/5 failed"* ]]
  [ "$(df_sleep_args)" = "5 10 " ]
}

@test "AC2[B]-b: a fresh apt-get update precedes every install attempt" {
  df_behaviour_init
  APT_FAIL_INSTALLS=1 run df_run_helper apt-retry onlypkg
  [ "$status" -eq 0 ]
  # The stub log must alternate update,install,update,install (never two installs
  # in a row without an update between them).
  seq="$(sed -nE 's/^apt-get .*(update|install).*/\1/p' "$STUB_LOG" | tr '\n' ' ')"
  [ "$seq" = "update install update install " ]
}

@test "AC2[B]-c: apt-retry always failing -> rc1 after 5 installs, names packages" {
  df_behaviour_init
  APT_FAIL_INSTALLS=99 run df_run_helper apt-retry alpha beta
  [ "$status" -eq 1 ]
  [ "$(df_log_count '^apt-get .*install')" -eq 5 ]
  [ "$(printf '%s\n' "$output" | grep -cE 'attempt [1-5]/5 failed')" -eq 5 ]
  [[ "$output" == *"attempt 5/5 failed"* ]]
  [[ "$output" == *"giving up"* ]]
  [[ "$output" == *"alpha beta"* ]]
  [ "$(df_sleep_args)" = "5 10 15 20 " ]   # no sleep after the 5th failure
}

@test "AC2[B]-d: apt-retry first-try success -> rc0, 1 update + 1 install, no sleep" {
  df_behaviour_init
  run --separate-stderr df_run_helper apt-retry onepkg
  [ "$status" -eq 0 ]
  [ "$(df_log_count '^apt-get .*update')" -eq 1 ]
  [ "$(df_log_count '^apt-get .*install')" -eq 1 ]
  [ "$(df_log_count '^sleep')" -eq 0 ]
  [ -z "$stderr" ]
}

@test "AC2[B]: apt-retry with no args -> rc2 usage" {
  df_behaviour_init
  run df_run_helper apt-retry
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: apt-retry"* ]]
}

# --- fetch-retry ---

@test "AC3[B]/AC4[B]: fetch-retry download fails -> rc1, empty stdout, names URL" {
  df_behaviour_init
  CURL_MODE=fail run --separate-stderr df_run_helper fetch-retry https://bun.sh/install
  [ "$status" -eq 1 ]
  [ -z "$output" ]                                   # nothing on stdout
  [[ "$stderr" == *"download failed: https://bun.sh/install"* ]]
  [ "$(df_log_count 'curl .*-fsSL')" -ge 1 ]
  [[ "$(df_log)" == *"--retry 5"* ]]
  [[ "$(df_log)" == *"--retry-all-errors"* ]]
}

@test "AC4[B]: fetch-retry empty (0-byte) body -> rc1 with message, no temp left" {
  df_behaviour_init
  CURL_MODE=empty run --separate-stderr df_run_helper fetch-retry https://cli.github.com/packages/githubcli-archive-keyring.gpg
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"empty response (0 bytes)"* ]]
  [ -z "$(ls -A "$DF_TMP")" ]                         # temp file cleaned up
}

@test "AC3[B]: fetch-retry payload (NUL, no trailing newline) -> rc0, byte-identical" {
  df_behaviour_init
  printf 'ab\000cd' > "$DF_WORK/payload.bin"          # 5 bytes incl. a NUL
  CURL_PAYLOAD="$DF_WORK/payload.bin" CURL_MODE=payload \
    df_run_helper fetch-retry https://sh.rustup.rs > "$DF_WORK/out.bin" 2>"$DF_WORK/err"
  rc=$?
  [ "$rc" -eq 0 ]
  cmp "$DF_WORK/payload.bin" "$DF_WORK/out.bin"
  [ -z "$(ls -A "$DF_TMP")" ]
}

# --- run-retry ---

@test "AC5[B]: run-retry fails twice then OK -> rc0 after 3 runs, spaces intact" {
  df_behaviour_init
  _make_flaky 2
  run df_run_helper run-retry "demo installer (example.com)" "$DF_WORK/flaky" "a b" c
  [ "$status" -eq 0 ]
  [ "$(df_log_count '^flaky ')" -eq 3 ]
  [[ "$(df_log)" == *"flaky args=[a b][c]"* ]]        # "a b" stayed one argument
}

@test "AC5[B]/AC7[B]: run-retry always failing -> rc1 after 5 runs, names label" {
  df_behaviour_init
  _make_flaky 99
  run df_run_helper run-retry "uv installer (astral.sh, github.com)" "$DF_WORK/flaky"
  [ "$status" -eq 1 ]
  [ "$(df_log_count '^flaky ')" -eq 5 ]
  [[ "$output" == *"uv installer (astral.sh, github.com)"* ]]
  [[ "$output" == *"giving up"* ]]
  [ "$(df_sleep_args)" = "5 10 15 20 " ]
}

@test "AC7[B]: run-retry first-try success -> rc0, no sleep, empty stderr" {
  df_behaviour_init
  _make_flaky 0
  run --separate-stderr df_run_helper run-retry "ok (host)" "$DF_WORK/flaky"
  [ "$status" -eq 0 ]
  [ "$(df_log_count '^sleep')" -eq 0 ]
  [ -z "$stderr" ]
}

@test "AC5[B]: run-retry removes RETRY_CLEAN before retries, not before attempt 1" {
  df_behaviour_init
  mkdir -p "$DF_SB/usr/local/bun"                     # pre-existing, like a partial install
  _make_flaky 2 "$DF_SB/usr/local/bun"
  RETRY_CLEAN="$DF_SB/usr/local/bun" run df_run_helper run-retry "bun (host)" "$DF_WORK/flaky"
  [ "$status" -eq 0 ]
  # attempt 1 saw the dir (untouched), attempts 2 and 3 saw it removed.
  seq="$(sed -nE 's/^flaky clean=(present|absent)/\1/p' "$STUB_LOG" | tr '\n' ' ')"
  [ "$seq" = "present absent absent " ]
}

@test "AC5[B]: run-retry relative RETRY_CLEAN -> rc2, command never runs" {
  df_behaviour_init
  _make_flaky 0
  RETRY_CLEAN="relative/dir" run df_run_helper run-retry "x (host)" "$DF_WORK/flaky"
  [ "$status" -eq 2 ]
  [ "$(df_log_count '^flaky ')" -eq 0 ]
  [[ "$output" == *"must be absolute paths"* ]]
}

@test "AC7[B]: budget — a 5-fail run sleeps 5,10,15,20 (sum 50 <= 60)" {
  df_behaviour_init
  APT_FAIL_INSTALLS=99 run df_run_helper apt-retry pkg
  [ "$status" -eq 1 ]
  args="$(df_sleep_args)"
  [ "$args" = "5 10 15 20 " ]
  sum=0; for s in $args; do sum=$((sum + s)); done
  [ "$sum" -le 60 ]
}

# ===========================================================================
# 5.3 Behavioural step-body tests (Q-4)
# ===========================================================================

# failing curl: rc != 0, the consumer stub is never invoked, stderr names the URL.

@test "AC3[B]: DOCKER_CLI failing download -> rc!=0, gpg never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step DOCKER_CLI 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^gpg ')" -eq 0 ]
  [[ "$output" == *"download.docker.com/linux/debian/gpg"* ]]
}

@test "AC3[B]: DOCKER_COMPOSE failing download -> rc!=0, gpg never runs" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step DOCKER_COMPOSE 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^gpg ')" -eq 0 ]
  [[ "$output" == *"download.docker.com/linux/debian/gpg"* ]]
}

@test "AC3[B]: GO failing download -> rc!=0, tar never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step GO 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^tar ')" -eq 0 ]
  [[ "$output" == *"go.dev/dl/go1.23.4"* ]]
}

@test "AC3[B]: RUST failing download -> rc!=0, installer never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step RUST 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^sh ')" -eq 0 ]
  [[ "$output" == *"sh.rustup.rs"* ]]
}

@test "AC3[B]: MONGODB failing download -> rc!=0, gpg never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step MONGODB 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^gpg ')" -eq 0 ]
  [[ "$output" == *"pgp.mongodb.com/server-7.0.asc"* ]]
}

@test "AC3[B]: BUN failing download -> rc!=0, bash never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step BUN 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^bash ')" -eq 0 ]
  [[ "$output" == *"bun.sh/install"* ]]
}

@test "AC3[B]: UV failing download -> rc!=0, installer never runs, names URL" {
  df_behaviour_init
  CURL_MODE=fail run df_run_step UV 1
  [ "$status" -ne 0 ]
  [ "$(df_log_count '^env ')" -eq 0 ]
  [ "$(df_log_count '^sh ')" -eq 0 ]
  [[ "$output" == *"astral.sh/uv/install.sh"* ]]
}

# installer post-condition: rc0 installer with no binary fails; with binary passes.

@test "AC5[B]: BUN installer returns 0 but creates no binary -> rc!=0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 run df_run_step BUN 1
  [ "$status" -ne 0 ]
}

@test "AC5[B]: BUN installer that creates the binary -> rc0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 INSTALLER_CREATE="$DF_SB/usr/local/bun/bin/bun" \
    run df_run_step BUN 1
  [ "$status" -eq 0 ]
}

@test "AC5[B]: RUST installer returns 0 but creates no binary -> rc!=0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 run df_run_step RUST 1
  [ "$status" -ne 0 ]
}

@test "AC5[B]: RUST installer that creates cargo and rustc -> rc0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 \
    INSTALLER_CREATE="$DF_SB/usr/local/cargo/bin/cargo $DF_SB/usr/local/cargo/bin/rustc" \
    INSTALLER_MKDIR="$DF_SB/usr/local/rustup" \
    run df_run_step RUST 1
  [ "$status" -eq 0 ]
}

@test "AC5[B]: UV installer returns 0 but creates no binary -> rc!=0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 run df_run_step UV 1
  [ "$status" -ne 0 ]
}

@test "AC5[B]: UV installer that creates the binary -> rc0" {
  df_behaviour_init
  CURL_MODE=payload INSTALLER_RC=0 INSTALLER_CREATE="$DF_SB/usr/local/bin/uv" \
    run df_run_step UV 1
  [ "$status" -eq 0 ]
}

# guard off (TOOL_X=0): rc0, zero stub calls — one per step shape.

@test "UC-9: DOCKER_CLI disabled -> rc0, no stub invoked (fetch/gpg shape)" {
  df_behaviour_init
  run df_run_step DOCKER_CLI 0
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "UC-9: BUN disabled -> rc0, no stub invoked (installer shape)" {
  df_behaviour_init
  run df_run_step BUN 0
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "UC-9: PYTHON disabled -> rc0, no stub invoked (apt-only shape)" {
  df_behaviour_init
  run df_run_step PYTHON 0
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

# one full happy path proves the rewritten step reaches its last command.

@test "UC-1: DOCKER_CLI happy path -> rc0, repo list written, package installed" {
  df_behaviour_init
  CURL_MODE=payload run df_run_step DOCKER_CLI 1
  [ "$status" -eq 0 ]
  [ -f "$DF_SB/etc/apt/sources.list.d/docker.list" ]
  [[ "$(df_log)" == *"install -y --no-install-recommends docker-ce-cli"* ]]
}

# --- test-local helper: a flaky command that fails its first N runs -----------
# Usage: _make_flaky N [CLEANDIR]. Writes $DF_WORK/flaky which logs its args
# (each bracketed), optionally records whether CLEANDIR exists at entry, then
# exits non-zero for its first N invocations and 0 thereafter.
_make_flaky() {
  local n="$1" cleandir="${2:-}"
  cat > "$DF_WORK/flaky" <<EOF
#!/bin/sh
{ printf 'flaky args='; for a in "\$@"; do printf '[%s]' "\$a"; done; printf '\n'; } >> "$STUB_LOG"
EOF
  if [ -n "$cleandir" ]; then
    cat >> "$DF_WORK/flaky" <<EOF
if [ -d "$cleandir" ]; then echo "flaky clean=present" >> "$STUB_LOG"; else echo "flaky clean=absent" >> "$STUB_LOG"; fi
EOF
  fi
  cat >> "$DF_WORK/flaky" <<EOF
c=0; [ -f "$DF_WORK/flaky.ctr" ] && c=\$(cat "$DF_WORK/flaky.ctr")
c=\$((c + 1)); printf '%s' "\$c" > "$DF_WORK/flaky.ctr"
[ "\$c" -le "$n" ] && exit 3
exit 0
EOF
  chmod +x "$DF_WORK/flaky"
}
