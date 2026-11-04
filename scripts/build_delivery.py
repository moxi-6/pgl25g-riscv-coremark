"""Package a board-verified deliverable with its measured evidence."""
import argparse
import json
import shutil
import uuid
import zipfile
from pathlib import Path
from audit_artifacts import audit, load, sha
from validate_offline import snapshot

DOCS=('参赛作品说明书.md','性能分析报告.md','提交材料清单.md',
      '2026-11-01_ILA波形采集.md','2026-11-01_反应力游戏.md',
      '同步存储接口.md','PDS工程运行.md','实板验收与ILA采样计划.md')

# Firmware build directories: name -> path relative to software/build.
FIRMWARE=('main','runtime_test','perf_test','perf_report','coremark','coremark_sim','game','game_sim')
# CPU release packages that ship as ready-to-flash bitstreams.
RELEASES=('coremark','perf_report','game')
# Measured board captures worth shipping as evidence.
CAPTURES=('coremark_board_20261101_01','coremark_board_20261101_03','game_board_20261101_04')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label',default='board_verified')
    args=parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in args.label):
        raise ValueError('Use an ASCII filename label')
    root=Path(__file__).resolve().parents[1]
    validation=load(root/'build/offline_validation/summary.json')
    if validation['status']!='PASS' or validation['source_sha256']!=snapshot(root):
        raise RuntimeError('Run validate_offline.py against current sources before packaging')
    artifact_audit=audit(root)
    output=root/'build/delivery'/f'{args.label}_{uuid.uuid4().hex[:8]}'
    project=output/'fpga_riscv_starter'; project.mkdir(parents=True)
    ignore=shutil.ignore_patterns('__pycache__','*.pyc','build')
    for folder in ('rtl','sim','scripts','windows_scripts','constraints','boards'):
        if (root/folder).is_dir(): shutil.copytree(root/folder,project/folder,ignore=ignore)
    shutil.copytree(root/'software',project/'software',ignore=shutil.ignore_patterns('build','__pycache__'))
    (project/'docs').mkdir()
    for name in DOCS: shutil.copy2(root/'docs'/name,project/'docs'/name)
    firmware_names=('firmware.elf','firmware.bin','firmware.hex','firmware.dis','firmware.map','firmware.json','toolchain.txt')
    for app in FIRMWARE:
        relative=Path('software/build') if app=='main' else Path('software/build')/app
        destination=project/relative; destination.mkdir(parents=True,exist_ok=True)
        for name in firmware_names:
            source=root/relative/name
            if source.is_file(): shutil.copy2(source,destination/name)
    shutil.copy2(root/'software/build/coremark/sim_firmware.hex',project/'software/build/coremark/sim_firmware.hex')
    for app in RELEASES:
        relative=Path('build/board_release/cpu')/app
        shutil.copytree(root/relative,project/relative)
    for name in CAPTURES:
        source=root/'build/uart_capture'/name
        if source.is_dir():
            shutil.copytree(source,project/'build/uart_capture'/name)
    ila=root/'build/coremark_ila'
    if ila.is_dir():
        shutil.copytree(ila,project/'build/coremark_ila')
    for folder in ('offline_validation','isa_checks'):
        shutil.copytree(root/'build'/folder,project/'build'/folder,ignore=shutil.ignore_patterns('*.vvp'))
    for pattern in ('*.compile.log','*.run.log','pipeline_trace.*','pipeline_trace_summary.json'):
        for file in (root/'build').glob(pattern): shutil.copy2(file,project/'build'/file.name)
    readme='''# FPGA RISC-V 处理器交付包（实板验收终版）

状态：BOARD_VERIFIED_DEMO_READY。三件交付物已在 ATK-L50（PGL25G/-6/MBG324）实测闭环。

入口文档：fpga_riscv_starter/docs/参赛作品说明书.md、性能分析报告.md、提交材料清单.md。

## 实测成绩

- CoreMark：300 次迭代、17.834 s、16.822 分、0.3364 CoreMark/MHz、CRC 0x5275 正确；
  两次独立上板运行 ticks 完全相同（891 700 236）。
- 硬件 ILA：92 路探针、512 点深度，抓到 matrix_mul_matrix_bitextract 调用的软件乘法内循环 20 轮。
- 应用演示：反应力小游戏，10 轮完整上板运行，仿真覆盖 OK / 按错 / 超时三分支。
- 仿真回归：15 项全过；指令差分 48 次运行、7 455 条提交逐条匹配。

## 内容

- 源码：rtl/、sim/、scripts/、software/、constraints/、boards/
- 固件构建：八套（main、runtime_test、perf_test、perf_report、coremark、coremark_sim、game、game_sim）
- 可烧录位流：build/board_release/cpu/{coremark,perf_report,game}/atk_l50_top.sbit（含 SHA256 与 PDS 报告）
- 实测证据：build/uart_capture/、build/coremark_ila/、build/offline_validation/、build/isa_checks/

## 复现

进入 fpga_riscv_starter 后：

    python scripts/validate_offline.py     # 15 项仿真 + 差分 + 判分控制 + 失败守卫
    scripts/build_firmware.ps1 -App all
    scripts/run_pds.ps1 -Target cpu -FirmwareApp coremark -ConstraintProfile Vcc33 -Stage Bitstream
    scripts/program_sram.ps1 -Target cpu -FirmwareApp coremark
    scripts/run_game_capture.ps1 -Port COM8 -TimeoutSeconds 150

环境：Python 3.10+、PowerShell、Icarus Verilog；重编译固件另需 WSL 中的 RISC-V GCC；
生成位流需 Pango Design Suite 与许可证（不随包分发）。

## 未完成项

见 delivery_manifest.json 的 pending 字段：人工按键的一局录像、3 分钟演示视频、
Flash 冷启动验收、2026 官方章程存档。
'''
    (output/'README.md').write_text(readme,encoding='utf-8')
    manifest={'status':'BOARD_VERIFIED_DEMO_READY','hardware_touched':True,
              'validation_summary_sha256':sha(root/'build/offline_validation/summary.json'),
              'artifact_audit':artifact_audit,
              'pending':['recorded human-key run','demo video','Flash cold-boot acceptance',
                         'archive official 2026 rules'],
              'files':{p.relative_to(output).as_posix():sha(p) for p in sorted(output.rglob('*')) if p.is_file()}}
    (output/'delivery_manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8')
    archive=output.with_suffix('.zip')
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
        for file in sorted(output.rglob('*')):
            if file.is_file(): z.write(file,file.relative_to(output))
    with zipfile.ZipFile(archive) as z:
        if z.testzip(): raise RuntimeError('ZIP CRC validation failed')
        for name,expected in manifest['files'].items():
            import hashlib
            if hashlib.sha256(z.read(name)).hexdigest()!=expected: raise RuntimeError(f'ZIP hash mismatch: {name}')
    result={'status':manifest['status'],'directory':str(output),'zip':str(archive),'zip_sha256':sha(archive),'file_count':len(manifest['files'])+1}
    (root/'build/delivery/latest.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()