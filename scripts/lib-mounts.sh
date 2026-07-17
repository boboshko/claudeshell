#!/bin/bash

MOUNTS_CONF="$SCRIPT_ROOT/scripts/mounts.conf"
MOUNTS_OVERRIDE="$SCRIPT_ROOT/docker/docker-compose.mounts.yml"

mounts_ensure_conf() {
  [ -f "$MOUNTS_CONF" ] || touch "$MOUNTS_CONF"
}

mounts_list() {
  mounts_ensure_conf
  grep -v '^\s*$' "$MOUNTS_CONF" 2>/dev/null || true
}

mounts_add() {
  local path="$1"
  mounts_ensure_conf
  path="${path%/}"
  if grep -qxF "$path" "$MOUNTS_CONF" 2>/dev/null; then
    echo "This path is already added."
    return 1
  fi
  echo "$path" >> "$MOUNTS_CONF"
}

mounts_remove_by_index() {
  local idx="$1"
  mounts_ensure_conf
  sed -i.bak "${idx}d" "$MOUNTS_CONF" && rm -f "$MOUNTS_CONF.bak"
}

mounts_generate_override() {
  mounts_ensure_conf
  ADD_DIR_ARGS=()

  {
    echo "services:"
    echo "  claude-shell:"
    echo "    volumes:"

    local root_path="${SCRIPT_ROOT}/workspace"
    local escaped_root="${root_path//\\/\\\\}"
    escaped_root="${escaped_root//\"/\\\"}"
    echo "      - \"${escaped_root}:/workspace\""

    if [ -s "$MOUNTS_CONF" ]; then
      local i=0
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        i=$((i + 1))
        local base
        base="$(printf '%s' "$(basename "$path")" | tr -c 'a-zA-Z0-9_-' '-')"
        local target="/workspace/${i}-${base}"
        local escaped_path="${path//\\/\\\\}"
        escaped_path="${escaped_path//\"/\\\"}"
        echo "      - \"${escaped_path}:${target}\""
        ADD_DIR_ARGS+=("--add-dir" "$target")
      done < "$MOUNTS_CONF"
    fi
  } > "$MOUNTS_OVERRIDE"
}
