#!/usr/bin/env bash
# Docker health check for the VPN namespace.
# Verifies the OpenVPN process, tunnel interface, routing, VPN DNS, HTTPS
# connectivity through tun0, and the IPv6-disabled invariant.
set -euo pipefail

PID_FILE="${VPN_PID_FILE:-/var/run/openvpn.pid}"
READY_FILE="${VPN_READY_FILE:-/run/vpn-ready}"
DNS_SERVERS_FILE="${VPN_DNS_STATE_DIR:-/run/vpn-dns}/servers"
ROUTE_IP="${VPN_HEALTHCHECK_ROUTE_IP:-1.1.1.1}"
TEST_HOST="${VPN_HEALTHCHECK_HOST:-example.com}"
TEST_URL="${VPN_HEALTHCHECK_URL:-https://example.com/}"
DNS_TIMEOUT="${VPN_HEALTHCHECK_DNS_TIMEOUT:-8}"
HTTP_TIMEOUT="${VPN_HEALTHCHECK_HTTP_TIMEOUT:-10}"

fail() {
    printf '[VPN HEALTH] %s\n' "$*" >&2
    exit 1
}

check_ipv6_disabled() {
    local path value

    [[ -d /proc/sys/net/ipv6/conf ]] || return 0

    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ -r "$path" ]] || fail "Cannot read IPv6 state at $path"
        value=$(cat "$path")
        [[ "$value" == "1" ]] || fail "IPv6 is enabled for ${path%/disable_ipv6}"
    done

    if ip -6 address show scope global | grep -q 'inet6'; then
        fail "A global IPv6 address is present"
    fi
}

check_openvpn_process() {
    local pid comm

    [[ -s "$PID_FILE" ]] || fail "OpenVPN PID file is missing"
    pid=$(cat "$PID_FILE")
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "OpenVPN PID is invalid: '$pid'"
    kill -0 "$pid" 2>/dev/null || fail "OpenVPN process $pid is not running"

    comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
    [[ "$comm" == openvpn* ]] || fail "PID $pid is '$comm', not OpenVPN"
}

check_tunnel_and_routes() {
    local route dns

    ip link show dev tun0 >/dev/null 2>&1 || fail "tun0 is missing"
    ip link show dev tun0 | grep -q '<[^>]*UP[,>]' || fail "tun0 is not UP"

    route=$(ip -4 route get "$ROUTE_IP" 2>/dev/null || true)
    [[ "$route" =~ dev[[:space:]]+tun0 ]] || \
        fail "Route to $ROUTE_IP does not use tun0: ${route:-no route}"

    [[ -s "$DNS_SERVERS_FILE" ]] || fail "VPN DNS server state is missing"
    while IFS= read -r dns; do
        [[ -n "$dns" ]] || continue
        route=$(ip -4 route get "$dns" 2>/dev/null || true)
        [[ "$route" =~ dev[[:space:]]+tun0 ]] || \
            fail "Route to DNS server $dns does not use tun0: ${route:-no route}"
    done <"$DNS_SERVERS_FILE"
}

check_connectivity() {
    timeout "$DNS_TIMEOUT" getent ahostsv4 "$TEST_HOST" >/dev/null 2>&1 || \
        fail "VPN DNS/connectivity check failed for $TEST_HOST"

    [[ -z "$TEST_URL" ]] && return 0

    curl \
        --fail \
        --silent \
        --show-error \
        --output /dev/null \
        --connect-timeout 5 \
        --max-time "$HTTP_TIMEOUT" \
        --interface tun0 \
        "$TEST_URL" || fail "HTTPS connectivity through tun0 failed for $TEST_URL"
}

main() {
    [[ -f "$READY_FILE" ]] || fail "VPN startup has not completed"
    check_ipv6_disabled
    check_openvpn_process
    check_tunnel_and_routes
    check_connectivity
}

main "$@"
