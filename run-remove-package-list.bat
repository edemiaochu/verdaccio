@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0remove-package-list.ps1" %*
pause
