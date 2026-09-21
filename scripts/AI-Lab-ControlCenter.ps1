#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE 'AI-Lab'),
    [string]$SourceRoot,
    [switch]$LibraryMode
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ControlCenterMainMenu {
    @(
        [pscustomobject]@{ Key='1'; Label='Analyze my computer' }
        [pscustomobject]@{ Key='2'; Label='Find my best AI models' }
        [pscustomobject]@{ Key='3'; Label='Discover and install compatible models' }
        [pscustomobject]@{ Key='4'; Label='Manage AI Lab services' }
        [pscustomobject]@{ Key='5'; Label='View previous benchmark reports' }
        [pscustomobject]@{ Key='6'; Label='Advanced tools' }
        [pscustomobject]@{ Key='7'; Label='Exit' }
    )
}

function Resolve-ControlCenterPaths {
    [CmdletBinding()]
    param([string]$RequestedLabRoot,[string]$RequestedSourceRoot,[string]$ControlScriptRoot)
    if ([string]::IsNullOrWhiteSpace($RequestedLabRoot)) { $RequestedLabRoot=Join-Path $env:USERPROFILE 'AI-Lab' }
    if ([string]::IsNullOrWhiteSpace($ControlScriptRoot)) { $ControlScriptRoot=$PSScriptRoot }
    if ([string]::IsNullOrWhiteSpace($RequestedSourceRoot)) { $RequestedSourceRoot=Split-Path -Parent $ControlScriptRoot }
    $lab=[IO.Path]::GetFullPath($RequestedLabRoot);$source=[IO.Path]::GetFullPath($RequestedSourceRoot)
    [pscustomobject]@{LabRoot=$lab;SourceRoot=$source;ScriptRoots=@((Join-Path $lab 'scripts'),(Join-Path $source 'scripts'))|Select-Object -Unique}
}

function Resolve-AILabScript {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$Name)
    if($Name -notmatch '^[A-Za-z0-9-]+\.ps1$'){throw "Unsafe script name: $Name"}
    foreach($root in @($Paths.ScriptRoots)){$candidate=Join-Path $root $Name;if(Test-Path -LiteralPath $candidate -PathType Leaf){return [IO.Path]::GetFullPath($candidate)}}
    $null
}

function ConvertTo-DisplayArgument {param([AllowEmptyString()][string]$Value);'"'+($Value-replace '"','\"')+'"'}
function New-AILabChildProcessSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ScriptPath,[Parameter(Mandatory=$true)][string]$LabRoot,[hashtable]$Parameters=@{})
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-LabRoot',$LabRoot)
    foreach($name in @($Parameters.Keys|Sort-Object)){
        $value=$Parameters[$name]
        if($value -is [Management.Automation.SwitchParameter] -or $value -is [bool]){if([bool]$value){$arguments+="-$name"}}
        elseif($null-ne$value){$arguments+="-$name";if($value-is[array]){$arguments+=@($value|ForEach-Object{[string]$_})}else{$arguments+=[string]$value}}
    }
    [pscustomobject]@{FilePath='powershell.exe';ArgumentList=$arguments;CommandLine='powershell.exe '+(($arguments|ForEach-Object{ConvertTo-DisplayArgument ([string]$_)})-join ' ');ScriptPath=$ScriptPath}
}

