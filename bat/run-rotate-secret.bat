@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0..\ps1\rotate-secret.ps1"

pause