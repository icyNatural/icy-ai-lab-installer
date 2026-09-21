#requires -Version 5.1
$repoRoot=Split-Path $PSScriptRoot -Parent
$scriptPath=Join-Path $repoRoot 'scripts\AI-Lab-ControlCenter.ps1'
$cmdPath=Join-Path $repoRoot 'AI-LAB.cmd'
. $scriptPath -LibraryMode

Describe 'AI Lab Control Center' {
 It 'parses and LibraryMode does not launch the interactive menu' {
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
  @($errors).Count|Should Be 0
  {& $scriptPath -LibraryMode}|Should Not Throw
 }
 It 'has the exact ordered seven-item main menu' {
  $menu=@(Get-ControlCenterMainMenu)
  $menu.Count|Should Be 7
  ($menu.Key-join ',')|Should Be '1,2,3,4,5,6,7'
  ($menu.Label-join '|')|Should Be 'Analyze my computer|Find my best AI models|Discover and install compatible models|Manage AI Lab services|View previous benchmark reports|Advanced tools|Exit'
 }
 It 'resolves installed scripts first and source scripts as fallback' {
  $base=Join-Path $TestDrive 'Root With Spaces (test)';$lab=Join-Path $base 'Installed';$source=Join-Path $base 'Source'
  New-Item (Join-Path $lab 'scripts') -ItemType Directory -Force|Out-Null;New-Item (Join-Path $source 'scripts') -ItemType Directory -Force|Out-Null
  Set-Content (Join-Path $source 'scripts\Profile-AI-Lab.ps1') '# source'
  $paths=Resolve-ControlCenterPaths $lab $source (Join-Path $source 'scripts')
  (Resolve-AILabScript $paths 'Profile-AI-Lab.ps1')|Should Be ([IO.Path]::GetFullPath((Join-Path $source 'scripts\Profile-AI-Lab.ps1')))
  Set-Content (Join-Path $lab 'scripts\Profile-AI-Lab.ps1') '# installed'
  (Resolve-AILabScript $paths 'Profile-AI-Lab.ps1')|Should Be ([IO.Path]::GetFullPath((Join-Path $lab 'scripts\Profile-AI-Lab.ps1')))
  (Resolve-AILabScript $paths 'Missing.ps1')|Should Be $null
 }
 It 'builds a safely separated child PowerShell process specification' {
  $file='C:\AI Lab (local)\scripts\Benchmark-AI-Lab.ps1';$root='C:\Users\Test User\AI Lab'
  $spec=New-AILabChildProcessSpec $file $root @{Quick=$true;GuidedSelection=$true;Model='tiny model:1b'}
  $spec.FilePath|Should Be 'powershell.exe'
  ($spec.ArgumentList -contains '-File')|Should Be $true;($spec.ArgumentList -contains $file)|Should Be $true;($spec.ArgumentList -contains $root)|Should Be $true
  ($spec.ArgumentList -contains '-Quick')|Should Be $true;($spec.ArgumentList -contains '-GuidedSelection')|Should Be $true
  $spec.CommandLine|Should Match ([regex]::Escape('"C:\AI Lab (local)\scripts\Benchmark-AI-Lab.ps1"'))
 }
 It 'delegates only to existing operational scripts in isolated child processes' {
  $source=Get-Content $scriptPath -Raw
  foreach($name in 'Profile-AI-Lab.ps1','Manage-Models.ps1','Benchmark-AI-Lab.ps1','Start-AI-Lab.ps1','Stop-AI-Lab.ps1','Update-AI-Lab.ps1','Backup-AI-Lab.ps1','Repair-AI-Lab.ps1'){$source|Should Match ([regex]::Escape($name))}
  $source|Should Match "FilePath='powershell.exe'"
  $source|Should Match 'AutoSelect=\$true'
  $source|Should Match 'GuidedSelection=\$true'
 }
 It 'maps the selected use case to a comparable benchmark task' {
  (Get-BenchmarkTaskForUseCase general)|Should Be 'Conversation'
  (Get-BenchmarkTaskForUseCase coding)|Should Be 'Coding'
  (Get-BenchmarkTaskForUseCase reasoning)|Should Be 'Reasoning'
  (Get-BenchmarkTaskForUseCase tools)|Should Be 'ToolUse'
  (Get-BenchmarkTaskForUseCase vision)|Should Be $null
 }
 It 'classifies completed partial postponed and actual-error benchmark outcomes' {
  $postponed=Join-Path $TestDrive 'postponed.json';@{Cancelled=$false;Runs=@();SkippedModels=@(@{Model='small';Reason='Only 0.5 GB RAM is available; this benchmark needs about 2.5 GB.'});Failures=@()}|ConvertTo-Json -Depth 5|Set-Content $postponed
  $partial=Join-Path $TestDrive 'partial.json';@{Cancelled=$false;Runs=@(@{Model='a'});SkippedModels=@(@{Model='b';Reason='low RAM'});Failures=@()}|ConvertTo-Json -Depth 5|Set-Content $partial
  $complete=Join-Path $TestDrive 'complete.json';@{Cancelled=$false;Runs=@(@{Model='a'});SkippedModels=@();Failures=@()}|ConvertTo-Json -Depth 5|Set-Content $complete
  $failedReportPath=Join-Path $TestDrive 'error.json';@{Cancelled=$false;Runs=@();SkippedModels=@();Failures=@(@{Error='binding failed'})}|ConvertTo-Json -Depth 5|Set-Content $failedReportPath
  (Get-BenchmarkOutcome 10 $postponed).Status|Should Be 'Postponed';(Get-BenchmarkOutcome 10 $postponed).Message|Should Match 'Only 0.5 GB RAM.*needs about 2.5 GB'
  (Get-BenchmarkOutcome 20 $partial).Status|Should Be 'Partial'
  (Get-BenchmarkOutcome 0 $complete).Status|Should Be 'Completed'
  (Get-BenchmarkOutcome 2 $failedReportPath).Status|Should Be 'Error';(Get-BenchmarkOutcome 2 $failedReportPath).Message|Should Match 'binding failed'
 }
 It 'suppresses raw benchmark exit-code messaging in favor of report-backed outcomes' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Match 'Invoke-AILabChildScript \$Paths ''Benchmark-AI-Lab\.ps1'' \$Parameters -SuppressExitMessage'
  $source|Should Match 'if\(\$code-ne 0-and-not\$SuppressExitMessage\)'
  $source|Should Match '\|Out-Host;\$code=\[int\]\$LASTEXITCODE'
 }
 It 'never invokes or references the installer from either launcher or control center' {
  ((Get-Content $scriptPath -Raw)+(Get-Content $cmdPath -Raw))|Should Not Match '(?i)Install-AI-Lab|START-HERE|reinstall'
 }
 It 'launcher quotes the control script and forwards arguments' {
  $cmd=Get-Content $cmdPath -Raw
  $cmd|Should Match '%~dp0scripts\\AI-Lab-ControlCenter\.ps1'
  $cmd|Should Match '-File\s+"%CONTROL%"'
  $cmd|Should Match '-LabRoot\s+"%~dp0"\s+%\*'
 }
 It 'keeps custom-root backups inside that LabRoot' {
  $source=Get-Content $scriptPath -Raw
  $source|Should Match 'BackupDir=\(Join-Path \$Paths\.LabRoot ''backups''\)'
 }
 It 'discovers and groups benchmark report formats newest first' {
  $logs=Join-Path $TestDrive 'logs';New-Item $logs -ItemType Directory|Out-Null
  Set-Content (Join-Path $logs 'benchmark_20250101.txt') 'old compact';Set-Content (Join-Path $logs 'benchmark_20250101.json') '{}'
  Set-Content (Join-Path $logs 'benchmark_20250102.txt') 'new compact';Set-Content (Join-Path $logs 'not-a-report.txt') 'ignore'
  Get-Item (Join-Path $logs 'benchmark_20250101.txt'),(Join-Path $logs 'benchmark_20250101.json')|ForEach-Object{$_.LastWriteTime=Get-Date '2025-01-01'}
  (Get-Item (Join-Path $logs 'benchmark_20250102.txt')).LastWriteTime=Get-Date '2025-01-02'
  $reports=@(Get-BenchmarkReports $TestDrive);$sets=@(Get-BenchmarkReportSets $TestDrive)
  $reports.Count|Should Be 3;$sets.Count|Should Be 2;$sets[0].Name|Should Be 'benchmark_20250102';$sets[1].Files.Count|Should Be 2
 }
 It 'prefers Markdown for viewing and compact text for sharing' {
  $logs=Join-Path $TestDrive 'logs';New-Item $logs -ItemType Directory -Force|Out-Null
  Set-Content (Join-Path $logs 'benchmark_1.md') '# readable';Set-Content (Join-Path $logs 'benchmark_1.txt') 'compact'
  $set=@(Get-BenchmarkReportSets $TestDrive)[0]
  $set.Preferred.Extension|Should Be '.md'
  @($set.Files|Where-Object Extension -eq '.txt').Count|Should Be 1
 }
 It 'creates a clipboard command spec from the compact share report without executing it' {
  $report=Join-Path $TestDrive 'benchmark_share.txt';Set-Content $report 'Model|Task|Cold/Warm'
  $spec=New-ShareClipboardCommandSpec $report
  $spec.Command|Should Be 'Set-Clipboard';$spec.Value|Should Match 'Model\|Task\|Cold/Warm';$spec.SourcePath|Should Be ([IO.Path]::GetFullPath($report))
  {New-ShareClipboardCommandSpec (Join-Path $TestDrive 'missing.txt')}|Should Throw
 }
}
