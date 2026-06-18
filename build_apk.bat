@echo off
rem 💡 强制使用 UTF-8 编码，防止终端中文乱码
chcp 65001 >nul

echo =======================================================
echo     🚀 NAS Car Player 一键全自动化打包流水线启动 🚀
echo =======================================================
echo.

rem 💡 召唤 PowerShell 瞬间抓取当前系统时间，并存入 BUILD_TIME 变量
for /f "delims=" %%a in ('powershell -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'"') do set BUILD_TIME=%%a
echo [当前锁定的出厂时间]: %BUILD_TIME%
echo.

echo 📦 [1/2] 正在编译全架构通用大包 (Fat APK)...
rem 💡 注意：在 bat 里调用 flutter 必须加 call，否则打完第一个包脚本就会闪退
call flutter build apk --release --dart-define=BUILD_TIME="%BUILD_TIME%"

echo.
echo ✂️ [2/2] 正在编译 32/64位 独立瘦身包 (Split APK)...
call flutter build apk --split-per-abi --release --dart-define=BUILD_TIME="%BUILD_TIME%"

echo.
echo =======================================================
echo   ✅ 全部编译搞定！请去 build\app\outputs\flutter-apk\ 收货！
echo =======================================================
pause