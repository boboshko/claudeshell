#!/usr/bin/env bats
#
# Item 7 (S3): the firewall value the container receives is decided by the
# firewall mode in scripts/firewall.conf, never by a DISABLE_FIREWALL line in
# docker/.env nor by an inherited shell variable. Exercises the real start.sh
# and scripts/run-claude.sh against a recording stub `docker`; no daemon runs.
#
# SAFETY: PATH is "$STUBS:/usr/bin:/bin" and the stub docker (and curl) win the
# lookup, so nothing here starts a container or reaches the network.

bats_require_minimum_version 1.5.0

REPO_ROOT_FILE_DIR=""

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ROOT="$BATS_TEST_TMPDIR/root"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  DOCKER_REC="$BATS_TEST_TMPDIR/docker.rec"
  mkdir -p "$STUBS"
  export DOCKER_REC
  ENV_PATH="$STUBS:/usr/bin:/bin"

  # --- scratch copy of everything start.sh / run-claude.sh read ---
  mkdir -p "$ROOT"
  cp "$REPO_ROOT/start.sh" "$ROOT/"
  cp "$REPO_ROOT/VERSION" "$ROOT/"
  cp -r "$REPO_ROOT/scripts" "$ROOT/scripts"
  cp -r "$REPO_ROOT/docker" "$ROOT/docker"
  # strip anything host-local that would otherwise leak into the run
  rm -f "$ROOT/docker/.env" "$ROOT/docker/.build-hash" \
        "$ROOT/docker/docker-compose.mounts.yml" \
        "$ROOT/docker/docker-compose.docker-socket.yml"
  rm -f "$ROOT/scripts/firewall.conf" "$ROOT/scripts/tools.conf" \
        "$ROOT/scripts/mounts.conf"
  # a fresh, current update cache so check_for_update stays offline and adds no row
  printf '%s %s\n' "$(date +%s)" "$(tr -d '[:space:]' < "$ROOT/VERSION")" \
    > "$ROOT/.update-cache"

  _envh_write_stubs
}

_envh_write_stubs() {
  # docker: succeeds for everything, and records the environment value plus the
  # full argument list of the one `run` compose invocation.
  cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
is_run=0
for a in "$@"; do [ "$a" = "run" ] && { is_run=1; break; }; done
if [ "$is_run" -eq 1 ]; then
  {
    printf 'DISABLE_FIREWALL=%s\n' "${DISABLE_FIREWALL-<unset>}"
    printf 'ARGS='; for x in "$@"; do printf ' %s' "$x"; done; printf '\n'
  } >> "$DOCKER_REC"
fi
exit 0
STUB
  chmod +x "$STUBS/docker"
  # curl: offline, empty (the update cache already prevents a fetch)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/curl"
  chmod +x "$STUBS/curl"
}

_envh_write_conf() {
  case "$1" in
    recommended) printf 'MODE=recommended\n' > "$ROOT/scripts/firewall.conf" ;;
    disabled)    printf 'MODE=disabled\n'    > "$ROOT/scripts/firewall.conf" ;;
    invalid)     printf 'MODE=disabled\nFOO=bar\n' > "$ROOT/scripts/firewall.conf" ;;
  esac
}

_envh_write_env() {
  case "$1" in
    absent)  rm -f "$ROOT/docker/.env" ;;
    dfw1)    printf 'DISABLE_FIREWALL=1\n'  > "$ROOT/docker/.env" ;;
    dfw0)    printf 'DISABLE_FIREWALL=0\n'  > "$ROOT/docker/.env" ;;
    comment) printf '# DISABLE_FIREWALL=1\nANTHROPIC_MODEL=x\n' > "$ROOT/docker/.env" ;;
  esac
}

# Run start.sh driven by "Run" (first row) then "q".
_envh_run_start() {
  local hostvar="$1" envarg
  case "$hostvar" in
    unset) envarg=(env -u DISABLE_FIREWALL) ;;
    *)     envarg=(env "DISABLE_FIREWALL=$hostvar") ;;
  esac
  : > "$DOCKER_REC"
  run timeout 30 "${envarg[@]}" PATH="$ENV_PATH" \
    bash -c 'printf "\rq" | bash "$0"' "$ROOT/start.sh"
}

# Run run-claude.sh directly with SCRIPT_ROOT set (no start.sh in front).
_envh_run_direct() {
  local hostvar="$1" envarg
  case "$hostvar" in
    unset) envarg=(env -u DISABLE_FIREWALL) ;;
    *)     envarg=(env "DISABLE_FIREWALL=$hostvar") ;;
  esac
  : > "$DOCKER_REC"
  run timeout 30 "${envarg[@]}" PATH="$ENV_PATH" SCRIPT_ROOT="$ROOT" \
    bash "$ROOT/scripts/run-claude.sh"
}

# Shared per-cell assertions on the recording. $1 = expected value (0|1),
# $2 = .env variant, $3 = context string.
_envh_assert_record() {
  local want="$1" envv="$2" ctx="$3" rec val args note
  # exactly one run invocation recorded
  local nruns; nruns="$(grep -c '^DISABLE_FIREWALL=' "$DOCKER_REC" || true)"
  [ "$nruns" -eq 1 ] || { echo "[$ctx] expected 1 run, recorded $nruns"; cat "$DOCKER_REC"; return 1; }
  val="$(grep '^DISABLE_FIREWALL=' "$DOCKER_REC" | cut -d= -f2-)"
  args="$(grep '^ARGS=' "$DOCKER_REC")"
  [ "$val" = "$want" ] || { echo "[$ctx] env value $val, wanted $want"; return 1; }
  [ "$val" != "<unset>" ] && [ -n "$val" ] || { echo "[$ctx] value unset/empty"; return 1; }
  # -e DISABLE_FIREWALL=<want> is passed and precedes the service name
  [[ "$args" == *"-e DISABLE_FIREWALL=$want claude-shell"* ]] \
    || { echo "[$ctx] args missing '-e DISABLE_FIREWALL=$want' before service: $args"; return 1; }
  # --env-file .env present iff the file exists
  if [ "$envv" = "absent" ]; then
    [[ "$args" != *"--env-file .env"* ]] || { echo "[$ctx] unexpected --env-file: $args"; return 1; }
  else
    [[ "$args" == *"--env-file .env"* ]] || { echo "[$ctx] missing --env-file: $args"; return 1; }
  fi
}

