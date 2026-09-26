param([int]$Port = 11434)

$ErrorActionPreference = 'Stop'
$taskRule = 'Qwen3-VL Road Assistant API'
$taskAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $taskAdmin) {
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    Start-Process powershell.exe -Verb RunAs -ArgumentList $taskArgs
    return
}

Get-NetFirewallRule -DisplayName $taskRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $taskRule -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
Write-Host "已允许专用网络访问 TCP $Port。" -ForegroundColor Green
Write-Host '公共网络未开放。' -ForegroundColor Cyan

