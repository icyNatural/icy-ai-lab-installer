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
  @((Get-BenchmarkHardware).PSObject.Properties.Name -contains 'MachineName')|Should Be $false
 }
 It 'binds one or multiple model names and exposes selection modes' {
  $command=Get-Command $scriptPath
  $command.Parameters.Model.ParameterType|Should Be ([string[]])
  foreach($name in 'AllModels','AutoSelect','GuidedSelection'){$command.Parameters.ContainsKey($name)|Should Be $true}
 }
 It 'validates installed names, excludes embeddings, and auto orders smaller models' {
  $installed=@([pscustomobject]@{name='large';size=20},[pscustomobject]@{name='embed';size=1},[pscustomobject]@{name='small';size=5})
  $show={param($n) if($n-eq 'embed'){[pscustomobject]@{capabilities=@('embedding')}}else{[pscustomobject]@{capabilities=@('completion')}}}
  $picked=@(Select-BenchmarkModels $installed @() -Auto -ShowModel $show)
  $picked.Count|Should Be 2;$picked[0].Name|Should Be 'small';$picked[1].Name|Should Be 'large'
  {Select-BenchmarkModels $installed @('missing') -ShowModel $show}|Should Throw
 }
 It 'caps automatic comparisons while preserving smallest-first order' {
  $installed=1..5|ForEach-Object{[pscustomobject]@{name="m$_";size=(10-$_)}}
  $picked=@(Select-BenchmarkModels $installed @() -Auto -ShowModel {param($n)[pscustomobject]@{capabilities=@('completion')}})
  $picked.Count|Should Be 3
  ($picked.Name-join ',')|Should Be 'm5,m4,m3'
 }
 It 'uses a conservative non-forcing resource gate' {
  (Test-ModelResourceGate 100 ([pscustomobject]@{AvailableRamBytes=124;AvailableStorageBytes=1000})).Allowed|Should Be $false
  (Test-ModelResourceGate 100 ([pscustomobject]@{AvailableRamBytes=125;AvailableStorageBytes=20MB})).Allowed|Should Be $true
  (Test-ModelResourceGate 100 ([pscustomobject]@{AvailableRamBytes=$null;AvailableStorageBytes=$null})).Allowed|Should Be $false
  (Test-ModelResourceGate 100 ([pscustomobject]@{AvailableRamBytes=$null;AvailableStorageBytes=$null})).Reason|Should Match 'could not be verified'
 }
 It 'emits the exact compact fields and falls back without losing fields' {
  $m=[pscustomobject]@{Model='m';Task='t';Temperature='Cold';TTFTSeconds=.1;LoadSeconds=.2;GenerationTokensPerSecond=3;Correct=$true}
  (Format-CompactResult $m 200)|Should Be 'm|t|Cold|0.1|0.2|3|True'
  $list=Format-CompactResult $m 10
  foreach($label in 'Model:','Task:','Cold/Warm:','TTFT:','Load:','Tokens/sec:','Correct:'){$list|Should Match ([regex]::Escape($label))}
 }
 It 'generates deterministic evidence and privacy-safe Markdown and text' {
  $runs=@([pscustomobject]@{Model='m';Task='Reasoning';Temperature='Cold';TTFTSeconds=2;GenerationTokensPerSecond=10;Correct=$true;SpilloverBytes=1},[pscustomobject]@{Model='m';Task='Reasoning';Temperature='Warm';TTFTSeconds=1;GenerationTokensPerSecond=12;Correct=$false;SpilloverBytes=0})
  $insights=@(Get-BenchmarkInsights $runs);($insights -join ' ')|Should Match 'Generation speed:';($insights -join ' ')|Should Match 'Responsiveness:';($insights -join ' ')|Should Match 'Correctness:'
  ($insights -join ' ')|Should Match 'within these measured rows only'
  ($insights -join ' ')|Should Match 'Task evidence:'
  $summary=@([pscustomobject]@{Model='m';Task='Reasoning';Temperature='Warm';AverageTTFTSeconds=1;AverageLoadSeconds=.2;AverageGenerationTokensPerSecond=12;CorrectRuns=1;Runs=2})
  $share=New-ShareReportContent $summary $insights '2025-01-01' @([pscustomobject]@{Model='skip';Reason='low RAM'}) @([pscustomobject]@{Model='fail';Stage='Warm';Error='C:\Users\Private\file token=abc'});$share.Markdown|Should Match '# Icy AI Lab Benchmark';$share.Text|Should Match 'Model\|Task\|Cold/Warm\|TTFT\|Load\|Tokens/sec\|Correct';$share.Markdown|Should Match 'Skipped: skip';$share.Markdown|Should Match 'Failed: fail';$share.Markdown|Should Not Match 'C:\\Users\\Private|token=abc'
  (Remove-PrivateText "x $env:USERPROFILE y $env:COMPUTERNAME")|Should Not Match ([regex]::Escape($env:USERPROFILE))
  (Remove-PrivateText 'error C:\Users\Someone\file.txt password=hunter2')|Should Not Match 'Someone|hunter2'
 }
 It 'is sequential, records failures, snapshots residency, and finalizes partial reports' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Not Match '(?i)Start-Job|ForEach-Object\s+-Parallel|Start-ThreadJob'
  $source|Should Match '\$initialNames=@\(Get-OllamaProcesses'
  $source|Should Match 'Failures=\$failures'
  $source|Should Match 'PipelineStoppedException'
  $source|Should Match 'Postponed to protect initially resident model'
  $source|Should Match 'finally\s*\{'
  $source|Should Match 'Write-Progress'
 }
 It 'keeps quick mode comparable across every selected model' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Not Match 'if\(\$Quick-and !\$Model\.Count-and \$selected\.Count-gt 1\)'
  $source|Should Match 'AutoSelectCount=3'
 }
}
