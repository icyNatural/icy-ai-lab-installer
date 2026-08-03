$ErrorActionPreference = "Stop"
$LabRoot = Join-Path $env:USERPROFILE "AI-Lab"
Set-Location (Join-Path $LabRoot "docker")
docker compose stop
