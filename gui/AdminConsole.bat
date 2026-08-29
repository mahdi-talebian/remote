@echo off
rem Remote Admin GUI - admin console (run on YOUR computer)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0AdminConsole.ps1"
if errorlevel 1 pause
