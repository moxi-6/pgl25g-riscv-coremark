> **2026-10-22 15:20 最新：CPU 最小作品实板闭环通过。** 板载 CH340 COM8 实收两次 `OK\r\n`（8 字节 `4F 4B 0D 0A 4F 4B 0D 0A`）；用户确认两次物理复位后均恢复 LED0/LED2 亮、其余灭。结合此前 GUI 下载与同源回读校验，CPU、UART、GPIO、按键复位重复运行均已有实板证据。以下旧的“串口/复位待验收”属于历史状态。尚未完成命令行下载流程修复、CSR/完整异常中断、CoreMark 及性能验收。
# ATK-L50 制作与上板入口

2026-10-22：CPU 已经通过官方 GUI 下载、同源回读校验及实板 GPIO 演示。STATUSR=0x001ffca0，用户确认 LED0/LED2 亮、LED1/LED3 灭。当前使用 Vcc33 约束；实物 UART 和按键复位重复运行仍待验收。早期电压约束和下载状态见历史记录。

状态（2026-10-20）：实际器件已由用户和 JTAG 确认为 PGL25G，ID 为 0x00511899。此前 PGL50G 是照片误读，其位流已标记作废并隔离。PDS/FTDI 授权和驱动正常；现按 PGL25G / -6 / MBG324 重建和上板验证，结果见 docs/实板验证记录.md。

## 顶层与现象

| 用途 | 顶层 | 有序清单 | 预期现象 |
|---|---|---|---|
| 独立板级验证 | `atk_l50_bringup` | `bringup.f` | 四灯每 0.5 秒依次点亮；串口周期输出 `ATK-L50 OK\r\n` |
| CPU 最小作品 | `atk_l50_top` | `cpu.f` | 输出一次 `OK\r\n`；GPIO 最终为 `0xa5`；四灯最后为 `0101` |

共同端口：`sys_clk`、`sys_rst_n`、`uart_txd`、`led[3:0]`。默认 50 MHz、115200 8N1。LED 高电平点亮；CPU GPIO 只取低 4 位。复位异步置位、两拍同步释放。独立顶层不需要 CPU、软件或 RAM 初始化；每条消息的 LF 被 UART 接收后，等待 `MESSAGE_PERIOD_CYCLES`（默认 1 秒）再启动下一条消息。

## 引脚证据与待核验电压

当前使用 `constraints/atk_l50_vcc33.fdc`：LED 为 3.3 V/LVCMOS33，时钟及复位为 3.3 V/LVCMOS12。这组约束已有流水灯与 CPU GPIO 的实板功能证据，尚不构成 Bank 电压及电气合规的测量结论。`atk_l50_reference.fdc` 与 `atk_l50_guide_candidate.fdc` 保留作历史对照，不能按本节旧表直接作为当前下载约束。

## CPU 串口及复位验收

使用可传数据的 USB Type-C 线连接底板 **USB_UART** 到电脑。板载 CH340 应出现独立 COM 口；下载器 FTDI 的 COM23/COM24 不是板载 UART。当前 CPU 默认 115200、8N1、无流控，TX 为 FPGA C15，数据只在每次程序启动时输出一次 `OK\r\n`。

先确保板上已通过官方 GUI 下载当前 CPU SRAM 位流，然后在项目根目录运行：

```powershell
& .\fpga_riscv_starter\scripts\verify_board_uart.ps1
```

脚本只接收已识别的 CH340 串口；若接入多个 CH340，使用 `-Port COMx` 指定板载接口。看到 `UART_CAPTURE_READY` 后，按下并松开板上复位键两次，每次间隔至少一秒，观察每次松开后 LED0/LED2 是否恢复点亮。不要断电，SRAM 位流断电即丢失。脚本默认监听 60 秒，严格检查两条 `OK\r\n`（字节 `4F 4B 0D 0A`），输出在 `build/uart_capture/<时间>/capture.bin` 和 `result.json`。

脚本成功只证明收到匹配字节；物理按键操作与 LED 灯态须另行记录。超时、错误字节及多余字节均失败并保留已接收数据。GUI 下载和命令行下载流程差异仍未定位，暂以已验证的官方 GUI 作为实板演示入口。

## 历史引脚资料

| 端口 | 引脚 | 官方 FDC 标准 | 交叉核对 |
|---|---|---|---|
| `sys_clk` | T9 | LVCMOS12 | 指南第 354 页写 LVCMOS18；核心板第 4 页为 50 MHz 振荡器，第 5 页 Bank2 为 1.8 V |
| `sys_rst_n` | T4 | LVCMOS12 | 指南写 LVCMOS18；底板第 8 页复位上拉 1.8 V，按下接地 |
| `uart_txd` | C15 | LVCMOS33 | 底板第 6、10 页 UART1_TX 经电平转换接 CH340_RX；J27 照片显示在 3V3 档 |
| `led[0]` | C8 | LVCMOS33 | NPN 高电平驱动；J27 照片显示在 3V3 档 |
| `led[1]` | L14 | LVCMOS15 | 核心板图纸为 Bank1，电源标 1.35 V；需按实物版本和 PDS 器件规则核验 |
| `led[2]` | P16 | LVCMOS15 | 同上 |
| `led[3]` | P15 | LVCMOS15 | 同上 |

