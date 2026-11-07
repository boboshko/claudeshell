#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-firewall.sh"

# _fw_hub is a self-contained menu loop local to this script (mirrors the
# tput smcup/civis + trap + read -rsn1 escape-sequence style used by
# menu_select/menu_multiselect in lib-menu.sh). It cannot reuse those functions:
# Space must set the mode without leaving the menu, which menu_select does not
# support, and menu_multiselect always returns 0 on Enter regardless of cursor
# row, so Enter on Back could not be told apart from the no-op Enter on a mode
# row.
_fw_hub_build_rows() {
  firewall_conf_ensure
  _fw_hub_mode="$(firewall_mode)"
  _fw_hub_labels=()
  _fw_hub_actions=()

  local rec_mark="[ ]" dis_mark="[ ]"
  if [ "$_fw_hub_mode" = "recommended" ]; then
    rec_mark="[*]"
  else
    dis_mark="[*]"
  fi

  _fw_hub_labels+=("${rec_mark} Recommended")
  _fw_hub_actions+=("mode:recommended")
  _fw_hub_labels+=("${dis_mark} Disabled")
  _fw_hub_actions+=("mode:disabled")

  _fw_hub_labels+=("← Back")
  _fw_hub_actions+=("back")
}

_fw_hub() {
  local cursor=0
  local key
  local n
  local _fw_hub_mode
  local _fw_hub_labels=()
  local _fw_hub_actions=()

  tput smcup 2>/dev/null
  tput civis 2>/dev/null
  trap '_menu_on_interrupt' INT TERM HUP QUIT PIPE

  _fw_hub_draw_frame() {
    _fw_hub_build_rows
    n=${#_fw_hub_labels[@]}

    tput cup 0 0 2>/dev/null
    tput ed 2>/dev/null
    echo -e "\033[1mFirewall\033[0m"
    echo
    local i
    for i in "${!_fw_hub_labels[@]}"; do
      if [ "$i" -eq "$cursor" ]; then
        echo -e "  \033[1;36m→ ${_fw_hub_labels[$i]}\033[0m"
      else
        echo "    ${_fw_hub_labels[$i]}"
      fi
    done
    echo
    echo "  ↑/↓ — navigate, Space — set mode, Enter — select, q — quit"
  }

  _fw_hub_draw_frame

  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      case "${_fw_hub_actions[$cursor]}" in
        back)
          break
          ;;
        mode:*)
          : # mode rows are Space-only; Enter here is a no-op
          ;;
      esac
    elif [[ $key == $'\x1b' ]]; then
      read -rsn2 key
      case "$key" in
        '[A')
          cursor=$(( (cursor - 1 + n) % n ))
          ;;
        '[B')
          cursor=$(( (cursor + 1) % n ))
          ;;
      esac
    elif [[ $key == " " ]]; then
      case "${_fw_hub_actions[$cursor]}" in
        mode:*)
          firewall_set_mode "${_fw_hub_actions[$cursor]#mode:}"
          ;;
      esac
    elif [[ $key == "q" ]]; then
      break
    fi

    _fw_hub_draw_frame
  done

  trap - INT TERM HUP QUIT PIPE
  unset -f _fw_hub_draw_frame
  tput cnorm 2>/dev/null
  tput rmcup 2>/dev/null
}

_fw_hub
