#!/usr/bin/env python3
"""Run the actual mine firmware through CPU + SoC + GT9147 and render RTL PNGs."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/mine_checks'
TOOLS=ROOT.parent/'tools/iverilog/bin'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def simulate(name,sources,extra=(),timeout=1200):
    binary=OUT/f'{name}.vvp'
    command=[str(TOOLS/'iverilog.exe'),'-g2012','-s',name,'-o',str(binary),*sources,f'sim/{name}.sv']
    result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
    (OUT/f'{name}.compile.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode: raise RuntimeError(f'{name} compile failed: {result.stderr[-2000:]}')
    result=subprocess.run([str(TOOLS/'vvp.exe'),str(binary),*extra],cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    log=result.stdout+result.stderr
    (OUT/f'{name}.run.log').write_text(log,encoding='utf-8')
    print(log,flush=True)
    if result.returncode or '[PASS]' not in log or 'ERROR:' in log: raise RuntimeError(f'{name} simulation failed')
    return log


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    firmware=ROOT/'software/build/mine_sim'
    manifest=json.loads((firmware/'firmware.json').read_text(encoding='utf-8-sig'))
    if manifest['isa']!='rv32i' or manifest.get('ram_bytes')!=16384:
        raise RuntimeError('mine_sim must use RV32I and 16 KiB RAM')
    for source,value in manifest['source_sha256'].items():
        if sha(ROOT/'software'/source)!=value: raise RuntimeError(f'Stale firmware source: {source}')
    if sha(firmware/'firmware.hex')!=manifest['artifact_sha256']['firmware.hex']:
        raise RuntimeError('mine_sim image differs from its manifest')
    memory_map=(firmware/'firmware.map').read_text()
    symbols=[]
    for name in ('mine','blocked','open_cell'):
        found=re.search(r'\.bss\.'+name+r'\s+(0x[0-9a-fA-F]+)',memory_map)
        if not found: raise RuntimeError(f'Missing read-only test observer symbol {name}')
        symbols.append(f"localparam integer ADDR_{name.upper()}=32'h{int(found[1],16):08x};")
    (OUT/'mine_symbols.svh').write_text('\n'.join(symbols)+'\n',encoding='ascii')
    sources=[x.strip() for x in (ROOT/'boards/atk_l50/mine.f').read_text(encoding='utf-8-sig').splitlines() if x.strip() and not x.startswith('#')]
    evidence_sources=sources+['sim/gt9147_model.sv','sim/tb_mine.sv','sim/tb_mine_render.sv','sim/tb_mine_top_smoke.sv',
        'software/mine.c','rtl/periph/mine_font.hex','scripts/run_mine_checks.py']
    source_hashes={p:sha(ROOT/p) for p in evidence_sources}
    simulate('tb_mine_top_smoke',sources+['sim/gt9147_model.sv'],timeout=180)
    log=simulate('tb_mine',sources+['sim/gt9147_model.sv'])
    if '[PASS] mine_integration ' not in log: raise RuntimeError('Missing full mine integration completion')
    previews=[]
    for name in ('initial','lost','stage3','won'):
        ppm=OUT/f'{name}.ppm'
        simulate('tb_mine_render',['rtl/periph/lcd_mine_display.sv'],
                 [f'+state=build/mine_checks/{name}.hex',f'+ppm=build/mine_checks/{name}.ppm'],timeout=180)
        png=OUT/f'{name}.png'
        with Image.open(ppm) as image: image.save(png)
        previews.append(str(png.relative_to(ROOT)))
    for path,value in source_hashes.items():
        if sha(ROOT/path)!=value: raise RuntimeError(f'Source changed during verification: {path}')
    evidence={'status':'PASS','source_sha256':source_hashes,'firmware_sha256':sha(firmware/'firmware.hex'),
        'cases':['board_top_pin_startup','real_cpu_gt9147_i2c','keys_move_open_hold_flag','touch_flag_toggle',
                 'first_click_3x3_safe','exact_mine_counts','loss_all_mines_wrong_flags','explicit_restart',
                 'eight_increasing_difficulty_stages','terrain_and_mine_map_changes','eight_stage_wrap','rtl_pixel_render'],
        'preview_paths':previews,'scope':'Offline simulation; board electrical/touch calibration and PDS timing remain separate gates.'}
    (OUT/'summary.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print('[PASS] mine_checks all cases and RTL previews',flush=True)


if __name__=='__main__': main()
