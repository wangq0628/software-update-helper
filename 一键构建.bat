@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "FLUTTER=D:\flutter\bin\flutter.bat"
if not exist "%FLUTTER%" set "FLUTTER=flutter"

echo ============================================
echo  软件更新助手 - Flutter Windows 绿色版构建
echo ============================================
echo.

echo [1/3] 获取 Flutter 依赖...
call "%FLUTTER%" pub get
if errorlevel 1 goto :failed

echo [2/3] 编译 Windows Release...
call "%FLUTTER%" build windows --release
if errorlevel 1 goto :failed

echo [3/3] 打包绿色目录...
set "SRC="
for %%P in ("build\windows\x64\runner\Release" "build\windows\runner\Release") do (
  if exist "%%~fP\software_update_helper.exe" set "SRC=%%~fP"
)
if "%SRC%"=="" (
  echo 找不到编译产物，请检查 build\windows 目录。
  goto :failed
)

if exist release rmdir /s /q release
mkdir release
xcopy /E /I /Y "%SRC%\*" "release\" >nul
xcopy /E /I /Y "data" "release\data" >nul
copy /Y "使用说明.txt" "release\" >nul

echo.
echo 构建完成！绿色程序在：%~dp0release
echo 整个 release 文件夹可复制到任意 Windows 电脑使用。
echo.
pause
exit /b 0

:failed
echo.
echo 构建失败。若提示缺少 MSVC / Windows SDK，请先用管理员身份安装：
echo winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
echo 安装后重新运行本脚本。
echo.
pause
exit /b 1
