#!/usr/bin/env python3
"""Build a source-bound offline CPU + touchscreen-minesweeper ZIP.

Only current validated artifacts are selected. Historical physical measurements
remain explicitly historical. This tool never programs or opens hardware.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import uuid
import zipfile
from competition_artifacts import (PENDING, inside, load, require, sha, source_snapshot, verify_files)
from validate_competition import audit

READY = 'OFFLINE_READY_HARDWARE_PENDING'


def verify_archive(archive):
    with zipfile.ZipFile(archive) as zipped:
        require(zipped.testzip() is None, 'ZIP CRC validation failed')
        names = zipped.namelist()
        require(len(names) == len(set(names)), 'Duplicate ZIP names')
        manifest = json.loads(zipped.read('delivery_manifest.json'))
        require(manifest.get('status') == READY and manifest.get('hardware_touched') is False and
                manifest.get('current_hardware_verified') is False, 'Invalid offline evidence status')
        expected = manifest['files']
        require(set(names) == set(expected) | {'delivery_manifest.json'}, 'ZIP has unmanifested/missing files')
        for name, digest in expected.items():
            require(not name.startswith(('/', '\\')) and '..' not in Path(name).parts, 'Unsafe ZIP member')
            require(hashlib.sha256(zipped.read(name)).hexdigest() == digest, f'ZIP content mismatch: {name}')
    return manifest


def build_package(root, report, label):
    require(re.fullmatch(r'[A-Za-z0-9_-]+', label), 'Use an ASCII label')
    require(report.get('status') == READY and report.get('hardware_touched') is False, 'Offline acceptance is incomplete')
    require(report.get('source_sha256') == source_snapshot(root, include_docs=True), 'Sources/docs changed after acceptance')
    verify_files(root, report['artifact_sha256'])
    parent = root / 'build/competition_delivery'
    output = parent / f'{label}_{uuid.uuid4().hex[:8]}'
    project = output / 'fpga_riscv_starter'
    project.mkdir(parents=True)
    payload = report['source_sha256'] | report['artifact_sha256']
    for relative, expected in payload.items():
        source = inside(root, relative)
        destination = inside(project, relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        require(sha(destination) == expected, f'Copy changed bytes: {relative}')
    summary = root / 'build/competition_validation/summary.json'
    destination = project / summary.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(summary, destination)
    releases = {item['evidence']['target']: item['evidence'] for item in report['checks']
                if item['name'].startswith('release:') and item['status'] == 'PASS'}
    cpu = releases.get('cpu', {})
    readme = f'''# CPU + 触屏扫雷比赛离线交付包

状态：{READY}。源码、固件、离线测试与 CPU/扫雷位流已经文件一致性验收。
本工具只校验文件和离线测试，不执行硬件操作。实板成绩和验收范围见公开性能报告及原始测量证据。

主应用是中文触屏扫雷。先读 fpga_riscv_starter/docs/参赛作品说明书.md、性能分析报告.md、提交材料清单.md。
build/uart_capture/ 和 build/coremark_ila/ 是较早 CPU 的原始实板基线及 ILA，不能代表当前设计。
单迭代 CoreMark 仿真用于 CRC 与周期比较，不能作为满足至少 10 秒要求的正式比赛成绩。

## 实板复现实验顺序

1. 校验 delivery_manifest.json 中的文件 SHA256；CPU 当前配置为 {cpu.get('clock_hz', '见run_inputs.json')} Hz。
2. 进入 fpga_riscv_starter，核对板型 PGL25G、LCD/触摸连接和实际串口号。
3. CPU 镜像路径：build/board_release/cpu/coremark/atk_l50_top.sbit；先打开串口捕获，按项目 program_sram.ps1 的 CPU/CoreMark SRAM 流程下载并回读。
4. 等待自动迭代完整报告；保存原始 UART，核对真实频率、至少 10 秒、CRC，再用 scripts/score_coremark.ps1 显式传 -ClockHz {cpu.get('clock_hz', '<真实频率>')} -EvidenceKind BoardCapture。
5. 扫雷镜像路径：build/board_release/mine/mine/atk_l50_mine.sbit；按 mine 目标 SRAM 流程下载，完成触摸、插旗、失败重开与多关卡演示，具体按钮以作品说明书为准。
6. 按 docs/演示操作指南.md 完成上板操作，录制演示视频。

## 离线复现

配置 Python、PowerShell、Icarus Verilog；固件重编译另需 WSL RISC-V GCC，PDS 仿真原语模型/位流构建需本机 Pango Design Suite。
工具安装和许可证不随包分发。Icarus 可安装到项目父目录 tools/iverilog/bin；使用其他安装位置时须加入 PATH。PDS 安装路径通过相应脚本的 PdsRoot 或 --pds-root 参数指定。

    python scripts/validate_competition.py --tests-only
    python scripts/validate_competition.py --audit-only
    python scripts/build_competition_delivery.py --label competition

比赛验收只做离线工作，不访问 UART/JTAG，不下载 FPGA。位流重建使用 scripts/run_pds.ps1 的 cpu/coremark 与 mine/mine 目标。
校验 ZIP：python scripts/build_competition_delivery.py --verify-zip <本ZIP路径>。

本离线审计未覆盖的硬件项目记录在 delivery_manifest.json 的 pending_hardware 中。第三方代码和字库的许可范围见 docs/THIRD_PARTY_NOTICES.md。
'''
    (output / 'README.md').write_text(readme, encoding='utf-8')
    manifest = {'status': READY, 'hardware_touched': False, 'current_hardware_verified': False,
                'application': 'touchscreen_minesweeper', 'pending_hardware': PENDING,
                'validation_summary_sha256': sha(summary),
                'historical_evidence_scope': 'Old-core physical baseline and ILA; never current CPU/application validation.',
                'files': {p.relative_to(output).as_posix(): sha(p) for p in sorted(output.rglob('*')) if p.is_file()}}
    (output / 'delivery_manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    # Detect concurrent edits after copying, before creating a release archive.
    require(report['source_sha256'] == source_snapshot(root, include_docs=True), 'Source changed while packaging')
    verify_files(root, report['artifact_sha256'])
    archive = output.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as zipped:
        for file in sorted(output.rglob('*')):
            if file.is_file():
                zipped.write(file, file.relative_to(output).as_posix())
    verify_archive(archive)
    result = {'status': READY, 'directory': str(output), 'zip': str(archive),
              'zip_sha256': sha(archive), 'files': len(manifest['files']) + 1,
              'hardware_touched': False, 'current_hardware_verified': False}
    (parent / 'latest.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', default='cpu_minesweeper_offline')
    parser.add_argument('--verify-zip', type=Path)
    parser.add_argument('--performance-firmware', default='software/build/coremark_sim')
    parser.add_argument('--validation-firmware', default='software/build/coremark_o3_lto_inline_b_validation_sim')
    args = parser.parse_args()
    if args.verify_zip:
        manifest = verify_archive(args.verify_zip)
        print(json.dumps({'status': 'ZIP_VERIFIED', 'files': len(manifest['files']) + 1, 'sha256': sha(args.verify_zip)}))
        return
    root = Path(__file__).resolve().parents[1]
    out = root / 'build/competition_validation'
    out.mkdir(parents=True, exist_ok=True)
    report = audit(root, out, args)
    result = build_package(root, report, args.label)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