@test "BF7-AC1/AC2/AC3: start.sh forces the container value from firewall.conf across the full env matrix" {
  local conf envv host want ctx
  for conf in recommended invalid disabled; do
    _envh_write_conf "$conf"
    if [ "$conf" = "disabled" ]; then want=1; else want=0; fi
    for envv in absent dfw1 dfw0 comment; do
      _envh_write_env "$envv"
      for host in unset 1 0 ""; do
        ctx="start conf=$conf env=$envv host=${host:-empty}"
        _envh_run_start "$host"
        [ "$status" -eq 0 ] || { echo "[$ctx] start.sh exit $status"; echo "$output"; return 1; }
        _envh_assert_record "$want" "$envv" "$ctx"

        # status line matches the value
        if [ "$want" = "1" ]; then
          [[ "$output" == *"Firewall: Disabled"* ]] || { echo "[$ctx] missing Disabled status line"; return 1; }
        else
          [[ "$output" == *"Firewall: Recommended"* ]] || { echo "[$ctx] missing Recommended status line"; return 1; }
        fi

        # the .env notice: exactly once for an assignment line, never otherwise
        local note; note="$(printf '%s\n' "$output" | grep -c '\[firewall\] NOTE:' || true)"
        case "$envv" in
          dfw1|dfw0) [ "$note" -eq 1 ] || { echo "[$ctx] NOTE count $note, wanted 1"; return 1; } ;;
          *)         [ "$note" -eq 0 ] || { echo "[$ctx] NOTE count $note, wanted 0"; return 1; } ;;
        esac

        # invalid config warns exactly once on the start.sh path
        local warn; warn="$(printf '%s\n' "$output" | grep -c '\[firewall\] WARNING' || true)"
        if [ "$conf" = "invalid" ]; then
          [ "$warn" -eq 1 ] || { echo "[$ctx] invalid-config WARNING count $warn, wanted 1"; return 1; }
        else
          [ "$warn" -eq 0 ] || { echo "[$ctx] WARNING count $warn, wanted 0"; return 1; }
        fi
      done
    done
  done
}

@test "BF7-AC1/AC2/AC3: run-claude.sh called directly ignores the inherited variable and resolves from firewall.conf" {
  local conf envv host want ctx
  for conf in recommended invalid disabled; do
    _envh_write_conf "$conf"
    if [ "$conf" = "disabled" ]; then want=1; else want=0; fi
    for envv in absent dfw1 dfw0 comment; do
      _envh_write_env "$envv"
      for host in unset 1 0 ""; do
        ctx="direct conf=$conf env=$envv host=${host:-empty}"
        _envh_run_direct "$host"
        [ "$status" -eq 0 ] || { echo "[$ctx] run-claude.sh exit $status"; echo "$output"; return 1; }
        _envh_assert_record "$want" "$envv" "$ctx"

        # the .env notice still fires once per assignment line
        local note; note="$(printf '%s\n' "$output" | grep -c '\[firewall\] NOTE:' || true)"
        case "$envv" in
          dfw1|dfw0) [ "$note" -eq 1 ] || { echo "[$ctx] NOTE count $note, wanted 1"; return 1; } ;;
          *)         [ "$note" -eq 0 ] || { echo "[$ctx] NOTE count $note, wanted 0"; return 1; } ;;
        esac

        # the invalid-config WARNING is suppressed on the direct path (2>/dev/null)
        local warn; warn="$(printf '%s\n' "$output" | grep -c '\[firewall\] WARNING' || true)"
        [ "$warn" -eq 0 ] || { echo "[$ctx] direct-path WARNING count $warn, wanted 0"; return 1; }
      done
    done
  done
}

@test "BF7-AC1/AC2: real 'docker compose config' resolves DISABLE_FIREWALL to the exported value, not to docker/.env" {
  if ! /usr/bin/docker compose version >/dev/null 2>&1; then
    skip "real docker compose client not available"
  fi
  _envh_write_conf recommended
  # make the mounts override the scripts expect
  ( cd "$ROOT/docker" && : > docker-compose.mounts.yml )
  printf 'services:\n  claude-shell:\n    image: claude-shell:latest\n' \
    > "$ROOT/docker/docker-compose.mounts.yml"

  local envv val out
  # one representative cell per (.env, exported value) pair
  for envv in absent dfw1 dfw0; do
    _envh_write_env "$envv"
    for val in 0 1; do
      local envfile_flag=()
      [ -f "$ROOT/docker/.env" ] && envfile_flag=(--env-file .env)
      out="$(cd "$ROOT/docker" && DISABLE_FIREWALL="$val" /usr/bin/docker compose \
        -p claude-shell "${envfile_flag[@]}" \
        -f docker-compose.yml -f docker-compose.mounts.yml config 2>/dev/null \
        | grep -A2 -i 'DISABLE_FIREWALL' | head -3)"
      [[ "$out" == *"$val"* ]] || { echo "[env=$envv exported=$val] resolved: $out"; return 1; }
    done
  done
}
