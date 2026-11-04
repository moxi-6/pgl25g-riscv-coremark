# CoreMark 移植与跑分

2026-10-22：CoreMark 1.01 已移植到本工程的 RV32I/ILP32 裸机环境并通过正确性校验。本文记录移植层、RV32I 约束、构建与回归方式，以及尚未完成的实板跑分。

## 上游版本

EEMBC 官方仓库的 CoreMark **只有 `v1.01` 一个标签**（commit `cfa9ab3778`）；`v1.0` 标签并不存在，网上流传的 v1.0 下载链接现已全部 404。因此本工程使用 **CoreMark 1.01**，它自报的版本字符串仍是 `CoreMark 1.0`，CRC 与 v1.0 一致——参赛要求的"CoreMark v1.0"按这一口径满足。

取源与校验：

- 归档：`tmp/coremark-v1.01.tar.gz`，401208 字节
- SHA256：`99C5A6D63AF85A281B4E4D6CCB522C446653C435DFEC9455AD73EF9E71F28BDE`

EEMBC 的五个算法源文件（`core_list_join.c`、`core_main.c`、`core_matrix.c`、`core_state.c`、`core_util.c`）与 `coremark.h`、`LICENSE.md` 逐字未改，放在 `software/coremark/`。`core_list_join.c` 的 `info.data16 may be used uninitialized` 是上游代码在该路径上无法被 GCC 证明初始化所致，属未修改的上游源码，`Makefile` 只对该文件名放宽 `-Werror=maybe-uninitialized`，豁免绑定到确切文件名，不会掩盖我们自己代码里的新告警。

## 移植层

| 文件 | 作用 |
|---|---|
| `software/coremark/core_portme.h` | 类型、`MEM_METHOD`、`MAIN_HAS_NOARGC` 等 EEMBC 要求由移植者定义的宏；含 `PROFILE_RUN`/`PERFORMANCE_RUN`/`VALIDATION_RUN` 的选择块 |
| `software/coremark/core_portme.c` | `barebones_clock()`、`time_in_secs()`、`portable_init()`/`portable_fini()`、`uart_send_char()`、种子与 `default_num_contexts` |
| `software/coremark/board_coremark_config.h` | 板级常量：`BOARD_CLOCK_HZ`、`ITERATIONS`、`FLAGS_STR` |
| `software/coremark/ee_printf.c` | 自写最小 `ee_printf`（EEMBC 原版依赖运行期除法和 `uart_send_char` 的 `#error` 占位） |
| `software/coremark/softmath.c` | `__mulsi3`、`__udivsi3`、`__umodsi3` 等 RV32I 算术例程 |

关键选择：

- **`MEM_STATIC`**：`MEM_METHOD` 必须为 `MEM_STATIC`。若用栈上 2000 字节缓冲，会直接压垮本板预留的 1 KiB 栈。
- **`CORETIMETYPE` 为 64 位**：50 MHz 下 32 位计数约 85.9 秒回卷，而 CoreMark 单次运行就可能超过该值。
- **`HAS_FLOAT 0`**：不引入浮点格式化与 `cvt.c`。
- **种子**：`VALIDATION_RUN` 用 seed1/2 `0x3415`、seed3 `0x66`；`PERFORMANCE_RUN` 用 `0x0`/`0x0`/`0x66`；`PROFILE_RUN` 用 `0x8`×3。`seed4_volatile = ITERATIONS`。
- **`portable_fini()` 置 GPIO 为 `0xa5`**：`start.S` 固定 `call main`，而 `core_main.c` 自带 `main`，加壳会与 `-Dmain=` 互相污染，因此成功标志改由 `portable_fini` 承载。

## RV32I 没有乘除法（本移植的核心难点）

`rtl/core/rv32i_alu.sv` 只实现 `ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND/COPY_B`，**没有 MUL/DIV/REM**，整个 `rtl/` 目录对 `MUL|DIV` 零匹配，即无硬件乘法器、无 M 扩展。而 `software/verify_firmware.py` 明确拒绝 M 扩展指令，也拒绝除 `EBREAK` 外的所有系统指令（无 `ECALL`/CSR）。

项目 `LDFLAGS` 为 `-nostdlib`，不链接 libgcc，因此 `__mulsi3`/`__udivsi3` 必须自备。检查过 libgcc 的 `rv32i/ilp32/libgcc.a`：算术例程本身是纯 RV32I（27407 个可执行字中仅 `unwind-dw2.o` 的一个字被拒，该文件不会被拉入），但把它链进来既违背 `-nostdlib` 约定，也破坏"共享同一套 RV32I 固件构建与校验链路"的目标，所以改为两条措施：

