[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [string]$Model = "",
    [string]$Prompt = "Explain quantum computing in 3 concise sentences.",
    [int]$Warmup = 1,
    [int]$Runs = 3,
    [string]$OllamaUrl = "http://localhost:11434",
    [switch]$JsonOutput
)

$ErrorActionPreference = "Stop"
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

Write-Log "Icy AI Lab Model Benchmark Utility" "HEADER"

# Check Ollama Server Readiness
try {
    $ver = Invoke-RestMethod -Uri "$OllamaUrl/api/version" -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Log "Ollama Server is responsive (v$($ver.version))." "SUCCESS"
}
catch {
    Write-Log "Ollama Server is not reachable at '$OllamaUrl'. Please start Ollama first." "ERROR"
    exit 1
}

# Resolve Models to Benchmark
$modelsToTest = @()
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $modelsToTest += $Model
} else {
    try {
        $tagsResp = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method Get -TimeoutSec 5
        if ($tagsResp -and $tagsResp.models) {
            $modelsToTest = $tagsResp.models.name
        }
    } catch { }

    if ($modelsToTest.Count -eq 0 -and (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
        $modelsToTest = ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ }
    }
}

if ($modelsToTest.Count -eq 0) {
    Write-Log "No Ollama models found to benchmark." "ERROR"
    exit 1
}

Write-Log "Models targeted for benchmark: $($modelsToTest -join ', ')" "SUCCESS"

$benchmarkResults = @()

