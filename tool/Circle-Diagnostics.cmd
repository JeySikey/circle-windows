@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose_windows.ps1" -Executable "%~dp0..\circle_windows.exe"
echo.
echo Report: %%LOCALAPPDATA%%\Circle\diagnostics\last-launch-report.txt
echo Please review the report before sharing it.
pause
