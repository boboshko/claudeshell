#!/usr/bin/env bash

: "${FIREWALL_CONF:=${SCRIPT_ROOT:+$SCRIPT_ROOT/scripts/firewall.conf}}"
: "${FIREWALL_CONF:=/etc/claude-shell/firewall.conf}"

FW_DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
FW_CIDR_REGEX='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'

FW_KNOWN_SERVICES=(npm github gitlab pypi dockerhub huggingface microsoft apple go rust)

declare -A FW_SERVICE_LABEL=(
  [npm]="npm registry"
  [github]="GitHub"
  [gitlab]="GitLab"
  [pypi]="PyPI"
  [dockerhub]="Docker Hub"
  [huggingface]="Hugging Face"
  [microsoft]="Microsoft dev services"
  [apple]="Apple dev resources"
  [go]="Go toolchain"
  [rust]="Rust toolchain"
)

declare -A FW_SERVICE_DESC=(
  [npm]="registry.npmjs.org, npmjs.org, www.npmjs.org"
  [github]="github.com, api.github.com, codeload.github.com, raw.githubusercontent.com + live GitHub CIDR ranges"
  [gitlab]="gitlab.com, registry.gitlab.com, assets.gitlab-static.net"
  [pypi]="pypi.org, files.pythonhosted.org"
  [dockerhub]="registry-1.docker.io, auth.docker.io, index.docker.io, production.cloudflare.docker.com"
  [huggingface]="huggingface.co, cdn-lfs.huggingface.co, cdn-lfs-us-1.huggingface.co"
  [microsoft]="api.nuget.org, marketplace.visualstudio.com, dotnet.microsoft.com, related hosts"
  [apple]="developer.apple.com, swift.org, download.swift.org"
  [go]="proxy.golang.org, sum.golang.org"
  [rust]="static.rust-lang.org, crates.io, static.crates.io, index.crates.io"
)

FW_WARNED=0
FW_MODE=""
declare -A FW_SERVICES=()
FW_CUSTOM=()

declare -A FW_PARSED_SERVICES=()
FW_PARSED_CUSTOM=()
FW_PARSED_MODE=""

firewall_known_services() {
  printf '%s\n' "${FW_KNOWN_SERVICES[@]}"
}

firewall_service_label() {
  printf '%s\n' "${FW_SERVICE_LABEL[$1]:-$1}"
}

firewall_service_description() {
  printf '%s\n' "${FW_SERVICE_DESC[$1]:-}"
}

_firewall_is_known_service() {
  local slug="$1" known
  for known in "${FW_KNOWN_SERVICES[@]}"; do
    [ "$known" = "$slug" ] && return 0
  done
  return 1
}

_firewall_write_defaults() {
  cat > "$FIREWALL_CONF" <<'EOF'
MODE=recommended
SERVICE_NPM=on
SERVICE_GITHUB=on
SERVICE_GITLAB=on
SERVICE_PYPI=on
SERVICE_DOCKERHUB=on
SERVICE_HUGGINGFACE=off
SERVICE_MICROSOFT=off
SERVICE_APPLE=off
SERVICE_GO=off
SERVICE_RUST=on
EOF
}

firewall_conf_ensure() {
  if [ ! -f "$FIREWALL_CONF" ]; then
    local dir
    dir="$(dirname "$FIREWALL_CONF")"
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
    _firewall_write_defaults
  fi
}

firewall_parse_strict() {
  local file="$1"
  [ -r "$file" ] || return 1

  FW_PARSED_MODE=""
  FW_PARSED_SERVICES=()
  FW_PARSED_CUSTOM=()

  local line key value slug n
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      '#'*) continue ;;
    esac

    if [[ ! "$line" =~ ^[A-Z][A-Z0-9_]*=.*$ ]]; then
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      MODE)
        if [ "$value" != "disabled" ] && [ "$value" != "recommended" ]; then
          return 1
        fi
        FW_PARSED_MODE="$value"
        ;;
      SERVICE_*)
        slug="${key#SERVICE_}"
        slug="${slug,,}"
        if ! _firewall_is_known_service "$slug"; then
          return 1
        fi
        if [ "$value" != "on" ] && [ "$value" != "off" ]; then
          return 1
        fi
        FW_PARSED_SERVICES[$slug]="$value"
        ;;
      CUSTOM_*)
        n="${key#CUSTOM_}"
        if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
          return 1
        fi
        if [[ "$value" =~ $FW_DOMAIN_REGEX ]] || [[ "$value" =~ $FW_CIDR_REGEX ]]; then
          FW_PARSED_CUSTOM+=("$value")
        else
          return 1
        fi
        ;;
      *)
        return 1
        ;;
    esac
  done < "$file"

  [ -n "$FW_PARSED_MODE" ] || return 1
  return 0
}

