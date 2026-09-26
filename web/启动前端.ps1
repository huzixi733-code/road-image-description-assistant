param(
    [int]$Port = 8080,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$taskIndex = Join-Path $PSScriptRoot 'index.html'
if (-not (Test-Path -LiteralPath $taskIndex)) { throw 'index.html was not found.' }

Add-Type -AssemblyName System.Net.Http

function Read-HttpRequest {
    param([Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream)

    $headerBuffer = [System.IO.MemoryStream]::new()
    $matchState = 0
    while ($matchState -lt 4) {
        $nextByte = $Stream.ReadByte()
        if ($nextByte -lt 0) { throw 'Client disconnected before sending complete HTTP headers.' }
        $headerBuffer.WriteByte([byte]$nextByte)
        if ($headerBuffer.Length -gt 65536) { throw 'HTTP headers are too large.' }

        switch ($matchState) {
            0 { if ($nextByte -eq 13) { $matchState = 1 } }
            1 {
                if ($nextByte -eq 10) { $matchState = 2 }
                elseif ($nextByte -ne 13) { $matchState = 0 }
            }
            2 { if ($nextByte -eq 13) { $matchState = 3 } else { $matchState = 0 } }
            3 { if ($nextByte -eq 10) { $matchState = 4 } else { $matchState = 0 } }
        }
    }

    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBuffer.ToArray())
    $headerLines = $headerText -split "`r`n"
    if ($headerLines[0] -notmatch '^(?<method>[A-Z]+)\s+(?<target>[^\s]+)\s+HTTP/') {
        throw 'Invalid HTTP request line.'
    }

    $headers = @{}
    foreach ($line in $headerLines[1..($headerLines.Count - 1)]) {
        if (-not $line) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { continue }
        $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] = $line.Substring($separator + 1).Trim()
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) {
        $contentLength = [int]$headers['content-length']
        if ($contentLength -gt 52428800) { throw 'HTTP request body is too large.' }
    }

    $body = [byte[]]::new($contentLength)
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $Stream.Read($body, $offset, $contentLength - $offset)
        if ($read -le 0) { throw 'Client disconnected while sending the request body.' }
        $offset += $read
    }

    [PSCustomObject]@{
        Method = $Matches.method
        Target = $Matches.target
        Headers = $headers
        Body = $body
    }
}

function Write-HttpResponse {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][byte[]]$Body,
        [switch]$HeadOnly
    )

    $headers = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Headers: Content-Type`r`nAccess-Control-Allow-Methods: GET, HEAD, POST, OPTIONS`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

$taskListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$taskListener.Start()

$taskHttpHandler = [System.Net.Http.HttpClientHandler]::new()
$taskHttpHandler.UseProxy = $false
$taskHttpClient = [System.Net.Http.HttpClient]::new($taskHttpHandler)
$taskHttpClient.Timeout = [TimeSpan]::FromMinutes(10)

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
        $taskStream = $null
        try {
            $taskStream = $taskClient.GetStream()
            $taskRequest = Read-HttpRequest -Stream $taskStream
            $taskMethod = $taskRequest.Method
            $taskPath = ([System.Uri]::UnescapeDataString($taskRequest.Target)).Split('?')[0]

            if ($taskMethod -eq 'OPTIONS') {
                Write-HttpResponse -Stream $taskStream -StatusCode 204 -Reason 'No Content' `
                    -ContentType 'text/plain; charset=utf-8' -Body ([byte[]]::new(0))
            } elseif ($taskPath -in @('/', '/index.html') -and $taskMethod -in @('GET', 'HEAD')) {
                $taskBody = [System.IO.File]::ReadAllBytes($taskIndex)
                Write-HttpResponse -Stream $taskStream -StatusCode 200 -Reason 'OK' `
                    -ContentType 'text/html; charset=utf-8' -Body $taskBody -HeadOnly:($taskMethod -eq 'HEAD')
            } elseif ($taskPath -in @('/api/chat', '/api/tags', '/api/version') -and $taskMethod -in @('GET', 'POST')) {
                $taskProxyRequest = $null
                $taskProxyResponse = $null
                try {
                    $taskProxyUri = "http://127.0.0.1:11434$taskPath"
                    $taskProxyRequest = [System.Net.Http.HttpRequestMessage]::new(
                        [System.Net.Http.HttpMethod]::new($taskMethod),
                        $taskProxyUri
                    )
                    if ($taskRequest.Body.Length -gt 0) {
                        $taskProxyRequest.Content = [System.Net.Http.ByteArrayContent]::new($taskRequest.Body)
                        $taskProxyRequest.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
                    }
                    $taskProxyResponse = $taskHttpClient.SendAsync($taskProxyRequest).GetAwaiter().GetResult()
                    $taskBody = $taskProxyResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $taskType = if ($taskProxyResponse.Content.Headers.ContentType) {
                        $taskProxyResponse.Content.Headers.ContentType.ToString()
                    } else {
                        'application/json; charset=utf-8'
                    }
                    Write-HttpResponse -Stream $taskStream -StatusCode ([int]$taskProxyResponse.StatusCode) `
                        -Reason $taskProxyResponse.ReasonPhrase -ContentType $taskType -Body $taskBody
                } finally {
                    if ($taskProxyResponse) { $taskProxyResponse.Dispose() }
                    if ($taskProxyRequest) { $taskProxyRequest.Dispose() }
                }
            } else {
                $taskBody = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
                Write-HttpResponse -Stream $taskStream -StatusCode 404 -Reason 'Not Found' `
                    -ContentType 'text/plain; charset=utf-8' -Body $taskBody -HeadOnly:($taskMethod -eq 'HEAD')
            }
        } catch {
            if ($taskStream -and $taskStream.CanWrite) {
                $taskErrorBody = [System.Text.Encoding]::UTF8.GetBytes((@{ error = $_.Exception.Message } | ConvertTo-Json -Compress))
                try {
                    Write-HttpResponse -Stream $taskStream -StatusCode 502 -Reason 'Bad Gateway' `
                        -ContentType 'application/json; charset=utf-8' -Body $taskErrorBody
                } catch {}
            }
        } finally {
            if ($taskStream) { $taskStream.Dispose() }
            $taskClient.Dispose()
        }
    }
} finally {
    $taskHttpClient.Dispose()
    $taskHttpHandler.Dispose()
    $taskListener.Stop()
}
