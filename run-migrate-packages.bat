@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0migrate-packages.ps1" %*
pause
