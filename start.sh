#!/bin/bash

trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; stty sane 2>/dev/null' EXIT INT TERM

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_ROOT

mkdir -p "$SCRIPT_ROOT/workspace"

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-mounts.sh"
source "$SCRIPT_ROOT/scripts/lib-update.sh"
source "$SCRIPT_ROOT/scripts/lib-platform.sh"
source "$SCRIPT_ROOT/scripts/lib-firewall.sh"
source "$SCRIPT_ROOT/scripts/lib-tools.sh"

print_banner_text() {
  cat "$SCRIPT_ROOT/scripts/banner.txt"
  echo
}

show_banner() {
  clear
  print_banner_text
}

show_banner

main_menu() {
  while true; do
    local core_options=("Run Claude Code" "Manage mounted folders" \
      "Firewall" "Tools" "Image" "Fix authorization link")
    local core_actions=("run" "mounts" "firewall" "tools" "image" "fix-oauth")

    if check_for_update; then
      core_options+=("Update to ${LATEST_VERSION}")
      core_actions+=("update")
    fi

    local labels=()
    for i in "${!core_options[@]}"; do
      labels+=("$((i + 1)). ${core_options[$i]}")
    done
    labels+=("0. Exit")
    local actions=("${core_actions[@]}" "exit")

    MENU_HEADER="print_banner_text"
    menu_select "Choose an action:" "${labels[@]}"
    choice=$?
    unset MENU_HEADER

    if [ "$choice" -eq 255 ]; then
      echo; echo "Bye!"; exit 0
    fi

    case "${actions[$choice]}" in
      run)
        show_banner
        firewall_conf_ensure
        if [ "$(firewall_mode)" = "disabled" ]; then
          echo "Firewall: Disabled — unrestricted egress. Change this in the Firewall menu."
          export DISABLE_FIREWALL=1
        else
          echo "Firewall: Recommended ($(firewall_active_count) service(s) active). Change this in the Firewall menu."
          unset DISABLE_FIREWALL
        fi
        echo
        bash "$SCRIPT_ROOT/scripts/run-claude.sh"; rc=$?
        if [ "$rc" -ne 0 ]; then
          echo
          echo "Run failed (exit code $rc). See the output above."
          press_enter_to_continue
        fi
        unset DISABLE_FIREWALL
        ;;
      mounts) bash "$SCRIPT_ROOT/scripts/manage-mounts.sh" ;;
      firewall) bash "$SCRIPT_ROOT/scripts/manage-firewall.sh" ;;
      tools)    bash "$SCRIPT_ROOT/scripts/manage-tools.sh" ;;
      image)    bash "$SCRIPT_ROOT/scripts/manage-image.sh" ;;
      fix-oauth) show_banner; bash "$SCRIPT_ROOT/scripts/fix-oauth-url.sh" ;;
      update)
        show_banner
        if bash "$SCRIPT_ROOT/scripts/update.sh" "$LATEST_VERSION"; then
          echo
          echo "Update complete. Restarting ClaudeShell..."
          sleep 1
          exec "$SCRIPT_ROOT/start.sh"
        else
          echo
          echo "Update failed. See the output above."
          press_enter_to_continue
        fi
        ;;
      exit) echo; echo "Bye!"; exit 0 ;;
    esac
  done
}

main_menu