1. `ee_printf.c` 的十进制转换改成 pow10 表减法循环（与 `perf_report.c` 的 `uart_u64_dec` 同法）。**注意：GCC 在 RV32I 上连除以常量 10 也不会强度削减**——强度削减需要乘法而 RV32I 没有，于是直接退回 `__umodsi3`/`__udivsi3` 库调用；这一点已由反汇编证据确认（`li a1,10; call __umodsi3`）。
2. `time_in_secs()` 的 64 位除法改为纯减法循环，避免 `__udivdi3`。

算法自身的乘法（`core_matrix.c` 的矩阵乘法、`seed = (order * seed) % 65536`、`core_list_join.c` 的 `blksize/per_item` 等）无法回避，由 `softmath.c` 提供。这些是移位加法循环，在 50 MHz 三级顺序核上会主导分数——这是本跑分的真实下限来源，不是缺陷掩盖。

## 容量

CoreMark 的多文件镜像需要 13 KB 级 ROM。原 `linker.ld` 把 `RAM` 定在 `ORIGIN = 0x2000 LENGTH = 8K`，导致 `.data` VMA 与 `.text` VMA 重叠而链接失败。实测 `-Os` 只能把 `.text` 压到 9323 字节，仍放不进 8 KB。

由于本 SoC 是 Harvard 结构（IMEM 与 DMEM 各自 16 KiB、地址均从 0 起），`linker.ld` 改为把 RAM 铺到 `0x2000`–`0x3fff` 全 8 KiB，并新增 `__ram_alias_start`。`rv32i_soc.sv` 增加 DMEM 高位别名，`verify_firmware.py` 同步接受该布局。改动后 13 项原有回归全绿，证明对既有四个镜像零影响。

当前 CoreMark 板级镜像：ROM 13044 字节、data 1612、bss 2676。

## 构建

```powershell
& .\fpga_riscv_starter\scripts\build_firmware.ps1 -App coremark -Rebuild
```

一次调用产出**两个**镜像：

| 镜像 | 用途 | 迭代次数 |
|---|---|---|
| `software/build/coremark/firmware.hex` | 上板跑分 | 自动标定（`ITERATIONS 0`） |
| `software/build/coremark/sim_firmware.hex` | 仿真回归 | 钉死为 1（`DEFS=-DITERATIONS=1`） |

板级发布包：

```powershell
& .\fpga_riscv_starter\scripts\prepare_board.ps1 -Target cpu -FirmwareApp coremark
```

## 位流（已生成，尚未上板）

```powershell
& .\fpga_riscv_starter\scripts\run_pds.ps1 -Target cpu -Stage Bitstream -ConstraintProfile Vcc33 -FirmwareApp coremark
```

产出在 `build/board_release/cpu/coremark/`：

| 文件 | 说明 |
|---|---|
| `atk_l50_top.sbit` | 1007712 字节；**sbit 内容逐次不同**（见下文「位流不可复现」），故不记录 sbit 哈希 |
| `atk_l50_top.smsk` | 同源掩码 |
| `timing.rtr` | `All Constraints Met.`（PGL25G，20 ns 周期） |
| `release.json` | `firmware_app: coremark`、`programmed: false`、`board_verified: false` |

资源占用 **1826 LUT / 1395 FF / 16 DRM18K**。

**发布目录按 app 分目录**（`board_release/cpu/<app>/`），因为两个 app 的位流只有 IMEM 内容不同，共用目录会互相覆盖。核对位流装的是哪个固件，只能看 `run_inputs.json` 的 `firmware_app`，或上板后看首行输出（CoreMark 打印 `2K performance run parameters for coremark.`）。

## 实板运行时序（算术推演，尚未实测）

单次迭代实测 **2,972,310 周期**，即 50 MHz 下 **0.0594 秒**。CoreMark 的自动标定（`core_main.c:196-213`）由此收敛到 300 次迭代：

| 标定轮次 | 迭代数 | 用时 |
|---|---|---|
| 1 | 10 | 0.59 s（不足 1 秒，继续） |
| 2 | 100 | 5.94 s（越过 1 秒，`divisor=5`，退出） |
| 最终 | `100 × (1 + 10/5) = 300` | **约 17.8 s** |

17.8 秒满足 EEMBC 的 ≥10 秒报告规则，对应分数约 **16.8 iterations/sec**。

**这组数字是周期数的算术外推，不是硅上测量**；仿真时钟下跑完一次真实运行需数亿周期，墙钟代价不可接受（实测约 3.5 万周期/秒），所以仿真回归只跑钉死 1 次迭代的镜像。上板跑分是唯一能确认它的手段。

