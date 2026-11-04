param([string]$WorkDir='C:/fpga/riscv_l50/coremark_ila_20261101')
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$work=[IO.Path]::GetFullPath($WorkDir).Replace('\','/')
& python (Join-Path $PSScriptRoot 'prepare_coremark_ila.py') --work-dir $work
if($LASTEXITCODE -ne 0){throw 'ILA staging failed'}
$env:PANGO_LICENSE_FILE='C:/fpga/riscv_l50/licenses/provided.lic'
Push-Location $work
try {
    & C:/pango/PDS_2022.2-SP4.2-ads/bin/pds_shell.exe -file "$work/build.tcl" -work_dir $work -project_name coremark_ila *> "$work/build.log"
    if($LASTEXITCODE -ne 0){throw 'ILA synthesis/map/route failed; inspect build.log'}
    $log=[IO.File]::ReadAllText("$work/build.log")
    $timing=[IO.File]::ReadAllText("$work/report_timing/atk_l50_top.rtr")
    if($log -match '(?m)^\s*E:' -or $timing -notmatch 'Design Summary\s*:\s*All Constraints Met\.'){throw 'ILA timing failed'}
    & C:/pango/PDS_2022.2-SP4.2-ads/bin/pds_shell.exe -project "$work/coremark_ila.pds" -run gen_bit_stream *> "$work/generate.log"
    if($LASTEXITCODE -ne 0 -or [IO.File]::ReadAllText("$work/generate.log") -notmatch 'Process "Generate Bitstream" done\.'){throw 'ILA bitstream generation failed'}
    $out=Join-Path $project 'build/coremark_ila'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    foreach($file in @('pds_design.sv','fixed_pins.fdc','coremark_ila.fic','probe_schema.json','build.tcl','build.log','generate.log')){Copy-Item "$work/$file" "$out/$file"}
    Copy-Item "$work/generate_bitstream/atk_l50_top.sbit" "$out/atk_l50_top.sbit"
    # cfg_assign_file needs the matching mask file; without it the programmer
    # aborts with Configuration-0004 before any bit is shifted.
    Copy-Item "$work/generate_bitstream/atk_l50_top.smsk" "$out/atk_l50_top.smsk"
    Copy-Item "$work/report_timing/atk_l50_top.rtr" "$out/timing.rtr"
    Copy-Item "$work/device_map/atk_l50_top.pcf" "$out/pins.pcf"
    Get-FileHash "$out/atk_l50_top.sbit"
    Write-Host "COREMARK_ILA_BUILD_PASS $out"
} finally {Pop-Location}
