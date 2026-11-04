"""Fail-closed file audits shared by the current CPU + minesweeper delivery."""
import hashlib
import json
from pathlib import Path
import re
from coremark_score import evaluate

SOURCE_DIRS = ('rtl', 'sim', 'scripts', 'constraints', 'boards', 'software', 'windows_scripts')
DOCS = ('参赛作品说明书.md', '性能分析报告.md', '提交材料清单.md',
        '演示操作指南.md', 'THIRD_PARTY_NOTICES.md')
PENDING = ['Current dual-issue CPU hardware ILA capture (only the early baseline ILA is archived)',
           'Physical demo video recording',
           'Final competition submission-format check']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def require(ok, message):
    if not ok:
        raise ValueError(message)


def inside(base, relative):
    base = Path(base).resolve()
    path = (base / relative).resolve()
    require(path.is_relative_to(base), f'Path escapes evidence root: {relative}')
    return path


def source_snapshot(root, include_docs=False):
    files = []
    for folder in SOURCE_DIRS:
        for path in (root / folder).rglob('*'):
            rel = path.relative_to(root)
            if path.is_file() and 'build' not in rel.parts and '__pycache__' not in rel.parts and path.suffix != '.pyc':
                require(path.resolve().is_relative_to(root.resolve()), f'External source link: {rel}')
                files.append(path)
    if include_docs:
        # Public release documents are explicit: development journals, local
        # licensing requests and personnel research are not release inputs.
        files.extend(root / 'docs' / name for name in DOCS)
        files.extend((root / 'README.md', root / 'LICENSE'))
    return {path.relative_to(root).as_posix(): sha(path) for path in sorted(set(files))}


def files_in(root, directory):
    directory = inside(root, directory)
    require(directory.is_dir(), f'Missing evidence directory: {directory}')
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(directory.rglob('*'))
            if p.is_file() and p.suffix not in ('.vvp', '.pyc') and '__pycache__' not in p.parts}


def verify_files(root, expected):
    require(bool(expected), 'Empty file evidence')
    for relative, digest in expected.items():
        path = inside(root, relative)
        require(path.is_file() and sha(path) == digest.lower(), f'Missing/stale/corrupt file: {relative}')


def audit_firmware(root, relative, expected_app=None):
    directory = inside(root, relative)
    manifest = load(directory / 'firmware.json')
    require(manifest.get('abi') == 'ilp32', f'{relative}: unsupported ABI')
    if expected_app:
        require(manifest.get('app') == expected_app, f'{relative}: incorrect application')
    verify_files(root / 'software', manifest.get('source_sha256', {}))
    verify_files(directory, manifest.get('artifact_sha256', {}))
    flags = (directory / 'build_flags.txt').read_text(encoding='utf-8-sig').strip()
    require(flags == manifest.get('compiler_flags'), f'{relative}: compiler flag mismatch')
    for name in ('firmware.elf', 'firmware.bin', 'firmware.hex', 'firmware.dis', 'firmware.map', 'toolchain.txt'):
        require((directory / name).is_file(), f'{relative}: missing {name}')
    return {'directory': relative, 'app': manifest['app'], 'isa': manifest['isa'],
            'hex_sha256': sha(directory / 'firmware.hex'), 'clock_hz': manifest.get('clock_hz'),
            'ram_bytes': manifest.get('ram_bytes'), 'compiler_flags': flags}


def top_parameters(root):
    text = (root / 'rtl/top/atk_l50_top.sv').read_text(encoding='utf-8-sig')
    names = ('INPUT_CLOCK_HZ', 'CLOCK_HZ', 'CPU_CLOCK_DIV', 'BAUD', 'BTB_ENTRIES', 'MUL_CYCLES', 'DMEM_WORDS')
    result = {}
    for name in names:
        match = re.search(r'parameter\s+integer\s+' + name + r'\s*=\s*([0-9_]+)', text)
        require(match is not None, f'Missing literal board parameter: {name}')
        result[name] = int(match[1].replace('_', ''))
    for name in ('ZMMUL_ENABLE', 'BITMANIP_ENABLE', 'DUAL_ISSUE', 'FAST_DMEM', 'PIPELINE_DECODE'):
        match = re.search(r'parameter\s+bit\s+' + name + r"\s*=\s*1'b([01])", text)
        require(match is not None, f'Missing literal board feature: {name}')
        result[name] = bool(int(match[1]))
    require(result['INPUT_CLOCK_HZ'] == result['CLOCK_HZ'] * result['CPU_CLOCK_DIV'], 'Clock divider/metadata mismatch')
    return result


