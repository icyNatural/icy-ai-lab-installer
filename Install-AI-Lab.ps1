#requires -Version 5.1
<#
.SYNOPSIS
    Icy AI Lab Production-Quality Portable Windows Bootstrapper
.DESCRIPTION
    Automates local AI workstation setup: WSL 2, Docker Desktop, Ollama, Git, VS Code, Python, Node.js,
    Open WebUI, n8n, model pack management, backup/restore/repair utilities, and desktop shortcuts.
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [switch]$SkipReboot,
    [switch]$SkipModels,
    [switch]$NonInteractive,
    [switch]$ResumedFromReboot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Global Constants & Exit Codes
$script:EXIT_SUCCESS          = 0
$script:EXIT_REBOOT_REQUIRED = 10
$script:EXIT_PARTIAL_SUCCESS  = 20
$script:EXIT_FAILURE          = 1

$global:HasWarnings = $false

# Single-Instance Mutex Enforcement
$script:InstallerMutex = $null
$createdNew = $false
try {
    $script:InstallerMutex = New-Object System.Threading.Mutex($true, "Global\IcyAILabInstallerMutex", [ref]$createdNew)
} catch {
    $createdNew = $true
}

if (-not $createdNew) {
    Write-Host "ERROR: Another instance of Icy AI Lab Installer is already running." -ForegroundColor Red
    exit $script:EXIT_FAILURE
}

# Resolve Full Absolute Script Path
$resolvedScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($resolvedScriptPath) -or -not (Test-Path -Path $resolvedScriptPath)) {
    $resolvedScriptPath = $PSCommandPath
}
if ($resolvedScriptPath -and (Test-Path -Path $resolvedScriptPath)) {
    $resolvedScriptPath = (Get-Item -Path $resolvedScriptPath).FullName
}

# Helper: Check UAC Elevation
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self-Elevate if not Administrator
if (-not (Test-IsAdmin)) {
    Write-Host "Elevating privileges to Administrator..." -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($resolvedScriptPath) -or -not (Test-Path -Path $resolvedScriptPath)) {
        Write-Host "ERROR: Could not resolve full absolute script path for elevation." -ForegroundColor Red
        exit $script:EXIT_FAILURE
    }

    # Build escaped argument string preserving paths with spaces or parentheses
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$resolvedScriptPath`" -InstallRoot `"$InstallRoot`""
    if ($SkipReboot)        { $argList += " -SkipReboot" }
    if ($SkipModels)        { $argList += " -SkipModels" }
    if ($NonInteractive)     { $argList += " -NonInteractive" }
    if ($ResumedFromReboot)  { $argList += " -ResumedFromReboot" }
    if ($Force)              { $argList += " -Force" }

    # Release mutex so elevated child process can acquire it
    if ($script:InstallerMutex) {
        try { $script:InstallerMutex.ReleaseMutex(); $script:InstallerMutex.Dispose() } catch { }
    }

    try {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -PassThru
        if ($process) {
            Write-Host "Elevated process successfully launched (PID: $($process.Id)). Exiting parent process." -ForegroundColor Green
            exit $script:EXIT_SUCCESS
        } else {
            throw "Start-Process returned null process object."
        }
    }
    catch {
        Write-Host "ERROR: Administrator elevation was denied or failed: $_" -ForegroundColor Red
        exit $script:EXIT_FAILURE
    }
}

# In Elevated Process: Display confirmation message
Write-Host "Administrator privileges acquired. Continuing installation." -ForegroundColor Green

