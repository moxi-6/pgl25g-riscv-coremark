#!/usr/bin/env python3
"""Offline acceptance for the current CPU and touchscreen minesweeper submission.

Never opens serial/JTAG, programs a device, or starts PDS. Bitstreams must have
been built separately. --tests-only records reusable source-bound test evidence;
--audit-only refreshes packaging eligibility without rerunning unchanged tests.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from competition_artifacts import (DOCS, PENDING, audit_firmware, audit_historical,
                                   audit_release, files_in, inside, load, require,
                                   sha, source_snapshot, top_parameters, verify_files)

REGRESSION_IMAGES = ('software/build/firmware.hex', 'software/build/runtime_test/firmware.hex',
                     'software/build/perf_test/firmware.hex', 'software/build/perf_report/firmware.hex',
                     'software/build/coremark/sim_firmware.hex', 'software/build/game_sim/firmware.hex')


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def firmware_directories(args):
    return [('software/build/coremark', 'coremark/core_main.c'),
            (args.performance_firmware, 'coremark/core_main.c'),
            (args.validation_firmware, 'coremark/core_main.c'),
            ('software/build/mine', 'mine.c'), ('software/build/mine_sim', 'mine.c')]


def run_tests(root, out, args):
    require(args.powershell is not None, 'PowerShell is required')
    before = source_snapshot(root)
    inputs = {name: sha(inside(root, name)) for name in REGRESSION_IMAGES}
    for relative, app in firmware_directories(args):
        audit_firmware(root, relative, app)
        inputs.update(files_in(root, relative))
    params = top_parameters(root)
    receipt = {'status': 'RUNNING', 'started_utc': timestamp(), 'hardware_touched': False,
               'source_sha256': before, 'input_sha256': inputs, 'checks': [],
               'parameters': params, 'firmware_directories': firmware_directories(args)}
    receipt_path = out / 'tests.json'
    save(receipt_path, receipt)
    shell = [args.powershell, '-NoProfile', '-File']
    evidence = {}

    def run(name, command, marker, folders=(), timeout=1800):
        print(f'COMPETITION_CHECK_BEGIN {name}', flush=True)
        log = out / f'{name}.log'
        # Stream to a file so a timeout still leaves usable diagnostics.
        with log.open('w', encoding='utf-8') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        text = log.read_text(encoding='utf-8', errors='replace')
        passed = result.returncode == 0 and re.search(marker, text) is not None
        receipt['checks'].append({'name': name, 'exit_code': result.returncode, 'passed': passed,
                                  'log': log.relative_to(root).as_posix()})
        save(receipt_path, receipt)
        require(passed, f'{name} failed; inspect {log}')
        evidence[log.relative_to(root).as_posix()] = sha(log)
        for folder in folders:
            evidence.update(files_in(root, folder))
        print(f'COMPETITION_CHECK_PASS {name}', flush=True)

    try:
        run('system_regression', shell + [str(root / 'scripts/run_iverilog.ps1')], r'All \d+ simulations passed\.')
        for pattern in ('tb_*.compile.log', 'tb_*.run.log', 'regression_compile_inputs.jsonl'):
            evidence.update({p.relative_to(root).as_posix(): sha(p) for p in (root / 'build').glob(pattern)})
        extensions = (['--zmmul'] if params['ZMMUL_ENABLE'] else []) + (['--bitmanip'] if params['BITMANIP_ENABLE'] else [])
        current = extensions + (['--dual'] if params['DUAL_ISSUE'] else []) + ['--mul-cycles', str(params['MUL_CYCLES']), '--decode-pipeline', str(int(params['PIPELINE_DECODE']))]
        run('isa_current', [sys.executable, str(root / 'scripts/run_isa_checks.py'), *current,
                           '--output', str(out / 'isa_current')], r'\[PASS\] isa_checks ', ['build/competition_validation/isa_current'])
        run('isa_base', [sys.executable, str(root / 'scripts/run_isa_checks.py'),
                        '--output', str(out / 'isa_base')], r'\[PASS\] isa_checks ', ['build/competition_validation/isa_base'])
        run('clock_reset', [sys.executable, str(root / 'scripts/run_board_clock_checks.py')],
            r'div2_wrong_metadata: PASS', ['build/board_clock'])
        run('rom_banks', [sys.executable, str(root / 'scripts/run_imem_pair_checks.py')],
            r'\[PASS\] imem_pair WORDS=16384 ', ['build/imem_pair'])
        run('mine_application', [sys.executable, str(root / 'scripts/run_mine_checks.py')],
            r'(?i)(MINE_CHECKS_PASS|\[PASS\].*mine)', ['build/mine_checks'])
        require(load(root / 'build/mine_checks/summary.json').get('status') == 'PASS', 'Mine summary did not pass')
        common = current + (['--fast-dmem'] if params['FAST_DMEM'] else []) + [
            '--btb-entries', str(params['BTB_ENTRIES']), '--dmem-words', str(params['DMEM_WORDS'])]
        for kind, firmware in (('performance', args.performance_firmware), ('validation', args.validation_firmware)):
            label = f'competition_{kind}'
            options = ['--validation'] if kind == 'validation' else []
            run(f'coremark_{kind}', [sys.executable, str(root / 'scripts/run_coremark_profile.py'),
                                    '--label', label, '--firmware-dir', str(root / firmware), *common, *options],
                r'projected_coremark_per_mhz', [f'build/optimization_20261103/{label}'])
            require(load(root / f'build/optimization_20261103/{label}/summary.json').get('status') == 'PASS', f'{kind} profile failed')
        run('score_controls', [sys.executable, str(root / 'scripts/test_coremark_score.py')], r'\bOK\b')
        run('delivery_guards', [sys.executable, str(root / 'scripts/test_competition_delivery.py')], r'\bOK\b')
        require(before == source_snapshot(root), 'Source changed during tests; rerun against stable source')
        verify_files(root, inputs)
        receipt.update(status='PASS', evidence_sha256=evidence, completed_utc=timestamp())
    except Exception as exc:
        receipt.update(status='FAIL', failure=str(exc), completed_utc=timestamp())
        raise
    finally:
        save(receipt_path, receipt)
    return receipt


def audit(root, out, args):
    report = {'status': 'INCOMPLETE', 'hardware_touched': False, 'current_hardware_verified': False,
              'application': 'touchscreen_minesweeper', 'generated_utc': timestamp(),
              'pending_hardware': PENDING, 'checks': [], 'artifact_sha256': {}}

    def check(name, action):
        try:
            value = action()
            report['checks'].append({'name': name, 'status': 'PASS', 'evidence': value})
            return value
        except (OSError, ValueError, KeyError, TypeError) as exc:
            report['checks'].append({'name': name, 'status': 'FAIL', 'failure': str(exc)})
            return None

    def tests():
        receipt = load(out / 'tests.json')
        require(receipt.get('status') == 'PASS', 'Run --tests-only against the final source/firmware first')
        require(receipt.get('source_sha256') == source_snapshot(root), 'Current sources differ from tested sources')
        require(receipt.get('firmware_directories') == [list(x) for x in firmware_directories(args)], 'Validation firmware selection changed')
        verify_files(root, receipt['input_sha256'])
        verify_files(root, receipt['evidence_sha256'])
        report['artifact_sha256'].update(receipt['input_sha256'])
        report['artifact_sha256'].update(receipt['evidence_sha256'])
        report['artifact_sha256']['build/competition_validation/tests.json'] = sha(out / 'tests.json')
        return {'receipt': 'build/competition_validation/tests.json', 'checks': len(receipt['checks'])}

    check('current_tests', tests)
    for relative, app in firmware_directories(args):
        if check(f'firmware:{relative}', lambda relative=relative, app=app: audit_firmware(root, relative, app)):
            report['artifact_sha256'].update(files_in(root, relative))
    for target, app in (('cpu', 'coremark'), ('mine', 'mine')):
        release = check(f'release:{target}', lambda target=target, app=app: audit_release(root, target, app))
        if release:
            report['artifact_sha256'].update(files_in(root, release['directory']))
    history = check('historical_baseline_and_ila', lambda: audit_historical(root))
    if history:
        for directory in [item['directory'] for item in history['captures']] + [history['ila_directory']]:
            report['artifact_sha256'].update(files_in(root, directory))
    for name in DOCS:
        check(f'document:{name}', lambda name=name: require((root / 'docs' / name).is_file(), f'Missing document {name}') or {'path': f'docs/{name}'})
    report['source_sha256'] = source_snapshot(root, include_docs=True)
    if all(item['status'] == 'PASS' for item in report['checks']):
        report['status'] = 'OFFLINE_READY_HARDWARE_PENDING'
    save(out / 'summary.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--audit-only', action='store_true')
    mode.add_argument('--tests-only', action='store_true')
    parser.add_argument('--powershell', default=shutil.which('pwsh') or shutil.which('powershell'))
    parser.add_argument('--performance-firmware', default='software/build/coremark_sim')
    parser.add_argument('--validation-firmware', default='software/build/coremark_o3_lto_inline_b_validation_sim')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = root / 'build/competition_validation'
    out.mkdir(parents=True, exist_ok=True)
    for name, _ in firmware_directories(args):
        inside(root, name)
    if not args.audit_only:
        run_tests(root, out, args)
        if args.tests_only:
            print('COMPETITION_TESTS_PASS: file-bound offline evidence; no hardware accessed.')
            return
    report = audit(root, out, args)
    print(json.dumps({'status': report['status'], 'checks': report['checks']}, indent=2, ensure_ascii=False))
    if report['status'] != 'OFFLINE_READY_HARDWARE_PENDING':
        raise SystemExit(2)


if __name__ == '__main__':
    main()
