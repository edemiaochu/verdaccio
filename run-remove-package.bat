@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0remove-package.ps1" %*
pause