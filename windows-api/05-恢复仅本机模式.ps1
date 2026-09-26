param([int]$Port = 11434)

$ErrorActionPreference = 'Stop'
$taskExe = Join-Path $PSScriptRoot 'runtime/ollama.exe'
Get-Process -Name ollama -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $taskExe } |
    Stop-Process -Force
Start-Sleep -Milliseconds 500
& (Join-Path $PSScriptRoot '00-start.ps1')
Write-Host '已恢复仅本机模式：http://127.0.0.1:11434' -ForegroundColor Green

