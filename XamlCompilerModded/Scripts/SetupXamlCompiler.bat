@echo off
set SCRIPT_DIR=%~dp0

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%SetupXamlCompiler.ps1" %*

pause
