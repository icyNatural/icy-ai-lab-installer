# Icy AI Lab Installer (v2.1.0)

Production-quality portable Windows bootstrapper and management suite for a local AI workstation.

---

## Quick Start (One-Click Setup)

1. Download and extract the latest release ZIP.
2. **Double-click `START-HERE.cmd`** in the extracted folder.
3. Click **Yes** on the Windows UAC prompt.

*No manual PowerShell execution policy commands required.*

---

## Overview & Architecture

```text
+-----------------------------------------------------------------------+
|                              WINDOWS HOST                             |
|                                                                       |
|  +---------------------+   +---------------------+   +-------------+  |
|  | Open WebUI          |   | n8n Workflows       |   | Ollama      |  |
|  | (Docker Container)  |   | (Docker Container)  |   | (Native API)|  |
|  | 127.0.0.1:3000      |   | 127.0.0.1:5678      |   | Port 11434  |  |
|  +----------+----------+   +----------+----------+   +------+------+  |
|             |                         |                     ^         |
|             +---- Docker Compose -----+                     |         |
|             |                                               |         |
|             v (host.docker.internal:11434) -----------------+         |
+-----------------------------------------------------------------------+
```

- **Host Ollama**: Native Windows inference engine with GPU/CPU acceleration.
- **Docker Compose Services**: Open WebUI (`http://localhost:3000`) and n8n (`http://localhost:5678`), bound strictly to `127.0.0.1` for local-only security.
- **Persistent Data**: Local workspace defaults to `%USERPROFILE%\AI-Lab`. Container data is stored in named Docker volumes (`open-webui-data`, `n8n-data`).

---

## Hardware Profiling, Benchmarking & Model Recommendations

The installer includes modular scripts to profile workstation hardware, benchmark model inference speeds, and automatically rank installed Ollama models:

### 1. Workstation Hardware & Model Profiler
Inspects CPU, System RAM, GPU/VRAM, Ollama version, and installed model roster:
```powershell
.\scripts\Profile-AI-Lab.ps1
```
Ranks installed models into three clear operational tiers:
- ⚡ **Fastest Model**: Lowest parameter/size footprint for instant latency.
- ⚖️ **Best Balanced Model**: Optimal speed and quality ratio for system memory.
- 💪 **Largest Practical Model**: Maximum model size that runs safely without thrashing swap memory.

### 2. Model Performance Benchmarking Utility
Measures LLM load time, sustained tokens per second, prompt processing speed, and RAM/GPU memory residency:
```powershell
.\scripts\Benchmark-AI-Lab.ps1 -Model qwen3.5:4b -Runs 3
```
- Benchmark results are automatically exported to `%USERPROFILE%\AI-Lab\logs\benchmark_<timestamp>.json` and `.csv`.

---

## Robust Systems Engineering Features (v2.1.0)

### 1. Phase-Based State Machine
The installer tracks progress across 10 durable execution phases saved in `%LOCALAPPDATA%\IcyAILab\installer-state.json`:
- `Preflight` -> `EnableWindowsFeatures` -> `AwaitingReboot` -> `VerifyWSL` -> `InstallApplications` -> `StartDocker` -> `StartServices` -> `PullModels` -> `CreateShortcuts` -> `Complete`

### 2. Persistent Installer Staging Directory
Before requesting a reboot, the installer copies runtime files (`Install-AI-Lab.ps1`, `config.json`, `docker/`, `scripts/`) to a permanent location:
```text
%LOCALAPPDATA%\IcyAILab\InstallerSource
```
`RunOnce` registry keys point to the staged copy, guaranteeing seamless auto-resume even if the Downloads directory is moved, deleted, or unmounted after reboot.

### 3. Clear 9-Stage User Experience
```text
[1/9] System checks & hardware diagnostics
[2/9] Preparing Windows features (WSL 2 & Virtual Machine Platform)
[3/9] Verifying WSL 2 Engine
[4/9] Installing applications via Winget
[5/9] Starting Docker Desktop
[6/9] Starting Open WebUI and n8n
[7/9] Configuring & pulling Ollama models
[8/9] Generating desktop shortcuts
[9/9] Final verification & status report
```

### 4. UAC Elevation & Mutex Protection
- Relaunches elevated process using `Start-Process powershell.exe -WorkingDirectory "$scriptWorkingDir" -ArgumentList "-NoExit ..."` so the window remains open and preserves working directory context.
- Global mutex (`Global\IcyAILabInstallerMutex`) prevents duplicate concurrent installer runs.

---

## Prerequisites

- **Operating System**: Windows 10 (Build 19041+) or Windows 11 (64-bit AMD64/ARM64).
- **Virtualization**: Hardware Virtualization enabled in system BIOS.
- **Package Manager**: Microsoft `winget` (included in Windows 10/11 App Installer).
- **Free Disk Space**: Minimum 15 GB free disk space.

> **Docker Desktop Licensing Note**: Docker Desktop is free for personal use, education, open-source projects, and small businesses (<250 employees and <$10M annual revenue). Commercial use in larger organizations requires a paid subscription.

---

## Ollama Model Packs

Model pack definitions and RAM recommendations are maintained in `config.json`:

| Pack Key | RAM Requirement | Est. Disk Space | Models Included |
| :--- | :--- | :--- | :--- |
| **`light`** | < 12 GB RAM | ~8.5 GB | `qwen3.5:4b`, `gemma3:4b`, `llama3.2:3b`, `nomic-embed-text` |
| **`balanced`** | 12–23 GB RAM | ~14.0 GB | `qwen3.5:4b`, `deepseek-r1:8b`, `gemma3:4b`, `qwen2.5-coder:7b`, `llama3.2:3b`, `nomic-embed-text` |
| **`coding`** | $\ge$ 16 GB RAM | ~12.5 GB | `qwen3.5:4b`, `qwen2.5-coder:7b`, `deepseek-r1:8b`, `nomic-embed-text` |

---

## Management Scripts Suite (`scripts/`)

- **Start Services**: `.\scripts\Start-AI-Lab.ps1`
- **Stop Services**: `.\scripts\Stop-AI-Lab.ps1`
- **Update Environment & Services**: `.\scripts\Update-AI-Lab.ps1`
- **Hardware Profile & Ranking**: `.\scripts\Profile-AI-Lab.ps1`
- **Benchmark Model Speeds**: `.\scripts\Benchmark-AI-Lab.ps1`
- **Backup User Data & Docker Volumes**: `.\scripts\Backup-AI-Lab.ps1`
- **Restore Archive**: `.\scripts\Restore-AI-Lab.ps1 -BackupPath "..\backups\AI-Lab-Backup-20260803-120000.zip"`
- **Non-Destructive System Repair**: `.\scripts\Repair-AI-Lab.ps1`
- **Manage Ollama Models**: `.\scripts\Manage-Models.ps1 -Action recommend`

---

## License

Distributed under the [MIT License](LICENSE).
