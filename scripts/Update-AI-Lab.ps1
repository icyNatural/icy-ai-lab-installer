$ErrorActionPreference = "Stop"
$LabRoot = Join-Path $env:USERPROFILE "AI-Lab"
winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
Set-Location (Join-Path $LabRoot "docker")
docker compose pull
docker compose up -d
