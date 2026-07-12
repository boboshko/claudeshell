FROM node:20-slim

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    curl \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

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