# Ensure Folders and Logging Initialization
if (-not (Test-Path -Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
}
$LogDir = Join-Path $InstallRoot "logs"
if (-not (Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDir "install_$timestamp.log"

function Redact-Secrets([string]$InputText) {
    if ([string]::IsNullOrEmpty($InputText)) { return "" }
    $redacted = $InputText -replace '(?i)(password|secret|token|key)\s*[:=]\s*["''][^"'']+["'']', '$1=***REDACTED***'
    return $redacted
}

function Write-Log([string]$Message, [string]$Level = "INFO") {
    $cleanMessage = Redact-Secrets -InputText $Message
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$time] [$Level] $cleanMessage"
    Add-Content -Path $LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue

    switch ($Level) {
        "ERROR"   { Write-Host " $cleanMessage" -ForegroundColor Red }
        "WARN"    { Write-Host " $cleanMessage" -ForegroundColor Yellow; $global:HasWarnings = $true }
        "SUCCESS" { Write-Host " $cleanMessage" -ForegroundColor Green }
        "SECTION" {
            Write-Host "`n============================================================" -ForegroundColor Cyan
            Write-Host " $cleanMessage" -ForegroundColor Cyan
            Write-Host "============================================================" -ForegroundColor Cyan
        }
        default   { Write-Host " $cleanMessage" -ForegroundColor White }
    }
}

Write-Log "Icy AI Lab Windows Bootstrapper Started" "SECTION"
Write-Log "Target Install Root: '$InstallRoot'"
Write-Log "Log File Location:   '$LogFile'"
Write-Log "Resolved Script:     '$resolvedScriptPath'"

# System & Hardware Diagnostics
Write-Log "Performing Hardware and Environment Diagnostics..." "SECTION"

$SysInfo = @{}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $SysInfo.OSCaption     = $os.Caption
    $SysInfo.OSVersion     = $os.Version
    $SysInfo.BuildNumber   = [int]$os.BuildNumber
    $SysInfo.TotalRAM_GB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $SysInfo.Architecture  = $env:PROCESSOR_ARCHITECTURE

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $SysInfo.CPUName       = $cpu.Name.Trim()
    $SysInfo.CPUCores      = $cpu.NumberOfCores
    $SysInfo.CPULogical    = $cpu.NumberOfLogicalProcessors

    $gpus = Get-CimInstance Win32_VideoController
    $gpuDetails = @()
    foreach ($gpu in $gpus) {
        $vramGB = [math]::Round($gpu.AdapterRAM / 1GB, 2)
        $gpuDetails += "$($gpu.Name) (Reported VRAM: ${vramGB}GB - Note: Windows WMI VRAM caps at 4GB)"
    }
    $SysInfo.GPUs = $gpuDetails

    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($InstallRoot.Substring(0,2))'"
    $SysInfo.FreeDisk_GB   = [math]::Round($drive.FreeSpace / 1GB, 2)

    Write-Log "OS Edition:       $($SysInfo.OSCaption) (Build $($SysInfo.BuildNumber))" "SUCCESS"
    Write-Log "Architecture:     $($SysInfo.Architecture)" "SUCCESS"
    Write-Log "CPU:              $($SysInfo.CPUName) ($($SysInfo.CPUCores) Cores / $($SysInfo.CPULogical) Threads)" "SUCCESS"
    Write-Log "Installed RAM:    $($SysInfo.TotalRAM_GB) GB" "SUCCESS"
    Write-Log "GPU Adapters:     $($SysInfo.GPUs -join '; ')" "SUCCESS"
    Write-Log "Free Disk Space:  $($SysInfo.FreeDisk_GB) GB on drive $($drive.DeviceID)" "SUCCESS"
}
catch {
    Write-Log "Hardware detection encounter non-fatal error: $_" "WARN"
}

# Validate OS Version
if ($SysInfo.BuildNumber -lt 19041) {
    Write-Log "Windows 10 Build 19041 or Windows 11 is required for WSL 2 feature support. Current build: $($SysInfo.BuildNumber)." "ERROR"
    exit $script:EXIT_FAILURE
}

if ($SysInfo.FreeDisk_GB -lt 15) {
    Write-Log "Less than 15 GB free disk space available ($($SysInfo.FreeDisk_GB) GB). Installation may fail during container/model setup." "WARN"
}

# State & Reboot-Resume Engine
$StateFile = Join-Path $env:TEMP "ai_lab_install_state.json"
$RunOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$RunOnceValue = "IcyAILabResume"

function Read-InstallState {
    if (Test-Path -Path $StateFile) {
        try {
            return Get-Content -Path $StateFile -Raw | ConvertFrom-Json
        } catch { return $null }
    }
    return $null
}

function Save-InstallState([hashtable]$StateData) {
    $json = $StateData | ConvertTo-Json -Depth 5
    Set-Content -Path $StateFile -Value $json -Encoding UTF8 -Force
}

function Cleanup-ResumeState {
    if (Test-Path -Path $StateFile) {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceValue -ErrorAction SilentlyContinue
}

$state = Read-InstallState
$resumeCount = 0
if ($state -and $state.resumeCount) {
    $resumeCount = [int]$state.resumeCount
}

# Handle Post-Reboot Resume Initialization
if ($ResumedFromReboot -or $state) {
    # Remove RunOnce registry entry immediately to prevent infinite reboot loops
    Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceValue -ErrorAction SilentlyContinue
    Write-Log "RunOnce key removed to prevent duplicate auto-resume loops."

    if ($resumeCount -ge 2) {
        Write-Log "Maximum auto-resume limit reached ($resumeCount). Clearing state." "WARN"
        Cleanup-ResumeState
        $manualCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$resolvedScriptPath`" -InstallRoot `"$InstallRoot`""
        Write-Log "To resume manually, execute: $manualCmd" "WARN"
        exit $script:EXIT_FAILURE
    }

    # Validate source script exists at resume time
    $savedScriptPath = if ($state -and $state.ScriptPath) { $state.ScriptPath } else { $resolvedScriptPath }
    if (-not (Test-Path -Path $savedScriptPath)) {
        Write-Log "ERROR: Source installer script no longer exists at '$savedScriptPath'." "ERROR"
        $manualCmd = "powershell.exe -ExecutionPolicy Bypass -File `"<path_to_Install-AI-Lab.ps1>`" -InstallRoot `"$InstallRoot`""
        Write-Log "Please locate Install-AI-Lab.ps1 and run manually: $manualCmd" "ERROR"
        Cleanup-ResumeState
        exit $script:EXIT_FAILURE
    }

    Write-Host "Resuming Icy AI Lab installation after reboot." -ForegroundColor Green
    Write-Log "Resuming Icy AI Lab installation after reboot (Resume Count: $resumeCount)." "SUCCESS"
}

# WSL 2 Diagnostics & Enablement
Write-Log "Checking WSL 2 and Virtual Machine Platform..." "SECTION"

$rebootNeeded = $false

try {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"
    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"

    if ($wslFeature.State -ne "Enabled") {
        Write-Log "Enabling Microsoft-Windows-Subsystem-Linux..."
        Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart | Out-Null
        $rebootNeeded = $true
    }

    if ($vmpFeature.State -ne "Enabled") {
        Write-Log "Enabling VirtualMachinePlatform..."
        Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart | Out-Null
        $rebootNeeded = $true
    }
}
catch {
    Write-Log "DISM / WindowsOptionalFeature check failed: $_. Falling back to dism.exe..." "WARN"
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
}

# Check Registry Reboot Pending Flags
$pendingRename = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
$cbsReboot = Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"

if ($rebootNeeded -or $cbsReboot -or $pendingRename) {
    Write-Log "A Windows restart is required to finalize WSL 2 feature installation." "WARN"

    if (-not (Test-Path -Path $resolvedScriptPath)) {
        Write-Log "ERROR: Cannot register auto-resume because installer script is missing at '$resolvedScriptPath'." "ERROR"
        exit $script:EXIT_FAILURE
    }

    # Save resume state before prompting
    $newResumeCount = $resumeCount + 1
    Save-InstallState -StateData @{
        resumeCount = $newResumeCount
        InstallRoot = $InstallRoot
        ScriptPath  = $resolvedScriptPath
        Phase       = "WSL_ENABLED"
        Timestamp   = (Get-Date).ToString("o")
    }

    # Register RunOnce using full absolute script path with safe quotes
    $resumeCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$resolvedScriptPath`" -ResumedFromReboot -InstallRoot `"$InstallRoot`""
    if ($SkipModels)     { $resumeCmd += " -SkipModels" }
    if ($NonInteractive) { $resumeCmd += " -NonInteractive" }
    if ($Force)          { $resumeCmd += " -Force" }

    Set-ItemProperty -Path $RunOnceKey -Name $RunOnceValue -Value $resumeCmd -Force
    Write-Log "Registered auto-resume RunOnce key: $RunOnceValue" "SUCCESS"

    if (-not $NonInteractive) {
        $resp = Read-Host "Would you like to restart your computer now? [Y/n]"
        if ($resp -notmatch '^[Nn]') {
            Write-Log "Initiating immediate system restart..." "SUCCESS"
            Restart-Computer -Force
            exit $script:EXIT_REBOOT_REQUIRED
        } else {
            Write-Host "Restart Windows, then sign back in. Installation will resume automatically." -ForegroundColor Yellow
            Write-Log "Restart Windows, then sign back in. Installation will resume automatically." "WARN"
            # STOP ALL DEPENDENT INSTALLATION WORK IMMEDIATELY
            exit $script:EXIT_REBOOT_REQUIRED
        }
    } else {
        if (-not $SkipReboot) {
            Write-Log "Non-interactive mode: initiating system restart..." "SUCCESS"
            Restart-Computer -Force
            exit $script:EXIT_REBOOT_REQUIRED
        } else {
            Write-Host "Restart Windows, then sign back in. Installation will resume automatically." -ForegroundColor Yellow
            Write-Log "Restart Windows, then sign back in. Installation will resume automatically." "WARN"
            # STOP ALL DEPENDENT INSTALLATION WORK IMMEDIATELY
            exit $script:EXIT_REBOOT_REQUIRED
        }
    }
} else {
    Cleanup-ResumeState
}

# Configure WSL Default Version
if (Get-Command "wsl" -ErrorAction SilentlyContinue) {
    Write-Log "Configuring default WSL 2 version..."
    wsl --set-default-version 2 2>&1 | Out-Null
    wsl --update 2>&1 | Out-Null
}

# Subfolder Structure
Write-Log "Creating Directory Structure at '$InstallRoot'..." "SECTION"
$folders = @("models", "projects", "knowledge", "outputs", "workflows", "docker", "installers", "backups", "logs", "scripts")
foreach ($f in $folders) {
    $dirPath = Join-Path $InstallRoot $f
    if (-not (Test-Path -Path $dirPath)) {
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }
}
Write-Log "Directory hierarchy initialized." "SUCCESS"

# Core Tool Deployments via Winget
Write-Log "Installing Core Applications via Winget..." "SECTION"

if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    Write-Log "winget was not found. Please install App Installer from the Microsoft Store." "ERROR"
    exit $script:EXIT_FAILURE
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name
    )

    Write-Log "Checking installation status of $Name ($Id)..."
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($LASTEXITCODE -eq 0 -and $installed -match [regex]::Escape($Id)) {
        Write-Log "$Name is already installed." "SUCCESS"
        return $true
    }

    Write-Log "Installing $Name via winget..."
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Successfully installed $Name." "SUCCESS"
        return $true
    } else {
        Write-Log "Winget install for $Name returned exit code $LASTEXITCODE. Retrying or relying on existing binary." "WARN"
        return $false
    }
}