function Get-BenchmarkReports {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$LabRoot)
    $logRoot=Join-Path $LabRoot 'logs';if(-not(Test-Path -LiteralPath $logRoot -PathType Container)){return @()}
    @(Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-match'^benchmark_.+\.(json|md|txt|csv)$'}|Sort-Object LastWriteTime -Descending)
}
function Get-BenchmarkReportSets {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$LabRoot)
    $files=@(Get-BenchmarkReports $LabRoot)
    @($files|Group-Object{$_.BaseName-replace'-runs$',''}|ForEach-Object{$preferred=@($_.Group|Where-Object Extension -eq '.md'|Select-Object -First 1);if(-not$preferred){$preferred=@($_.Group|Where-Object Extension -eq '.txt'|Select-Object -First 1)};if(-not$preferred){$preferred=@($_.Group|Select-Object -First 1)};[pscustomobject]@{Name=$_.Name;LastWriteTime=($_.Group|Sort-Object LastWriteTime -Descending|Select-Object -First 1).LastWriteTime;Files=@($_.Group);Preferred=$preferred[0]}}|Sort-Object LastWriteTime -Descending)
}
function New-ShareClipboardCommandSpec {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ReportPath)
    if(-not(Test-Path -LiteralPath $ReportPath -PathType Leaf)){throw "Report not found: $ReportPath"}
    [pscustomobject]@{Command='Set-Clipboard';Value=(Get-Content -LiteralPath $ReportPath -Raw);SourcePath=[IO.Path]::GetFullPath($ReportPath)}
}
function Get-LatestBenchmarkJson {
    param([string]$LabRoot,[datetime]$Since=[datetime]::MinValue)
    $logs=Join-Path $LabRoot 'logs';if(-not(Test-Path -LiteralPath $logs)){return $null}
    @(Get-ChildItem -LiteralPath $logs -Filter 'benchmark_*.json' -File -ErrorAction SilentlyContinue|Where-Object{$_.LastWriteTime-ge$Since}|Sort-Object LastWriteTime -Descending|Select-Object -First 1)
}
function Get-BenchmarkOutcome {
    [CmdletBinding()]param([int]$ExitCode,[string]$ReportPath)
    $report=$null;if($ReportPath-and(Test-Path -LiteralPath $ReportPath -PathType Leaf)){try{$report=Get-Content -LiteralPath $ReportPath -Raw|ConvertFrom-Json}catch{}}
    if($null-eq$report){return [pscustomobject]@{Status='Error';Message="The comparison stopped unexpectedly (exit code $ExitCode) and no readable diagnostic report was produced.";ReportPath=$ReportPath}}
    $runs=@($report.Runs).Count;$skipped=@($report.SkippedModels);$failures=@($report.Failures)
    if([bool]$report.Cancelled-or$ExitCode-eq130){$status='Cancelled';$message="The comparison was cancelled after $runs measured run(s). Partial results were saved."}
    elseif($runs-gt0-and($failures.Count-or$skipped.Count-or$ExitCode-eq20)){$status='Partial';$message="The comparison completed partially: $runs measured run(s), $($skipped.Count) safely postponed model(s), and $($failures.Count) error(s)."}
    elseif($runs-gt0){$status='Completed';$message="The comparison completed with $runs measured run(s)."}
    elseif($skipped.Count-gt0-and$failures.Count-eq0){$status='Postponed';$details=@($skipped|ForEach-Object{"$($_.Model): $($_.Reason)"})-join ' ';$message="No model was loaded. The comparison was safely postponed. $details"}
    else{$status='Error';$detail=if($failures.Count){$failures[0].Error}else{"Exit code $ExitCode"};$message="The comparison could not run because of an unexpected error: $detail"}
    [pscustomobject]@{Status=$status;Message=$message;ReportPath=$ReportPath;Runs=$runs;Skipped=$skipped.Count;Failures=$failures.Count}
}
function Invoke-AILabBenchmark {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Paths,[hashtable]$Parameters=@{})
    $started=Get-Date;$code=Invoke-AILabChildScript $Paths 'Benchmark-AI-Lab.ps1' $Parameters -SuppressExitMessage;$latest=@(Get-LatestBenchmarkJson $Paths.LabRoot $started|Select-Object -First 1);$path=if($latest.Count){$latest[0].FullName}else{$null};$outcome=Get-BenchmarkOutcome $code $path
    $color=switch($outcome.Status){'Completed'{'Green'}'Partial'{'Yellow'}'Postponed'{'Yellow'}'Cancelled'{'Yellow'}default{'Red'}}
    Write-Host "`n$($outcome.Message)" -ForegroundColor $color
    if($outcome.ReportPath){Write-Host "Diagnostic report: $($outcome.ReportPath)" -ForegroundColor DarkGray}
    return $outcome
}

function Write-Menu {param([string]$Title,[object[]]$Items);Clear-Host;Write-Host ('='*62)-ForegroundColor DarkCyan;Write-Host "  $Title" -ForegroundColor Cyan;Write-Host ('='*62)-ForegroundColor DarkCyan;foreach($item in $Items){Write-Host("  {0}. {1}"-f$item.Key,$item.Label)};Write-Host}
function Pause-ControlCenter {[void](Read-Host 'Press Enter to continue')}
function Invoke-AILabChildScript {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$Name,[hashtable]$Parameters=@{},[switch]$SuppressExitMessage)
    $scriptPath=Resolve-AILabScript $Paths $Name
    if(-not$scriptPath){Write-Host "This tool is unavailable because '$Name' could not be found." -ForegroundColor Yellow;Write-Host("Looked in: {0}"-f(@($Paths.ScriptRoots)-join'; '))-ForegroundColor DarkGray;return 127}
    $spec=New-AILabChildProcessSpec $scriptPath $Paths.LabRoot $Parameters
    Write-Host "`nStarting $Name in an isolated PowerShell process..." -ForegroundColor Cyan
    &$spec.FilePath @($spec.ArgumentList)|Out-Host;$code=[int]$LASTEXITCODE
    if($code-ne 0-and-not$SuppressExitMessage){Write-Host "$Name exited with code $code." -ForegroundColor Yellow};$code
}

