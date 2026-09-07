# Changelog

All notable changes to the **Icy AI Lab Installer** project will be documented in this file.

## [2.1.0] - 2.1.0 End-to-End Resilience & Model Profiling/Benchmarking Layer

### Added
- **Modular Hardware Profiler (`scripts/Profile-AI-Lab.ps1`)**: Detects CPU, RAM, GPU/VRAM (including `nvidia-smi`), Ollama version, and installed model roster.
- **Model Recommendation Engine**: Automatically ranks installed models into ⚡ *Fastest*, ⚖️ *Best Balanced*, and 💪 *Largest Practical* tiers based on hardware RAM/VRAM constraints.
- **Performance Benchmarking Utility (`scripts/Benchmark-AI-Lab.ps1`)**: Measures LLM load duration, sustained tokens/sec, prompt tokens/sec, total execution time, and RAM/GPU memory residency using microsecond-level Ollama REST API metrics. Exports JSON & CSV reports.
- **Extended `Manage-Models.ps1`**: Added `profile`, `recommend`, and `benchmark` actions to the management CLI.
- **Top-Level Launchers (`START-HERE.cmd` & `START-HERE.ps1`)**: One-click launch from Windows Explorer without manual PowerShell execution policy commands.
- **Durable Installer Staging Directory (`%LOCALAPPDATA%\IcyAILab\InstallerSource`)**: Automatically copies installer source files before reboot, insulating RunOnce execution from moved or deleted Downloads folders.
- **Phase-Based State Machine (`%LOCALAPPDATA%\IcyAILab\installer-state.json`)**: Tracks 10 distinct setup phases (`Preflight`, `EnableWindowsFeatures`, `AwaitingReboot`, `VerifyWSL`, `InstallApplications`, `StartDocker`, `StartServices`, `PullModels`, `CreateShortcuts`, `Complete`).
- **Automated Pester Test Suite (`tests/Installer.Tests.ps1`)**: Unit and integration tests covering path quoting, state serialization, reboot thresholds, RAM pack recommendations, profiler output, and benchmark metric calculations (20/20 tests passing).

### Fixed
- **WSL Reboot Loop Issue**: Verified feature enablement before prompting reboot; cleared RunOnce registry entries on resume; added 2-reboot safeguard limit.
- **UAC Elevation Window Retention**: Added `-NoExit` and `-WorkingDirectory "$scriptWorkingDir"` to ensure elevated windows stay open and preserve working directory context.

## [2.0.0] - 2.0.0 Architecture Overhaul

### Added
- UAC self-elevation, WSL 2 reboot-resume, management scripts (`Backup`, `Restore`, `Repair`, `Manage-Models`), status report JSON, and CI workflows.
