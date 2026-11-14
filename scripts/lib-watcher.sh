#!/usr/bin/env bash

: "${WATCHER_CONF:=${SCRIPT_ROOT:+$SCRIPT_ROOT/scripts/watcher.conf}}"
: "${WATCHER_CONF:=/etc/claudeshell/watcher.conf}"

WATCHER_WARNED=0
WATCHER_MODE=""
WATCHER_PARSED_MODE=""

_watcher_write_defaults() {
  cat > "$WATCHER_CONF" <<'EOF'
MODE=disabled
EOF
}

watcher_conf_ensure() {
  if [ ! -f "$WATCHER_CONF" ]; then
    local dir
    dir="$(dirname "$WATCHER_CONF")"
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
    _watcher_write_defaults
  fi
}

watcher_parse_strict() {
  local file="$1"
  [ -r "$file" ] || return 1

  WATCHER_PARSED_MODE=""

  local line="" key value
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
        if [ "$value" != "enabled" ] && [ "$value" != "disabled" ]; then
          return 1
        fi
        WATCHER_PARSED_MODE="$value"
        ;;
      *)
        return 1
        ;;
    esac
  done < "$file"

  [ -n "$WATCHER_PARSED_MODE" ] || return 1
  return 0
}

_watcher_warn_fallback() {
  if [ "$WATCHER_WARNED" != "1" ]; then
    echo "[watcher] WARNING: scripts/watcher.conf is invalid — falling back to Disabled." >&2
    WATCHER_WARNED=1
  fi
}

_watcher_load() {
  if watcher_parse_strict "$WATCHER_CONF"; then
    WATCHER_MODE="$WATCHER_PARSED_MODE"
    return 0
  fi

  _watcher_warn_fallback
  WATCHER_MODE="disabled"
  return 1
}

watcher_mode() {
  _watcher_load || true
  printf '%s\n' "$WATCHER_MODE"
}

_watcher_set_key() {
  local key="$1" value="$2" tmp
  watcher_conf_ensure
  if grep -q "^${key}=" "$WATCHER_CONF" 2>/dev/null; then
    tmp="$(mktemp "${WATCHER_CONF}.XXXXXX")" || return 1
    if ! sed "s|^${key}=.*|${key}=${value}|" "$WATCHER_CONF" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    chmod "$(stat -L -c '%a' "$WATCHER_CONF" 2>/dev/null || stat -L -f '%Lp' "$WATCHER_CONF" 2>/dev/null)" "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$WATCHER_CONF"; then
      rm -f "$tmp"
      return 1
    fi
  else
    printf '%s=%s\n' "$key" "$value" >> "$WATCHER_CONF"
  fi
}

watcher_set_mode() {
  local mode="$1"
  if [ "$mode" != "enabled" ] && [ "$mode" != "disabled" ]; then
    echo "Invalid watcher mode: $mode" >&2
    return 1
  fi
  _watcher_set_key "MODE" "$mode"
}
