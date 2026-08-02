@echo off
setlocal
where powershell.exe >nul 2>&1
if errorlevel 1 goto try_pwsh
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0TokenRader.ps1"
exit /b %errorlevel%

:try_pwsh
where pwsh.exe >nul 2>&1
if errorlevel 1 goto no_powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0TokenRader.ps1"
exit /b %errorlevel%

:no_powershell
echo Token Rader requires Windows PowerShell or PowerShell 7 in PATH.
exit /b 1
