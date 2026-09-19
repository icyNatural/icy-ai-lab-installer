Set-StrictMode -Version Latest

function New-EvidenceValue {
    param($Value, [string]$Source, [ValidateSet('High','Medium','Low','Unavailable')][string]$Confidence = 'High', [bool]$Measured = $true)
    [pscustomobject][ordered]@{ Value = $Value; Source = $Source; Confidence = $Confidence; Measured = $Measured }
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Import-AIModelCatalog {
    [CmdletBinding()]
    param([string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'model-catalog.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Model catalog not found: $Path" }
    try { $catalog = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid model catalog JSON at '$Path': $($_.Exception.Message)" }
    if (-not $catalog.schemaVersion -or -not $catalog.models -or @($catalog.models).Count -eq 0) { throw 'Catalog must contain schemaVersion and at least one model.' }
    $seen = @{}
    foreach ($model in @($catalog.models)) {
        foreach ($required in @('tag','name','tasks','artifactSizeBytes','license','sourceUrl','minimum')) {
            if (-not $model.PSObject.Properties[$required] -or $null -eq $model.$required -or "$($model.$required)".Length -eq 0) { throw "Catalog model is missing '$required'." }
        }
        if ($model.tag -notmatch '^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$') { throw "Catalog tag is not explicit: $($model.tag)" }
        if ($seen.ContainsKey($model.tag)) { throw "Duplicate catalog tag: $($model.tag)" }; $seen[$model.tag] = $true
        if ([double]$model.artifactSizeBytes -le 0 -or [double]$model.minimum.ramGB -le 0 -or [double]$model.minimum.diskGB -le 0) { throw "Catalog model '$($model.tag)' has invalid resource values." }
        $uri = $null
        if (-not [uri]::TryCreate([string]$model.sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { throw "Catalog model '$($model.tag)' requires an HTTPS sourceUrl." }
    }
    return $catalog
}

function Get-AIStorageProfile {
    [CmdletBinding()]
    param([string]$ModelPath)
    if (-not $ModelPath) {
        $ModelPath = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.ollama\models' } else { $env:TEMP }
    }
    $probe = $ModelPath
    while ($probe -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path $probe -Parent }
    try {
        if (-not $probe) { throw 'No existing parent path.' }
        $item = Get-Item -LiteralPath $probe -ErrorAction Stop
        $root = [System.IO.Path]::GetPathRoot($item.FullName)
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'" -ErrorAction Stop
        [pscustomobject][ordered]@{ ModelPath=$ModelPath; Volume=$disk.DeviceID; FreeGB=New-EvidenceValue ([math]::Round([double]$disk.FreeSpace/1GB,2)) 'Win32_LogicalDisk.FreeSpace'; TotalGB=New-EvidenceValue ([math]::Round([double]$disk.Size/1GB,2)) 'Win32_LogicalDisk.Size'; Available=$true }
    } catch {
        [pscustomobject][ordered]@{ ModelPath=$ModelPath; Volume=$null; FreeGB=New-EvidenceValue $null 'Unavailable' 'Unavailable' $false; TotalGB=New-EvidenceValue $null 'Unavailable' 'Unavailable' $false; Available=$false; Error=$_.Exception.Message }
    }
}

function Get-AIHardwareProfile {
    [CmdletBinding()]
    param([string]$ModelPath)
    $cpu = $null; $os = $null; $gpus = @()
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch {}
    $archMap = @{0='x86';5='ARM';6='Itanium';9='x64';12='ARM64'}
    $archCode = Get-PropertyValue $cpu 'Architecture' -1
    $arch = if ($archMap.ContainsKey([int]$archCode)) { $archMap[[int]$archCode] } elseif ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { 'Unknown' }
    $hints = @()
    $caption = "$(Get-PropertyValue $cpu 'Caption' '') $(Get-PropertyValue $cpu 'Name' '')"
    if ($arch -in @('x64','x86')) { $hints += 'SSE2 (architecture baseline)' }
    if ($caption -match 'Intel|AMD') { $hints += 'AVX/AVX2 not safely inferable from WMI; verify at runtime' }
    $adapters = @()
    foreach ($gpu in $gpus) {
        $name = [string](Get-PropertyValue $gpu 'Name' 'Unknown GPU'); $kind = if ($name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc\(TM\) A') {'Discrete'} elseif ($name -match 'Intel|UHD|Iris|Vega|Integrated|Radeon\(TM\) Graphics') {'Integrated'} else {'Unknown'}
        $raw = Get-PropertyValue $gpu 'AdapterRAM' $null; $vram = $null
        if ($null -ne $raw -and [double]$raw -gt 0) { $vram = [math]::Round([double]$raw/1GB,2) }
        $adapters += [pscustomobject][ordered]@{ Name=$name; Mode=$kind; Architecture=New-EvidenceValue $null 'Unavailable from generic Windows telemetry' 'Unavailable' $false; DriverVersion=Get-PropertyValue $gpu 'DriverVersion'; DedicatedVRAMGB=New-EvidenceValue $vram 'Win32_VideoController.AdapterRAM' $(if($null -ne $vram){'Low'}else{'Unavailable'}) $false; VRAMGB=New-EvidenceValue $vram 'Win32_VideoController.AdapterRAM' $(if($null -ne $vram){'Low'}else{'Unavailable'}) $false; SharedMemoryGB=New-EvidenceValue $null 'Unavailable from Win32_VideoController' 'Unavailable' $false }
    }
    $nvidia = @()
    try {
        if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
            $rows = @(& nvidia-smi '--query-gpu=name,memory.total,memory.used,utilization.gpu' '--format=csv,noheader,nounits' 2>$null)
            foreach ($row in $rows) { $p = $row -split '\s*,\s*'; if ($p.Count -ge 4 -and $p[1] -as [double]) { $nvidia += [pscustomobject][ordered]@{ Name=$p[0]; VRAMGB=New-EvidenceValue ([math]::Round([double]$p[1]/1024,2)) 'nvidia-smi memory.total' 'High'; UsedVRAMGB=New-EvidenceValue ([math]::Round([double]$p[2]/1024,2)) 'nvidia-smi memory.used' 'High'; UtilizationPercent=New-EvidenceValue ([double]$p[3]) 'nvidia-smi utilization.gpu' 'High' } } }
        }
    } catch {}
    $gpuMode = if ($nvidia.Count) {'Discrete'} elseif (@($adapters | Where-Object Mode -eq 'Discrete').Count) {'Discrete'} elseif (@($adapters | Where-Object Mode -eq 'Integrated').Count) {'Integrated'} else {'CPU'}
    $cpuUtil=$null; $memUtil=$null; $gpuUtil=$null
    $load=Get-PropertyValue $cpu 'LoadPercentage' $null
    if($null-ne$load){$cpuUtil=[double]$load}
    if($nvidia.Count){$gpuUtil=[double](($nvidia|ForEach-Object {$_.UtilizationPercent.Value}|Measure-Object -Maximum).Maximum)}
    $totalRam = if($os -and $null -ne (Get-PropertyValue $os 'TotalVisibleMemorySize')){[math]::Round([double]$os.TotalVisibleMemorySize/1MB,2)}else{$null}
    $freeRam = if($os -and $null -ne (Get-PropertyValue $os 'FreePhysicalMemory')){[math]::Round([double]$os.FreePhysicalMemory/1MB,2)}else{$null}
    if($null-ne$totalRam -and $totalRam-gt 0 -and $null-ne$freeRam){$memUtil=100*(1-($freeRam/$totalRam))}
    [pscustomobject][ordered]@{
        CPU=[pscustomobject][ordered]@{ Name=New-EvidenceValue (Get-PropertyValue $cpu 'Name' 'Unknown') 'Win32_Processor.Name' $(if($cpu){'High'}else{'Unavailable'}); Architecture=New-EvidenceValue $arch 'Win32_Processor.Architecture' $(if($cpu){'High'}else{'Low'}); Cores=New-EvidenceValue (Get-PropertyValue $cpu 'NumberOfCores') 'Win32_Processor.NumberOfCores' $(if($cpu){'High'}else{'Unavailable'}); Threads=New-EvidenceValue (Get-PropertyValue $cpu 'NumberOfLogicalProcessors') 'Win32_Processor.NumberOfLogicalProcessors' $(if($cpu){'High'}else{'Unavailable'}); InstructionHints=$hints }
        Memory=[pscustomobject][ordered]@{ InstalledGB=New-EvidenceValue $totalRam 'Win32_OperatingSystem.TotalVisibleMemorySize' $(if($null-ne$totalRam){'High'}else{'Unavailable'}); AvailableGB=New-EvidenceValue $freeRam 'Win32_OperatingSystem.FreePhysicalMemory' $(if($null-ne$freeRam){'High'}else{'Unavailable'}) }
        GPU=[pscustomobject][ordered]@{ Mode=$gpuMode; Adapters=$adapters; Nvidia=$nvidia }
        Storage=Get-AIStorageProfile -ModelPath $ModelPath
        Utilization=[pscustomobject][ordered]@{ CPUPercent=New-EvidenceValue $(if($null-ne$cpuUtil){[math]::Round($cpuUtil,1)}else{$null}) 'Win32_Processor.LoadPercentage' $(if($null-ne$cpuUtil){'Medium'}else{'Unavailable'}); MemoryPercent=New-EvidenceValue $(if($null-ne$memUtil){[math]::Round($memUtil,1)}else{$null}) 'Derived from Win32_OperatingSystem memory values' $(if($null-ne$memUtil){'Medium'}else{'Unavailable'}); GPUPercent=New-EvidenceValue $(if($null-ne$gpuUtil){[math]::Round($gpuUtil,1)}else{$null}) $(if($nvidia.Count){'nvidia-smi utilization.gpu'}else{'Unavailable without supported vendor telemetry'}) $(if($null-ne$gpuUtil){'High'}else{'Unavailable'}); PowerWatts=New-EvidenceValue $null 'Unavailable without supported vendor telemetry' 'Unavailable' $false; MemoryBandwidthGBps=New-EvidenceValue $null 'Not measured by this quick profile' 'Unavailable' $false }
    }
}

function Get-OllamaProfile {
    [CmdletBinding()]
    param([string]$Url='http://localhost:11434')
    $installed = [bool](Get-Command ollama -ErrorAction SilentlyContinue); $available=$false; $version=$null; $models=@(); $running=@()
    try { $r=Invoke-RestMethod "$($Url.TrimEnd('/'))/api/version" -TimeoutSec 3 -ErrorAction Stop; $available=$true; $version=$r.version } catch {}
    if ($available) {
        try { $models=@((Invoke-RestMethod "$($Url.TrimEnd('/'))/api/tags" -TimeoutSec 3 -ErrorAction Stop).models) } catch {}
        try { $running=@((Invoke-RestMethod "$($Url.TrimEnd('/'))/api/ps" -TimeoutSec 3 -ErrorAction Stop).models | ForEach-Object { [pscustomobject][ordered]@{ Name=$_.name; SizeBytes=$_.size; SizeVRAMBytes=$_.size_vram; Placement=if($null-ne$_.size_vram -and [double]$_.size_vram -gt 0){ if([double]$_.size_vram -ge [double]$_.size){'GPU'}else{'Hybrid'} }else{'CPU'}; Source='Ollama /api/ps'; Confidence='High'; Measured=$true } }) } catch {}
    }
    [pscustomobject][ordered]@{ Installed=$installed; ApiAvailable=$available; Url=$Url; Version=$version; InstalledModels=$models; RunningModels=$running; EvidenceSource=if($available){'Ollama REST API'}else{'API unavailable'}; Confidence=if($available){'High'}else{'Unavailable'} }
}

function Test-AIModelCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Hardware)
    $reasons=@(); $warnings=@()
    $installed=Get-PropertyValue $Hardware.Memory.InstalledGB 'Value' $null; $available=Get-PropertyValue $Hardware.Memory.AvailableGB 'Value' $null; $disk=Get-PropertyValue $Hardware.Storage.FreeGB 'Value' $null
    if($null-eq$installed){$reasons+='Installed RAM telemetry could not be verified.'}elseif([double]$installed-lt[double]$Model.minimum.ramGB){$reasons+="Requires at least $($Model.minimum.ramGB) GB installed RAM."}
    if($null-eq$available){$reasons+='Available RAM telemetry could not be verified.'}else{
        $runtimeRequired=[math]::Round(([double]$Model.artifactSizeBytes/1GB)*1.25+0.5,2)
        if([double]$available-lt$runtimeRequired){$reasons+="Estimated runtime needs about $runtimeRequired GB; only $available GB RAM is currently available."}
        elseif([double]$available-lt([double]$Model.minimum.ramGB*0.75)){$warnings+='Current available RAM leaves limited operating-system headroom.'}
    }
    if($null-eq$disk){$reasons+='Storage availability could not be verified.'}elseif([double]$disk-lt[double]$Model.minimum.diskGB){$reasons+="Requires $($Model.minimum.diskGB) GB disk; $disk GB is available."}
    [pscustomobject][ordered]@{Tag=$Model.tag; Compatible=($reasons.Count-eq 0); Reasons=$reasons; Warnings=$warnings; Minimum=$Model.minimum; Evidence=[pscustomobject]@{InstalledRAMGB=$installed;AvailableRAMGB=$available;FreeDiskGB=$disk;GPUMode=$Hardware.GPU.Mode}}
}

function Get-AIModelRecommendation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)]$Hardware,[ValidateSet('general','coding','reasoning','vision','embedding','tools')][string]$Task='general',$BenchmarkReport)
    $ranked=@()
    foreach($m in @($Catalog.models|Where-Object {$_.tasks -contains $Task})){
        $compat=Test-AIModelCompatibility $m $Hardware; $estimate=Get-AIResourceEstimate $m $Hardware
        $measured=$null
        if($BenchmarkReport -and $BenchmarkReport.SchemaVersion -eq '1.0' -and $BenchmarkReport.Summary -and $BenchmarkReport.Hardware){
            $hardwareCpu=Get-PropertyValue $Hardware 'CPU' $null
            $cpuName=Get-PropertyValue $hardwareCpu 'Name' $null
            $currentCpu=[string](Get-PropertyValue $cpuName 'Value' '')
            $reportCpu=[string](Get-PropertyValue $BenchmarkReport.Hardware 'CPUName' '')
            $currentRam=[double](Get-PropertyValue $Hardware.Memory.InstalledGB 'Value' 0)
            $reportRam=[double](Get-PropertyValue $BenchmarkReport.Hardware 'InstalledRAMGB' 0)
            $sameMachine=($currentCpu.Trim() -eq $reportCpu.Trim() -and [math]::Abs($currentRam-$reportRam) -le 0.25)
            $taskMap=@{general=@('Conversation','Summarization','Extraction');coding=@('Coding');reasoning=@('Reasoning');tools=@('ToolUse');vision=@();embedding=@()}
            [object[]]$allowedTasks=@($taskMap[$Task])
            $rows=@()
            if($sameMachine -and @($allowedTasks).Count -gt 0){$rows=@($BenchmarkReport.Summary|Where-Object {$_.Model -eq $m.tag -and $allowedTasks -contains $_.Task})}
            if(@($rows).Count -gt 0){
                [object[]]$warm=@($rows|Where-Object {$_.Temperature -eq 'Warm'});if(@($warm).Count -eq 0){$warm=@($rows)}
                [object[]]$speed=@($warm|ForEach-Object {if($null-ne$_.AverageGenerationTokensPerSecond){[double]$_.AverageGenerationTokensPerSecond}})
                $correct=[double](($rows|Measure-Object CorrectRuns -Sum).Sum);$runs=[double](($rows|Measure-Object Runs -Sum).Sum)
                $measured=[pscustomobject][ordered]@{GenerationTokensPerSecond=if(@($speed).Count -gt 0){[math]::Round(($speed|Measure-Object -Average).Average,2)}else{$null};CorrectRuns=[int]$correct;Runs=[int]$runs;Source='Icy AI Lab benchmark report';Measured=$true}
            }
        }
        $score=if($compat.Compatible){100+[int](Get-PropertyValue $m 'qualityTier' 0)-[double]$estimate.Estimated.RuntimeMemoryGB}else{-100}
        if($measured -and $measured.Runs -gt 0){$score+=20*($measured.CorrectRuns/$measured.Runs);if($null-ne$measured.GenerationTokensPerSecond){$score+=[math]::Min(5,$measured.GenerationTokensPerSecond/10)}}
        $ranked += [pscustomobject][ordered]@{Tag=$m.tag;Name=$m.name;Task=$Task;Compatible=$compat.Compatible;Reasons=$compat.Reasons;Warnings=$compat.Warnings;Minimum=$m.minimum;Estimated=$estimate.Estimated;MeasuredPerformance=$measured;License=$m.license;SourceUrl=$m.sourceUrl;Score=$score}
    }
    $ordered=@($ranked|Sort-Object @{Expression='Compatible';Descending=$true},@{Expression='Score';Descending=$true},Tag)
    [pscustomobject][ordered]@{Task=$Task;Recommended=if($ordered.Count){$ordered[0]}else{$null};Candidates=$ordered;FallbackUsed=($ordered.Count-eq 0 -or -not $ordered[0].Compatible);Basis='Minimum requirements plus conservative estimated fit; no throughput is predicted.'}
}

