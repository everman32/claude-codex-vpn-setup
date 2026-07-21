#!/bin/bash
# entrypoint.sh — Connects Windscribe via OpenVPN, installs an IPv4+IPv6 kill
# switch, switches DNS to VPN-provided resolvers, verifies the tunnel, opens a
# hole for selected host-published services, then hands off to CMD.
#
# Privilege note: this script runs as root to configure the VPN and iptables,
# then exec's CMD (default: `sleep infinity`) — which therefore also runs as
# root. The actual work (Claude Code, Codex, Maven) is run as the unprivileged
# `dev` user via docker exec.
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
VPN_TIMEOUT="${VPN_TIMEOUT:-90}"
VPN_DNS_STATE_DIR="${VPN_DNS_STATE_DIR:-/run/vpn-dns}"
VPN_DNS_UP_SCRIPT="${VPN_DNS_UP_SCRIPT:-/usr/local/sbin/vpn-dns-up}"
DOCKER_DNS="127.0.0.11"

is_ipv4() {
    local address="$1" octet
    local -a octets
    local IFS='.'

    read -r -a octets <<<"$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

show_openvpn_log_and_exit() {
    local message="$1"
    error "$message"
    error "─── OpenVPN log ───────────────────────────────"
    if [[ -f "$VPN_LOG" ]]; then
        cat "$VPN_LOG" >&2
    else
        error "OpenVPN log is not available."
    fi
    exit 1
}

# ─────────────────────── parse VPN server ────────────────────────
parse_vpn_server() {
    local line

    line=$(grep "^remote " "$VPN_CONFIG" | head -1)
    VPN_REMOTE=$(awk '{print $2}' <<<"$line")
    VPN_PORT=$(awk '{print $3}' <<<"$line")
    VPN_PROTO=$(grep "^proto " "$VPN_CONFIG" | head -1 | awk '{print $2}')
    VPN_PROTO="${VPN_PROTO:-udp}"

    # Resolve before activating the kill switch. These addresses are both
    # firewall-allowlisted and pinned in /etc/hosts so OpenVPN reconnects do
    # not need Docker's host-forwarding resolver after DNS lockdown.
    VPN_IPS=$(getent ahostsv4 "$VPN_REMOTE" 2>/dev/null | awk '{print $1}' | sort -u)

    if [[ -z "$VPN_IPS" ]]; then
        if is_ipv4 "$VPN_REMOTE"; then
            VPN_IPS="$VPN_REMOTE"
        else
            error "Could not resolve VPN endpoint '$VPN_REMOTE' before enabling the kill switch."
            exit 1
        fi
    fi

    log "VPN server: $VPN_REMOTE → [$(echo "$VPN_IPS" | tr '\n' ' ')] :$VPN_PORT/$VPN_PROTO"
}

pin_vpn_endpoint() {
    local vip

    is_ipv4 "$VPN_REMOTE" && return 0

    {
        printf '\n# ai-vpn: VPN endpoint pinned before DNS lockdown\n'
        for vip in $VPN_IPS; do
            printf '%s\t%s\n' "$vip" "$VPN_REMOTE"
        done
    } >>/etc/hosts

    log "Pinned $VPN_REMOTE in /etc/hosts for DNS-independent reconnects"
}

# ─────────────────────── kill switch ─────────────────────────────
# Block all outbound IPv4 and IPv6 except:
#   • loopback during bootstrap
#   • established/related traffic
#   • the pre-resolved VPN endpoint IPs
# Later, tun0 and selected host service ports are allowed. Docker's embedded
# resolver is explicitly blocked after VPN DNS has been installed.
setup_kill_switch() {
    log "Installing iptables kill switch (IPv4)..."
    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT DROP

    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    if [[ -n "$VPN_PORT" ]]; then
        local vip
        for vip in $VPN_IPS; do
            iptables -A OUTPUT -d "$vip" -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT
            log "Allowed VPN endpoint $vip:$VPN_PORT/$VPN_PROTO"
        done
    fi

    # IPv6 is blocked outright because this setup uses an IPv4 VPN endpoint.
    if command -v ip6tables >/dev/null 2>&1; then
        log "Installing kill switch (IPv6 — full block)..."
        ip6tables -F OUTPUT 2>/dev/null || true
        ip6tables -P OUTPUT DROP 2>/dev/null || true
        ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi

    log "Kill switch active — all other outbound traffic is blocked"
}

enable_tun_traffic() {
    iptables -A OUTPUT -o tun0 -j ACCEPT
    command -v ip6tables >/dev/null 2>&1 && \
        ip6tables -A OUTPUT -o tun0 -j ACCEPT 2>/dev/null || true
    log "tun0 outbound traffic allowed"
}

block_docker_dns() {
    # Insert these before the general loopback ACCEPT rule. This prevents
    # applications from bypassing /etc/resolv.conf and directly querying
    # Docker's 127.0.0.11 resolver, which forwards to host-configured DNS.
    iptables -I OUTPUT 1 -d "$DOCKER_DNS" -p udp --dport 53 -j REJECT
    iptables -I OUTPUT 1 -d "$DOCKER_DNS" -p tcp --dport 53 -j REJECT
    log "Docker embedded DNS blocked; external DNS must use VPN resolvers"
}

# ───────────────── allow host-published services ─────────────────
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

# ─────────────────────── start OpenVPN ───────────────────────────
start_vpn() {
    log "Launching OpenVPN..."
    rm -rf "$VPN_DNS_STATE_DIR"
    mkdir -p "$VPN_DNS_STATE_DIR"

    local args=(
        --config "$VPN_CONFIG"
        --daemon
        --log "$VPN_LOG"
        --writepid /var/run/openvpn.pid
        --script-security 2
        --up "$VPN_DNS_UP_SCRIPT"
        --up-restart
        --verb 3
    )
    [[ -f "$VPN_CREDS" ]] && args+=(--auth-user-pass "$VPN_CREDS")
    openvpn "${args[@]}"
}

wait_for_tun() {
    log "Waiting for tunnel interface tun0 (timeout: ${VPN_TIMEOUT}s)..."
    local elapsed=0

    while (( elapsed < VPN_TIMEOUT )); do
        ip link show tun0 &>/dev/null && {
            log "tun0 is up after ${elapsed}s ✓"
            return 0
        }
        sleep 2
        (( elapsed+=2 ))
    done

    show_openvpn_log_and_exit "tun0 did not appear within ${VPN_TIMEOUT}s — VPN failed to connect."
}

wait_for_vpn_dns() {
    local ready_file="$VPN_DNS_STATE_DIR/ready"
    local servers_file="$VPN_DNS_STATE_DIR/servers"
    local elapsed=0

    log "Waiting for OpenVPN DNS configuration..."
    while (( elapsed < VPN_TIMEOUT )); do
        if [[ -f "$ready_file" && -s "$servers_file" ]]; then
            log "VPN DNS configured: $(tr '\n' ' ' <"$servers_file")"
            return 0
        fi

        if [[ -f /var/run/openvpn.pid ]] && ! kill -0 "$(cat /var/run/openvpn.pid)" 2>/dev/null; then
            show_openvpn_log_and_exit "OpenVPN exited before DNS was configured."
        fi

        sleep 1
        (( elapsed+=1 ))
    done

    show_openvpn_log_and_exit \
        "OpenVPN did not provide DNS within ${VPN_TIMEOUT}s. Set VPN_DNS if the profile does not push dhcp-option DNS."
}

wait_for_dns_routes() {
    local dns route elapsed=0 all_on_tun

    log "Waiting for VPN DNS routes through tun0..."
    while (( elapsed < VPN_TIMEOUT )); do
        all_on_tun=1

        while IFS= read -r dns; do
            [[ -n "$dns" ]] || continue
            route=$(ip -4 route get "$dns" 2>/dev/null || true)
            if [[ ! "$route" =~ dev[[:space:]]+tun0 ]]; then
                all_on_tun=0
                break
            fi
        done <"$VPN_DNS_STATE_DIR/servers"

        if (( all_on_tun )); then
            log "All DNS resolvers route through tun0"
            return 0
        fi

        sleep 1
        (( elapsed+=1 ))
    done

    while IFS= read -r dns; do
        [[ -n "$dns" ]] || continue
        route=$(ip -4 route get "$dns" 2>/dev/null || true)
        error "DNS server $dns is not routed through tun0: ${route:-no route}"
    done <"$VPN_DNS_STATE_DIR/servers"
    exit 1
}

verify_dns_resolution() {
    local test_host="${VPN_DNS_TEST_HOST:-example.com}"

    log "Testing DNS through the VPN with '$test_host'..."
    if ! timeout 10 getent ahostsv4 "$test_host" >/dev/null 2>&1; then
        show_openvpn_log_and_exit "VPN DNS could not resolve '$test_host'."
    fi
    log "VPN DNS resolution succeeded"
}

# ──────────────────── verify external IP ─────────────────────────
verify_vpn() {
    log "Checking external IP through tun0..."
    local ip
    ip=$(curl -s --max-time 10 --interface tun0 https://ifconfig.me 2>/dev/null \
         || echo "unknown")
    if [[ "$ip" == "unknown" ]]; then
        warn "Could not determine external IP — proceeding anyway."
    else
        log "External IP: $ip  ← should be a Windscribe exit node"
    fi
}

# ─────────────────────────── main ────────────────────────────────
main() {
    if [[ ! -f "$VPN_CONFIG" ]]; then
        error "No VPN config found at '$VPN_CONFIG'."
        error "Mount your windscribe.ovpn file:"
        error "  -v /path/to/vpn:/vpn:ro"
        exit 1
    fi

    if [[ ! -x "$VPN_DNS_UP_SCRIPT" ]]; then
        error "VPN DNS helper is missing or not executable: $VPN_DNS_UP_SCRIPT"
        exit 1
    fi

    parse_vpn_server
    pin_vpn_endpoint
    setup_kill_switch
    start_vpn
    wait_for_tun
    wait_for_vpn_dns
    enable_tun_traffic
    block_docker_dns
    wait_for_dns_routes
    allow_host_services
    verify_dns_resolution
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
