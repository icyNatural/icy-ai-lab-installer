# Changelog

All notable changes to the **Icy AI Lab Installer** project will be documented in this file.

## [2.1.0] - 2.1.0 End-to-End Resilience & State Machine Overhaul

### Added
- **Top-Level Launcher (`START-HERE.cmd` & `START-HERE.ps1`)**: Enables one-click launch from Windows Explorer without manual PowerShell execution policy commands.
- **Durable Installer Staging Directory (`%LOCALAPPDATA%\IcyAILab\InstallerSource`)**: Automatically copies installer source files before reboot, insulating RunOnce execution from moved or deleted Downloads folders.
- **Phase-Based State Machine (`%LOCALAPPDATA%\IcyAILab\installer-state.json`)**: Tracks 10 distinct setup phases (`Preflight`, `EnableWindowsFeatures`, `AwaitingReboot`, `VerifyWSL`, `InstallApplications`, `StartDocker`, `StartServices`, `PullModels`, `CreateShortcuts`, `Complete`).
- **9-Stage UX Progress Display**: Clear stage progress banners (`[1/9]` to `[9/9]`) and exit status banners.
- **Automated Pester Test Suite (`tests/Installer.Tests.ps1`)**: Unit and integration tests covering path quoting, state serialization, reboot thresholds, RAM pack recommendations, and localhost Docker spec bindings.
- **Desktop Recovery Shortcut**: Generates `Resume AI Lab Setup.lnk` on desktop if post-reboot auto-resume requires manual retry.

### Fixed
- **WSL Reboot Loop Issue**: Verified feature enablement before prompting reboot; cleared RunOnce registry entries on resume; added 2-reboot safeguard limit.
- **UAC Elevation Window Retention**: Added `-NoExit` and `-WorkingDirectory "$scriptWorkingDir"` to ensure elevated windows stay open and preserve working directory context.
- **Path Quoting**: Escaped paths containing spaces, apostrophes, ampersands, and parentheses across UAC elevation and RunOnce keys.

## [2.0.0] - 2.0.0 Architecture Overhaul

### Added
- UAC self-elevation, WSL 2 reboot-resume, management scripts (`Backup`, `Restore`, `Repair`, `Manage-Models`), status report JSON, and CI workflows.
