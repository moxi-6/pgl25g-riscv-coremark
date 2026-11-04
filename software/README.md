# 裸机固件构建与启动环境

固件使用 RISC-V GCC/binutils、GNU Make 和 Python 3，遵循 ILP32 ABI。工具名前缀 `riscv64-unknown-elf-` 同时支持生成 RV32 程序；实际指令集由 `-march` 指定。

## 构建

以下 PowerShell 命令在项目根目录运行：

```powershell
# 扫雷：RV32I、16 KiB RAM，同时生成相同配置的仿真固件
./scripts/build_firmware.ps1 -App mine -Isa rv32i -RamBytes 16384 -Rebuild

# 跑分：与 atk_l50_top 的扩展、8 KiB RAM 配置匹配
./scripts/build_firmware.ps1 -App coremark -Isa rv32i_zba_zbb_zmmul -RamBytes 8192 -Opt '-O3' -Relax 1 -ExtraCflags '-flto -finline-limit=1000' -Rebuild

# 已构建固件的系统回归与扫雷整机验证
./scripts/run_iverilog.ps1
python scripts/run_mine_checks.py
```

Windows 入口调用 WSL 中的工具链，可通过 `-WslDistro` 和 `-RiscvPrefix` 指定安装。Linux/WSL 可在本目录直接调用 Makefile，例如：

```sh
make RISCV_PREFIX=riscv64-unknown-elf- APP=mine.c BUILD_DIR=build/mine \
  EXTRA_SRCS=coremark/softmath.c MARCH=rv32i RAM_BYTES=16384
```

`-App coremark` 生成自动校准迭代数的板载镜像，以及 `ITERATIONS=1` 的仿真镜像。单轮仿真检查 CRC 与周期；正式成绩须来自至少10秒的实板运行。时钟配置来自 `coremark/board_coremark_config.h`，必须与板级顶层实际时钟一致。

## 存储与启动

| 区域 | 地址与用途 |
|---|---|
| 指令 ROM | `0x00000000–0x0000ffff`，64 KiB，保存代码与数据初值 |
| RAM | 以 `0x40000000` 为基址，长度由 `RAM_BYTES` 指定；低地址保留同一 RAM 的别名 |
| ROM 数据窗口 | `0x20000000–0x2000ffff`，供启动程序复制数据初值 |
| GPIO / UART / KEY | `0x10000000` / `0x10000004` / `0x10000008` |
| 周期 / 提交计数 | `0x10000010/14` / `0x10000018/1c`，64位低字／高字 |
| 配置频率 | `0x10000020`，Hz；是设计配置值，不是频率测量结果 |
| 视频帧计数 | `0x10000044` |
| 触摸寄存器 | `0x10000054–0x10000060` |
| 扫雷状态 / 提交 | `0x100000a0–0x100000dc` / `0x100000e0` |

链接器把常量和带初值数据放入 RAM，在 ROM 保存装载副本。`start.S` 从 ROM 数据窗口复制初值、清零 BSS、设置栈后调用 `main`。复位会重新执行启动过程。栈顶为 RAM 基址加容量，保持16字节对齐，链接器保留顶部1 KiB；此预留不是运行时溢出检测。

扫雷使用16 KiB RAM；跑分发布配置使用8 KiB。修改 RAM、ISA 或频率后应重建对应固件并执行验证，不能复用不同配置的镜像。

## 输出与校验

每个构建目录包含 ELF、BIN、32位字 HEX、反汇编、链接 map、编译选项、工具版本和 `firmware.json`。清单记录源文件与产物的 SHA256。校验器检查 ELF32／ILP32、容量、栈对齐、装载布局及指令编码，仅接受声明配置支持的 RV32I、Zmmul、Zba/Zbb 指令。

`prepare_board.ps1` 会复核源文件和产物哈希。双发射取指使用 `.hex.even` 和 `.hex.odd` 两份 ROM 初始化文件，由 `scripts/split_imem_banks.py` 从同一 HEX 生成。

环境为 freestanding 裸机，不提供完整 libc、动态堆、特权 CSR、异常向量或中断服务框架。应用应使用已有 MMIO 和运行时接口。CoreMark 上游文件及显示字库的许可范围见 [第三方说明](../docs/THIRD_PARTY_NOTICES.md)。
