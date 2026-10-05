@echo off
rem LanBeam one-click launcher: double-click this file.
rem Usage: run.bat [windows^|android^|build-windows^|build-apk^|all^|test^|doctor] [-NoUpdate]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lanbeam.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
if "%~1"=="" pause
exit /b %EXITCODE%
