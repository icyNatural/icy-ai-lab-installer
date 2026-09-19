$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'scripts\Adaptive-AI-Lab.psm1'
$catalogPath = Join-Path $repoRoot 'model-catalog.json'
Import-Module $modulePath -Force

function New-TestHardware {
    param([double]$Installed=16,[double]$Available=12,[AllowNull()]$Disk=20,[string]$Mode='CPU',[double]$VRAM=0)
    $nvidia=@(); if($VRAM -gt 0){$nvidia=@([pscustomobject]@{VRAMGB=[pscustomobject]@{Value=$VRAM}})}
    [pscustomobject]@{
        Memory=[pscustomobject]@{InstalledGB=[pscustomobject]@{Value=$Installed};AvailableGB=[pscustomobject]@{Value=$Available}}
        Storage=[pscustomobject]@{FreeGB=[pscustomobject]@{Value=$Disk}}
        GPU=[pscustomobject]@{Mode=$Mode;Nvidia=$nvidia}
    }
}

Describe 'Adaptive AI Lab' {
    BeforeAll { $catalog=Import-AIModelCatalog $catalogPath }

    It 'loads a validated explicitly tagged catalog for every task' {
        @($catalog.models).Count | Should BeGreaterThan 5
        foreach($task in 'general','coding','reasoning','vision','embedding','tools'){@($catalog.models|? tasks -contains $task).Count|Should BeGreaterThan 0}
        @($catalog.models|? tag -notmatch ':').Count | Should Be 0
    }
    It 'rejects malformed catalogs' {
        $bad=Join-Path $TestDrive 'bad.json'; '{"schemaVersion":"1.0","models":[{"tag":"latest"}]}'|Set-Content $bad
        { Import-AIModelCatalog $bad } | Should Throw
    }
    It 'uses CPU placement with no GPU' {
        $e=Get-AIResourceEstimate $catalog.models[0] (New-TestHardware)
        $e.Estimated.Placement | Should Be 'CPU'
        $e.Estimated.Measured | Should Be $false
    }
    It 'uses hybrid placement with low VRAM' {
        (Get-AIResourceEstimate ($catalog.models|? tag -eq 'gemma3:4b') (New-TestHardware -Mode Discrete -VRAM 2)).Estimated.Placement | Should Be 'Hybrid'
    }
    It 'does not claim CPU placement for a discrete non-NVIDIA GPU with unverified VRAM' {
        (Get-AIResourceEstimate $catalog.models[0] (New-TestHardware -Mode Discrete)).Estimated.Placement | Should Be 'UnknownOffload'
    }
    It 'does not use unreliable integrated GPU VRAM for placement' {
        (Get-AIResourceEstimate $catalog.models[0] (New-TestHardware -Mode Integrated)).Estimated.Placement | Should Be 'CPU'
    }
    It 'rejects models when disk is low' {
        (Test-AIModelCompatibility ($catalog.models|? tag -eq 'gemma3:4b') (New-TestHardware -Disk .2)).Compatible | Should Be $false
    }
    It 'fails closed when storage telemetry is missing' {
        $x=Test-AIModelCompatibility $catalog.models[0] (New-TestHardware -Disk $null)
        $x.Compatible|Should Be $false; $x.Reasons -join ' '|Should Match 'Storage'
    }
    It 'handles bad or missing VRAM without throwing' {
        $h=New-TestHardware; $h.GPU.Nvidia=@([pscustomobject]@{VRAMGB=[pscustomobject]@{Value=$null}})
        { Get-AIResourceEstimate $catalog.models[0] $h }|Should Not Throw
    }
    It 'marks unavailable Ollama safely' {
        $o=Get-OllamaProfile -Url 'http://127.0.0.1:1'
        $o.ApiAvailable|Should Be $false; $o.Confidence|Should Be 'Unavailable'
    }
    It 'provides task recommendation and fallback when nothing fits' {
        $r=Get-AIModelRecommendation $catalog (New-TestHardware -Installed 1 -Available 1 -Disk .1) general
        $r.FallbackUsed|Should Be $true; $r.Recommended|Should Not BeNullOrEmpty
    }
    It 'fails closed when current RAM cannot cover estimated runtime memory' {
        $x=Test-AIModelCompatibility $catalog.models[0] (New-TestHardware -Installed 16 -Available .5 -Disk 20)
        $x.Compatible|Should Be $false
        $x.Reasons -join ' '|Should Match 'currently available'
    }
    It 'builds all requested recommendation categories as provisional without benchmarks' {
        $portfolio=Get-AIRecommendationPortfolio $catalog (New-TestHardware -Available 12 -Disk 20)
        foreach($name in 'FastEverydayAssistant','BalancedGeneralAssistant','LightweightCodingAssistant','LocalAutomationToolUse','DocumentAndRetrieval','VisionModel','LargestComfortable'){@($portfolio|? Category -eq $name).Count|Should Be 1}
        @($portfolio|? Provisional -eq $false).Count|Should Be 0
    }
    It 'uses only supplied measured benchmark values in recommendation evidence' {
        $hardware=New-TestHardware -Available 12 -Disk 20
        $hardware|Add-Member CPU ([pscustomobject]@{Name=[pscustomobject]@{Value='Test CPU'}})
        $bench=[pscustomobject]@{SchemaVersion='1.0';Hardware=[pscustomobject]@{CPUName='Test CPU';InstalledRAMGB=16};Summary=@([pscustomobject]@{Model='llama3.2:1b';Task='Conversation';Temperature='Warm';AverageGenerationTokensPerSecond=12.5;CorrectRuns=2;Runs=3})}
        $r=Get-AIModelRecommendation $catalog $hardware general $bench
        ($r.Candidates|? Tag -eq 'llama3.2:1b').MeasuredPerformance.GenerationTokensPerSecond|Should Be 12.5
    }
    It 'rejects benchmark evidence from another machine or unrelated task' {
        $hardware=New-TestHardware -Available 12 -Disk 20
        $hardware|Add-Member CPU ([pscustomobject]@{Name=[pscustomobject]@{Value='This CPU'}})
        $bench=[pscustomobject]@{SchemaVersion='1.0';Hardware=[pscustomobject]@{CPUName='Other CPU';InstalledRAMGB=16};Summary=@([pscustomobject]@{Model='llama3.2:1b';Task='Coding';Temperature='Warm';AverageGenerationTokensPerSecond=99;CorrectRuns=1;Runs=1})}
        $r=Get-AIModelRecommendation $catalog $hardware general $bench
        ($r.Candidates|? Tag -eq 'llama3.2:1b').MeasuredPerformance|Should Be $null
    }
    It 'fails closed when RAM telemetry is unavailable' {
        $h=New-TestHardware;$h.Memory.InstalledGB.Value=$null;$h.Memory.AvailableGB.Value=$null
        (Test-AIModelCompatibility $catalog.models[0] $h).Compatible|Should Be $false
    }
    It 'exports compatible CLI JSON to a file' {
        $out=Join-Path $TestDrive 'profile.json'
        $json=& (Join-Path $repoRoot 'scripts\Profile-AI-Lab.ps1') -JsonOutput -OutputPath $out -OllamaUrl 'http://127.0.0.1:1'
        Test-Path $out|Should Be $true
        ($json|ConvertFrom-Json).Recommendations|Should Not BeNullOrEmpty
    }
    It 'runs through powershell File invocation without an early PSScriptRoot binding failure' {
        $out=Join-Path $TestDrive 'external-profile.json'
        $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repoRoot 'scripts\Profile-AI-Lab.ps1'),'-JsonOutput','-OutputPath',$out,'-OllamaUrl','http://127.0.0.1:1') -Wait -PassThru -WindowStyle Hidden
        $process.ExitCode|Should Be 0
        (Test-Path $out)|Should Be $true
    }
}
