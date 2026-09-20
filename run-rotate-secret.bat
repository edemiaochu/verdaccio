@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0rotate-secret.ps1"

pause