#!/bin/bash
export MSYS_NO_PATHCONV=1   # stop Git Bash from rewriting /workspace
# cc.sh — shortcut to start Claude Code inside the running container.
#
# Usage:
#   ./cc.sh            → opens Claude Code interactively in /workspace
#   ./cc.sh --help     → passes --help to claude
#
# Place this in your repo root or ~/bin/cc and chmod +x it.

CONTAINER="claude-vpn"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container '${CONTAINER}' is not running."
    echo "Start it with:  docker compose up -d"
    exit 1
fi

exec docker exec -it -u dev -w /workspace "$CONTAINER" claude "$@"
