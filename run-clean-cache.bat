@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0clean-cache.ps1"

pause
