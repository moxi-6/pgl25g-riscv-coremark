param(
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [string]$WorkDir = 'C:\fpga\riscv_l50\coremark_ila_capture',
    [string]$Bitstream = '',
    [string]$Fic = '',
    [ValidateSet('1Mhz', '5Mhz', '10Mhz', '15Mhz')][string]$JtagFrequency = '1Mhz',
    [int]$Depth = 512
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if ($WorkDir -match '[^\x00-\x7f]') { throw 'Debug work directory must be ASCII.' }
$BuildDir = Join-Path $ProjectRoot 'build/coremark_ila'
if (-not $Bitstream) { $Bitstream = Join-Path $BuildDir 'atk_l50_top.sbit' }
if (-not $Fic) { $Fic = Join-Path $BuildDir 'coremark_ila.fic' }
foreach ($Path in @($Bitstream, $Fic)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing ILA artifact: $Path" }
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Sbit = Join-Path $WorkDir 'atk_l50_top.sbit'
$Smsk = Join-Path $WorkDir 'atk_l50_top.smsk'
$FicCopy = Join-Path $WorkDir 'coremark_ila.fic'
Copy-Item -LiteralPath $Bitstream -Destination $Sbit -Force
# cfg_assign_file also opens <name>.smsk next to the bitstream, so stage both.
$SmskSource = [IO.Path]::ChangeExtension($Bitstream, '.smsk')
if (-not (Test-Path -LiteralPath $SmskSource)) { throw "Missing ILA mask file: $SmskSource" }
Copy-Item -LiteralPath $SmskSource -Destination $Smsk -Force
Copy-Item -LiteralPath $Fic -Destination $FicCopy -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'program_sram.tcl') -Destination (Join-Path $WorkDir 'program_sram.tcl') -Force
$SbitSha = (Get-FileHash -LiteralPath $Sbit).Hash
$SmskSha = (Get-FileHash -LiteralPath $Smsk).Hash
$FicSha = (Get-FileHash -LiteralPath $FicCopy).Hash

# One JTAG server serves both clients. A stale server from another work dir
# would hide the cable state, so refuse to run beside anything unexpected.
$Others = @(Get-Process cdt_js, cdt_dbg, cdt_cfg_shell, cdt_ins -ErrorAction SilentlyContinue)
if ($Others.Count) { throw ('Another JTAG/debug process is active: ' + ($Others.Name -join ', ')) }

$Server = $null
$Debugger = $null
$SavedLicense = $env:PANGO_LICENSE_FILE
$SavedEnv = @{}
foreach ($Name in @('L50_SRAM_FILE', 'L50_SRAM_VERIFY_ONLY', 'L50_SRAM_SKIP_VERIFY',
        'L50_SRAM_PROGRAM_MODE', 'L50_SRAM_SKIP_STATUS', 'L50_JTAG_FREQUENCY',
        'L50_SRAM_READ_REGISTER')) {
    $SavedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name)
}
$Result = [ordered]@{ bitstream_sha256 = $SbitSha; mask_sha256 = $SmskSha; fic_sha256 = $FicSha; work_dir = $WorkDir }
try {
    $Server = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_js.exe') `
        -ArgumentList @('-work_dir', $WorkDir, '-port', '65420') -WorkingDirectory $WorkDir `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $WorkDir 'server_stdout.log') `
        -RedirectStandardError (Join-Path $WorkDir 'server_stderr.log')
    $Deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Get-NetTCPConnection -LocalPort 65420 -State Listen -ErrorAction SilentlyContinue)) {
        if ([DateTime]::UtcNow -gt $Deadline) { throw 'JTAG server did not start listening.' }
        Start-Sleep -Milliseconds 100
    }

    $env:L50_SRAM_FILE = $Sbit.Replace('\', '/')
    $env:L50_SRAM_VERIFY_ONLY = '0'
    $env:L50_SRAM_SKIP_VERIFY = '0'
    $env:L50_SRAM_PROGRAM_MODE = '1'   # Shutdown: the only mode proven to keep GOUTEN asserted.
    $env:L50_SRAM_SKIP_STATUS = '0'
    $env:L50_SRAM_READ_REGISTER = '1'
    $env:L50_JTAG_FREQUENCY = $JtagFrequency
    Push-Location $WorkDir
    try {
        $ProgramStart = [DateTime]::UtcNow
        $ProgramOutput = @(& (Join-Path $PdsRoot 'bin/cdt_cfg_shell.exe') -work_dir $WorkDir -file (Join-Path $WorkDir 'program_sram.tcl') 2>&1)
    } finally { Pop-Location }
    $Result.program_seconds = [math]::Round(([DateTime]::UtcNow - $ProgramStart).TotalSeconds, 2)
    $ProgramOutput | Set-Content -LiteralPath (Join-Path $WorkDir 'program.log') -Encoding utf8
    $ProgramText = $ProgramOutput -join "`n"
    if ($ProgramText -match '(?m)^\s*E:') { throw 'SRAM programming reported an error; see program.log.' }
    if ($ProgramText -notmatch 'SRAM_OPERATION_COMPLETE') { throw 'SRAM programming did not complete.' }
    if ($ProgramText -notmatch 'The done bit is 1') { throw 'DONE was not asserted after configuration.' }
    $StatusMatches = [regex]::Matches($ProgramText, 'Status Register:\s*0x([0-9a-fA-F]+)')
    $Result.final_status = if ($StatusMatches.Count) { [Convert]::ToUInt32($StatusMatches[$StatusMatches.Count - 1].Groups[1].Value, 16) } else { $null }
    $Gouten = [regex]::Matches($ProgramText, 'Bit 17:\s+([01])\s+gouten\b')
    $Result.gouten_asserted = if ($Gouten.Count) { $Gouten[$Gouten.Count - 1].Groups[1].Value -eq '1' } else { $null }
    Write-Host ("SRAM programmed in {0}s; done=1 gouten={1}" -f $Result.program_seconds, $Result.gouten_asserted)

    # The CPU starts CoreMark the instant DONE rises and needs ~17.8 s, so the
    # debugger session must be launched immediately and trigger on demand.
    $CaptureTcl = @"
dbg_connect -ip 127.0.0.1 -port 65420
dbg_scan_chain
dbg_read_device_id
dbg_read_status_register
dbg_list -device *
dbg_list -core *
dbg_set_cur_core -device 0 -core 0
dbg_import_fic -file $($FicCopy.Replace('\', '/')) -devid 0
dbg_add_bus -name commit_pc -channel 0-31
dbg_add_bus -name commit_instr -channel 32-63
dbg_add_bus -name commit_valid -channel 64
dbg_add_bus -name ex_valid -channel 65
dbg_add_bus -name ex_wait -channel 66
dbg_add_bus -name redirect -channel 67
dbg_add_bus -name dmem_valid -channel 68
dbg_add_bus -name dmem_ready -channel 69
dbg_add_bus -name dmem_write -channel 70
dbg_add_bus -name imem_valid -channel 71
dbg_add_bus -name imem_ready -channel 72
dbg_add_bus -name imem_rvalid -channel 73
dbg_add_bus -name fetch_valid -channel 74
dbg_add_bus -name fetch_take -channel 75
dbg_add_bus -name cycle_low -channel 76-83
dbg_add_bus -name retire_low -channel 84-91
dbg_add_all_to_waveform
dbg_add_all_to_listing
dbg_set_capture -type w -windows 1
dbg_set_capture -type w -depth $Depth -position 0
dbg_trig_immd
dbg_delay -time 6
dbg_save_project -file $($WorkDir.Replace('\', '/'))/coremark_ila_$Depth.dprj
dbg_read_status_register
dbg_disconnect
dbg_close
"@
    $CaptureTcl | Set-Content -LiteralPath (Join-Path $WorkDir 'capture_coremark_ila.tcl') -Encoding ascii
    $env:PANGO_LICENSE_FILE = 'C:\fpga\riscv_l50\licenses\provided.lic'
    $DbgLog = Join-Path $WorkDir 'capture_coremark_ila.log'
    $Debugger = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_dbg.exe') `
        -ArgumentList @('-file', ($WorkDir.Replace('\', '/') + '/capture_coremark_ila.tcl')) `
        -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $DbgLog `
        -RedirectStandardError (Join-Path $WorkDir 'capture_coremark_ila_error.log')
    $Deadline = [DateTime]::UtcNow.AddSeconds(180)
    while (-not $Debugger.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -gt $Deadline) { throw 'Debugger capture timed out.' }
    }
    $DbgText = Get-Content -LiteralPath $DbgLog -Raw
    if ($DbgText -match '(?m)^\s*E:') { throw 'Debugger reported an error; see capture_coremark_ila.log.' }
    if ($DbgText -notmatch 'Import Core: 0 OK') { throw 'FIC was not imported by the debugger.' }
    if ($DbgText -notmatch 'dbg_save_project .* successfully\.') { throw 'Capture project was not saved.' }
    if ($DbgText -notmatch 'Executing : dbg_trig_immd successfully\.') { throw 'Immediate trigger failed.' }
    if ($DbgText -notmatch 'Executing : dbg_set_capture -type w -depth \d+ -position 0 successfully\.') {
        throw 'Capture depth setup failed.'
    }
    $Project = Join-Path $WorkDir "coremark_ila_$Depth.dprj"
    $Wave = Join-Path $WorkDir "coremark_ila_$Depth.wdf"
    if (-not (Test-Path -LiteralPath $Project)) { throw 'Debugger project file missing.' }
    $Result.project = $Project
    $Result.wave = if (Test-Path -LiteralPath $Wave) { $Wave } else { $null }
    $Result.project_sha256 = (Get-FileHash -LiteralPath $Project).Hash
    $Result.wave_sha256 = if ($Result.wave) { (Get-FileHash -LiteralPath $Wave).Hash } else { $null }
    $Result.depth = $Depth
    $Result.channels = 92
    $Result.captured_at = [DateTimeOffset]::Now.ToString('o')
    Copy-Item -LiteralPath $DbgLog -Destination (Join-Path $ProjectRoot 'build/coremark_ila/capture.log') -Force
    foreach ($Ext in @('dprj', 'wdf')) {
        $Source = Join-Path $WorkDir "coremark_ila_$Depth.$Ext"
        if (Test-Path -LiteralPath $Source) {
            Copy-Item -LiteralPath $Source -Destination (Join-Path $BuildDir "coremark_ila_$Depth.$Ext") -Force
        }
    }
    # Decode the samples into named fields so the capture itself is checkable
    # evidence rather than an opaque binary the next reader must trust.
    $Decoded = & python (Join-Path $PSScriptRoot 'verify_coremark_ila.py') $Wave $Project `
        (Join-Path $BuildDir 'probe_schema.json') $BuildDir --depth $Depth
    if ($LASTEXITCODE -ne 0) { throw 'ILA sample decoding failed.' }
    $DecodeText = $Decoded -join "`n"
    $DecodeExit = $LASTEXITCODE
    $Result.decoded = ($DecodeText | ConvertFrom-Json)
    if (-not $Result.decoded.core_was_running) {
        Write-Host '[WARN] capture decoded but the core did not retire instructions in this window.'
    }
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $BuildDir 'capture_result.json') -Encoding utf8
    Write-Host ("CAPTURE_PASS project={0} wave={1} commits={2} decode_exit={3}" -f `
        $Project, $Result.wave, $Result.decoded.commit_valid_samples, $DecodeExit)
} finally {
    foreach ($Name in $SavedEnv.Keys) { Set-Item -Path "env:$Name" -Value $SavedEnv[$Name] }
    $env:PANGO_LICENSE_FILE = $SavedLicense
    if ($Debugger -and -not $Debugger.HasExited) { Stop-Process -Id $Debugger.Id -Force }
    if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id -Force }
}