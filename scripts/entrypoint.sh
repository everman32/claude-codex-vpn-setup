#!/bin/bash
# entrypoint.sh — Connects Windscribe via OpenVPN, installs an IPv4+IPv6 kill
# switch, verifies the tunnel, opens a hole for host-published services
# (Postgres/Kafka via host.docker.internal), then hands off to CMD.
#
# Privilege note: this script runs as root to configure the VPN and iptables,
# then exec's CMD (default: `sleep infinity`) — which therefore also runs as
# root. That is intentional and harmless; the actual work (Claude Code, Maven)
# is run as the unprivileged `dev` user via `docker exec -u dev`.
set -euo pipefail

# ──────────────────────────── colours ────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[VPN]${NC} $*"; }
warn()  { echo -e "${YELLOW}[VPN]${NC} $*"; }
error() { echo -e "${RED}[VPN]${NC} $*" >&2; }

# ─────────────────────────── config ──────────────────────────────
VPN_CONFIG="${VPN_CONFIG:-/vpn/windscribe.ovpn}"
VPN_CREDS="${VPN_CREDS:-/vpn/credentials.txt}"
VPN_LOG="/var/log/openvpn.log"
VPN_TIMEOUT="${VPN_TIMEOUT:-90}"   # seconds to wait for tun0

# ─────────────────────── parse VPN server ────────────────────────
parse_vpn_server() {
    local line
    line=$(grep "^remote " "$VPN_CONFIG" | head -1)
    VPN_REMOTE=$(awk '{print $2}' <<<"$line")
    VPN_PORT=$(awk '{print $3}'   <<<"$line")
    VPN_PROTO=$(grep "^proto " "$VPN_CONFIG" | head -1 | awk '{print $2}')
    VPN_PROTO="${VPN_PROTO:-udp}"

    # Resolve hostname → ALL IPv4 addresses (some Windscribe hosts round-robin
    # across several A records; OpenVPN may pick a different one than we'd get
    # from a single lookup, so we allow every resolved IP in the kill switch).
    # Resolution happens here, BEFORE the kill switch, while OUTPUT is still
    # ACCEPT, so DNS works.
    VPN_IPS=$(getent ahostsv4 "$VPN_REMOTE" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -z "$VPN_IPS" ] && VPN_IPS="$VPN_REMOTE"
    log "VPN server: $VPN_REMOTE → [$(echo $VPN_IPS | tr '\n' ' ')] :$VPN_PORT/$VPN_PROTO"
}

# ─────────────────────── kill switch ─────────────────────────────
# Block ALL outbound (IPv4 AND IPv6) except:
#   • loopback (also covers Docker's embedded DNS at 127.0.0.11)
#   • established/related (keeps the live VPN handshake alive)
#   • traffic to each resolved VPN server IP:PORT (for connect & reconnect)
# Later we add: allow tun0 (all VPN-tunnelled traffic) and the local Docker
# subnet (host-published services). IPv6 is blocked outright since Windscribe
# is reached over IPv4 — this prevents an IPv6 leak path around the tunnel.
setup_kill_switch() {
    log "Installing iptables kill switch (IPv4)..."
    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT DROP

    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    if [ -n "$VPN_PORT" ]; then
        local vip
        for vip in $VPN_IPS; do
            iptables -A OUTPUT -d "$vip" -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT
            log "Allowed VPN endpoint $vip:$VPN_PORT/$VPN_PROTO"
        done
    fi

    # IPv6: deny everything except loopback / established. tun0 added later.
    if command -v ip6tables >/dev/null 2>&1; then
        log "Installing kill switch (IPv6 — full block)..."
        ip6tables -F OUTPUT 2>/dev/null || true
        ip6tables -P OUTPUT DROP 2>/dev/null || true
        ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi

    log "Kill switch active — all other outbound is blocked"
}

enable_tun_traffic() {
    iptables -A OUTPUT -o tun0 -j ACCEPT
    command -v ip6tables >/dev/null 2>&1 && \
        ip6tables -A OUTPUT -o tun0 -j ACCEPT 2>/dev/null || true
    log "tun0 outbound traffic allowed"
}

