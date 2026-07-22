#!/usr/bin/env bash
# Runtime verification for the nested Codex and Claude Code sandboxes.
# Run as the unprivileged dev user through scripts/ai.sh/ai.ps1 sandbox-check.
set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

require_command() {
    local command="$1"
    command -v "$command" >/dev/null 2>&1 || fail "Required command is missing: $command"
    pass "$command is available at $(command -v "$command")"
}

if [ "$(id -u)" -eq 0 ]; then
    fail "Run this check as the unprivileged dev user, not root."
fi
pass "running as unprivileged user $(id -un) (uid $(id -u))"

for command in node codex claude bwrap socat; do
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

# Exercise Codex's own Linux sandbox helper rather than only checking for a
# helper binary. This command does not contact the API and needs no login.
codex sandbox linux -- /bin/sh -eu -c '
    test -r /etc/os-release
    printf "codex sandbox command executed\n"
'
pass "Codex Linux sandbox executed a command successfully"

printf '\n'
info "Both non-network sandbox smoke tests passed."
info "For Claude's interactive dependency panel, start Claude and run /sandbox."
