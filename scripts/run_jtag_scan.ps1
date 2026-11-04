param(
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [string]$WorkDir = 'C:\fpga\riscv_l50\jtag_identify',
    [switch]$WakeUserMode,
    [switch]$ReadConfig,
    [switch]$ReadDebug
)
$ErrorActionPreference = 'Stop'
if (([int]$WakeUserMode.IsPresent + [int]$ReadConfig.IsPresent + [int]$ReadDebug.IsPresent) -gt 1) { throw 'Choose one diagnostic mode.' }
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceLog = Join-Path $ProjectRoot 'build/jtag_identify.log'
if ($ReadConfig) { $WorkspaceLog = Join-Path $ProjectRoot 'build/jtag_config_registers.log' }
if ($ReadDebug) { $WorkspaceLog = Join-Path $ProjectRoot 'build/jtag_debug_registers.log' }
if ($WakeUserMode) {
    # Keep the original identity precheck before issuing a wakeup command.
    & $PSCommandPath -PdsRoot $PdsRoot -WorkDir $WorkDir
    $IdentityLines = Get-Content -LiteralPath $WorkspaceLog
    if (-not ($IdentityLines -match '^\s*PGL25G\s*$') -or -not ($IdentityLines -match 'The ID value is:\s*0x00511899')) {
        throw 'Wakeup requires the expected live PGL25G / 0x00511899.'
    }
    $WorkspaceLog = Join-Path $ProjectRoot 'build/jtag_wakeup.log'
}
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if ($WorkDir -match '[^\x00-\x7f]') { throw 'JTAG work directory must use ASCII characters.' }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$ScriptName = if ($WakeUserMode) { 'wake_user_mode.tcl' } else { 'scan_jtag.tcl' }
if ($ReadConfig) { $ScriptName = 'read_config_registers.tcl' }
if ($ReadDebug) { $ScriptName = 'read_debug_registers.tcl' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot $ScriptName) -Destination (Join-Path $WorkDir $ScriptName) -Force
$ExistingServer = Get-Process -Name cdt_js -ErrorAction SilentlyContinue
$LocalServer = $null
if (-not $ExistingServer) {
    $LocalServer = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_js.exe') -ArgumentList @('-work_dir',$WorkDir,'-port','65420') -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $WorkDir 'server_stdout.log') -RedirectStandardError (Join-Path $WorkDir 'server_stderr.log')
}
try {
    Push-Location $WorkDir
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& (Join-Path $PdsRoot 'bin/cdt_cfg_shell.exe') -work_dir $WorkDir -file (Join-Path $WorkDir $ScriptName) 2>&1)
        $NativeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $SavedPreference
        Pop-Location
    }
    $Output | Set-Content -LiteralPath $WorkspaceLog -Encoding utf8
    $Output | Set-Content -LiteralPath (Join-Path $WorkDir 'identify.log') -Encoding utf8
    $Output | ForEach-Object { Write-Host $_ }
    if ($NativeExit -ne 0 -or ($Output -match '^\s*E:') -or -not ($Output -match 'JTAG_IDENTIFY_END')) {
        throw "JTAG identification failed; native exit=$NativeExit; see $WorkspaceLog. No hardware was programmed."
    }
    Write-Host '[PASS] JTAG chain identified. No hardware was programmed.'
} finally {
    if ($LocalServer -and -not $LocalServer.HasExited) { Stop-Process -Id $LocalServer.Id }
}

