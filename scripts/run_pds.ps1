param(
    [ValidateSet('bringup', 'cpu', 'probe', 'lcd', 'lcd_game','shooter','mine')][string]$Target = 'bringup',
    [ValidateSet('Probe', 'Create', 'Compile', 'Synthesize', 'Map', 'Route', 'Timing', 'Bitstream')][string]$Stage = 'Probe',
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [string]$WorkRoot = 'C:\fpga\riscv_l50',
    [string]$LicenseFile = 'C:\fpga\riscv_l50\licenses\provided.lic',
    [ValidateSet('ClockOnly', 'GuideCandidate', 'Vcc33')][string]$ConstraintProfile = 'ClockOnly',
    # Must list every app prepare_board.ps1 accepts, otherwise a valid app name
    # is rejected here while the packaging path would have handled it.
    [ValidateSet('main', 'runtime_test', 'perf_test', 'perf_report', 'coremark', 'game', 'shooter', 'mine')][string]$FirmwareApp = 'main',
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
if ($Target -eq 'mine') {
    if (-not $PSBoundParameters.ContainsKey('FirmwareApp')) { $FirmwareApp = 'mine' }
    if ($FirmwareApp -ne 'mine') { throw 'The mine target requires -FirmwareApp mine.' }
}
function Get-CpuImplementationEvidence {
    param([string]$BuildDirectory, [string]$Top, [switch]$RequireTiming)
    # An optimized-away CPU can produce "All Constraints Met" with zero
    # endpoints. Require mapped hardware and real constrained paths first.
    $MapPath = Join-Path $BuildDirectory 'device_map/run.log'
    $MapText = Get-Content -LiteralPath $MapPath -Raw
    $Resources = [ordered]@{}
    foreach ($Resource in @('LUT', 'FF', 'DRM')) {
        $ResourceMatch = [regex]::Match($MapText, ('(?m)^\s*\|\s*' + $Resource + '\s*\|\s*(\d+)\s*\|'))
        if (-not $ResourceMatch.Success -or [int]$ResourceMatch.Groups[1].Value -le 0) {
            throw "CPU implementation is empty or incomplete: mapped $Resource must be greater than zero. Inspect $MapPath."
        }
        $Resources[$Resource] = [int]$ResourceMatch.Groups[1].Value
    }
    $Evidence = [ordered]@{
        mapped_resources = $Resources
        map_log_sha256 = (Get-FileHash -LiteralPath $MapPath).Hash
        timing_checked = [bool]$RequireTiming
    }
    if ($RequireTiming) {
        $TimingPath = Join-Path $BuildDirectory "report_timing/$Top.rtr"
        $TimingText = Get-Content -LiteralPath $TimingPath -Raw
        $TimingLogPath = Join-Path $BuildDirectory 'report_timing/run.log'
        $TimingLog = Get-Content -LiteralPath $TimingLogPath -Raw
        if ($TimingText -notmatch 'Device\s*:\s*PGL25G\s' -or
            $TimingText -notmatch 'Design Summary\s*:\s*All Constraints Met\.' -or
            ($TimingText + $TimingLog) -match '(?i)\bunsatisfied\b|not connected to any clock endpoints|has a sdc constraint, but it do not connect') {
            throw "CPU post-route timing failed or has unsatisfied clock constraints. Inspect $TimingPath and $TimingLogPath."
        }
        $ClockSection = [regex]::Match($TimingText, '(?s)Clock Summary:.*?={10,}').Value
        $ClockRows = [regex]::Matches($ClockSection, '(?m)^\s*(\S+)\s+([\d.]+)\s+\{[^}]+\}\s+\S+\s+(\d+)\s+\d+\s+\{')
        $ActiveClocks = @($ClockRows | Where-Object { [int]$_.Groups[3].Value -gt 0 } | ForEach-Object { $_.Groups[1].Value })
        if (-not $ActiveClocks.Count -or
            $TimingText -notmatch '(?m)^Startpoint\s*:\s*\S+' -or
            $TimingText -notmatch '(?m)^Endpoint\s*:\s*\S+' -or
            $TimingText -notmatch '(?m)^Path Class\s*:\s*sequential timing path') {
            throw "CPU timing report has no active clock or actual sequential timing paths: $TimingPath."
        }
        $CheckedSummaries = [ordered]@{}
        foreach ($Kind in @('Setup', 'Hold')) {
            foreach ($Corner in @('Slow', 'Fast')) {
                $Heading = "$Kind Summary($Corner Corner):"
                $Section = [regex]::Match($TimingText, ('(?s)' + [regex]::Escape($Heading) + '.*?={10,}')).Value
                $Rows = [regex]::Matches($Section, '(?m)^\s*\S+\s+\S+\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$')
                $Endpoints = 0
                foreach ($Row in $Rows) {
                    if ([double]$Row.Groups[1].Value -lt 0 -or [int]$Row.Groups[3].Value -ne 0) {
                        throw "CPU timing violation in $Heading Inspect $TimingPath."
                    }
                    $Endpoints += [int]$Row.Groups[4].Value
                }
                if ($Endpoints -le 0) { throw "CPU timing summary has no constrained endpoints: $Heading" }
                $CheckedSummaries["${Kind}_${Corner}_endpoints"] = $Endpoints
            }
        }
        $Evidence.active_clocks = $ActiveClocks
        $Evidence.constrained_endpoints = $CheckedSummaries
        $Evidence.timing_report_sha256 = (Get-FileHash -LiteralPath $TimingPath).Hash
        $Evidence.timing_log_sha256 = (Get-FileHash -LiteralPath $TimingLogPath).Hash
    }
    return $Evidence
}
if ($Target -in @('lcd','lcd_game','shooter','mine') -and $ConstraintProfile -ne 'Vcc33') {
    throw 'LCD requires Vcc33 (Bank3 J28 at 3.3V) and its dedicated fixed-pin constraints.'
}
if ($Stage -eq 'Bitstream' -and $ConstraintProfile -notin @('GuideCandidate', 'Vcc33')) {
    throw 'Bitstream requires the fixed-pin GuideCandidate profile; ClockOnly is exploratory.'
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Executable = Join-Path $PdsRoot 'bin/pds_shell.exe'
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "PDS not found: $Executable" }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (@($WorkRoot.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -gt 0) { throw 'PDS work path must use ASCII characters.' }
$PackageRoot = Join-Path $ProjectRoot "build/atk_l50_$Target"
& (Join-Path $PSScriptRoot 'prepare_board.ps1') -Target $Target -FirmwareApp $FirmwareApp
$Manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'manifest.json') -Raw | ConvertFrom-Json
$Destination = Join-Path $WorkRoot $Target
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
foreach ($Entry in $Manifest.files) {
    $Source = Join-Path $PackageRoot $Entry.path
    if ((Get-FileHash -LiteralPath $Source).Hash -ne $Entry.sha256) { throw "Package hash mismatch: $($Entry.path)" }
    $Output = Join-Path $Destination $Entry.path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Output -Force
}
Copy-Item -LiteralPath (Join-Path $PackageRoot 'sources.f') -Destination (Join-Path $Destination 'sources.f') -Force
# PDS's automatic dependency scan skips a standalone package file. Keep the
# verified source order in one compilation unit, with the package before users.
$Combined = foreach ($Relative in Get-Content -LiteralPath (Join-Path $Destination 'sources.f')) {
    if ($Relative.Trim() -and -not $Relative.StartsWith('#')) {
        "// Source: $Relative"
        Get-Content -LiteralPath (Join-Path $Destination $Relative) -Raw
    }
}
$Combined | Set-Content -LiteralPath (Join-Path $Destination 'pds_design.sv') -Encoding ascii
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'boards/atk_l50/build_pds.tcl') -Destination (Join-Path $Destination 'build_pds.tcl') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pds_probe.tcl') -Destination (Join-Path $Destination 'pds_probe.tcl') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'boards/atk_l50/device.json') -Destination (Join-Path $Destination 'device.json') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'constraints/atk_l50_clock_only.fdc') -Destination (Join-Path $Destination 'constraints/atk_l50_clock_only.fdc') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'constraints/atk_l50_guide_candidate.fdc') -Destination (Join-Path $Destination 'constraints/atk_l50_guide_candidate.fdc') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'constraints/atk_l50_vcc33.fdc') -Destination (Join-Path $Destination 'constraints/atk_l50_vcc33.fdc') -Force
$ConstraintName = @{
    GuideCandidate = 'atk_l50_guide_candidate.fdc'
    Vcc33          = 'atk_l50_vcc33.fdc'
    ClockOnly      = 'atk_l50_clock_only.fdc'
}[$ConstraintProfile]
if ($Target -eq 'cpu' -and $ConstraintProfile -eq 'Vcc33') {
    $ConstraintName = 'atk_l50_cpu_vcc33.fdc'
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "constraints/$ConstraintName") -Destination (Join-Path $Destination "constraints/$ConstraintName") -Force
}
if ($Target -in @('lcd','lcd_game','shooter','mine')) {
    $ConstraintName = "atk_l50_$Target.fdc"
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "constraints/$ConstraintName") -Destination (Join-Path $Destination "constraints/$ConstraintName") -Force
}
[ordered]@{
    target = $Target; stage = $Stage; device = 'PGL25G'; constraint_profile = $ConstraintProfile
    firmware_app = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareApp } else { $null })
    firmware_isa = $Manifest.firmware_isa
    compiler_flags = $Manifest.compiler_flags
    cpu_features = $Manifest.cpu_features
    clock_hz = $Manifest.clock_hz
    input_clock_hz = $Manifest.input_clock_hz
    cpu_clock_div = $Manifest.cpu_clock_div
    firmware_ram_bytes = $Manifest.firmware_ram_bytes
    constraint_sha256 = (Get-FileHash -LiteralPath (Join-Path $Destination "constraints/$ConstraintName")).Hash
    combined_source_sha256 = (Get-FileHash -LiteralPath (Join-Path $Destination 'pds_design.sv')).Hash
    # Record which firmware image PDS will embed. $readmemh loads BRAM CONTENT
    # from this file, so it leaves no trace in the synthesized logic: every app
    # maps to the same LUT/DRM counts and PDS bitstreams are not reproducible
    # run-to-run. The embedded image is therefore only auditable through this
    # recorded hash, taken from the file actually staged for MEM_FILE.
    firmware_hex_sha256 = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { (Get-FileHash -LiteralPath (Join-Path $Destination 'software/build/firmware.hex') -Algorithm SHA256).Hash } else { $null })
    board_download_ready = $false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'run_inputs.json') -Encoding utf8
