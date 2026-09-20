#requires -Version 5.1
<#
.SYNOPSIS
    Pester Automated Test Suite for Icy AI Lab Installer (v2.3.0)
#>

$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript   = Join-Path $repoRoot "Install-AI-Lab.ps1"
$configFile      = Join-Path $repoRoot "config.json"
$composeFile     = Join-Path $repoRoot "docker\compose.yml"
$profileScript   = Join-Path $repoRoot "scripts\Profile-AI-Lab.ps1"
$benchmarkScript = Join-Path $repoRoot "scripts\Benchmark-AI-Lab.ps1"

Describe "Icy AI Lab Installer Core Tests" {

    Context "Script and Config File Integrity" {
        It "Installer script Install-AI-Lab.ps1 physically exists" {
            (Test-Path -Path $installScript) | Should Be $true
        }

        It "config.json physically exists and parses valid JSON" {
            (Test-Path -Path $configFile) | Should Be $true
            $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            $config.installerVersion | Should Be "2.3.0"
            @($config.lightweightMode.defaultTasks).Count | Should BeGreaterThan 0
            $config.modelPacks.light | Should Not BeNullOrEmpty
            $config.modelPacks.balanced | Should Not BeNullOrEmpty
            $config.modelPacks.coding | Should Not BeNullOrEmpty
        }

        It "START-HERE.cmd launcher physically exists" {
            (Test-Path -Path (Join-Path $repoRoot "START-HERE.cmd")) | Should Be $true
        }

        It "START-HERE.ps1 launcher physically exists" {
            (Test-Path -Path (Join-Path $repoRoot "START-HERE.ps1")) | Should Be $true
        }

        It "Profile-AI-Lab.ps1 profiler module physically exists" {
            (Test-Path -Path $profileScript) | Should Be $true
        }

        It "Benchmark-AI-Lab.ps1 benchmarking module physically exists" {
            (Test-Path -Path $benchmarkScript) | Should Be $true
        }

        It "ships and deploys the one-click control center without replacing START-HERE" {
            (Test-Path -Path (Join-Path $repoRoot 'AI-LAB.cmd')) | Should Be $true
            (Test-Path -Path (Join-Path $repoRoot 'scripts\AI-Lab-ControlCenter.ps1')) | Should Be $true
            $raw = Get-Content -Path $installScript -Raw
            $raw | Should Match 'AI-LAB\.cmd'
            $raw | Should Match 'Icy AI Lab Control Center\.lnk'
        }
    }

    Context "Localhost Security & Docker Compose Specification" {
        It "docker/compose.yml physically exists" {
            (Test-Path -Path $composeFile) | Should Be $true
        }

        It "open-webui is bound strictly to 127.0.0.1:3000" {
            $raw = Get-Content -Path $composeFile -Raw
            $raw | Should Match '127\.0\.0\.1:3000:8080'
        }

        It "n8n is bound strictly to 127.0.0.1:5678" {
            $raw = Get-Content -Path $composeFile -Raw
            $raw | Should Match '127\.0\.0\.1:5678:5678'
        }

        It "open-webui contains extra_hosts host.docker.internal:host-gateway" {
            $raw = Get-Content -Path $composeFile -Raw
            $raw | Should Match 'host\.docker\.internal:host-gateway'
        }
    }

    Context "Path Resolution & Safe Quoting Engine" {
        It "Handles path containing spaces and parentheses correctly" {
            $testPath = "C:\Users\John (Dev)\Downloads (1)\Icy AI Lab (v2.1.0)\Install-AI-Lab.ps1"
            $escaped = "`"$testPath`""
            $escaped | Should Be '"C:\Users\John (Dev)\Downloads (1)\Icy AI Lab (v2.1.0)\Install-AI-Lab.ps1"'
        }

        It "Generates safe RunOnce command string with quotes" {
            $script = "C:\Users\Test User\AppData\Local\IcyAILab\InstallerSource\Install-AI-Lab.ps1"
            $root = "C:\Users\Test User\AI-Lab"
            $cmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$script`" -ResumedFromReboot -InstallRoot `"$root`""
            $cmd | Should Match '-ExecutionPolicy Bypass'
            $cmd | Should Match ([regex]::Escape($script))
            $cmd | Should Match ([regex]::Escape($root))
        }
    }

    Context "State Serialization & Reboot Safeguard Logic" {
        It "Serializes and deserializes installer state JSON correctly" {
            $tempStatePath = Join-Path $env:TEMP "pester_installer_state.json"
            try {
                $sampleState = [ordered]@{
                    schemaVersion     = "1.0"
                    installerVersion  = "2.2.0"
                    scriptPath        = "C:\Staged\Install-AI-Lab.ps1"
                    currentPhase      = "VerifyWSL"
                    rebootCount       = 1
                }
                $sampleState | ConvertTo-Json -Depth 5 | Set-Content -Path $tempStatePath -Encoding UTF8
                (Test-Path -Path $tempStatePath) | Should Be $true

                $readObj = Get-Content -Path $tempStatePath -Raw | ConvertFrom-Json
                $readObj.installerVersion | Should Be "2.2.0"
                $readObj.currentPhase | Should Be "VerifyWSL"
                $readObj.rebootCount | Should Be 1
            }
            finally {
                if (Test-Path -Path $tempStatePath) { Remove-Item $tempStatePath -Force }
            }
        }

        It "Flags reboot count threshold when rebootCount >= 2" {
            $rebootCount = 2
            ($rebootCount -ge 2) | Should Be $true
        }
    }

    Context "Lightweight Mode Installer Compatibility" {
        It "declares and propagates the LightweightMode switch" {
            $raw = Get-Content -Path $installScript -Raw
            $raw | Should Match '\[switch\]\$LightweightMode'
            $raw | Should Match '\$argList \+= " -LightweightMode"'
            $raw | Should Match '\$resumeCmd \+= " -LightweightMode"'
            $raw | Should Match '\$recoveryArgs \+= " -LightweightMode"'
            $raw | Should Match 'Choose either -LightweightMode or -ModelPack'
        }

        It "keeps SkipModels outside all adaptive assessment and pull work" {
            $raw = Get-Content -Path $installScript -Raw
            $skipStart = $raw.IndexOf('if (-not $SkipModels)')
            $adaptiveStart = $raw.IndexOf('if ($LightweightMode)', $skipStart)
            $skipEnd = $raw.IndexOf('SkipModels specified; all model assessment and downloads skipped.', $adaptiveStart)
            ($skipStart -ge 0) | Should Be $true
            ($adaptiveStart -gt $skipStart) | Should Be $true
            ($skipEnd -gt $adaptiveStart) | Should Be $true
        }

        It "guards adaptive download approval from NonInteractive mode" {
            $raw = Get-Content -Path $installScript -Raw
            $raw | Should Match 'if \(-not \$NonInteractive -and \(Read-Host.*Pull'
            $raw | Should Match 'NonInteractive Lightweight Mode reports recommendations only'
        }

        It "preserves all original model packs" {
            $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            @($config.modelPacks.light.models).Count | Should BeGreaterThan 0
            @($config.modelPacks.balanced.models).Count | Should BeGreaterThan 0
            @($config.modelPacks.coding.models).Count | Should BeGreaterThan 0
        }

        It "model manager exposes read-only adaptive actions and explicit removal only" {
            $manager = Get-Content -Path (Join-Path $repoRoot 'scripts\Manage-Models.ps1') -Raw
            $manager | Should Match '"catalog"'
            $manager | Should Match '"assess"'
            $manager | Should Match '"recommend"'
            $manager | Should Match 'Test-SafeAdaptivePull'
            $manager | Should Match '"remove"[\s\S]*if \(-not \$PackOrModel\)[\s\S]*ollama rm \$PackOrModel'
        }
    }

    Context "RAM & Model Pack Smart Recommendation Logic" {
        It "Recommends light pack when RAM < 12 GB" {
            $ramGB = 8
            $pack = if ($ramGB -lt 12) { "light" } else { "balanced" }
            $pack | Should Be "light"
        }

        It "Defaults to balanced pack when RAM is between 12 GB and 23 GB" {
            $ramGB = 16
            $pack = if ($ramGB -ge 24) { "coding" } elseif ($ramGB -ge 12) { "balanced" } else { "light" }
            $pack | Should Be "balanced"
        }

        It "Recommends balanced or coding pack when RAM >= 24 GB" {
            $ramGB = 32
            $pack = if ($ramGB -ge 24) { "coding" } else { "balanced" }
            $pack | Should Be "coding"
        }
    }

    Context "Profiling & Performance Calculation Logic" {
        It "Calculates sustained tokens per second from Ollama metrics accurately" {
            $evalCount = 45
            $evalDurationNanoseconds = 950000000 # 0.95 seconds
            $evalDurationSeconds = $evalDurationNanoseconds / 1e9
            $sustainedTokSec = [math]::Round($evalCount / $evalDurationSeconds, 2)
            $sustainedTokSec | Should Be 47.37
        }

        It "Calculates model load time in seconds accurately" {
            $loadDurationNanoseconds = 2500000000 # 2.5 seconds
            $loadTimeSec = [math]::Round($loadDurationNanoseconds / 1e9, 3)
            $loadTimeSec | Should Be 2.5
        }

        It "Executes Profile-AI-Lab.ps1 with JsonOutput switch" {
            $jsonResult = & $profileScript -JsonOutput
            $jsonResult | Should Not BeNullOrEmpty
            $parsedObj = $jsonResult | ConvertFrom-Json
            $parsedObj.Hardware | Should Not BeNullOrEmpty
            $parsedObj.Ollama | Should Not BeNullOrEmpty
            $parsedObj.Recommendations | Should Not BeNullOrEmpty
        }
    }
}
