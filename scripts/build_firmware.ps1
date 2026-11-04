param(
    [ValidateSet('all', 'main', 'runtime_test', 'perf_test', 'perf_report', 'coremark', 'game', 'shooter', 'mine', 'mine_sim')][string]$App = 'all',
    [string]$WslDistro = 'Ubuntu',
    [string]$RiscvPrefix = 'riscv64-unknown-elf-',
    [ValidateSet('rv32i', 'rv32i_zmmul', 'rv32i_zba_zbb_zmmul')][string]$Isa = 'rv32i',
    [ValidateSet('-O2','-O3','-Os')][string]$Opt = '-O2',
    [ValidateSet(0,1)][int]$Relax = 0,
    [ValidateSet(8192,16384)][int]$RamBytes = 16384,
    [string]$ExtraCflags = '',
    [switch]$Rebuild
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SoftwareRoot = Join-Path $ProjectRoot 'software'
# Multi-file images list their extra translation units and out-of-root headers
# here; single-file images build from APP alone.
#
# coremark is the first image whose sources are not in software/ itself: EEMBC's
# five algorithm files plus the local port layer live in software/coremark/.
# softmath.c supplies __mulsi3/__udivsi3 for RV32I, which has neither
# instruction; without it the link fails with undefined references, because the
# project links -nostdlib and therefore has no libgcc.
$AppSources = @{
    'coremark' = 'coremark/core_list_join.c coremark/core_matrix.c coremark/core_state.c coremark/core_util.c coremark/core_portme.c coremark/ee_printf.c coremark/softmath.c'
    'mine' = 'coremark/softmath.c'
    'mine_sim' = 'coremark/softmath.c'
}
$AppHeaders = @{
    'coremark' = 'coremark/core_portme.h coremark/coremark.h coremark/board_coremark_config.h'
}
# Single-file images build from "$Name.c". A multi-file image has no such file:
# CoreMark's main() lives in coremark/core_main.c, which is also the translation
# unit verify_firmware.py must find as its STT_FILE symbol. APP therefore has to
# name a real source file, not a synthetic "$Name.c".
#
# APP is compiled separately by the Makefile rule and must NOT be repeated in
# EXTRA_SRCS, or that translation unit is compiled twice and the link fails with
# "multiple definition of `main'".
$AppMain = @{
    'coremark' = 'coremark/core_main.c'
    'mine_sim' = 'mine.c'
}
# Wrap a value for a POSIX shell in single quotes so spaces, slashes and the
# non-ASCII path components survive the trip through wsl.exe intact.
function ConvertTo-WslQuote([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is required for this build entry.' }
if ($SoftwareRoot.Length -lt 3 -or $SoftwareRoot.Substring(1, 2) -ne ':\') { throw 'Use a local drive path for the WSL build.' }
$Drive = $SoftwareRoot.Substring(0, 1).ToLowerInvariant()
$WslRoot = '/mnt/' + $Drive + $SoftwareRoot.Substring(2).Replace('\', '/')
$Apps = if ($App -eq 'all') { @('main', 'runtime_test', 'perf_test', 'perf_report', 'coremark', 'mine', 'mine_sim') } elseif ($App -eq 'mine') { @('mine', 'mine_sim') } else { @($App) }
foreach ($Name in $Apps) {
    $OutputDir = if ($Name -eq 'main') { 'build' } else { "build/$Name" }
    $MainSource = if ($AppMain.ContainsKey($Name)) { $AppMain[$Name] } else { "$Name.c" }
    # Every argument is quoted exactly once, here, and the whole command is handed
    # to bash as ONE string. Passing a PowerShell array to wsl.exe lets the
    # command line be re-split on whitespace, so a multi-file image's
    # "EXTRA_SRCS=a.c b.c ..." arrived as several separate make arguments and
    # make treated the extra names as goals. Single-file images never hit this
    # because their EXTRA_SRCS is empty, which is why it only surfaced now.
    #
    # $WslRoot must NOT be pre-quoted in this array: the loop at the end quotes
    # every element, and quoting it twice produced ''\''/mnt/...'\''' which
    # bash reads as an empty string. make then failed with "No such file or
    # directory" while the script still reported success, because a stale
    # manifest from an earlier build was present and the manifest's existence
    # was all the script checked.
    $MakeParts = @('make', '-C', $WslRoot,
        "RISCV_PREFIX=$RiscvPrefix", "MARCH=$Isa", "RAM_BYTES=$RamBytes", "OPT=$Opt", "RELAX=$Relax", "EXTRA_CFLAGS=$ExtraCflags", "APP=$MainSource", "BUILD_DIR=$OutputDir")
    if ($AppSources.ContainsKey($Name)) { $MakeParts += "EXTRA_SRCS=$($AppSources[$Name])" }
    if ($AppHeaders.ContainsKey($Name)) { $MakeParts += "EXTRA_HDRS=$($AppHeaders[$Name])" }
    if ($Rebuild) { $MakeParts += '-B' }
    $Command = ($MakeParts | ForEach-Object { ConvertTo-WslQuote $_ }) -join ' '
    $Arguments = @('-d', $WslDistro, '--', 'bash', '-lc', $Command)
    # Record the manifest's timestamp before the build. A stale manifest left
    # over from an earlier run makes "the manifest exists" meaningless as a
    # success signal, and that is exactly how a failed make() once passed for a
    # good build: wsl.exe reported non-zero, the manifest existed from a
    # previous run, and nothing noticed the image had not been rebuilt.
    $ManifestPath = Join-Path $SoftwareRoot "$OutputDir/firmware.json"
    $BeforeStamp = if (Test-Path -LiteralPath $ManifestPath) { (Get-Item -LiteralPath $ManifestPath).LastWriteTimeUtc } else { $null }
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & wsl.exe @Arguments
        $BuildExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $SavedPreference }
    # wsl.exe reports a non-zero exit whenever it writes anything to stderr, and
    # this host's WSL always prints an unrelated localhost/NAT proxy notice
    # there. A non-zero code alone therefore cannot fail the build, so the check
    # below is that the manifest was REFRESHED: make rewrites firmware.json only
    # after verify_firmware.py has accepted the image, so a newer timestamp is
    # the real proof that this run produced a verified image.
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Firmware build failed: $Name (exit=$BuildExit); no manifest was produced."
    }
    $AfterStamp = (Get-Item -LiteralPath $ManifestPath).LastWriteTimeUtc
    if ($null -ne $BeforeStamp -and $AfterStamp -le $BeforeStamp) {
        throw "Firmware build for $Name did not refresh $ManifestPath (exit=$BuildExit); the image was NOT rebuilt."
    }
    # The build runs inside WSL and every read below comes back over the 9p
    # mount. A file can be visible in WSL yet momentarily stale or unreadable
    # from Windows: the manifest read here once returned the pre-build copy,
    # which then looked like a source whose hash had changed. Retry until the
    # manifest parses as JSON, so a transient miss is not reported as a broken
    # build. The retry lives here rather than inline because the manifest is
    # needed before the per-artifact helper below is defined.
    function Read-Manifest([string]$Path) {
        for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
            $Text = $null
            try { $Text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { $Text = $null }
            if ($Text) {
                try { return ($Text | ConvertFrom-Json) } catch { }
            }
            Start-Sleep -Milliseconds 150
        }
        throw "Firmware manifest unreadable after build: $Path"
    }
    $Manifest = Read-Manifest $ManifestPath
    if ($Manifest.ram_bytes -ne $RamBytes) { throw "Firmware RAM size does not match requested $RamBytes bytes." }
    if ($Manifest.isa -ne $Isa -or $Manifest.abi -ne 'ilp32' -or $Manifest.app -ne $MainSource) {
        throw "Firmware manifest does not match requested app/ISA/ABI: $Name / $Isa / ilp32."
    }
    $BuildFlags = (Get-Content -LiteralPath (Join-Path $SoftwareRoot "$OutputDir/build_flags.txt") -Raw).Trim()
    if ($BuildFlags -ne $Manifest.compiler_flags) { throw 'Build flags differ from verified firmware manifest.' }
    # The build runs inside WSL and the checks below read the results back over
    # the 9p mount. A file can be visible in WSL yet momentarily unreadable from
    # Windows, which surfaced as a null hash instead of a useful message. Retry
    # briefly so a transient miss is not reported as a broken build.
    function Get-ArtifactHash([string]$Path) {
        for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
            if (Test-Path -LiteralPath $Path) {
                $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($Item) {
                    $Hash = Get-FileHash -LiteralPath $Path -ErrorAction SilentlyContinue
                    if ($Hash) { return $Hash.Hash.ToLowerInvariant() }
                }
            }
            Start-Sleep -Milliseconds 150
        }
        return $null
    }
    foreach ($Property in $Manifest.source_sha256.PSObject.Properties) {
        $SourceHash = Get-ArtifactHash (Join-Path $SoftwareRoot $Property.Name)
        if ($null -eq $SourceHash) { throw "Firmware source not readable after build: $($Property.Name)" }
        if ($SourceHash -ne $Property.Value) {
            throw "Stale firmware source: $($Property.Name)"
        }
    }
    foreach ($Property in $Manifest.artifact_sha256.PSObject.Properties) {
        $ArtifactPath = Join-Path $SoftwareRoot "$OutputDir/$($Property.Name)"
        $ArtifactHash = Get-ArtifactHash $ArtifactPath
        if ($null -eq $ArtifactHash) { throw "Firmware artifact missing after build: $($Property.Name)" }
        if ($ArtifactHash -ne $Property.Value) {
            throw "Firmware artifact hash mismatch: $($Property.Name)"
        }
    }
    Write-Host "[PASS] rebuilt $Name, verified source/artifact hashes ($($Manifest.toolchain))" -ForegroundColor Green
}

# CoreMark needs a second image. The board image lets CoreMark pick its own
# iteration count so the run reaches EEMBC's ten-second reporting rule, which
# no simulation can afford. The
# regression therefore runs a second build of the same sources with the count
# pinned to one and the default seed set, which still exercises all three
# algorithms and reproduces EEMBC's published CRCs.
#
# This image is a test artefact, not something to program onto the board. Its
# manifest records the same sources but distinguishes ITERATIONS=1 in the
# compiler flags; both the manifest and artifacts are checked before staging.
if ($Apps -contains 'coremark') {
    # CoreMark treats an iteration count of 0 as "choose one yourself", so the
    # pin has to reach the compiler as a -D. The Makefile exposes DEFS for
    # exactly this: the shared CFLAGS stays identical for every image and the
    # board image leaves DEFS empty.
    $SimCommand = (@('make', '-C', $WslRoot,
        "RISCV_PREFIX=$RiscvPrefix",
        'APP=coremark/core_main.c',
        'BUILD_DIR=build/coremark_sim',
        "MARCH=$Isa",
        "RAM_BYTES=$RamBytes",
        "OPT=$Opt", "RELAX=$Relax", "EXTRA_CFLAGS=$ExtraCflags",
        "EXTRA_SRCS=$($AppSources['coremark'])",
        "EXTRA_HDRS=$($AppHeaders['coremark'])",
        'DEFS=-DITERATIONS=1',
        '-B') | ForEach-Object { ConvertTo-WslQuote $_ }) -join ' '
    $SimManifestPath = Join-Path $SoftwareRoot 'build/coremark_sim/firmware.json'
    $SimBeforeStamp = if (Test-Path -LiteralPath $SimManifestPath) { (Get-Item -LiteralPath $SimManifestPath).LastWriteTimeUtc } else { $null }
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & wsl.exe -d $WslDistro -- bash -c $SimCommand
        $SimBuildExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $SavedPreference }
    if (-not (Test-Path -LiteralPath $SimManifestPath) -or
        ($null -ne $SimBeforeStamp -and (Get-Item -LiteralPath $SimManifestPath).LastWriteTimeUtc -le $SimBeforeStamp)) {
        throw "CoreMark simulation image was not verified and refreshed (exit=$SimBuildExit)."
    }
    $SimManifest = Read-Manifest $SimManifestPath
    if ($SimManifest.ram_bytes -ne $RamBytes) { throw "CoreMark simulation RAM size does not match requested $RamBytes bytes." }
    if ($SimManifest.isa -ne $Isa -or $SimManifest.abi -ne 'ilp32' -or $SimManifest.app -ne $AppMain['coremark']) {
        throw 'CoreMark simulation manifest does not match requested app/ISA/ABI.'
    }
    $SimFlags = (Get-Content -LiteralPath (Join-Path $SoftwareRoot 'build/coremark_sim/build_flags.txt') -Raw).Trim()
    if ($SimFlags -ne $SimManifest.compiler_flags -or $SimFlags -notmatch '(^|\s)-DITERATIONS=1(\s|$)') {
        throw 'CoreMark simulation build flags are stale or do not specify ITERATIONS=1.'
    }
    foreach ($Property in $SimManifest.source_sha256.PSObject.Properties) {
        if ((Get-ArtifactHash (Join-Path $SoftwareRoot $Property.Name)) -ne $Property.Value) {
            throw "CoreMark simulation source hash mismatch: $($Property.Name)"
        }
    }
    foreach ($Property in $SimManifest.artifact_sha256.PSObject.Properties) {
        if ((Get-ArtifactHash (Join-Path $SoftwareRoot "build/coremark_sim/$($Property.Name)")) -ne $Property.Value) {
            throw "CoreMark simulation artifact hash mismatch: $($Property.Name)"
        }
    }
    $SimHex = Join-Path $SoftwareRoot 'build/coremark_sim/firmware.hex'
    if (-not (Test-Path -LiteralPath $SimHex)) {
        throw 'CoreMark simulation image was not produced (build/coremark_sim/firmware.hex).'
    }
    $SimTarget = Join-Path $SoftwareRoot 'build/coremark/sim_firmware.hex'
    Copy-Item -LiteralPath $SimHex -Destination $SimTarget -Force
    $SimSize = (Get-Item -LiteralPath $SimTarget).Length
    Write-Host "[PASS] built coremark simulation image (ITERATIONS=1, $SimSize bytes hex)" -ForegroundColor Green
}

# The reflex game also needs a second image for simulation: its board build
# waits three real seconds per round (150M core cycles at the 50 MHz the
# firmware models), which Icarus cannot simulate. -DGAME_FAST_SIM keeps the same
# code paths but runs two short rounds, which is what tb_game drives.
if ($Apps -contains 'game') {
    $SimCommand = (@('make', '-C', $WslRoot,
        "RISCV_PREFIX=$RiscvPrefix",
        'APP=game.c',
        "RAM_BYTES=$RamBytes",
        'BUILD_DIR=build/game_sim',
        'DEFS=-DGAME_FAST_SIM',
        '-B') | ForEach-Object { ConvertTo-WslQuote $_ }) -join ' '
    $SavedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & wsl.exe -d $WslDistro -- bash -c $SimCommand
    } finally { $ErrorActionPreference = $SavedPreference }
    $SimHex = Join-Path $SoftwareRoot 'build/game_sim/firmware.hex'
    if (-not (Test-Path -LiteralPath $SimHex)) {
        throw 'Reflex game simulation image was not produced (build/game_sim/firmware.hex).'
    }
    Write-Host "[PASS] built reflex game simulation image (2 rounds, $((Get-Item -LiteralPath $SimHex).Length) bytes hex)" -ForegroundColor Green
}
