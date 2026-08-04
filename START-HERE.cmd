@echo off
setlocal enabledelayedexpansion
title Icy AI Lab Installer Launcher

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Install-AI-Lab.ps1"

if not exist "%PS_SCRIPT%" (
    echo ============================================================
    echo ERROR: Install-AI-Lab.ps1 was not found in:
    echo "%SCRIPT_DIR%"
    echo ============================================================
    echo Please ensure all files were extracted from the release ZIP archive.
    echo.
    pause
    exit /b 1
)

echo Launching Icy AI Lab Installer...
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*

set "EXIT_CODE=%ERRORLEVEL%"
if %EXIT_CODE% NEQ 0 (
    if %EXIT_CODE% NEQ 10 (
        echo.
        echo Installer exited with error code %EXIT_CODE%.
        pause
    )
)
