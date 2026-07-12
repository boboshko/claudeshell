#!/bin/bash
set -e

stty sane 2>/dev/null || true

url=""

CLIPBOARD_CMD=""
if command -v pbpaste >/dev/null 2>&1; then
  CLIPBOARD_CMD="pbpaste"
elif command -v wl-paste >/dev/null 2>&1; then
  CLIPBOARD_CMD="wl-paste"
elif command -v xclip >/dev/null 2>&1; then
  CLIPBOARD_CMD="xclip -selection clipboard -o"
elif command -v xsel >/dev/null 2>&1; then
  CLIPBOARD_CMD="xsel --clipboard --output"
elif command -v powershell.exe >/dev/null 2>&1; then
  CLIPBOARD_CMD="powershell.exe -NoProfile -Command Get-Clipboard"
elif command -v powershell >/dev/null 2>&1; then
  CLIPBOARD_CMD="powershell -NoProfile -Command Get-Clipboard"
fi

if [ -n "$CLIPBOARD_CMD" ]; then
  echo "Copy the authorization link and just press Enter —"
  echo "I'll grab it straight from the clipboard, no need to paste it here"
  echo "(if you paste it anyway, that's fine too — it'll just be ignored)."
  echo
  read -r _junk
  url="$($CLIPBOARD_CMD | tr -d '\r\n')"
  echo
  echo "Got this from the clipboard:"
  echo "$url"
  echo
  read -r -p "Look right? Press Enter to continue, or Ctrl+C to cancel... " _junk
else
  echo "Couldn't find a clipboard tool"
  echo "(pbpaste / wl-paste / xclip / xsel / powershell) — paste the link manually:"
  echo
  read -r url
fi

if [ -z "$url" ]; then
  echo "Empty link, cancelling."
  exit 0
fi

fixed="${url//code=true\&/}"
fixed="${fixed//org%3Acreate_api_key+/}"
fixed="${fixed//org%3Acreate_api_key%2B/}"
fixed="${fixed//org:create_api_key+/}"

echo
echo "Fixed link:"
echo
echo "$fixed"
echo
echo "Open it in your browser, log in, and paste the resulting code back into Claude Code."
read -r -p "Press Enter to go back to the menu... " _junk
