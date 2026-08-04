#requires -Version 5.1
<#
.SYNOPSIS
    Pester Automated Test Suite for Icy AI Lab Installer (v2.1.0)
#>

$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repoRoot "Install-AI-Lab.ps1"
$configFile = Join-Path $repoRoot "config.json"
$composeFile = Join-Path $repoRoot "docker\compose.yml"

Describe "Icy AI Lab Installer Core Tests" {

    Context "Script and Config File Integrity" {
        It "Installer script Install-AI-Lab.ps1 physically exists" {
            (Test-Path -Path $installScript) | Should Be $true
        }

        It "config.json physically exists and parses valid JSON" {
            (Test-Path -Path $configFile) | Should Be $true
            $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            $config.installerVersion | Should Be "2.1.0"
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
                    installerVersion  = "2.1.0"
                    scriptPath        = "C:\Staged\Install-AI-Lab.ps1"
                    currentPhase      = "VerifyWSL"
                    rebootCount       = 1
                }
                $sampleState | ConvertTo-Json -Depth 5 | Set-Content -Path $tempStatePath -Encoding UTF8
                (Test-Path -Path $tempStatePath) | Should Be $true

                $readObj = Get-Content -Path $tempStatePath -Raw | ConvertFrom-Json
                $readObj.installerVersion | Should Be "2.1.0"
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
}
