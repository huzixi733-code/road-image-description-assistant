$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$cloudflared = Join-Path $PSScriptRoot 'cloudflared.exe'
$webScript = Join-Path $projectRoot 'web\启动前端.ps1'
$localUrl = 'http://127.0.0.1:8080/'
$downloadUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

function Test-LocalWeb {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $localUrl -TimeoutSec 3
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $cloudflared)) {
    Write-Host '首次运行：正在下载 Cloudflare 官方便携程序……' -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $cloudflared
    $signature = Get-AuthenticodeSignature -LiteralPath $cloudflared
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Cloudflare') {
        Remove-Item -LiteralPath $cloudflared -Force -ErrorAction SilentlyContinue
        throw 'cloudflared 数字签名验证失败，已删除下载文件。'
    }
    Write-Host '[正常] Cloudflare 数字签名验证通过。' -ForegroundColor Green
}

if (-not (Test-LocalWeb)) {
    if (-not (Test-Path -LiteralPath $webScript)) { throw '网页启动脚本不存在。' }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $webScript, '-NoBrowser') `
        -WindowStyle Hidden

    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if (Test-LocalWeb) { $ready = $true; break }
    }
    if (-not $ready) { throw '电脑网页服务启动失败，请先启动 Ollama 和网页服务。' }
}

Write-Host ''
Write-Host '正在生成手机 HTTPS 地址……' -ForegroundColor Cyan
Write-Host '在手机浏览器中打开窗口显示的 https://随机名称.trycloudflare.com 地址。' -ForegroundColor Yellow
Write-Host '手机与电脑无需在同一局域网，但电脑必须保持开机联网。' -ForegroundColor Yellow
Write-Host '图片和模型请求会经 Cloudflare 加密转发；请勿把临时地址分享给他人。' -ForegroundColor Yellow
Write-Host '按 Ctrl+C 或关闭窗口后，临时地址会失效。' -ForegroundColor Yellow
Write-Host ''

& $cloudflared tunnel --no-autoupdate --url $localUrl

