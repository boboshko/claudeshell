#!/bin/bash
set -e

source "$SCRIPT_ROOT/scripts/lib-tools.sh"

cd "$SCRIPT_ROOT/docker"

# prepull_base_image — pull the Dockerfile's base image on the host, with retries,
# BEFORE `docker compose build` runs. BuildKit resolves `FROM` (its "load metadata
# for ..." step) over the network before any RUN executes, so the retry helpers
# that live inside the Dockerfile (apt-retry/fetch-retry/run-retry) cannot cover
# it: a slow or unreachable registry makes that metadata HEAD request time out and
# fails the whole build at line 1. Pre-pulling into the local image store means the
# subsequent `FROM` resolves locally with no network round-trip. Same 5-attempt
# 5+10+15+20s back-off shape as the in-Dockerfile helpers; fails loud on give-up.
prepull_base_image() {
  local image attempt delay
  # First FROM in the Dockerfile; skip an optional `--platform=...`/`--flag` token
  # and ignore a trailing `AS <stage>`, leaving the bare image reference.
  image="$(awk 'toupper($1)=="FROM"{for(i=2;i<=NF;i++){if($i !~ /^--/){print $i; exit}}}' Dockerfile)"
  if [ -z "$image" ] || case "$image" in *'$'*) true;; *) false;; esac; then
    echo "build-image: base image not a plain reference ('${image}') — skipping pre-pull, letting the build resolve it." >&2
    return 0
  fi

  # Already in the local image store: FROM resolves locally, no pull needed.
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi

  attempt=1
  while :; do
    if docker pull "$image"; then
      return 0
    fi
    if [ "$attempt" -ge 5 ]; then
      break
    fi
    delay=$((attempt * 5))
    echo "build-image: base image pull attempt ${attempt}/5 failed (${image}), retrying in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done

  # Give up loud — but if a local copy exists after all (e.g. a concurrent pull or
  # a stale-but-usable cache), let the build proceed with it instead of failing.
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "build-image: pull of ${image} failed but a local copy is present — continuing with the cached image." >&2
    return 0
  fi
  echo "build-image: could not pull base image ${image} after 5 attempts — check network/proxy access to the container registry (e.g. registry-1.docker.io)." >&2
  return 1
}

export CACHE_BUST="$(date +%s)"

# OCI label values — build provenance stamped into the image metadata (not its name).
# BUILD_DATE is RFC 3339 UTC; APP_VERSION is the toolkit VERSION (source of truth for
# versioning — the image itself stays a single rolling claudeshell:latest tag).
export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export APP_VERSION="$(tr -d '[:space:]' < "$SCRIPT_ROOT/VERSION" 2>/dev/null || true)"
: "${APP_VERSION:=unknown}"

tools_export_build_args

prepull_base_image

PULL_FLAG=()
[ "${BUILD_PULL:-0}" = "1" ] && PULL_FLAG=(--pull)

if [ -f .env ]; then
  docker compose -p claudeshell --env-file .env -f docker-compose.yml build "${PULL_FLAG[@]}"
else
  docker compose -p claudeshell -f docker-compose.yml build "${PULL_FLAG[@]}"
fi

echo
echo "Image built."