$packages = @(
    @{ Id = "Git.Git";                    Name = "Git" },
    @{ Id = "Microsoft.VisualStudioCode"; Name = "Visual Studio Code" },
    @{ Id = "Python.Python.3.12";         Name = "Python 3.12" },
    @{ Id = "OpenJS.NodeJS.LTS";          Name = "Node.js LTS" },
    @{ Id = "Docker.DockerDesktop";       Name = "Docker Desktop" },
    @{ Id = "Ollama.Ollama";              Name = "Ollama" }
)

foreach ($pkg in $packages) {
    Install-WingetPackage -Id $pkg.Id -Name $pkg.Name | Out-Null
}

# Refresh Environment PATH
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"

# Deploy Helper Scripts & Compose File
Write-Log "Deploying Management Scripts & Docker Compose..." "SECTION"
$SourceScripts = Join-Path $PSScriptRoot "scripts"
if (Test-Path -Path $SourceScripts) {
    Copy-Item -Path "$SourceScripts\*" -Destination (Join-Path $InstallRoot "scripts") -Force -Recurse
    Write-Log "Helper scripts deployed to '$InstallRoot\scripts'." "SUCCESS"
}

$DockerDir = Join-Path $InstallRoot "docker"
$ComposePath = Join-Path $DockerDir "compose.yml"

