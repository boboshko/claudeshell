#!/bin/bash
set -e

REPO="boboshko/claudeshell"
SCRIPT_ROOT="${SCRIPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
  echo "No target version specified."
  exit 1
fi

echo "Downloading ClaudeShell ${TARGET_VERSION}..."

tmp_tar="$(mktemp)"
tmp_extract="$(mktemp -d)"
trap 'rm -f "$tmp_tar"; rm -rf "$tmp_extract"' EXIT

url="https://github.com/${REPO}/archive/refs/tags/${TARGET_VERSION}.tar.gz"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$tmp_tar"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$url" -O "$tmp_tar"
else
  echo "Need curl or wget, and neither was found."
  exit 1
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
