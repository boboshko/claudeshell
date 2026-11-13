#!/bin/bash

TOOLS_CONF="$SCRIPT_ROOT/scripts/tools.conf"
TOOLS_DOCKER_SOCKET_OVERRIDE="$SCRIPT_ROOT/docker/docker-compose.docker-socket.yml"

TOOLS_KNOWN_SLUGS=(DOCKER_CLI DOCKER_COMPOSE DOCKER_SOCKET PYTHON GO RUST JAVA MAKE CMAKE BUILD_ESSENTIAL GH_CLI POSTGRES MONGODB REDIS PNPM BUN UV SSH_CLIENT RSYNC JQ YQ WGET XCODE)
TOOLS_BUILD_ARG_SLUGS=(DOCKER_CLI DOCKER_COMPOSE PYTHON GO RUST JAVA MAKE CMAKE BUILD_ESSENTIAL GH_CLI POSTGRES MONGODB REDIS PNPM BUN UV SSH_CLIENT RSYNC JQ YQ WGET)

_tools_is_known_slug() {
  local slug="$1"
  local known
  for known in "${TOOLS_KNOWN_SLUGS[@]}"; do
    [ "$known" = "$slug" ] && return 0
  done
  return 1
}

tools_conf_ensure() {
  [ -f "$TOOLS_CONF" ] && return 0
  local slug
  {
    for slug in "${TOOLS_KNOWN_SLUGS[@]}"; do
      echo "TOOL_${slug}=off"
    done
  } > "$TOOLS_CONF"
}

tools_parse_strict() {
  local file="$1"
  [ -f "$file" ] && [ -r "$file" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    if [[ "$line" =~ ^TOOL_([A-Z0-9_]+)=(on|off)$ ]]; then
      _tools_is_known_slug "${BASH_REMATCH[1]}" || return 1
    else
      return 1
    fi
  done < "$file"
  return 0
}

_tools_reset_to_all_off() {
  local slug
  {
    for slug in "${TOOLS_KNOWN_SLUGS[@]}"; do
      echo "TOOL_${slug}=off"
    done
  } > "$TOOLS_CONF"
}

tools_get() {
  local slug="$1"
  tools_conf_ensure
  if ! tools_parse_strict "$TOOLS_CONF"; then
    echo "[tools] WARNING: scripts/tools.conf is invalid — falling back to all tools disabled." >&2
    echo "off"
    return 0
  fi
  local value
  value="$(grep -E "^TOOL_${slug}=" "$TOOLS_CONF" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  [ -n "$value" ] || value="off"
  echo "$value"
}

tools_enabled() {
  local slug="$1"
  [ "$(tools_get "$slug")" = "on" ]
}

tools_set() {
  local slug="$1" value="$2"
  _tools_is_known_slug "$slug" || return 1
  tools_conf_ensure
  if ! tools_parse_strict "$TOOLS_CONF"; then
    _tools_reset_to_all_off
  fi
  if grep -qE "^TOOL_${slug}=" "$TOOLS_CONF" 2>/dev/null; then
    sed -i.bak "s/^TOOL_${slug}=.*/TOOL_${slug}=${value}/" "$TOOLS_CONF" && rm -f "$TOOLS_CONF.bak"
  else
    echo "TOOL_${slug}=${value}" >> "$TOOLS_CONF"
  fi
}

tools_check_deps() {
  local slug="$1" new_state="$2"
  if [ "$slug" = "PYTHON" ] && [ "$new_state" = "off" ] && tools_enabled UV; then
    echo "Deselect uv first — uv depends on Python."
    return 1
  fi
  if [ "$slug" = "UV" ] && [ "$new_state" = "on" ] && ! tools_enabled PYTHON; then
    tools_set PYTHON on
    echo "Python has been auto-selected because uv requires it."
  fi
  return 0
}

tools_export_build_args() {
  tools_conf_ensure
  local slug
  for slug in "${TOOLS_BUILD_ARG_SLUGS[@]}"; do
    if tools_enabled "$slug"; then
      export "TOOL_${slug}=1"
    else
      export "TOOL_${slug}=0"
    fi
  done
}

tools_generate_docker_socket_override() {
  tools_conf_ensure
  if tools_enabled DOCKER_SOCKET; then
    {
      echo "services:"
      echo "  claudeshell:"
      echo "    volumes:"
      echo "      - /var/run/docker.sock:/var/run/docker.sock"
    } > "$TOOLS_DOCKER_SOCKET_OVERRIDE"
  else
    rm -f "$TOOLS_DOCKER_SOCKET_OVERRIDE"
  fi
}