# ───────────────── allow host-published services ─────────────────
# Permit traffic to the local Docker subnet + the host gateway so the app can
# reach Postgres/Kafka/etc. that you run in Docker on the HOST and expose via
# host.docker.internal. This traffic stays on the Docker host and never leaves
# to the public internet, so it does NOT defeat the kill switch / leak your IP.
# This whole step is BEST-EFFORT: a failure here must never abort VPN bringup,
# so each iptables call is guarded and we never let a bad value reach iptables.
allow_host_services() {
    local hgw ports

    ports="${HOST_SERVICE_TCP_PORTS:-5434,19092}"

    hgw=$(
        getent ahostsv4 host.docker.internal 2>/dev/null |
        awk '{print $1}' |
        head -1 ||
        true
    )

    if [[ ! "$hgw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "host.docker.internal did not resolve to IPv4."
        warn "Host services will not be reachable from the container."
        return 0
    fi

    if [[ ! "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        warn "Invalid HOST_SERVICE_TCP_PORTS value: '$ports'."
        warn "Expected a comma-separated list such as: 5434,19092"
        return 0
    fi

    if iptables -A OUTPUT \
        -o eth0 \
        -d "$hgw" \
        -p tcp \
        -m multiport \
        --dports "$ports" \
        -j ACCEPT
    then
        log "Allowed host services at $hgw on TCP ports: $ports"
    else
        warn "Could not add host-service firewall rule."
    fi
}

# ─────────────────────── start openvpn ───────────────────────────
start_vpn() {
    log "Launching OpenVPN..."
    local args=(
        --config "$VPN_CONFIG"
        --daemon
        --log   "$VPN_LOG"
        --writepid /var/run/openvpn.pid
        --script-security 2
        --verb 3
    )
    [ -f "$VPN_CREDS" ] && args+=(--auth-user-pass "$VPN_CREDS")
    openvpn "${args[@]}"
}

wait_for_tun() {
    log "Waiting for tunnel interface tun0 (timeout: ${VPN_TIMEOUT}s)..."
    local elapsed=0
    while (( elapsed < VPN_TIMEOUT )); do
        ip link show tun0 &>/dev/null && { log "tun0 is up after ${elapsed}s ✓"; return 0; }
        sleep 2; (( elapsed+=2 ))
    done
    error "tun0 did not appear within ${VPN_TIMEOUT}s — VPN failed to connect."
    error "─── OpenVPN log ───────────────────────────────"
    cat "$VPN_LOG" >&2
    exit 1
}

# ──────────────────── verify external IP ─────────────────────────
verify_vpn() {
    log "Checking external IP through tun0..."
    local ip
    ip=$(curl -s --max-time 10 --interface tun0 https://ifconfig.me 2>/dev/null \
         || echo "unknown")
    if [ "$ip" = "unknown" ]; then
        warn "Could not determine external IP — proceeding anyway."
    else
        log "External IP: $ip  ← should be a Windscribe exit node"
    fi
}

# ─────────────────────────── main ────────────────────────────────
main() {
    if [ ! -f "$VPN_CONFIG" ]; then
        error "No VPN config found at '$VPN_CONFIG'."
        error "Mount your windscribe.ovpn file:"
        error "  -v /path/to/vpn:/vpn:ro"
        exit 1
    fi

    parse_vpn_server
    setup_kill_switch
    start_vpn
    wait_for_tun
    enable_tun_traffic
    allow_host_services
    verify_vpn

    echo ""
    log "════════════════════════════════════════════════"
    log " VPN is active. Workspace: /workspace"
    log ""
    log " Codex:"
    log "   docker exec -it -u dev -w /workspace ai-vpn codex"
    log ""
    log " Claude Code:"
    log "   docker exec -it -u dev -w /workspace ai-vpn claude"
    log "════════════════════════════════════════════════"
    echo ""

    exec "$@"
}

main "$@"