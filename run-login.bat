```bat
@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0login.ps1"

pause
```