@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp004-添加Windows防火墙规则.ps1"
pause

