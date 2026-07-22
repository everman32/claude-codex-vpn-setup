#!/bin/bash
# entrypoint.sh — Protects root-only VPN inputs, verifies that IPv6 is
# disabled, connects Windscribe through OpenVPN, installs an IPv4 kill switch,
# switches DNS to VPN-provided resolvers, verifies process/route/connectivity,
# opens selected host-published services, then hands off to CMD.
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
VPN_SOURCE_DIR="${VPN_SOURCE_DIR:-/run/vpn-source}"
VPN_CONFIG="${VPN_CONFIG:-$VPN_SOURCE_DIR/files/windscribe.ovpn}"
VPN_CREDS="${VPN_CREDS:-$VPN_SOURCE_DIR/files/credentials.txt}"
VPN_LOG="${VPN_LOG:-/var/log/openvpn.log}"
VPN_PID_FILE="${VPN_PID_FILE:-/var/run/openvpn.pid}"
VPN_READY_FILE="${VPN_READY_FILE:-/run/vpn-ready}"
VPN_TIMEOUT="${VPN_TIMEOUT:-90}"
VPN_DNS_STATE_DIR="${VPN_DNS_STATE_DIR:-/run/vpn-dns}"
VPN_DNS_UP_SCRIPT="${VPN_DNS_UP_SCRIPT:-/usr/local/sbin/vpn-dns-up}"
VPN_HEALTHCHECK_ROUTE_IP="${VPN_HEALTHCHECK_ROUTE_IP:-1.1.1.1}"
VPN_HEALTHCHECK_URL="${VPN_HEALTHCHECK_URL:-https://example.com/}"
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

# ───────────────── protect root-only VPN inputs ──────────────────
protect_vpn_inputs() {
    local path path_real source_real

    # The VPN directory is bind-mounted below this image-created parent.
    # Parent-directory traversal permissions protect every profile, key, and
    # credential file even if Docker Desktop reports permissive file modes.
    install -d -m 0700 -o root -g root "$VPN_SOURCE_DIR"
    chmod 0700 "$VPN_SOURCE_DIR"
    chown root:root "$VPN_SOURCE_DIR"
    source_real=$(realpath -e "$VPN_SOURCE_DIR")

    for path in "$VPN_CONFIG" "$VPN_CREDS"; do
        path_real=$(realpath -m "$path")
        [[ "$path_real" == "$source_real/"* ]] || {
            error "VPN input '$path' escapes protected directory '$VPN_SOURCE_DIR'."
            exit 1
        }
    done

    [[ -f "$VPN_CONFIG" ]] || {
        error "No VPN config found at '$VPN_CONFIG'."
        exit 1
    }

    if [[ -e "$VPN_CREDS" ]]; then
        [[ -f "$VPN_CREDS" ]] || {
            error "VPN credentials path is not a regular file: '$VPN_CREDS'."
            exit 1
        }

        if runuser -u dev -- test -r "$VPN_CREDS"; then
            error "VPN credentials are readable by the dev user."
            error "The protected parent directory must remain root:root mode 0700."
            exit 1
        fi
        log "VPN credentials are protected from the dev user"
    else
        log "No separate VPN credentials file mounted; continuing without --auth-user-pass"
    fi
}

# ─────────────────── explicit IPv6 shutdown ─────────────────────
verify_ipv6_disabled() {
    local path value

    [[ -d /proc/sys/net/ipv6/conf ]] || {
        log "IPv6 is unavailable in this network namespace"
        return 0
    }

    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ -r "$path" ]] || {
            error "Cannot verify IPv6 state at '$path'."
            exit 1
        }
        value=$(cat "$path")
        if [[ "$value" != "1" ]]; then
            error "IPv6 is not disabled for ${path%/disable_ipv6}."
            error "Keep the net.ipv6.conf.*.disable_ipv6 sysctls in docker-compose.yml."
            exit 1
        fi
    done

    if ip -6 address show scope global | grep -q 'inet6'; then
        error "A global IPv6 address remains after IPv6 was meant to be disabled."
        ip -6 address show scope global >&2 || true
        exit 1
    fi

    log "IPv6 is disabled for every interface in the container namespace"
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
# IPv6 is disabled at the network-namespace level and verified above. For
# IPv4, block all outbound traffic except loopback during bootstrap,
# established/related traffic, and the pre-resolved VPN endpoints. Later,
# tun0 and selected host service ports are allowed.
setup_kill_switch() {
    log "Installing iptables kill switch (IPv4)..."
    iptables -F OUTPUT
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

    log "IPv4 kill switch active — all other outbound traffic is blocked"
}

enable_tun_traffic() {
    iptables -A OUTPUT -o tun0 -j ACCEPT
    log "tun0 outbound traffic allowed"
}

block_docker_dns() {
    # Docker's embedded resolver DNATs 127.0.0.11:53 to a per-container,
    # high-numbered loopback port in the nat OUTPUT chain. The filter OUTPUT
    # chain therefore no longer sees destination port 53. Block the resolver's
    # address entirely, before the general loopback ACCEPT rule.
    iptables -I OUTPUT 1 -d "${DOCKER_DNS}/32" -j REJECT
    log "Docker embedded DNS blocked; external DNS must use VPN resolvers"
}