function Get-AIRecommendationPortfolio {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)]$Hardware,$BenchmarkReport)
    $byTask=@{}
    foreach($task in 'general','coding','tools','embedding','vision'){$byTask[$task]=Get-AIModelRecommendation -Catalog $Catalog -Hardware $Hardware -Task $task -BenchmarkReport $BenchmarkReport}
    $general=@($byTask.general.Candidates|Where-Object Compatible)
    $all=@();$compatibleAll=@()
    foreach($task in 'general','coding','reasoning','vision','tools'){
        $taskCandidates=@((Get-AIModelRecommendation -Catalog $Catalog -Hardware $Hardware -Task $task -BenchmarkReport $BenchmarkReport).Candidates)
        $all+=$taskCandidates;$compatibleAll+=@($taskCandidates|Where-Object Compatible)
    }
    $all=@($all|Sort-Object Tag -Unique);$compatibleAll=@($compatibleAll|Sort-Object Tag -Unique)
    $fast=@($general|Sort-Object {$_.Estimated.RuntimeMemoryGB},Tag|Select-Object -First 1)
    $balanced=@($general|Sort-Object @{Expression='Score';Descending=$true},Tag|Select-Object -First 1)
    $largestPool=if($compatibleAll.Count){$compatibleAll}else{$all}
    $largest=@($largestPool|Sort-Object @{Expression={$_.Estimated.RuntimeMemoryGB};Descending=$true},Tag|Select-Object -First 1)
    $definitions=[ordered]@{
        FastEverydayAssistant=if($fast.Count){$fast[0]}else{$byTask.general.Recommended}
        BalancedGeneralAssistant=if($balanced.Count){$balanced[0]}else{$byTask.general.Recommended}
        LightweightCodingAssistant=$byTask.coding.Recommended
        LocalAutomationToolUse=$byTask.tools.Recommended
        DocumentAndRetrieval=$byTask.embedding.Recommended
        VisionModel=$byTask.vision.Recommended
        LargestComfortable=if($largest.Count){$largest[0]}else{$null}
    }
    $categories=@()
    foreach($entry in $definitions.GetEnumerator()){
        $candidate=$entry.Value;if(-not$candidate){continue};$measured=$candidate.MeasuredPerformance
        $explanation=if($measured){"Measured benchmark: $($measured.GenerationTokensPerSecond) generation tokens/sec and $($measured.CorrectRuns)/$($measured.Runs) task checks passed. Estimated placement: $($candidate.Estimated.Placement)."}else{"Provisional: no matching benchmark data. Estimated runtime memory $($candidate.Estimated.RuntimeMemoryGB) GB; placement $($candidate.Estimated.Placement)."}
        $categories+=[pscustomobject][ordered]@{Category=$entry.Key;Model=$candidate.Tag;Compatible=$candidate.Compatible;Provisional=($null-eq$measured);Explanation=$explanation;MeasuredPerformance=$measured;Estimated=$candidate.Estimated;Warnings=$candidate.Warnings;Reasons=$candidate.Reasons}
    }
    return $categories
}

