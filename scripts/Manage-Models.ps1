[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [string]$Action = "list",
    [string]$PackOrModel = ""
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

if (-not (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
    Write-Log "Ollama is not installed or not in PATH." "ERROR"
    exit 1
}

$ConfigFile = Join-Path $LabRoot "config.json"
if (-not (Test-Path -Path $ConfigFile)) {
    $ConfigFile = Join-Path $PSScriptRoot "..\config.json"
}

$config = $null
if (Test-Path -Path $ConfigFile) {
    try {
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Failed to parse config.json at '$ConfigFile'." "WARN"
    }
}

switch ($Action.ToLower()) {
    "list" {
        Write-Log "Current Installed Ollama Models:" "SUCCESS"
        ollama list
        if ($config -and $config.modelPacks) {
            Write-Host "`nAvailable Configured Model Packs in config.json:" -ForegroundColor Yellow
            $config.modelPacks.psobject.properties | ForEach-Object {
                $packInfo = $_.Value
                Write-Host "  - Pack Name: $($_.Name) ($($packInfo.name))" -ForegroundColor Cyan
                Write-Host "    Min RAM: $($packInfo.minRamGB) GB | Est Disk: $($packInfo.estimatedDiskGB) GB" -ForegroundColor White
                Write-Host "    Models:  $($packInfo.models -join ', ')" -ForegroundColor Gray
            }
        }
    }
    "pull-pack" {
        if (-not $PackOrModel) {
            Write-Log "Please specify a pack name (e.g. light, balanced, coding)." "ERROR"
            exit 1
        }
        if (-not $config -or -not $config.modelPacks.$PackOrModel) {
            Write-Log "Model pack '$PackOrModel' not found in config.json." "ERROR"
            exit 1
        }
        $selectedPack = $config.modelPacks.$PackOrModel
        Write-Log "Pulling model pack '$PackOrModel' ($($selectedPack.name)). Total Est. Disk: $($selectedPack.estimatedDiskGB) GB..." "SUCCESS"
        foreach ($m in $selectedPack.models) {
            Write-Log "Pulling model '$m'..."
            ollama pull $m
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Failed to pull model '$m'." "WARN"
            }
        }
    }
    "pull" {
        if (-not $PackOrModel) {
            Write-Log "Please specify a model tag (e.g. qwen3.5:4b)." "ERROR"
            exit 1
        }
        Write-Log "Pulling model '$PackOrModel'..."
        ollama pull $PackOrModel
    }
    "remove" {
        if (-not $PackOrModel) {
            Write-Log "Please specify a model tag to remove." "ERROR"
            exit 1
        }
        Write-Log "Removing model '$PackOrModel'..."
        ollama rm $PackOrModel
    }
    default {
        Write-Log "Unknown action '$Action'. Supported actions: list, pull-pack, pull, remove" "ERROR"
    }
}
