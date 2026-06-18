FROM ubuntu:22.04

LABEL description="Claude Code isolated environment with Windscribe VPN"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# System dependencies
# (iptables here also provides ip6tables, used by the kill switch.)
RUN apt-get update && apt-get install -y \
    curl wget ca-certificates gnupg \
    openvpn \
    iptables iproute2 net-tools \
    dnsutils iputils-ping \
    git \
    && rm -rf /var/lib/apt/lists/*

# Java build tools
RUN apt-get update && apt-get install -y \
    openjdk-21-jdk \
    maven \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20.x (Claude Code requires Node 18+)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code ──────────────────────────────────────────────────
# Pin the version for reproducible image builds. Default is `latest`;
# override per build for a locked, predictable CLI, e.g.:
#   docker compose build --build-arg CLAUDE_CODE_VERSION=2.1.170
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Claude Code is installed globally as root, but runs as the `dev` user, so it
# cannot write to the global npm dir to self-update — which otherwise produces
# a one-time "couldn't auto-update" notice at every startup. Disable the
# background updater; you update deliberately by rebuilding this image.
# For a hard pin that also blocks manual `claude update`, use DISABLE_UPDATES=1.
ENV DISABLE_AUTOUPDATER=1

# Non-root user for Claude Code (recommended)
RUN useradd -m -s /bin/bash dev \
    && mkdir -p /workspace \
    && chown dev:dev /workspace \
    # Pre-create the mountpoints so the named volume / bind mount inherit
    # correct (dev-owned) permissions instead of defaulting to root.
    && mkdir -p /home/dev/.claude-state /home/dev/.m2 \
    && chown -R dev:dev /home/dev/.claude-state /home/dev/.m2

# Default location for Claude Code state (config, credentials, sessions).
# Compose mounts a volume here; setting it in the image keeps `docker run`
# usage self-consistent too.
ENV CLAUDE_CONFIG_DIR=/home/dev/.claude-state

# entrypoint runs as root to configure VPN/iptables; the actual work
# (Claude Code, Maven) is run as `dev` via `docker exec -u dev`.
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Mark the container unhealthy if the VPN tunnel interface disappears.
# start-period covers the initial OpenVPN connect (see VPN_TIMEOUT).
HEALTHCHECK --interval=30s --timeout=5s --start-period=100s --retries=3 \
    CMD ip link show tun0 >/dev/null 2>&1 || exit 1

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
# Default: keep container alive so you can docker exec into it
CMD ["sleep", "infinity"]