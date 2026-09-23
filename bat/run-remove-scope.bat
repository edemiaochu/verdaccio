@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0remove-scope.ps1" %*
pause
