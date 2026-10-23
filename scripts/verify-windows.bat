@echo off
REM ====================================================
REM  kty-ntfs Windows 11 Cross-Platform Validation Runner
REM ====================================================

echo Starting knowthankyew NTFS Windows 11 Verification...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-windows.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [!] VERIFICATION FAILED with error code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

echo.
echo [+] VERIFICATION PASSED cleanly!
exit /b 0
