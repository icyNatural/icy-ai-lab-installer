#requires -Version 5.1
<#
Icy AI Lab Bootstrapper for Windows
- Installs core tools with winget
- Creates an organized AI Lab directory
- Sets up Open WebUI + n8n with Docker Compose
- Optionally downloads laptop-sized Ollama models
- Safe to rerun: existing installs/containers are reused where possible
#>

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Section([string]$Text) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Name
    )

    Write-Host "`nChecking $Name..." -ForegroundColor Yellow
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($LASTEXITCODE -eq 0 -and $installed -match [regex]::Escape($Id)) {
        Write-Host "$Name is already installed." -ForegroundColor Green
        return
    }

    Write-Host "Installing $Name..." -ForegroundColor Yellow
    winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$Name did not install successfully. You can retry it later."
    }
}

function Wait-ForCommand {
    param([string]$Command, [int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (Test-Command $Command) { return $true }
        Start-Sleep -Seconds 2
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
    } until ((Get-Date) -gt $deadline)
    return $false
}

Write-Section "Icy AI Lab Setup"

if (-not (Test-Command "winget")) {
    throw "winget was not found. Install/update 'App Installer' from Microsoft Store, then rerun this script."
}

$defaultRoot = Join-Path $env:USERPROFILE "AI-Lab"
$rootInput = Read-Host "AI Lab folder location [$defaultRoot]"
$LabRoot = if ([string]::IsNullOrWhiteSpace($rootInput)) { $defaultRoot } else { $rootInput }

$Folders = @(
    $LabRoot,
    (Join-Path $LabRoot "models"),
    (Join-Path $LabRoot "projects"),
    (Join-Path $LabRoot "knowledge"),
    (Join-Path $LabRoot "outputs"),
    (Join-Path $LabRoot "workflows"),
    (Join-Path $LabRoot "docker"),
    (Join-Path $LabRoot "installers"),
    (Join-Path $LabRoot "backups")
)
$Folders | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

Write-Host "AI Lab created at: $LabRoot" -ForegroundColor Green

Write-Section "Installing Core Applications"

$packages = @(
    @{ Id = "Git.Git";                    Name = "Git" },
    @{ Id = "Microsoft.VisualStudioCode"; Name = "Visual Studio Code" },
    @{ Id = "Python.Python.3.12";         Name = "Python 3.12" },
    @{ Id = "OpenJS.NodeJS.LTS";          Name = "Node.js LTS" },
    @{ Id = "Docker.DockerDesktop";       Name = "Docker Desktop" },
    @{ Id = "Ollama.Ollama";              Name = "Ollama" }
)

foreach ($package in $packages) {
    Install-WingetPackage -Id $package.Id -Name $package.Name
}

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")

Write-Section "Creating Docker Services"

$DockerDir = Join-Path $LabRoot "docker"
$ComposePath = Join-Path $DockerDir "compose.yml"

$compose = @"
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    volumes:
      - n8n-data:/home/node/.n8n
      - ../workflows:/files
    environment:
      - GENERIC_TIMEZONE=America/New_York
      - TZ=America/New_York
      - N8N_SECURE_COOKIE=false

volumes:
  open-webui-data:
  n8n-data:
"@

Set-Content -Path $ComposePath -Value $compose -Encoding UTF8
Write-Host "Docker Compose file created: $ComposePath" -ForegroundColor Green

$startDocker = Read-Host "Start Open WebUI and n8n now? Docker Desktop must be running. [Y/n]"
if ($startDocker -notmatch '^[Nn]') {
    if (-not (Test-Command "docker")) {
        Write-Warning "Docker command is not available yet. Restart Windows, open Docker Desktop, then run:"
        Write-Host "  cd `"$DockerDir`"" -ForegroundColor White
        Write-Host "  docker compose up -d" -ForegroundColor White
    }
    else {
        try {
            docker info *> $null
            if ($LASTEXITCODE -ne 0) { throw "Docker engine is not running." }
            Push-Location $DockerDir
            docker compose up -d
            Pop-Location
            Write-Host "Open WebUI: http://localhost:3000" -ForegroundColor Green
            Write-Host "n8n:        http://localhost:5678" -ForegroundColor Green
        }
        catch {
            Write-Warning "Docker is installed but not ready. Open Docker Desktop, finish its setup, then run:"
            Write-Host "  cd `"$DockerDir`"" -ForegroundColor White
            Write-Host "  docker compose up -d" -ForegroundColor White
        }
    }
}

