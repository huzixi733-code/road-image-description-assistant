@echo off
chcp 65001 >nul
title 道路图片描述助手 - 手机HTTPS访问
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0启动手机HTTPS访问.ps1"
echo.
echo 手机访问服务已经停止。
pause
