FROM node:20-slim

ARG CLAUDE_CODE_VERSION=latest

# apt-retry PACKAGE... — runs "apt-get update" + "apt-get install" as one unit
# and retries the whole unit on any transient network failure (a failed install
# always gets a fresh update, because apt-get update can return 0 with only
# warnings when an index fails to download). At most 5 attempts with a growing
# back-off (5+10+15+20 = 50s of sleep, none after the 5th failure or on first-try
# success); every failed attempt and the final give-up are reported on stderr.
# Depends only on apt-get + sleep, so it works in the base step before curl exists.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -u' \
      'if [ "$#" -lt 1 ]; then echo "usage: apt-retry PACKAGE..." >&2; exit 2; fi' \
      'attempt=1' \
      'while :; do' \
      '  if apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y --no-install-recommends "$@"; then exit 0; fi' \
      '  if [ "$attempt" -ge 5 ]; then break; fi' \
      '  delay=$((attempt * 5))' \
      '  echo "apt-retry: attempt ${attempt}/5 failed (apt-get update + install $*), retrying in ${delay}s..." >&2' \
      '  sleep "$delay"' \
      '  attempt=$((attempt + 1))' \
      'done' \
      'echo "apt-retry: attempt 5/5 failed (apt-get update + install $*) - giving up; check network/proxy access to the apt repositories used by this step" >&2' \
      'exit 1' \
      > /usr/local/bin/apt-retry \
    && chmod +x /usr/local/bin/apt-retry

# fetch-retry URL — prints the download to stdout, retrying on any network
# error. It downloads to a temp file first, so a retry after a mid-transfer
# drop never feeds partial or duplicated data into a consumer (gpg, tar, sh).
# curl's own --retry 5 absorbs blips; on exhaustion, or on a zero-byte body,
# it prints nothing on stdout and exits non-zero naming the URL, so the "$()"/
# redirect consumer never runs on a bad download.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'if [ "$#" -ne 1 ]; then echo "usage: fetch-retry URL" >&2; exit 2; fi' \
      'tmp=$(mktemp)' \
      'cleanup() { rm -f "$tmp"; }' \
      'trap cleanup EXIT' \
      'if ! curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o "$tmp" "$1"; then' \
      '  echo "fetch-retry: download failed: $1 - check network/proxy access to that host" >&2' \
      '  exit 1' \
      'fi' \
      'if [ ! -s "$tmp" ]; then' \
      '  echo "fetch-retry: empty response (0 bytes): $1" >&2' \
      '  exit 1' \
      'fi' \
      'cat "$tmp"' \
      > /usr/local/bin/fetch-retry \
    && chmod +x /usr/local/bin/fetch-retry

# run-retry LABEL COMMAND [ARG...] — retries a self-downloading installer
# (rustup/bun/uv) as a whole when its own nested downloads fail transiently.
# LABEL is free text naming the operation and its hosts; the command and its
# args are run via "$@" (no eval). At most 5 attempts, same 5+10+15+20 back-off
# as apt-retry. Optional env RETRY_CLEAN is a whitespace-separated list of
# absolute paths removed before attempts 2..5 (never before attempt 1) so each
# retry starts from the same state as the first; a relative entry aborts with
# exit 2 before anything runs.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -u' \
      'if [ "$#" -lt 2 ]; then echo "usage: run-retry LABEL COMMAND [ARG...] (optional env RETRY_CLEAN: absolute paths removed before each retry)" >&2; exit 2; fi' \
      'label=$1' \
      'shift' \
      'set -f' \
      'for p in ${RETRY_CLEAN:-}; do' \
      '  case "$p" in' \
      '    /?*) ;;' \
      '    *) echo "run-retry: RETRY_CLEAN entries must be absolute paths: $p" >&2; exit 2 ;;' \
      '  esac' \
      'done' \
      'attempt=1' \
      'while :; do' \
      '  "$@" && exit 0' \
      '  rc=$?' \
      '  if [ "$attempt" -ge 5 ]; then break; fi' \
      '  delay=$((attempt * 5))' \
      '  echo "run-retry: attempt ${attempt}/5 failed (${label}, exit ${rc}), retrying in ${delay}s..." >&2' \
      '  sleep "$delay"' \
      '  for p in ${RETRY_CLEAN:-}; do rm -rf -- "$p"; done' \
      '  attempt=$((attempt + 1))' \
      'done' \
      'echo "run-retry: attempt 5/5 failed (${label}, exit ${rc}) - giving up; check network/proxy access to the hosts named above" >&2' \
      'exit 1' \
      > /usr/local/bin/run-retry \
    && chmod +x /usr/local/bin/run-retry

