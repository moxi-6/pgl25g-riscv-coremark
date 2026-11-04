# 当前器件及构建结果（2026-10-20）

2026-10-20：实际器件为 PGL25G，JTAG ID 0x00511899；此前 PGL50G 误读已撤回，旧位流作废。自检和 CPU 已按正确器件重建并生成位流。自检 SRAM 下载及回读校验通过，但实物四灯全亮、复位后不流水，正在用独立引脚/时钟诊断定位；尚不能声称整机运行通过。最新状态见 fpga_riscv_starter/docs/实板验证记录.md。

正式英文工作目录改为 `C:/fpga/riscv_l50/pgl25g_verified`；阶段支持 Probe/Create/Compile/Synthesize/Map/Route/Timing/Bitstream。Bitstream 先运行 Timing，PowerShell 读取实际报告通过后，第二次调用 PDS 打开原生工程生成位流，避免 PDS 预解析 Tcl 时提前读取尚未生成的时序报告。

以下是错误 50G 目标的历史构建记录，不能用作当前板卡资源和时序结论。

# PDS 工程运行与验证结果

2026-10-19，PDS 2022.2-SP4.2 build 132111；器件 PGL50G-6IMBG324（Logos / PGL50G / -6 / MBG324）。安装路径 `C:/pango/PDS_2022.2-SP4.2-ads`。

## 授权已通过

根据用户明确确认，已安装签名有效的 OpenVPN TAP-Windows V9，仅将 TAP 虚拟网卡的 MAC 设置为 `AA-BB-CC-DD-EE-FF`，并重启该虚拟网卡。物理 WLAN/有线网卡未修改。原许可证未改动，运行器仅临时设置进程级许可证环境并恢复。PDS 已实际签出 fabric_shell 和 fabric_ads。

变更结果见根目录 `交接记录/2026-10-19_TAP配置结果.json`；先前 Host ID 失败日志为修复前历史记录。

## 实际综合结果

| 工程 | LUT | 寄存器 | DRM18K | 锁存器 |
|---|---:|---:|---:|---:|
| 独立流水灯/UART | 121 | 85 | 0 | 0 |
| RV32I CPU SoC | 1613 | 1266 | 16 | 0 |

最终原生工程：

- `C:/fpga/riscv_l50/verified/bringup/atk_l50_bringup.pds`
- `C:/fpga/riscv_l50/verified/cpu/atk_l50_cpu.pds`

每个目录包含源文件、sources.f、按清单合并的 pds_design.sv、固件（CPU）、Tcl、时钟约束及综合产物。根目录 `交接记录/2026-10-19_PDS_bringup综合.log`、`2026-10-19_PDS_CPU综合.log` 为最终完整终端日志；项目 `build/*_pds_synthesize.log` 同时保留原始 PDS 输出。以完成标记及错误检查共同判断成功，不能只看原生退出码。

CPU 编译识别出四组 4096×8 RAM，综合报告包含 `Packing u_soc/u_imem/mem_1 and u_soc/u_imem/mem into one dual port dpram`，确认 ROM 双读口合并。16 DRM18K 为 SoC 合计。固件初始化的实板效果尚未验证。

## 兼容性修复与验证

PDS 自动依赖扫描跳过独立 package 文件，因此运行器按 sources.f 合并输入，保留 package 在前。ADS 不支持 enum，控制信号统一采用相同位宽的显式常量编码；仿真和综合共用源码，无条件编译分支。RAM 循环变量在模块作用域声明；复位同步寄存器使用 syn_preserve。

修改后完整 10 项 Icarus 仿真通过，包含串口引脚解码、分支丢弃、访存等待、RAM 字节写和 C 初始化/重复复位。日志见根目录 `交接记录/2026-10-19_ADS兼容回归.log`。本次使用此前已重建并校验的固件。

## 可复现命令

在桌面 FPGA项目 根目录执行：

```powershell
& .\fpga_riscv_starter\scripts\run_iverilog.ps1
& .\fpga_riscv_starter\scripts\run_pds.ps1 -Target bringup -Stage Synthesize -WorkRoot 'C:\fpga\riscv_l50\verified'
& .\fpga_riscv_starter\scripts\run_pds.ps1 -Target cpu -Stage Synthesize -WorkRoot 'C:\fpga\riscv_l50\verified'
```

默认许可证为 `C:/fpga/riscv_l50/licenses/provided.lic`；可用 -LicenseFile 指定。也支持 -PrepareOnly 和 Probe/Create/Compile/Map；本次验证完成到 Synthesize。

## 下一步

当前仅加载 20 ns 时钟约束，输出及复位未约束警告仍存在。尚未布局布线、验证 setup/hold、生成位流或下载。官方 FDC 的时钟/复位电压与指南存在差异，需核对 CFL50B 核心板对应原理图及各 Bank 电压后确定引脚约束，再推进实板验证。综合通过不代表 50 MHz 时序已收敛。
