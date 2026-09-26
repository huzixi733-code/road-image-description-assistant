param(
    [int]$Port = 11434,
    [switch]$AllowBrowserOrigins
)

$ErrorActionPreference = 'Stop'
$taskExe = Join-Path $PSScriptRoot 'runtime/ollama.exe'
if (-not (Test-Path -LiteralPath $taskExe)) { throw 'Ollama 运行程序不存在。' }

# Stop only this project's Ollama process so the listening address can change.
Get-Process -Name ollama -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $taskExe } |
    Stop-Process -Force

$env:OLLAMA_HOST = "0.0.0.0:$Port"
$env:OLLAMA_MODELS = Join-Path $PSScriptRoot 'models'
$env:OLLAMA_NO_CLOUD = '1'
$env:OLLAMA_CONTEXT_LENGTH = '4096'
$env:OLLAMA_FLASH_ATTENTION = '1'
$env:OLLAMA_NUM_PARALLEL = '1'
$env:OLLAMA_MAX_LOADED_MODELS = '1'
if ($AllowBrowserOrigins) {
    $env:OLLAMA_ORIGINS = '*'
} else {
    Remove-Item Env:OLLAMA_ORIGINS -ErrorAction SilentlyContinue
}

$taskLogs = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
Start-Process -FilePath $taskExe -ArgumentList 'serve' -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $taskLogs 'lan-server.out.log') `
    -RedirectStandardError (Join-Path $taskLogs 'lan-server.err.log')

$taskReady = $false
for ($taskAttempt = 0; $taskAttempt -lt 30; $taskAttempt++) {
    Start-Sleep -Seconds 1
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 2
        $taskReady = $true
        break
    } catch {}
}
if (-not $taskReady) { throw '局域网 API 启动失败，请查看 logs/lan-server.err.log。' }

$taskAddresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object {
        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        -not [System.Net.IPAddress]::IsLoopback($_)
    } |
    ForEach-Object IPAddressToString |
    Sort-Object -Unique

Write-Host ''
Write-Host 'Qwen3-VL 局域网 API 已启动' -ForegroundColor Green
Write-Host "监听地址：0.0.0.0:$Port" -ForegroundColor Cyan
foreach ($taskAddress in $taskAddresses) {
    Write-Host "局域网地址：http://${taskAddress}:$Port" -ForegroundColor Yellow
}
Write-Host '接口：POST /api/chat；GET /api/version；GET /api/tags' -ForegroundColor Cyan
Write-Host '注意：Ollama API 本身不提供访问密码，仅应在可信局域网内开放。' -ForegroundColor DarkYellow
Write-Host '如果其他设备无法连接，请以管理员身份运行“04-添加Windows防火墙规则.ps1”。' -ForegroundColor DarkYellow

