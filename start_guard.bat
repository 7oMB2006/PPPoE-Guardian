@echo off
title Broadband Guard
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0broadband_guard.ps1"
echo.
pause
