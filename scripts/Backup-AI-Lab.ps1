[CmdletBinding()]
param(
    [string]$LabRoot = (Join-Path $env:USERPROFILE "AI-Lab"),
    [string]$BackupDir = (Join-Path $env:USERPROFILE "AI-Lab\backups")
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

Write-Log "Starting backup of Icy AI Lab environment at: '$LabRoot'"

if (-not (Test-Path -Path $LabRoot)) {
    Write-Log "Lab root directory '$LabRoot' does not exist." "ERROR"
    exit 1
}

if (-not (Test-Path -Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tempStaging = Join-Path $env:TEMP "AI-Lab-Backup-Staging-$timestamp"
if (Test-Path -Path $tempStaging) { Remove-Item -Path $tempStaging -Recurse -Force }
New-Item -ItemType Directory -Path $tempStaging -Force | Out-Null

try {
    # Copy user data directories and config
    $itemsToCopy = @("projects", "knowledge", "outputs", "workflows", "config.json")
    foreach ($item in $itemsToCopy) {
        $src = Join-Path $LabRoot $item
        if (Test-Path -Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $tempStaging $item) -Recurse -Force
            Write-Log "Backed up folder/file: $item"
        }
    }

    # Backup Docker Volumes non-destructively if Docker is available
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        $volStaging = Join-Path $tempStaging "docker_volumes"
        New-Item -ItemType Directory -Path $volStaging -Force | Out-Null

        $volumes = @("open-webui-data", "n8n-data")
        foreach ($vol in $volumes) {
            Write-Log "Exporting Docker volume '$vol'..."
            $volTar = Join-Path $volStaging "$vol.tar"
            # Export volume contents to tar file
            docker run --rm -v "${vol}:/volume" -v "${volStaging}:/backup" alpine tar -cf "/backup/$vol.tar" -C /volume . *> $null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -Path $volTar)) {
                Write-Log "Successfully exported Docker volume '$vol'." "SUCCESS"
            } else {
                Write-Log "Could not export volume '$vol' via alpine container (container image pull issue or volume missing)." "WARN"
            }
        }
    } else {
        Write-Log "Docker daemon not running; skipping Docker volume export." "WARN"
    }

    # Create backup ZIP archive
    $zipPath = Join-Path $BackupDir "AI-Lab-Backup-$timestamp.zip"
    Write-Log "Compressing backup staging directory to '$zipPath'..."
    Compress-Archive -Path "$tempStaging\*" -DestinationPath $zipPath -Force

    # Validate archive existence and non-zero size
    if ((Test-Path -Path $zipPath) -and ((Get-Item $zipPath).Length -gt 0)) {
        Write-Log "Backup completed successfully! Archive: '$zipPath'" "SUCCESS"
    } else {
        Write-Log "Backup archive creation failed or returned an empty file." "ERROR"
        exit 1
    }
}
finally {
    if (Test-Path -Path $tempStaging) {
        Remove-Item -Path $tempStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
