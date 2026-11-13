#!/usr/bin/env bash
# Shared helper for tests/dockerfile-resilience.bats (pass 3 — docker build
# network resilience). Lets the bats suite exercise the retry helpers and the
# rewritten RUN step bodies that live INSIDE docker/Dockerfile, with no Docker
# daemon: the code under test is extracted from the Dockerfile's own text (never
# a copy that can drift), the three helpers are materialised by the same
# `printf ... > file` their RUN uses, and everything runs under dash with stubs
# on a narrowed PATH inside a per-test sandbox.
#
# SAFETY (design D-6.5, same spirit as tests/helpers/enforcement.bash):
#  1. Behavioural PATH contains ONLY the stub dir, so real apt-get/curl/gpg/tar/
#     sh/bash/env/sudo can never be reached (an un-stubbed command fails 127).
#  2. A rewritten step body is executed ONLY after df_assert_sandboxed proves no
#     absolute path outside the sandbox root survived the path rewrite; this is
#     what keeps `rm -rf /var/lib/apt/lists/*`, `> /etc/apt/...` and
#     `. /etc/os-release` inside the sandbox even when the suite runs as root.
#  3. The shell under test is invoked by ABSOLUTE path ($DF_SH); with a stub-only
#     PATH a bare `dash` would not be found.
#  4. Stubs use shell builtins or real binaries symlinked into the stub dir and
#     resolved with `type -P` BEFORE the PATH is narrowed; no stub relies on PATH.
#  5. TMPDIR points inside the per-test dir; the sandbox root is pre-populated
#     with what a real image has (etc/os-release, etc/apt/..., usr/local/bin,
#     var/lib/apt/lists).
#  6. In step-body tests the three helpers are reached through PATH as wrappers
#     that run the GENERATED helper file with $DF_SH, so the host's /bin/sh does
#     not silently replace dash via the shebang.

# ---------------------------------------------------------------------------
# df_setup — cheap, run from bats setup(). Locates the Dockerfile, picks the
# shell under test, and caches the joined instruction list. No sandbox yet.
# ---------------------------------------------------------------------------
df_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOCKERFILE="$REPO_ROOT/docker/Dockerfile"
  export REPO_ROOT DOCKERFILE

  # Shell under test: dash by absolute path if present, else sh. Reported by the
  # suite (df_shell_name).
  local d
  d="$(type -P dash 2>/dev/null || true)"
  if [ -n "$d" ]; then
    DF_SH="$d"; DF_SH_NAME="dash"
  else
    DF_SH="$(type -P sh 2>/dev/null || echo /bin/sh)"; DF_SH_NAME="sh"
  fi
  export DF_SH DF_SH_NAME

  DF_INSTR="$BATS_TEST_TMPDIR/instructions.txt"
  df_join_instructions < "$DOCKERFILE" > "$DF_INSTR"
  export DF_INSTR
}

# ---------------------------------------------------------------------------
# df_join_instructions — reproduce what the Dockerfile parser does with a
# multi-line instruction: a trailing `\` continues the line; a full-line `#`
# comment inside a continuation is dropped; the pieces are concatenated. One
# logical instruction is emitted per output line (newlines removed), which makes
# a single instruction trivially greppable. Pure awk; no GNU-only features.
# ---------------------------------------------------------------------------
df_join_instructions() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)                         # tolerate stray CR
      if (cont) {
        if (line ~ /^[[:space:]]*#/) next          # comment inside continuation
        if (line ~ /\\[[:space:]]*$/) {
          sub(/[[:space:]]*\\[[:space:]]*$/, " ", line)
          buf = buf line
        } else {
          buf = buf line; print buf; cont = 0; buf = ""
        }
        next
      }
      if (line ~ /^[[:space:]]*#/) next             # standalone comment
      if (line ~ /^[[:space:]]*$/) next             # blank
      if (line ~ /\\[[:space:]]*$/) {
        sub(/[[:space:]]*\\[[:space:]]*$/, " ", line)
        buf = line; cont = 1
      } else {
        print line
      }
    }
  '
}

