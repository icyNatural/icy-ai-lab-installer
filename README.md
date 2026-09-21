# Icy AI Lab Installer (v2.3.0)

Production-quality portable Windows bootstrapper and management suite for a local AI workstation.

---

## Quick Start (One-Click Setup)

1. Download and extract the latest release ZIP.
2. **Double-click `START-HERE.cmd`** in the extracted folder.
3. Click **Yes** on the Windows UAC prompt.

*No manual PowerShell execution policy commands required.*

## After Installation: One-Click Control Center

Double-click **`AI-LAB.cmd`** in your installed AI Lab folder, or use the **Icy AI Lab Control Center** desktop shortcut. This opens a beginner-friendly menu; it does not reinstall anything.

```text
1. Analyze my computer
2. Find my best AI models
3. Discover and install compatible models
4. Manage AI Lab services
5. View previous benchmark reports
6. Advanced tools
7. Exit
```

Choose **Find my best AI models** to select a task, see hardware-aware recommendations, and optionally compare a small set of suitable models already installed on the computer. The comparison never downloads a model.

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

The installer includes modular scripts to profile workstation hardware, recommend catalog models by task, and benchmark installed Ollama models:

### 1. Workstation Hardware & Model Profiler
Inspects CPU, System RAM, GPU/VRAM, Ollama version, and installed model roster:
```powershell
.\scripts\Profile-AI-Lab.ps1

# Incorporate only measurements from an existing benchmark report
.\scripts\Profile-AI-Lab.ps1 -BenchmarkReportPath "$env:USERPROFILE\AI-Lab\logs\benchmark_<timestamp>.json"
```
The profile records measurement source and confidence, distinguishes installed from currently available RAM, and treats non-NVIDIA WMI VRAM as a low-confidence estimate. It reports fast everyday, balanced general, coding, automation/tool-use, retrieval, vision, and largest-comfortable categories. Recommendations are marked provisional until a matching task benchmark from the same CPU/RAM profile is supplied.

### 2. Model Performance Benchmarking Utility
Measures LLM load time, sustained tokens per second, prompt processing speed, and RAM/GPU memory residency:
```powershell
.\scripts\Benchmark-AI-Lab.ps1 -Model qwen3.5:4b -Quick

# Compare selected installed models with identical quick settings
.\scripts\Benchmark-AI-Lab.ps1 -Model qwen3.5:4b,llama3.2:3b -Quick

# Select from installed compatible models interactively
.\scripts\Benchmark-AI-Lab.ps1 -GuidedSelection -Quick

# Compare all installed completion models sequentially
.\scripts\Benchmark-AI-Lab.ps1 -AllModels -Quick

# Automatically compare up to three smaller suitable installed models
.\scripts\Benchmark-AI-Lab.ps1 -AutoSelect -Quick

# Optional repeatable task/context suite
.\scripts\Benchmark-AI-Lab.ps1 -Model qwen3.5:4b `
    -Tasks Conversation,Summarization,Coding,Extraction,Reasoning,ToolUse `
    -ContextLength 2048,4096 -Runs 3
```
- Cold runs use Ollama's non-destructive `keep_alive: 0` unload operation; warm runs follow with the model resident.
- Task correctness is recorded separately from speed. Streaming time-to-first-token, load time, prompt speed, generation speed, RAM, Ollama GPU residency/spillover, and supported NVIDIA power telemetry are exported to JSON and per-run CSV.
- Unsupported telemetry is marked unavailable; benchmark values are never synthesized.
- Benchmark reports are written as detailed JSON/CSV plus readable Markdown and compact privacy-safe text. Use Control Center option 5 to open or copy previous results.

---

## Optional Lightweight Mode

Lightweight Mode performs a quick hardware/storage assessment and recommends small, explicitly tagged models by task. It is opt-in and does **not** run a benchmark or predict performance.

```powershell
# Interactive installation: choose tasks, then approve each recommended model separately.
.\Install-AI-Lab.ps1 -LightweightMode

# Unattended assessment is safe: it reports recommendations but downloads no adaptive models.
.\Install-AI-Lab.ps1 -LightweightMode -NonInteractive

# SkipModels takes precedence and skips assessment and all model downloads.
.\Install-AI-Lab.ps1 -LightweightMode -SkipModels
```

The original `light`, `balanced`, and `coding` packs remain available with `-ModelPack`. Without Lightweight Mode, existing pack-selection behavior is unchanged.

Manage the catalog and recommendations after installation:

```powershell
.\scripts\Manage-Models.ps1 -Action catalog
.\scripts\Manage-Models.ps1 -Action assess
.\scripts\Manage-Models.ps1 -Action recommend -PackOrModel coding
.\scripts\Manage-Models.ps1 -Action pull -PackOrModel qwen2.5-coder:1.5b
```

`catalog`, `assess`, and `recommend` never download or remove models. `pull` accepts only an explicit catalog tag and fails closed if hardware/storage checks cannot approve it. `remove` remains a separate, explicit action; nothing auto-removes models.

### Actual-hardware example

A local Windows run during documentation reported an `AMD Ryzen 7 6800H with Radeon Graphics`, `15.21 GB` installed RAM (`0.75 GB` available at capture time), `Discrete` GPU mode, and `244.23 GB` free on the model volume. These are point-in-time hardware/storage telemetry values—not benchmark results. Available memory changes with workload, GPU classification can be imperfect, and a recommendation remains an estimate until the user explicitly pulls and tests a model.

### Limitations

- WMI GPU memory can be missing or inaccurate; NVIDIA telemetry is used when available.
- Catalog artifact sizes and minimums are metadata, while runtime-memory placement is a conservative estimate. A pull fails closed when current available RAM cannot cover that estimate; close memory-heavy applications and assess again.
- A recommendation does not guarantee speed, quality, context capacity, or successful execution under changing system load.
- Assessment/module/catalog failures are non-fatal in the installer and result in no adaptive downloads.

---

## Robust Systems Engineering Features (v2.3.0)

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
