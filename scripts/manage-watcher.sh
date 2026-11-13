#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-watcher.sh"

_watcher_hub_build_rows() {
  watcher_conf_ensure
  _watcher_hub_mode="$(watcher_mode)"
  _watcher_hub_labels=()
  _watcher_hub_actions=()

  local en_mark="[ ]" dis_mark="[ ]"
  if [ "$_watcher_hub_mode" = "enabled" ]; then
    en_mark="[*]"
  else
    dis_mark="[*]"
  fi

  _watcher_hub_labels+=("${en_mark} Enabled")
  _watcher_hub_actions+=("mode:enabled")
  _watcher_hub_labels+=("${dis_mark} Disabled")
  _watcher_hub_actions+=("mode:disabled")

  _watcher_hub_labels+=("← Back")
  _watcher_hub_actions+=("back")
}

_watcher_hub() {
  local cursor=0
  local key
  local n
  local _watcher_hub_mode
  local _watcher_hub_labels=()
  local _watcher_hub_actions=()

  tput smcup 2>/dev/null
  tput civis 2>/dev/null
  trap '_menu_on_interrupt' INT TERM HUP QUIT PIPE

  _watcher_hub_draw_frame() {
    _watcher_hub_build_rows
    n=${#_watcher_hub_labels[@]}

    tput cup 0 0 2>/dev/null
    tput ed 2>/dev/null
    echo -e "\033[1mWatcher\033[0m"
    echo
    echo "  Auto-restart Claude Code in the container and resume (claude --continue)"
    echo "  when it exits abnormally. Up to 3 restarts per 10 minutes."
    echo
    local i
    for i in "${!_watcher_hub_labels[@]}"; do
      if [ "$i" -eq "$cursor" ]; then
        echo -e "  \033[1;36m→ ${_watcher_hub_labels[$i]}\033[0m"
      else
        echo "    ${_watcher_hub_labels[$i]}"
      fi
    done
    echo
    echo "  ↑/↓ — navigate, Space — set mode, Enter — select, q — quit"
  }

  _watcher_hub_draw_frame

  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      case "${_watcher_hub_actions[$cursor]}" in
        back)
          break
          ;;
        mode:*)
          :
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
      case "${_watcher_hub_actions[$cursor]}" in
        mode:*)
          watcher_set_mode "${_watcher_hub_actions[$cursor]#mode:}"
          ;;
      esac
    elif [[ $key == "q" ]]; then
      break
    fi

    _watcher_hub_draw_frame
  done

  trap - INT TERM HUP QUIT PIPE
  unset -f _watcher_hub_draw_frame
  tput cnorm 2>/dev/null
  tput rmcup 2>/dev/null
}

_watcher_hub
