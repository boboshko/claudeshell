#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-mounts.sh"

while true; do
  clear
  current_mounts=()
  while IFS= read -r line; do
    current_mounts+=("$line")
  done < <(mounts_list)

  options=()
  if [ ${#current_mounts[@]} -eq 0 ]; then
    options+=("(nothing mounted yet)")
  else
    for i in "${!current_mounts[@]}"; do
      options+=("[$((i+1))] ${current_mounts[$i]}  →  remove")
    done
  fi
  options+=("+ Add a path")
  options+=("← Back")

  menu_select "Mounted project folders" "${options[@]}"
  choice=$?

  last_index=$(( ${#options[@]} - 1 ))
  add_index=$(( ${#options[@]} - 2 ))

  if [ "$choice" -eq 255 ] || [ "$choice" -eq "$last_index" ]; then
    break
  elif [ "$choice" -eq "$add_index" ]; then
    echo
    read -rep "Enter the full path to a folder (you can drag a folder into the terminal): " new_path
    new_path="${new_path/#\~/$HOME}"
    if [ -z "$new_path" ]; then
      echo "Empty, skipping."
    elif [ ! -d "$new_path" ]; then
      echo "No such folder: $new_path"
    else
      mounts_add "$new_path" && echo "Added: $new_path"
    fi
    press_enter_to_continue
  elif [ ${#current_mounts[@]} -gt 0 ] && [ "$choice" -lt ${#current_mounts[@]} ]; then
    removed="${current_mounts[$choice]}"
    mounts_remove_by_index $((choice + 1))
    echo
    echo "Removed: $removed"
    press_enter_to_continue
  fi
done

mounts_generate_override
echo
echo "Path list saved. No image rebuild needed —"
echo "the change will apply automatically next time you run Claude Code (item 1)."
press_enter_to_continue