核心板图纸标题为 `ATK_CFPGL25G_CORE_1V0_0303`，器件符号为 PGL25G。实物核心板丝印 CFL50B；实际 FPGA 经用户和 JTAG 确认为 **PGL25G**（ID `0x00511899`）。工程选择 Logos / PGL25G / -6 / MBG324。此前根据照片识别为 PGL50G 的结论已撤回，50G 位流不可用于这块板。

## 安装 PDS

配套《ATK-L50 之 FPGA 开发指南 V1.1》第 123–131 页使用 **PDS 2022.2 SP4.2**。配套安装包应在开发板工具盘 B 盘的 PDS 目录，指南给出的官方入口为：

<https://pangomicro.com/resources/software/pds/>

PDS 安装及授权已完成。实际综合工程在 `C:/fpga/riscv_l50/verified`；可复现命令和资源见 `docs/PDS工程运行.md`。A 盘的 25G/50G 示例压缩包之前仍为下载中状态，不作为已验证输入。

1. 完成配套安装包下载，解压并安装到纯英文路径，例如 `C:\pango\PDS_2022.2-SP4.2-ads`。
2. 按官方安装说明安装 USB Cable 驱动；指南要求运行安装程序前断开下载器。
3. 根据安装包内 `Pango_Design_Suite_Windows_Install.pdf` 的 License 章节申请和配置有效许可证，无需使用目录中的虚拟网卡工具。
4. 启动 PDS 并记录版本、许可证状态，确认器件库支持实物芯片。目前无需另装 Modelsim，现有 Icarus 已能验证本工程。

## 生成源码包

在根目录 `FPGA项目` 运行：

```powershell
& .\fpga_riscv_starter\scripts\build_firmware.ps1 -Rebuild
& .\fpga_riscv_starter\scripts\run_iverilog.ps1
& .\fpga_riscv_starter\scripts\prepare_board.ps1 -Target bringup
& .\fpga_riscv_starter\scripts\prepare_board.ps1 -Target cpu
```

输出为 `build/atk_l50_bringup/` 和 `build/atk_l50_cpu/`。包内含 RTL、参考 FDC、说明、`sources.f` 和 SHA256 清单；CPU 包另含重新构建的固件、源码、构建入口及校验记录。打包命令会检查固件来源哈希，源代码修改后需先重建；打包本身不编译固件或生成 PDS 项目。也可以用 `run_iverilog.ps1 -RebuildFirmware` 一次完成构建与全部 10 项仿真。

PDS 对工程路径字符有限制。安装后把源码包复制到纯英文目录，例如 `C:\fpga\atk_l50_bringup`，再在该目录创建工程；当前中文工作目录不作为正式 PDS 构建路径。

## PDS 工程与上板步骤

1. 先新建独立 bringup 工程，按芯片丝印选器件，按 `sources.f` 顺序加入 `.sv`，类型为 SystemVerilog，顶层 `atk_l50_bringup`；不加入 testbench。
2. 核对上表电压和板卡版本后生成最终 FDC；参考 FDC 仍标为未核验。检查 7 个信号位均有约束、主时钟为 20 ns。
3. 运行综合、布局布线和时序分析，保存日志、资源和 setup/hold 报告；处理未约束路径及同步器时序约束，不能只以生成比特流代替时序验收。
4. 连接下载器并识别 FPGA，先下载到 SRAM。串口终端选择 CH340 的 COM，115200 8N1，无流控。
5. 验证四灯流水、串口周期输出；按复位后从 LED0 和消息开头重新开始。保存串口原始记录、最终 FDC、工程、比特流及演示照片。
6. 独立验证后再建 CPU 工程，按 `cpu.f` 导入、顶层 `atk_l50_top`。在包根目录创建工程，使 `software/build/firmware.hex` 路径有效，并检查综合确实载入固件。串口在按复位前打开，确认一次 `OK` 及最终 LED `0101`。

CPU 当前使用 `sync_imem` / `sync_dmem` 的时钟同步读模型，包含取指握手、返回缓存、跳转丢弃和数据等待；ROM 另有独立数据读口，启动代码用它初始化 RAM 常量/数据。`simple_imem.sv` 仅保留历史参考，不在 CPU 清单中。10 项 Icarus 仿真通过，固件已从源码重编译；PDS 已确认 RAM 推断及 ROM 双读口合并，使用 16 DRM18K；综合资源已记录，初始化实板效果及时序尚未验证。接口和构建见 `docs/同步存储接口.md`、`software/README.md`。

