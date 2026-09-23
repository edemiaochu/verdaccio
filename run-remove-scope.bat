@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0..\ps1emove-scope.ps1" %*
pause
