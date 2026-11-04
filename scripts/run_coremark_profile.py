"""Compare CPU changes over CoreMark's exact, single-iteration timer interval."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from split_imem_banks import split_imem_banks

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--label', required=True)
parser.add_argument('--core-source', type=Path)
parser.add_argument('--zmmul', action='store_true')
parser.add_argument('--fast-dmem', action='store_true')
parser.add_argument('--bitmanip', action='store_true')
parser.add_argument('--validation', action='store_true')
parser.add_argument('--dual', action='store_true')
parser.add_argument('--btb-entries', type=int, choices=(16,32,64,128,256), default=16)
parser.add_argument('--mul-cycles', type=int, choices=(2,3), default=3)
parser.add_argument('--dmem-words', type=int, choices=(2048,4096), default=4096)
parser.add_argument('--decode-pipeline', type=int, choices=(0, 1), default=1)
parser.add_argument('--firmware-dir', type=Path)
args = parser.parse_args()
if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.label):
    raise ValueError('Use an ASCII label')
root = Path(__file__).resolve().parents[1]
out = root / 'build/optimization_20261103' / args.label
out.mkdir(parents=True, exist_ok=True)
local = root.parent / 'tools/iverilog/bin'
compiler = str(local / 'iverilog.exe') if (local / 'iverilog.exe').exists() else shutil.which('iverilog')
runtime = str(local / 'vvp.exe') if (local / 'vvp.exe').exists() else shutil.which('vvp')
if not compiler or not runtime:
    raise RuntimeError('Icarus Verilog is required')
sources = [root / name.strip() for name in (root / 'boards/atk_l50/cpu.f').read_text().splitlines()
           if name.strip() and not name.startswith('#')]
if args.core_source:
    sources = [args.core_source.resolve() if p.name == 'rv32i_core_3stage.sv' else p for p in sources]
bench = root / 'sim/tb_coremark.sv'
binary = out / 'profile.vvp'
source_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [bench]}
firmware_dir = args.firmware_dir.resolve() if args.firmware_dir else root / 'software/build/coremark_sim'
firmware_hex = firmware_dir / 'firmware.hex'
staged_hex = out / 'firmware.hex'
shutil.copy2(firmware_hex, staged_hex)
split_imem_banks(staged_hex, 16384)
shutil.copy2(firmware_dir / 'firmware.dis', out / 'firmware.dis')
compile_options = [f'-Ptb_coremark.ZMMUL_ENABLE={int(args.zmmul)}',
                   f'-Ptb_coremark.DUAL_ISSUE={int(args.dual)}',
                   f'-Ptb_coremark.BTB_ENTRIES={args.btb_entries}',
                   f'-Ptb_coremark.MUL_CYCLES={args.mul_cycles}',
                   f'-Ptb_coremark.DMEM_WORDS={args.dmem_words}',
                   f'-Ptb_coremark.BITMANIP_ENABLE={int(args.bitmanip)}',
                   f'-Ptb_coremark.VALIDATION_RUN={int(args.validation)}',
                   f'-Ptb_coremark.FAST_DMEM={int(args.fast_dmem)}',
                   f'-Ptb_coremark.PIPELINE_DECODE={args.decode_pipeline}',
                   f'-DCM_MEM_FILE="{staged_hex.relative_to(root).as_posix()}"']
compiled = subprocess.run([compiler, '-g2012', '-s', 'tb_coremark', '-o', str(binary), *compile_options,
                           *map(str, sources), str(bench)], cwd=root, capture_output=True, text=True)
(out / 'compile.log').write_text(compiled.stdout + compiled.stderr, encoding='utf-8')
if compiled.returncode:
    raise RuntimeError(f'Compilation failed; see {out / "compile.log"}')
disassembly = (firmware_dir / 'firmware.dis').read_text()
symbols = [(int(a, 16), n) for a, n in re.findall(r'^([0-9a-fA-F]+) <([^>]+)>:', disassembly, re.M)]
addresses = {name: address for address, name in symbols}
def symbol_end(name):
    return min(address for address, _ in symbols if address > addresses[name])
options = {'profile_start_pc': addresses['start_time'], 'profile_stop_pc': addresses['stop_time'],
           'profile_stop_end': symbol_end('stop_time'), 'profile_mul_start': addresses.get('__mulsi3', 0),
           'profile_mul_end': symbol_end('__mulsi3') if '__mulsi3' in addresses else 0}
print(f'PROFILE_SIMULATION_BEGIN {args.label}', flush=True)
result = subprocess.run([runtime, str(binary), '+profile_coremark',
                         *[f'+{name}={value:x}' for name, value in options.items()]],
                        cwd=root, capture_output=True, text=True, timeout=600)
log = result.stdout + result.stderr
(out / 'run.log').write_text(log, encoding='utf-8')
if result.returncode or '[PASS] coremark' not in log:
    raise RuntimeError(f'CoreMark correctness failed; see {out / "run.log"}')
profiles = re.findall(r'^\[PROFILE\] (.*)$', log, re.M)
if len(profiles) != 1:
    raise RuntimeError('Expected exactly one timed benchmark interval')
metrics = {name: int(value) for name, value in re.findall(r'(\w+)=(\d+)', profiles[0])}
ticks = int(re.search(r'^UART\[\d+\] Total ticks\s*:\s*(\d+)', log, re.M)[1])
if metrics['cycles'] != ticks:
    raise RuntimeError('Profile interval differs from CoreMark reported ticks')
metrics['cpi'] = metrics['cycles'] / metrics['retired']
metrics['projected_coremark_per_mhz'] = 1_000_000 / metrics['cycles']
report = {'status': 'PASS', 'label': args.label, 'metrics': metrics, 'symbols': options,
          'source_sha256': source_hashes,
          'firmware_hex_sha256': hashlib.sha256(staged_hex.read_bytes()).hexdigest(),
          'configuration': {'zmmul': args.zmmul, 'decode_pipeline': args.decode_pipeline,
                            'fast_dmem': args.fast_dmem, 'bitmanip':args.bitmanip,
                            'validation':args.validation,'dual':args.dual,'btb_entries':args.btb_entries,
                            'mul_cycles':args.mul_cycles,'dmem_words':args.dmem_words},
          'scope': 'Single-iteration simulation with matching CRCs; independent stall counts overlap; board score requires >=10s hardware run.'}
(out / 'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(metrics, indent=2), flush=True)
