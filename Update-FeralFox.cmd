@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FeralFox-Updater.ps1" -GameRoot "%~dp0." %*
set "FERALFOX_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %FERALFOX_EXIT%