## 可复现验证

```powershell
& .\fpga_riscv_starter\scripts\run_iverilog.ps1
```

完整回归现为 **14 项**（原 13 项 + `tb_coremark`）。`tb_coremark` 跑钉死迭代的镜像并断言三件事：

1. 三个算法的 CRC 与 EEMBC 公布值逐一相符
2. `seedcrc == 0xe9f5`、`CoreMark Size == 666`

   注意是 **`0xe9f5`（2K performance 剖面）而不是 `0x18f2`（2K validation 剖面）**：板级镜像用
   `PERFORMANCE_RUN` 种子（seed1/2 `0x0`、seed3 `0x66`），所以 seedcrc 是 `0xe9f5`。更正前本文
   这里误写成 `0x18f2`，与 `sim/tb_coremark.sv:274` 的 `if (seedcrc_value != 'hE9F5)` 不符。
3. GPIO 为 `0xa5`、未触发 trap

通过输出：

```
[PASS] coremark size=666 seedcrc=0x0000e9f5 crclist=0x0000e714 crcmatrix=0x00001fd7 crcstate=0x00008e3a ticks=2972310 lines=15
```

注意 `tb_coremark` 输出里必然出现 `ERROR! Must execute for at least 10 secs` 与 `Errors detected`，并**不打印** `Correct operation validated`：这两条判据针对性能运行，而钉死 1 次迭代的镜像必然不足 10 秒。CRC 全对才是移植正确性的依据，不要据此误判回归失败。

## 后续

1. 上板跑分：位流已在 `build/board_release/cpu/coremark/` → **GUI Program 下载** → 抄录 COM8 完整报告（迭代数、ticks、分数、CRC）。
2. 用实测值替换本文的算术外推，并把实际串口、编译参数、LUT/FF/BRAM、时序报告一并归档。
3. 命令行下载**已被证明无法独立完成上板验证**，原因不是工具用法而是硬件位：CLI 下载后
   `gouten`（STATUSR bit 17）恒为 0，所有 IO 停在 high-Z，串口必然静默。该结论已由寄存器
   级证据钉死（厂商工具自带的状态解码模板 + 两个独立读取通道 + 写入无效实验），
   详见 `docs/2026-10-23_gouten结论.md`。**下载走 GUI Program，这是唯一能点亮 IO 的路径。**
   注意旧文档中"CLI 读 GOUTEN=0 / GUI 读 GOUTEN=1"的因果解释曾一度被推翻（当时以为那个
   GOUTEN=1 读数来自一次没有编程的 `-VerifyOnly` 运行），现经穷举复核**重新成立**：
   GOUTEN 差异是 GUI 与 CLI 下载的真实、唯一区别。
## 正确性验证结论（2026-10-23）

仿真镜像 `tb_coremark` 跑 1 次迭代，输出与 EEMBC 上游已知值**逐项精确吻合**：

| 项 | 期望（id3 = 2K performance） | 实测 |
| --- | --- | --- |
| seedcrc | 0xe9f5 | 0xe9f5 |
| [0]crclist | 0xe714 | 0xe714 |
| [0]crcmatrix | 0x1fd7 | 0x1fd7 |
| [0]crcstate | 0x8e3a | 0x8e3a |

三个算法全部通过 EEMBC 官方 CRC 比对，证明 RV32I/ILP32 移植（含自写 `softmath.c`）
在功能上正确。

**关于 `Errors detected` 输出**：仿真打印 `ERROR! Must execute for at least 10 secs`
并因此打印 `Errors detected`。这是 `core_main.c:298-300` 的上游 10 秒规则：

```c
if (time_in_secs(total_time) < 10) {
    ee_printf("ERROR! Must execute for at least 10 secs for a valid result!\n");
    total_errors++;
}
```

仿真只跑 1 次迭代（2,972,310 周期 ≈ 0.059 秒 @50MHz），必然触发。这**不是**正确性
失败。`sim/tb_coremark.sv` 因此在 L250 只在「出现 Errors detected 但没有出现
Must execute for at least 10 secs」时才判失败，并单独断言三个 CRC 值。

## 位流不可复现（重要，影响发布校验方式）

同一份 RTL + 同一份固件，连续三次运行 PDS 生成的 `atk_l50_top.sbit`
**哈希各不相同**：

| 运行 | sbit sha256 |
| --- | --- |
| run1 | `F4B38821166B319D1897694BD84BEF619128C165FE7F8B8CECB77BB984290F0A` |
| run2 | `76B316D148DABE949C6E1CC0D2BB74A88795E507D00225B509FD38949F395A3E` |
| run3 | `5BA75D715BD8470523347D8F9BA487E22A6E9BEF9F38B6EFED39A975EF1A4C25` |

