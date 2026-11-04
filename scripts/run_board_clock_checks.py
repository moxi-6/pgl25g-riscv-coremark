#!/usr/bin/env python3
"""Verify actual board clock/reset/UART behavior using Pango's buffer model."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from split_imem_banks import split_imem_banks


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pds-root', type=Path, default=Path('C:/pango/PDS_2022.2-SP4.2-ads'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = root / 'build/board_clock'
    out.mkdir(parents=True, exist_ok=True)
    tool_dir = root.parent / 'tools/iverilog/bin'
    vendor_model = args.pds_root / 'arch/vendor/pango/verilog/simulation/GTP_CLKBUFG.v'
    if not vendor_model.is_file():
        raise FileNotFoundError(vendor_model)
    sources = [root / line.strip() for line in (root / 'boards/atk_l50/cpu.f').read_text().splitlines()
               if line.strip() and not line.startswith('#')]
    sources += [vendor_model, root / 'sim/tb_board_clock.sv']
    # LUI x1,MMIO; LW x2,CLOCK_HZ; LUI x3,RAM; SW x2,0(x3);
    # ADDI x4,0,0x55; SW x4,UART; ADDI x5,0,0xa5; SW x5,GPIO; EBREAK.
    program = [0x100000B7, 0x0200A103, 0x400001B7, 0x0021A023,
               0x05500213, 0x0040A223, 0x0A500293, 0x0050A023, 0x00100073]
    image = out / 'program.hex'
    image.write_text(''.join(f'{ins:08x}\n' for ins in program), encoding='ascii')
    banks = split_imem_banks(image, 16384)
    original_hashes = {str(path): digest(path) for path in sources}
    results = []
    for divisor, invalid_clock in [(1, False), (2, False), (4, False), (2, True)]:
        name = f'div{divisor}' + ('_wrong_metadata' if invalid_clock else '')
        binary = out / f'{name}.vvp'
        binary.unlink(missing_ok=True)
        command = [str(tool_dir / 'iverilog.exe'), '-g2012', '-s', 'tb_board_clock',
                   f'-Ptb_board_clock.CPU_CLOCK_DIV={divisor}', '-o', str(binary)]
        if invalid_clock:
            command.append('-Ptb_board_clock.DUT_CLOCK_HZ=50000000')
        compiled = subprocess.run(command + list(map(str, sources)), cwd=root, capture_output=True, text=True)
        (out / f'{name}.compile.log').write_text(compiled.stdout + compiled.stderr, encoding='utf-8')
        if compiled.returncode:
            raise RuntimeError(f'{name} failed to compile')
        for path in sources:
            if digest(path) != original_hashes[str(path)]:
                raise RuntimeError(f'Source changed during clock checks: {path}')
        run = subprocess.run([str(tool_dir / 'vvp.exe'), str(binary)], cwd=root,
                             capture_output=True, text=True, timeout=90)
        (out / f'{name}.run.log').write_text(run.stdout + run.stderr, encoding='utf-8')
        if invalid_clock:
            passed = run.returncode != 0 and 'MMIO_CLOCK_MISMATCH' in run.stdout
        else:
            passed = run.returncode == 0 and f'[PASS] board_clock div={divisor} ' in run.stdout
        results.append({'case': name, 'passed': passed, 'returncode': run.returncode,
                        'negative_guard': invalid_clock, 'executable_sha256': digest(binary)})
        print(f'{name}: {"PASS" if passed else "FAIL"}\n{run.stdout}', end='', flush=True)
        if not passed:
            raise RuntimeError(f'{name} did not produce the expected result')
    evidence = {'results': results, 'source_sha256': original_hashes, 'firmware': banks,
                'scope': 'Functional simulation of actual board divider, reset and UART; not post-route timing or hardware proof.'}
    (out / 'summary.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
