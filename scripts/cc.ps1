# cc.ps1 — shortcut to start Claude Code inside the running container.
#
# Usage:
#   ./cc.ps1         → opens Claude Code interactively in /workspace
#   ./cc.ps1 --help  → passes --help to claude

$Container = "claude-vpn"

# Check if the container is running
$RunningContainers = docker ps --format '{{.Names}}'
if ($RunningContainers -notcontains $Container) {
    Write-Host "Container '$Container' is not running." -ForegroundColor Red
    Write-Host "Start it with:  docker compose up -d"
    exit 1
}

# Run Claude Code interactively, passing all arguments ($args)
docker exec -it -u dev -w /workspace $Container claude $args