[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Log([string]$Message, [string]$Level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $formatted -ForegroundColor Red }
        "WARN"    { Write-Host $formatted -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formatted -ForegroundColor Green }
        default   { Write-Host $formatted -ForegroundColor Cyan }
    }
}

Write-Log "Updating Icy AI Lab environment at: '$LabRoot'"

if (Get-Command "winget" -ErrorAction SilentlyContinue) {
    Write-Log "Checking and upgrading Winget packages..."
    $packages = @("Git.Git", "Microsoft.VisualStudioCode", "Python.Python.3.12", "OpenJS.NodeJS.LTS", "Docker.DockerDesktop", "Ollama.Ollama")
    foreach ($pkg in $packages) {
        Write-Log "Upgrading $pkg..."
        winget upgrade --id $pkg --exact --silent --accept-package-agreements --accept-source-agreements 2>$null
    }
}

$DockerDir = Join-Path $LabRoot "docker"
$ComposeFile = Join-Path $DockerDir "compose.yml"

if (Test-Path -Path $ComposeFile) {
    Write-Log "Pulling latest Docker images and restarting containers..."
    Push-Location -Path $DockerDir
    try {
        docker compose pull
        docker compose up -d
        Write-Log "Docker services updated successfully." "SUCCESS"
    }
    catch {
        Write-Log "Docker update failed: $_" "WARN"
    }
    finally {
        Pop-Location
    }
}

if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
    Write-Log "Refreshing existing local Ollama models..."
    try {
        $models = ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ }
        foreach ($m in $models) {
            Write-Log "Updating model $m..."
            ollama pull $m
        }
    }
    catch {
        Write-Log "Could not auto-update Ollama models: $_" "WARN"
    }
}

Write-Log "Update process completed." "SUCCESS"
