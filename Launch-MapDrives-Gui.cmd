@echo off
:: Double-click launcher for MapDrives-Gui.ps1.
:: - Bypasses execution policy (per-process only) and forces STA for WinForms.
:: - Launches PowerShell with a HIDDEN console so no black console band appears
::   (matters in ScreenConnect Backstage; the GUI itself is WinForms/GDI, which
::   renders fine there - the band was the console host window).
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0MapDrives-Gui.ps1"
