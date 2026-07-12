#!/bin/bash

trap 'tput cnorm 2>/dev/null; stty sane 2>/dev/null' EXIT INT TERM

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_ROOT

mkdir -p "$SCRIPT_ROOT/workspace"

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-mounts.sh"

show_banner() {
  clear
  cat "$SCRIPT_ROOT/scripts/banner.txt"
  echo
}

show_banner

main_menu() {
  local options=(
    "1. Run Claude Code"
    "2. Manage mounted folders"
    "3. Fix authorization link"
    "0. Exit"
  )

  while true; do
    show_banner
    menu_select "Choose an action:" "${options[@]}"
    choice=$?

    case $choice in
      0)
        show_banner
        if ! bash "$SCRIPT_ROOT/scripts/run-claude.sh"; then
          rc=$?
          echo
          echo "Run failed (exit code $rc). See the output above."
          press_enter_to_continue
        fi
        ;;
      1) bash "$SCRIPT_ROOT/scripts/manage-mounts.sh" ;;
      2) show_banner; bash "$SCRIPT_ROOT/scripts/fix-oauth-url.sh" ;;
      3|255) echo; echo "Bye!"; exit 0 ;;
    esac
  done
}

main_menu
