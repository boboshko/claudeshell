#!/bin/bash
set -e

REPO="boboshko/claudeshell"
BRANCH="main"
SCRIPT_ROOT="${SCRIPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
  echo "No target version specified."
  exit 1
fi

tmp_tar="$(mktemp)"
tmp_extract="$(mktemp -d)"
trap 'rm -f "$tmp_tar" /tmp/claudeshell-curl-err; rm -rf "$tmp_extract"' EXIT

_download_tarball() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" 2>/tmp/claudeshell-curl-err || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest" 2>/tmp/claudeshell-curl-err || return 1
  else
    echo "Need curl or wget, and neither was found."
    return 1
  fi

  if [ "$(head -c 2 "$dest" | od -An -tx1 | tr -d ' ')" != "1f8b" ]; then
    return 1
  fi
  return 0
}

echo "Downloading ClaudeShell ${TARGET_VERSION}..."

if ! _download_tarball "https://github.com/${REPO}/archive/refs/tags/${TARGET_VERSION}.tar.gz" "$tmp_tar"; then
  echo "Couldn't download release '${TARGET_VERSION}'. Falling back to the ${BRANCH} branch..."
  if ! _download_tarball "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" "$tmp_tar"; then
    echo
    echo "Couldn't download the archive for ${REPO} (tag ${TARGET_VERSION} or branch ${BRANCH})."
    if [ -f /tmp/claudeshell-curl-err ]; then
      echo "curl/wget error:"
      cat /tmp/claudeshell-curl-err
    fi
    exit 1
  fi
  echo "Downloaded the ${BRANCH} branch instead of ${TARGET_VERSION}."
fi

echo "Extracting..."
tar -xzf "$tmp_tar" -C "$tmp_extract" --strip-components=1

cp -R "$tmp_extract"/. "$SCRIPT_ROOT"/

chmod +x \
  "$SCRIPT_ROOT"/start.sh \
  "$SCRIPT_ROOT"/install.sh \
  "$SCRIPT_ROOT"/scripts/*.sh \
  "$SCRIPT_ROOT"/docker/entrypoint.sh \
  "$SCRIPT_ROOT"/docker/init-firewall.sh \
  2>/dev/null || true

rm -f "$SCRIPT_ROOT/docker/.build-hash"

echo "Updated to ${TARGET_VERSION}."
