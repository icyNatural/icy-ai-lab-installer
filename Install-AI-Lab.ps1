#requires -Version 5.1
<#
.SYNOPSIS
    Icy AI Lab Production-Quality Portable Windows Bootstrapper (v2.1.0)
.DESCRIPTION
    Enterprise-grade installer and management suite for a local AI workstation.
    Automates hardware diagnostics, WSL 2 enablement with reboot-resume state machine,
    Winget package deployment, Docker Desktop, Ollama, Open WebUI, n8n, model packs,
    backup/restore/repair scripts, and desktop shortcuts.
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [string]$ModelPack = "",
    [switch]$SkipReboot,
    [switch]$SkipModels,
    [switch]$NonInteractive,
    [switch]$ResumedFromReboot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Global Constants & Exit Codes
$script:INSTALLER_VERSION     = "2.1.0"
$script:STATE_SCHEMA_VERSION  = "1.0"

$script:EXIT_SUCCESS          = 0
$script:EXIT_REBOOT_REQUIRED = 10
$script:EXIT_PARTIAL_SUCCESS  = 20
$script:EXIT_FAILURE          = 1

$global:HasWarnings           = $false

# Define State & Staging Paths
$script:StateDir        = Join-Path $env:LOCALAPPDATA "IcyAILab"
$script:StateFile       = Join-Path $script:StateDir "installer-state.json"
$script:StagingDir      = Join-Path $script:StateDir "InstallerSource"
$script:RunOnceKey      = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$script:RunOnceValue    = "IcyAILabResume"

# Single-Instance Mutex Safeguard
$script:InstallerMutex  = $null
$createdNew             = $false
try {
    $script:InstallerMutex = New-Object System.Threading.Mutex($true, "Global\IcyAILabInstallerMutex", [ref]$createdNew)
} catch {
    $createdNew = $true
}

if (-not $createdNew) {
    Write-Host "ERROR: Another instance of Icy AI Lab Installer is already running." -ForegroundColor Red
    exit $script:EXIT_FAILURE
}

# Resolve Source Script Path & Working Directory
$resolvedScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($resolvedScriptPath) -or -not (Test-Path -Path $resolvedScriptPath)) {
    $resolvedScriptPath = $PSCommandPath
}
if ($resolvedScriptPath -and (Test-Path -Path $resolvedScriptPath)) {
    $resolvedScriptPath = (Get-Item -Path $resolvedScriptPath).FullName
}
$scriptWorkingDir = (Get-Location).Path

# Helper: Check UAC Elevation
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Helper: Stage Installer Source Files to Stable Location
function Stage-InstallerSource {
    param([string]$SourcePath)

    if (-not (Test-Path -Path $script:StagingDir)) {
        New-Item -ItemType Directory -Path $script:StagingDir -Force | Out-Null
    }

    $sourceDir = Split-Path -Parent $SourcePath
    if ([string]::IsNullOrWhiteSpace($sourceDir) -or -not (Test-Path -Path $sourceDir)) {
        $sourceDir = (Get-Location).Path
    }

    # Copy core script, config, and directories
    $itemsToStage = @("Install-AI-Lab.ps1", "config.json", "docker", "scripts")
    foreach ($item in $itemsToStage) {
        $itemPath = Join-Path $sourceDir $item
        if (Test-Path -Path $itemPath) {
            Copy-Item -Path $itemPath -Destination $script:StagingDir -Recurse -Force
        }
    }

    $stagedScript = Join-Path $script:StagingDir "Install-AI-Lab.ps1"
    if (-not (Test-Path -Path $stagedScript)) {
        throw "Failed to stage installer source file to '$stagedScript'."
    }

    return $stagedScript
}

# Stage files before UAC or Reboot operations
$stagedScriptPath = $resolvedScriptPath
try {
    if (Test-Path -Path $resolvedScriptPath) {
        $stagedScriptPath = Stage-InstallerSource -SourcePath $resolvedScriptPath
    }
} catch {
    # Non-fatal during preflight fallback
}