verify_docker_dns_blocked() {
    local test_host="${VPN_DNS_TEST_HOST:-example.com}"

    log "Verifying Docker embedded DNS is unreachable..."
    if timeout 5 nslookup "$test_host" "$DOCKER_DNS" >/dev/null 2>&1; then
        error "Docker embedded DNS at $DOCKER_DNS still answered a query."
        error "─── filter OUTPUT ─────────────────────────────"
        iptables -S OUTPUT >&2 || true
        error "─── nat OUTPUT / DOCKER_OUTPUT ────────────────"
        iptables -t nat -S OUTPUT >&2 || true
        iptables -t nat -S DOCKER_OUTPUT >&2 || true
        exit 1
    fi

    log "Docker embedded DNS is blocked"
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
    local config_dir config_name

    log "Launching OpenVPN..."
    rm -rf "$VPN_DNS_STATE_DIR"
    rm -f "$VPN_PID_FILE" "$VPN_READY_FILE"
    mkdir -p "$VPN_DNS_STATE_DIR"

    config_dir=$(dirname "$VPN_CONFIG")
    config_name=$(basename "$VPN_CONFIG")

    local args=(
        --cd "$config_dir"
        --config "$config_name"
        --daemon
        --log "$VPN_LOG"
        --writepid "$VPN_PID_FILE"
        --script-security 2
        --up "$VPN_DNS_UP_SCRIPT"
        --up-restart
        --verb 3
    )
    [[ -f "$VPN_CREDS" ]] && args+=(--auth-user-pass "$VPN_CREDS")
    openvpn "${args[@]}"
}

wait_for_vpn_route() {
    local elapsed=0 pid route

    log "Waiting for OpenVPN process, tun0, and a VPN route (timeout: ${VPN_TIMEOUT}s)..."
    while (( elapsed < VPN_TIMEOUT )); do
        if [[ -s "$VPN_PID_FILE" ]]; then
            pid=$(cat "$VPN_PID_FILE")
            if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
                show_openvpn_log_and_exit "OpenVPN exited before the tunnel became ready."
            fi
        fi

        if [[ -s "$VPN_PID_FILE" ]] && ip link show dev tun0 >/dev/null 2>&1; then
            local comm
            pid=$(cat "$VPN_PID_FILE")
            comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
            route=$(ip -4 route get "$VPN_HEALTHCHECK_ROUTE_IP" 2>/dev/null || true)
            if [[ "$pid" =~ ^[0-9]+$ ]] \
                && kill -0 "$pid" 2>/dev/null \
                && [[ "$comm" == openvpn* ]] \
                && [[ "$route" =~ dev[[:space:]]+tun0 ]]; then
                log "OpenVPN process, tun0, and route through tun0 are ready after ${elapsed}s ✓"
                return 0
            fi
        fi

        sleep 2
        (( elapsed+=2 ))
    done

    route=$(ip -4 route get "$VPN_HEALTHCHECK_ROUTE_IP" 2>/dev/null || true)
    show_openvpn_log_and_exit \
        "VPN was not ready within ${VPN_TIMEOUT}s; route to $VPN_HEALTHCHECK_ROUTE_IP: ${route:-no route}."
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

        if [[ -f "$VPN_PID_FILE" ]] && ! kill -0 "$(cat "$VPN_PID_FILE")" 2>/dev/null; then
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

# ───────────────── verify tunnel connectivity ───────────────────
verify_vpn_connectivity() {
    [[ -z "$VPN_HEALTHCHECK_URL" ]] && {
        warn "VPN_HEALTHCHECK_URL is blank; skipping the HTTPS startup check."
        return 0
    }

    log "Testing HTTPS connectivity through tun0..."
    if ! curl \
        --fail \
        --silent \
        --show-error \
        --output /dev/null \
        --connect-timeout 5 \
        --max-time "${VPN_HEALTHCHECK_HTTP_TIMEOUT:-10}" \
        --interface tun0 \
        "$VPN_HEALTHCHECK_URL";
    then
        show_openvpn_log_and_exit \
            "HTTPS connectivity through tun0 failed for '$VPN_HEALTHCHECK_URL'."
    fi
    log "HTTPS connectivity through tun0 succeeded"
}

verify_external_ip() {
    log "Checking external IP through tun0..."
    local ip
    ip=$(curl -s --max-time 10 --interface tun0 https://ifconfig.me 2>/dev/null \
         || echo "unknown")
    if [[ "$ip" == "unknown" ]]; then
        warn "Could not determine external IP; the mandatory connectivity check already passed."
    else
        log "External IP: $ip  ← should be a Windscribe exit node"
    fi
}

mark_vpn_ready() {
    : >"$VPN_READY_FILE"
    chmod 0644 "$VPN_READY_FILE"
    log "VPN health state marked ready"
}

# ─────────────────────────── main ────────────────────────────────
main() {
    rm -f "$VPN_READY_FILE"

    if [[ ! -x "$VPN_DNS_UP_SCRIPT" ]]; then
        error "VPN DNS helper is missing or not executable: $VPN_DNS_UP_SCRIPT"
        exit 1
    fi

    protect_vpn_inputs
    verify_ipv6_disabled
    parse_vpn_server
    pin_vpn_endpoint
    setup_kill_switch
    start_vpn
    wait_for_vpn_route
    wait_for_vpn_dns
    enable_tun_traffic
    block_docker_dns
    verify_docker_dns_blocked
    wait_for_dns_routes
    allow_host_services
    verify_dns_resolution
    verify_vpn_connectivity
    verify_external_ip
    mark_vpn_ready

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