_firewall_warn_fallback() {
  if [ "$FW_WARNED" != "1" ]; then
    echo "[firewall] WARNING: scripts/firewall.conf is invalid — falling back to Recommended defaults." >&2
    FW_WARNED=1
  fi
}

_firewall_load() {
  FW_MODE=""
  FW_SERVICES=()
  FW_CUSTOM=()

  if firewall_parse_strict "$FIREWALL_CONF"; then
    FW_MODE="$FW_PARSED_MODE"
    local slug
    for slug in "${FW_KNOWN_SERVICES[@]}"; do
      FW_SERVICES[$slug]="${FW_PARSED_SERVICES[$slug]:-off}"
    done
    FW_CUSTOM=("${FW_PARSED_CUSTOM[@]}")
    return 0
  fi

  _firewall_warn_fallback
  FW_MODE="recommended"
  FW_SERVICES=([npm]="on" [github]="on" [gitlab]="on" [pypi]="on" [dockerhub]="on" \
    [huggingface]="off" [microsoft]="off" [apple]="off" [go]="off" [rust]="on")
  FW_CUSTOM=()
  return 1
}

firewall_mode() {
  _firewall_load || true
  printf '%s\n' "$FW_MODE"
}

firewall_active_count() {
  _firewall_load || true
  local count=0 slug
  for slug in "${FW_KNOWN_SERVICES[@]}"; do
    [ "${FW_SERVICES[$slug]:-off}" = "on" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

firewall_service_enabled() {
  local slug="$1"
  _firewall_load || true
  [ "${FW_SERVICES[$slug]:-off}" = "on" ]
}

firewall_custom_list() {
  _firewall_load || true
  local c
  for c in "${FW_CUSTOM[@]}"; do
    [ -n "$c" ] && printf '%s\n' "$c"
  done
}

_firewall_set_key() {
  local key="$1" value="$2" tmp
  firewall_conf_ensure
  if grep -q "^${key}=" "$FIREWALL_CONF" 2>/dev/null; then
    tmp="$(mktemp "${FIREWALL_CONF}.XXXXXX")"
    sed "s|^${key}=.*|${key}=${value}|" "$FIREWALL_CONF" > "$tmp"
    mv "$tmp" "$FIREWALL_CONF"
  else
    printf '%s=%s\n' "$key" "$value" >> "$FIREWALL_CONF"
  fi
}

firewall_set_mode() {
  local mode="$1"
  if [ "$mode" != "disabled" ] && [ "$mode" != "recommended" ]; then
    echo "Invalid firewall mode: $mode" >&2
    return 1
  fi
  _firewall_set_key "MODE" "$mode"
}

firewall_set_service() {
  local slug="$1" state="$2" key
  if ! _firewall_is_known_service "$slug"; then
    echo "Unknown firewall service: $slug" >&2
    return 1
  fi
  if [ "$state" != "on" ] && [ "$state" != "off" ]; then
    echo "Invalid service state: $state" >&2
    return 1
  fi
  key="SERVICE_${slug^^}"
  _firewall_set_key "$key" "$state"
}

firewall_custom_add() {
  local value="$1" n=1
  if [[ ! "$value" =~ $FW_DOMAIN_REGEX ]] && [[ ! "$value" =~ $FW_CIDR_REGEX ]]; then
    echo "Invalid domain or CIDR: $value" >&2
    return 1
  fi
  firewall_conf_ensure
  while grep -q "^CUSTOM_${n}=" "$FIREWALL_CONF" 2>/dev/null; do
    n=$((n + 1))
  done
  printf 'CUSTOM_%s=%s\n' "$n" "$value" >> "$FIREWALL_CONF"
}

firewall_custom_remove() {
  local idx="$1" tmp n=1 i count v
  firewall_conf_ensure

  local customs=()
  while IFS= read -r v; do
    customs+=("$v")
  done < <(firewall_custom_list)
  count=${#customs[@]}

  if [ "$idx" -lt 1 ] 2>/dev/null || [ "$idx" -gt "$count" ] 2>/dev/null; then
    echo "No such custom entry: $idx" >&2
    return 1
  fi

  tmp="$(mktemp "${FIREWALL_CONF}.XXXXXX")"
  grep -v '^CUSTOM_[0-9][0-9]*=' "$FIREWALL_CONF" > "$tmp" || true

  for i in "${!customs[@]}"; do
    if [ "$((i + 1))" -ne "$idx" ]; then
      printf 'CUSTOM_%s=%s\n' "$n" "${customs[$i]}" >> "$tmp"
      n=$((n + 1))
    fi
  done

  mv "$tmp" "$FIREWALL_CONF"
}

firewall_restore_defaults() {
  firewall_conf_ensure
  _firewall_write_defaults
}
