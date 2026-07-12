#!/bin/bash
set -e

REPO="boboshko/claudeshell"
BRANCH="main"
TARGET_DIR="${1:-./claude-shell}"

echo "Installing ClaudeShell into: $TARGET_DIR"

if [ -e "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
  echo "That folder already exists and isn't empty."
  read -r -p "Install/update on top of it? (y/N) " confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "Cancelled."; exit 1 ;;
  esac
fi

mkdir -p "$TARGET_DIR"

tmp_tar="$(mktemp)"
tmp_extract="$(mktemp -d)"
trap 'rm -f "$tmp_tar" /tmp/claudeshell-curl-err; rm -rf "$tmp_extract"' EXIT

_download_tarball() {
  local branch="$1"
  local dest="$2"
  local url="https://github.com/${REPO}/archive/refs/heads/${branch}.tar.gz"

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

echo "Downloading the latest version from GitHub (branch ${BRANCH})..."
if ! _download_tarball "$BRANCH" "$tmp_tar"; then
  echo "Branch '${BRANCH}' didn't work. Trying to detect the default branch via the GitHub API..."
  default_branch="$(curl -fsSL "https://api.github.com/repos/${REPO}" 2>/dev/null | grep -o '"default_branch"[^,]*' | grep -o '"[^"]*"$' | tr -d '"')"

  if [ -n "$default_branch" ] && [ "$default_branch" != "$BRANCH" ]; then
    echo "Found default branch: ${default_branch}. Trying again..."
    if ! _download_tarball "$default_branch" "$tmp_tar"; then
      echo
      echo "Couldn't download the archive from branch '${default_branch}' either."
      echo "The repo ${REPO} might not be public, might be private, or the URL might be wrong."
      exit 1
    fi
  else
    echo
    echo "Couldn't download the archive for ${REPO} (branch ${BRANCH})."
    echo "Check that the repo is public and exists."
    if [ -f /tmp/claudeshell-curl-err ]; then
      echo "curl/wget error:"
      cat /tmp/claudeshell-curl-err
    fi
    exit 1
  fi
fi

echo "Extracting..."
tar -xzf "$tmp_tar" -C "$tmp_extract" --strip-components=1

cp -R "$tmp_extract"/. "$TARGET_DIR"/

chmod +x \
  "$TARGET_DIR"/start.sh \
  "$TARGET_DIR"/install.sh \
  "$TARGET_DIR"/scripts/*.sh \
  "$TARGET_DIR"/docker/entrypoint.sh \
  "$TARGET_DIR"/docker/init-firewall.sh \
  2>/dev/null || true

echo
echo "Done! ClaudeShell is installed at: $TARGET_DIR"
echo
echo "Next:"
echo "  cd $TARGET_DIR"
echo "  cp docker/.env.example docker/.env"
echo "  ./start.sh"
