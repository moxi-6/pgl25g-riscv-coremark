param(
    [Parameter(Mandatory=$true)][string]$Port,
    [ValidateRange(1,600)][int]$TimeoutSeconds = 120,
    [string]$OutputDir,
    [string]$CompletionMarker,
    [switch]$CompleteLine
)
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) ('build/uart_capture/' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
}
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$received = [Collections.Generic.List[byte]]::new()
$serial = [IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake = [IO.Ports.Handshake]::None
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$watch = [Diagnostics.Stopwatch]::new()
$failure = $null
$complete = $false
$startedAt = [DateTimeOffset]::Now.ToString('o')
try {
    $serial.Open()
    $watch.Start()
    Write-Host "UART_CAPTURE_READY port=$Port baud=115200 timeout=${TimeoutSeconds}s output=$OutputDir"
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($serial.BytesToRead -gt 0) {
            $buffer = [byte[]]::new($serial.BytesToRead)
            $count = $serial.Read($buffer,0,$buffer.Length)
            for ($i=0; $i -lt $count; $i++) { $received.Add($buffer[$i]) }
            Write-Host -NoNewline ([Text.Encoding]::ASCII.GetString($buffer,0,$count))
            [IO.File]::WriteAllBytes((Join-Path $OutputDir 'capture.bin'),$received.ToArray())
            $body = [Text.Encoding]::ASCII.GetString($received.ToArray())
            if ($CompletionMarker) {
                $markerIndex = $body.IndexOf($CompletionMarker, [StringComparison]::Ordinal)
                if ($markerIndex -ge 0 -and (-not $CompleteLine -or $body.IndexOf("`n", $markerIndex) -ge 0)) {
                    $complete = $true
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 10
    }
    if ($CompletionMarker -and -not $complete) { $failure = 'UART completion marker not received before timeout.' }
} catch { $failure = $_.Exception.Message }
finally {
    $watch.Stop()
    $serial.Dispose()
    [IO.File]::WriteAllBytes((Join-Path $OutputDir 'capture.bin'),$received.ToArray())
    [IO.File]::WriteAllText((Join-Path $OutputDir 'capture.txt'),[Text.Encoding]::ASCII.GetString($received.ToArray()))
    [ordered]@{
        started_at = $startedAt; completed_at = [DateTimeOffset]::Now.ToString('o')
        port = $Port; baud = 115200; format = '8N1'; received_bytes = $received.Count
        elapsed_seconds = $watch.Elapsed.TotalSeconds
        completion_marker = $CompletionMarker; marker_received = $complete; failure = $failure
        complete_line_required = [bool]$CompleteLine
        scope = 'Raw receive only; no transmit, DTR/RTS assertion, or board reset. Does not validate benchmark results.'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'result.json') -Encoding utf8
}
if ($failure) { throw $failure }
Write-Host "UART_CAPTURE_END bytes=$($received.Count) output=$OutputDir"
