"""Build isolated CoreMark compiler variants, then profile unchanged algorithms."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--variants', nargs='+', default=['o3_relax', 'o3', 'os_relax', 'o3_unroll'])
p.add_argument('--bitmanip',action='store_true')
p.add_argument('--fast',action='store_true')
p.add_argument('--validation',action='store_true')
p.add_argument('--ram-bytes',type=int,choices=(8192,16384),default=16384)
p.add_argument('--build-only',action='store_true')
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
sw = root / 'software'
out = root / 'build/cpu_optimization_20261104/compiler'
out.mkdir(parents=True, exist_ok=True)
wsl_sw = '/mnt/' + sw.drive[0].lower() + sw.as_posix()[2:]
sources = ' '.join('coremark/' + name + '.c' for name in (
    'core_list_join','core_matrix','core_state','core_util','core_portme','ee_printf','softmath'))
headers = 'coremark/core_portme.h coremark/coremark.h coremark/board_coremark_config.h'
variants = {'o3_relax': ('-O3',1,''), 'o3': ('-O3',0,''),
            'os_relax': ('-Os',1,''), 'o3_unroll': ('-O3',1,'-funroll-loops'),
            'o3_lto': ('-O3',1,'-flto'),
            'o3_lto_unroll': ('-O3',1,'-flto -funroll-loops'),
            'o3_lto_inline': ('-O3',1,'-flto -finline-limit=1000')}
results = json.loads((out / 'summary.json').read_text()) if (out / 'summary.json').exists() else {}
for name in args.variants:
    opt, relax, extra = variants[name]
    if args.bitmanip: name += '_b'
    if args.validation: name += '_validation'
    isa='rv32i_zba_zbb_zmmul' if args.bitmanip else 'rv32i_zmmul'
    build = sw / f'build/coremark_{name}_sim'
    manifest = build / 'firmware.json'
    old_stamp = manifest.stat().st_mtime_ns if manifest.exists() else None
    command = ['make','-C',wsl_sw,'APP=coremark/core_main.c',
               f'BUILD_DIR=build/coremark_{name}_sim',f'MARCH={isa}',
               f'RAM_BYTES={args.ram_bytes}',
               f'OPT={opt}',f'RELAX={relax}',f'EXTRA_CFLAGS={extra}',
               f'EXTRA_SRCS={sources}',f'EXTRA_HDRS={headers}',
               'DEFS=-DITERATIONS=1'+(' -DVALIDATION_RUN=1' if args.validation else ''),'-B']
    run = subprocess.run(['wsl.exe','-d','Ubuntu','--','bash','-c',shlex.join(command)],
                         capture_output=True, timeout=180)
    (out / f'{name}_build.log').write_bytes(run.stdout + run.stderr)
    if not manifest.exists() or manifest.stat().st_mtime_ns == old_stamp:
        results[name] = {'status':'BUILD_FAILED','returncode':run.returncode}
        print(f'{name}: BUILD_FAILED, inspect build log', flush=True)
    else:
        fw = json.loads(manifest.read_text(encoding='utf-8'))
        assert fw['isa'] == isa
        if args.build_only:
            print(f'{name}: BUILD_PASS {fw["rom_bytes"]} bytes RAM={fw["ram_bytes"]}',flush=True)
            continue
        print(f'{name}: built {fw["rom_bytes"]} bytes, profiling', flush=True)
        options=(['--bitmanip'] if args.bitmanip else [])+(['--fast-dmem','--decode-pipeline','0'] if args.fast else [])
        if args.validation: options+=['--validation']
        profile = subprocess.run([sys.executable,str(root/'scripts/run_coremark_profile.py'),*options,
            '--label',f'cpu_r4_{name}_20261104','--zmmul','--firmware-dir',str(build)],
            capture_output=True, text=True, timeout=660)
        (out / f'{name}_profile.log').write_text(profile.stdout+profile.stderr,encoding='utf-8')
        summary_path = root / f'build/optimization_20261103/cpu_r4_{name}_20261104/summary.json'
        results[name] = {'status':'PASS' if profile.returncode == 0 else 'PROFILE_FAILED',
                         'rom_bytes':fw['rom_bytes'],'compiler_flags':fw['compiler_flags']}
        if profile.returncode == 0:
            results[name]['metrics'] = json.loads(summary_path.read_text())['metrics']
        print(json.dumps({name:results[name]}), flush=True)
    (out / 'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
