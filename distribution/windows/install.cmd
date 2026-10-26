@echo off
setlocal
rem Keep Windows PowerShell modules ahead of PowerShell 7 modules for this launcher.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%PSModulePath%"
powershell.exe -NoProfile -File "%~dp0install.ps1" %*
set "exitcode=%ERRORLEVEL%"
echo.
echo Installer exit code: %exitcode%
pause
exit /b %exitcode%
