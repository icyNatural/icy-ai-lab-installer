[CmdletBinding()]
param(
 [string]$LabRoot=(Join-Path $env:USERPROFILE 'AI-Lab'),[string[]]$Model=@(),
 [string]$Prompt='Explain quantum computing in 3 concise sentences.',
 [ValidateRange(0,100)][int]$Warmup=1,[ValidateRange(1,100)][int]$Runs=3,
 [string]$OllamaUrl='http://localhost:11434',[switch]$JsonOutput,
 [ValidateSet('Conversation','Summarization','Coding','Extraction','Reasoning','ToolUse','Custom')][string[]]$Tasks=@('Conversation','Summarization','Coding','Extraction','Reasoning','ToolUse'),
 [ValidateRange(128,1048576)][int[]]$ContextLength=@(2048),
 [ValidateRange(1,3600)][int]$TimeoutSec=300,[ValidateRange(1,3600)][int]$KeepAliveSec=300,
 [switch]$Quick,[switch]$AllModels,[switch]$AutoSelect,[switch]$GuidedSelection,
 [ValidateRange(1,20)][int]$AutoSelectCount=3,
 [switch]$PassThru,[switch]$LibraryMode
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest

function Get-PropertyValue { param($Object,[string]$Name,$Default=$null); if($null-ne $Object-and $null-ne $Object.PSObject.Properties[$Name]){return $Object.$Name};$Default }
function Convert-NanosecondsToSeconds { param($Value);if($null-eq $Value){return $null};[math]::Round(([double]$Value/1e9),6) }
function Get-Rate { param($Count,$DurationNanoseconds);if($null-eq $Count-or $null-eq $DurationNanoseconds-or [double]$DurationNanoseconds-le 0){return $null};[math]::Round(([double]$Count/([double]$DurationNanoseconds/1e9)),2) }
function Get-NullableAverage {param([object[]]$Items,[string]$Property,[int]$Digits=6);$values=@($Items|ForEach-Object{$v=Get-PropertyValue $_ $Property;if($null-ne $v){[double]$v}});if(!$values){return $null};[math]::Round(($values|Measure-Object -Average).Average,$Digits)}

function New-TaskDefinition {
 param([string]$Name,[string]$CustomPrompt)
 switch($Name){
  'Conversation'{[pscustomobject]@{Name=$Name;Prompt='Remember the code word BLUE. Reply with exactly: I remember BLUE.';Kind='Contains';Expected='BLUE';Format=$null}}
  'Summarization'{[pscustomobject]@{Name=$Name;Prompt='Summarize in one short sentence: The solar array produced power during daylight. Batteries stored excess and supplied power after sunset.';Kind='ContainsAll';Expected=@('solar','batter');Format=$null}}
  'Coding'{[pscustomobject]@{Name=$Name;Prompt='Write a PowerShell function named Add-Numbers that accepts two parameters and returns their sum. Output code only.';Kind='ContainsAll';Expected=@('function','Add-Numbers');Format=$null}}
  'Extraction'{[pscustomobject]@{Name=$Name;Prompt='Return only JSON with keys name and age from: Ada Lovelace is 36 years old.';Kind='JsonFields';Expected=@{name='Ada Lovelace';age=36};Format='json'}}
  'Reasoning'{[pscustomobject]@{Name=$Name;Prompt='A box has 3 red and 2 blue balls. How many balls are there? End with ANSWER: 5.';Kind='Contains';Expected='ANSWER: 5';Format=$null}}
  'ToolUse'{[pscustomobject]@{Name=$Name;Prompt='What is the weather in Paris? Use the available tool.';Kind='ContainsAll';Expected=@('get_weather','Paris');Format=$null;Tools=@(@{type='function';function=@{name='get_weather';description='Get weather for a city';parameters=@{type='object';required=@('city');properties=@{city=@{type='string';description='City name'}}}}})}}
  default{[pscustomobject]@{Name='Custom';Prompt=$CustomPrompt;Kind='NonEmpty';Expected=$null;Format=$null}}
 }
}
function Test-TaskResponse {
 param([string]$Text,$Task);if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]@{Passed=$false;Reason='Empty response'}}
 $ok=$true
 switch($Task.Kind){
  'Contains'{$ok=$Text.IndexOf([string]$Task.Expected,[StringComparison]::OrdinalIgnoreCase)-ge 0}
  'ContainsAll'{foreach($word in $Task.Expected){if($Text.IndexOf([string]$word,[StringComparison]::OrdinalIgnoreCase)-lt 0){$ok=$false}}}
  'JsonFields'{$ok=$false;try{$value=$Text.Trim()|ConvertFrom-Json;$ok=$true;foreach($key in $Task.Expected.Keys){if($null-eq $value.PSObject.Properties[$key]-or [string]$value.$key-ne [string]$Task.Expected[$key]){$ok=$false}}}catch{$ok=$false}}
 }
 [pscustomobject]@{Passed=[bool]$ok;Reason=$(if($ok){'Passed'}else{'Expected response contract was not met'})}
}
function Get-SystemSample {
 $x=[ordered]@{Timestamp=(Get-Date).ToString('o');RamUsedMB=$null;CpuPercent=$null}
 try{$os=Get-CimInstance Win32_OperatingSystem;$x.RamUsedMB=[math]::Round(([double]$os.TotalVisibleMemorySize-[double]$os.FreePhysicalMemory)/1024,2)}catch{}
 try{$cpu=Get-CimInstance Win32_Processor|Measure-Object LoadPercentage -Average;if($null-ne $cpu.Average){$x.CpuPercent=[math]::Round([double]$cpu.Average,2)}}catch{}
 [pscustomobject]$x
}
function Get-BenchmarkHardware {
 $cpu=$null;$os=$null
 try{$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1}catch{}
 try{$os=Get-CimInstance Win32_OperatingSystem}catch{}
 [pscustomobject][ordered]@{CPUName=if($cpu){[string]$cpu.Name}else{$null};InstalledRAMGB=if($os){[math]::Round([double]$os.TotalVisibleMemorySize/1MB,2)}else{$null};Source='Windows CIM';Measured=$true}
}


