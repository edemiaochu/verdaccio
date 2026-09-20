@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0..\ps1\remove-package.ps1" %*
pause