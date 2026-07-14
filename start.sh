#!/bin/bash

trap 'tput cnorm 2>/dev/null; stty sane 2>/dev/null' EXIT INT TERM

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_ROOT

mkdir -p "$SCRIPT_ROOT/workspace"

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-mounts.sh"
source "$SCRIPT_ROOT/scripts/lib-update.sh"

show_banner() {
  clear
  cat "$SCRIPT_ROOT/scripts/banner.txt"
  echo
}

show_banner

main_menu() {
  while true; do
    show_banner

    local core_options=("Run Claude Code" "Manage mounted folders" "Fix authorization link")
    local core_actions=("run" "mounts" "fix-oauth")

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

    menu_select "Choose an action:" "${labels[@]}"
    choice=$?

    if [ "$choice" -eq 255 ]; then
      echo; echo "Bye!"; exit 0
    fi

    case "${actions[$choice]}" in
      run)
        show_banner
        if ! bash "$SCRIPT_ROOT/scripts/run-claude.sh"; then
          rc=$?
          echo
          echo "Run failed (exit code $rc). See the output above."
          press_enter_to_continue
        fi
        ;;
      mounts) bash "$SCRIPT_ROOT/scripts/manage-mounts.sh" ;;
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