# ---------------------------------------------------------------------------
# Extractors — all read $DF_INSTR (the joined instructions) and print the RUN
# body (text after the leading `RUN `) of the requested instruction.
# ---------------------------------------------------------------------------

# df_helper_body NAME  (apt-retry | fetch-retry | run-retry)
df_helper_body() {
  local name="$1" line
  line="$(grep -F "> /usr/local/bin/$name " "$DF_INSTR" | head -1)"
  if [ -z "$line" ]; then
    echo "df_helper_body: no RUN defines /usr/local/bin/$name" >&2
    return 1
  fi
  printf '%s\n' "${line#RUN }"
}

# df_tool_body SLUG  — the first RUN after `ARG TOOL_SLUG=0`
df_tool_body() {
  local slug="$1" line
  line="$(awk -v s="ARG TOOL_${slug}=0" '
    $0 == s { f = 1; next }
    f && /^RUN / { print; exit }
  ' "$DF_INSTR")"
  if [ -z "$line" ]; then
    echo "df_tool_body: no RUN after ARG TOOL_${slug}=0" >&2
    return 1
  fi
  printf '%s\n' "${line#RUN }"
}

# df_base_body — the `RUN apt-retry ...` base step before `ARG CACHE_BUST`
df_base_body() {
  local line
  line="$(awk '
    /^ARG CACHE_BUST/ { exit }
    /^RUN apt-retry / { print; exit }
  ' "$DF_INSTR")"
  if [ -z "$line" ]; then
    echo "df_base_body: base apt-retry RUN not found before ARG CACHE_BUST" >&2
    return 1
  fi
  printf '%s\n' "${line#RUN }"
}

# ---------------------------------------------------------------------------
# df_behaviour_init — build the per-test sandbox: stub dir, real-tool symlinks,
# stubs, helper wrappers, materialised helpers, pre-populated sandbox root,
# TMPDIR. Called at the top of every behavioural test.
# ---------------------------------------------------------------------------
df_behaviour_init() {
  DF_WORK="$BATS_TEST_TMPDIR/work"
  HELPERS="$DF_WORK/helpers"
  STUBS="$DF_WORK/stubs"
  DF_SB="$DF_WORK/root"            # sandbox filesystem root
  DF_TMP="$DF_WORK/tmp"            # TMPDIR for the code under test
  STUB_LOG="$DF_WORK/stub.log"
  export DF_WORK HELPERS STUBS DF_SB DF_TMP STUB_LOG
  mkdir -p "$HELPERS" "$STUBS" "$DF_SB" "$DF_TMP"
  : > "$STUB_LOG"

  df_link_real_tools
  df_write_stubs
  df_write_wrappers
  df_materialise_helpers
  df_prepopulate_root
}

# Resolve harmless real binaries the code under test needs and symlink them into
# the stub dir, BEFORE any PATH is narrowed (rule D-6.5-4).
df_link_real_tools() {
  local t p
  for t in mktemp cat rm chmod mkdir install ln cp sed; do
    p="$(type -P "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$STUBS/$t"
  done
}

# df_write_stubs — every stub appends "<name> <args>" to $STUB_LOG. None relies
# on PATH for its own tooling (builtins + the symlinks above only).
df_write_stubs() {
  # apt-get: `update` always succeeds; each `install` increments a counter file
  # and fails while the counter is <= $APT_FAIL_INSTALLS (default 0 = never).
  cat > "$STUBS/apt-get" <<'STUB'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$STUB_LOG"
mode=other
for a in "$@"; do
  case "$a" in update) mode=update ;; install) mode=install ;; esac
