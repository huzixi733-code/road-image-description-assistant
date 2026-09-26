param([string]$Model = "qwen3-vl:8b-instruct-q4_K_M")
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '00-start.ps1')
& (Join-Path $PSScriptRoot 'runtime/ollama.exe') pull $Model
if ($LASTEXITCODE -ne 0) { throw '模型下载失败。' }
& (Join-Path $PSScriptRoot 'runtime/ollama.exe') show $Model
