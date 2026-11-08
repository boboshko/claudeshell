#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-platform.sh"
source "$SCRIPT_ROOT/scripts/lib-tools.sh"

if platform_is_macos; then
  source "$SCRIPT_ROOT/scripts/platform/macos/lib-xcode-bridge.sh"
fi

tools_conf_ensure

_tools_add() {
  local label="$1" slug="$2"
  if ! _tools_is_known_slug "$slug"; then
    echo "[tools] INTERNAL ERROR: _tools_add called with unknown slug '$slug' (label '$label') — check argument order." >&2
    exit 1
  fi
  TOOLS_ITEMS+=("$label")
  TOOLS_SLUGS+=("$slug")
  if tools_enabled "$slug"; then
    MS_STATE+=("1")
  else
    MS_STATE+=("0")
  fi
}

_tools_build_items() {
  TOOLS_ITEMS=()
  TOOLS_SLUGS=()
  MS_STATE=()

  TOOLS_ITEMS+=("##Development")
  _tools_add "Docker CLI" "DOCKER_CLI"
  _tools_add "Docker Compose" "DOCKER_COMPOSE"
  _tools_add "Docker socket access" "DOCKER_SOCKET"
  _tools_add "Python" "PYTHON"
  _tools_add "Go" "GO"
  _tools_add "Rust" "RUST"
  _tools_add "Java" "JAVA"
  _tools_add "Make" "MAKE"
  _tools_add "CMake" "CMAKE"
  _tools_add "GCC/Clang" "BUILD_ESSENTIAL"

  TOOLS_ITEMS+=("##Version Control")
  _tools_add "GitHub CLI" "GH_CLI"

  TOOLS_ITEMS+=("##Databases")
  _tools_add "PostgreSQL" "POSTGRES"
  _tools_add "MongoDB" "MONGODB"
  _tools_add "Redis" "REDIS"

  TOOLS_ITEMS+=("##Package Managers")
  _tools_add "pnpm" "PNPM"
  _tools_add "Bun" "BUN"
  _tools_add "uv" "UV"

  TOOLS_ITEMS+=("##Utilities")
  _tools_add "SSH client" "SSH_CLIENT"
  _tools_add "rsync" "RSYNC"
  _tools_add "jq" "JQ"
  _tools_add "yq" "YQ"
  _tools_add "wget" "WGET"

  if platform_is_macos; then
    TOOLS_ITEMS+=("##macOS")
    _tools_add "Xcode" "XCODE"
  fi

  TOOLS_ITEMS+=("@@← Back")

  unset -f _tools_add

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

_tools_revert_slug() {
  local slug="$1" value="$2"
  local idx
  for idx in "${!TOOLS_SLUGS[@]}"; do
    if [ "${TOOLS_SLUGS[$idx]}" = "$slug" ]; then
      MS_STATE[$idx]="$value"
    fi
  done
}

_tools_on_toggle() {
  local slug="$1" state="$2"
  local new_value="off"
  [ "$state" = "1" ] && new_value="on"
  MS_MESSAGE=""

  if [ "$slug" = "DOCKER_SOCKET" ] && [ "$new_value" = "on" ]; then
    clear
    echo "WARNING: this gives the container root-equivalent control over every"
    echo "container, image, and volume on your host Docker daemon — it effectively"
    echo "removes container isolation for Docker itself. Only enable this if you"
    echo "understand and accept this risk."
    local confirm
    read -rp "Enable Docker socket access? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      _tools_revert_slug "DOCKER_SOCKET" "0"
      MS_MESSAGE="Docker socket access was not enabled."
      return
    fi
  fi

  if [ "$slug" = "PYTHON" ] && [ "$new_value" = "off" ]; then
    local dep_msg
    if ! dep_msg="$(tools_check_deps "$slug" "$new_value")"; then
      _tools_revert_slug "PYTHON" "1"
      MS_MESSAGE="$dep_msg"
      return
    fi
  fi

  tools_set "$slug" "$new_value"

  if [ "$slug" = "UV" ] && [ "$new_value" = "on" ]; then
    local dep_msg
    dep_msg="$(tools_check_deps "$slug" "$new_value")"
    if [ -n "$dep_msg" ]; then
      MS_MESSAGE="$dep_msg"
      _tools_revert_slug "PYTHON" "1"
    fi
  fi

  if [ "$slug" = "DOCKER_SOCKET" ]; then
    tools_generate_docker_socket_override
  fi

  if [ "$slug" = "XCODE" ]; then
    local detect_msg
    if [ "$new_value" = "on" ]; then
      if detect_msg="$(xcode_bridge_detect)"; then
        xcode_bridge_start
        MS_MESSAGE="$detect_msg"
      else
        MS_MESSAGE="$detect_msg"
        tools_set XCODE off
        _tools_revert_slug "XCODE" "0"
      fi
    else
      xcode_bridge_stop
    fi
  fi
}

_tools_cleanup_abort() {
  cp -p "$TOOLS_CONF" "${TOOLS_CONF}.tmp" && cat "$_tools_entry_snapshot" > "${TOOLS_CONF}.tmp" && mv -f "${TOOLS_CONF}.tmp" "$TOOLS_CONF"
  tools_generate_docker_socket_override
  if platform_is_macos; then
    if tools_enabled XCODE; then
      xcode_bridge_is_running || xcode_bridge_start
    else
      xcode_bridge_stop 2>/dev/null
    fi
  fi
}

if ! _tools_build_items; then
  exit 1
fi

MS_SLUGS=("${TOOLS_SLUGS[@]}")
MS_ON_TOGGLE="_tools_on_toggle"
MS_MESSAGE=""

_tools_entry_snapshot="$(mktemp)"
cp "$TOOLS_CONF" "$_tools_entry_snapshot"

MENU_ON_INTERRUPT="_tools_cleanup_abort"
menu_multiselect "Tools" "${TOOLS_ITEMS[@]}"
rc=$?
unset MENU_ON_INTERRUPT

if [ "$rc" -eq 255 ]; then
  _tools_cleanup_abort
  rm -f "$_tools_entry_snapshot"
  echo
  echo "Tools settings were not changed."
else
  rm -f "$_tools_entry_snapshot"
  echo
  echo "Tools settings saved. Changes to installed tools take effect on the next"
  echo "image build — this happens automatically next time you run Claude Code."
fi
press_enter_to_continue