function Read-TaskChoice {
    Write-Host '  1. General chat';Write-Host '  2. Coding';Write-Host '  3. Reasoning';Write-Host '  4. Vision';Write-Host '  5. Automation and tools'
    switch(Read-Host 'What will you use the model for? [1]'){'2'{'coding'}'3'{'reasoning'}'4'{'vision'}'5'{'tools'}default{'general'}}
}
function Get-BenchmarkTaskForUseCase {
    param([ValidateSet('general','coding','reasoning','vision','tools')][string]$Task)
    switch($Task){'coding'{'Coding'}'reasoning'{'Reasoning'}'tools'{'ToolUse'}'vision'{$null}default{'Conversation'}}
}

function Invoke-AnalyzeFlow {
 param($Paths);[void](Invoke-AILabChildScript $Paths 'Profile-AI-Lab.ps1')
 Write-Host "`nWould you also like to test installed model performance?" -ForegroundColor Cyan
 Write-Host '  1. Quick guided test (recommended for beginners)';Write-Host '  2. Comprehensive guided test';Write-Host '  3. Not now'
  switch(Read-Host 'Choose [3]'){'1'{[void](Invoke-AILabBenchmark $Paths @{Quick=$true;GuidedSelection=$true})}'2'{[void](Invoke-AILabBenchmark $Paths @{GuidedSelection=$true})}}
}
function Invoke-FindBestFlow {
 param($Paths);$task=Read-TaskChoice
 [void](Invoke-AILabChildScript $Paths 'Profile-AI-Lab.ps1' @{Task=$task})
 [void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='recommend';PackOrModel=$task})
 Write-Host "`nCompare small, suitable installed completion models now?" -ForegroundColor Cyan
 Write-Host 'This uses only models already installed and downloads nothing.' -ForegroundColor DarkGray
 if((Read-Host 'Run the automatic comparison? [Y/n]')-notmatch'^(n|no)$'){
   $benchmarkTask=Get-BenchmarkTaskForUseCase $task
   if($null-eq$benchmarkTask){Write-Host 'Automated vision comparison is not available yet because the repeatable suite has no image fixture. The recommendation above remains provisional.' -ForegroundColor Yellow}
   else{[void](Invoke-AILabBenchmark $Paths @{AutoSelect=$true;Runs=1;Warmup=0;Tasks=@($benchmarkTask);ContextLength=@(2048)})}
 }
}
function Invoke-DiscoveryFlow {
 param($Paths)
 [void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='catalog'});[void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='assess'})
 $task=Read-TaskChoice;[void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='recommend';PackOrModel=$task})
 Write-Host "`nNothing has been downloaded." -ForegroundColor Yellow
 $tag=Read-Host 'Enter an exact recommended model tag to install, or press Enter to cancel';if([string]::IsNullOrWhiteSpace($tag)){return}
 if((Read-Host "Type INSTALL to approve downloading '$tag'")-ceq'INSTALL'){[void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='pull';PackOrModel=$tag})}else{Write-Host 'Cancelled; no model was downloaded.' -ForegroundColor Yellow}
}
function Show-ServiceMenu {
 param($Paths)
 do{
  $items=@([pscustomobject]@{Key='1';Label='Start services'},[pscustomobject]@{Key='2';Label='Stop services'},[pscustomobject]@{Key='3';Label='Update services and installed tools'},[pscustomobject]@{Key='4';Label='Back'});Write-Menu 'Manage AI Lab services' $items
  switch(Read-Host 'Choose'){
   '1'{[void](Invoke-AILabChildScript $Paths 'Start-AI-Lab.ps1');Pause-ControlCenter}
   '2'{[void](Invoke-AILabChildScript $Paths 'Stop-AI-Lab.ps1');Pause-ControlCenter}
   '3'{if((Read-Host 'Updates can take time. Continue? [y/N]')-match'^(y|yes)$'){[void](Invoke-AILabChildScript $Paths 'Update-AI-Lab.ps1')};Pause-ControlCenter}
   '4'{return}
  }
 }while($true)
}


