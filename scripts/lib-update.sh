#!/bin/bash

UPDATE_REPO="boboshko/claudeshell"
UPDATE_CACHE_FILE="$SCRIPT_ROOT/.update-cache"
UPDATE_CACHE_TTL=3600

_update_current_version() {
  tr -d '[:space:]' < "$SCRIPT_ROOT/VERSION" 2>/dev/null
}

_update_fetch_latest_tag() {
  curl -fsSL --max-time 3 "https://api.github.com/repos/${UPDATE_REPO}/releases/latest" 2>/dev/null \
    | grep -o '"tag_name"[^,]*' | grep -o '"[^"]*"$' | tr -d '"'
}

_update_is_newer() {
  local latest="$1" current="$2"
  [ -n "$latest" ] || return 1
  [ "$latest" != "$current" ] || return 1
  [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)" = "$latest" ]
}

check_for_update() {
  local now cached_time cached_tag current
  current="$(_update_current_version)"
  now="$(date +%s)"

  if [ -f "$UPDATE_CACHE_FILE" ]; then
    read -r cached_time cached_tag < "$UPDATE_CACHE_FILE" 2>/dev/null
    if [ -n "$cached_time" ] && [ $(( now - cached_time )) -lt "$UPDATE_CACHE_TTL" ]; then
      LATEST_VERSION="$cached_tag"
      _update_is_newer "$LATEST_VERSION" "$current"
      return $?
    fi
  fi

  local tag
  tag="$(_update_fetch_latest_tag)"
  echo "$now $tag" > "$UPDATE_CACHE_FILE" 2>/dev/null

  LATEST_VERSION="$tag"
  _update_is_newer "$LATEST_VERSION" "$current"
}
