#!/usr/bin/env bash
# Configure container DNS from OpenVPN-pushed dhcp-option DNS values.
#
# OpenVPN invokes this script for the "up" event. VPN_DNS may override pushed
# values with a comma- or whitespace-separated list of IPv4 resolvers.
set -euo pipefail

RESOLV_CONF="${VPN_RESOLV_CONF:-/etc/resolv.conf}"
STATE_DIR="${VPN_DNS_STATE_DIR:-/run/vpn-dns}"
READY_FILE="$STATE_DIR/ready"
SERVERS_FILE="$STATE_DIR/servers"

log() {
    printf '[VPN DNS] %s\n' "$*"
}

fail() {
    printf '[VPN DNS] Error: %s\n' "$*" >&2
    exit 1
}

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

collect_dns_servers() {
    if [[ -n "${VPN_DNS:-}" ]]; then
        printf '%s\n' "$VPN_DNS" |
            tr ',;' '\n\n' |
            awk '{ for (i = 1; i <= NF; i++) print $i }'
        return
    fi

    env |
        sed -n 's/^foreign_option_[0-9][0-9]*=dhcp-option DNS //p'
}

main() {
    local server tmp
    local -a servers=()
    declare -A seen=()

    mkdir -p "$STATE_DIR"
    rm -f "$READY_FILE" "$SERVERS_FILE"

    while IFS= read -r server; do
        server="${server//$'\r'/}"
        [[ -n "$server" ]] || continue

        is_ipv4 "$server" || fail "Invalid or unsupported DNS server '$server'; only IPv4 is supported while IPv6 is blocked."

        if [[ -z "${seen[$server]:-}" ]]; then
            seen[$server]=1
            servers+=("$server")
        fi
    done < <(collect_dns_servers)

    ((${#servers[@]} > 0)) || fail \
        "The VPN did not push an IPv4 DNS server. Set VPN_DNS to one or more resolvers reachable through the tunnel."

    tmp="$(mktemp "$STATE_DIR/resolv.conf.XXXXXX")"
    {
        printf '# Managed by /usr/local/sbin/vpn-dns-up\n'
        for server in "${servers[@]}"; do
            printf 'nameserver %s\n' "$server"
        done
        printf 'options timeout:2 attempts:3\n'
    } >"$tmp"

    # /etc/resolv.conf is a Docker-managed mount, so replace its contents
    # rather than renaming a file over the mount point.
    cat "$tmp" >"$RESOLV_CONF"
    rm -f "$tmp"

    printf '%s\n' "${servers[@]}" >"$SERVERS_FILE"
    touch "$READY_FILE"
    log "Using VPN DNS: ${servers[*]}"
}

main "$@"
