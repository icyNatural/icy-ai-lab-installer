[CmdletBinding()]
param(
 [string]$LabRoot=(Join-Path $env:USERPROFILE 'AI-Lab'),[string]$Model='',
 [string]$Prompt='Explain quantum computing in 3 concise sentences.',
 [ValidateRange(0,100)][int]$Warmup=1,[ValidateRange(1,100)][int]$Runs=3,
 [string]$OllamaUrl='http://localhost:11434',[switch]$JsonOutput,
 [ValidateSet('Conversation','Summarization','Coding','Extraction','Reasoning','ToolUse','Custom')][string[]]$Tasks=@('Conversation','Summarization','Coding','Extraction','Reasoning','ToolUse'),
 [ValidateRange(128,1048576)][int[]]$ContextLength=@(2048),
 [ValidateRange(1,3600)][int]$TimeoutSec=300,[ValidateRange(1,3600)][int]$KeepAliveSec=300,
 [switch]$Quick,[switch]$LibraryMode
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
 [pscustomobject][ordered]@{CPUName=if($cpu){[string]$cpu.Name}else{$null};InstalledRAMGB=if($os){[math]::Round([double]$os.TotalVisibleMemorySize/1MB,2)}else{$null};MachineName=$env:COMPUTERNAME;Source='Windows CIM';Measured=$true}
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


if($LibraryMode){return}
function Write-Log([string]$Message,[string]$Level='INFO'){if(!$JsonOutput){Write-Host "[$Level] $Message"}}
# Preserve the legacy custom-prompt workflow when -Prompt is explicitly supplied.
if($PSBoundParameters.ContainsKey('Prompt')-and -not $PSBoundParameters.ContainsKey('Tasks')){$Tasks=@('Custom')}
if($Quick){$Runs=1;$Warmup=0;$Tasks=@('Custom');$ContextLength=@(2048)}
$OllamaUrl=$OllamaUrl.TrimEnd('/')
try{$version=Invoke-RestMethod "$OllamaUrl/api/version" -TimeoutSec 5}catch{Write-Error "Ollama is not reachable at $OllamaUrl";return}
if([string]::IsNullOrWhiteSpace($Model)){$models=@((Invoke-RestMethod "$OllamaUrl/api/tags" -TimeoutSec 10).models|ForEach-Object{$_.name});if($Quick-and $models.Count-gt 1){$models=@($models[0])}}else{$models=@($Model)}
if(!$models){Write-Error 'No Ollama models found.';return}
$allRuns=@();$skipped=@()
foreach($m in $models){
 try{$show=Invoke-OllamaJson "$OllamaUrl/api/show" @{model=$m} $TimeoutSec}catch{$skipped+=[pscustomobject]@{Model=$m;Reason="Show failed: $($_.Exception.Message)"};continue}
 if(-not(Test-CompletionModel $show)){$skipped+=[pscustomobject]@{Model=$m;Reason='No completion capability; embedding-only models are not sent to /api/generate.'};continue}
 Write-Log "Benchmarking $m"
 foreach($ctx in $ContextLength){foreach($taskName in $Tasks){$task=New-TaskDefinition $taskName $Prompt
  for($w=0;$w-lt $Warmup;$w++){if($task.Name-eq 'ToolUse'){$warmEndpoint="$OllamaUrl/api/chat";$body=@{model=$m;messages=@(@{role='user';content=$task.Prompt});tools=$task.Tools;stream=$false;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0}}}else{$warmEndpoint="$OllamaUrl/api/generate";$body=@{model=$m;prompt=$task.Prompt;stream=$false;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0}};if($task.Format){$body.format=$task.Format}};try{[void](Invoke-OllamaJson $warmEndpoint $body $TimeoutSec)}catch{Write-Log "Warmup failed: $_" WARN}}
  for($run=1;$run-le $Runs;$run++){foreach($temperature in @('Cold','Warm')){
   if($temperature-eq 'Cold'){try{$unloaded=Stop-OllamaModel $OllamaUrl $m $TimeoutSec}catch{Write-Log "Unload failed for $m; cold run skipped: $_" WARN;continue};if(-not $unloaded){Write-Log "Could not verify unload for $m; cold run skipped" WARN;continue}}
   $before=Get-SystemSample;$nb=Get-NvidiaSample;if($task.Name-eq 'ToolUse'){$endpoint="$OllamaUrl/api/chat";$body=@{model=$m;messages=@(@{role='user';content=$task.Prompt});tools=$task.Tools;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0;seed=42}}}else{$endpoint="$OllamaUrl/api/generate";$body=@{model=$m;prompt=$task.Prompt;keep_alive="${KeepAliveSec}s";options=@{num_ctx=$ctx;temperature=0;seed=42}};if($task.Format){$body.format=$task.Format}}
   try{$stream=Invoke-OllamaStream $endpoint $body $TimeoutSec;$correct=Test-TaskResponse $stream.Text $task;$after=Get-SystemSample;$na=Get-NvidiaSample;$resident=Get-Residency $OllamaUrl $m;$allRuns+=Convert-RunMetric $stream $m $task.Name $ctx $run $temperature $before $after $nb $na $resident $correct}catch{Write-Log "$temperature run failed for $m/$($task.Name): $_" WARN}
  }}
 }}}
$summary=@($allRuns|Group-Object Model,Task,ContextLength,Temperature|ForEach-Object{$g=@($_.Group);[pscustomobject]@{Model=$g[0].Model;Task=$g[0].Task;ContextLength=$g[0].ContextLength;Temperature=$g[0].Temperature;Runs=$g.Count;CorrectRuns=@($g|Where-Object Correct).Count;AverageTTFTSeconds=(Get-NullableAverage $g TTFTSeconds);AverageLoadSeconds=(Get-NullableAverage $g LoadSeconds);AverageGenerationTokensPerSecond=(Get-NullableAverage $g GenerationTokensPerSecond 2)}})
$logDir=Join-Path $LabRoot logs;if(!(Test-Path $logDir)){New-Item $logDir -ItemType Directory -Force|Out-Null};$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff';$jsonPath=Join-Path $logDir "benchmark_$stamp.json";$csvPath=Join-Path $logDir "benchmark_$stamp-runs.csv"
$report=[ordered]@{SchemaVersion='1.0';ReportType='IcyAILabBenchmark';Timestamp=(Get-Date).ToString('o');Hardware=Get-BenchmarkHardware;OllamaVersion=(Get-PropertyValue $version version);Configuration=[ordered]@{Runs=$Runs;Warmup=$Warmup;Tasks=$Tasks;ContextLengths=$ContextLength;KeepAliveSeconds=$KeepAliveSec;Streaming=$true};SkippedModels=$skipped;Summary=$summary;Runs=$allRuns;Files=[ordered]@{Json=$jsonPath;Csv=$csvPath}}
$json=$report|ConvertTo-Json -Depth 8;Set-Content $jsonPath $json -Encoding UTF8;$allRuns|Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
if($JsonOutput){$json}else{Write-Log "JSON: $jsonPath" SUCCESS;Write-Log "Per-run CSV: $csvPath" SUCCESS;$summary|Format-Table -AutoSize;$report}
