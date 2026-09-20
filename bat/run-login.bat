```bat
@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0..\ps1\login.ps1"

pause
```