@echo off
title Add ARM64 + x86_64 Multi-Arch Setup for Ventoy
pushd "%~dp0"
set "DEFAULT_VTOY=%~dp0.."

echo ==================================================================
echo   Ventoy Multi-Architecture (x86_64 + ARM64) Setup Launcher
echo ==================================================================
echo.
set /p "VTOY_PATH=Enter Ventoy portable folder path [%DEFAULT_VTOY%]: "
if "%VTOY_PATH%"=="" set "VTOY_PATH=%DEFAULT_VTOY%"

set /p "DISK_NUM=Enter Target Disk Number (press Enter to auto-detect): "
if "%DISK_NUM%"=="" set "DISK_NUM=-1"

set /p "DL_ISOS=Download missing Ubuntu LTS / Win11 ARM64 / Debian / Alpine ISOs? [Y/N, default=Y]: "
if /i "%DL_ISOS%"=="" set "DL_ISOS=Y"

set /p "SETUP_QEMU=Install Portable QEMU & create x86/ARM64 test launchers? [Y/N, default=Y]: "
if /i "%SETUP_QEMU%"=="" set "SETUP_QEMU=Y"

set "EXTRA_ARGS="
if /i "%DL_ISOS%"=="Y" set "EXTRA_ARGS=%EXTRA_ARGS% -DownloadISOs"
if /i "%SETUP_QEMU%"=="Y" set "EXTRA_ARGS=%EXTRA_ARGS% -SetupQEMU"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-VentoyMultiArch.ps1" -VentoyPath "%VTOY_PATH%" -DiskNumber %DISK_NUM% %EXTRA_ARGS%
echo.
pause
popd
