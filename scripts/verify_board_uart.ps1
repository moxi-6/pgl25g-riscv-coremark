param(
    [string]$Port,
    [ValidateRange(1, 10)][int]$ExpectedRuns = 2,
    [ValidateRange(5, 300)][int]$TimeoutSeconds = 60,
    [string]$OutputDir
)
$ErrorActionPreference = 'Stop'
# Board CH340 only: COM23/24 belong to the JTAG cable, not the FPGA UART.
$devices = @(Get-PnpDevice -PresentOnly | Where-Object {
    $_.Class -eq 'Ports' -and $_.Status -eq 'OK' -and
    $_.InstanceId -match '^USB\\VID_1A86&' -and $_.FriendlyName -match '\(COM\d+\)'
})
$ports = @($devices | ForEach-Object {
    [regex]::Match($_.FriendlyName, '\((COM\d+)\)').Groups[1].Value
})
if (-not $Port) {
    if ($ports.Count -ne 1) { throw "Expected one connected CH340 serial port; found $($ports.Count). Connect USB_UART, or specify -Port when multiple CH340 adapters are present." }
    $Port = $ports[0]
}
if ($Port -notin $ports) { throw "$Port is not a connected CH340 port. JTAG cable and Bluetooth ports are not accepted." }
if (-not $OutputDir) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $OutputDir = Join-Path $projectRoot ('build/uart_capture/' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
}
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$expected = [Text.Encoding]::ASCII.GetBytes(('OK' + "`r`n") * $ExpectedRuns)
$received = [Collections.Generic.List[byte]]::new()
$serial = [IO.Ports.SerialPort]::new($Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$serial.Handshake = [IO.Ports.Handshake]::None
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$failure = $null
$watch = [Diagnostics.Stopwatch]::new()
try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $watch.Start()
    Write-Host "UART_CAPTURE_READY port=$Port baud=115200 format=8N1 expected_runs=$ExpectedRuns timeout=${TimeoutSeconds}s"
    Write-Host 'Press and release the board reset button once per run, at least one second apart. Do not power cycle (SRAM image would be lost).'
    $lastByteAt = 0
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        while ($serial.BytesToRead -gt 0) {
            $received.Add([byte]$serial.ReadByte())
            $lastByteAt = $watch.Elapsed.TotalSeconds
            if ($received.Count -gt $expected.Length) { throw 'Unexpected extra UART bytes.' }
            if ($received[$received.Count - 1] -ne $expected[$received.Count - 1]) { throw 'UART byte mismatch; see capture.bin and result.json.' }
            if ($received.Count % 4 -eq 0) { Write-Host "UART_MESSAGE_RECEIVED run=$($received.Count / 4) elapsed=$([math]::Round($watch.Elapsed.TotalSeconds, 2))s" }
        }
        if ($received.Count -eq $expected.Length -and $watch.Elapsed.TotalSeconds - $lastByteAt -ge 1) { break }
        Start-Sleep -Milliseconds 10
    }
    if ($received.Count -ne $expected.Length) { throw "UART capture timed out: received $($received.Count) of $($expected.Length) expected bytes." }
} catch {
    $failure = $_.Exception.Message
} finally {
    $watch.Stop()
    $serial.Dispose()
    [IO.File]::WriteAllBytes((Join-Path $OutputDir 'capture.bin'), $received.ToArray())
    [ordered]@{
        completed_at = [DateTimeOffset]::Now.ToString('o')
        port = $Port; baud = 115200; format = '8N1'
        expected_runs = $ExpectedRuns; received_bytes = $received.Count
        received_hex = (($received | ForEach-Object { $_.ToString('X2') }) -join ' ')
        uart_verified = ($null -eq $failure); failure = $failure
        reset_trigger = 'external; operator must confirm physical reset button use'
        scope = 'Serial byte sequence only; does not verify LED state or electrical timing'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'result.json') -Encoding utf8
}
if ($failure) { throw $failure }
Write-Host "[PASS] board_uart runs=$ExpectedRuns bytes=$($received.Count) output=$OutputDir"
