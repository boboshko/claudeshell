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

menu_multiselect() {
  local title="$1"
  shift
  local raw_items=("$@")
  local n=${#raw_items[@]}
  local labels=()
  local descs=()
  local is_header=()
  local sel_index_map=()
  local sel_count=0
  local i

  for ((i = 0; i < n; i++)); do
    local item="${raw_items[$i]}"
    local label="${item%%|*}"
    local desc=""
    if [[ "$item" == *"|"* ]]; then
      desc="${item#*|}"
    fi
    labels[i]="$label"
    descs[i]="$desc"
    if [[ "$label" == "##"* ]]; then
      is_header[i]=1
      sel_index_map[i]=-1
    else
      is_header[i]=0
      sel_index_map[i]=$sel_count
      sel_count=$((sel_count + 1))
    fi
  done

  local entry_state=("${MS_STATE[@]}")
  local cursor=0
  for ((i = 0; i < n; i++)); do
    if [ "${is_header[$i]}" -eq 0 ]; then
      cursor=$i
      break
    fi
  done

  tput civis 2>/dev/null

  _ms_draw() {
    echo -e "\033[1m${title}\033[0m"
    echo
    for ((i = 0; i < n; i++)); do
      if [ "${is_header[$i]}" -eq 1 ]; then
        echo -e "  \033[1m${labels[$i]#\#\#}\033[0m"
      else
        local sidx="${sel_index_map[$i]}"
        local mark="[ ]"
        [ "${MS_STATE[$sidx]}" = "1" ] && mark="[*]"
        local line="${mark} ${labels[$i]}"
        [ -n "${descs[$i]}" ] && line="${line} — ${descs[$i]}"
        if [ "$i" -eq "$cursor" ]; then
          echo -e "  \033[1;36m→ ${line}\033[0m"
        else
          echo "    ${line}"
        fi
      fi
    done
    echo
    echo "  ↑/↓ — navigate, Space — toggle, Enter — confirm, q — cancel"
    if [ -n "${MS_MESSAGE:-}" ]; then
      echo "  ${MS_MESSAGE}"
    else
      echo
    fi
  }

  local lines_drawn=$(( n + 5 ))

  _ms_draw

  local key
  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      tput cnorm 2>/dev/null
      return 0
    elif [[ $key == $'\x1b' ]]; then
      read -rsn2 key
      case "$key" in
        '[A')
          local next=$cursor
          while true; do
            next=$(( (next - 1 + n) % n ))
            if [ "${is_header[$next]}" -eq 0 ]; then
              cursor=$next
              break
            fi
          done
          ;;
        '[B')
          local next=$cursor
          while true; do
            next=$(( (next + 1) % n ))
            if [ "${is_header[$next]}" -eq 0 ]; then
              cursor=$next
              break
            fi
          done
          ;;
      esac
    elif [[ $key == " " ]]; then
      local sidx="${sel_index_map[$cursor]}"
      if [ "${MS_STATE[$sidx]}" = "1" ]; then
        MS_STATE[$sidx]="0"
      else
        MS_STATE[$sidx]="1"
      fi
      if [ -n "${MS_ON_TOGGLE:-}" ]; then
        local slug="${MS_SLUGS[$sidx]:-$sidx}"
        "$MS_ON_TOGGLE" "$slug" "${MS_STATE[$sidx]}"
      fi
    elif [[ $key == "q" ]]; then
      local j
      for ((j = 0; j < ${#MS_STATE[@]}; j++)); do
        MS_STATE[$j]="${entry_state[$j]}"
      done
      tput cnorm 2>/dev/null
      return 255
    fi

    for ((i = 0; i < lines_drawn; i++)); do
      tput cuu1 2>/dev/null
      tput el 2>/dev/null
    done
    _ms_draw
  done
}