function Get-NvidiaSample {
 $no=[pscustomobject]@{Available=$false;UtilizationPercent=$null;MemoryUsedMB=$null;PowerWatts=$null;Reason='nvidia-smi unavailable or unsupported'}
 if(-not(Get-Command nvidia-smi -ErrorAction SilentlyContinue)){return $no}
 try{$lines=@(& nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv,noheader,nounits 2>$null);if($LASTEXITCODE-ne 0-or !$lines){return $no};$u=@();$v=@();$p=@();foreach($line in $lines){$a=$line-split ',';$u+=[double]$a[0].Trim();$v+=[double]$a[1].Trim();$p+=[double]$a[2].Trim()};[pscustomobject]@{Available=$true;UtilizationPercent=[math]::Round(($u|Measure-Object -Average).Average,2);MemoryUsedMB=[math]::Round(($v|Measure-Object -Sum).Sum,2);PowerWatts=[math]::Round(($p|Measure-Object -Sum).Sum,2);Reason=$null}}catch{$no}
}
function Invoke-OllamaJson {param([string]$Uri,[hashtable]$Body,[int]$Timeout=300);Invoke-RestMethod -Uri $Uri -Method Post -Body ($Body|ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json' -TimeoutSec $Timeout}
function Get-OllamaProcesses {param([string]$BaseUrl,[int]$Timeout=10);@((Invoke-RestMethod -Uri "$BaseUrl/api/ps" -TimeoutSec $Timeout -ErrorAction Stop).models)}
function Stop-OllamaModel {
 param([string]$BaseUrl,[string]$Name,[int]$Timeout=300)
 [void](Invoke-OllamaJson "$BaseUrl/api/generate" @{model=$Name;keep_alive=0} $Timeout)
 $end=(Get-Date).AddSeconds([math]::Min($Timeout,30));do{$found=@(Get-OllamaProcesses $BaseUrl 5|Where-Object{$_.name-eq $Name-or $_.model-eq $Name});if(!$found){return $true};Start-Sleep -Milliseconds 200}while((Get-Date)-lt $end);$false
}
function Get-Residency {
 param([string]$BaseUrl,[string]$Name);$item=@(Get-OllamaProcesses $BaseUrl|Where-Object{$_.name-eq $Name-or $_.model-eq $Name}|Select-Object -First 1)
 if(!$item){return [pscustomobject]@{Resident=$false;SizeBytes=$null;SizeVramBytes=$null;SpilloverBytes=$null;ExpiresAt=$null}}
 $size=Get-PropertyValue $item[0] size;$vram=Get-PropertyValue $item[0] size_vram;$spill=if($null-ne $size-and $null-ne $vram){[math]::Max(0,[double]$size-[double]$vram)}else{$null}
 [pscustomobject]@{Resident=$true;SizeBytes=$size;SizeVramBytes=$vram;SpilloverBytes=$spill;ExpiresAt=(Get-PropertyValue $item[0] expires_at)}
}
function Test-CompletionModel {param($ShowResponse);$caps=@(Get-PropertyValue $ShowResponse capabilities @());if($caps){return $caps-contains 'completion'};$family=[string](Get-PropertyValue (Get-PropertyValue $ShowResponse details) family '');$family-notmatch '(?i)bert|embed'}
function Get-InstalledModelName { param($Item);if($Item.PSObject.Properties['name']){return [string]$Item.name};[string]$Item.model }
function Select-BenchmarkModels {
 param([object[]]$Installed,[string[]]$Requested,[switch]$All,[switch]$Auto,[switch]$Guided,[scriptblock]$ShowModel)
 $names=@($Installed|ForEach-Object{Get-InstalledModelName $_}|Where-Object{$_}|Select-Object -Unique)
 if($Requested.Count){$missing=@($Requested|Where-Object{$names-notcontains $_});if($missing){throw "Model is not installed: $($missing -join ', ')"};$candidates=@($Requested|Select-Object -Unique)}elseif($All-or $Auto-or $Guided){$candidates=$names}else{$candidates=$names}
  $compatible=@();foreach($name in $candidates){try{$show=& $ShowModel $name;if(Test-CompletionModel $show){$item=@($Installed|Where-Object{(Get-InstalledModelName $_)-eq $name}|Select-Object -First 1);$compatible+=[pscustomobject]@{Name=$name;SizeBytes=[double](Get-PropertyValue $item[0] size 0);Show=$show}}}catch [Management.Automation.PipelineStoppedException]{throw}catch{}}
 if($Guided){Write-Host 'Compatible installed models:';for($i=0;$i-lt $compatible.Count;$i++){Write-Host "[$($i+1)] $($compatible[$i].Name)"};$answer=Read-Host 'Enter comma-separated numbers (blank selects all)';if($answer){$picked=@();foreach($n in $answer-split ','){if($n.Trim()-match '^\d+$'-and [int]$n-ge 1-and [int]$n-le $compatible.Count){$picked+=$compatible[[int]$n-1]}};$compatible=$picked}}
  if($Auto){$compatible=@($compatible|Sort-Object SizeBytes,Name|Select-Object -First $AutoSelectCount)}
 @($compatible)
}
function Get-ResourceAvailability {
 param([string]$Path)
 $freeRam=$null;$freeDisk=$null;try{$os=Get-CimInstance Win32_OperatingSystem;$freeRam=[double]$os.FreePhysicalMemory*1KB}catch{}
 try{$probe=$Path;while($probe-and -not(Test-Path $probe)){$probe=Split-Path $probe -Parent};$freeDisk=[double](Get-Item $probe).PSDrive.Free}catch{}
 [pscustomobject]@{AvailableRamBytes=$freeRam;AvailableStorageBytes=$freeDisk}
}
function Test-ModelResourceGate {
 param([double]$ModelSizeBytes,$Resources)
  # Quantized weights need runtime/context overhead. Unknown measurements fail closed.
  $required=[math]::Ceiling([math]::Max([double]1.0,[double]$ModelSizeBytes)*1.25)
 $ram=Get-PropertyValue $Resources AvailableRamBytes;$disk=Get-PropertyValue $Resources AvailableStorageBytes
  $minimumReportDisk=10MB;$known=($null-ne $ram-and $null-ne $disk);$ok=$known-and $ram-ge $required-and $disk-ge $minimumReportDisk
  $requiredGB=[math]::Round($required/1GB,2);$availableGB=if($null-ne$ram){[math]::Round([double]$ram/1GB,2)}else{$null}
  [pscustomobject]@{Allowed=$ok;RequiredBytes=$required;RequiredRamGB=$requiredGB;RequiredReportDiskBytes=$minimumReportDisk;AvailableRamBytes=$ram;AvailableRamGB=$availableGB;AvailableStorageBytes=$disk;Reason=$(if($ok){'Available'}elseif(-not$known){'RAM or storage availability could not be verified. The test was safely postponed.'}elseif($ram-lt$required){"Only $availableGB GB RAM is available; this benchmark needs about $requiredGB GB. The test was safely postponed. Close memory-heavy apps and try again."}else{'There is not enough disk space to write benchmark reports. The test was safely postponed.'})}
}
function Format-MetricValue {param($Value,[int]$Digits=2);if($null-eq $Value){return '-'};([math]::Round([double]$Value,$Digits)).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)}
function Format-CompactResult {
 param($Metric,[int]$Width=0)
 $fields=[ordered]@{Model=$Metric.Model;Task=$Metric.Task;'Cold/Warm'=$Metric.Temperature;TTFT=(Format-MetricValue $Metric.TTFTSeconds);Load=(Format-MetricValue $Metric.LoadSeconds);'Tokens/sec'=(Format-MetricValue $Metric.GenerationTokensPerSecond);Correct=[string]$Metric.Correct}
 $line=(($fields.Values|ForEach-Object{[string]$_})-join '|');if($Width-le 0){try{$Width=$Host.UI.RawUI.WindowSize.Width}catch{$Width=120}}
 if($Width-ge $line.Length){return $line}
 ($fields.GetEnumerator()|ForEach-Object{"$($_.Key): $($_.Value)"})-join [Environment]::NewLine
}
function Get-BenchmarkInsights {
 param([object[]]$Runs)
 if(!$Runs-or $Runs.Count-lt 2){return @('Insufficient evidence: fewer than two successful measured runs.')}
  $out=@();$rates=@($Runs|Where-Object{$null-ne $_.GenerationTokensPerSecond}|Sort-Object GenerationTokensPerSecond -Descending);if($rates){$out+="Generation speed: within these measured rows only, $($rates[0].Model) recorded the highest observed rate ($(Format-MetricValue $rates[0].GenerationTokensPerSecond) tokens/sec). More runs and tasks are needed for a general conclusion."}
  $responses=@($Runs|Where-Object{$null-ne $_.TTFTSeconds}|Sort-Object TTFTSeconds);if($responses){$out+="Responsiveness: $($responses[0].Model) had the lowest observed time to first token ($(Format-MetricValue $responses[0].TTFTSeconds)s) in the measured rows."}
 $correct=@($Runs|Where-Object Correct).Count;$out+="Correctness: $correct of $($Runs.Count) measured runs passed deterministic task checks."
  $pairs=@($Runs|Group-Object Model,Task,ContextLength,Run|Where-Object{@($_.Group|Where-Object Temperature -eq Cold).Count-and @($_.Group|Where-Object Temperature -eq Warm).Count});if($pairs.Count){$coldRows=@($pairs|ForEach-Object{$_.Group|Where-Object Temperature -eq Cold|Select-Object -First 1});$warmRows=@($pairs|ForEach-Object{$_.Group|Where-Object Temperature -eq Warm|Select-Object -First 1});$cold=Get-NullableAverage $coldRows TTFTSeconds;$warm=Get-NullableAverage $warmRows TTFTSeconds;$coldLoad=Get-NullableAverage $coldRows LoadSeconds;$loadText=if($null-ne$coldLoad){"; average measured cold load was $(Format-MetricValue $coldLoad)s"}else{'; cold-load timing was unavailable'};$out+="Cold/warm: across $($pairs.Count) paired run(s), average TTFT was $(Format-MetricValue $cold)s cold and $(Format-MetricValue $warm)s warm$loadText."}else{$out+='Cold/warm: insufficient paired timing evidence; additional cold and warm runs are needed.'}
  foreach($group in @($Runs|Group-Object Model,Task)){$items=@($group.Group);$passed=@($items|Where-Object Correct).Count;$out+="Task evidence: $($items[0].Model) passed $passed of $($items.Count) measured $($items[0].Task) run(s)."}
  $spill=@($Runs|Where-Object{$null-ne $_.SpilloverBytes-and [double]$_.SpilloverBytes-gt 0}).Count;$out+="Residency/spillover: $spill run(s) reported CPU/RAM spillover after generation.";$out+="Scope: evidence covers $(@($Runs.Task|Select-Object -Unique).Count) task type(s); untested tasks require additional benchmarking.";@($out)
}
function Remove-PrivateText {param([string]$Text);if($null-eq $Text){return ''};foreach($private in @($env:USERPROFILE,$env:USERNAME,$env:COMPUTERNAME)|Where-Object{$_}){$Text=$Text-replace ('(?i)'+[regex]::Escape([string]$private)),'[redacted]'};$Text=$Text-replace '(?i)\b(password|secret|token|credential|api[_ -]?key)\s*[:=]\s*\S+','$1=[redacted]';$Text=$Text-replace '(?i)(?:[A-Z]:\\|\\\\)[^\r\n|]+','[private path]';$Text}
function ConvertTo-SafeReportCell {param($Value);(Remove-PrivateText ([string]$Value))-replace '\|','/' -replace '[\r\n]+',' '}
function Get-BenchmarkExitCode {
 param([bool]$Cancelled,[bool]$SetupFailed,[int]$RunCount,[int]$SkippedCount,[int]$FailureCount)
 if($Cancelled){return 130};if($SetupFailed-or($RunCount-eq0-and$SkippedCount-eq0)){return 2};if($RunCount-eq0-and$SkippedCount-gt0-and$FailureCount-eq0){return 10};if($FailureCount-gt0-or$SkippedCount-gt0){return 20};0
}

function Invoke-OllamaStream {
 param([string]$Uri,[hashtable]$Body,[int]$Timeout=300);$Body.stream=$true
 $req=[Net.HttpWebRequest]::Create($Uri);$req.Method='POST';$req.ContentType='application/json';$req.Timeout=$Timeout*1000;$req.ReadWriteTimeout=$Timeout*1000
 $bytes=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 12 -Compress));$req.ContentLength=$bytes.Length;$s=$req.GetRequestStream();try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()}
 $clock=[Diagnostics.Stopwatch]::StartNew();$resp=$req.GetResponse();$reader=New-Object IO.StreamReader($resp.GetResponseStream());$text=New-Object Text.StringBuilder;$first=$null;$final=$null
 try{while(($line=$reader.ReadLine())-ne $null){if([string]::IsNullOrWhiteSpace($line)){continue};$part=$line|ConvertFrom-Json;$chunk=[string](Get-PropertyValue $part response '');$message=Get-PropertyValue $part message;if($message){$chunk+=[string](Get-PropertyValue $message content '');$calls=Get-PropertyValue $message tool_calls;if($calls){$chunk+=($calls|ConvertTo-Json -Depth 12 -Compress)}};if($chunk.Length-gt 0-and $null-eq $first){$first=$clock.Elapsed.TotalSeconds};[void]$text.Append($chunk);if([bool](Get-PropertyValue $part done $false)){$final=$part}}}finally{$clock.Stop();$reader.Dispose();$resp.Dispose()}
 [pscustomobject]@{Text=$text.ToString();TTFTSeconds=$(if($null-eq $first){$null}else{[math]::Round($first,6)});WallSeconds=[math]::Round($clock.Elapsed.TotalSeconds,6);Final=$final}
}
function Convert-RunMetric {
 param($Stream,[string]$ModelName,[string]$TaskName,[int]$Context,[int]$Iteration,[string]$Temperature,$Before,$After,$NvidiaBefore,$NvidiaAfter,$Residency,$Correctness)
 $f=$Stream.Final;$load=Get-PropertyValue $f load_duration;$promptNs=Get-PropertyValue $f prompt_eval_duration;$evalNs=Get-PropertyValue $f eval_duration;$total=Get-PropertyValue $f total_duration;$pc=Get-PropertyValue $f prompt_eval_count;$ec=Get-PropertyValue $f eval_count
 $energy=$null;if($NvidiaBefore.Available-and $NvidiaAfter.Available){$energy=[math]::Round((($NvidiaBefore.PowerWatts+$NvidiaAfter.PowerWatts)/2)*$Stream.WallSeconds,2)}
 [pscustomobject][ordered]@{Model=$ModelName;Task=$TaskName;ContextLength=$Context;Run=$Iteration;Temperature=$Temperature;TTFTSeconds=$Stream.TTFTSeconds;LoadSeconds=(Convert-NanosecondsToSeconds $load);PromptSeconds=(Convert-NanosecondsToSeconds $promptNs);GenerationSeconds=(Convert-NanosecondsToSeconds $evalNs);TotalSeconds=(Convert-NanosecondsToSeconds $total);WallSeconds=$Stream.WallSeconds;PromptTokens=$pc;PromptTokensPerSecond=(Get-Rate $pc $promptNs);GeneratedTokens=$ec;GenerationTokensPerSecond=(Get-Rate $ec $evalNs);Correct=$Correctness.Passed;CorrectnessReason=$Correctness.Reason;Resident=$Residency.Resident;SizeBytes=$Residency.SizeBytes;SizeVramBytes=$Residency.SizeVramBytes;SpilloverBytes=$Residency.SpilloverBytes;RamBeforeMB=$Before.RamUsedMB;RamAfterMB=$After.RamUsedMB;CpuBeforePercent=$Before.CpuPercent;CpuAfterPercent=$After.CpuPercent;NvidiaAvailable=$NvidiaAfter.Available;NvidiaUnavailableReason=$NvidiaAfter.Reason;NvidiaUtilizationPercent=$NvidiaAfter.UtilizationPercent;NvidiaPowerWatts=$NvidiaAfter.PowerWatts;NvidiaEstimatedEnergyJoules=$energy}
}


