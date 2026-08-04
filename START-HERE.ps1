#requires -Version 5.1
<#
.SYNOPSIS
    Icy AI Lab Quick Launcher (PowerShell)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetScript = Join-Path $scriptDir "Install-AI-Lab.ps1"

if (-not (Test-Path -Path $targetScript)) {
    Write-Host "ERROR: Install-AI-Lab.ps1 was not found in '$scriptDir'." -ForegroundColor Red
    Write-Host "Please ensure all files were extracted from the release ZIP archive." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}

& "$targetScript" @args