function Show-ReportMenu {
 param($Paths);$sets=@(Get-BenchmarkReportSets $Paths.LabRoot)
 if(-not$sets.Count){Write-Host "No benchmark reports were found in '$(Join-Path $Paths.LabRoot 'logs')'." -ForegroundColor Yellow;Pause-ControlCenter;return}
 Write-Host "`nPrevious benchmark reports:" -ForegroundColor Cyan
 for($i=0;$i-lt$sets.Count;$i++){Write-Host("  {0}. {1} ({2})"-f($i+1),$sets[$i].Name,$sets[$i].LastWriteTime)}
 Write-Host '  F. Open report folder';Write-Host '  B. Back';$choice=Read-Host 'Choose a report'
 if($choice-match'^[Ff]$'){Start-Process -FilePath explorer.exe -ArgumentList @((Join-Path $Paths.LabRoot 'logs'));return};if($choice-match'^[Bb]$'){return}
 $number=0;if(-not[int]::TryParse($choice,[ref]$number)-or$number-lt 1-or$number-gt$sets.Count){Write-Host 'Invalid selection.' -ForegroundColor Yellow;Pause-ControlCenter;return}
 $set=$sets[$number-1];Write-Host '  1. Open report';Write-Host '  2. Copy compact share summary to clipboard';Write-Host '  3. Cancel'
 switch(Read-Host 'Choose'){
  '1'{Start-Process -FilePath $set.Preferred.FullName}
  '2'{$text=@($set.Files|Where-Object Extension -eq '.txt'|Select-Object -First 1);if(-not$text){Write-Host 'This report has no compact share summary (.txt).' -ForegroundColor Yellow}else{$spec=New-ShareClipboardCommandSpec $text[0].FullName;&$spec.Command -Value $spec.Value;Write-Host 'Compact share summary copied to clipboard.' -ForegroundColor Green}}
 };Pause-ControlCenter
}
function Show-AdvancedMenu {
 param($Paths)
 do{
  $items=@([pscustomobject]@{Key='1';Label='Benchmark installed models - quick guided'},[pscustomobject]@{Key='2';Label='Benchmark installed models - comprehensive guided'},[pscustomobject]@{Key='3';Label='List installed models'},[pscustomobject]@{Key='4';Label='Back up AI Lab data'},[pscustomobject]@{Key='5';Label='Run non-destructive repair'},[pscustomobject]@{Key='6';Label='Back'});Write-Menu 'Advanced tools' $items
  switch(Read-Host 'Choose'){
   '1'{[void](Invoke-AILabBenchmark $Paths @{Quick=$true;GuidedSelection=$true});Pause-ControlCenter}
   '2'{[void](Invoke-AILabBenchmark $Paths @{GuidedSelection=$true});Pause-ControlCenter}
   '3'{[void](Invoke-AILabChildScript $Paths 'Manage-Models.ps1' @{Action='list'});Pause-ControlCenter}
   '4'{[void](Invoke-AILabChildScript $Paths 'Backup-AI-Lab.ps1' @{BackupDir=(Join-Path $Paths.LabRoot 'backups')});Pause-ControlCenter}
   '5'{[void](Invoke-AILabChildScript $Paths 'Repair-AI-Lab.ps1');Pause-ControlCenter}
   '6'{return}
  }
 }while($true)
}

if($LibraryMode){return}
$paths=Resolve-ControlCenterPaths $LabRoot $SourceRoot $PSScriptRoot;$exit=$false
do{
 Write-Menu 'Icy AI Lab Control Center' (Get-ControlCenterMainMenu)
 switch(Read-Host 'Choose 1-7'){
  '1'{Invoke-AnalyzeFlow $paths;Pause-ControlCenter}
  '2'{Invoke-FindBestFlow $paths;Pause-ControlCenter}
  '3'{Invoke-DiscoveryFlow $paths;Pause-ControlCenter}
  '4'{Show-ServiceMenu $paths}
  '5'{Show-ReportMenu $paths}
  '6'{Show-AdvancedMenu $paths}
  '7'{$exit=$true}
  default{Write-Host 'Please choose a number from 1 to 7.' -ForegroundColor Yellow;Pause-ControlCenter}
 }
}until($exit)
