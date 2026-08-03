# Icy AI Lab Testing Strategy & Windows Test Plan

This document outlines the validation suite and real Windows hardware testing plan for the **Icy AI Lab Installer**.

## Automated Testing Suite (Run in CI / Local Dev)

The automated test suite validates syntax, static analysis, file formatting, and Docker Compose configurations:

1. **PowerShell Static Analysis**:
   ```powershell
   Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
   ```
2. **JSON Schema & Syntax Validation**:
   ```powershell
   Get-ChildItem -Path . -Filter "*.json" -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
   ```
3. **Docker Compose Configuration Check**:
   ```powershell
   docker compose -f docker/compose.yml config
   ```

---

## Real Windows Hardware Testing Matrix

The following test scenarios must be executed on a physical Windows 10/11 system before certifying public releases:

| Test Case ID | Test Scenario | Description / Steps | Expected Result | Pass/Fail Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **Clean Installation** | Run `Install-AI-Lab.ps1` on a fresh Windows 10/11 machine with default parameters. | Installs winget packages, enables WSL 2, starts Docker services, pulls models, and creates desktop shortcuts. | Status report `ExitCode` is `0` or `20`, services accessible at `http://localhost:3000` and `:5678`. |
| **TC-02** | **Reboot-Resume Engine** | Run installer on a machine where WSL 2 features are disabled. | DISM enables features, script sets `RunOnce` registry key, saves state to `%TEMP%\ai_lab_install_state.json`, prompts reboot. Upon login, installer automatically resumes. | RunOnce key triggers `Install-AI-Lab.ps1 -ResumedFromReboot` and finishes setup cleanly. `resumeCount` does not exceed 2. |
| **TC-03** | **Idempotent Rerun** | Execute `Install-AI-Lab.ps1` repeatedly on an already configured workstation. | Detects existing packages and containers; reuses volumes without overwriting data or deleting Docker volumes. | Exit code `0`, no duplicate desktop shortcuts, user data preserved. |
| **TC-04** | **Low Disk Space Handling** | Run installer on a system with < 15 GB free disk space. | Log outputs disk warning, model pull evaluates estimated disk usage vs free disk, skips large model pack without crashing. | Status report records warning; installer completes with exit code `20`. |
| **TC-05** | **Offline / Network Failure** | Disconnect network during model pull stage. | Model pull logs failure for individual model tag, continues remaining steps, finishes with partial success summary. | Installer does not abort; status report reflects failed models. |
| **TC-06** | **Docker Inactive Startup** | Kill Docker Desktop daemon before running `scripts/Start-AI-Lab.ps1`. | Script launches `Docker Desktop.exe`, polls `docker info` up to 180s, starts containers once daemon becomes responsive. | Containers start successfully after daemon spin-up; browser tabs open automatically. |
| **TC-07** | **Backup & Restore Validation** | Run `Backup-AI-Lab.ps1`, modify user files, then run `Restore-AI-Lab.ps1`. | Backup generates valid `.zip` containing user folders & exported Docker volume tarballs. Restore validates ZIP structure, creates safety backup, and restores data. | User projects/workflows restored; Docker volumes intact. |
| **TC-08** | **Non-Destructive Repair** | Execute `scripts/Repair-AI-Lab.ps1`. | Refreshes `$env:PATH`, checks WSL status, re-verifies Docker engine, starts compose containers without `--force-recreate` or volume deletion. | All services green; zero data loss. |
