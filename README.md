# Icy AI Lab Installer

Portable Windows bootstrapper for a local AI workstation.

## Installs

- WSL 2 prerequisites
- Docker Desktop
- Ollama
- Open WebUI
- n8n
- Git
- Visual Studio Code
- Python
- Node.js
- Selectable Ollama models

The default destination uses the current Windows profile:

```text
C:\Users\<current-user>\AI-Lab
```

It does **not** save into Chad's username on another computer.

## Run

Extract the ZIP, open PowerShell in the folder, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-AI-Lab.ps1
```

Open WebUI: http://localhost:3000  
n8n: http://localhost:5678

## Before public release

This repository is a working starter that succeeded on one HP Windows machine. It still needs hardening and testing for reboot-resume, low disk space, failed downloads, Docker first-run prompts, and different GPUs.
