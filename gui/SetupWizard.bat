@echo off
rem Remote Admin GUI - setup wizard (run once on each employee PC, as admin)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SetupWizard.ps1"
if errorlevel 1 pause
