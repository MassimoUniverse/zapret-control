@echo off
:: Launcher for Zapret Control GUI (elevation is handled inside the script)
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ZapretGUI.ps1"
