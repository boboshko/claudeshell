#!/bin/bash

source "$SCRIPT_ROOT/scripts/lib-menu.sh"
source "$SCRIPT_ROOT/scripts/lib-firewall.sh"

_fw_menu_slugs=()

_fw_on_toggle() {
  local slug="$1" state="$2"
  local onoff="off"
  [ "$state" = "1" ] && onoff="on"
  firewall_set_service "$slug" "$onoff"
}

_fw_cleanup_abort() {
  if [ "$_fw_entry_existed" = "1" ]; then
    cp -p "$FIREWALL_CONF" "${FIREWALL_CONF}.tmp" && cat "$_fw_entry_snapshot" > "${FIREWALL_CONF}.tmp" && mv -f "${FIREWALL_CONF}.tmp" "$FIREWALL_CONF"
  else
    rm -f "$FIREWALL_CONF"
  fi
}

_fw_manage_services() {
  local labels=()
  _fw_menu_slugs=()

  labels+=("##Anthropic API/Console — required, always allowed")

  local slug
  for slug in $(firewall_known_services); do
    _fw_menu_slugs+=("$slug")
    labels+=("$(firewall_service_label "$slug") ($slug)|$(firewall_service_description "$slug")")
  done

  MS_STATE=()
  local i
  for i in "${!_fw_menu_slugs[@]}"; do
    if firewall_service_enabled "${_fw_menu_slugs[$i]}"; then
      MS_STATE+=("1")
    else
      MS_STATE+=("0")
    fi
  done

  local _fw_entry_existed=0
  local _fw_entry_snapshot
  _fw_entry_snapshot="$(mktemp)"
  if [ -f "$FIREWALL_CONF" ]; then
    _fw_entry_existed=1
    cp "$FIREWALL_CONF" "$_fw_entry_snapshot"
  fi

  MS_SLUGS=("${_fw_menu_slugs[@]}")
  MS_ON_TOGGLE="_fw_on_toggle"
  MENU_ON_INTERRUPT="_fw_cleanup_abort"
  menu_multiselect "Firewall services — $(firewall_active_count) active (Space toggles, Enter saves, q cancels)" "${labels[@]}"
  local rc=$?
  unset MS_ON_TOGGLE
  unset MENU_ON_INTERRUPT

  if [ "$rc" -eq 255 ]; then
    _fw_cleanup_abort
  else
    for i in "${!_fw_menu_slugs[@]}"; do
      local onoff="off"
      [ "${MS_STATE[$i]:-0}" = "1" ] && onoff="on"
      firewall_set_service "${_fw_menu_slugs[$i]}" "$onoff"
    done
  fi

  rm -f "$_fw_entry_snapshot"
}

_fw_add_custom() {
  echo
  read -rep "Enter a domain (example.com) or IPv4 CIDR (10.0.0.0/24): " value
  if [ -z "$value" ]; then
    echo "Empty, skipping."
  elif firewall_custom_add "$value"; then
    echo "Added: $value"
  fi
  press_enter_to_continue
}

_fw_manage_custom() {
  while true; do
    clear
    local entries=()
    while IFS= read -r entry; do
      [ -n "$entry" ] && entries+=("$entry")
    done < <(firewall_custom_list)

    local options=()
    if [ ${#entries[@]} -eq 0 ]; then
      options+=("(no custom entries yet)")
    else
      local i
      for i in "${!entries[@]}"; do
        options+=("[$((i + 1))] ${entries[$i]}  →  remove")
      done
    fi
    options+=("← Back")

    menu_select "Custom domain/CIDR entries" "${options[@]}"
    local choice=$?

    local last_index=$(( ${#options[@]} - 1 ))
    if [ "$choice" -eq 255 ] || [ "$choice" -eq "$last_index" ]; then
      break
    elif [ ${#entries[@]} -gt 0 ] && [ "$choice" -lt ${#entries[@]} ]; then
      local removed="${entries[$choice]}"
      firewall_custom_remove $((choice + 1))
      echo
      echo "Removed: $removed"
      press_enter_to_continue
    fi
  done
}

_fw_restore_defaults() {
  echo
  read -rep "Restore recommended defaults? This resets mode, all service toggles, AND removes every custom domain/CIDR entry. [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    firewall_restore_defaults
    echo "Restored recommended defaults."
  else
    echo "Cancelled."
  fi
  press_enter_to_continue
}

while true; do
  clear
  firewall_conf_ensure
  current_mode="$(firewall_mode)"

  if [ "$current_mode" = "disabled" ]; then
    mode_options=("Disabled (current) — unrestricted egress" \
      "Recommended — default-deny + allow-list")
    mode_values=("disabled" "recommended")
  else
    mode_options=("Recommended (current) — default-deny + allow-list, $(firewall_active_count) service(s) active" \
      "Disabled — unrestricted egress")
    mode_values=("recommended" "disabled")
  fi

  options=("${mode_options[@]}")
  if [ "$current_mode" = "recommended" ]; then
    options+=("Manage allowed services")
    options+=("+ Add custom domain/CIDR")
    options+=("View/remove custom entries")
  fi
  options+=("Restore recommended defaults")
  options+=("← Back")

  menu_select "Firewall" "${options[@]}"
  choice=$?

  last_index=$(( ${#options[@]} - 1 ))
  if [ "$choice" -eq 255 ] || [ "$choice" -eq "$last_index" ]; then
    break
  fi

  if [ "$choice" -lt 2 ]; then
    firewall_set_mode "${mode_values[$choice]}"
    continue
  fi

  rest_index=$(( choice - 2 ))
  if [ "$current_mode" = "recommended" ]; then
    case "$rest_index" in
      0) _fw_manage_services ;;
      1) _fw_add_custom ;;
      2) _fw_manage_custom ;;
      3) _fw_restore_defaults ;;
    esac
  else
    case "$rest_index" in
      0) _fw_restore_defaults ;;
    esac
  fi
done
