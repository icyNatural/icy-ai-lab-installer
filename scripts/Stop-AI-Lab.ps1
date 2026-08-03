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

Write-Log "Stopping Icy AI Lab environment at: '$LabRoot'"

$DockerDir = Join-Path $LabRoot "docker"
$ComposeFile = Join-Path $DockerDir "compose.yml"

if (-not (Test-Path -Path $ComposeFile)) {
    Write-Log "Docker Compose file not found at '$ComposeFile'." "ERROR"
    exit 1
}

Push-Location -Path $DockerDir
try {
    docker compose stop
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Icy AI Lab services stopped cleanly." "SUCCESS"
    } else {
        Write-Log "Failed to stop Docker Compose services cleanly." "WARN"
        exit 1
    }
}
finally {
    Pop-Location
}
