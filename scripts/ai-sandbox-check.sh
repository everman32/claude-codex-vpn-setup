#!/usr/bin/env bash
# Runtime verification for the nested Codex and Claude Code sandboxes.
# Run as the unprivileged dev user through scripts/ai.sh/ai.ps1 sandbox-check.
set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

require_command() {
    local command="$1"
    command -v "$command" >/dev/null 2>&1 || fail "Required command is missing: $command"
    pass "$command is available at $(command -v "$command")"
}

read_sysctl_if_present() {
    local path="$1"
    if [ -r "$path" ]; then
        printf '%s' "$(cat "$path")"
    else
        printf '%s' "n/a"
    fi
}

show_userns_diagnostics() {
    local seccomp_mode userns_clone max_userns

    seccomp_mode="$(awk '/^Seccomp:/ {print $2}' /proc/self/status 2>/dev/null || true)"
    userns_clone="$(read_sysctl_if_present /proc/sys/kernel/unprivileged_userns_clone)"
    max_userns="$(read_sysctl_if_present /proc/sys/user/max_user_namespaces)"

    warn "Nested user-namespace diagnostics:"
    warn "  /proc/self/status Seccomp: ${seccomp_mode:-unknown} (0 means no outer seccomp filter)"
    warn "  kernel.unprivileged_userns_clone: $userns_clone"
    warn "  user.max_user_namespaces: $max_userns"
    warn "Docker's default seccomp profile blocks clone/unshare namespace operations."
    warn "Recreate the container with the supplied security_opt settings:"
    warn "  docker compose down"
    warn "  docker compose up -d --force-recreate"
}

if [ "$(id -u)" -eq 0 ]; then
    fail "Run this check as the unprivileged dev user, not root."
fi
pass "running as unprivileged user $(id -un) (uid $(id -u))"

for command in node codex claude bwrap socat unshare; do
    require_command "$command"
done

node_version="$(node --version)"
case "$node_version" in
    v24.*) pass "Node.js 24 detected: $node_version" ;;
    *) fail "Expected Node.js 24, found: $node_version" ;;
esac

pass "Codex CLI detected: $(codex --version)"
pass "Claude Code detected: $(claude --version)"
pass "bubblewrap detected: $(bwrap --version | head -n 1)"
pass "socat detected: $(socat -V 2>&1 | head -n 1)"

# Verify the outer container allows an unprivileged process to create a user
# namespace. This is the first primitive bubblewrap needs. Testing it directly
# produces a much clearer diagnosis than bubblewrap's generic permission error.
userns_error_file="$(mktemp)"
trap 'rm -f "$userns_error_file"' EXIT
if unshare --user --map-root-user /bin/sh -eu -c 'test "$(id -u)" -eq 0' \
    2>"$userns_error_file"
then
    pass "unprivileged user namespace creation is permitted"
else
    cat "$userns_error_file" >&2 || true
    show_userns_diagnostics
    fail "The outer container still blocks the user namespace required by bubblewrap."
fi

# Claude Code uses bubblewrap for filesystem isolation and socat for its
# sandbox network relay. In an unprivileged Docker container it uses the
# documented enableWeakerNestedSandbox mode, which bind-mounts the existing
# /proc rather than trying to create a fresh procfs mount.
bwrap \
    --die-with-parent \
    --unshare-user \
    --uid 0 \
    --gid 0 \
    --unshare-uts \
    --unshare-ipc \
    --unshare-cgroup-try \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --ro-bind /proc /proc \
    --tmpfs /tmp \
    -- /bin/sh -eu -c '
        test "$(id -u)" -eq 0
        test -r /etc/os-release
        test -r /proc/self/status
        if touch /etc/claude-sandbox-must-be-read-only 2>/dev/null; then
            rm -f /etc/claude-sandbox-must-be-read-only
            exit 1
        fi
        touch /tmp/claude-sandbox-smoke-test
    '
pass "Claude nested sandbox prerequisites and bubblewrap smoke test passed"

# Exercise Codex's own host sandbox rather than only checking for a helper
# binary. Recent Codex releases auto-select the platform backend, while older
# releases exposed an explicit `linux` subcommand. Detect the CLI shape from
# help output so deliberate version overrides remain testable.
codex_sandbox_help="$(codex sandbox --help 2>&1)" || {
    printf '%s\n' "$codex_sandbox_help" >&2
    fail "Could not inspect the Codex sandbox command."
}

if grep -Eq '^[[:space:]]*linux([[:space:]]|$)' <<<"$codex_sandbox_help"; then
    codex_sandbox_command=(codex sandbox linux --)
    info "Codex sandbox syntax: explicit Linux backend"
else
    codex_sandbox_command=(codex sandbox --)
    info "Codex sandbox syntax: automatic host backend"
fi

codex_sandbox_error_file="$(mktemp)"
trap 'rm -f "$userns_error_file" "$codex_sandbox_error_file"' EXIT
if "${codex_sandbox_command[@]}" /bin/sh -eu -c '
    test -r /etc/os-release
    printf "codex sandbox command executed\n"
' 2>"$codex_sandbox_error_file"
then
    pass "Codex Linux sandbox executed a command successfully"
else
    cat "$codex_sandbox_error_file" >&2 || true
    fail "Codex could not execute a command through its Linux sandbox."
fi

printf '\n'
info "Both non-network sandbox smoke tests passed."
info "For Claude's interactive dependency panel, start Claude and run /sandbox."
