# Universal launcher for Codex CLI or Claude Code.
#
# Select the active tool in .env:
#
#   AI_TOOL=codex
#   # AI_TOOL=claude
#
# Usage:
#   ./scripts/ai.ps1
#   ./scripts/ai.ps1 login
#   ./scripts/ai.ps1 status
#   ./scripts/ai.ps1 logout
#   ./scripts/ai.ps1 doctor
#   ./scripts/ai.ps1 sandbox-check
#
# One-command override:
#   $env:AI_TOOL = "claude"; ./scripts/ai.ps1
#
# A Docker TTY is allocated only when host stdin and stdout are not redirected.

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

        [string[]] $CommandArgs = @()
    )

    $DockerArgs = @("exec", "-i")

    if (
        -not [Console]::IsInputRedirected -and
        -not [Console]::IsOutputRedirected
    ) {
        $DockerArgs += "-t"
    }

    $DockerArgs += @(
        "-u", "dev",
        "-w", $WorkDir,
        $Container,
        $Command
    )
    $DockerArgs += $CommandArgs

    & docker @DockerArgs
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
            "Warning: container is unhealthy; VPN checks are failing." `
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
    @($args[1..($args.Count - 1)])
} else {
    @()
}

if ($FirstArg -eq "sandbox-check") {
    Invoke-AiCli `
        -Command "/usr/local/sbin/ai-sandbox-check" `
        -CommandArgs $RemainingArgs
}

switch ($Tool.ToLowerInvariant()) {
    "codex" {
        switch ($FirstArg) {
            "login" {
                Invoke-AiCli -Command "codex" -CommandArgs (@("login") + $RemainingArgs)
            }

            "status" {
                Invoke-AiCli -Command "codex" -CommandArgs (@("login", "status") + $RemainingArgs)
            }

            "logout" {
                Invoke-AiCli -Command "codex" -CommandArgs (@("logout") + $RemainingArgs)
            }

            "doctor" {
                Invoke-AiCli -Command "codex" -CommandArgs (@("doctor") + $RemainingArgs)
            }

            default {
                Invoke-AiCli -Command "codex" -CommandArgs @($args)
            }
        }
    }

    "claude" {
        switch ($FirstArg) {
            "login" {
                Invoke-AiCli -Command "claude" -CommandArgs (@("auth", "login") + $RemainingArgs)
            }

            "status" {
                Invoke-AiCli -Command "claude" -CommandArgs (@("auth", "status") + $RemainingArgs)
            }

            "logout" {
                Invoke-AiCli -Command "claude" -CommandArgs (@("auth", "logout") + $RemainingArgs)
            }

            "setup-token" {
                Invoke-AiCli -Command "claude" -CommandArgs (@("setup-token") + $RemainingArgs)
            }

            "doctor" {
                Invoke-AiCli -Command "claude" -CommandArgs (@("doctor") + $RemainingArgs)
            }

            default {
                Invoke-AiCli -Command "claude" -CommandArgs @($args)
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
