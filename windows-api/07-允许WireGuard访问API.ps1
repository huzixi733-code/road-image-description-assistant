param(
    [int]$Port = 11434,
    [string]$LocalAddress = '10.0.0.102',
    [string[]]$RemoteAddress = @('10.0.0.0/24', '172.17.0.0/16')
)

$ErrorActionPreference = 'Stop'
$taskRule = 'Road Assistant Ollama via WireGuard'
$taskAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $taskAdmin) {
    $remoteCsv = $RemoteAddress -join ','
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -LocalAddress `"$LocalAddress`" -RemoteAddress $remoteCsv"
    $taskProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $taskArgs -Wait -PassThru
    exit $taskProcess.ExitCode
}

Get-NetFirewallRule -DisplayName $taskRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $taskRule -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -LocalAddress $LocalAddress `
    -RemoteAddress $RemoteAddress -Profile Any | Out-Null

Write-Host "已允许 $($RemoteAddress -join ', ') 访问 $LocalAddress`:$Port。" -ForegroundColor Green