RUN apt-retry \
    ca-certificates \
    git \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    curl \
    sudo \
    && rm -rf /var/lib/apt/lists/*

ARG CACHE_BUST=1
# The npm registry connection can drop mid-handshake (ECONNRESET) on flaky
# networks; raise npm's own fetch retries and retry the whole install a few
# times before failing the build.
RUN for attempt in 1 2 3 4 5; do \
      npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        --fetch-retries=5 \
        --fetch-retry-mintimeout=10000 \
        --fetch-retry-maxtimeout=60000 \
        && exit 0; \
      if [ "$attempt" -lt 5 ]; then \
        echo "npm install failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..." >&2; \
        sleep $((attempt * 5)); \
      fi; \
    done; \
    echo "npm install failed after 5 attempts — check network/proxy access to registry.npmjs.org" >&2; \
    exit 1

ARG TOOL_DOCKER_CLI=0
RUN if [ "$TOOL_DOCKER_CLI" = "1" ]; then \
      apt-retry gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      tmp=$(mktemp) && \
      fetch-retry https://download.docker.com/linux/debian/gpg > "$tmp" && \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg "$tmp" && \
      rm -f "$tmp" && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
      apt-retry docker-ce-cli && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_DOCKER_COMPOSE=0
RUN if [ "$TOOL_DOCKER_COMPOSE" = "1" ]; then \
      apt-retry gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      tmp=$(mktemp) && \
      fetch-retry https://download.docker.com/linux/debian/gpg > "$tmp" && \
      gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg "$tmp" && \
      rm -f "$tmp" && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
      apt-retry docker-compose-plugin && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_PYTHON=0
RUN if [ "$TOOL_PYTHON" = "1" ]; then \
      apt-retry python3 python3-pip python3-venv && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_GO=0
RUN if [ "$TOOL_GO" = "1" ]; then \
      tmp=$(mktemp) && \
      fetch-retry "https://go.dev/dl/go1.23.4.linux-$(dpkg --print-architecture).tar.gz" > "$tmp" && \
      tar -C /usr/local -xzf "$tmp" && \
      rm -f "$tmp" && \
      ln -s /usr/local/go/bin/go /usr/local/bin/go; \
    fi

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
ARG TOOL_RUST=0
RUN if [ "$TOOL_RUST" = "1" ]; then \
      tmp=$(mktemp) && \
      fetch-retry https://sh.rustup.rs > "$tmp" && \
      RETRY_CLEAN="/usr/local/rustup /usr/local/cargo" run-retry "rustup installer (sh.rustup.rs, static.rust-lang.org)" sh "$tmp" -y --no-modify-path --default-toolchain stable && \
      rm -f "$tmp" && \
      /usr/local/cargo/bin/cargo --version && \
      /usr/local/cargo/bin/rustc --version && \
      chmod -R a+rX /usr/local/rustup /usr/local/cargo; \
    fi

ARG TOOL_JAVA=0
RUN if [ "$TOOL_JAVA" = "1" ]; then \
      apt-retry default-jdk && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_MAKE=0
RUN if [ "$TOOL_MAKE" = "1" ]; then \
      apt-retry make && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_CMAKE=0
RUN if [ "$TOOL_CMAKE" = "1" ]; then \
      apt-retry cmake && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_BUILD_ESSENTIAL=0
RUN if [ "$TOOL_BUILD_ESSENTIAL" = "1" ]; then \
      apt-retry build-essential clang && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_GH_CLI=0
RUN if [ "$TOOL_GH_CLI" = "1" ]; then \
      apt-retry gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      fetch-retry https://cli.github.com/packages/githubcli-archive-keyring.gpg > /etc/apt/keyrings/githubcli.gpg && \
      chmod a+r /etc/apt/keyrings/githubcli.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
      apt-retry gh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_POSTGRES=0
RUN if [ "$TOOL_POSTGRES" = "1" ]; then \
      apt-retry postgresql-client && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_MONGODB=0
RUN if [ "$TOOL_MONGODB" = "1" ]; then \
      apt-retry gnupg && \
      install -m 0755 -d /usr/share/keyrings && \
      tmp=$(mktemp) && \
      fetch-retry https://pgp.mongodb.com/server-7.0.asc > "$tmp" && \
      gpg --batch --yes --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg "$tmp" && \
      rm -f "$tmp" && \
      chmod a+r /usr/share/keyrings/mongodb-server-7.0.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/debian ${VERSION_CODENAME}/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list && \
      apt-retry mongodb-mongosh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_REDIS=0
RUN if [ "$TOOL_REDIS" = "1" ]; then \
      apt-retry redis-tools && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_PNPM=0
RUN if [ "$TOOL_PNPM" = "1" ]; then \
      for attempt in 1 2 3 4 5; do \
        npm install -g pnpm \
          --fetch-retries=5 \
          --fetch-retry-mintimeout=10000 \
          --fetch-retry-maxtimeout=60000 \
          && exit 0; \
        if [ "$attempt" -lt 5 ]; then \
          echo "npm install pnpm failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..." >&2; \
          sleep $((attempt * 5)); \
        fi; \
      done; \
      echo "npm install pnpm failed after 5 attempts — check network/proxy access to registry.npmjs.org" >&2; \
      exit 1; \
    fi

ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH
ARG TOOL_BUN=0
RUN if [ "$TOOL_BUN" = "1" ]; then \
      apt-retry unzip && \
      tmp=$(mktemp) && \
      fetch-retry https://bun.sh/install > "$tmp" && \
      RETRY_CLEAN="/usr/local/bun" run-retry "bun installer (bun.sh, github.com)" bash "$tmp" && \
      rm -f "$tmp" && \
      /usr/local/bun/bin/bun --version && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_UV=0
RUN if [ "$TOOL_UV" = "1" ]; then \
      tmp=$(mktemp) && \
      fetch-retry https://astral.sh/uv/install.sh > "$tmp" && \
      RETRY_CLEAN="/usr/local/bin/uv /usr/local/bin/uvx" run-retry "uv installer (astral.sh, github.com)" env UV_INSTALL_DIR=/usr/local/bin sh "$tmp" && \
      rm -f "$tmp" && \
      /usr/local/bin/uv --version; \
    fi

ARG TOOL_SSH_CLIENT=0
RUN if [ "$TOOL_SSH_CLIENT" = "1" ]; then \
      apt-retry openssh-client && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_RSYNC=0
RUN if [ "$TOOL_RSYNC" = "1" ]; then \
      apt-retry rsync && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_JQ=0
RUN if [ "$TOOL_JQ" = "1" ]; then \
      apt-retry jq && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_YQ=0
RUN if [ "$TOOL_YQ" = "1" ]; then \
      fetch-retry "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" > /usr/local/bin/yq && \
      chmod +x /usr/local/bin/yq; \
    fi

ARG TOOL_WGET=0
RUN if [ "$TOOL_WGET" = "1" ]; then \
      apt-retry wget && \
      rm -rf /var/lib/apt/lists/*; \
    fi

COPY xcode-shims/xcodebuild xcode-shims/xcrun xcode-shims/simctl /usr/local/bin/
RUN chmod +x /usr/local/bin/xcodebuild /usr/local/bin/xcrun /usr/local/bin/simctl

RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /home/claude/.npm \
    && chown -R claude:claude /home/claude \
    && echo "claude ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh" >> /etc/sudoers \
    && echo "claude ALL=(ALL) NOPASSWD: /usr/local/bin/fix-docker-sock.sh" >> /etc/sudoers

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY fix-docker-sock.sh /usr/local/bin/fix-docker-sock.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/fix-docker-sock.sh

ENV CLAUDE_CONFIG_DIR=/home/claude/.claude

WORKDIR /workspace

USER claude

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# OCI image metadata (build provenance). Declared here as the final, zero-size
# metadata layer so a changing BUILD_DATE only rebuilds this layer, never the
# expensive tool layers above. Versioning lives in the toolkit VERSION/git tag and
# is stamped here via org.opencontainers.image.version; the image name/tag stays a
# single rolling claudeshell:latest. BUILD_DATE/APP_VERSION are passed by
# scripts/build-image.sh (RFC 3339 UTC date, and the VERSION file); they default to
# "unknown" so a plain `docker build` without them still succeeds.
ARG BUILD_DATE=unknown
ARG APP_VERSION=unknown
LABEL org.opencontainers.image.title="claudeshell" \
      org.opencontainers.image.description="Claude Code in an isolated Docker sandbox" \
      org.opencontainers.image.source="https://github.com/boboshko/claudeshell" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      com.claudeshell.claude-code.version="${CLAUDE_CODE_VERSION}"
