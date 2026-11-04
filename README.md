# RV32I 三阶段流水处理器 · 紫光同创 FPGA 平台

> 2026 全国大学生嵌入式芯片与系统设计竞赛 — FPGA 创新设计赛道 · 紫光同创选题一
> 开发板：正点原子 ATK-L50（紫光同创 **PGL25G**-6 / MBG324，实器件 JTAG ID `0x00511899`）

从零用 SystemVerilog 实现一颗 RV32I 处理器，配上片上同步存储、UART/GPIO/按键、64 位性能计数器、
RGB LCD 显示控制器与 I²C 触摸驱动，最后在上面跑三个能用手玩的游戏。

---

## 亮点

| 维度 | 结果 |
|---|---|
| CPU | RV32I 三阶段流水线（IF / EX / WB），写回前递、load-use 互锁、非法指令与未对齐访问检测 |
| 可参数化扩展 | 分支预测（BTB，可配 16/64/128 项）、`Zmmul` 硬件乘法、`Zba`/`Zbb` 位操作、**双发射**、多周期乘法 |
| 实板 CoreMark（50 MHz） | **23.7844**（300 迭代 / CRC `0x5275` 通过），较基线 16.8218 提升 **41.4%** |
| 仿真最优（R9，未上板） | **5.345 CoreMark/MHz** ≈ 50 MHz 下 267 分（仅仿真 + 时序推算） |
| 资源占用 | LUT 1 840（8.16%）、FF 1 395（4.12%）、DRM18K 16（26.67%） |
| 时序 | 20 ns 约束下 setup slack **+2.531 ns**，等效 Fmax ≈ 57 MHz |
| 仿真回归 | **17 项全部通过**，含指令差分（48 次逐步比对）与真 bug 复现 |
| 硬件 ILA | 92 路探针 / 512 点深度，抓到 `__mulsi3` 移位相加内循环 |

---

## 系统架构

```text
                 ┌──────────────────────────────────────────┐
   KEY[3:0] ────▶ │                                          │
                 │   rv32i_core_3stage                      │
   UART  ◀─────── │   IF ──▶ EX ──▶ WB                       │
                 │     │       │                             │
                 │   sync_imem sync_dmem                    │
                 │                                          │
   MMIO  ◀────── │  0x1000_0000  GPIO / LED                 │
                 │  0x1000_0004  UART                       │
                 │  0x1000_0008  KEY                        │
                 │  0x1000_0010  64-bit CYCLES              │
                 │  0x1000_0018  64-bit INSTRET             │
                 │  0x1000_0044  FRAME（视频帧计数）          │
                 │  0x1000_0054  TOUCH_X / Y / STAT / EVT   │
                 │  0x1000_00A0  MINE 格子总线（16 字）       │
                 │  0x1000_0100  SPRITE / HUD                │
                 └───────────┬──────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
      lcd_800x480 (800×480 RGB)      gt9147_touch ── I²C ── i2c_master
              │                                              │
              ▼                                              ▼
        LCD 面板                                   GT9147 触摸（7 寸屏）
```

**设计原则：CPU 不写像素。** 显示内容由 CPU 通过 MMIO 发布「语义量」（精灵坐标、格子状态、HUD 文本），
渲染器在硬件里组合生成 RGB。这样即使在 50 MHz、无 Cache 的条件下也能稳定跑满帧。

---

## CPU 参数

`rtl/core/rv32i_core_3stage.sv` 顶部暴露全部性能开关，默认取保守配置：

```systemverilog
parameter logic [31:0] RESET_VECTOR = 32'h0000_0000,
parameter bit    ASYNC_IMEM      = 1'b0,
parameter bit    PREDICT_ENABLE  = 1'b1,   // BTB 分支预测
parameter integer BTB_ENTRIES    = 16,
parameter bit    PIPELINE_DECODE = 1'b1,
parameter bit    ZMMUL_ENABLE    = 1'b0,   // MUL/MULH/MULHSU/MULHU
parameter bit    BITMANIP_ENABLE = 1'b0,   // Zba + Zbb 子集
parameter bit    DUAL_ISSUE      = 1'b0,   // 双发射
parameter integer MUL_CYCLES     = 3
```

`scripts/run_isa_checks.py` 会针对这些开关的组合跑差分回归（`isa_decode0/1`、`isa_decode1_mul2` 等）。

---

## 实测数据（可追溯到证据文件）

| 指标 | 数值 | 来源 |
|---|---|---|
| CoreMark @50 MHz 基线 | 16.8218（0.3364 /MHz） | `build/uart_capture/coremark_board_20261101_01/` |
| CoreMark @50 MHz 取指重叠后 | **23.7844** | `build/board_release/cpu/coremark/` |
| CPI（仿真基线） | 3.4544（3 136 219 周期 / 907 896 提交） | `sim/tb_coremark.sv` |
| CPI（R9 仿真） | **0.734**（187 076 周期 / 254 839 提交） | `build/cpu_optimization_20261104/r9_dual_isa/` |

