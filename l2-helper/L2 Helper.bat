@echo off
:: Launcher for L2 Helper (elevation is handled inside the script)
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0L2Helper.ps1"
