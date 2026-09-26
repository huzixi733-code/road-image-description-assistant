param(
    [int]$Port = 8080,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$taskIndex = Join-Path $PSScriptRoot 'index.html'
if (-not (Test-Path -LiteralPath $taskIndex)) { throw 'index.html was not found.' }

$taskListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$taskListener.Start()

$taskLocalUrl = "http://127.0.0.1:$Port/"
$taskAddresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object {
        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        -not [System.Net.IPAddress]::IsLoopback($_)
    } |
    ForEach-Object IPAddressToString |
    Sort-Object -Unique

Write-Host "Local web app: $taskLocalUrl" -ForegroundColor Cyan
foreach ($taskAddress in $taskAddresses) {
    Write-Host "LAN web app: http://${taskAddress}:$Port/" -ForegroundColor Yellow
}
Write-Host 'Keep this window open. Press Ctrl+C to stop.' -ForegroundColor DarkYellow
if (-not $NoBrowser) { Start-Process $taskLocalUrl }

try {
    while ($true) {
        $taskClient = $taskListener.AcceptTcpClient()
        $taskReader = $null
        $taskStream = $null
        try {
            $taskStream = $taskClient.GetStream()
            $taskReader = [System.IO.StreamReader]::new($taskStream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $taskRequestLine = $taskReader.ReadLine()
            while (($taskHeaderLine = $taskReader.ReadLine()) -ne $null -and $taskHeaderLine -ne '') {}

            $taskMethod = ''
            $taskPath = ''
            if ($taskRequestLine -match '^(GET|HEAD)\s+([^\s]+)\s+HTTP/') {
                $taskMethod = $Matches[1]
                $taskPath = ([System.Uri]::UnescapeDataString($Matches[2])).Split('?')[0]
            }

            if ($taskPath -in @('/', '/index.html')) {
                $taskBody = [System.IO.File]::ReadAllBytes($taskIndex)
                $taskStatus = '200 OK'
                $taskType = 'text/html; charset=utf-8'
            } else {
                $taskBody = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
                $taskStatus = '404 Not Found'
                $taskType = 'text/plain; charset=utf-8'
            }

            $taskHeaders = "HTTP/1.1 $taskStatus`r`nContent-Type: $taskType`r`nContent-Length: $($taskBody.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
            $taskHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($taskHeaders)
            $taskStream.Write($taskHeaderBytes, 0, $taskHeaderBytes.Length)
            if ($taskMethod -ne 'HEAD') { $taskStream.Write($taskBody, 0, $taskBody.Length) }
            $taskStream.Flush()
        } finally {
            if ($taskReader) { $taskReader.Dispose() }
            if ($taskStream) { $taskStream.Dispose() }
            $taskClient.Dispose()
        }
    }
} finally {
    $taskListener.Stop()
}
