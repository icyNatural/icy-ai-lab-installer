# Changelog

All notable changes to the **Icy AI Lab Installer** project will be documented in this file.

## [2.0.0] - 2.0.0 Architecture Overhaul

### Added
- **UAC Self-Elevation**: Automatic administrative privilege escalation for DISM and WSL 2 configuration.
- **WSL 2 Reboot-Resume Engine**: Automatic `RunOnce` registry state persistence and recovery after system restarts with loop prevention safeguard.
- **Hardware Diagnostics**: CPU, core counts, RAM, GPU adapter list (noting 4GB WMI VRAM caps), and drive space detection.
- **Full Management Suite**:
  - `Backup-AI-Lab.ps1`: Non-destructive backup of user data and Docker volumes.
  - `Restore-AI-Lab.ps1`: Validated restore engine with safety backups before overwriting.
  - `Repair-AI-Lab.ps1`: Non-destructive system PATH, WSL, Docker, and Ollama repair utility.
  - `Manage-Models.ps1`: Interactive CLI for listing, pulling, and switching Ollama model packs.
- **Localhost Binding Security**: Bound Open WebUI (`3000`) and n8n (`5678`) to `127.0.0.1` explicitly.
- **Machine-Readable Status Report**: Automated `$InstallRoot\status_report.json` and timestamped file logging.
- **Desktop Shortcuts**: Automatic `.lnk` generation for starting, stopping, and opening web interfaces.
- **CI/CD Pipeline**: GitHub Actions for PSScriptAnalyzer, JSON validation, Docker Compose syntax checks, and release packaging.

### Fixed
- Fixed hardcoded paths and usernames across all scripts.
- Fixed global execution policy modification risks by running with `-ExecutionPolicy Bypass` scoped to script invocation.
- Fixed volume deletion risks during update and repair operations.
