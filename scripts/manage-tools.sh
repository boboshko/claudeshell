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
  TOOLS_ITEMS+=("Docker CLI|Run Docker commands against a remote daemon")
  TOOLS_SLUGS+=("DOCKER_CLI")
  TOOLS_ITEMS+=("Docker Compose|Define and run multi-container applications")
  TOOLS_SLUGS+=("DOCKER_COMPOSE")
  TOOLS_ITEMS+=("Docker socket access|Full control of the host's Docker — high risk")
  TOOLS_SLUGS+=("DOCKER_SOCKET")
  TOOLS_ITEMS+=("Python|Python language and tools")
  TOOLS_SLUGS+=("PYTHON")
  TOOLS_ITEMS+=("Go|Go language")
  TOOLS_SLUGS+=("GO")
  TOOLS_ITEMS+=("Rust|Rust language")
  TOOLS_SLUGS+=("RUST")
  TOOLS_ITEMS+=("Java|Java development kit")
  TOOLS_SLUGS+=("JAVA")
  TOOLS_ITEMS+=("Make|Build automation")
  TOOLS_SLUGS+=("MAKE")
  TOOLS_ITEMS+=("CMake|Cross-platform build system")
  TOOLS_SLUGS+=("CMAKE")
  TOOLS_ITEMS+=("GCC/Clang|C/C++ compilers and build tools")
  TOOLS_SLUGS+=("BUILD_ESSENTIAL")

  TOOLS_ITEMS+=("##Version Control")
  TOOLS_ITEMS+=("GitHub CLI|Work with GitHub from the terminal")
  TOOLS_SLUGS+=("GH_CLI")

  TOOLS_ITEMS+=("##Package Managers")
  TOOLS_ITEMS+=("pnpm|Fast, disk-efficient package manager")
  TOOLS_SLUGS+=("PNPM")
  TOOLS_ITEMS+=("Bun|Fast JavaScript runtime and package manager")
  TOOLS_SLUGS+=("BUN")
  TOOLS_ITEMS+=("uv|Fast package manager — requires Python")
  TOOLS_SLUGS+=("UV")

  TOOLS_ITEMS+=("##Utilities")
  TOOLS_ITEMS+=("SSH client|Connect to remote machines")
  TOOLS_SLUGS+=("SSH_CLIENT")
  TOOLS_ITEMS+=("rsync|Synchronize files and directories")
  TOOLS_SLUGS+=("RSYNC")
  TOOLS_ITEMS+=("jq|Query and transform JSON")
  TOOLS_SLUGS+=("JQ")
  TOOLS_ITEMS+=("yq|Query and transform YAML")
  TOOLS_SLUGS+=("YQ")
  TOOLS_ITEMS+=("wget|Download files from the web")
  TOOLS_SLUGS+=("WGET")

  if platform_is_macos; then
    TOOLS_ITEMS+=("##macOS")
    TOOLS_ITEMS+=("Xcode|Host bridge for building and testing iOS/macOS apps")
    TOOLS_SLUGS+=("XCODE")
  fi

  TOOLS_ITEMS+=("@@← Back")
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

  tools_generate_docker_socket_override

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

_tools_build_items

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

menu_multiselect "Tools" "${TOOLS_ITEMS[@]}"
rc=$?

if [ "$rc" -eq 255 ]; then
  cp "$_tools_entry_snapshot" "$TOOLS_CONF"
  tools_generate_docker_socket_override
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
