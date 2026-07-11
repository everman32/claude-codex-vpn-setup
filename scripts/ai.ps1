# Universal launcher for Codex CLI or Claude Code.
#
# Select the active tool in .env:
#
#   AI_TOOL=codex
#   # AI_TOOL=claude
#
# Usage:
#   ./scripts/ai.ps1
#   ./scripts/ai.ps1 --help
#   ./scripts/ai.ps1 login
#   ./scripts/ai.ps1 status
#
# One-command override:
#   $env:AI_TOOL = "claude"; ./scripts/ai.ps1

$ErrorActionPreference = "Stop"

$Container = if ($env:AI_CONTAINER) { $env:AI_CONTAINER } else { "ai-vpn" }
$WorkDir = if ($env:AI_WORKDIR) { $env:AI_WORKDIR } else { "/workspace" }

function Get-RepoRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Get-DotEnvValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $EnvFile = Join-Path (Get-RepoRoot) ".env"

    if (-not (Test-Path $EnvFile)) {
        return $null
    }

    foreach ($Line in Get-Content $EnvFile) {
        $Trimmed = $Line.Trim()

        if (
            $Trimmed.Length -eq 0 -or
            $Trimmed.StartsWith("#") -or
            -not $Trimmed.Contains("=")
        ) {
            continue
        }

        $Parts = $Trimmed.Split("=", 2)

        if ($Parts[0].Trim() -ne $Name) {
            continue
        }

        $Value = $Parts[1].Trim()

        # Strip a trailing inline comment and matching simple quotes.
        $Value = ($Value -replace '\s+#.*$', '').Trim()
        $Value = $Value.Trim('"').Trim("'")

        return $Value
    }

    return $null
}

function Invoke-AiCli {
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]] $CommandArgs
    )

    & docker exec `
        -it `
        -u dev `
        -w $WorkDir `
        $Container `
        $Command `
        @CommandArgs

    exit $LASTEXITCODE
}

$Tool = if ($env:AI_TOOL) {
    $env:AI_TOOL
} else {
    Get-DotEnvValue -Name "AI_TOOL"
}

if (-not $Tool) {
    $Tool = "codex"
}

$RunningContainers = @(docker ps --format '{{.Names}}')

if ($RunningContainers -notcontains $Container) {
    Write-Host "Container '$Container' is not running." -ForegroundColor Red
    Write-Host "Start it with: docker compose up -d" -ForegroundColor Red
    exit 1
}

$Health = docker inspect `
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' `
    $Container 2>$null

switch ($Health) {
    "unhealthy" {
        Write-Host `
            "Warning: container is unhealthy; tun0 may be down." `
            -ForegroundColor Yellow
        Write-Host `
            "The selected CLI may fail to reach its API." `
            -ForegroundColor Yellow
        Write-Host `
            "Inspect it with: docker logs $Container" `
            -ForegroundColor Yellow
    }

    "starting" {
        Write-Host `
            "The VPN is still connecting. Inspect: docker logs $Container" `
            -ForegroundColor Yellow
    }
}

$FirstArg = if ($args.Count -gt 0) { $args[0] } else { $null }
$RemainingArgs = if ($args.Count -gt 1) {
    $args[1..($args.Count - 1)]
} else {
    @()
}

switch ($Tool.ToLowerInvariant()) {
    "codex" {
        switch ($FirstArg) {
            "login" {
                Invoke-AiCli codex @("login") @RemainingArgs
            }

            "status" {
                Invoke-AiCli codex @("login", "status") @RemainingArgs
            }

            "logout" {
                Invoke-AiCli codex @("logout") @RemainingArgs
            }

            default {
                Invoke-AiCli codex @args
            }
        }
    }

    "claude" {
        switch ($FirstArg) {
            "login" {
                Invoke-AiCli claude @("/login") @RemainingArgs
            }

            "setup-token" {
                Invoke-AiCli claude @("setup-token") @RemainingArgs
            }

            default {
                Invoke-AiCli claude @args
            }
        }
    }

    default {
        Write-Host `
            "Unsupported AI_TOOL='$Tool'. Use 'codex' or 'claude'." `
            -ForegroundColor Red
        exit 2
    }
}