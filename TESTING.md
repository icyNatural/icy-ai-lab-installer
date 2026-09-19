# Icy AI Lab Testing Strategy & Windows Test Plan (v2.2.0)

This document outlines the validation suite and real Windows hardware testing plan for the **Icy AI Lab Installer**.

## Automated Testing Suite (Run in CI / Local Dev)

The automated test suite validates syntax, static analysis, file formatting, Pester unit tests, and Docker Compose configurations:

1. **Pester Unit & Integration Tests**:
   ```powershell
   Invoke-Pester -Path .\tests -PassThru
   ```
2. **PowerShell Static Analysis**:
   ```powershell
   Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
   ```
3. **PowerShell AST Syntax Parsing**:
   ```powershell
   Get-ChildItem -Path . -Filter "*.ps1" -Recurse | ForEach-Object {
       [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
   }
   ```
4. **JSON Schema & Syntax Validation**:
   ```powershell
   Get-ChildItem -Path . -Filter "*.json" -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
   ```
5. **Docker Compose Configuration Check**:
   ```powershell
   docker compose -f docker/compose.yml config
   ```

---

## Real Windows Hardware Testing Matrix

| Test Case ID | Test Scenario | Description / Steps | Expected Result | Pass/Fail Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **One-Click START-HERE.cmd Launch** | Double-click `START-HERE.cmd` from Windows Explorer. | Resolves script directory, launches `Install-AI-Lab.ps1` with `-ExecutionPolicy Bypass`, prompts UAC. | Opens elevated setup window; requires no manual PowerShell commands. |
| **TC-02** | **Persistent Staging & Reboot-Resume** | Run installer on machine where WSL 2 features are disabled. | Copies files to `%LOCALAPPDATA%\IcyAILab\InstallerSource`, sets RunOnce key pointing to staged script, prompts reboot. Upon sign-in, resumes automatically from staged script displaying *"Resuming Icy AI Lab installation after reboot."* | Auto-resumes cleanly even if original Downloads folder was moved or deleted. |
| **TC-03** | **Reboot Declined** | Decline reboot prompt (`N`) when WSL features are newly enabled. | Saves state (`currentPhase = "AwaitingReboot"`), registers RunOnce key, displays *"Restart Windows, then sign back in. Installation will resume automatically."*, and **stops all dependent installation work immediately**. | Exits cleanly with exit code `10`. Docker/Ollama/containers are NOT installed prior to restart. |
| **TC-04** | **Reboot Threshold Safeguard** | Simulate `rebootCount = 2` in `%LOCALAPPDATA%\IcyAILab\installer-state.json`. | Installer detects loop threshold, removes RunOnce key, clears state file, creates Desktop Recovery Shortcut `Resume AI Lab Setup.lnk`. | Prevents infinite reboot loops. |
| **TC-05** | **UAC Self-Elevation & Window Retention** | Launch `Install-AI-Lab.ps1` non-elevated. Accept UAC prompt. | Relaunches elevated process using `Start-Process powershell.exe -WorkingDirectory "$scriptWorkingDir" -ArgumentList "-NoExit ..."` displaying *"Administrator privileges acquired. Continuing installation."* | Window stays open; working directory preserved. |
| **TC-06** | **Paths with Spaces & Parentheses** | Place installer in `C:\Users\Test User\Downloads (1)\Icy AI Lab (v2.1.0)\START-HERE.cmd` and run. | Full absolute path resolution and argument escaping handles spaces and parentheses in UAC elevation and RunOnce keys. | Setup completes without script path binding errors. |
| **TC-07** | **Duplicate Process Protection** | Launch two concurrent instances of `Install-AI-Lab.ps1`. | Mutex `Global\IcyAILabInstallerMutex` prevents second process from running, displaying *"ERROR: Another instance of Icy AI Lab Installer is already running."* | Second process exits immediately with code `1`. |
| **TC-08** | **Interactive Lightweight Mode** | Run with `-LightweightMode`; choose multiple tasks, decline one recommendation, approve another. | Quick assessment is wrapped as non-fatal; each task shows a recommendation and separate `[y/N]` pull consent. | Only explicitly approved, compatible models are passed to `ollama pull`; declined models are untouched. |
| **TC-09** | **Unattended Lightweight Safety** | Run with `-LightweightMode -NonInteractive`. | Configured tasks are assessed and reported without prompts. | No adaptive `ollama pull` command is issued. |
| **TC-10** | **SkipModels Precedence** | Run with `-LightweightMode -SkipModels` and repeat with `-ModelPack light -SkipModels`. | Stage 7 records that model work is skipped. | No assessment, recommendation, or model pull occurs. |
| **TC-11** | **Original Pack Compatibility** | Run without Lightweight Mode; test default RAM selection and explicit `-ModelPack light`, `balanced`, and `coding`. | Existing pack names, disk checks, duplicate detection, and pulls remain in effect. | Selected pack behavior matches v2.1; no adaptive prompt changes explicit pack content. |
| **TC-12** | **Reboot/UAC Switch Propagation** | Trigger UAC and reboot-resume with `-LightweightMode`, plus combinations of `-SkipModels`, `-ModelPack`, and `-NonInteractive`. | Generated elevation and RunOnce commands preserve every supplied compatibility switch. | Resumed behavior matches the original invocation and does not surprise-download adaptive models. |
| **TC-13** | **Assessment Failure** | Temporarily hide/corrupt the adaptive module or catalog, then run Lightweight Mode. | Installer catches the failure, logs a warning, and continues. | No adaptive pull occurs; Docker, launcher, backup, repair, and completion behavior remain intact. |
| **TC-14** | **Model Manager Read-only Actions** | Run `catalog`, `assess`, and `recommend` with Ollama stopped or absent. | Catalog/assessment/recommendation output is available without invoking pulls/removals. | Installed models remain unchanged. |
| **TC-15** | **Safe Pull Checks** | Request a catalog model with adequate space, then an unknown tag and a known model with insufficient/unavailable storage telemetry. | Explicit catalog model is checked first; unknown/unsafe requests fail closed. | Pull runs only after safe checks pass; no action ever auto-removes a model. |
| **TC-16** | **PowerShell/Pester Compatibility** | Parse scripts under Windows PowerShell 5.1 and execute tests with Pester 3.4. | No PowerShell 7-only syntax or Pester 4/5-only assertions/configuration. | Parser is clean and compatibility tests pass. |