def audit_combined_source(root, target, combined):
    # run_pds concatenates verified source files with an explicit marker and
    # ASCII encoding. Match each actual source body, not just a stale stored hash.
    expected_names = [line.strip() for line in (root / f'boards/atk_l50/{target}.f').read_text(encoding='utf-8-sig').splitlines()
                      if line.strip() and not line.startswith('#')]
    text = combined.read_text(encoding='ascii').replace('\r\n', '\n')
    chunks = re.split(r'^// Source: ([^\n]+)\n', text, flags=re.M)
    require(chunks[0].strip() == '' and chunks[1::2] == expected_names, f'{target}: combined source list mismatch')
    for relative, body in zip(chunks[1::2], chunks[2::2]):
        original = inside(root, relative).read_text(encoding='utf-8-sig')
        original = original.encode('ascii', errors='replace').decode('ascii').replace('\r\n', '\n')
        require(original.strip() == body.strip(), f'{target}: stale embedded RTL {relative}')


def audit_release(root, target, app):
    relative = f'build/board_release/{target}/{app}'
    directory = inside(root, relative)
    release = load(directory / 'release.json')
    top = 'atk_l50_top' if target == 'cpu' else 'atk_l50_mine'
    require((release.get('target'), release.get('firmware_app'), release.get('top'), release.get('device')) ==
            (target, app, top, 'PGL25G'), f'{target}: wrong release identity')
    entries = release.get('files', [])
    hashes = {e['file']: e['sha256'].lower() for e in entries}
    require(len(hashes) == len(entries), f'{target}: duplicate release paths')
    for name in (f'{top}.sbit', f'{top}.smsk', 'run_inputs.json', 'pds_design.sv', 'firmware.hex',
                 'firmware.json', 'constraints.fdc', 'timing.rtr', 'implementation_checks.json', 'device_map.log', 'timing.log'):
        require(name in hashes, f'{target}: release does not bind {name}')
    verify_files(directory, hashes)
    inputs = load(directory / 'run_inputs.json')
    require(inputs.get('stage') == 'Bitstream', f'{target}: not a completed bitstream build')
    require(inputs.get('combined_source_sha256', '').lower() == sha(directory / 'pds_design.sv'), f'{target}: source fingerprint mismatch')
    audit_combined_source(root, target, directory / 'pds_design.sv')
    firmware = audit_firmware(root, f'software/build/{app}', 'coremark/core_main.c' if target == 'cpu' else 'mine.c')
    require(inputs.get('firmware_hex_sha256', '').lower() == firmware['hex_sha256'] == sha(directory / 'firmware.hex'),
            f'{target}: release firmware does not match current verified build')
    require(sha(directory / 'firmware.json') == sha(root / f'software/build/{app}/firmware.json'), f'{target}: firmware manifest mismatch')
    constraint = root / f'constraints/atk_l50_{"cpu_vcc33" if target == "cpu" else "mine"}.fdc'
    require(inputs.get('constraint_sha256', '').lower() == sha(constraint) == sha(directory / 'constraints.fdc'), f'{target}: stale constraints')
    impl = load(directory / 'implementation_checks.json')
    for resource, capacity in (('LUT', 22560), ('FF', 33840), ('DRM', 60)):
        require(0 < impl.get('mapped_resources', {}).get(resource, 0) <= capacity, f'{target}: invalid {resource} mapping')
    require(impl.get('timing_checked') is True and bool(impl.get('active_clocks')), f'{target}: no actual clock timing evidence')
    for key in ('Setup_Slow_endpoints', 'Setup_Fast_endpoints', 'Hold_Slow_endpoints', 'Hold_Fast_endpoints'):
        require(impl.get('constrained_endpoints', {}).get(key, 0) > 0, f'{target}: no timing endpoints {key}')
    for key, name in (('map_log_sha256', 'device_map.log'), ('timing_report_sha256', 'timing.rtr'), ('timing_log_sha256', 'timing.log')):
        require(impl.get(key, '').lower() == sha(directory / name), f'{target}: stale implementation evidence {key}')
    timing = (directory / 'timing.rtr').read_text(encoding='utf-8-sig')
    require(re.search(r'Design Summary\s*:\s*All Constraints Met\.', timing), f'{target}: timing failed')
    require(re.search(r'^Path Class\s*:\s*sequential timing path', timing, re.M), f'{target}: no sequential timing path')
    if target == 'cpu':
        params = top_parameters(root)
        require(inputs.get('cpu_features') == params, 'CPU release parameters differ from actual top defaults')
        require(inputs.get('clock_hz', params['CLOCK_HZ']) == firmware['clock_hz'] == params['CLOCK_HZ'], 'CPU clock/firmware metadata mismatch')
        require(firmware['ram_bytes'] == params['DMEM_WORDS'] * 4, 'CPU RAM/linker mismatch')
        clock_name = 'cpu_clk' if params['CPU_CLOCK_DIV'] != 1 else 'sys_clk'
        clock_row = re.search(r'^\s*' + clock_name + r'\s+([\d.]+)\s+\{[^}]+\}\s+(?:Declared|Generated\s+\([^)]*\))\s+(\d+)\s+', timing, re.M)
        require(clock_row is not None and int(clock_row[2]) > 0 and
                abs(float(clock_row[1]) - 1e9 / params['CLOCK_HZ']) < 0.001, 'CPU real clock timing period/endpoints mismatch')
        if params['DUAL_ISSUE']:
            for bank in ('even', 'odd'):
                require(f'firmware.hex.{bank}' in hashes, f'CPU missing bound {bank} ROM bank')
    else:
        require('mine_font.hex' in hashes and sha(directory / 'mine_font.hex') == sha(root / 'rtl/periph/mine_font.hex'), 'Mine font mismatch')
    return {'directory': relative, 'target': target, 'top': top, 'clock_hz': inputs.get('clock_hz', inputs.get('cpu_features', {}).get('CLOCK_HZ')),
            'bitstream_sha256': hashes[f'{top}.sbit'], 'resources': impl['mapped_resources'],
            'timing_passed': True, 'current_hardware_verified': False}


