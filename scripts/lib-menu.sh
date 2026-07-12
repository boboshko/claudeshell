#!/bin/bash

menu_select() {
  local title="$1"
  shift
  local options=("$@")
  local selected=0
  local key
  local n=${#options[@]}

  tput civis 2>/dev/null

  _draw_menu() {
    echo -e "\033[1m${title}\033[0m"
    echo
    for i in "${!options[@]}"; do
      if [ "$i" -eq "$selected" ]; then
        echo -e "  \033[1;36m→ ${options[$i]}\033[0m"
      else
        echo "    ${options[$i]}"
      fi
    done
    echo
    echo "  ↑/↓ — navigate, Enter — select, q — quit"
  }

  local lines_drawn=$(( n + 4 ))

  _draw_menu

  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      tput cnorm 2>/dev/null
      return $selected
    elif [[ $key == $'\x1b' ]]; then
      read -rsn2 key
      case "$key" in
        '[A')
          selected=$(( (selected - 1 + n) % n ))
          ;;
        '[B')
          selected=$(( (selected + 1) % n ))
          ;;
      esac
    elif [[ $key == "q" ]]; then
      tput cnorm 2>/dev/null
      return 255
    fi

    for ((i = 0; i < lines_drawn; i++)); do
      tput cuu1 2>/dev/null
      tput el 2>/dev/null
    done
    _draw_menu
  done
}

press_enter_to_continue() {
  echo
  read -rsn1 -p "Press any key to continue..."
  echo
}
