param(
    [ValidateSet('bringup', 'cpu', 'probe', 'lcd', 'lcd_game','shooter','mine')][string]$Target = 'bringup',
    # Which verified firmware image the cpu target carries onto the board. Each
    # app builds into its own directory (main is the top-level software/build),
    # so the release package must name the image it actually ships instead of
    # assuming main.c.
    [ValidateSet('main', 'runtime_test', 'perf_test', 'perf_report', 'coremark', 'game', 'shooter', 'mine')][string]$FirmwareApp = 'main'
)
$ErrorActionPreference = 'Stop'
if ($Target -eq 'mine') {
    if (-not $PSBoundParameters.ContainsKey('FirmwareApp')) { $FirmwareApp = 'mine' }
    if ($FirmwareApp -ne 'mine') { throw 'The mine target requires -FirmwareApp mine.' }
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BoardDir = Join-Path $ProjectRoot 'boards/atk_l50'
$Destination = Join-Path $ProjectRoot "build/atk_l50_$Target"
$FirmwareDir = if ($FirmwareApp -eq 'main') { 'software/build' } else { "software/build/$FirmwareApp" }
# Applications whose translation units live outside software/ name their own
# entry point and source list here. CoreMark is the first such app: its main()
# is coremark/core_main.c and its algorithms plus the port layer sit beside it,
# so the release package has to carry that directory rather than a single
# "software/<app>.c" file.
$AppEntry = @{ 'coremark' = 'coremark/core_main.c' }
$AppSourceTree = @{
    'coremark' = @('software/coremark/core_list_join.c', 'software/coremark/core_matrix.c',
        'software/coremark/core_state.c', 'software/coremark/core_util.c',
        'software/coremark/core_portme.c', 'software/coremark/core_portme.h',
        'software/coremark/ee_printf.c', 'software/coremark/softmath.c',
        'software/coremark/coremark.h', 'software/coremark/board_coremark_config.h',
        'software/coremark/LICENSE.md')
    'mine' = @('software/coremark/softmath.c', 'software/coremark/coremark.h',
        'software/coremark/core_portme.h', 'software/coremark/board_coremark_config.h')
}
$AppMain = if ($AppEntry.ContainsKey($FirmwareApp)) { $AppEntry[$FirmwareApp] } else { "$FirmwareApp.c" }
# The SoC loads its program image from MEM_FILE, which defaults to the literal
# path 'software/build/firmware.hex' (see rtl/top/atk_l50_top.sv and
# rtl/soc/rv32i_soc.sv). PDS resolves that relative to the package root, so a
# non-main image must also be published at that exact path or synthesis would
# pick up a stale image -- or none at all.
$FirmwareStage = 'software/build'
# Read the source list through .NET so entries stay plain strings even when the
# shell hands out provider-wrapped objects for file cmdlets.
$Sources = @([IO.File]::ReadAllLines((Join-Path $BoardDir "$Target.f")) | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
$Files = @($Sources) + @('constraints/atk_l50_reference.fdc', 'boards/atk_l50/README.md')
if ($Target -in @('lcd','lcd_game','shooter','mine')) { $Files += 'constraints/atk_l50_lcd.fdc'; if ($Target -eq 'lcd_game') { $Files += 'constraints/atk_l50_lcd_game.fdc' } }
if ($Target -eq 'shooter') { $Files += @('constraints/atk_l50_shooter.fdc','rtl/periph/shooter_font.hex','rtl/periph/shooter_font_map.json','rtl/periph/lcd_shooter_display.sv.in','scripts/generate_shooter_font.py') }
if ($Target -eq 'mine') {
    $Files += @('constraints/atk_l50_mine.fdc', 'rtl/periph/mine_font.hex', 'rtl/periph/mine_font_map.json')
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'scripts/generate_mine_font.py')) { $Files += 'scripts/generate_mine_font.py' }
}
if ($Target -in @('cpu','lcd_game','shooter','mine')) {
    # Every app shares one source tree; ship the sources that apply to the app
    # being released plus that app's own translation unit.
    $Files += @('software/start.S', 'software/perf.h', 'software/linker.ld',
        'software/Makefile', 'software/verify_firmware.py', 'software/README.md', 'scripts/build_firmware.ps1',
        "$FirmwareDir/firmware.elf", "$FirmwareDir/firmware.bin", "$FirmwareDir/firmware.hex",
        "$FirmwareDir/firmware.dis", "$FirmwareDir/firmware.map", "$FirmwareDir/firmware.json",
        "$FirmwareDir/toolchain.txt", "$FirmwareDir/build_flags.txt", "software/$AppMain")
    # For a non-main app the image is published a second time at $FirmwareStage,
    # the literal path MEM_FILE opens. That staged copy is produced below from
    # $FirmwareDir and must NOT be listed in $Files: $Files entries are all read
    # from $ProjectRoot, and $ProjectRoot/$FirmwareStage/firmware.hex is the
    # leftover main-app image, so listing it would overwrite the staged copy
    # with main and the bitstream would silently carry the wrong firmware.
    # A multi-file app also ships every translation unit and header the verifier
    # hashed, so the package can be rebuilt without the original source tree.
    if ($AppSourceTree.ContainsKey($FirmwareApp)) { $Files += $AppSourceTree[$FirmwareApp] }
}
foreach ($Relative in $Files) {
    if (-not (Test-Path (Join-Path $ProjectRoot $Relative) -PathType Leaf)) { throw "Missing input: $Relative" }
}
$CpuFeatures = $null
if ($Target -eq 'cpu') {
    # PDS uses these top-level defaults (no parameter overrides in run_pds).
    # Verify the actual source instead of assuming every cpu build enables M/B.
    $CpuTopText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'rtl/top/atk_l50_top.sv') -Raw
    $CpuFeatures = [ordered]@{}
    foreach ($Parameter in @('ZMMUL_ENABLE', 'BITMANIP_ENABLE', 'DUAL_ISSUE', 'FAST_DMEM', 'PIPELINE_DECODE')) {
        $Pattern = 'parameter\s+bit\s+' + [regex]::Escape($Parameter) + "\s*=\s*1'b([01])"
        $Match = [regex]::Match($CpuTopText, $Pattern)
        if (-not $Match.Success) { throw "Cannot determine cpu top default: $Parameter" }
        $CpuFeatures[$Parameter] = [bool]([int]$Match.Groups[1].Value)
    }
    foreach ($Parameter in @('BTB_ENTRIES', 'MUL_CYCLES', 'CLOCK_HZ', 'INPUT_CLOCK_HZ', 'CPU_CLOCK_DIV', 'BAUD', 'DMEM_WORDS')) {
        $Match = [regex]::Match($CpuTopText, 'parameter\s+integer\s+' + $Parameter + '\s*=\s*([0-9_]+)')
        if (-not $Match.Success) { throw "Cannot determine cpu top default: $Parameter" }
        $CpuFeatures[$Parameter] = [int]$Match.Groups[1].Value.Replace('_','')
    }
    if ($CpuFeatures.CPU_CLOCK_DIV -notin @(1,2) -or
        $CpuFeatures.INPUT_CLOCK_HZ -ne $CpuFeatures.CLOCK_HZ * $CpuFeatures.CPU_CLOCK_DIV) {
        throw 'CPU input frequency, divider, and CLOCK_HZ defaults disagree.'
    }
}
if ($Target -in @('cpu','lcd_game','shooter','mine')) {
    $Firmware = Get-Content -LiteralPath (Join-Path $ProjectRoot "$FirmwareDir/firmware.json") -Raw | ConvertFrom-Json
    if ($Firmware.ram_bytes -notin @(8192,16384)) { throw 'Firmware manifest is missing a supported ram_bytes value; rebuild firmware.' }
    $HardwareRamBytes = 16384
    if ($Target -eq 'cpu') { $HardwareRamBytes = 4 * $CpuFeatures.DMEM_WORDS }
    if ($Firmware.ram_bytes -ne $HardwareRamBytes) {
        throw "Firmware RAM size $($Firmware.ram_bytes) does not match target RAM size $HardwareRamBytes."
    }
    if ($FirmwareApp -eq 'coremark') {
        $HardwareClockHz = if ($Target -eq 'cpu') { $CpuFeatures.CLOCK_HZ } else { 50000000 }
        if ($Firmware.clock_hz -ne $HardwareClockHz) {
            throw "CoreMark firmware clock $($Firmware.clock_hz) does not match hardware $HardwareClockHz Hz."
        }
    }
    if ($Firmware.app -ne $AppMain -or $Firmware.isa -notin @('rv32i','rv32i_zmmul','rv32i_zba_zbb_zmmul') -or $Firmware.abi -ne 'ilp32') {
        throw "Expected a verified $AppMain supported RV32/ILP32 build, found app=$($Firmware.app) isa=$($Firmware.isa) abi=$($Firmware.abi)."
    }
    if ($Firmware.isa -ne 'rv32i') {
        if ($Target -ne 'cpu' -or -not $CpuFeatures.ZMMUL_ENABLE) {
            throw 'Zmmul firmware requires the cpu top with ZMMUL_ENABLE=1.'
        }
        if ($Firmware.isa -eq 'rv32i_zba_zbb_zmmul' -and -not $CpuFeatures.BITMANIP_ENABLE) {
            throw 'Zba/Zbb firmware requires BITMANIP_ENABLE=1 in the cpu top.'
        }
    }
    $BuildFlags = (Get-Content -LiteralPath (Join-Path $ProjectRoot "$FirmwareDir/build_flags.txt") -Raw).Trim()
    if ($BuildFlags -ne $Firmware.compiler_flags) { throw 'Build flags differ from verified firmware manifest.' }
    foreach ($Property in $Firmware.source_sha256.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $ProjectRoot "software/$($Property.Name)")).Hash.ToLowerInvariant() -ne $Property.Value) {
            throw "Stale firmware: $($Property.Name). Run scripts/build_firmware.ps1."
        }
    }
    foreach ($Property in $Firmware.artifact_sha256.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $ProjectRoot "$FirmwareDir/$($Property.Name)")).Hash.ToLowerInvariant() -ne $Property.Value) {
            throw "Firmware hash mismatch: $($Property.Name)"
        }
    }
}
# Remove only obsolete files recorded by the previous generated manifest.
# User-created PDS projects/reports in the output folder are left untouched.
# A manifest written under a different text encoding can hold paths that are no
# longer valid on disk (mangled non-ASCII names, or reserved characters such as
# '?'); such an entry cannot name a file this script created, so skip it rather
# than abort the release. Everything still reachable under the destination is
# checked for containment before removal.
$PreviousManifest = Join-Path $Destination 'manifest.json'
if (Test-Path -LiteralPath $PreviousManifest) {
    $Previous = Get-Content -LiteralPath $PreviousManifest -Raw | ConvertFrom-Json
    $DestinationPrefix = [IO.Path]::GetFullPath($Destination) + [IO.Path]::DirectorySeparatorChar
    foreach ($Entry in $Previous.files) {
        if ($Entry.path -in $Files) { continue }
        try {
            $OldPath = [IO.Path]::GetFullPath((Join-Path $Destination $Entry.path))
        } catch [System.ArgumentException] {
            Write-Warning "Skipping unusable previous manifest entry: $($Entry.path)"
            continue
        }
        if (-not $OldPath.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Previous manifest path escapes package: $($Entry.path)"
        }
        if (Test-Path -LiteralPath $OldPath -PathType Leaf) { Remove-Item -LiteralPath $OldPath }
    }
}
$Hashes = foreach ($Relative in $Files) {
    $Source = Join-Path $ProjectRoot $Relative
    $Output = Join-Path $Destination $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Output -Force
    [ordered]@{ path = $Relative; sha256 = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash }
}
# Publish the selected image where MEM_FILE looks for it. For main this is a
# no-op because the app already builds straight into software/build. This runs
# AFTER the $Files loop so nothing can overwrite it, and it appends its own
# manifest entries because run_pds.ps1 copies exactly what the manifest lists.
if ($Target -in @('cpu','lcd_game','shooter','mine') -and $FirmwareDir -ne $FirmwareStage) {
    $StagedHashes = foreach ($Name in @('firmware.hex', 'firmware.elf', 'firmware.bin', 'firmware.dis', 'firmware.map', 'firmware.json', 'toolchain.txt', 'build_flags.txt')) {
        $Staged = Join-Path $Destination "$FirmwareStage/$Name"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Staged) | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "$FirmwareDir/$Name") -Destination $Staged -Force
        [ordered]@{ path = "$FirmwareStage/$Name"; sha256 = (Get-FileHash -LiteralPath $Staged -Algorithm SHA256).Hash }
    }
    $Hashes = @($Hashes) + @($StagedHashes)
    Write-Host "Staged $FirmwareApp image at $FirmwareStage/firmware.hex for MEM_FILE."
}
Copy-Item -LiteralPath (Join-Path $BoardDir "$Target.f") -Destination (Join-Path $Destination 'sources.f') -Force
if ($Target -eq 'cpu' -and $CpuFeatures.DUAL_ISSUE) {
    # Load each physical ROM bank directly: PDS cannot synthesize an initial
    # copy from a different memory that was populated by $readmemh.
    $BankImage = Join-Path $Destination "$FirmwareStage/firmware.hex"
    $Words = [string[]]::new(16384)
    for ($WordIndex=0; $WordIndex -lt 16384; $WordIndex++) { $Words[$WordIndex] = '00100073' }
    $WordIndex = 0
    foreach ($HexToken in ((Get-Content -LiteralPath $BankImage -Raw) -split '\s+')) {
        if (-not $HexToken) { continue }
        if ($HexToken -match '^@([0-9a-fA-F]+)$') { $WordIndex = [Convert]::ToInt32($Matches[1],16) }
        elseif ($HexToken -match '^[0-9a-fA-F]{8}$' -and $WordIndex -lt 16384) {
            $Words[$WordIndex] = $HexToken
            $WordIndex++
        } else { throw "Invalid or out-of-range ROM word: $HexToken" }
    }
    $EvenWords = [Collections.Generic.List[string]]::new()
    $OddWords = [Collections.Generic.List[string]]::new()
    for ($WordIndex=0; $WordIndex -lt 16384; $WordIndex++) {
        $Word = if ($WordIndex -lt $Words.Count) { $Words[$WordIndex] } else { '00100073' }
        if (($WordIndex % 2) -eq 0) { $EvenWords.Add($Word) } else { $OddWords.Add($Word) }
    }
    [IO.File]::WriteAllLines("$BankImage.even", $EvenWords, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllLines("$BankImage.odd", $OddWords, [Text.Encoding]::ASCII)
    foreach ($Suffix in @('even','odd')) {
        $Hashes += [ordered]@{path="$FirmwareStage/firmware.hex.$Suffix"; sha256=(Get-FileHash -LiteralPath "$BankImage.$Suffix").Hash}
    }
}
$Top = @{bringup='atk_l50_bringup';cpu='atk_l50_top';probe='atk_l50_io_probe';lcd='atk_l50_lcd';lcd_game='atk_l50_lcd_game';shooter='atk_l50_shooter';mine='atk_l50_mine'}[$Target]
[ordered]@{
    target = $Target; top = $Top; language = 'SystemVerilog'
    clock_hz = $(if ($Target -eq 'cpu') { $CpuFeatures.CLOCK_HZ } else { 50000000 })
    input_clock_hz = $(if ($Target -eq 'cpu') { $CpuFeatures.INPUT_CLOCK_HZ } else { 50000000 })
    cpu_clock_div = $(if ($Target -eq 'cpu') { $CpuFeatures.CPU_CLOCK_DIV } else { 1 })
    baud = $(if ($Target -eq 'cpu') { $CpuFeatures.BAUD } else { 115200 })
    device = 'PGL25G / -6 / MBG324 (JTAG ID 0x00511899)'
    constraint_status = $(if ($Target -in @('lcd','lcd_game','shooter','mine')) { 'LCD fixed pins; Bank3/J28 configured for 3.3V; interface timing budget provisional' } else { 'REFERENCE ONLY: clock/reset voltage differs between supplied FDC and guide; confirm board revision before bitstream' })
    firmware_app = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareApp } else { $null })
    firmware_dir = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $FirmwareDir } else { $null })
    firmware_status = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { "Verified $AppMain $($Firmware.isa)/ILP32 image; source/artifact hashes checked; ROM data-copy startup" } else { 'Not required' })
    firmware_isa = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $Firmware.isa } else { $null })
    firmware_ram_bytes = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $Firmware.ram_bytes } else { $null })
    compiler_flags = $(if ($Target -in @('cpu','lcd_game','shooter','mine')) { $Firmware.compiler_flags } else { $null })
    cpu_features = $CpuFeatures
    files = @($Hashes)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'manifest.json') -Encoding utf8
Write-Host "Prepared $Destination (top=$Top). Source package only; PDS project/bitstream NOT generated."
if ($Target -notin @('lcd','lcd_game','shooter','mine')) { Write-Warning 'Reference FDC needs board voltage verification before implementation/download. See boards/atk_l50/README.md.' }
