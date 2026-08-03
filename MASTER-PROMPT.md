# MASTER PROMPT — ICY AI LAB INSTALLER

Build and harden the attached repository. Do not replace it with a mockup, landing page, or conceptual answer. Edit the actual files and return the complete repository.

## Goal

Create a portable Windows 10/11 installer named **Icy AI Lab Installer**. A user downloads a GitHub Release ZIP, extracts it, runs one PowerShell installer, approves administrator access, restarts once if WSL requires it, and returns to a working local AI workstation.

## Preserve this architecture

- Ollama runs directly on Windows.
- Open WebUI runs in Docker and connects to host Ollama at `http://host.docker.internal:11434`.
- n8n runs in Docker.
- Open WebUI is at `http://localhost:3000`.
- n8n is at `http://localhost:5678`.
- Persistent data uses Docker volumes.
- The local root defaults to `%USERPROFILE%\AI-Lab`; never hardcode a username.
- Use `winget` for supported Windows applications.

## Required behavior

1. Self-elevate with UAC.
2. Detect Windows version, CPU, RAM, GPU, architecture, and free disk.
3. Validate prerequisites and explain failures clearly.
4. Enable `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`.
5. Set WSL 2 as default and update WSL.
6. Detect reboot requirements.
7. Resume after reboot using a safe per-user RunOnce mechanism.
8. Install or verify Docker Desktop, Ollama, Git, VS Code, Python 3.12, and Node.js LTS.
9. Be idempotent: safe to rerun without deleting data.
10. Create `%USERPROFILE%\AI-Lab` with projects, knowledge, outputs, workflows, backups, logs, scripts, and docker folders.
11. Start Docker Desktop and wait for its engine with a timeout and readable diagnostics.
12. Pull and start Open WebUI and n8n using Docker Compose.
13. Wait for Ollama before pulling models.
14. Offer model packs from `config.json` and show estimated disk size.
15. Recommend Light below 12 GB RAM and Balanced at 12–23 GB RAM. Never silently install giant models.
16. Continue when one model fails and report failures at the end.
17. Create desktop shortcuts for Start AI Lab, Open WebUI, and n8n.
18. Write timestamped logs plus a machine-readable status JSON.
19. Add start, stop, update, backup, restore, repair, and model-management scripts.
20. Bind services to localhost by default; do not expose them publicly.

## Default model packs

Light:
- qwen3.5:4b
- gemma3:4b
- llama3.2:3b
- nomic-embed-text

Balanced:
- qwen3.5:4b
- deepseek-r1:8b
- gemma3:4b
- qwen2.5-coder:7b
- llama3.2:3b
- nomic-embed-text

Coding:
- qwen3.5:4b
- qwen2.5-coder:7b
- deepseek-r1:8b
- nomic-embed-text

Keep model tags in `config.json`. Verify all tags against Ollama's official model library before release. A missing model must not abort the full installation.

## Security and reliability

- No secrets.
- Do not pipe arbitrary internet scripts directly into PowerShell.
- Use official package IDs and official container images.
- Quote all paths.
- Never delete Docker volumes during update or repair.
- Never change global PowerShell execution policy.
- Preserve projects, chats, workflows, and knowledge data.
- Do not add CUDA or ComfyUI to v1; make that a later optional GPU module.
- Explain Docker Desktop licensing considerations in the README.

## GitHub deliverables

- Complete installer source
- `config.json`
- Docker Compose file
- start/stop/update/backup/restore/repair/model scripts
- README and license
- PSScriptAnalyzer configuration
- GitHub Actions that validates PowerShell, JSON, and Docker Compose
- Release ZIP packaging on version tags
- Test plan for clean install, reboot-resume, rerun, failed network, low disk, Docker-not-ready, and unavailable model

## Workflow

1. Audit the supplied code and list concrete defects.
2. Fix the files directly.
3. Add automated validation and tests.
4. Run everything available in your environment.
5. State exactly what passed and what still requires a real Windows test.
6. Never claim a successful Windows install unless it was actually tested on Windows.
7. Return the complete repository, not snippets.

## Anti-Gravity instruction

Focus on PowerShell correctness, restart/resume logic, idempotency, tests, GitHub Actions, release packaging, and real file edits. Do not replace the installer with a visual prototype.

## Lovable instruction

Lovable may build a polished project website or optional installer dashboard, but the browser UI cannot install WSL, Docker Desktop, or Ollama itself. Keep PowerShell as the actual installation engine. The website should explain hardware detection, model packs, progress stages, downloads, documentation, releases, and troubleshooting without faking system access.
