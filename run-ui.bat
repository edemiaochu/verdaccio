@echo off
title Verdaccio Toolbox UI
echo Tips: double-click run-ui.vbs to start WITHOUT this console window.
cd /d "%~dp0ui"
node server.js
pause
