#!/usr/bin/env bash

: "${FIREWALL_CONF:=${SCRIPT_ROOT:+$SCRIPT_ROOT/scripts/firewall.conf}}"
: "${FIREWALL_CONF:=/etc/claudeshell/firewall.conf}"

FW_DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
FW_CIDR_REGEX='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'

# This file also runs on the host (including macOS), so it must stay bash 3.2 compatible.

FW_WARNED=0
FW_MODE=""

FW_PARSED_MODE=""

_firewall_write_defaults() {
  cat > "$FIREWALL_CONF" <<'EOF'
MODE=recommended
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

  # line starts empty: when the config is a directory, read fails and leaves it
  # unset, and the loop condition below would abort under set -u.
  local line="" key value n
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

    # SERVICE_* and CUSTOM_* lines from older versions have no effect, but their
    # values are still checked: MODE=disabled with SERVICE_NPM=maybe has always
    # resolved to Recommended and must not open egress after an upgrade.
    case "$key" in
      MODE)
        if [ "$value" != "disabled" ] && [ "$value" != "recommended" ]; then
          return 1
        fi
        FW_PARSED_MODE="$value"
        ;;
      SERVICE_NPM|SERVICE_GITHUB|SERVICE_GITLAB|SERVICE_PYPI|SERVICE_DOCKERHUB|SERVICE_HUGGINGFACE|SERVICE_MICROSOFT|SERVICE_APPLE|SERVICE_GO|SERVICE_RUST)
        if [ "$value" != "on" ] && [ "$value" != "off" ]; then
          return 1
        fi
        ;;
      CUSTOM_*)
        n="${key#CUSTOM_}"
        if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
          return 1
        fi
        if [[ ! "$value" =~ $FW_DOMAIN_REGEX ]] && [[ ! "$value" =~ $FW_CIDR_REGEX ]]; then
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
  if firewall_parse_strict "$FIREWALL_CONF"; then
    FW_MODE="$FW_PARSED_MODE"
    return 0
  fi

  _firewall_warn_fallback
  FW_MODE="recommended"
  return 1
}

firewall_mode() {
  _firewall_load || true
  printf '%s\n' "$FW_MODE"
}

_firewall_set_key() {
  local key="$1" value="$2" tmp
  firewall_conf_ensure
  if grep -q "^${key}=" "$FIREWALL_CONF" 2>/dev/null; then
    tmp="$(mktemp "${FIREWALL_CONF}.XXXXXX")" || return 1
    # The source's mode is copied only after the write: a read-only mode on the
    # temp file would make the write fail. A failure here must never reach mv.
    if ! sed "s|^${key}=.*|${key}=${value}|" "$FIREWALL_CONF" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    # -L: a symlink's own mode is 777 on Linux, so read the mode of its target. If
    # stat fails, chmod rejects the mode and the temp file stays at mktemp's 600.
    # Limitation: mv below replaces a symlink with a regular file; the target keeps
    # its mode and its old content.
    chmod "$(stat -L -c '%a' "$FIREWALL_CONF" 2>/dev/null || stat -L -f '%Lp' "$FIREWALL_CONF" 2>/dev/null)" "$tmp" 2>/dev/null || true
    # -f: without it, mv asks on a terminal before replacing a read-only file,
    # which would stall the hub and leak the temp file on a "no" answer.
    if ! mv -f "$tmp" "$FIREWALL_CONF"; then
      rm -f "$tmp"
      return 1
    fi
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
