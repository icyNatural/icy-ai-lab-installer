[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE 'AI-Lab'),
    [string]$OllamaUrl = 'http://localhost:11434',
    [ValidateSet('general','coding','reasoning','vision','embedding','tools')]
    [string]$Task = 'general',
    [string]$CatalogPath,
    [string]$ModelPath,
    [string]$BenchmarkReportPath,
    [switch]$JsonOutput,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Adaptive-AI-Lab.psm1') -Force
if (-not $CatalogPath) {
    $CatalogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'model-catalog.json'
}
if (-not $ModelPath) {
    $ModelPath = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $env:USERPROFILE '.ollama\models' }
}
$benchmarkReport = $null
if ($BenchmarkReportPath) {
    if (-not (Test-Path -LiteralPath $BenchmarkReportPath -PathType Leaf)) { throw "Benchmark report not found: $BenchmarkReportPath" }
    $benchmarkReport = Get-Content -LiteralPath $BenchmarkReportPath -Raw | ConvertFrom-Json
}
$report = Get-AdaptiveAILabProfile -CatalogPath $CatalogPath -ModelPath $ModelPath -OllamaUrl $OllamaUrl -Task $Task -BenchmarkReport $benchmarkReport
$json = $report | ConvertTo-Json -Depth 12
if ($OutputPath) {
    $parent = Split-Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, (New-Object Text.UTF8Encoding($false)))
}
if ($JsonOutput) { return $json }
Write-Host 'AI Lab adaptive profile' -ForegroundColor Cyan
Write-Host ("CPU: {0} ({1} cores / {2} threads, {3})" -f $report.Hardware.CPU.Name.Value,$report.Hardware.CPU.Cores.Value,$report.Hardware.CPU.Threads.Value,$report.Hardware.CPU.Architecture.Value)
Write-Host ("RAM: {0} GB installed / {1} GB available" -f $report.Hardware.Memory.InstalledGB.Value,$report.Hardware.Memory.AvailableGB.Value)
Write-Host ("Compute mode: {0}; free model disk: {1} GB" -f $report.Hardware.GPU.Mode,$report.Hardware.Storage.FreeGB.Value)
Write-Host ("Ollama API: {0}; running models: {1}" -f $report.Ollama.ApiAvailable,@($report.Ollama.RunningModels).Count)
if ($report.Recommendations.Recommended) {
    $r=$report.Recommendations.Recommended
    Write-Host ("Recommended for {0}: {1} (compatible: {2}, estimated placement: {3})" -f $Task,$r.Tag,$r.Compatible,$r.Estimated.Placement) -ForegroundColor Green
    foreach ($warning in @($r.Warnings)) { Write-Warning $warning }
    if ($report.Recommendations.FallbackUsed) { Write-Warning 'No candidate passed every compatibility check; this is a provisional fallback only.' }
} else { Write-Warning "No catalog candidate exists for task '$Task'." }
if ($OutputPath) { Write-Host "JSON report written to $OutputPath" }
Write-Host "`nRecommendation portfolio:" -ForegroundColor Cyan
$report.RecommendationPortfolio | Format-Table Category,Model,Compatible,Provisional -AutoSize
return $report
