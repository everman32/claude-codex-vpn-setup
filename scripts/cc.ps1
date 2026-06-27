# cc.ps1 - shortcut to start Claude Code inside the running container.
#
# Usage:
#   ./cc.ps1              opens Claude Code interactively in /workspace
#   ./cc.ps1 --help       passes --help to claude
#   ./cc.ps1 setup-token  generates a long-lived auth token (one-time)

$Container = "claude-vpn"

# Is the container running?
$RunningContainers = docker ps --format '{{.Names}}'
if ($RunningContainers -notcontains $Container) {
    Write-Host "Container '$Container' is not running." -ForegroundColor Red
    Write-Host "Start it with:  docker compose up -d"
    exit 1
}

# Is the VPN tunnel up? The image has a HEALTHCHECK that turns the container
# 'unhealthy' if tun0 disappears. Without the tunnel, Claude Code has no
# internet (the kill switch blocks everything else), so warn but do not block.
$Health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $Container 2>$null
if ($Health -eq "unhealthy") {
    Write-Host "Warning: container is 'unhealthy' - the VPN tunnel (tun0) looks down." -ForegroundColor Yellow
    Write-Host "Claude Code may fail to reach the API. Check: docker logs $Container" -ForegroundColor Yellow
} elseif ($Health -eq "starting") {
    Write-Host "Note: VPN is still connecting. If Claude cannot reach the API, wait a moment and retry." -ForegroundColor Yellow
}

# Run Claude Code interactively as the non-root 'dev' user, passing all args.
docker exec -it -u dev -w /workspace $Container claude $args
