# Changelog

All notable changes to the **Icy AI Lab Installer** project will be documented in this file.

## [2.3.0] - One-Click Control Center and Guided Benchmarking

### Added
- `AI-LAB.cmd` beginner control center for hardware analysis, model discovery, recommendations, services, reports, and advanced tools without rerunning installation.
- Guided single-, selected-, compatible-, and automatic small-model comparisons using only installed completion models.
- Compact benchmark output plus privacy-safe Markdown and text summaries alongside detailed JSON and CSV reports.
- Evidence-based performance, correctness, cold/warm, task, and memory-residency insights.

### Safety and compatibility
- Benchmarks run sequentially, fail closed when resource availability cannot be verified, continue safely after individual model failures, and never download models.
- Models already resident before a benchmark are not unloaded; cleanup is limited to benchmark-owned model loads.
- Existing installer launchers, single-model benchmark commands, Lightweight Mode, model catalog, profiler, and management scripts remain available.

## [2.2.0] - Optional Adaptive Lightweight Mode

### Added
- Opt-in installer `-LightweightMode` with opportunistic quick hardware/storage assessment, task selection, and separate approval for every recommended model.
- `Manage-Models.ps1` `catalog`, `assess`, and task-aware `recommend` actions, plus fail-closed catalog/hardware/storage checks for explicit `pull` requests.
- Adaptive catalog/module staging and deployment, configuration defaults, compatibility tests, and a real-hardware telemetry example.

### Safety and compatibility
- `-NonInteractive -LightweightMode` is recommendation-only and never downloads adaptive models; `-SkipModels` takes precedence over all model assessment/download behavior.
- Preserved original `light`, `balanced`, and `coding` model packs and existing `-ModelPack` selection behavior.
- Recommendations never auto-remove models and do not claim benchmark or throughput results.
- Preserved UAC, reboot-resume, Docker, launcher, backup, restore, and repair workflows with Windows PowerShell 5.1/Pester 3.4 compatibility.

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
