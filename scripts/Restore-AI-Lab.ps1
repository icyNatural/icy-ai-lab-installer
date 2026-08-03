[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BackupPath,
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Log([string]$Message, [string]$Level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $formatted -ForegroundColor Red }
        "WARN"    { Write-Host $formatted -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formatted -ForegroundColor Green }
        default   { Write-Host $formatted -ForegroundColor Cyan }
    }
}

Write-Log "Starting restoration of Icy AI Lab environment from: '$BackupPath'"

if (-not (Test-Path -Path $BackupPath)) {
    Write-Log "Specified backup archive '$BackupPath' does not exist." "ERROR"
    exit 1
}

# Validate Archive Structure
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($BackupPath)
    $entries = $zip.Entries.FullName
    $zip.Dispose()

    if ($entries.Count -eq 0) {
        Write-Log "Backup archive '$BackupPath' is empty." "ERROR"
        exit 1
    }
    Write-Log "Archive validation passed. Total entries: $($entries.Count)." "SUCCESS"
}
catch {
    Write-Log "Failed to parse ZIP archive '$BackupPath': $_" "ERROR"
    exit 1
}

# Create Safety Backup of current state if $LabRoot exists
if (Test-Path -Path $LabRoot) {
    Write-Log "Creating pre-restore safety backup of existing '$LabRoot'..."
    $safetyBackupScript = Join-Path $PSScriptRoot "Backup-AI-Lab.ps1"
    if (Test-Path -Path $safetyBackupScript) {
        & $safetyBackupScript -LabRoot $LabRoot
    }
}

$tempExtract = Join-Path $env:TEMP "AI-Lab-Restore-Staging-$((Get-Date).Ticks)"
New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

try {
    Write-Log "Extracting backup archive..."
    Expand-Archive -Path $BackupPath -DestinationPath $tempExtract -Force

    # Restore user files
    $itemsToRestore = @("projects", "knowledge", "outputs", "workflows", "config.json")
    foreach ($item in $itemsToRestore) {
        $src = Join-Path $tempExtract $item
        if (Test-Path -Path $src) {
            $dest = Join-Path $LabRoot $item
            if (Test-Path -Path $dest) {
                Write-Log "Updating existing item '$item'..."
            }
            Copy-Item -Path $src -Destination $LabRoot -Recurse -Force
            Write-Log "Restored item '$item' to '$LabRoot'." "SUCCESS"
        }
    }

    # Restore Docker Volumes if present in archive
    $volStaging = Join-Path $tempExtract "docker_volumes"
    if (Test-Path -Path $volStaging) {
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            $volumes = @("open-webui-data", "n8n-data")
            foreach ($vol in $volumes) {
                $volTar = Join-Path $volStaging "$vol.tar"
                if (Test-Path -Path $volTar) {
                    Write-Log "Restoring Docker volume '$vol' from tarball..."
                    # Ensure Docker volume exists without destroying it
                    docker volume create $vol *> $null
                    docker run --rm -v "${vol}:/volume" -v "${volStaging}:/backup" alpine sh -c "tar -xf /backup/$vol.tar -C /volume" *> $null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Restored Docker volume '$vol' successfully." "SUCCESS"
                    } else {
                        Write-Log "Could not restore Docker volume '$vol'." "WARN"
                    }
                }
            }
        } else {
            Write-Log "Docker daemon is not active; skipped Docker volume restoration." "WARN"
        }
    }

    Write-Log "Restoration completed successfully!" "SUCCESS"
}
finally {
    if (Test-Path -Path $tempExtract) {
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
