FROM node:20-slim

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
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
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

ARG TOOL_DOCKER_CLI=0
RUN if [ "$TOOL_DOCKER_CLI" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && apt-get install -y --no-install-recommends docker-ce-cli && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_DOCKER_COMPOSE=0
RUN if [ "$TOOL_DOCKER_COMPOSE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && apt-get install -y --no-install-recommends docker-compose-plugin && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_PYTHON=0
RUN if [ "$TOOL_PYTHON" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_GO=0
RUN if [ "$TOOL_GO" = "1" ]; then \
      curl -fsSL "https://go.dev/dl/go1.23.4.linux-$(dpkg --print-architecture).tar.gz" \
        | tar -C /usr/local -xz && \
      ln -s /usr/local/go/bin/go /usr/local/bin/go; \
    fi

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
ARG TOOL_RUST=0
RUN if [ "$TOOL_RUST" = "1" ]; then \
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable && \
      chmod -R a+rX /usr/local/rustup /usr/local/cargo; \
    fi

ARG TOOL_JAVA=0
RUN if [ "$TOOL_JAVA" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends default-jdk && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_MAKE=0
RUN if [ "$TOOL_MAKE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends make && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_CMAKE=0
RUN if [ "$TOOL_CMAKE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends cmake && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_BUILD_ESSENTIAL=0
RUN if [ "$TOOL_BUILD_ESSENTIAL" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends build-essential clang && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_GH_CLI=0
RUN if [ "$TOOL_GH_CLI" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg && \
      chmod a+r /etc/apt/keyrings/githubcli.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
      apt-get update && apt-get install -y --no-install-recommends gh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_POSTGRES=0
RUN if [ "$TOOL_POSTGRES" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends postgresql-client && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_MONGODB=0
RUN if [ "$TOOL_MONGODB" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gnupg && \
      install -m 0755 -d /usr/share/keyrings && \
      curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --batch --yes --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg && \
      chmod a+r /usr/share/keyrings/mongodb-server-7.0.gpg && \
      . /etc/os-release && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/debian ${VERSION_CODENAME}/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list && \
      apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_REDIS=0
RUN if [ "$TOOL_REDIS" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends redis-tools && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_PNPM=0
RUN if [ "$TOOL_PNPM" = "1" ]; then \
      npm install -g pnpm; \
    fi

ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH
ARG TOOL_BUN=0
RUN if [ "$TOOL_BUN" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends unzip && \
      curl -fsSL https://bun.sh/install | bash && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_UV=0
RUN if [ "$TOOL_UV" = "1" ]; then \
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    fi

ARG TOOL_SSH_CLIENT=0
RUN if [ "$TOOL_SSH_CLIENT" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends openssh-client && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_RSYNC=0
RUN if [ "$TOOL_RSYNC" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends rsync && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_JQ=0
RUN if [ "$TOOL_JQ" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends jq && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG TOOL_YQ=0
RUN if [ "$TOOL_YQ" = "1" ]; then \
      curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" && \
      chmod +x /usr/local/bin/yq; \
    fi

ARG TOOL_WGET=0
RUN if [ "$TOOL_WGET" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends wget && \
      rm -rf /var/lib/apt/lists/*; \
    fi

COPY xcode-shims/xcodebuild xcode-shims/xcrun xcode-shims/simctl /usr/local/bin/
RUN chmod +x /usr/local/bin/xcodebuild /usr/local/bin/xcrun /usr/local/bin/simctl

RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /home/claude/.npm \
    && chown -R claude:claude /home/claude \
    && echo "claude ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh" >> /etc/sudoers

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

ENV CLAUDE_CONFIG_DIR=/home/claude/.claude

WORKDIR /workspace

USER claude

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
