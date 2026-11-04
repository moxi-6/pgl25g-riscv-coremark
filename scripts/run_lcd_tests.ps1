$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Bin = Join-Path (Split-Path -Parent $ProjectRoot) 'tools/iverilog/bin'
New-Item -ItemType Directory -Force (Join-Path $ProjectRoot 'build') | Out-Null
Push-Location $ProjectRoot
try {
    & (Join-Path $Bin 'iverilog.exe') -g2012 -s tb_lcd -o build/tb_lcd.vvp rtl/periph/lcd_800x480.sv rtl/periph/lcd_test_pattern.sv sim/tb_lcd.sv 2> build/tb_lcd.compile.log
    if ($LASTEXITCODE -ne 0) { throw 'LCD simulation compile failed.' }
    $Result = @(& (Join-Path $Bin 'vvp.exe') build/tb_lcd.vvp 2>&1)
    $Code = $LASTEXITCODE
    $Result | Set-Content build/tb_lcd.run.log -Encoding utf8
    $Result | ForEach-Object { Write-Host $_ }
    if ($Code -ne 0 -or -not ($Result -match '\[PASS\] lcd:')) { throw 'LCD simulation failed.' }
    & (Join-Path $Bin 'iverilog.exe') -g2012 -s atk_l50_lcd -o build/lcd_top.vvp -c boards/atk_l50/lcd.f 2> build/lcd_top.compile.log
    if ($LASTEXITCODE -ne 0) { throw 'LCD board top compile failed.' }
    & (Join-Path $Bin 'iverilog.exe') -g2012 -s tb_lcd_game_display -o build/tb_lcd_game_display.vvp rtl/periph/lcd_game_display.sv sim/tb_lcd_game_display.sv 2> build/tb_lcd_game_display.compile.log
    if ($LASTEXITCODE -ne 0) { throw 'LCD HUD compile failed.' }
    $HudResult = @(& (Join-Path $Bin 'vvp.exe') build/tb_lcd_game_display.vvp 2>&1)
    $HudCode = $LASTEXITCODE
    $HudResult | Set-Content build/tb_lcd_game_display.run.log -Encoding utf8
    $HudResult | ForEach-Object { Write-Host $_ }
    if ($HudCode -ne 0 -or -not ($HudResult -match '\[PASS\] lcd_game_display:')) { throw 'LCD HUD simulation failed.' }
    & (Join-Path $Bin 'iverilog.exe') -g2012 -s atk_l50_lcd_game -o build/lcd_game_top.vvp -c boards/atk_l50/lcd_game.f 2> build/lcd_game_top.compile.log
    if ($LASTEXITCODE -ne 0) { throw 'LCD CPU board top compile failed.' }
} finally { Pop-Location }
