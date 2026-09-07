[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [string]$OllamaUrl = "http://localhost:11434",
    [switch]$JsonOutput
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

function Write-Log([string]$Message, [string]$Level = "INFO") {
    if ($JsonOutput) { return }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $formatted -ForegroundColor Red }
        "WARN"    { Write-Host $formatted -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formatted -ForegroundColor Green }
        "HEADER"  {
            Write-Host "`n============================================================" -ForegroundColor Cyan
            Write-Host " $Message" -ForegroundColor Cyan
            Write-Host "============================================================" -ForegroundColor Cyan
        }
        default   { Write-Host $formatted -ForegroundColor White }
    }
}

Write-Log "AI Workstation Hardware & Model Profiler" "HEADER"

# 1. Hardware Detection
$hardware = [ordered]@{
    CPUName            = "Unknown"
    CPUCores           = 0
    CPULogicalProcessors = 0
    TotalRAM_GB        = 0.0
    FreeRAM_GB         = 0.0
    GPUAdapters        = @()
    NvidiaSmiAvailable = $false
    NvidiaVRAM_GB      = 0.0
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $hardware.TotalRAM_GB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $hardware.FreeRAM_GB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu) {
        $hardware.CPUName              = $cpu.Name.Trim()
        $hardware.CPUCores             = [int]$cpu.NumberOfCores
        $hardware.CPULogicalProcessors = [int]$cpu.NumberOfLogicalProcessors
    }

    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        $vramGB = [math]::Round($gpu.AdapterRAM / 1GB, 2)
        $hardware.GPUAdapters += [ordered]@{
            Name          = $gpu.Name
            DriverVersion = $gpu.DriverVersion
            ReportedVRAM_GB = $vramGB
        }
    }

    if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
        $hardware.NvidiaSmiAvailable = $true
        try {
            $smiOut = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
            if ($smiOut) {
                $hardware.NvidiaVRAM_GB = [math]::Round(([double]($smiOut.Trim())) / 1024, 2)
            }
        } catch { }
    }
} catch {
    Write-Log "Hardware diagnostic warning: $_" "WARN"
}

# 2. Ollama Environment Profiling
$ollamaProfile = [ordered]@{
    IsAvailable     = $false
    Version         = "Not Reachable"
    InstalledModels = @()
}

try {
    $verResp = Invoke-RestMethod -Uri "$OllamaUrl/api/version" -Method Get -TimeoutSec 5 -ErrorAction Stop
    if ($verResp -and $verResp.version) {
        $ollamaProfile.IsAvailable = $true
        $ollamaProfile.Version     = $verResp.version
    }
} catch {
    if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
        $verOut = ollama --version 2>&1 | Out-String
        if ($verOut -match '(\d+\.\d+\.\d+)') {
            $ollamaProfile.IsAvailable = $true
            $ollamaProfile.Version     = $Matches[1]
        }
    }
}

if ($ollamaProfile.IsAvailable) {
    try {
        $tagsResp = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method Get -TimeoutSec 5 -ErrorAction Stop
        if ($tagsResp -and $tagsResp.models) {
            foreach ($m in $tagsResp.models) {
                $sizeGB = [math]::Round($m.size / 1GB, 2)
                $ollamaProfile.InstalledModels += [ordered]@{
                    Name       = $m.name
                    Size_GB    = $sizeGB
                    SizeBytes  = $m.size
                    ModifiedAt = $m.modified_at
                    Family     = if ($m.details) { $m.details.family } else { "unknown" }
                    Quant      = if ($m.details) { $m.details.quantization_level } else { "unknown" }
                    Params     = if ($m.details) { $m.details.parameter_size } else { "unknown" }
                }
            }
        }
    } catch {
        if (Get-Command "ollama" -ErrorAction SilentlyContinue) {
            $cliList = ollama list 2>$null | Select-Object -Skip 1
            foreach ($line in $cliList) {
                $parts = $line -split '\s+'
                if ($parts.Count -ge 3) {
                    $ollamaProfile.InstalledModels += [ordered]@{
                        Name    = $parts[0]
                        Size_GB = 0.0
                        Family  = "unknown"
                    }
                }
            }
        }
    }
}

# 3. Model Ranking & Recommendation Engine
$recommendations = [ordered]@{
    FastestModel          = "None Installed"
    BestBalancedModel     = "None Installed"
    LargestPracticalModel = "None Installed"
    Ranking               = @()
}