> R9 的双发射、`Zmmul`、BTB128 组合目前只完成**仿真与部分 PDS 流程**，
> 位流尚未验收、没有对应的实板分数。上表已区分「实板」与「仿真」。

---

## 三个应用

| 应用 | 说明 | 状态 |
|---|---|---|
| **中文横版射击** | 640×480 游戏区 + 右侧中文 HUD，移动/跳跃/射击/敌人巡逻/碰撞/多关卡 | ✅ 已上板 |
| **反应力小游戏** | 10 轮随机点灯 + 按键反应计时 + 串口成绩 | ✅ 已上板 |
| **触屏扫雷** | 9×9 / 5 关 / 洪水填充 / I²C 触摸，硬件渲染格子与数字 | 🟡 代码完成，待整机仿真与位流 |

---

## 目录结构

```text
fpga_riscv_starter/
├── rtl/
│   ├── core/        RV32I 数据通路、ALU、译码、寄存器堆、三阶段核
│   ├── periph/      UART、RGB LCD 控制器、I²C 主机、GT9147 触摸、各游戏渲染器
│   ├── soc/         同步 IMEM/DMEM、MMIO 译码、SoC 顶层
│   └── top/         板级顶层（射击 / 扫雷 / 自检 / 探针等多种）
├── sim/             17 个自检 testbench（含 GT9147 行为模型）
├── software/        启动代码、链接脚本、C 应用、CoreMark 移植（含软浮点除法）
├── constraints/     PDS 引脚与时序约束（.fdc）
├── boards/          各目标综合文件列表（.f）
├── scripts/         固件构建、仿真、综合、下载、串口捕获、评分等 PowerShell/Python 入口
├── docs/            设计与验收文档（中文）
└── build/           构建产物（git 忽略）
```

---

## 快速开始

### 1. 仿真（无需开发板）

```powershell
# Icarus Verilog 回归
./scripts/run_iverilog.ps1
```

期望结尾输出 `All 17 simulations passed.`

### 2. 构建固件

需要 RISC-V 裸机工具链（`riscv64-unknown-elf-gcc`）：

```powershell
./scripts/build_firmware.ps1 -App shooter    # 或 mine / game / coremark / perf_report / all
```

### 3. 综合与位流

需要 Pango Design Suite 2022.2-SP4.2：

```powershell
./scripts/run_pds.ps1 -Target shooter -Stage Bitstream -ConstraintProfile Vcc33 -FirmwareApp shooter
```

> ⚠️ LCD 相关目标必须用 `-ConstraintProfile Vcc33`（Bank3 / J28 已确认为 3.3 V）。

### 4. 下载与验证

```powershell
./scripts/program_sram.ps1 -Target shooter -FirmwareApp shooter
./scripts/capture_uart.ps1 -Port COM8 -TimeoutSeconds 90
```

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [参赛作品说明书](docs/参赛作品说明书.md) | 赛题对应、结构、实测证据总表 |
| [提交材料清单](docs/提交材料清单.md) | 评分维度 → 证据索引、缺口分析 |
| [制作进度](docs/制作进度.md) | 完整开发时间线 |
| [CPU 跑分优化方向](docs/2026-11-04_CPU跑分优化方向.md) | 热点分析与优化路线 |
| [Zmmul 推进记录](docs/2026-11-04_Zmmul推进记录.md) | R6–R9 实验与差分验证 |
| [CoreMark 移植与跑分](docs/CoreMark移植与跑分.md) | 移植细节与评分规则 |
| [实板验证记录](docs/实板验证记录.md) | 逐次上板结果 |
| [扫雷交接文档](docs/扫雷交接文档.md) | 触屏扫雷的完整设计说明（MMIO、渲染器、固件、上板步骤） |
| [项目总交接](docs/项目总交接.md) | 扫雷 + CPU 两条线的总体状态与待办 |
| [开发日志](docs/开发日志.md) | 按日期的进展流水 |

---

## 边界声明

本作品在以下方面**不做超出实现范围的宣称**：

- 不宣称完整特权架构：无 CSR、无中断/异常恢复，`ECALL` 进入 trap 停机。
- CoreMark 的乘除法在基线配置下由软件例程完成，不依赖 M 扩展；`Zmmul` 为可选参数。
- 「最高频率」给出的是 PDS 时序报告推算值，不是实测运行频率。
- ILA 为单次 512 点触发采样，用于展示关键内循环，不是完整指令追踪。
- 实板验证全部通过 SRAM 下载完成，**没有做 Flash 冷启动**。
- 板卡为非推荐的 PGL25G（22 560 LUT），低于赛方答疑所述推荐区间，评审时可出示资源与时序证明。

未使用任何硬核 ARM / NPU 或第三方 IP 核：CPU、总线、外设、ILA 触发逻辑均为自研 RTL。

---

## 许可

本工程原创代码采用 MIT 许可。
`software/coremark/` 为 EEMBC CoreMark 移植，遵循其原始许可，见 [LICENSE.md](software/coremark/LICENSE.md)。