def audit_historical(root):
    captures = []
    for name in ('coremark_optimized_20261103_01', 'coremark_optimized_20261103_02'):
        directory = root / 'build/uart_capture' / name
        recorded = load(directory / 'coremark_score.json')
        require(recorded.get('capture_sha256') == sha(directory / 'capture.txt'), f'{name}: raw capture hash mismatch')
        result = evaluate((directory / 'capture.txt').read_text(encoding='utf-8-sig'),
                          clock_hz=recorded['clock_hz'], evidence_kind='BoardCapture')
        require(result['verdict'] == 'PASS', f'{name}: historical report invalid')
        captures.append({'directory': directory.relative_to(root).as_posix(), 'score': result['coremark_score'],
                         'coremark_per_mhz': result['coremark_per_mhz'], 'current_design': False})
    ila = root / 'build/coremark_ila'
    captured = load(ila / 'capture_result.json')
    for key, file in (('wave_sha256', 'coremark_ila_512.wdf'), ('project_sha256', 'coremark_ila_512.dprj'),
                      ('bitstream_sha256', 'atk_l50_top.sbit'), ('fic_sha256', 'coremark_ila.fic')):
        require(captured.get(key, '').lower() == sha(ila / file), f'Historical ILA mismatch: {file}')
    require((ila / 'coremark_ila_samples.csv').is_file(), 'Historical ILA decoded samples missing')
    return {'captures': captures, 'ila_directory': 'build/coremark_ila',
            'scope': 'Historical physical evidence for older cores only; not proof of current CPU or application.'}