$composeContent = @"
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:8080"
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
    extra_hosts:
      - "host.docker.internal:host-gateway"

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
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

Set-Content -Path $ComposePath -Value $composeContent -Encoding UTF8 -Force
Write-Log "Docker Compose configured at '$ComposePath' (bound to 127.0.0.1)." "SUCCESS"

# Docker Engine Readiness & Startup
Write-Log "Starting Docker Desktop and Container Services..." "SECTION"

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Docker engine is inactive. Launching Docker Desktop..." "WARN"
    $DockerDesktopBin = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -Path $DockerDesktopBin) {
        Start-Process -FilePath $DockerDesktopBin -ErrorAction SilentlyContinue
    }

    Write-Log "Waiting for Docker daemon readiness (timeout 180s)..."
    $deadline = (Get-Date).AddSeconds(180)
    $dockerReady = $false
    do {
        Start-Sleep -Seconds 5
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            $dockerReady = $true
            break
        }
    } until ((Get-Date) -gt $deadline)

    if (-not $dockerReady) {
        Write-Log "Docker engine failed to respond within 180s timeout." "WARN"
        Write-Log "Diagnostics: Ensure Hyper-V/VirtualMachinePlatform is enabled, WSL 2 is functional, and Docker Desktop licensing setup is completed." "WARN"
    }
}

