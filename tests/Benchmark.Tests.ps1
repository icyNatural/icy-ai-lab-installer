$repoRoot=Split-Path $PSScriptRoot -Parent
$scriptPath=Join-Path $repoRoot 'scripts\Benchmark-AI-Lab.ps1'
. $scriptPath -LibraryMode

Describe 'Benchmark AI Lab unit and static behavior' {
 It 'parses under Windows PowerShell without syntax errors' {
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
  @($errors).Count|Should Be 0
 }
 It 'retains legacy parameters and exposes safe controls' {
  $command=Get-Command $scriptPath
  foreach($name in 'LabRoot','Model','Prompt','Warmup','Runs','OllamaUrl','JsonOutput','Quick','ContextLength','Tasks'){$command.Parameters.ContainsKey($name)|Should Be $true}
 }
 It 'converts official nanosecond metrics without inventing absent values' {
  (Convert-NanosecondsToSeconds 2500000000)|Should Be 2.5
  (Get-Rate 20 2000000000)|Should Be 10
  (Get-Rate $null $null)|Should Be $null
  (Get-NullableAverage @([pscustomobject]@{Value=$null}) Value)|Should Be $null
 }
 It 'defines all repeatable task categories' {
  foreach($name in 'Conversation','Summarization','Coding','Extraction','Reasoning','ToolUse'){(New-TaskDefinition $name 'x').Name|Should Be $name}
 }
 It 'checks correctness independently from timing' {
  $task=New-TaskDefinition Reasoning ''
  (Test-TaskResponse 'Work omitted. ANSWER: 5' $task).Passed|Should Be $true
  (Test-TaskResponse 'ANSWER: 4' $task).Passed|Should Be $false
  $extract=New-TaskDefinition Extraction ''
  (Test-TaskResponse '{"name":"Ada Lovelace","age":36}' $extract).Passed|Should Be $true
 }
 It 'classifies completion capability and excludes embedding-only capability' {
  (Test-CompletionModel ([pscustomobject]@{capabilities=@('completion')}))|Should Be $true
  (Test-CompletionModel ([pscustomobject]@{capabilities=@('embedding')}))|Should Be $false
 }
 It 'contains official unload and residency semantics and no destructive model command' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Match 'keep_alive=0'
  $source|Should Match '/api/ps'
  $source|Should Match '/api/chat'
  $source|Should Match 'tool_calls'
  $source|Should Match 'size_vram'
  $source|Should Not Match '(?i)ollama\s+(rm|remove|delete)'
 }
 It 'returns unavailable NVIDIA markers when nvidia-smi is absent' {
  Mock Get-Command { $null } -ParameterFilter {$Name -eq 'nvidia-smi'}
  $sample=Get-NvidiaSample
  $sample.Available|Should Be $false
  $sample.Reason|Should Not BeNullOrEmpty
 }
 It 'maps response metrics and computes spillover fields per run' {
  $final=[pscustomobject]@{load_duration=1e9;prompt_eval_duration=2e9;eval_duration=4e9;total_duration=7e9;prompt_eval_count=20;eval_count=40}
  $stream=[pscustomobject]@{Final=$final;TTFTSeconds=.2;WallSeconds=7;Text='ok'}
  $sys=[pscustomobject]@{RamUsedMB=100;CpuPercent=10};$gpu=[pscustomobject]@{Available=$false;Reason='unavailable';PowerWatts=$null;UtilizationPercent=$null}
  $res=[pscustomobject]@{Resident=$true;SizeBytes=1000;SizeVramBytes=600;SpilloverBytes=400};$check=[pscustomobject]@{Passed=$true;Reason='Passed'}
  $run=Convert-RunMetric $stream model task 2048 1 Cold $sys $sys $gpu $gpu $res $check
  $run.LoadSeconds|Should Be 1;$run.PromptTokensPerSecond|Should Be 10;$run.GenerationTokensPerSecond|Should Be 10;$run.SpilloverBytes|Should Be 400
 }
 It 'adds benchmark schema and hardware provenance' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Match "SchemaVersion='1.0'"
  $source|Should Match "ReportType='IcyAILabBenchmark'"
  $source|Should Match 'Hardware=Get-BenchmarkHardware'
 }
}
