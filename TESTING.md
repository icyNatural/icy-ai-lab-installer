# Icy AI Lab Testing Strategy & Windows Test Plan

This document outlines the validation suite and real Windows hardware testing plan for the **Icy AI Lab Installer**.

## Automated Testing Suite (Run in CI / Local Dev)

The automated test suite validates syntax, static analysis, file formatting, and Docker Compose configurations:

1. **PowerShell Static Analysis**:
   ```powershell
   Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
   ```
2. **PowerShell AST Syntax Parsing**:
   ```powershell
   Get-ChildItem -Path . -Filter "*.ps1" -Recurse | ForEach-Object {
       [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
   }
   ```
3. **JSON Schema & Syntax Validation**:
   ```powershell
   Get-ChildItem -Path . -Filter "*.json" -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
   ```
4. **Docker Compose Configuration Check**:
   ```powershell
   docker compose -f docker/compose.yml config
   ```

---

## Real Windows Hardware Testing Matrix

The following test scenarios must be executed on a physical Windows 10/11 system before certifying public releases:

| Test Case ID | Test Scenario | Description / Steps | Expected Result | Pass/Fail Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **Clean Installation** | Run `Install-AI-Lab.ps1` on a fresh Windows 10/11 machine with default parameters. | Installs winget packages, enables WSL 2, starts Docker services, pulls models, and creates desktop shortcuts. | Status report `ExitCode` is `0` or `20`, services accessible at `http://localhost:3000` and `:5678`. |
| **TC-02** | **Reboot-Resume Engine (Accepted)** | Run installer on a machine where WSL 2 features are disabled. Accept reboot prompt (`Y`). | DISM enables features, script sets `RunOnce` registry key with full absolute path, saves state to `%TEMP%\ai_lab_install_state.json`, restarts immediately. Upon login, installer automatically resumes showing *"Resuming Icy AI Lab installation after reboot."* | RunOnce key triggers `Install-AI-Lab.ps1 -ResumedFromReboot` and finishes setup cleanly. `resumeCount` does not exceed 2. |
| **TC-03** | **Reboot-Resume Engine (Declined)** | Run installer on a machine where WSL 2 features are disabled. Decline reboot prompt (`N`). | Saves resume state, registers `RunOnce` key with absolute path, shows *"Restart Windows, then sign back in. Installation will resume automatically."*, and **stops all dependent installation work immediately**. | Exits cleanly with exit code `10`. Docker/Ollama/containers are NOT installed prior to restart. |
| **TC-04** | **UAC Self-Elevation (Accepted)** | Launch `Install-AI-Lab.ps1` from a non-elevated PowerShell process. Accept UAC prompt. | Relaunches elevated process using `Start-Process powershell.exe -Verb RunAs`. Elevated window displays *"Administrator privileges acquired. Continuing installation."* Parent process exits. | Parent process exits smoothly; elevated process completes installation. |
| **TC-05** | **UAC Self-Elevation (Denied)** | Launch `Install-AI-Lab.ps1` from a non-elevated PowerShell process. Click No/Cancel on UAC prompt. | Catch block intercepts elevation denial, writes error log, displays *"ERROR: Administrator elevation was denied or failed."* | Exits parent process cleanly with code `1`. |
| **TC-06** | **Paths with Spaces & Parentheses** | Place installer in `C:\Users\Test User\Downloads (1)\Icy AI Lab (v2)\Install-AI-Lab.ps1` and run setup. | Full absolute path resolution and argument escaping handles spaces and parentheses in UAC elevation and RunOnce keys. | Setup completes without script path binding errors. |
| **TC-07** | **Missing Source Script at Resume** | Register state file with a script path that is subsequently deleted before reboot. | On post-reboot sign-in, resume engine detects missing source file, displays exact manual recovery command, clears state. | Exits cleanly without crashing; displays clear recovery command. |
| **TC-08** | **Stale RunOnce / Loop Safeguard** | Simulate `resumeCount = 2` in `%TEMP%\ai_lab_install_state.json`. | Installer detects loop threshold, removes RunOnce key, clears state file, logs warning. | Prevents infinite reboot loops. |
| **TC-09** | **Duplicate Installer Launch** | Launch two concurrent instances of `Install-AI-Lab.ps1`. | Mutex `Global\IcyAILabInstallerMutex` prevents second process from running, displaying *"ERROR: Another instance of Icy AI Lab Installer is already running."* | Second process exits immediately with code `1`. |
| **TC-10** | **Idempotent Rerun** | Execute `Install-AI-Lab.ps1` repeatedly on an already configured workstation. | Detects existing packages and containers; reuses volumes without overwriting data or deleting Docker volumes. | Exit code `0`, no duplicate desktop shortcuts, user data preserved. |
| **TC-11** | **Low Disk Space Handling** | Run installer on a system with < 15 GB free disk space. | Log outputs disk warning, model pull evaluates estimated disk usage vs free disk, skips large model pack without crashing. | Status report records warning; installer completes with exit code `20`. |
| **TC-12** | **Backup & Restore Validation** | Run `Backup-AI-Lab.ps1`, modify user files, then run `Restore-AI-Lab.ps1`. | Backup generates valid `.zip` containing user folders & exported Docker volume tarballs. Restore validates ZIP structure, creates safety backup, and restores data. | User projects/workflows restored; Docker volumes intact. |
| **TC-13** | **Non-Destructive Repair** | Execute `scripts/Repair-AI-Lab.ps1`. | Refreshes `$env:PATH`, checks WSL status, re-verifies Docker engine, starts compose containers without `--force-recreate` or volume deletion. | All services green; zero data loss. |