done
if [ "$mode" = install ]; then
  n=0; [ -f "$DF_WORK/apt.ctr" ] && n=$(cat "$DF_WORK/apt.ctr")
  n=$((n + 1)); printf '%s' "$n" > "$DF_WORK/apt.ctr"
  if [ "$n" -le "${APT_FAIL_INSTALLS:-0}" ]; then
    echo "E: Unable to locate package" >&2
    exit 100
  fi
fi
exit 0
STUB

  # curl: parses `-o FILE`; CURL_MODE = fail (rc 7) | empty (0-byte file) |
  # payload (copy $CURL_PAYLOAD, default a small body).
  cat > "$STUBS/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
case "${CURL_MODE:-payload}" in
  fail)  echo "curl: (7) Failed to connect to host" >&2; exit 7 ;;
  empty) [ -n "$out" ] && : > "$out"; exit 0 ;;
  *)     if [ -n "${CURL_PAYLOAD:-}" ]; then cat "$CURL_PAYLOAD" > "$out";
         else printf 'PAYLOAD' > "$out"; fi; exit 0 ;;
esac
STUB

  # sleep: record the argument, return at once (time is neutralised).
  cat > "$STUBS/sleep" <<'STUB'
#!/bin/sh
printf 'sleep %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB

  # gpg / tar: consumer recorders. gpg honours `-o FILE` so the key-import happy
  # path can proceed; tar just records.
  cat > "$STUBS/gpg" <<'STUB'
#!/bin/sh
printf 'gpg %s\n' "$*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : > "$out"
exit 0
STUB
  cat > "$STUBS/tar" <<'STUB'
#!/bin/sh
printf 'tar %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB

  # Installer stand-ins (sh / bash / env). INSTALLER_RC (default 0) is the exit
  # code; INSTALLER_CREATE is a whitespace-separated list of absolute paths to
  # create as executables (used to satisfy / fail the post-condition).
  local interp
  for interp in sh bash env; do
    cat > "$STUBS/$interp" <<STUB
