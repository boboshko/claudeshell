#!/bin/bash
set -e

SCRIPT_ROOT="${SCRIPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SCRIPT_ROOT

source "$SCRIPT_ROOT/scripts/lib-tools.sh"
source "$SCRIPT_ROOT/scripts/lib-build.sh"

tools_conf_ensure

echo "Refreshing Claude Code and the base image — pulling the latest and rebuilding..."
echo

export BUILD_PULL=1
rm -f "$BUILD_HASH_FILE"
bash "$SCRIPT_ROOT/scripts/build-image.sh"
build_compute_hash > "$BUILD_HASH_FILE"

echo
echo "Done. The image now has the latest Claude Code and base-image updates."