同时 `coremark` 与 `perf_report` 两种固件的资源占用**完全相同**
（`CLMA=518 DRM=16 SRB_arcs=40633`），因为 `sync_imem.sv:30` 的
`$readmemh(INIT_FILE, mem)` 初始化的是 BRAM **内容**而非逻辑。

**后果**：位流哈希既不能判断固件是否正确嵌入，也不能用于跨次比对。
因此 `run_pds.ps1` 新增记录 `firmware_hex_sha256`，即 PDS 实际读入
`software/build/firmware.hex` 的那个文件的哈希——这是唯一可审计「位流里到底是哪份
固件」的手段。
## 当前发布包实况（2026-10-23 复核）

| 项 | 值 |
| --- | --- |
| 包目录 | `build/board_release/cpu/coremark/` |
| `firmware_app` | `coremark` |
| **`firmware_hex_sha256`（审计位流内究竟装了哪份固件，唯一可靠依据）** | `6E2EC4015E01908BBF10EB5B7BC2D738D07F1BEE1675EA62821443B09E6D06C3` |
| sbit 大小 | 1007712 字节 |
| 资源占用 | 1826 LUT / 1395 FF / 16 DRM18K |

## 可复现的跑分流程

三步，全部在仓库内可复现，不依赖 GUI 操作之外的手工步骤：

```
# 1. 构建（板级镜像 ITERATIONS=0 自动标定；仿真镜像 -DITERATIONS=1）
.\scripts\build_firmware.ps1 -App coremark -Rebuild

# 2. 出位流并拿到发布包
.\scripts\run_pds.ps1 -Target cpu -Stage Bitstream -ConstraintProfile Vcc33 -FirmwareApp coremark
#    -> build/board_release/cpu/coremark/atk_l50_top.sbit
#    -> run_inputs.json 内 firmware_hex_sha256 可核对装入的是哪份固件

# 3. 上板后抓串口并按 EEMBC 规则判分
.\scripts\capture_uart.ps1 -Port COM8 -TimeoutSeconds 180 -CompletionMarker 'CoreMark 1.0'
.\scripts\score_coremark.ps1 -CapturePath build\uart_capture\<时间戳>\capture.txt
```

`scripts/score_coremark.ps1` 解析报告并输出 `coremark_score.json` / `.txt`，
给出 `verdict` 与 `publishable` 两个判据：

| verdict | 含义 |
| --- | --- |
| `PASS` | CRC 三项与 EEMBC 已知值一致，且运行 ≥ 10 秒 —— 成绩可发布 |
| `FAIL_TOO_SHORT` | CRC 正确但不足 10 秒 —— 结果正确，但**不可作为成绩发布** |
| `FAIL_CRC` | CRC 不匹配 —— 运行无效，脚本抛错 |

CRC 期望值取自 `coremark/core_main.c` 的 `list_known_crc` / `matrix_known_crc` /
`state_known_crc`，按 `seedcrc` 选择对应列：

| seedcrc | 剖面 | crclist | crcmatrix | crcstate |
| --- | --- | --- | --- | --- |
| 0xe9f5 | 2K performance | 0xe714 | 0x1fd7 | 0x8e3a |
| 0x18f2 | 2K validation | 0xe3c1 | 0x0747 | 0x8d84 |

分数按 EEMBC 定义计算：`iterations / seconds`，其中 `seconds` 由
`Total ticks / 50000000` 得出（tick 即核心周期，`GETMYTIME` 走 `perf_cycles()`），
并额外给出 `CoreMark/MHz` = 分数 / 50。

**脚本已做正负对照验证**（证据存于
`交接记录/2026-10-23_位流审计与CoreMark正确性/`）：

| 输入 | 预期 | 实测 |
| --- | --- | --- |
| 仿真报告（1 次迭代） | FAIL_TOO_SHORT，CRC 全对 | ✅ `score_control_tooshort.json` |
| 正常 10 秒以上报告 | PASS | ✅ `score_control_good.txt` |
| crcmatrix 篡改为 0xdead | FAIL_CRC 并抛错 | ✅ `score_control_badcrc.txt` |
| 空文件 | 不崩溃，判 FAIL_CRC | ✅ |

按 `board_coremark_config.h` 的标定推演，实板预期成绩约
**16.82 iterations/sec（≈ 0.336 CoreMark/MHz）**，运行约 17.8 秒。
该数字是算术外推，**实板未验证**——板级镜像尚未成功取得串口输出。