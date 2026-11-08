#!/bin/bash

_menu_on_interrupt() {
  tput cnorm 2>/dev/null
  tput rmcup 2>/dev/null
  unset -f _menu_select_draw_frame _menu_multiselect_draw_frame
  [ -n "${MENU_ON_INTERRUPT:-}" ] && "$MENU_ON_INTERRUPT"
  unset MENU_ON_INTERRUPT
  trap - INT TERM HUP QUIT PIPE
  kill -s TERM "$$"
}

menu_select() {
  local title="$1"
  shift
  local options=("$@")
  local selected=0
  local key
  local n=${#options[@]}

  tput smcup 2>/dev/null
  tput civis 2>/dev/null
  trap '_menu_on_interrupt' INT TERM HUP QUIT PIPE

  _menu_select_draw_frame() {
    tput cup 0 0 2>/dev/null
    tput ed 2>/dev/null
    [ -n "${MENU_HEADER:-}" ] && "$MENU_HEADER"
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

  _menu_select_draw_frame

  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      trap - INT TERM HUP QUIT PIPE
      unset -f _menu_select_draw_frame
      unset MENU_ON_INTERRUPT
      tput cnorm 2>/dev/null
      tput rmcup 2>/dev/null
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
      trap - INT TERM HUP QUIT PIPE
      unset -f _menu_select_draw_frame
      unset MENU_ON_INTERRUPT
      tput cnorm 2>/dev/null
      tput rmcup 2>/dev/null
      return 255
    fi

    _menu_select_draw_frame
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
  local is_action=()
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
    descs[i]="$desc"
    if [[ "$label" == "##"* ]]; then
      labels[i]="$label"
      is_header[i]=1
      is_action[i]=0
      sel_index_map[i]=-1
    elif [[ "$label" == "@@"* ]]; then
      labels[i]="${label#@@}"
      is_header[i]=0
      is_action[i]=1
      sel_index_map[i]=-1
    else
      labels[i]="$label"
      is_header[i]=0
      is_action[i]=0
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

  tput smcup 2>/dev/null
  tput civis 2>/dev/null
  trap '_menu_on_interrupt' INT TERM HUP QUIT PIPE

  _menu_multiselect_draw_frame() {
    tput cup 0 0 2>/dev/null
    tput ed 2>/dev/null
    [ -n "${MENU_HEADER:-}" ] && "$MENU_HEADER"
    echo -e "\033[1m${title}\033[0m"
    echo
    for ((i = 0; i < n; i++)); do
      if [ "${is_header[$i]}" -eq 1 ]; then
        echo -e "  \033[1m${labels[$i]#\#\#}\033[0m"
      elif [ "${is_action[$i]}" -eq 1 ]; then
        if [ "$i" -eq "$cursor" ]; then
          echo -e "  \033[1;36m→ ${labels[$i]}\033[0m"
        else
          echo "    ${labels[$i]}"
        fi
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

  _menu_multiselect_draw_frame

  local key
  while true; do
    IFS= read -rsn1 key

    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      trap - INT TERM HUP QUIT PIPE
      unset -f _menu_multiselect_draw_frame
      unset MENU_ON_INTERRUPT
      tput cnorm 2>/dev/null
      tput rmcup 2>/dev/null
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
      if [ "$sidx" -ge 0 ]; then
        if [ "${MS_STATE[$sidx]}" = "1" ]; then
          MS_STATE[$sidx]="0"
        else
          MS_STATE[$sidx]="1"
        fi
        if [ -n "${MS_ON_TOGGLE:-}" ]; then
          if [ -n "${MS_SLUGS[$sidx]+set}" ]; then
            local slug="${MS_SLUGS[$sidx]}"
            "$MS_ON_TOGGLE" "$slug" "${MS_STATE[$sidx]}"
          else
            echo "[menu] WARNING: no MS_SLUGS entry for index $sidx — MS_ON_TOGGLE not called." >&2
          fi
        fi
      fi
    elif [[ $key == "q" ]]; then
      local j
      for ((j = 0; j < ${#MS_STATE[@]}; j++)); do
        MS_STATE[$j]="${entry_state[$j]}"
      done
      trap - INT TERM HUP QUIT PIPE
      unset -f _menu_multiselect_draw_frame
      unset MENU_ON_INTERRUPT
      tput cnorm 2>/dev/null
      tput rmcup 2>/dev/null
      return 255
    fi

    _menu_multiselect_draw_frame
  done
}
