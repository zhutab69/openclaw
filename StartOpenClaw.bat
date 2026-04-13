@echo off
powershell.exe -ExecutionPolicy Bypass -File "D:\Kiro\testopenclaw\OpenClaw.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Script exited with error code: %ERRORLEVEL%
    pause
)
