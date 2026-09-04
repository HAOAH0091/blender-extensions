@echo off
REM ============================================================
REM  HAOAH Blender Extensions - one-click release script
REM  Usage: double-click this file, or run release.bat from cmd
REM  Role:  call release.ps1 to package + update index + push,
REM         then pause once at the end (success or failure),
REM         the window will NOT close automatically.
REM  NOTE:  keep this file ASCII-only (no Chinese) to avoid
REM         cmd mangling multi-byte bytes as command separators.
REM ============================================================

chcp 65001 > nul
title HAOAH Blender Extensions Release

echo.
echo ============================================
echo    HAOAH Blender Extensions one-click release
echo ============================================
echo.

REM remember the script dir, cd to the repo root
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

REM check release.ps1 exists
if not exist "%~dp0release.ps1" (
    echo [ERROR] release.ps1 not found. Make sure this bat and the ps1 are in the same folder.
    goto :fail
)

REM call PowerShell to run release.ps1 (NoPause mode: no internal pause, this bat pauses once)
echo Running release.ps1 ...
echo --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0release.ps1" -NoPause
set "EXIT_CODE=%ERRORLEVEL%"
echo --------------------------------------------

REM judge result
if "%EXIT_CODE%"=="0" (
    echo.
    echo ============================================
    echo    [SUCCESS] Release done! Updated on GitHub.
    echo    Refresh the repo in Blender to see the new version.
    echo ============================================
    goto :pause_end
) else (
    echo.
    echo ============================================
    echo    [FAILED] Release did not finish. Exit code: %EXIT_CODE%
    echo    Check the red error message above.
    echo ============================================
    goto :pause_end
)

:pause_end
echo.
echo    Press any key to close this window...
pause > nul
exit /b %EXIT_CODE%

:fail
echo.
echo    Press any key to close this window...
pause > nul
exit /b 1
