@echo off
rem Windows-Optimizer starten - keine Installation noetig (PowerShell 5.1 + WPF aus Windows)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0WindowsOptimizer.ps1"
