$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
$Bin=Join-Path (Split-Path -Parent $ProjectRoot) 'tools/iverilog/bin'
Push-Location $ProjectRoot
try {
    $Sources=@(Get-Content boards/atk_l50/cpu.f)
    foreach($Name in @('tb_shooter','tb_shooter_display')) {
        $Inputs=@(if($Name -eq 'tb_shooter'){$Sources}else{'rtl/periph/lcd_shooter_display.sv'})
        & (Join-Path $Bin 'iverilog.exe') -g2012 -s $Name -o "build/$Name.vvp" @Inputs "sim/$Name.sv" 2> "build/$Name.compile.log"
        if($LASTEXITCODE -ne 0){throw "$Name compile failed"}
        $Result=@(& (Join-Path $Bin 'vvp.exe') "build/$Name.vvp" 2>&1)
        $Code=$LASTEXITCODE
        $Result | Set-Content "build/$Name.run.log" -Encoding utf8
        $Result | ForEach-Object {Write-Host $_}
        if($Code -ne 0 -or -not($Result -match '\[PASS\] shooter')){throw "$Name failed"}
    }
} finally {Pop-Location}