function New-ShareReportContent {
 param([object[]]$Summary,[string[]]$Insights,[string]$Timestamp,[object[]]$Skipped=@(),[object[]]$Failures=@())
  $rows=@('Model|Task|Cold/Warm|TTFT|Load|Tokens/sec|Correct');foreach($s in $Summary){$values=@($s.Model,$s.Task,$s.Temperature,(Format-MetricValue $s.AverageTTFTSeconds),(Format-MetricValue $s.AverageLoadSeconds),(Format-MetricValue $s.AverageGenerationTokensPerSecond),"$($s.CorrectRuns)/$($s.Runs)")|ForEach-Object{ConvertTo-SafeReportCell $_};$rows+=($values-join '|')};$safe=@($Insights|ForEach-Object{Remove-PrivateText $_});$status=@();foreach($item in $Skipped){$status+="Skipped: $(ConvertTo-SafeReportCell $item.Model) - $(ConvertTo-SafeReportCell $item.Reason)"};foreach($item in $Failures){$status+="Failed: $(ConvertTo-SafeReportCell $item.Model) / $(ConvertTo-SafeReportCell $item.Stage). See the private JSON report for diagnostics."}
  [pscustomobject]@{Text=((@('Icy AI Lab Benchmark',"Generated: $Timestamp")+$rows+@('Status:')+$status+@('Insights:')+$safe)-join "`r`n");Markdown=((@('# Icy AI Lab Benchmark',"Generated: $Timestamp",'','|Model|Task|Cold/Warm|TTFT|Load|Tokens/sec|Correct|','|---|---|---|---:|---:|---:|---|')+@($rows|Select-Object -Skip 1|ForEach-Object{"|$_|"})+@('','## Status')+@($status|ForEach-Object{"- $_"})+@('','## Evidence-based insights')+@($safe|ForEach-Object{"- $_"}))-join "`r`n")}
}
if($LibraryMode){return}
function Write-Log([string]$Message,[string]$Level='INFO'){if(!$JsonOutput){Write-Host "[$Level] $Message"}}
if($PSBoundParameters.ContainsKey('Prompt')-and -not $PSBoundParameters.ContainsKey('Tasks')){$Tasks=@('Custom')};if($Quick){$Runs=1;$Warmup=0;$Tasks=@('Custom');$ContextLength=@(2048)}
 $OllamaUrl=$OllamaUrl.TrimEnd('/');$allRuns=@();$skipped=@();$failures=@();$cancelled=$false;$setupFailed=$false;$version=$null;$initialNames=@();$owned=@();$logDir=Join-Path $LabRoot logs;if(!(Test-Path $logDir)){New-Item $logDir -ItemType Directory -Force|Out-Null};$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
