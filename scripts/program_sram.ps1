param(
    [ValidateSet('bringup','cpu','probe','vendor','internal','lcd','lcd_game','shooter','mine')][string]$Target = 'bringup',
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [string]$WorkRoot = 'C:\fpga\riscv_l50\sram_program',
    [switch]$VerifyOnly,
    # Offline package gate only: do not start JTAG or touch any connected device.
    [switch]$CheckPackageOnly,
    [switch]$SkipVerify,
    [switch]$SkipStatusRead,
    [ValidateSet('Combined','ISC','Shutdown')][string]$ConfigurationMethod = 'Shutdown',
    [ValidateSet('1Mhz','5Mhz','10Mhz','15Mhz')][string]$JtagFrequency = '1Mhz',
    # cpu releases live in per-app subdirectories (board_release/cpu/<app>) because
    # two apps differ only in IMEM content and would otherwise overwrite each other.
    [ValidateSet('main','runtime_test','perf_test','perf_report','coremark','game', 'shooter', 'mine')][string]$FirmwareApp = 'perf_report',
    # Diagnostic-only opt-out from the output-enable postcondition. On this board
    # ISC/Combined can leave GOUTEN low until a power cycle. Shutdown plus non-ISC
    # readback has been verified to keep outputs enabled from a clean state.
    [switch]$ExpectHighZ
)
$ErrorActionPreference = 'Stop'
if ($Target -eq 'mine') {
    if (-not $PSBoundParameters.ContainsKey('FirmwareApp')) { $FirmwareApp = 'mine' }
    if ($FirmwareApp -ne 'mine') { throw 'The mine target requires -FirmwareApp mine.' }
}
if ($ConfigurationMethod -ne 'Shutdown' -and -not $ExpectHighZ) {
    throw 'ISC/Combined reproduced persistent GOUTEN=0 on this board. Use Shutdown; explicit -ExpectHighZ is reserved for deliberate diagnosis.'
}
if ($VerifyOnly -and $SkipVerify) { throw 'VerifyOnly and SkipVerify cannot be used together.' }
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ReleaseLeaf = if ($Target -in @('cpu','lcd_game','shooter','mine')) { "$Target/$FirmwareApp" } else { $Target }
$ReleaseDir = Join-Path $ProjectRoot "build/board_release/$ReleaseLeaf"
if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir 'release.json'))) {
    throw "No release package at $ReleaseLeaf. Build one with: run_pds.ps1 -Target cpu -Stage Bitstream -ConstraintProfile Vcc33 -FirmwareApp $FirmwareApp"
}
$Release = Get-Content -LiteralPath (Join-Path $ReleaseDir 'release.json') -Raw | ConvertFrom-Json
$Top = @{bringup='atk_l50_bringup';cpu='atk_l50_top';probe='atk_l50_io_probe';vendor='flow_led';internal='atk_l50_io_probe';lcd='atk_l50_lcd';lcd_game='atk_l50_lcd_game';shooter='atk_l50_shooter';mine='atk_l50_mine'}[$Target]
if ($Release.target -ne $Target -or $Release.top -ne $Top) { throw 'Unexpected release target.' }
if ($Target -in @('cpu','lcd_game','shooter','mine') -and $Release.firmware_app -ne $FirmwareApp) {
    throw "Release at $ReleaseLeaf declares firmware_app '$($Release.firmware_app)', expected '$FirmwareApp'."
}
foreach ($File in $Release.files) {
    $Path = Join-Path $ReleaseDir $File.file
    if ((Get-FileHash -LiteralPath $Path).Hash -ne $File.sha256) { throw "Release hash mismatch: $($File.file)" }
}
if ($Target -eq 'vendor') {
    # Separate provenance for an unchanged vendor reference, not our own build.
    $VendorProject = Get-Content -LiteralPath (Join-Path $ReleaseDir 'flow_led.pds') -Raw
    if ($Release.provenance -ne 'ATK 25G flow_led; original ZIP members individually CRC-verified' -or
        $VendorProject -notmatch '\(_device PGL25G\)' -or
        $VendorProject -notmatch '\(_package MBG324\)' -or
        $VendorProject -notmatch '\(_speedgrade -6\)') { throw 'Unexpected vendor reference device/provenance.' }
} else {
    $Timing = Get-Content -LiteralPath (Join-Path $ReleaseDir 'timing.rtr') -Raw
    if ($Timing -notmatch 'Device\s*:\s*PGL25G\s' -or $Timing -notmatch 'Design Summary\s*:\s*All Constraints Met\.') {
        throw 'Requires a PGL25G release with passing constrained post-route timing.'
    }
    if ($Target -in @('cpu','mine')) {
        $Checks = Get-Content -LiteralPath (Join-Path $ReleaseDir 'implementation_checks.json') -Raw | ConvertFrom-Json
        foreach ($Resource in @('LUT','FF','DRM')) {
            if ($Checks.mapped_resources.$Resource -le 0) { throw "Empty implementation resource: $Resource" }
        }
        if (-not $Checks.timing_checked -or -not $Checks.active_clocks.Count -or
            $Timing -notmatch '(?m)^Startpoint\s*:\s*\S+' -or
            $Timing -notmatch '(?m)^Path Class\s*:\s*sequential timing path') {
            throw 'Release lacks verified active clocks and real sequential timing paths.'
        }
        foreach ($Kind in @('Setup_Slow_endpoints','Setup_Fast_endpoints','Hold_Slow_endpoints','Hold_Fast_endpoints')) {
            if ($Checks.constrained_endpoints.$Kind -le 0) { throw "Release lacks constrained endpoints: $Kind" }
        }
        foreach ($Pair in @(@('device_map.log','map_log_sha256'), @('timing.rtr','timing_report_sha256'), @('timing.log','timing_log_sha256'))) {
            if ((Get-FileHash -LiteralPath (Join-Path $ReleaseDir $Pair[0])).Hash -ne $Checks.($Pair[1])) {
                throw "Implementation evidence hash mismatch: $($Pair[0])"
            }
        }
    }
}
if ($CheckPackageOnly) {
    Write-Host "[PASS] $Target release package passed offline checks. No JTAG connection or programming was performed."
    return
}
# Identify the live board again before allowing any SRAM write.
& (Join-Path $PSScriptRoot 'run_jtag_scan.ps1') -PdsRoot $PdsRoot
$Scan = Get-Content -LiteralPath (Join-Path $ProjectRoot 'build/jtag_identify.log')
if (-not ($Scan -match '^\s*PGL25G\s*$') -or -not ($Scan -match 'The ID value is:\s*0x00511899')) {
    throw 'Live FPGA identity is not the expected PGL25G; SRAM write stopped.'
}
$WorkDir = [IO.Path]::GetFullPath((Join-Path $WorkRoot $Target))
if ($WorkDir -match '[^\x00-\x7f]') { throw 'SRAM work directory must use ASCII characters.' }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Bitstream = Join-Path $WorkDir "$Top.sbit"
Copy-Item -LiteralPath (Join-Path $ReleaseDir "$Top.sbit") -Destination $Bitstream -Force
Copy-Item -LiteralPath (Join-Path $ReleaseDir "$Top.smsk") -Destination (Join-Path $WorkDir "$Top.smsk") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'program_sram.tcl') -Destination (Join-Path $WorkDir 'program_sram.tcl') -Force
$BeforeEnv = $env:L50_SRAM_FILE
$BeforeVerify = $env:L50_SRAM_VERIFY_ONLY
$BeforeSkipVerify = $env:L50_SRAM_SKIP_VERIFY
$BeforeMethod = $env:L50_SRAM_PROGRAM_MODE
$BeforeStatusRead = $env:L50_SRAM_SKIP_STATUS
$BeforeFrequency = $env:L50_JTAG_FREQUENCY
$BeforeReadRegister = $env:L50_SRAM_READ_REGISTER
$LocalServer = $null
if (-not (Get-Process -Name cdt_js -ErrorAction SilentlyContinue)) {
    $LocalServer = Start-Process -FilePath (Join-Path $PdsRoot 'bin/cdt_js.exe') -ArgumentList @('-work_dir',$WorkDir,'-port','65420') -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $WorkDir 'server_stdout.log') -RedirectStandardError (Join-Path $WorkDir 'server_stderr.log')
}
try {
    $env:L50_SRAM_FILE = $Bitstream.Replace('\','/')
    $env:L50_SRAM_VERIFY_ONLY = if ($VerifyOnly) { '1' } else { '0' }
    $env:L50_SRAM_SKIP_VERIFY = if ($SkipVerify) { '1' } else { '0' }
    $env:L50_SRAM_PROGRAM_MODE = @{Combined='3';ISC='2';Shutdown='1'}[$ConfigurationMethod]
    $env:L50_SRAM_SKIP_STATUS = if ($SkipStatusRead) { '1' } else { '0' }
    $env:L50_SRAM_READ_REGISTER = if ($SkipStatusRead) { '0' } else { '1' }
    $env:L50_JTAG_FREQUENCY = $JtagFrequency
    Push-Location $WorkDir
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& (Join-Path $PdsRoot 'bin/cdt_cfg_shell.exe') -work_dir $WorkDir -file (Join-Path $WorkDir 'program_sram.tcl') 2>&1)
        $NativeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $SavedPreference
        Pop-Location
    }
    $Output | Set-Content -LiteralPath (Join-Path $ProjectRoot "build/${Target}_sram_program.log") -Encoding utf8
    $Output | Set-Content -LiteralPath (Join-Path $WorkDir 'program.log') -Encoding utf8
    $Output | ForEach-Object { Write-Host $_ }
    $ProgramDone = [bool]($Output -match '^The done bit is 1\s*$')
    $StatusMatches = [regex]::Matches(($Output -join "`n"), 'Status Register:\s*0x([0-9a-fA-F]+)')
    $FinalStatus = if ($StatusMatches.Count) { [Convert]::ToUInt32($StatusMatches[$StatusMatches.Count-1].Groups[1].Value,16) } else { $null }
    # The raw cfg_read_register path (STATUSR at address 9) is a second, independent
    # reading of the same word. Cross-check it against the property read; a
    # disagreement means the status source itself is unreliable and the caller must
    # not draw conclusions from either value.
    $RawMatches = [regex]::Matches(($Output -join "`n"), 'The register value is:\s*0x([0-9a-fA-F]+)')
    $RawStatus = if ($RawMatches.Count) { [Convert]::ToUInt32($RawMatches[$RawMatches.Count-1].Groups[1].Value,16) } else { $null }
    $StatusAgrees = if ($null -ne $FinalStatus -and $null -ne $RawStatus) { $FinalStatus -eq $RawStatus } else { $null }
    $UserModeSignalsReady = $(if ($null -ne $FinalStatus) { ($FinalStatus -band 0xe5000) -eq 0xe5000 } else { $null })
    # Positive evidence that the device is really running and driving IO, read from
    # the tool's OWN printed decode rather than from our own bit arithmetic. If the
    # log ever shows a different family template (different bit positions), this
    # returns $null and we refuse to claim IO is active.
    $GoutenMatches = [regex]::Matches(($Output -join "`n"), 'Bit 17:\s+([01])\s+gouten\b')
    $DecodedGouten = if ($GoutenMatches.Count) { $GoutenMatches[$GoutenMatches.Count-1].Groups[1].Value -eq '1' } else { $null }
    $DoneMatches = [regex]::Matches(($Output -join "`n"), 'Bit 12:\s+([01])\s+done\b')
    $DecodedDone = if ($DoneMatches.Count) { $DoneMatches[$DoneMatches.Count-1].Groups[1].Value -eq '1' } else { $null }
    $StateFailed = $null -ne $FinalStatus -and (($FinalStatus -band 0x1000) -eq 0 -or ($FinalStatus -band 7) -ne 0)
    if ((-not $VerifyOnly -and -not $ProgramDone) -or $StateFailed) {
        [ordered]@{
            target = $Target; firmware_app = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareApp } else { $null })
            release_directory = $ReleaseDir
            device = 'PGL25G'; completed_at = [DateTimeOffset]::Now.ToString('o')
            configuration_method = $ConfigurationMethod; jtag_frequency = $JtagFrequency
            bitstream_sha256 = (Get-FileHash -LiteralPath $Bitstream).Hash
            programmed_sram = $false; readback_verified = $false; flash_written = $false
            final_status = $FinalStatus; runtime_observed = $false
            failure = 'DONE was not asserted or final status reported a configuration error'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProjectRoot "build/${Target}_sram_result.json") -Encoding utf8
        throw 'FPGA configuration state failed even if the native tool reported success; inspect DONE/status.'
    }
    if ($NativeExit -ne 0 -or ($Output -match '^\s*E:') -or -not ($Output -match 'SRAM_OPERATION_COMPLETE')) {
        throw "SRAM programming/verification did not complete; inspect build/${Target}_sram_program.log."
    }
    [ordered]@{
        target = $Target; firmware_app = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareApp } else { $null })
        release_directory = $ReleaseDir
        device = 'PGL25G'; jtag_id = '0x00511899'
        completed_at = [DateTimeOffset]::Now.ToString('o')
        configuration_method = $ConfigurationMethod
        jtag_frequency = $JtagFrequency
        status_reads_skipped = [bool]$SkipStatusRead
        bitstream_sha256 = (Get-FileHash -LiteralPath $Bitstream).Hash
        programmed_sram = (-not $VerifyOnly); readback_verified = (-not $SkipVerify); flash_written = $false
        final_status = $FinalStatus
        user_mode_signals_ready = $UserModeSignalsReady
        # Check the final decoded state; an earlier GOUTEN=1 must not conceal a
        # later transition to 0. This state is not proof of firmware execution.
        gouten_asserted = $DecodedGouten
        done_asserted = $DecodedDone
        io_likely_active = $DecodedGouten
        raw_status_register = $RawStatus
        status_sources_agree = $StatusAgrees
        runtime_observed = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProjectRoot "build/${Target}_sram_result.json") -Encoding utf8
    if ($DecodedGouten -eq $false) {
        $GoutenMessage = ('GOUTEN is 0: configuration completed but output is disabled. ' +
            'After the reproduced ISC failure, power-cycle the board and reload using Shutdown. ' +
            'See docs/2026-11-01_program3输出关闭复现.md.')
        if ($ExpectHighZ) {
            Write-Host "[EXPECTED] $GoutenMessage"
        } else {
            throw $GoutenMessage
        }
    }
    Write-Host "[PASS] $Target SRAM operation; verify_only=$VerifyOnly skip_verify=$SkipVerify. Runtime still requires observation."
} finally {
    $env:L50_SRAM_FILE = $BeforeEnv
    $env:L50_SRAM_VERIFY_ONLY = $BeforeVerify
    $env:L50_SRAM_SKIP_VERIFY = $BeforeSkipVerify
    $env:L50_SRAM_PROGRAM_MODE = $BeforeMethod
    $env:L50_SRAM_SKIP_STATUS = $BeforeStatusRead
    $env:L50_JTAG_FREQUENCY = $BeforeFrequency
    $env:L50_SRAM_READ_REGISTER = $BeforeReadRegister
    if ($LocalServer -and -not $LocalServer.HasExited) { Stop-Process -Id $LocalServer.Id }
}