Write-Section "Optional Ollama Models"

Write-Host "Do NOT pull every huge model. These choices are laptop-sized:" -ForegroundColor Yellow
Write-Host "  1. Qwen 3.5 4B       - balanced, multimodal-capable family"
Write-Host "  2. Qwen 3.5 9B       - stronger, requires more RAM/VRAM"
Write-Host "  3. DeepSeek-R1 8B     - reasoning"
Write-Host "  4. Gemma 3 4B         - lightweight image + text"
Write-Host "  5. Qwen 3 4B Instruct - small general model"
Write-Host "  A. Recommended starter pack: Qwen 3.5 4B + DeepSeek-R1 8B + Gemma 3 4B"
Write-Host "  S. Skip model downloads"

$modelChoice = Read-Host "Choose [A]"
if ([string]::IsNullOrWhiteSpace($modelChoice)) { $modelChoice = "A" }

$modelMap = @{
    "1" = @("qwen3.5:4b")
    "2" = @("qwen3.5:9b")
    "3" = @("deepseek-r1:8b")
    "4" = @("gemma3:4b")
    "5" = @("qwen3:4b-instruct")
    "A" = @("qwen3.5:4b", "deepseek-r1:8b", "gemma3:4b")
}

if ($modelChoice.ToUpper() -ne "S") {
    if (-not (Wait-ForCommand "ollama" 30)) {
        Write-Warning "Ollama is installed but this terminal cannot see it yet. Restart Windows, then run the model commands listed in:"
    }
    else {
        $selected = $modelMap[$modelChoice.ToUpper()]
        if (-not $selected) {
            Write-Warning "Unknown selection; skipping model downloads."
        }
        else {
            foreach ($model in $selected) {
                Write-Host "`nDownloading $model..." -ForegroundColor Yellow
                ollama pull $model
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not download $model. Continue later with: ollama pull $model"
                }
            }
        }
    }
}

Write-Section "Writing Helper Files"

$StartPath = Join-Path $LabRoot "START-AI-LAB.ps1"
$StartScript = @"
`$ErrorActionPreference = "Continue"
Start-Process "Docker Desktop"
Start-Sleep -Seconds 12
Set-Location "$DockerDir"
docker compose up -d
Start-Process "http://localhost:3000"
Start-Process "http://localhost:5678"
"@
Set-Content -Path $StartPath -Value $StartScript -Encoding UTF8

$StopPath = Join-Path $LabRoot "STOP-AI-LAB.ps1"
$StopScript = @"
Set-Location "$DockerDir"
docker compose stop
"@
Set-Content -Path $StopPath -Value $StopScript -Encoding UTF8

$ReadmePath = Join-Path $LabRoot "README.txt"
$Readme = @"
ICY AI LAB

Open WebUI: http://localhost:3000
n8n:        http://localhost:5678
Ollama API: http://localhost:11434

START:
1. Open Docker Desktop.
2. Right-click START-AI-LAB.ps1 and choose Run with PowerShell.
3. Open WebUI and create your local account.

USE OLLAMA:
ollama list
ollama run qwen3.5:4b
ollama run deepseek-r1:8b
ollama run gemma3:4b

CANCEL A DOWNLOAD:
Press Ctrl+C in the terminal.

REMOVE A PARTIAL OR UNWANTED MODEL:
ollama list
ollama rm MODEL_NAME

START SERVICES MANUALLY:
cd "$DockerDir"
docker compose up -d

STOP SERVICES:
cd "$DockerDir"
docker compose stop

UPDATE SERVICES:
cd "$DockerDir"
docker compose pull
docker compose up -d

IMPORTANT:
- Docker Desktop may require a restart and WSL 2 setup.
- Huge models can consume tens or hundreds of GB.
- ComfyUI Desktop is intentionally not auto-installed here because its GPU setup
  should be selected after confirming your NVIDIA GPU and available VRAM.
"@
Set-Content -Path $ReadmePath -Value $Readme -Encoding UTF8

Write-Host "`nSetup stage complete." -ForegroundColor Green
Write-Host "Folder: $LabRoot" -ForegroundColor Green
Write-Host "Read:   $ReadmePath" -ForegroundColor Green
Write-Host "`nA Windows restart may be required before Docker and Ollama work normally." -ForegroundColor Yellow
Read-Host "Press Enter to close"
