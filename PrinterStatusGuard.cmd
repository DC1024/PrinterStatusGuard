@echo off
set "DIR=%~dp0"
if exist "%DIR%PrinterStatusGuard.exe" (
    "%DIR%PrinterStatusGuard.exe" %*
    exit /b %errorlevel%
)
if exist "%DIR%PrinterStatusGuard.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PrinterStatusGuard.ps1" %*
    exit /b %errorlevel%
)
echo PrinterStatusGuard.exe and PrinterStatusGuard.ps1 not found in same folder.
pause
exit /b 1