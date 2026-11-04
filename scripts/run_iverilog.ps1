param([switch]$SkipSoc, [switch]$RebuildFirmware)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $ProjectRoot 'build'
if ($RebuildFirmware) { & (Join-Path $PSScriptRoot 'build_firmware.ps1') -Rebuild }
$LocalBin = Join-Path (Split-Path -Parent $ProjectRoot) 'tools/iverilog/bin'
if (Test-Path (Join-Path $LocalBin 'iverilog.exe')) {
    $env:PATH = $LocalBin + [IO.Path]::PathSeparator + $env:PATH
}
foreach ($Tool in @('iverilog', 'vvp')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "Missing tool: $Tool" }
}
foreach ($Firmware in @('software/build/firmware.hex', 'software/build/runtime_test/firmware.hex', 'software/build/perf_test/firmware.hex', 'software/build/perf_report/firmware.hex', 'software/build/coremark/firmware.hex', 'software/build/coremark/sim_firmware.hex')) {
    if (-not $SkipSoc -and -not (Test-Path (Join-Path $ProjectRoot $Firmware) -PathType Leaf)) {
        throw "Missing $Firmware. Run scripts/build_firmware.ps1 first; -SkipSoc explicitly runs a PARTIAL regression."
    }
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$CompileEvidencePath = Join-Path $BuildDir 'regression_compile_inputs.jsonl'
Set-Content -LiteralPath $CompileEvidencePath -Value '' -Encoding utf8
$CoreSources = @(
    'rtl/core/rv32i_pkg.sv', 'rtl/core/rv32i_alu.sv',
    'rtl/core/rv32i_imm_gen.sv', 'rtl/core/rv32i_regfile.sv',
    'rtl/core/rv32i_decoder.sv', 'rtl/core/rv32i_core_3stage.sv'
)
$MemorySources = @('rtl/soc/sync_imem.sv', 'rtl/soc/sync_dmem.sv')
$SocSources = @('rtl/periph/uart_tx.sv', 'rtl/soc/rv32i_soc.sv') + $MemorySources
function Invoke-Testbench([string]$Name, [string[]]$Sources, [string]$PassMarker, [string[]]$Defines = @()) {
    $OutputFile = Join-Path $BuildDir "$Name.vvp"
    $InputHashes = [ordered]@{}
    foreach ($Source in @($Sources) + @("sim/$Name.sv")) {
        $InputHashes[$Source] = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot $Source) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    # Never run a stale executable after compilation fails.
    if (Test-Path $OutputFile) { Remove-Item -LiteralPath $OutputFile }
    # Windows PowerShell 5 treats native stderr warnings as ErrorRecords.
    # Check native exit codes explicitly; retain diagnostics without aborting on warnings.
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & iverilog -g2012 -s $Name -o $OutputFile @Defines @Sources "sim/$Name.sv" 2> (Join-Path $BuildDir "$Name.compile.log")
        $CompileCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $SavedPreference }
    if ($CompileCode -ne 0) { throw "$Name compilation failed; see build/$Name.compile.log" }
    foreach ($Source in $InputHashes.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $ProjectRoot $Source) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $InputHashes[$Source]) {
            throw "$Name input changed during compilation: $Source. Rerun against stable sources."
        }
    }
    [ordered]@{
        testbench = $Name
        compiled_at_utc = [DateTime]::UtcNow.ToString('o')
        parameters = @($Defines)
        source_sha256 = $InputHashes
        executable_sha256 = (Get-FileHash -LiteralPath $OutputFile -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 5 -Compress | Add-Content -LiteralPath $CompileEvidencePath -Encoding utf8
    try {
        $ErrorActionPreference = 'Continue'
        $Result = @(& vvp $OutputFile 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $SavedPreference }
    $Result | Set-Content -LiteralPath (Join-Path $BuildDir "$Name.run.log") -Encoding utf8
    $Result | ForEach-Object { Write-Host $_ }
    if ($ExitCode -ne 0 -or -not ($Result -match ([regex]::Escape($PassMarker)))) {
        throw "$Name failed (exit=$ExitCode or missing PASS marker); see build/$Name.run.log"
    }
}
function Get-CoreMarkIsaDefines([string]$SimImage) {
    $ManifestPath = Join-Path $ProjectRoot 'software/build/coremark_sim/firmware.json'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw 'Missing CoreMark simulation manifest. Rebuild CoreMark with scripts/build_firmware.ps1.'
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.abi -ne 'ilp32' -or $Manifest.app -ne 'coremark/core_main.c' -or
        $Manifest.compiler_flags -notmatch '(^|\s)-DITERATIONS=1(\s|$)') {
        throw 'CoreMark simulation manifest is not an ILP32 one-iteration CoreMark build.'
    }
    $ExpectedHash = $Manifest.artifact_sha256.'firmware.hex'
    if (-not $ExpectedHash -or
        (Get-FileHash -LiteralPath $SimImage -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash.ToLowerInvariant()) {
        throw 'CoreMark simulation image does not match its manifest. Rebuild before regression.'
    }
    $UseZmmul = 0
    $UseBitmanip = 0
    switch ($Manifest.isa) {
        'rv32i' { }
        'rv32i_zmmul' { $UseZmmul = 1 }
        'rv32i_zba_zbb_zmmul' { $UseZmmul = 1; $UseBitmanip = 1 }
        default { throw "Unsupported CoreMark simulation ISA: $($Manifest.isa)" }
    }
    Write-Host "CoreMark simulation ISA=$($Manifest.isa), image SHA256=$ExpectedHash"
    return @("-Ptb_coremark.ZMMUL_ENABLE=$UseZmmul", "-Ptb_coremark.BITMANIP_ENABLE=$UseBitmanip")
}
Push-Location $ProjectRoot
try {
    Invoke-Testbench 'tb_alu' $CoreSources[0..1] '[PASS] rv32i_alu'
    Invoke-Testbench 'tb_core' $CoreSources '[PASS] rv32i_core_3stage'
    Invoke-Testbench 'tb_core_wait' $CoreSources '[PASS] rv32i_core_wait'
    Invoke-Testbench 'tb_sync_memory' $MemorySources '[PASS] sync_memory'
    Invoke-Testbench 'tb_core_sync' $CoreSources '[PASS] rv32i_core_sync'
    Invoke-Testbench 'tb_soc_memory' ($CoreSources + $SocSources) '[PASS] rv32i_soc_memory'
    Invoke-Testbench 'tb_soc_memory' ($CoreSources + $SocSources) '[PASS] rv32i_soc_memory' @('-Ptb_soc_memory.FAST_DMEM=1')
    Invoke-Testbench 'tb_soc_perf' ($CoreSources + $SocSources) '[PASS] soc_perf'
    Invoke-Testbench 'tb_soc_lcd' ($CoreSources + $SocSources) '[PASS] soc_lcd'
    Invoke-Testbench 'tb_bringup' @('rtl/periph/uart_tx.sv', 'rtl/top/reset_sync.sv', 'rtl/top/atk_l50_bringup.sv') '[PASS] atk_l50_bringup'
    if (-not $SkipSoc) {
        Invoke-Testbench 'tb_soc' ($CoreSources + $SocSources) '[PASS] rv32i_soc'
        Invoke-Testbench 'tb_board_cpu' ($CoreSources + $SocSources + @('rtl/top/reset_sync.sv', 'rtl/top/atk_l50_top.sv')) '[PASS] atk_l50_cpu'
        Invoke-Testbench 'tb_runtime' ($CoreSources + $SocSources) '[PASS] c_runtime'
        Invoke-Testbench 'tb_perf_firmware' ($CoreSources + $SocSources) '[PASS] perf_firmware'
        Invoke-Testbench 'tb_perf_report' ($CoreSources + $SocSources) '[PASS] perf_report'
        # CoreMark is a multi-file application rather than a single .c, and the
        # image the board runs auto-scales its iteration count to a ten-second
        # run, which no simulation can afford. This testbench therefore runs a
        # separately built image with the iteration count pinned to one.
        $CoreMarkHex = Join-Path $ProjectRoot 'software/build/coremark/firmware.hex'
        $CoreMarkSimHex = Join-Path $ProjectRoot 'software/build/coremark/sim_firmware.hex'
        # A board image auto-calibrates for >=10 seconds of FPGA time and is
        # not a substitute for the one-iteration simulation image.
        if (-not (Test-Path $CoreMarkSimHex -PathType Leaf)) {throw 'Missing dedicated CoreMark simulation image.'}
        $CoreMarkDefines = @(Get-CoreMarkIsaDefines $CoreMarkSimHex)
        Invoke-Testbench 'tb_coremark' ($CoreSources + $SocSources) '[PASS] coremark' $CoreMarkDefines
        if ($RebuildFirmware) {
            Write-Host 'All 16 simulations passed. Firmware build script completed; inspect its per-app manifest output for rebuild scope.' -ForegroundColor Green
        } else {
            Write-Host 'All 16 simulations passed. Firmware images used as provided; use -RebuildFirmware to rebuild.' -ForegroundColor Green
        }
    } else {
        Write-Warning 'PARTIAL: 10 simulations passed; six firmware-dependent tests explicitly skipped.'
    }
} finally { Pop-Location }
