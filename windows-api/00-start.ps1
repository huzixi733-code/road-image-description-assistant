$ErrorActionPreference = 'Stop'
$env:OLLAMA_HOST = '127.0.0.1:11434'
$env:OLLAMA_MODELS = Join-Path $PSScriptRoot 'models'
$env:OLLAMA_NO_CLOUD = '1'
$env:OLLAMA_CONTEXT_LENGTH = '6144'
$env:OLLAMA_FLASH_ATTENTION = '1'
$env:OLLAMA_NUM_PARALLEL = '1'
$env:OLLAMA_MAX_LOADED_MODELS = '1'
$taskExe = Join-Path $PSScriptRoot 'runtime/ollama.exe'
if (-not (Test-Path -LiteralPath $taskExe)) { throw 'Ollama runtime installation is incomplete.' }
try { $null = Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 3; return } catch {}
$taskLogs = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
Start-Process -FilePath $taskExe -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskLogs 'server.out.log') -RedirectStandardError (Join-Path $taskLogs 'server.err.log')
for ($taskAttempt = 0; $taskAttempt -lt 30; $taskAttempt++) {
    Start-Sleep -Seconds 1
    try { $null = Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 2; return } catch {}
}
throw 'Ollama failed to start. See logs/server.err.log.'
