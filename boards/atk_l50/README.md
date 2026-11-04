# ATK-L50 构建与上板

目标器件为 Pango Logos **PGL25G / -6 / MBG324**，JTAG ID `0x00511899`。参考工具为 PDS 2022.2-SP4.2。约束文件必须匹配实际板卡电压与连线。

## 发布目标

| 用途 | 顶层与清单 | 时钟与固件 |
|---|---|---|
| 处理器跑分 | `atk_l50_top`，`cpu.f` | 50 MHz输入经真实二分频产生25 MHz CPU；8 KiB RAM；CoreMark |
| 中文触屏扫雷 | `atk_l50_mine`，`mine.f` | 50 MHz系统、25 MHz LCD像素时钟；16 KiB RAM；`mine.c` |
| 独立板级诊断 | `atk_l50_bringup`，`bringup.f` | 流水灯与周期 UART 报文 |

两项发布目标使用115200、8N1串口。按键低有效，LED高有效。复位异步置位、同步释放。扫雷使用800×480 RGB屏幕和 GT9147 触控桥；INT仅在地址选择阶段由FPGA驱动，随后释放。

## 工具与构建

安装 Python 3、PowerShell、Icarus Verilog、WSL RISC-V GCC/binutils 与 PDS。PDS 使用厂商许可证与 USB Cable 驱动；许可证、驱动和工具二进制不属于本仓库。PDS 工程应放在 ASCII 路径，安装和工作位置由脚本参数指定。

在项目根目录运行：

```powershell
./scripts/build_firmware.ps1 -App mine -Isa rv32i -RamBytes 16384 -Rebuild
python scripts/run_mine_checks.py
./scripts/prepare_board.ps1 -Target mine -FirmwareApp mine
./scripts/run_pds.ps1 -Target mine -FirmwareApp mine -ConstraintProfile Vcc33 -Stage Bitstream -WorkRoot C:/fpga/mine_release
```

CoreMark构建配置和启动布局见 [固件说明](../../software/README.md)。跑分硬件使用 `-Target cpu -FirmwareApp coremark`；提交结果须绑定对应频率、固件和位流。

`prepare_board.ps1` 只组装源码并核对固件哈希。`run_pds.ps1 -Stage Bitstream` 还执行综合、布局布线、时序和资源检查。发布目录 `build/board_release/<target>/<app>/` 包含位流、掩码、固件、约束、报告和清单。源码或固件变更后应重新构建；仅生成位流不等于完成时序验收。

## 连接与下载

下载器用于JTAG；底板 USB_UART 的 CH340用于应用串口，两个接口用途不同。多设备环境用 `-Port` 指定实际串口，不依赖固定 COM 编号。下载流程使用 `scripts/program_sram.ps1` 并执行回读校验；SRAM配置断电后丢失。具体参数见项目作品说明书。

扫雷核验触摸坐标、翻格、模式按钮、插旗、首点安全、失败重开和关卡推进。跑分核验完整 UART 原始报告、CRC、迭代数、真实时钟与至少10秒计时区间。仿真图片、CRC检查、回读以及操作者观察分别记录其证据范围。

## 引脚与时序

CPU使用 `constraints/atk_l50_cpu_vcc33.fdc`，扫雷使用 `constraints/atk_l50_mine.fdc`。LCD／触摸 Bank3/J28配置为3.3 V。面板外部setup/hold预算是约束假设，PCB偏斜未测量，不能把逻辑功能验收等同于电气测量。

`reference`、`guide_candidate` 约束及其他应用清单保留作诊断参考，不属于扫雷／跑分默认发布入口。
