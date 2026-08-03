$ErrorActionPreference = "Stop"
$LabRoot = Join-Path $env:USERPROFILE "AI-Lab"
$DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
if (Test-Path $DockerDesktop) { Start-Process $DockerDesktop -ErrorAction SilentlyContinue }
$deadline = (Get-Date).AddMinutes(5)
do {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 5
} until ((Get-Date) -gt $deadline)
if ($LASTEXITCODE -ne 0) { throw "Docker is not ready. Open Docker Desktop and retry." }
Set-Location (Join-Path $LabRoot "docker")
docker compose up -d
Start-Process "http://localhost:3000"
Start-Process "http://localhost:5678"
