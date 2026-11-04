$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$env:PATH = (Join-Path (Split-Path -Parent $ProjectRoot) 'tools/iverilog/bin') + [IO.Path]::PathSeparator + $env:PATH
$Fixture = Join-Path $ProjectRoot ('build/regression_guard_' + [guid]::NewGuid().ToString('N'))
foreach ($Subdir in @('scripts','rtl/core','sim','software/build/runtime_test','software/build/perf_test','software/build/perf_report','software/build/coremark','software/build/game','software/build/game_sim','build')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Fixture $Subdir) | Out-Null
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run_iverilog.ps1') -Destination (Join-Path $Fixture 'scripts/run_iverilog.ps1')
foreach ($Source in @('rv32i_pkg.sv','rv32i_alu.sv')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "rtl/core/$Source") -Destination (Join-Path $Fixture "rtl/core/$Source")
}
$Shell = (Get-Process -Id $PID).Path
function Expect-Failure([string]$CaseName) {
    # The fixture deliberately breaks inputs; the child's stderr must not abort this guard.
    $ErrorActionPreference = 'Continue'
    $Result = @(& $Shell -NoProfile -File (Join-Path $Fixture 'scripts/run_iverilog.ps1') 2>&1)
    $Code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $Result | Set-Content -LiteralPath (Join-Path $Fixture "$CaseName.log") -Encoding utf8
    if ($Code -eq 0 -or $Result -match 'All \d+ simulations passed') { throw "Guard failed: $CaseName" }
    Write-Host "[PASS] regression_guard $CaseName exit=$Code"
}
Expect-Failure 'missing_firmware'
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/firmware.hex')
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/runtime_test/firmware.hex')
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/perf_test/firmware.hex')
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/perf_report/firmware.hex')
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/coremark/firmware.hex')
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/game_sim/firmware.hex')
Expect-Failure 'missing_coremark_sim_image'
'00000013' | Set-Content -LiteralPath (Join-Path $Fixture 'software/build/coremark/sim_firmware.hex')
'invalid syntax' | Set-Content -LiteralPath (Join-Path $Fixture 'sim/tb_alu.sv')
'stale executable' | Set-Content -LiteralPath (Join-Path $Fixture 'build/tb_alu.vvp')
Expect-Failure 'compile_error'
if (Test-Path (Join-Path $Fixture 'build/tb_alu.vvp')) { throw 'Stale executable survived compilation failure' }
'module tb_alu; initial $fatal(1, "injected failure"); endmodule' | Set-Content -LiteralPath (Join-Path $Fixture 'sim/tb_alu.sv')
Expect-Failure 'simulation_fatal'
'module tb_alu; initial $finish; endmodule' | Set-Content -LiteralPath (Join-Path $Fixture 'sim/tb_alu.sv')
Expect-Failure 'missing_pass_marker'
Write-Host "All 5 failure guards passed. Isolated evidence: $Fixture"
