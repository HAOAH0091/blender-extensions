@echo off
REM ============================================================
REM  HAOAH Blender Extensions - 一键发布脚本
REM  用法: 双击本文件, 或命令行运行 release.bat
REM  功能: 调用 release.ps1 完成打包+更新索引+推送, 结束后统一暂停
REM  (成功或失败都会提示按任意键关闭, 不会自动关闭窗口)
REM ============================================================

chcp 65001 > nul
title HAOAH Blender Extensions Release

echo.
echo ============================================
echo    HAOAH Blender Extensions 一键发布
echo ============================================
echo.

REM 记录脚本所在目录, 切换到仓库根目录
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

REM 检查 release.ps1 是否存在
if not exist "%~dp0release.ps1" (
    echo [错误] 未找到 release.ps1, 请确认本 bat 与 release.ps1 在同一目录。
    goto :fail
)

REM 调用 PowerShell 执行 release.ps1(NoPause 模式: 内部不暂停, 由本 bat 统一 pause)
echo 正在执行发布脚本 release.ps1 ...
echo --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0release.ps1" -NoPause
set "EXIT_CODE=%ERRORLEVEL%"
echo --------------------------------------------

REM 判断结果
if "%EXIT_CODE%"=="0" (
    echo.
    echo ============================================
    echo    [成功] 发布完成! 已在 GitHub 上更新。
    echo    Blender 端刷新仓库即可看到新版本。
    echo ============================================
    goto :pause_end
) else (
    echo.
    echo ============================================
    echo    [失败] 发布未成功, 退出码: %EXIT_CODE%
    echo    请查看上方红色错误信息后排查。
    echo ============================================
    goto :pause_end
)

:pause_end
echo.
echo    按任意键关闭此窗口...
pause > nul
exit /b %EXIT_CODE%

:fail
echo.
echo    按任意键关闭此窗口...
pause > nul
exit /b 1
