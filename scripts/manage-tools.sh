#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-platform.sh"
source "$SCRIPT_ROOT/scripts/lib-tools.sh"

if platform_is_macos; then
  source "$SCRIPT_ROOT/scripts/platform/macos/lib-xcode-bridge.sh"
fi

tools_conf_ensure

_tools_build_items() {
  TOOLS_ITEMS=()
  TOOLS_SLUGS=()

  TOOLS_ITEMS+=("##Development")
  TOOLS_ITEMS+=("Docker CLI")
  TOOLS_SLUGS+=("DOCKER_CLI")
  TOOLS_ITEMS+=("Docker Compose")
  TOOLS_SLUGS+=("DOCKER_COMPOSE")
  TOOLS_ITEMS+=("Docker socket access")
  TOOLS_SLUGS+=("DOCKER_SOCKET")
  TOOLS_ITEMS+=("Python")
  TOOLS_SLUGS+=("PYTHON")
  TOOLS_ITEMS+=("Go")
  TOOLS_SLUGS+=("GO")
  TOOLS_ITEMS+=("Rust")
  TOOLS_SLUGS+=("RUST")
  TOOLS_ITEMS+=("Java")
  TOOLS_SLUGS+=("JAVA")
  TOOLS_ITEMS+=("Make")
  TOOLS_SLUGS+=("MAKE")
  TOOLS_ITEMS+=("CMake")
  TOOLS_SLUGS+=("CMAKE")
  TOOLS_ITEMS+=("GCC/Clang")
  TOOLS_SLUGS+=("BUILD_ESSENTIAL")

  TOOLS_ITEMS+=("##Version Control")
  TOOLS_ITEMS+=("GitHub CLI")
  TOOLS_SLUGS+=("GH_CLI")

  TOOLS_ITEMS+=("##Package Managers")
  TOOLS_ITEMS+=("pnpm")
  TOOLS_SLUGS+=("PNPM")
  TOOLS_ITEMS+=("Bun")
  TOOLS_SLUGS+=("BUN")
  TOOLS_ITEMS+=("uv")
  TOOLS_SLUGS+=("UV")

  TOOLS_ITEMS+=("##Utilities")
  TOOLS_ITEMS+=("SSH client")
  TOOLS_SLUGS+=("SSH_CLIENT")
  TOOLS_ITEMS+=("rsync")
  TOOLS_SLUGS+=("RSYNC")
  TOOLS_ITEMS+=("jq")
  TOOLS_SLUGS+=("JQ")
  TOOLS_ITEMS+=("yq")
  TOOLS_SLUGS+=("YQ")
  TOOLS_ITEMS+=("wget")
  TOOLS_SLUGS+=("WGET")

  if platform_is_macos; then
    TOOLS_ITEMS+=("##macOS")
    TOOLS_ITEMS+=("Xcode")
    TOOLS_SLUGS+=("XCODE")
  fi

  TOOLS_ITEMS+=("@@← Back")

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
  cp "$TOOLS_CONF" "${TOOLS_CONF}.tmp" && cat "$_tools_entry_snapshot" > "${TOOLS_CONF}.tmp" && mv -f "${TOOLS_CONF}.tmp" "$TOOLS_CONF"
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

MS_STATE=()
for idx in "${!TOOLS_SLUGS[@]}"; do
  if tools_enabled "${TOOLS_SLUGS[$idx]}"; then
    MS_STATE[$idx]="1"
  else
    MS_STATE[$idx]="0"
  fi
done
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
  echo "image build — this happens automatically next time you run Claude Code,"
  echo "or via Image -> Rebuild Local Image."
fi
press_enter_to_continue
