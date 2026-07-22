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
        util-linux \
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
    && install -d -m 0700 -o root -g root /run/vpn-source \
    && mkdir -p \
        /workspace \
        /home/dev/.ai-state/claude \
        /home/dev/.ai-state/codex \
        /home/dev/.m2/repository \
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
COPY scripts/vpn-dns.sh /usr/local/sbin/vpn-dns-up
COPY scripts/vpn-healthcheck.sh /usr/local/sbin/vpn-healthcheck
RUN chmod 0755 \
        /entrypoint.sh \
        /usr/local/sbin/vpn-dns-up \
        /usr/local/sbin/vpn-healthcheck

HEALTHCHECK \
    --interval=30s \
    --timeout=25s \
    --start-period=100s \
    --retries=3 \
    CMD ["/usr/local/sbin/vpn-healthcheck"]

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]