function Get-AdaptiveAILabProfile {
    [CmdletBinding()]
    param([string]$CatalogPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'model-catalog.json'),[string]$ModelPath,[string]$OllamaUrl='http://localhost:11434',[ValidateSet('general','coding','reasoning','vision','embedding','tools')][string]$Task='general',$BenchmarkReport)
    $catalog=Import-AIModelCatalog $CatalogPath; $hardware=Get-AIHardwareProfile $ModelPath; $ollama=Get-OllamaProfile $OllamaUrl; $recommendation=Get-AIModelRecommendation $catalog $hardware $Task -BenchmarkReport $BenchmarkReport;$portfolio=Get-AIRecommendationPortfolio $catalog $hardware $BenchmarkReport
    [pscustomobject][ordered]@{SchemaVersion='1.0';Timestamp=(Get-Date).ToString('o');Hardware=$hardware;Ollama=$ollama;Recommendations=$recommendation;RecommendationPortfolio=$portfolio;Catalog=[pscustomobject]@{Path=$CatalogPath;Version=$catalog.catalogVersion;ModelCount=@($catalog.models).Count}}
}

function Get-AIResourceEstimate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Hardware)
    $artifactGB=[math]::Round([double]$Model.artifactSizeBytes/1GB,2); $runtimeGB=[math]::Round($artifactGB*1.25+0.5,2)
    $ram=[double](Get-PropertyValue $Hardware.Memory.AvailableGB 'Value' 0); $disk=[double](Get-PropertyValue $Hardware.Storage.FreeGB 'Value' 0)
    $vram=0
    $vramValues=@($Hardware.GPU.Nvidia | ForEach-Object { if($null-ne$_.VRAMGB.Value -and $_.VRAMGB.Value -as [double]){[double]$_.VRAMGB.Value} })
    if($vramValues.Count){$vram=[double](($vramValues|Measure-Object -Maximum).Maximum)}
    $gpuMode=[string](Get-PropertyValue $Hardware.GPU 'Mode' 'CPU')
    $mode=if($vram -ge $runtimeGB){'GPU'}elseif($vram -gt 0){'Hybrid'}elseif($gpuMode -eq 'Discrete'){'UnknownOffload'}else{'CPU'}
    [pscustomobject][ordered]@{ Tag=$Model.tag; Minimum=$Model.minimum; Estimated=[pscustomobject][ordered]@{ DownloadGB=$artifactGB; RuntimeMemoryGB=$runtimeGB; Placement=$mode; Fit=if($ram-ge [double]$Model.minimum.ramGB -and $disk-ge [double]$Model.minimum.diskGB){'Fits'}else{'DoesNotFit'}; Source='Heuristic: catalog artifact x 1.25 + 0.5 GB overhead'; Confidence='Low'; Measured=$false }; MeasuredEvidence=$Hardware }
}

Export-ModuleMember -Function Import-AIModelCatalog,Get-AIStorageProfile,Get-AIHardwareProfile,Get-OllamaProfile,Get-AIResourceEstimate,Test-AIModelCompatibility,Get-AIModelRecommendation,Get-AIRecommendationPortfolio,Get-AdaptiveAILabProfile
