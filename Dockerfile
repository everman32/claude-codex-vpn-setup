FROM ubuntu:22.04

LABEL description="Codex and Claude Code isolated development environment with OpenVPN"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# ── System dependencies ─────────────────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        curl \
        wget \
        ca-certificates \
        gnupg \
        openvpn \
        iptables \
        iproute2 \
        net-tools \
        dnsutils \
        iputils-ping \
        git \
        openssh-client \
        procps \
        less \
        jq \
        bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# ── Java build tools ─────────────────────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-21-jdk \
        maven \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js ──────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── AI coding CLIs ───────────────────────────────────────────────
# Use explicit versions for reproducible builds:
#
# docker compose build \
#   --build-arg CLAUDE_CODE_VERSION=2.1.170 \
#   --build-arg CODEX_VERSION=0.144.1
#
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest

RUN npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force

# Claude's global npm installation is root-owned, while the CLI runs as dev.
ENV DISABLE_AUTOUPDATER=1

# ── Non-root development user ────────────────────────────────────
RUN useradd -m -s /bin/bash dev \
    && mkdir -p \
        /workspace \
        /home/dev/.ai-state/claude \
        /home/dev/.ai-state/codex \
        /home/dev/.m2 \
    && chown -R dev:dev \
        /workspace \
        /home/dev/.ai-state \
        /home/dev/.m2

# Separate state locations inside one persisted volume.
ENV CLAUDE_CONFIG_DIR=/home/dev/.ai-state/claude
ENV CODEX_HOME=/home/dev/.ai-state/codex

# Ensure container-created files have predictable ownership defaults.
ENV HOME=/home/dev
ENV USER=dev

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=100s \
    --retries=3 \
    CMD ip link show tun0 >/dev/null 2>&1 || exit 1

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]