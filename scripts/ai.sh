#!/usr/bin/env bash
# Universal launcher for Codex CLI or Claude Code.
#
# The active tool is selected through AI_TOOL in .env:
#
#   AI_TOOL=codex
#   # AI_TOOL=claude
#
# Usage:
#   ./scripts/ai.sh
#   ./scripts/ai.sh login
#   ./scripts/ai.sh status
#   ./scripts/ai.sh logout
#   ./scripts/ai.sh doctor
#   ./scripts/ai.sh sandbox-check
#
# Override the tool for one invocation:
#   AI_TOOL=claude ./scripts/ai.sh
#
# Non-interactive input and redirected output are supported. A TTY is allocated
# only when both the host stdin and stdout are terminals.

# Git Bash only: prevent MSYS from rewriting Linux container paths.
export MSYS_NO_PATHCONV=1

set -euo pipefail

CONTAINER="${AI_CONTAINER:-ai-vpn}"
WORKDIR="${AI_WORKDIR:-/workspace}"

error() {
    printf 'Error: %s\n' "$*" >&2
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

# Read AI_TOOL from the host .env when it was not exported by the caller.
# docker compose automatically reads .env, but this standalone host script does
# not, so we parse only the simple AI_TOOL=value setting.
load_tool_from_env() {
    if [[ -n "${AI_TOOL:-}" ]]; then
        return
    fi

    local script_dir repo_root env_file value
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd -- "$script_dir/.." && pwd)"
    env_file="$repo_root/.env"

    if [[ -f "$env_file" ]]; then
        value="$(
            sed -n \
                's/^[[:space:]]*AI_TOOL[[:space:]]*=[[:space:]]*//p' \
                "$env_file" |
            head -n 1 |
            tr -d '\r' |
            sed 's/[[:space:]]*#.*$//' |
            sed 's/^["'\'']//;s/["'\'']$//'
        )"

        if [[ -n "$value" ]]; then
            AI_TOOL="$value"
        fi
    fi

    AI_TOOL="${AI_TOOL:-codex}"
}

container_is_running() {
    docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"
}

check_health() {
    local health
    health="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$CONTAINER" 2>/dev/null || true
    )"

    case "$health" in
        unhealthy)
            warn "Container '$CONTAINER' is unhealthy; VPN checks are failing."
            warn "The selected CLI may not reach its API."
            warn "Inspect it with: docker logs $CONTAINER"
            ;;
        starting)
            warn "The VPN is still connecting."
            warn "If the CLI cannot connect, inspect: docker logs $CONTAINER"
            ;;
    esac
}

run_in_container() {
    local command="$1"
    shift

    local -a docker_args=(exec -i)
    if [[ -t 0 && -t 1 ]]; then
        docker_args+=(-t)
    fi

    exec docker "${docker_args[@]}" \
        -u dev \
        -w "$WORKDIR" \
        "$CONTAINER" \
        "$command" "$@"
}

load_tool_from_env

if ! container_is_running; then
    error "Container '$CONTAINER' is not running."
    error "Start it with: docker compose up -d"
    exit 1
fi

check_health

# This checks both installed agents and does not depend on AI_TOOL.
if [[ "${1:-}" == "sandbox-check" ]]; then
    shift
    run_in_container /usr/local/sbin/ai-sandbox-check "$@"
fi

case "${AI_TOOL,,}" in
    codex)
        case "${1:-}" in
            login)
                shift
                run_in_container codex login "$@"
                ;;
            status)
                shift
                run_in_container codex login status "$@"
                ;;
            logout)
                shift
                run_in_container codex logout "$@"
                ;;
            doctor)
                shift
                run_in_container codex doctor "$@"
                ;;
            *)
                run_in_container codex "$@"
                ;;
        esac
        ;;

    claude)
        case "${1:-}" in
            login)
                shift
                run_in_container claude auth login "$@"
                ;;
            status)
                shift
                run_in_container claude auth status "$@"
                ;;
            logout)
                shift
                run_in_container claude auth logout "$@"
                ;;
            setup-token)
                shift
                run_in_container claude setup-token "$@"
                ;;
            doctor)
                shift
                run_in_container claude doctor "$@"
                ;;
            *)
                run_in_container claude "$@"
                ;;
        esac
        ;;

    *)
        error "Unsupported AI_TOOL='$AI_TOOL'."
        error "Use AI_TOOL=codex or AI_TOOL=claude."
        exit 2
        ;;
esac