try{
 $version=Invoke-RestMethod "$OllamaUrl/api/version" -TimeoutSec 5;$installed=@((Invoke-RestMethod "$OllamaUrl/api/tags" -TimeoutSec 10).models);$initialNames=@(Get-OllamaProcesses $OllamaUrl 10|%{Get-InstalledModelName $_})
  $selected=@(Select-BenchmarkModels $installed $Model -All:$AllModels -Auto:$AutoSelect -Guided:$GuidedSelection -ShowModel {param($n) Invoke-OllamaJson "$OllamaUrl/api/show" @{model=$n} $TimeoutSec});if(!$selected){throw 'No compatible installed completion models were selected.'};$total=$selected.Count*$ContextLength.Count*$Tasks.Count*$Runs*2;$step=0;if(!$JsonOutput){Write-Host 'Model|Task|Cold/Warm|TTFT|Load|Tokens/sec|Correct'}
 foreach($selection in $selected){$m=$selection.Name;$wasInitial=$initialNames-contains $m;if($initialNames.Count-and -not$wasInitial){$skipped+=[pscustomobject]@{Model=$m;Reason="Postponed to protect initially resident model(s): $($initialNames -join ', ')"};continue};$gate=Test-ModelResourceGate $selection.SizeBytes (Get-ResourceAvailability $LabRoot);if(!$gate.Allowed){$skipped+=[pscustomobject]@{Model=$m;Reason=$gate.Reason};continue};if(!$wasInitial){$owned+=$m};Write-Log "Benchmarking $m"
  foreach($ctx in $ContextLength){foreach($taskName in $Tasks){$task=New-TaskDefinition $taskName $Prompt
 for($w=0;$w-lt$Warmup;$w++){try{$wb=@{model=$m;stream=$false;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0}};if($task.Name-eq 'ToolUse'){$we="$OllamaUrl/api/chat";$wb.messages=@(@{role='user';content=$task.Prompt});$wb.tools=$task.Tools}else{$we="$OllamaUrl/api/generate";$wb.prompt=$task.Prompt;if($task.Format){$wb.format=$task.Format}};[void](Invoke-OllamaJson $we $wb $TimeoutSec)}catch [Management.Automation.PipelineStoppedException]{$cancelled=$true;throw}catch{$failures+=[pscustomobject]@{Model=$m;Task=$task.Name;Stage='Warmup';Error=$_.Exception.Message}}}
   for($run=1;$run-le $Runs;$run++){foreach($temperature in @('Cold','Warm')){$step++;Write-Progress -Activity 'AI Lab benchmark' -Status "$m / $($task.Name) / $temperature" -PercentComplete (100*$step/$total)
 if($temperature-eq 'Cold'-and $wasInitial){$skipped+=[pscustomobject]@{Model=$m;Reason='Cold run omitted: initially resident model is not benchmark-owned.'};continue};if($temperature-eq 'Cold'){try{if(!(Stop-OllamaModel $OllamaUrl $m $TimeoutSec)){throw 'Unload not verified'}}catch [Management.Automation.PipelineStoppedException]{$cancelled=$true;throw}catch{$failures+=[pscustomobject]@{Model=$m;Task=$task.Name;Stage='ColdUnload';Error=$_.Exception.Message};continue}}
    $before=Get-SystemSample;$nb=Get-NvidiaSample;$body=@{model=$m;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0;seed=42}};if($task.Name-eq 'ToolUse'){$endpoint="$OllamaUrl/api/chat";$body.messages=@(@{role='user';content=$task.Prompt});$body.tools=$task.Tools}else{$endpoint="$OllamaUrl/api/generate";$body.prompt=$task.Prompt;if($task.Format){$body.format=$task.Format}}
    try{$stream=Invoke-OllamaStream $endpoint $body $TimeoutSec;$metric=Convert-RunMetric $stream $m $task.Name $ctx $run $temperature $before (Get-SystemSample) $nb (Get-NvidiaSample) (Get-Residency $OllamaUrl $m) (Test-TaskResponse $stream.Text $task);$allRuns+=$metric;if(!$JsonOutput){Write-Host (Format-CompactResult $metric)}}catch [Management.Automation.PipelineStoppedException]{$cancelled=$true;throw}catch{$failures+=[pscustomobject]@{Model=$m;Task=$task.Name;Stage=$temperature;Error=$_.Exception.Message}}
   }}
  }};if($owned-contains $m){try{[void](Stop-OllamaModel $OllamaUrl $m $TimeoutSec)}catch{}}
 }
}catch [Management.Automation.PipelineStoppedException]{$cancelled=$true}catch{$setupFailed=$true;$failures+=[pscustomobject]@{Model=$null;Task=$null;Stage='Setup';Error=$_.Exception.Message};Write-Log $_.Exception.Message ERROR}
finally{
 Write-Progress -Activity 'AI Lab benchmark' -Completed;foreach($name in @($owned|Select -Unique)){try{if($initialNames-notcontains $name){[void](Stop-OllamaModel $OllamaUrl $name ([math]::Min($TimeoutSec,30)))}}catch{}}
 $summary=@($allRuns|Group-Object Model,Task,ContextLength,Temperature|%{$g=@($_.Group);[pscustomobject]@{Model=$g[0].Model;Task=$g[0].Task;ContextLength=$g[0].ContextLength;Temperature=$g[0].Temperature;Runs=$g.Count;CorrectRuns=@($g|? Correct).Count;AverageTTFTSeconds=Get-NullableAverage $g TTFTSeconds;AverageLoadSeconds=Get-NullableAverage $g LoadSeconds;AverageGenerationTokensPerSecond=Get-NullableAverage $g GenerationTokensPerSecond 2}});$insights=@(Get-BenchmarkInsights $allRuns);$timestamp=(Get-Date).ToString('o')
 $jsonPath=Join-Path $logDir "benchmark_$stamp.json";$csvPath=Join-Path $logDir "benchmark_$stamp-runs.csv";$mdPath=Join-Path $logDir "benchmark_$stamp.md";$textPath=Join-Path $logDir "benchmark_$stamp.txt";$share=New-ShareReportContent $summary $insights $timestamp $skipped $failures
 $report=[ordered]@{SchemaVersion='1.0';ReportType='IcyAILabBenchmark';Timestamp=$timestamp;Cancelled=$cancelled;Hardware=Get-BenchmarkHardware;OllamaVersion=Get-PropertyValue $version version;Configuration=[ordered]@{Runs=$Runs;Warmup=$Warmup;Tasks=$Tasks;ContextLengths=$ContextLength;KeepAliveSeconds=$KeepAliveSec;Streaming=$true;Sequential=$true};InitialResidentModels=$initialNames;SkippedModels=$skipped;Failures=$failures;Insights=$insights;Summary=$summary;Runs=$allRuns;Files=[ordered]@{Json=$jsonPath;Csv=$csvPath;Markdown=$mdPath;Text=$textPath}}
 $json=$report|ConvertTo-Json -Depth 8;Set-Content $jsonPath $json -Encoding UTF8;if($allRuns.Count){$allRuns|Export-Csv $csvPath -NoTypeInformation -Encoding UTF8}else{Set-Content $csvPath 'Model,Task,ContextLength,Run,Temperature,TTFTSeconds,LoadSeconds,GenerationTokensPerSecond,Correct' -Encoding UTF8};Set-Content $mdPath $share.Markdown -Encoding UTF8;Set-Content $textPath $share.Text -Encoding UTF8
 if($JsonOutput){$json}else{Write-Log "JSON report: $jsonPath";Write-Log "CSV report: $csvPath";Write-Log "Markdown report: $mdPath";Write-Log "Shareable text: $textPath";if($PassThru){$report}};$exitCode=Get-BenchmarkExitCode $cancelled $setupFailed @($allRuns).Count @($skipped).Count @($failures).Count;if($exitCode-ne0){exit $exitCode}
}
