@echo off
setlocal
title Icy AI Lab Control Center

set "CONTROL=%~dp0scripts\AI-Lab-ControlCenter.ps1"
if not exist "%CONTROL%" (
  echo ERROR: AI-Lab-ControlCenter.ps1 was not found in "%~dp0scripts".
  echo Keep AI-LAB.cmd with the AI Lab files, or restore the missing control-center script.
  exit /b 1
)

if exist "%~dp0status_report.json" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CONTROL%" -LabRoot "%~dp0" %*
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CONTROL%" %*
)
exit /b %ERRORLEVEL%
