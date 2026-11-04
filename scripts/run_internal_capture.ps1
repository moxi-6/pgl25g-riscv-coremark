param(
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [string]$WorkDir = 'C:\fpga\riscv_l50\debug_audit'
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
# The accompanying Tcl records the installed diagnostic paths explicitly.
if ($WorkDir -ne 'C:\fpga\riscv_l50\debug_audit') { throw 'Capture Tcl requires the documented diagnostic work directory.' }
$ExistingServers = @(Get-CimInstance Win32_Process -Filter "Name = 'cdt_js.exe'")
if ($ExistingServers.Count -gt 1 -or (Get-Process cdt_dbg -ErrorAction SilentlyContinue)) { throw 'Another JTAG/debug session is active.' }
if ($ExistingServers.Count -and $ExistingServers[0].CommandLine -notlike '*C:/fpga/riscv_l50/debug_audit*') { throw 'An unrelated JTAG server is active.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'capture_internal.tcl') -Destination (Join-Path $WorkDir 'capture_internal.tcl') -Force
$SetupTcl = @'
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_disconnect
cfg_close
'@
$SetupTcl | Set-Content -LiteralPath (Join-Path $WorkDir 'set_debug_frequency.tcl') -Encoding ascii
$Server = $null
$Debugger = $null
$SavedLicense = $env:PANGO_LICENSE_FILE
$OutputLog = Join-Path $WorkDir 'capture_internal_retry.log'
try {
    if (-not $ExistingServers.Count) {
        $Server = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_js.exe') -ArgumentList @('-work_dir','C:/fpga/riscv_l50/debug_audit','-port','65420') -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $WorkDir 'server_capture_stdout.log') -RedirectStandardError (Join-Path $WorkDir 'server_capture_stderr.log')
    }
    $ServerDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Get-NetTCPConnection -LocalPort 65420 -State Listen -ErrorAction SilentlyContinue)) {
        if ([DateTime]::UtcNow -gt $ServerDeadline) { throw 'JTAG server did not become ready.' }
        Start-Sleep -Milliseconds 100
    }
    Push-Location $WorkDir
    try {
        & (Join-Path $PdsRoot 'bin/cdt_cfg_shell.exe') -work_dir $WorkDir -file C:/fpga/riscv_l50/debug_audit/set_debug_frequency.tcl *> (Join-Path $WorkDir 'set_debug_frequency.log')
    } finally { Pop-Location }
    $Identity = Get-Content -LiteralPath (Join-Path $WorkDir 'set_debug_frequency.log') -Raw
    if ($Identity -notmatch 'The ID value is:\s*0x00511899' -or $Identity -match '(?m)^E:') { throw 'Expected PGL25G is not readable.' }
    $env:PANGO_LICENSE_FILE = 'C:\fpga\riscv_l50\licenses\provided.lic'
    $Debugger = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_dbg.exe') -ArgumentList @('-file','C:/fpga/riscv_l50/debug_audit/capture_internal.tcl') -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $OutputLog -RedirectStandardError (Join-Path $WorkDir 'capture_internal_retry_error.log')
    $Deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $Debugger.WaitForExit(1000)) {
        $PartialOutput = Get-Content -LiteralPath $OutputLog -Raw -ErrorAction SilentlyContinue
        if ($PartialOutput -match '(?m)^E:') { throw 'Debugger command failed; see capture log.' }
        if ([DateTime]::UtcNow -gt $Deadline) { throw 'Debugger capture timed out; no samples assumed.' }
    }
    $Output = Get-Content -LiteralPath $OutputLog -Raw
    if ($Debugger.ExitCode -ne 0 -or $Output -match '(?m)^E:' -or $Output -notmatch 'Executing : dbg_save_project .* successfully\.') { throw 'Capture project was not saved successfully.' }
    Write-Host 'Debugger project saved. Sample contents still require verification.'
} finally {
    if ($Debugger -and -not $Debugger.HasExited) { Stop-Process -Id $Debugger.Id }
    if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id }
    $env:PANGO_LICENSE_FILE = $SavedLicense
    if (Test-Path -LiteralPath $OutputLog) {
        Copy-Item -LiteralPath $OutputLog -Destination (Join-Path $ProjectRoot 'build/internal_capture.log') -Force
        Get-Content -LiteralPath $OutputLog -Tail 90 | Write-Host
    }
}