if (Get-Command "docker" -ErrorAction SilentlyContinue) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        Push-Location -Path $DockerDir
        try {
            docker compose up -d
            Write-Log "Open WebUI running at: http://localhost:3000" "SUCCESS"
            Write-Log "n8n running at:        http://localhost:5678" "SUCCESS"
        }
        catch {
            Write-Log "Docker compose up encountered error: $_" "WARN"
        }
        finally {
            Pop-Location
        }
    }
}

# Model Pack Selection & Download
if (-not $SkipModels) {
    Write-Log "Configuring Ollama Models..." "SECTION"

    $ConfigFile = Join-Path $PSScriptRoot "config.json"
    if (-not (Test-Path -Path $ConfigFile)) {
        $ConfigFile = Join-Path $InstallRoot "config.json"
    }

    $config = $null
    if (Test-Path -Path $ConfigFile) {
        try {
            $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        } catch { }
    }

    # Recommended pack based on RAM
    $recommendedPackKey = "light"
    if ($SysInfo.TotalRAM_GB -ge 24) {
        $recommendedPackKey = "coding"
    } elseif ($SysInfo.TotalRAM_GB -ge 12) {
        $recommendedPackKey = "balanced"
    }

    Write-Log "System RAM: $($SysInfo.TotalRAM_GB) GB -> Recommended Pack: '$recommendedPackKey'" "SUCCESS"

    if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
        # Check Ollama daemon accessibility
        try {
            ollama list *> $null
        }
        catch {
            Write-Log "Starting Ollama server process..."
            Start-Process -FilePath "ollama" -ArgumentList "serve" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }

        $selectedModels = @()
        if ($config -and $config.modelPacks -and $config.modelPacks.$recommendedPackKey) {
            $pack = $config.modelPacks.$recommendedPackKey
            Write-Log "Selected Pack: $($pack.name)"
            Write-Log "Est. Disk Needed: $($pack.estimatedDiskGB) GB | Free Disk: $($SysInfo.FreeDisk_GB) GB"

            if ($SysInfo.FreeDisk_GB -lt $pack.estimatedDiskGB) {
                Write-Log "Insufficient disk space to pull full pack '$recommendedPackKey'. Required: $($pack.estimatedDiskGB)GB, Free: $($SysInfo.FreeDisk_GB)GB." "WARN"
            } else {
                $selectedModels = $pack.models
            }
        } else {
            $selectedModels = @("qwen3.5:4b", "gemma3:4b", "llama3.2:3b", "nomic-embed-text")
        }

        $failedModels = @()
        foreach ($m in $selectedModels) {
            Write-Log "Pulling Ollama model '$m'..."
            ollama pull $m
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Failed to download model '$m'." "WARN"
                $failedModels += $m
            } else {
                Write-Log "Model '$m' downloaded successfully." "SUCCESS"
            }
        }

        if ($failedModels.Count -gt 0) {
            Write-Log "The following models could not be pulled: $($failedModels -join ', '). You can retry later with 'Manage-Models.ps1'." "WARN"
        }
    } else {
        Write-Log "Ollama binary not accessible in PATH yet; skipping model downloads." "WARN"
    }
}