if ($ollamaProfile.InstalledModels.Count -gt 0) {
    # Sort installed models by disk footprint / size
    $sortedModels = $ollamaProfile.InstalledModels | Sort-Object SizeBytes

    # Fastest Model: Smallest parameter/size footprint for lowest latency
    $recommendations.FastestModel = $sortedModels[0].Name

    # Effective Available VRAM / RAM Budget
    $usableMemoryGB = if ($hardware.NvidiaVRAM_GB -gt 0) { $hardware.NvidiaVRAM_GB } else { $hardware.TotalRAM_GB * 0.7 }

    # Largest Practical Model: Largest model that stays under 80% usable memory
    $practicalModels = $sortedModels | Where-Object { $_.Size_GB -eq 0.0 -or $_.Size_GB -le ($usableMemoryGB * 0.85) }
    if ($practicalModels.Count -gt 0) {
        $recommendations.LargestPracticalModel = ($practicalModels | Select-Object -Last 1).Name
    } else {
        $recommendations.LargestPracticalModel = $sortedModels[0].Name
    }

    # Best Balanced Model: Medium size model near optimal RAM/quality threshold
    $balancedCandidates = $sortedModels | Where-Object { $_.Size_GB -ge 2.0 -and $_.Size_GB -le ($usableMemoryGB * 0.6) }
    if ($balancedCandidates.Count -gt 0) {
        $recommendations.BestBalancedModel = ($balancedCandidates | Select-Object -First 1).Name
    } else {
        $recommendations.BestBalancedModel = $recommendations.FastestModel
    }

    foreach ($m in $sortedModels) {
        $rankTag = "Standard"
        if ($m.Name -eq $recommendations.FastestModel) { $rankTag = "Fastest / Low Latency" }
        elseif ($m.Name -eq $recommendations.BestBalancedModel) { $rankTag = "Best Balanced" }
        elseif ($m.Name -eq $recommendations.LargestPracticalModel) { $rankTag = "Largest Practical" }

        $recommendations.Ranking += [ordered]@{
            ModelName   = $m.Name
            Size_GB     = $m.Size_GB
            Family      = $m.Family
            Quant       = $m.Quant
            RecommendedRole = $rankTag
        }
    }
}

$profileReport = [ordered]@{
    Timestamp       = (Get-Date).ToString("o")
    Hardware        = $hardware
    Ollama          = $ollamaProfile
    Recommendations = $recommendations
}

if ($JsonOutput) {
    return ($profileReport | ConvertTo-Json -Depth 5)
}

# Render Terminal Output
Write-Log "Hardware Profile Summary:" "SUCCESS"
Write-Host "  CPU:           $($hardware.CPUName) ($($hardware.CPUCores) Cores / $($hardware.CPULogicalProcessors) Threads)" -ForegroundColor White
Write-Host "  System RAM:    $($hardware.TotalRAM_GB) GB (Available: $($hardware.FreeRAM_GB) GB)" -ForegroundColor White
if ($hardware.NvidiaSmiAvailable) {
    Write-Host "  NVIDIA VRAM:   $($hardware.NvidiaVRAM_GB) GB (via nvidia-smi)" -ForegroundColor Green
} else {
    Write-Host "  GPU Adapters:  $($hardware.GPUAdapters.Name -join '; ')" -ForegroundColor White
}

Write-Log "Ollama Environment:" "SUCCESS"
Write-Host "  Ollama Status: $(if ($ollamaProfile.IsAvailable) { 'Active (v' + $ollamaProfile.Version + ')' } else { 'Not Reachable' })" -ForegroundColor White
Write-Host "  Models Count:  $($ollamaProfile.InstalledModels.Count)" -ForegroundColor White

if ($ollamaProfile.InstalledModels.Count -gt 0) {
    Write-Log "Model Ranking & Recommendations:" "HEADER"
    Write-Host "  ⚡ Fastest Model:           $($recommendations.FastestModel)" -ForegroundColor Cyan
    Write-Host "  ⚖️ Best Balanced Model:     $($recommendations.BestBalancedModel)" -ForegroundColor Green
    Write-Host "  💪 Largest Practical Model: $($recommendations.LargestPracticalModel)" -ForegroundColor Yellow

    Write-Host "`nDetailed Model Roster:" -ForegroundColor Yellow
    $recommendations.Ranking | Format-Table ModelName, Size_GB, Family, Quant, RecommendedRole -AutoSize
}

return $profileReport
