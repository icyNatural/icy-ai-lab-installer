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

Write-Log "Starting Icy AI Lab environment from: '$LabRoot'"

if (-not (Test-Path -Path $LabRoot)) {
    Write-Log "Lab directory '$LabRoot' does not exist." "ERROR"
    exit 1
}

$DockerDir = Join-Path $LabRoot "docker"
$ComposeFile = Join-Path $DockerDir "compose.yml"

if (-not (Test-Path -Path $ComposeFile)) {
    Write-Log "Docker Compose file not found at '$ComposeFile'." "ERROR"
    exit 1
}

# Start Docker Desktop if Docker daemon is not active
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Docker engine is not active. Attempting to start Docker Desktop..." "WARN"
    $DockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -Path $DockerDesktopPath) {
        Start-Process -FilePath $DockerDesktopPath -ErrorAction SilentlyContinue
    } else {
        Write-Log "Docker Desktop binary not found at standard path: '$DockerDesktopPath'" "WARN"
    }

    Write-Log "Waiting for Docker engine to become responsive (timeout 180s)..."
    $deadline = (Get-Date).AddSeconds(180)
    $ready = $false
    do {
        Start-Sleep -Seconds 5
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
    } until ((Get-Date) -gt $deadline)

    if (-not $ready) {
        Write-Log "Docker engine failed to start within 180 seconds." "ERROR"
        Write-Log "Diagnostic check: ensure Virtual Machine Platform and WSL 2 are active, and Docker Desktop is initialized." "ERROR"
        exit 1
    }
}

Write-Log "Docker engine is active. Launching services..." "SUCCESS"
Push-Location -Path $DockerDir
try {
    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up returned exit code $LASTEXITCODE"
    }
    Write-Log "Services started successfully!" "SUCCESS"
    Write-Log "Open WebUI: http://localhost:3000" "SUCCESS"
    Write-Log "n8n:        http://localhost:5678" "SUCCESS"

    Start-Process "http://localhost:3000"
    Start-Process "http://localhost:5678"
}
finally {
    Pop-Location
}