foreach ($m in $modelsToTest) {
    Write-Log "Benchmarking model '$m' ($Runs runs, $Warmup warmup)..." "HEADER"

    # Warmup runs
    for ($w = 1; $w -le $Warmup; $w++) {
        Write-Log "Executing Warmup Run $w/$Warmup..."
        try {
            $body = @{ model = $m; prompt = $Prompt; stream = $false } | ConvertTo-Json
            Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 120 | Out-Null
        } catch {
            Write-Log "Warmup run failed for '$m': $_" "WARN"
        }
    }

    $modelRunStats = @()
    for ($r = 1; $r -le $Runs; $r++) {
        Write-Log "Executing Measured Benchmark Run $r/$Runs..."

        # Sample Initial RAM & GPU Memory
        $osBefore = Get-CimInstance Win32_OperatingSystem
        $ramUsedBefore_MB = [math]::Round(($osBefore.TotalVisibleMemorySize - $osBefore.FreePhysicalMemory) / 1024, 2)

        $gpuVramBefore_MB = 0.0
        if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
            try {
                $smiOut = nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
                if ($smiOut) { $gpuVramBefore_MB = [double]($smiOut.Trim()) }
            } catch { }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $apiResp = $null
        try {
            $body = @{ model = $m; prompt = $Prompt; stream = $false } | ConvertTo-Json
            $apiResp = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 180
        } catch {
            Write-Log "Run $r failed for model '$m': $_" "WARN"
            continue
        }
        $sw.Stop()

        # Sample Peak RAM & GPU Memory after run
        $osAfter = Get-CimInstance Win32_OperatingSystem
        $ramUsedAfter_MB = [math]::Round(($osAfter.TotalVisibleMemorySize - $osAfter.FreePhysicalMemory) / 1024, 2)

        $gpuVramAfter_MB = 0.0
        if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
            try {
                $smiOut = nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
                if ($smiOut) { $gpuVramAfter_MB = [double]($smiOut.Trim()) }
            } catch { }
        }

        if ($apiResp) {
            # Extract microsecond timing metrics from Ollama API
            $loadTime_sec   = if ($apiResp.load_duration) { [math]::Round($apiResp.load_duration / 1e9, 3) } else { 0.0 }
            $totalTime_sec  = if ($apiResp.total_duration) { [math]::Round($apiResp.total_duration / 1e9, 3) } else { [math]::Round($sw.Elapsed.TotalSeconds, 3) }
            
            $promptTokens = if ($apiResp.prompt_eval_count) { [int]$apiResp.prompt_eval_count } else { 0 }
            $promptDuration_sec = if ($apiResp.prompt_eval_duration -and $apiResp.prompt_eval_duration -gt 0) { $apiResp.prompt_eval_duration / 1e9 } else { 0.0 }
            $promptTokPerSec = if ($promptDuration_sec -gt 0) { [math]::Round($promptTokens / $promptDuration_sec, 2) } else { 0.0 }

            $evalTokens = if ($apiResp.eval_count) { [int]$apiResp.eval_count } else { 0 }
            $evalDuration_sec = if ($apiResp.eval_duration -and $apiResp.eval_duration -gt 0) { $apiResp.eval_duration / 1e9 } else { 0.0 }
            $sustainedTokPerSec = if ($evalDuration_sec -gt 0) { [math]::Round($evalTokens / $evalDuration_sec, 2) } else { 0.0 }

            $modelRunStats += [ordered]@{
                Run                 = $r
                LoadTime_sec        = $loadTime_sec
                TotalTime_sec       = $totalTime_sec
                PromptTokens        = $promptTokens
                PromptTokensPerSec  = $promptTokPerSec
                EvalTokens          = $evalTokens
                SustainedTokensPerSec = $sustainedTokPerSec
                RAMDelta_MB         = [math]::Round($ramUsedAfter_MB - $ramUsedBefore_MB, 2)
                GPUVRAMDelta_MB     = [math]::Round($gpuVramAfter_MB - $gpuVramBefore_MB, 2)
            }
        }
    }

    if ($modelRunStats.Count -gt 0) {
        $avgLoadTime   = [math]::Round(($modelRunStats.LoadTime_sec | Measure-Object -Average).Average, 3)
        $avgSustained  = [math]::Round(($modelRunStats.SustainedTokensPerSec | Measure-Object -Average).Average, 2)
        $avgPromptTok  = [math]::Round(($modelRunStats.PromptTokensPerSec | Measure-Object -Average).Average, 2)
        $avgTotalTime  = [math]::Round(($modelRunStats.TotalTime_sec | Measure-Object -Average).Average, 3)

        $modelSummary = [ordered]@{
            Model                 = $m
            AvgLoadTime_sec       = $avgLoadTime
            AvgSustainedTokensPerSec = $avgSustained
            AvgPromptTokensPerSec = $avgPromptTok
            AvgTotalTime_sec      = $avgTotalTime
            SuccessfulRuns        = $modelRunStats.Count
            RunDetails            = $modelRunStats
        }
        $benchmarkResults += $modelSummary
    }
}

# Ensure Logs Directory Exists & Export Reports
$logDir = Join-Path $LabRoot "logs"
if (-not (Test-Path -Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonReportPath = Join-Path $logDir "benchmark_$timestamp.json"
$csvReportPath  = Join-Path $logDir "benchmark_$timestamp.csv"

$finalReport = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    Prompt    = $Prompt
    Runs      = $Runs
    Warmup    = $Warmup
    Results   = $benchmarkResults
}

$jsonContent = $finalReport | ConvertTo-Json -Depth 6
Set-Content -Path $jsonReportPath -Value $jsonContent -Encoding UTF8 -Force

# Generate CSV Export
$flatResults = $benchmarkResults | Select-Object Model, AvgLoadTime_sec, AvgSustainedTokensPerSec, AvgPromptTokensPerSec, AvgTotalTime_sec, SuccessfulRuns
$flatResults | Export-Csv -Path $csvReportPath -NoTypeInformation -Encoding UTF8 -Force

if ($JsonOutput) {
    return $jsonContent
}

Write-Log "Benchmark Summary Results:" "HEADER"
$flatResults | Format-Table -AutoSize

Write-Log "Benchmark JSON Report: $jsonReportPath" "SUCCESS"
Write-Log "Benchmark CSV Export:  $csvReportPath" "SUCCESS"

return $finalReport