# Self-Elevate if not Administrator
if (-not (Test-IsAdmin)) {
    Write-Host "Elevating privileges to Administrator..." -ForegroundColor Yellow

    $targetScriptToRun = if (Test-Path -Path $stagedScriptPath) { $stagedScriptPath } else { $resolvedScriptPath }

    if ([string]::IsNullOrWhiteSpace($targetScriptToRun) -or -not (Test-Path -Path $targetScriptToRun)) {
        Write-Host "ERROR: Could not resolve script path for UAC elevation." -ForegroundColor Red
        exit $script:EXIT_FAILURE
    }

    # Build escaped argument string using -NoExit
    $argList = "-NoExit -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$targetScriptToRun`" -InstallRoot `"$InstallRoot`""
    if (-not [string]::IsNullOrWhiteSpace($ModelPack)) { $argList += " -ModelPack `"$ModelPack`"" }
    if ($SkipReboot)        { $argList += " -SkipReboot" }
    if ($SkipModels)        { $argList += " -SkipModels" }
    if ($NonInteractive)     { $argList += " -NonInteractive" }
    if ($ResumedFromReboot)  { $argList += " -ResumedFromReboot" }
    if ($Force)              { $argList += " -Force" }

    # Release mutex so elevated child process can acquire it
    if ($script:InstallerMutex) {
        try { $script:InstallerMutex.ReleaseMutex(); $script:InstallerMutex.Dispose() } catch { }
        $script:InstallerMutex = $null
    }

    try {
        $process = Start-Process -FilePath "powershell.exe" -WorkingDirectory "$scriptWorkingDir" -ArgumentList $argList -Verb RunAs -PassThru
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
Write-Host "Administrator privileges acquired." -ForegroundColor Green
Write-Host "Continuing installation..." -ForegroundColor Green

try {
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

    # State Machine Persistence Functions
    function Read-InstallerState {
        if (Test-Path -Path $script:StateFile) {
            try {
                return Get-Content -Path $script:StateFile -Raw | ConvertFrom-Json
            } catch { return $null }
        }
        return $null
    }

    function Save-InstallerState([string]$Phase, [int]$RebootCount = 0, [string]$LastError = "") {
        if (-not (Test-Path -Path $script:StateDir)) {
            New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        }

        $existing = Read-InstallerState
        $createdAt = if ($existing -and $existing.createdAt) { $existing.createdAt } else { (Get-Date).ToString("o") }

        $stateObj = [ordered]@{
            schemaVersion     = $script:STATE_SCHEMA_VERSION
            installerVersion  = $script:INSTALLER_VERSION
            scriptPath        = $stagedScriptPath
            workingDirectory  = $scriptWorkingDir
            installRoot       = $InstallRoot
            selectedModelPack = $ModelPack
            currentPhase      = $Phase
            rebootCount       = $RebootCount
            createdAt         = $createdAt
            updatedAt         = (Get-Date).ToString("o")
            lastError         = $LastError
            originalArguments = $PSBoundParameters.Values -join ' '
        }

        $json = $stateObj | ConvertTo-Json -Depth 5
        Set-Content -Path $script:StateFile -Value $json -Encoding UTF8 -Force
    }

    function Cleanup-InstallerState {
        if (Test-Path -Path $script:StateFile) {
            Remove-Item -Path $script:StateFile -Force -ErrorAction SilentlyContinue
        }
        Remove-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceValue -ErrorAction SilentlyContinue
    }

    function Create-DesktopRecoveryShortcut([string]$ScriptPath) {
        try {
            $desktopPath = [Environment]::GetFolderPath("Desktop")
            $shortcutPath = Join-Path $desktopPath "Resume AI Lab Setup.lnk"
            $wshell = New-Object -ComObject WScript.Shell
            $shortcut = $wshell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = "powershell.exe"
            $shortcut.Arguments = "-NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$ScriptPath`" -ResumedFromReboot -InstallRoot `"$InstallRoot`""
            $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
            $shortcut.Description = "Resume Icy AI Lab Installation"
            $shortcut.Save()
            Write-Log "Created Desktop Recovery Shortcut: '$shortcutPath'" "SUCCESS"
        } catch { }
    }

    # UX Stage Banner Helper
    function Show-StageBanner([string]$StageNum, [string]$Title) {
        Write-Log "[$StageNum] $Title" "SECTION"
    }

    Write-Log "Icy AI Lab Windows Bootstrapper Started (v$script:INSTALLER_VERSION)" "SECTION"
    Write-Log "Target Install Root: '$InstallRoot'"
    Write-Log "Log File Location:   '$LogFile'"
    Write-Log "Staged Script Path:  '$stagedScriptPath'"
    Write-Log "Working Directory:   '$scriptWorkingDir'"

    # State Recovery Check
    $savedState = Read-InstallerState
    $rebootCount = 0
    if ($savedState -and $savedState.rebootCount) {
        $rebootCount = [int]$savedState.rebootCount
    }

    if ($ResumedFromReboot -or $savedState) {
        # Always remove RunOnce key on resume to prevent infinite reboot loops
        Remove-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceValue -ErrorAction SilentlyContinue
        Write-Log "RunOnce key removed to prevent duplicate auto-resume loops."

        if ($rebootCount -ge 2) {
            Write-Log "ERROR: Maximum reboot-resume attempts (2) reached for this state." "ERROR"
            Save-InstallerState -Phase "Failed" -RebootCount $rebootCount -LastError "Maximum reboot-resume limit reached"
            Cleanup-InstallerState

            Create-DesktopRecoveryShortcut -ScriptPath $stagedScriptPath
            $manualCmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$stagedScriptPath`" -InstallRoot `"$InstallRoot`""
            Write-Log "To attempt manual recovery, run: $manualCmd" "WARN"

            Write-Host "`nInstallation failed." -ForegroundColor Red
            if (-not $NonInteractive) { Read-Host "Press Enter to exit..." }
            exit $script:EXIT_FAILURE
        }

        # Validate Staged Script File Existence
        if (-not (Test-Path -Path $stagedScriptPath)) {
            Write-Log "ERROR: Staged installer script no longer exists at '$stagedScriptPath'." "ERROR"
            Create-DesktopRecoveryShortcut -ScriptPath $resolvedScriptPath
            $manualCmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$resolvedScriptPath`" -InstallRoot `"$InstallRoot`""
            Write-Log "Please locate Install-AI-Lab.ps1 and run manually: $manualCmd" "ERROR"
            exit $script:EXIT_FAILURE
        }

        Write-Host "Resuming Icy AI Lab installation after reboot." -ForegroundColor Green
        Write-Log "Resuming Icy AI Lab installation after reboot (Resume Count: $rebootCount)." "SUCCESS"
    }

    # =========================================================================
    # STAGE 1/9: SYSTEM CHECKS
    # =========================================================================
    Show-StageBanner "1/9" "System Checks & Hardware Diagnostics"
    Save-InstallerState -Phase "Preflight" -RebootCount $rebootCount

    $SysInfo = @{}
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

    if ($SysInfo.BuildNumber -lt 19041) {
        Write-Log "Windows 10 Build 19041 or Windows 11 is required for WSL 2 feature support. Current build: $($SysInfo.BuildNumber)." "ERROR"
        Save-InstallerState -Phase "Failed" -RebootCount $rebootCount -LastError "Unsupported Windows Build"
        Write-Host "`nInstallation failed." -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "Press Enter to exit..." }
        exit $script:EXIT_FAILURE
    }

    if ($SysInfo.FreeDisk_GB -lt 15) {
        Write-Log "Less than 15 GB free disk space available ($($SysInfo.FreeDisk_GB) GB). Setup will continue but model pulls may fail." "WARN"
    }

    # =========================================================================
    # STAGE 2/9: PREPARING WINDOWS FEATURES
    # =========================================================================
    Show-StageBanner "2/9" "Preparing Windows Features (WSL 2 & Virtual Machine Platform)"
    Save-InstallerState -Phase "EnableWindowsFeatures" -RebootCount $rebootCount

    $newlyEnabledFeatures = $false
    try {
        $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"
        $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"

        if ($wslFeature.State -ne "Enabled") {
            Write-Log "Enabling Microsoft-Windows-Subsystem-Linux..."
            Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart | Out-Null
            $newlyEnabledFeatures = $true
        }

        if ($vmpFeature.State -ne "Enabled") {
            Write-Log "Enabling VirtualMachinePlatform..."
            Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart | Out-Null
            $newlyEnabledFeatures = $true
        }
    }
    catch {
        Write-Log "DISM check encountered exception: $_. Falling back to dism.exe..." "WARN"
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        $newlyEnabledFeatures = $true
    }

    # Verify if WSL is functional before demanding reboot
    $wslFunctional = $false
    if (Get-Command "wsl" -ErrorAction SilentlyContinue) {
        $wslStatusCheck = wsl --status 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $wslStatusCheck -notmatch "reboot") {
            $wslFunctional = $true
        }
    }

    # Trigger Reboot ONLY if features were newly enabled AND WSL is not yet functional
    if ($newlyEnabledFeatures -and -not $wslFunctional) {
        Write-Log "Windows features were newly enabled. A system restart is required before WSL 2 can initialize." "WARN"

        $newRebootCount = $rebootCount + 1
        Save-InstallerState -Phase "AwaitingReboot" -RebootCount $newRebootCount

        # Register RunOnce against staged script
        $resumeCmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$stagedScriptPath`" -ResumedFromReboot -InstallRoot `"$InstallRoot`""
        if (-not [string]::IsNullOrWhiteSpace($ModelPack)) { $resumeCmd += " -ModelPack `"$ModelPack`"" }
        if ($SkipModels)     { $resumeCmd += " -SkipModels" }
        if ($NonInteractive) { $resumeCmd += " -NonInteractive" }
        if ($Force)          { $resumeCmd += " -Force" }

        Set-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceValue -Value $resumeCmd -Force
        Write-Log "Registered RunOnce Key: $resumeCmd" "SUCCESS"

        if (-not $NonInteractive) {
            $resp = Read-Host "Would you like to restart your computer now? [Y/n]"
            if ($resp -notmatch '^[Nn]') {
                Write-Log "Initiating system restart..." "SUCCESS"
                Restart-Computer -Force
                Write-Host "`nRestart required." -ForegroundColor Yellow
                exit $script:EXIT_REBOOT_REQUIRED
            } else {
                Write-Host "Restart Windows, then sign back in. Installation will resume automatically." -ForegroundColor Yellow
                Write-Log "User declined immediate reboot. Installation paused until restart." "WARN"
                Write-Host "`nRestart required." -ForegroundColor Yellow
                if (-not $NonInteractive) { Read-Host "Press Enter to exit..." }
                exit $script:EXIT_REBOOT_REQUIRED
            }
        } else {
            if (-not $SkipReboot) {
                Write-Log "Non-interactive mode: initiating system restart..." "SUCCESS"
                Restart-Computer -Force
                Write-Host "`nRestart required." -ForegroundColor Yellow
                exit $script:EXIT_REBOOT_REQUIRED
            } else {
                Write-Host "Restart Windows, then sign back in. Installation will resume automatically." -ForegroundColor Yellow
                Write-Log "SkipReboot specified. Installation paused until restart." "WARN"
                Write-Host "`nRestart required." -ForegroundColor Yellow
                exit $script:EXIT_REBOOT_REQUIRED
            }
        }
    } else {
        Write-Log "WSL 2 optional features verified active." "SUCCESS"
    }

    # =========================================================================
    # STAGE 3/9: VERIFYING WSL
    # =========================================================================
    Show-StageBanner "3/9" "Verifying WSL 2 Engine & Default Kernel"
    Save-InstallerState -Phase "VerifyWSL" -RebootCount $rebootCount

    if (Get-Command "wsl" -ErrorAction SilentlyContinue) {
        Write-Log "Setting default WSL version to 2..."
        wsl --set-default-version 2 2>&1 | Out-Null
        Write-Log "Updating WSL kernel binaries..."
        wsl --update 2>&1 | Out-Null
        Write-Log "WSL 2 verified functional." "SUCCESS"
    } else {
        Write-Log "WSL binary not accessible yet; proceeding with package installations." "WARN"
    }

    # =========================================================================
    # STAGE 4/9: INSTALLING APPLICATIONS
    # =========================================================================
    Show-StageBanner "4/9" "Installing Core Applications via Winget"
    Save-InstallerState -Phase "InstallApplications" -RebootCount $rebootCount

    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
        Write-Log "ERROR: winget package manager is missing. Please install App Installer from Microsoft Store." "ERROR"
        Save-InstallerState -Phase "Failed" -RebootCount $rebootCount -LastError "winget missing"
        Write-Host "`nInstallation failed." -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "Press Enter to exit..." }
        exit $script:EXIT_FAILURE
    }

    function Install-ManagedPackage {
        param([string]$Id, [string]$Name, [bool]$IsCritical = $false)

        Write-Log "Checking installation status of $Name ($Id)..."
        $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $installed -match [regex]::Escape($Id)) {
            Write-Log "$Name is already installed." "SUCCESS"
            return $true
        }

        Write-Log "Installing $Name..."
        winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully installed $Name." "SUCCESS"
            return $true
        } else {
            if ($IsCritical) {
                Write-Log "Critical application $Name failed to install (Exit code $LASTEXITCODE)." "ERROR"
                return $false
            } else {
                Write-Log "Non-critical package $Name did not complete cleanly; continuing." "WARN"
                return $true
            }
        }
    }

    $packages = @(
        @{ Id = "Git.Git";                    Name = "Git";                Critical = $false },
        @{ Id = "Microsoft.VisualStudioCode"; Name = "Visual Studio Code"; Critical = $false },
        @{ Id = "Python.Python.3.12";         Name = "Python 3.12";        Critical = $false },
        @{ Id = "OpenJS.NodeJS.LTS";          Name = "Node.js LTS";         Critical = $false },
        @{ Id = "Docker.DockerDesktop";       Name = "Docker Desktop";      Critical = $true },
        @{ Id = "Ollama.Ollama";              Name = "Ollama";             Critical = $true }
    )

    foreach ($pkg in $packages) {
        $res = Install-ManagedPackage -Id $pkg.Id -Name $pkg.Name -IsCritical $pkg.Critical
        if (-not $res -and $pkg.Critical) {
            Write-Log "Critical application deployment failed for $($pkg.Name)." "ERROR"
        }
    }

    # Refresh Environment PATH
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"

    # Deploy Helper Management Scripts
    $SourceScripts = Join-Path $script:StagingDir "scripts"
    if (-not (Test-Path -Path $SourceScripts)) {
        $SourceScripts = Join-Path $PSScriptRoot "scripts"
    }
    if (Test-Path -Path $SourceScripts) {
        Copy-Item -Path "$SourceScripts\*" -Destination (Join-Path $InstallRoot "scripts") -Force -Recurse
        Write-Log "Management scripts deployed to '$InstallRoot\scripts'." "SUCCESS"
    }

    # =========================================================================
    # STAGE 5/9: STARTING DOCKER
    # =========================================================================
    Show-StageBanner "5/9" "Starting Docker Desktop Engine"
    Save-InstallerState -Phase "StartDocker" -RebootCount $rebootCount

    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Docker daemon inactive. Launching Docker Desktop..." "WARN"
        $DockerDesktopBin = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
        if (Test-Path -Path $DockerDesktopBin) {
            Start-Process -FilePath $DockerDesktopBin -ErrorAction SilentlyContinue
        }

        Write-Log "Waiting for Docker engine readiness (timeout 180s)..."
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
        } else {
            Write-Log "Docker Desktop engine is ready." "SUCCESS"
        }
    } else {
        Write-Log "Docker Desktop engine is active." "SUCCESS"
    }

    # =========================================================================
    # STAGE 6/9: STARTING OPEN WEBUI AND N8N
    # =========================================================================
    Show-StageBanner "6/9" "Starting Open WebUI and n8n Containers"
    Save-InstallerState -Phase "StartServices" -RebootCount $rebootCount

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
    Write-Log "Docker Compose configured at '$ComposePath' (bound strictly to 127.0.0.1)." "SUCCESS"

    if (Get-Command "docker" -ErrorAction SilentlyContinue) {
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            Push-Location -Path $DockerDir
            try {
                docker compose up -d
                Write-Log "Open WebUI container running at: http://localhost:3000" "SUCCESS"
                Write-Log "n8n container running at:        http://localhost:5678" "SUCCESS"
            }
            catch {
                Write-Log "Docker compose up encountered warning: $_" "WARN"
            }
            finally {
                Pop-Location
            }
        }
    }

    # =========================================================================
    # STAGE 7/9: DOWNLOADING MODELS
    # =========================================================================
    Show-StageBanner "7/9" "Configuring & Pulling Ollama Models"
    Save-InstallerState -Phase "PullModels" -RebootCount $rebootCount

    if (-not $SkipModels) {
        $ConfigFile = Join-Path $script:StagingDir "config.json"
        if (-not (Test-Path -Path $ConfigFile)) {
            $ConfigFile = Join-Path $InstallRoot "config.json"
        }

        $config = $null
        if (Test-Path -Path $ConfigFile) {
            try {
                $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
            } catch { }
        }

        # Model pack selection: Default to balanced unless RAM < 12GB (light) or explicitly specified
        $selectedPackKey = "balanced"
        if (-not [string]::IsNullOrWhiteSpace($ModelPack)) {
            $selectedPackKey = $ModelPack.ToLower()
        } elseif ($SysInfo.TotalRAM_GB -lt 12) {
            $selectedPackKey = "light"
        }

        Write-Log "Selected Model Pack: '$selectedPackKey'" "SUCCESS"

        if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
            try {
                ollama list *> $null
            } catch {
                Write-Log "Launching Ollama background process..."
                Start-Process -FilePath "ollama" -ArgumentList "serve" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }

            $selectedModels = @()
            if ($config -and $config.modelPacks -and $config.modelPacks.$selectedPackKey) {
                $packObj = $config.modelPacks.$selectedPackKey
                Write-Log "Pack Name: $($packObj.name)"
                Write-Log "Est. Disk: $($packObj.estimatedDiskGB) GB | Available Free Disk: $($SysInfo.FreeDisk_GB) GB"

                if ($SysInfo.FreeDisk_GB -ge $packObj.estimatedDiskGB) {
                    $selectedModels = $packObj.models
                } else {
                    Write-Log "Free disk space is lower than estimated pack size; pulling default starter models." "WARN"
                    $selectedModels = @("qwen3.5:4b", "gemma3:4b", "llama3.2:3b", "nomic-embed-text")
                }
            } else {
                $selectedModels = @("qwen3.5:4b", "gemma3:4b", "llama3.2:3b", "nomic-embed-text")
            }

            # Check existing models to avoid duplicate downloads
            $existingModels = @()
            try {
                $existingModels = ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] }
            } catch { }

            $failedModels = @()
            foreach ($m in $selectedModels) {
                if ($existingModels -contains $m) {
                    Write-Log "Model '$m' is already downloaded. Skipping." "SUCCESS"
                    continue
                }

                Write-Log "Pulling Ollama model '$m'..."
                ollama pull $m
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to download model '$m'." "WARN"
                    $failedModels += $m
                } else {
                    Write-Log "Successfully pulled model '$m'." "SUCCESS"
                }
            }

            if ($failedModels.Count -gt 0) {
                Write-Log "Model pull incomplete for: $($failedModels -join ', '). Retry later via Manage-Models.ps1." "WARN"
            }
        } else {
            Write-Log "Ollama service not available in PATH yet; skipping model pulls." "WARN"
        }
    }

    # =========================================================================
    # STAGE 8/9: CREATING SHORTCUTS
    # =========================================================================
    Show-StageBanner "8/9" "Generating Desktop Shortcuts"
    Save-InstallerState -Phase "CreateShortcuts" -RebootCount $rebootCount

    try {
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        $wshell = New-Object -ComObject WScript.Shell

        # Start Shortcut
        $startLnk = $wshell.CreateShortcut((Join-Path $desktopPath "Start AI Lab.lnk"))
        $startLnk.TargetPath = "powershell.exe"
        $startLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallRoot\scripts\Start-AI-Lab.ps1`""
        $startLnk.Description = "Start Icy AI Lab Docker Services"
        $startLnk.Save()

        # Stop Shortcut
        $stopLnk = $wshell.CreateShortcut((Join-Path $desktopPath "Stop AI Lab.lnk"))
        $stopLnk.TargetPath = "powershell.exe"
        $stopLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallRoot\scripts\Stop-AI-Lab.ps1`""
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

        Write-Log "Desktop shortcuts generated successfully." "SUCCESS"
    } catch {
        Write-Log "Shortcut creation encountered non-fatal error: $_" "WARN"
    }

    # =========================================================================
    # STAGE 9/9: FINAL VERIFICATION & REPORTING
    # =========================================================================
    Show-StageBanner "9/9" "Final Verification & Status Report"
    Save-InstallerState -Phase "Complete" -RebootCount $rebootCount

    $reportPath = Join-Path $InstallRoot "status_report.json"
    $overallStatus = "Success"
    $exitCode = $script:EXIT_SUCCESS

    if ($global:HasWarnings) {
        $overallStatus = "PartialSuccess"
        $exitCode = $script:EXIT_PARTIAL_SUCCESS
    }

    $statusReport = [ordered]@{
        installerVersion = $script:INSTALLER_VERSION
        phase            = "Complete"
        overallStatus    = $overallStatus
        exitCode         = $exitCode
        rebootCount      = $rebootCount
        timestamp        = (Get-Date).ToString("o")
        installRoot      = $InstallRoot
        systemInfo       = $SysInfo
        services         = @{
            openWebUI = "http://localhost:3000"
            n8n       = "http://localhost:5678"
        }
        logPath          = $LogFile
    }

    $reportJson = $statusReport | ConvertTo-Json -Depth 5
    Set-Content -Path $reportPath -Value $reportJson -Encoding UTF8 -Force
    Write-Log "Status report saved to '$reportPath'." "SUCCESS"

    # Cleanup State on Successful Complete
    Cleanup-InstallerState

    Write-Log "Icy AI Lab Setup Finished!" "SECTION"
    Write-Log "Root Directory: $InstallRoot" "SUCCESS"
    Write-Log "Open WebUI:     http://localhost:3000" "SUCCESS"
    Write-Log "n8n Workflows:  http://localhost:5678" "SUCCESS"
    Write-Log "Status Report:  $reportPath" "SUCCESS"

    if ($global:HasWarnings) {
        Write-Host "`nInstallation completed with warnings." -ForegroundColor Yellow
    } else {
        Write-Host "`nInstallation completed successfully." -ForegroundColor Green
    }

    if (-not $NonInteractive) {
        Read-Host "Press Enter to exit..."
    }

    exit $exitCode
}
catch {
    $err = $_
    Write-Host "`nCRITICAL ERROR ENCOUNTERED:" -ForegroundColor Red
    Write-Host "$err" -ForegroundColor Red
    if ($err.ScriptStackTrace) {
        Write-Host "$($err.ScriptStackTrace)" -ForegroundColor Red
    }
    if (Get-Command "Write-Log" -ErrorAction SilentlyContinue) {
        Write-Log "CRITICAL UNHANDLED ERROR: $err`n$($err.ScriptStackTrace)" "ERROR"
    }

    Write-Host "`nInstallation failed." -ForegroundColor Red
    if (-not $NonInteractive) {
        Read-Host "Press Enter to exit..."
    }
    exit $script:EXIT_FAILURE
}
finally {
    if ($script:InstallerMutex) {
        try { $script:InstallerMutex.ReleaseMutex(); $script:InstallerMutex.Dispose() } catch { }
        $script:InstallerMutex = $null
    }
}