# Create Desktop Shortcuts
Write-Log "Generating Desktop Shortcuts..." "SECTION"

try {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $wshell = New-Object -ComObject WScript.Shell

    # Start Shortcut
    $startLnk = $wshell.CreateShortcut((Join-Path $desktopPath "Start AI Lab.lnk"))
    $startLnk.TargetPath = "powershell.exe"
    $startLnk.Arguments = "-ExecutionPolicy Bypass -File `"$InstallRoot\scripts\Start-AI-Lab.ps1`""
    $startLnk.Description = "Start Icy AI Lab Docker Services"
    $startLnk.Save()

    # Stop Shortcut
    $stopLnk = $wshell.CreateShortcut((Join-Path $desktopPath "Stop AI Lab.lnk"))
    $stopLnk.TargetPath = "powershell.exe"
    $stopLnk.Arguments = "-ExecutionPolicy Bypass -File `"$InstallRoot\scripts\Stop-AI-Lab.ps1`""
    $stopLnk.Description = "Stop Icy AI Lab Docker Services"
    $stopLnk.Save()

    # Open WebUI URL Shortcut
    $webuiLnk = $wshell.CreateShortcut((Join-Path $desktopPath "Open WebUI.url"))
    $webuiLnk.TargetPath = "http://localhost:3000"
    $webuiLnk.Save()

    # n8n URL Shortcut
    $n8nLnk = $wshell.CreateShortcut((Join-Path $desktopPath "n8n Workflows.url"))
    $n8nLnk.TargetPath = "http://localhost:5678"
    $n8nLnk.Save()

    Write-Log "Desktop shortcuts created successfully." "SUCCESS"
}
catch {
    Write-Log "Shortcut creation encountered non-fatal error: $_" "WARN"
}

# Generate Machine-Readable Status Report
Write-Log "Generating Machine-Readable Status Report..." "SECTION"

$reportPath = Join-Path $InstallRoot "status_report.json"
$overallStatus = "Success"
$exitCode = $script:EXIT_SUCCESS

if ($global:HasWarnings) {
    $overallStatus = "PartialSuccess"
    $exitCode = $script:EXIT_PARTIAL_SUCCESS
}

$statusReport = @{
    Timestamp      = (Get-Date).ToString("o")
    InstallRoot    = $InstallRoot
    OverallStatus  = $overallStatus
    ExitCode       = $exitCode
    SystemInfo     = $SysInfo
    Services = @{
        OpenWebUI = "http://localhost:3000"
        n8n       = "http://localhost:5678"
    }
}

$reportJson = $statusReport | ConvertTo-Json -Depth 5
Set-Content -Path $reportPath -Value $reportJson -Encoding UTF8 -Force
Write-Log "Status report written to '$reportPath'." "SUCCESS"

Write-Log "Icy AI Lab Setup Complete!" "SECTION"
Write-Log "Root Folder: $InstallRoot" "SUCCESS"
Write-Log "Report:      $reportPath" "SUCCESS"

exit $exitCode
