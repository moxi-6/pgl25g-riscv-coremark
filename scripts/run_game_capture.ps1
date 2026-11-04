param(
    [string]$Port,
    [ValidateRange(30,600)][int]$TimeoutSeconds = 150,
    [string]$OutputDir
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Port) {
    $devices = @(Get-PnpDevice -PresentOnly | Where-Object {
        $_.Class -eq 'Ports' -and $_.Status -eq 'OK' -and
        $_.InstanceId -match '^USB\\VID_1A86&' -and $_.FriendlyName -match '\(COM\d+\)'
    })
    if ($devices.Count -ne 1) {throw 'Connect one CH340 USB_UART adapter or specify -Port.'}
    $Port = [regex]::Match($devices[0].FriendlyName, '\((COM\d+)\)').Groups[1].Value
}
if (-not $OutputDir) {
    $OutputDir = Join-Path $ProjectRoot ('build/uart_capture/game_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

# Open the receiver before programming so the welcome message is retained.
Write-Host '步骤 1/3：先启动串口采集（避免错过固件启动输出）。' -ForegroundColor Cyan
$CaptureScript = Join-Path $PSScriptRoot 'capture_uart.ps1'
$CaptureArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $CaptureScript),
    '-Port', $Port, '-TimeoutSeconds', $TimeoutSeconds,
    '-OutputDir', ('"{0}"' -f $OutputDir), '-CompletionMarker', '"Match: "', '-CompleteLine'
)
$Capture = Start-Process -FilePath 'powershell.exe' -ArgumentList $CaptureArgs -NoNewWindow -PassThru
Start-Sleep -Seconds 2

Write-Host '步骤 2/3：下载 game 位流到 SRAM（Shutdown 模式）。' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'program_sram.ps1') -Target cpu -FirmwareApp game | Select-Object -Last 2

Write-Host ''
Write-Host '步骤 3/3：固件已经在跑，现在轮到你操作：' -ForegroundColor Yellow
Write-Host '  - 等 LED0..LED3 中某一颗亮起；' -ForegroundColor Yellow
Write-Host '  - 立刻按下编号相同的 KEY（LED2 亮就按 KEY2），越慢分数越差；' -ForegroundColor Yellow
Write-Host '  - 10 轮后串口会打印 Match: x/10 hit、平均与最好反应时间。' -ForegroundColor Yellow
Write-Host '  - 想从第 1 轮开始：现在按一下板上 RESET（10 秒内），采集不会中断。' -ForegroundColor Yellow
Write-Host ''

$Capture.WaitForExit()
if ($Capture.ExitCode -ne 0) {
    throw "UART capture failed with exit code $($Capture.ExitCode); inspect $OutputDir/result.json."
}

$CaptureFile = Join-Path $OutputDir 'capture.txt'
if (Test-Path -LiteralPath $CaptureFile) {
    Write-Host ''
    Write-Host '================ 串口实录 ================' -ForegroundColor Green
    Get-Content -LiteralPath $CaptureFile
    Write-Host '==========================================' -ForegroundColor Green
    Write-Host "证据目录：$OutputDir"
}
