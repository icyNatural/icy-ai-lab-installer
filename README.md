# Icy AI Lab Installer

Production-quality portable Windows bootstrapper and management suite for a local AI workstation.

---

## Overview & Architecture

**Icy AI Lab** turns any Windows 10/11 machine into a local AI workspace:

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
- **Persistent Data**: Local workspace defaults to `%USERPROFILE%\AI-Lab` (never hardcodes usernames). Container data is stored in named Docker volumes (`open-webui-data`, `n8n-data`).

---

## Prerequisites

- **Operating System**: Windows 10 (Build 19041+) or Windows 11 (64-bit AMD64/ARM64).
- **Virtualization**: Hardware Virtualization enabled in system BIOS.
- **Package Manager**: Microsoft `winget` (included in Windows 10/11 App Installer).
- **Free Disk Space**: Minimum 15 GB free disk space (more recommended for large model packs).

> **Docker Desktop Licensing Note**: Docker Desktop is free for personal use, education, open-source projects, and small businesses (<250 employees and <$10M annual revenue). Commercial use in larger organizations requires a paid subscription.

---

## Quick Start Installation

1. Download and extract the latest release ZIP.
2. Open PowerShell as administrator or normal user (the script auto-elevates via UAC).
3. Execute the bootstrapper:

```powershell
.\Install-AI-Lab.ps1
```

*Note: You do not need to change your global PowerShell ExecutionPolicy. Run single commands with `-ExecutionPolicy Bypass` if prompted.*

---

## Reboot & Auto-Resume Mechanism

If WSL 2 features (`Microsoft-Windows-Subsystem-Linux` or `VirtualMachinePlatform`) were not previously enabled:
1. The installer enables the required Windows optional features via DISM.
2. It registers a temporary per-user `RunOnce` registry key (`HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce`) and saves installer state to `%TEMP%\ai_lab_install_state.json`.
3. You will be prompted to restart your computer.
4. Upon logging back into Windows, the installer **automatically resumes** from where it left off.
5. The state file and registry key are automatically cleaned up upon completion, with built-in safeguards to prevent infinite reboot loops.

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

- **Start Services**:
  ```powershell
  .\scripts\Start-AI-Lab.ps1
  ```
- **Stop Services**:
  ```powershell
  .\scripts\Stop-AI-Lab.ps1
  ```
- **Update Environment & Services**:
  ```powershell
  .\scripts\Update-AI-Lab.ps1
  ```
- **Backup User Data & Docker Volumes**:
  ```powershell
  .\scripts\Backup-AI-Lab.ps1
  ```
- **Restore Archive**:
  ```powershell
  .\scripts\Restore-AI-Lab.ps1 -BackupPath "..\backups\AI-Lab-Backup-20260803-120000.zip"
  ```
- **Non-Destructive System Repair**:
  ```powershell
  .\scripts\Repair-AI-Lab.ps1
  ```
- **Manage Ollama Models**:
  ```powershell
  .\scripts\Manage-Models.ps1 -Action list
  .\scripts\Manage-Models.ps1 -Action pull-pack -PackOrModel balanced
  ```

---

## Security & Localhost Binding

- Services are bound exclusively to `127.0.0.1` (localhost) to prevent unauthorized network exposure.
- No hardcoded paths or usernames exist in any script or configuration.
- Installation state logs and reports automatically redact sensitive tokens/secrets.

---

## License

Distributed under the [MIT License](LICENSE).