#!/bin/sh
printf '$interp %s\n' "\$*" >> "\$STUB_LOG"
for d in \${INSTALLER_MKDIR:-}; do mkdir -p "\$d" 2>/dev/null || true; done
for p in \${INSTALLER_CREATE:-}; do
  d=\${p%/*}; mkdir -p "\$d" 2>/dev/null || true
  printf '#!/bin/sh\necho stub-tool\n' > "\$p"; chmod +x "\$p"
done
exit "\${INSTALLER_RC:-0}"
STUB
  done

  # dpkg: prints a fixed architecture (used by \$(dpkg --print-architecture)).
  cat > "$STUBS/dpkg" <<'STUB'
#!/bin/sh
printf 'dpkg %s\n' "$*" >> "$STUB_LOG"
echo arm64
exit 0
STUB

  chmod +x "$STUBS/apt-get" "$STUBS/curl" "$STUBS/sleep" "$STUBS/gpg" \
           "$STUBS/tar" "$STUBS/sh" "$STUBS/bash" "$STUBS/env" "$STUBS/dpkg"
}

# df_write_wrappers — apt-retry / fetch-retry / run-retry reachable through PATH
# in step-body tests, each running the GENERATED helper file under $DF_SH (so
# the shebang does not pick the host /bin/sh). Absolute paths are baked in.
df_write_wrappers() {
  local name
  for name in apt-retry fetch-retry run-retry; do
    cat > "$STUBS/$name" <<STUB
#!/bin/sh
exec "$DF_SH" "$HELPERS/$name" "\$@"
STUB
    chmod +x "$STUBS/$name"
  done
}

# df_materialise_helpers — run each helper's own `printf ... > file && chmod +x`
# body (with /usr/local/bin rewritten into $HELPERS) under $DF_SH, so the file
# is produced exactly as the real build produces it.
df_materialise_helpers() {
  local name body
  for name in apt-retry fetch-retry run-retry; do
    body="$(df_helper_body "$name")" || return 1
    body="${body//\/usr\/local\/bin\//$HELPERS/}"
    "$DF_SH" -c "$body" || {
      echo "df_materialise_helpers: generating $name failed" >&2; return 1; }
    [ -x "$HELPERS/$name" ] || {
      echo "df_materialise_helpers: $name not produced/executable" >&2; return 1; }
  done
}

# df_prepopulate_root — what a real node:20-slim image already has (D-6.5-5).
df_prepopulate_root() {
  mkdir -p "$DF_SB/etc/apt/sources.list.d" "$DF_SB/etc/apt/keyrings" \
           "$DF_SB/usr/share/keyrings" "$DF_SB/usr/local/bin" \
           "$DF_SB/usr/local/go/bin" "$DF_SB/var/lib/apt/lists"
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$DF_SB/etc/os-release"
}

# ---------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------

# df_run_helper NAME [ARG...] — run a materialised helper under $DF_SH with a
# stub-only PATH and sandbox TMPDIR. Env the test exported (APT_FAIL_INSTALLS,
# CURL_MODE, RETRY_CLEAN, ...) is inherited. Use with bats `run`.
df_run_helper() {
  local name="$1"; shift
  (
    export PATH="$STUBS" TMPDIR="$DF_TMP"
    exec "$DF_SH" "$HELPERS/$name" "$@"
  )
}

# df_rewrite_paths — move /etc,/usr,/var absolute paths into the sandbox root.
# A path segment in a URL is preceded by a host char (not space/=/>/"), so URLs
# are left untouched.
df_rewrite_paths() {
  sed -E "s#(^|[ =>\"])/(etc|usr|var)/#\\1${DF_SB}/\\2/#g"
}

# df_assert_sandboxed BODY — fail (return 1) unless every absolute path in the
# rewritten body is under $DF_SB. Done in the bats process, before the body runs.
df_assert_sandboxed() {
  local body="$1" probe
  probe="${body//$DF_SB\//SBX/}"            # neutralise the legitimate root
  if printf '%s' "$probe" | grep -Eq '(^|[ =>"])/[a-z]'; then
    echo "df_assert_sandboxed: body still contains an absolute path outside the sandbox:" >&2
    printf '%s' "$probe" | grep -Eo '(^|[ =>"])/[a-z][^ "]*' >&2
    return 1
  fi
}

# df_run_step SLUG TOOLVAL — extract the tool body, rewrite paths, assert it is
# sandboxed, then run it under $DF_SH with TOOL_<SLUG>=TOOLVAL and a stub-only
# PATH. Use with bats `run`.
df_run_step() {
  local slug="$1" toolval="$2" body
  body="$(df_tool_body "$slug")" || return 1
  body="$(printf '%s' "$body" | df_rewrite_paths)"
  df_assert_sandboxed "$body" || return 1
  (
    export PATH="$STUBS" TMPDIR="$DF_TMP"
    export "TOOL_${slug}=${toolval}"
    exec "$DF_SH" -c "$body"
  )
}

# df_run_base — run the base apt step body in the sandbox (guard-free).
df_run_base() {
  local body
  body="$(df_base_body)" || return 1
  body="$(printf '%s' "$body" | df_rewrite_paths)"
  df_assert_sandboxed "$body" || return 1
  (
    export PATH="$STUBS" TMPDIR="$DF_TMP"
    exec "$DF_SH" -c "$body"
  )
}

# ---------------------------------------------------------------------------
# Small assertion/inspection helpers for the suite.
# ---------------------------------------------------------------------------
df_log_count() {            # df_log_count REGEX  -> count of matching log lines
  grep -Ec "$1" "$STUB_LOG" 2>/dev/null || true
}
df_log() { cat "$STUB_LOG"; }
df_shell_name() { printf '%s' "$DF_SH_NAME"; }
df_sleep_args() {           # space-joined sleep arguments, in order
  sed -n 's/^sleep //p' "$STUB_LOG" | tr '\n' ' '
}
