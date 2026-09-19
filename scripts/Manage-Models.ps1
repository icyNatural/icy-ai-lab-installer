#requires -Version 5.1
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

$ollamaAvailable = [bool](Get-Command "ollama" -ErrorAction SilentlyContinue)
$actionsWithoutOllama = @("catalog", "assess", "profile", "recommend")
if (-not $ollamaAvailable -and $actionsWithoutOllama -notcontains $Action.ToLower()) {
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

$AdaptiveModule = Join-Path $PSScriptRoot "Adaptive-AI-Lab.psm1"
$CatalogFile = Join-Path $LabRoot "model-catalog.json"
if (-not (Test-Path $CatalogFile)) { $CatalogFile = Join-Path $PSScriptRoot "..\model-catalog.json" }

function Get-AdaptiveContext {
    if (-not (Test-Path $AdaptiveModule)) { throw "Adaptive module missing at '$AdaptiveModule'." }
    Import-Module $AdaptiveModule -Force -ErrorAction Stop
    $hardware = Get-AIHardwareProfile
    $catalog = Import-AIModelCatalog -Path $CatalogFile
    return [pscustomobject]@{ Hardware = $hardware; Catalog = $catalog }
}

function Test-SafeAdaptivePull([string]$Tag) {
    try {
        $context = Get-AdaptiveContext
        $model = @($context.Catalog.models | Where-Object { $_.tag -eq $Tag }) | Select-Object -First 1
        if (-not $model) { Write-Log "'$Tag' is not an explicitly tagged catalog model." "ERROR"; return $false }
        $compatibility = Test-AIModelCompatibility -Model $model -Hardware $context.Hardware
        $safe = if ($compatibility -is [bool]) { $compatibility } elseif ($compatibility.PSObject.Properties['Compatible']) { [bool]$compatibility.Compatible } else { $false }
        if (-not $safe) { Write-Log "Hardware/storage checks rejected '$Tag'; nothing was downloaded." "ERROR" }
        return $safe
    } catch { Write-Log "Safe pull check failed closed: $_" "ERROR"; return $false }
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
    "catalog" {
        try {
            $context = Get-AdaptiveContext
            Write-Host "Adaptive model catalog (metadata only):" -ForegroundColor Yellow
            $context.Catalog.models | ForEach-Object { Write-Host ("  {0} | tasks: {1} | artifact: {2} | min RAM/disk: {3}/{4} GB" -f $_.tag,($_.tasks -join ','),$_.artifactSizeDisplay,$_.minimum.ramGB,$_.minimum.diskGB) }
        } catch { Write-Log "Catalog action failed: $_" "ERROR" }
    }
    "assess" {
        try {
            $context = Get-AdaptiveContext
            Write-Host ("RAM: {0} GB installed / {1} GB available; GPU mode: {2}; free model disk: {3} GB" -f $context.Hardware.Memory.InstalledGB.Value,$context.Hardware.Memory.AvailableGB.Value,$context.Hardware.GPU.Mode,$context.Hardware.Storage.FreeGB.Value) -ForegroundColor Cyan
            Write-Host "This is a quick hardware assessment, not a performance benchmark." -ForegroundColor Yellow
        } catch { Write-Log "Assessment failed: $_" "ERROR" }
    }
    "profile" {
        $profileScript = Join-Path $PSScriptRoot "Profile-AI-Lab.ps1"
        if (Test-Path -Path $profileScript) { & $profileScript -LabRoot $LabRoot } else { Write-Log "Profiler script missing at '$profileScript'." "ERROR" }
    }
    "recommend" {
        try {
            $task = if ([string]::IsNullOrWhiteSpace($PackOrModel)) { "general" } else { $PackOrModel.ToLower() }
            if (@("general","coding","reasoning","vision","embedding","tools") -notcontains $task) { throw "Specify a task: general, coding, reasoning, vision, embedding, or tools." }
            $context = Get-AdaptiveContext
            $benchmarkReport=$null
            $latestReport=Get-ChildItem (Join-Path $LabRoot 'logs') -Filter 'benchmark_*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
            if($latestReport){try{$benchmarkReport=Get-Content $latestReport.FullName -Raw|ConvertFrom-Json}catch{}}
            $result = Get-AIModelRecommendation -Catalog $context.Catalog -Hardware $context.Hardware -Task $task -BenchmarkReport $benchmarkReport
            $result.Candidates | ForEach-Object {
                Write-Host ("  {0} | compatible: {1} | placement estimate: {2}" -f $_.Tag,$_.Compatible,$_.Estimated.Placement)
                foreach ($warning in @($_.Warnings)) { Write-Host "    warning: $warning" -ForegroundColor Yellow }
                foreach ($reason in @($_.Reasons)) { Write-Host "    blocked: $reason" -ForegroundColor Red }
            }
            if ($result.FallbackUsed) { Write-Host 'No candidate passed every compatibility check; the first item is provisional only.' -ForegroundColor Yellow }
            Write-Host $result.Basis -ForegroundColor Yellow
            Write-Host "`nTask portfolio:" -ForegroundColor Cyan
            Get-AIRecommendationPortfolio -Catalog $context.Catalog -Hardware $context.Hardware -BenchmarkReport $benchmarkReport | ForEach-Object { Write-Host ("  {0}: {1} | provisional: {2} | {3}" -f $_.Category,$_.Model,$_.Provisional,$_.Explanation) }
            Write-Host "Recommendations do not download or remove models." -ForegroundColor Yellow
        } catch { Write-Log "Recommendation failed: $_" "ERROR" }
    }
    "benchmark" {
        $benchmarkScript = Join-Path $PSScriptRoot "Benchmark-AI-Lab.ps1"
        if (Test-Path -Path $benchmarkScript) {
            & $benchmarkScript -LabRoot $LabRoot -Model $PackOrModel
        } else {
            Write-Log "Benchmark script missing at '$benchmarkScript'." "ERROR"
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
        try {
            $targetPath = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $env:USERPROFILE ".ollama\models" }
            $probe = $targetPath
            while ($probe -and -not (Test-Path $probe)) { $probe = Split-Path $probe -Parent }
            if (-not $probe) { throw "Model volume could not be resolved." }
            $root = [IO.Path]::GetPathRoot((Get-Item $probe).FullName)
            $freeGB = [math]::Round((New-Object IO.DriveInfo($root)).AvailableFreeSpace / 1GB, 2)
            if ($freeGB -lt [double]$selectedPack.estimatedDiskGB) { throw "Pack needs about $($selectedPack.estimatedDiskGB) GB; only $freeGB GB is free." }
        } catch { Write-Log "Pack storage check failed closed: $_" "ERROR"; exit 1 }
        Write-Log "Storage check passed. Pulling model pack '$PackOrModel' ($($selectedPack.name)). Total Est. Disk: $($selectedPack.estimatedDiskGB) GB..." "SUCCESS"
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
            Write-Log "Please specify an explicitly tagged catalog model (e.g. llama3.2:1b)." "ERROR"
            exit 1
        }
        if (-not (Test-SafeAdaptivePull -Tag $PackOrModel)) { exit 1 }
        Write-Log "Safe checks passed. Pulling model '$PackOrModel'..."
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
        Write-Log "Unknown action '$Action'. Supported actions: list, catalog, assess, profile, recommend, benchmark, pull-pack, pull, remove" "ERROR"
    }
}
