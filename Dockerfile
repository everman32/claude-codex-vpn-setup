FROM ubuntu:22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
        socat \
    && rm -rf /var/lib/apt/lists/*

# ── Java build tools ─────────────────────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-21-jdk \
        maven \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 24 ───────────────────────────────────────────────────
# Configure NodeSource explicitly instead of executing a downloaded setup
# script. The major release is fixed; Ubuntu security/package updates remain
# available when the image is rebuilt.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && chmod 0644 /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── AI coding CLIs ───────────────────────────────────────────────
# Pin stable CLI releases for reproducible builds. Override deliberately with
# docker compose build --build-arg NAME=VERSION when testing an upgrade.
ARG CLAUDE_CODE_VERSION=2.1.217
ARG CODEX_VERSION=0.145.0

RUN npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force \
    && node --version | grep -Eq '^v24\.' \
    && claude --version | grep -Fq "${CLAUDE_CODE_VERSION}" \
    && codex --version | grep -Fq "${CODEX_VERSION}" \
    && bwrap --version \
    && socat -V >/dev/null

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
COPY scripts/ai-sandbox-check.sh /usr/local/sbin/ai-sandbox-check
COPY scripts/claude-managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod 0644 /etc/claude-code/managed-settings.json \
    && chmod 0755 \
        /entrypoint.sh \
        /usr/local/sbin/vpn-dns-up \
        /usr/local/sbin/vpn-healthcheck \
        /usr/local/sbin/ai-sandbox-check

HEALTHCHECK \
    --interval=30s \
    --timeout=25s \
    --start-period=100s \
    --retries=3 \
    CMD ["/usr/local/sbin/vpn-healthcheck"]

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]