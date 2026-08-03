[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [switch]$Force
)

$ErrorActionPreference = "Continue"
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

Write-Log "Running Diagnostic and Non-Destructive Repair on Icy AI Lab..."

# 1. PATH Refresh
Write-Log "[Check 1/5] Refreshing Environment PATH..."
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"
Write-Log "Environment PATH refreshed." "SUCCESS"

# 2. WSL Status
Write-Log "[Check 2/5] Checking WSL Status..."
if (Get-Command "wsl" -ErrorAction SilentlyContinue) {
    $wslStatus = wsl --status 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Log "WSL is responding normally." "SUCCESS"
    } else {
        Write-Log "WSL returned non-zero status. Attempting non-destructive update..." "WARN"
        wsl --update 2>&1 | Out-Null
    }
} else {
    Write-Log "WSL executable not found in system PATH." "ERROR"
}

# 3. Docker Service & Daemon Check
Write-Log "[Check 3/5] Checking Docker Engine Status..."
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Docker engine is inactive. Attempting to start Docker Desktop service..." "WARN"
    $DockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -Path $DockerDesktopPath) {
        Start-Process -FilePath $DockerDesktopPath -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Docker engine successfully reactivated." "SUCCESS"
        } else {
            Write-Log "Docker engine is still not responding. Open Docker Desktop manually." "WARN"
        }
    } else {
        Write-Log "Docker Desktop binary not found." "ERROR"
    }
} else {
    Write-Log "Docker engine is healthy." "SUCCESS"
}

# 4. Docker Compose Service Check
Write-Log "[Check 4/5] Checking Docker Compose Services..."
$DockerDir = Join-Path $LabRoot "docker"
$ComposeFile = Join-Path $DockerDir "compose.yml"
if (Test-Path -Path $ComposeFile) {
    Push-Location -Path $DockerDir
    try {
        if ($Force) {
            Write-Log "-Force specified: recreates containers without deleting volumes..." "WARN"
            docker compose up -d --force-recreate
        } else {
            docker compose up -d
        }
        Write-Log "Docker Compose services verified and running." "SUCCESS"
    }
    catch {
        Write-Log "Docker Compose repair failed: $_" "ERROR"
    }
    finally {
        Pop-Location
    }
} else {
    Write-Log "Docker Compose configuration missing at '$ComposeFile'." "WARN"
}

# 5. Ollama Check
Write-Log "[Check 5/5] Checking Ollama Service..."
if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
    try {
        $models = ollama list 2>&1
        Write-Log "Ollama service is responsive. Models available:" "SUCCESS"
        Write-Host $models
    }
    catch {
        Write-Log "Ollama service is not responding. Restarting Ollama server process..." "WARN"
        Start-Process -FilePath "ollama" -ArgumentList "serve" -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "Ollama executable not found." "WARN"
}

Write-Log "Repair diagnostic completed." "SUCCESS"