Write-Host "Staged $Target in $Destination; device=PGL25G speed=-6 package=MBG324."
if ($PrepareOnly) {
    Write-Host 'PREPARED ONLY: PDS has not created a project or run synthesis.'
    return
}
if (-not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) { throw "License file not found: $LicenseFile" }
$SavedEnvironment = @{}
foreach ($Name in @('PANGO_LICENSE_FILE','L50_TOP_MODULE','L50_FLOW_STAGE','L50_CONSTRAINT_FILE')) {
    $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
}
try {
    $env:PANGO_LICENSE_FILE = [IO.Path]::GetFullPath($LicenseFile)
    $env:L50_TOP_MODULE = @{bringup='atk_l50_bringup';cpu='atk_l50_top';probe='atk_l50_io_probe';lcd='atk_l50_lcd';lcd_game='atk_l50_lcd_game';shooter='atk_l50_shooter';mine='atk_l50_mine'}[$Target]
    # PDS preparses Tcl before executing flow commands. Read timing only in
    # PowerShell after report_timing finishes, then generate in a second process.
    $FlowStage = if ($Stage -eq 'Bitstream') { 'Timing' } else { $Stage }
    $env:L50_FLOW_STAGE = $FlowStage
    $env:L50_CONSTRAINT_FILE = $ConstraintName
    $Script = if ($Stage -eq 'Probe') { 'pds_probe.tcl' } else { 'build_pds.tcl' }
    $Marker = if ($Stage -eq 'Probe') { 'PDS_PROBE_END' } else { "PDS_FLOW_COMPLETE $FlowStage" }
    $SavedPreference = $ErrorActionPreference
    Push-Location $Destination
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $Executable -file (Join-Path $Destination $Script) -work_dir $Destination -project_name "atk_l50_$Target" 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $SavedPreference
        Pop-Location
    }
    $LogName = "pds_$($Stage.ToLowerInvariant()).log"
    $Output | Set-Content -LiteralPath (Join-Path $Destination $LogName) -Encoding utf8
    $Output | Set-Content -LiteralPath (Join-Path $ProjectRoot "build/${Target}_$LogName") -Encoding utf8
    $Output | ForEach-Object { Write-Host $_ }
    # PDS returns exit code zero even on some license failures.
    $HasError = $Output -match '^\s*E:|Check license failed|PDS_FLOW_FAILED'
    if ($ExitCode -ne 0 -or $HasError -or -not ($Output -match ([regex]::Escape($Marker)))) {
        throw "PDS $Stage did not complete; inspect $Destination\$LogName. Native exit=$ExitCode; no success is assumed without marker."
    }
    if ($Target -in @('cpu','mine') -and $Stage -in @('Map', 'Route', 'Timing', 'Bitstream')) {
        $ImplementationEvidence = Get-CpuImplementationEvidence -BuildDirectory $Destination -Top $env:L50_TOP_MODULE -RequireTiming:($Stage -in @('Timing','Bitstream'))
        $ImplementationEvidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'implementation_checks.json') -Encoding utf8
    }
    if ($Stage -eq 'Bitstream') {
        $TimingPath = Join-Path $Destination "report_timing/$($env:L50_TOP_MODULE).rtr"
        $TimingText = Get-Content -LiteralPath $TimingPath -Raw
        if ($TimingText -notmatch 'Design Summary\s*:\s*All Constraints Met\.' -or $TimingText -notmatch 'Device\s*:\s*PGL25G\s') {
            throw 'PGL25G post-route timing did not pass; bitstream generation stopped.'
        }
        Push-Location $Destination
        try {
            $ErrorActionPreference = 'Continue'
            # Logos project defaults: create bit file, write DRM data, unused IO pulldown.
            $BitOutput = @(& $Executable -project (Join-Path $Destination "atk_l50_$Target.pds") -run gen_bit_stream 2>&1)
            $BitExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $SavedPreference
            Pop-Location
        }
        $Output += $BitOutput
        $BitOutput | ForEach-Object { Write-Host $_ }
        $Output | Set-Content -LiteralPath (Join-Path $Destination $LogName) -Encoding utf8
        $Output | Set-Content -LiteralPath (Join-Path $ProjectRoot "build/${Target}_$LogName") -Encoding utf8
        if ($BitExit -ne 0 -or ($BitOutput -match '^\s*E:|Check license failed') -or -not ($BitOutput -match 'Process "Generate Bitstream" done\.')) {
            throw "Bitstream generation did not complete; see $Destination/$LogName."
        }
        # One bitstream differs from another only by the firmware baked into IMEM,
        # so packages for different apps must not share a directory: whichever ran
        # last would silently overwrite the other and the remaining files would
        # describe the wrong image. Non-cpu targets keep the plain path.
        $ReleaseLeaf = if ($Target -in @('cpu','lcd_game','shooter','mine')) { "$Target/$FirmwareApp" } else { $Target }
        $ReleaseDir = Join-Path $ProjectRoot "build/board_release/$ReleaseLeaf"
        New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
        $Top = $env:L50_TOP_MODULE
        $ReleaseFiles = @(
            @{ Source = "generate_bitstream/$Top.sbit"; Name = "$Top.sbit" },
            @{ Source = "generate_bitstream/$Top.smsk"; Name = "$Top.smsk" },
            @{ Source = "report_timing/$Top.rtr"; Name = 'timing.rtr' },
            @{ Source = "device_map/$Top.pcf"; Name = 'pins.pcf' },
            @{ Source = "constraints/$ConstraintName"; Name = 'constraints.fdc' },
            @{ Source = 'run_inputs.json'; Name = 'run_inputs.json' },
            @{ Source = $LogName; Name = $LogName }
        )
        if ($Target -in @('lcd','lcd_game','shooter','mine')) {
            $ReleaseFiles += @{ Source = 'pds_design.sv'; Name = 'pds_design.sv' }
        }
        if ($Target -in @('cpu','lcd_game','shooter','mine')) {
            $ReleaseFiles += @{ Source = 'software/build/firmware.hex'; Name = 'firmware.hex' }
            $ReleaseFiles += @{ Source = 'software/build/firmware.json'; Name = 'firmware.json' }
            $ReleaseFiles += @{ Source = 'software/build/build_flags.txt'; Name = 'build_flags.txt' }
            $ReleaseFiles += @{ Source = 'software/build/firmware.elf'; Name = 'firmware.elf' }
            $ReleaseFiles += @{ Source = 'software/build/firmware.dis'; Name = 'firmware.dis' }
        }
        if ($Target -eq 'cpu') {
            $ReleaseFiles += @{ Source = 'pds_design.sv'; Name = 'pds_design.sv' }
            if ($Manifest.cpu_features.DUAL_ISSUE) {
                foreach ($Bank in @('even','odd')) {
                    $ReleaseFiles += @{ Source = "software/build/firmware.hex.$Bank"; Name = "firmware.hex.$Bank" }
                }
            }
        }
        if ($Target -in @('cpu','mine')) {
            $ReleaseFiles += @{ Source = 'implementation_checks.json'; Name = 'implementation_checks.json' }
            $ReleaseFiles += @{ Source = 'device_map/run.log'; Name = 'device_map.log' }
            $ReleaseFiles += @{ Source = 'report_timing/run.log'; Name = 'timing.log' }
        }
        if ($Target -eq 'shooter') { $ReleaseFiles += @{ Source='rtl/periph/shooter_font.hex'; Name='shooter_font.hex' } }
        if ($Target -eq 'mine') {
            $ReleaseFiles += @{ Source='rtl/periph/mine_font.hex'; Name='mine_font.hex' }
            $ReleaseFiles += @{ Source='rtl/periph/mine_font_map.json'; Name='mine_font_map.json' }
        }
        foreach ($File in $ReleaseFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $Destination $File.Source) -PathType Leaf)) {
                throw "Missing PDS artifact: $($File.Source)"
            }
        }
        $ReleaseHashes = foreach ($File in $ReleaseFiles) {
            $ReleasePath = Join-Path $ReleaseDir $File.Name
            Copy-Item -LiteralPath (Join-Path $Destination $File.Source) -Destination $ReleasePath -Force
            [ordered]@{ file = $File.Name; sha256 = (Get-FileHash -LiteralPath $ReleasePath).Hash; bytes = (Get-Item -LiteralPath $ReleasePath).Length }
        }
        [ordered]@{
            target = $Target; top = $Top; device = 'PGL25G'; constraint_profile = $ConstraintProfile
            firmware_app = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareApp } else { $null })
            programmed = $false; board_verified = $false
            timing_scope = $(if ($Target -eq 'cpu') { "Input 50 MHz; CPU $($Manifest.cpu_features.CLOCK_HZ) Hz with actual divider $($Manifest.cpu_features.CPU_CLOCK_DIV); reset/LED/UART interface delays unbudgeted" } elseif ($Target -in @('lcd','lcd_game','shooter','mine')) { '20 ns system clock; 40 ns forwarded LCD clock; provisional panel setup=5 ns/hold=2 ns, board skew unmeasured; reset/LED/UART unbudgeted' } else { '20 ns clock; external asynchronous reset and LED/UART interface delays unbudgeted' })
            files = @($ReleaseHashes)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReleaseDir 'release.json') -Encoding utf8
        Write-Host "Bitstream/report package: $ReleaseDir. Hardware has NOT been programmed."
    }
    Write-Host "[PASS] PDS $Stage completed for $Target."
} finally {
    foreach ($Name in $SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], 'Process') }
}
