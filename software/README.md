# 裸机固件构建与启动环境

2026-10-19 已定位本机 Ubuntu/WSL 中的 `riscv64-unknown-elf-gcc 14.2.0`，并从源码生成两份 RV32I/ILP32 固件。工具名前缀中的 64 不代表生成 64 位程序；构建明确使用 `-march=rv32i -mabi=ilp32`。

## Windows 构建入口

在桌面 `FPGA项目` 根目录运行：

```powershell
# 编译主演示和 C 运行环境测试，生成并校验全部产物
& .\fpga_riscv_starter\scripts\build_firmware.ps1 -Rebuild

# 一条命令完成重建和 12 项 RTL/软件集成仿真
& .\fpga_riscv_starter\scripts\run_iverilog.ps1 -RebuildFirmware
```

入口使用现有 WSL Ubuntu、GNU Make、RISC-V GCC/binutils 和 Python 3，不需要 Windows 版 make。可通过 `-WslDistro`、`-RiscvPrefix` 指定其他已安装的环境；`-App main`、`-App runtime_test` 或 `-App perf_test` 单独构建，默认构建全部三个。小程序每次均重新编译，避免切换 APP 或工具链后误用旧 ELF。

在 Linux/WSL 的 `software` 目录也可直接运行：

```sh
make RISCV_PREFIX=riscv64-unknown-elf-
make RISCV_PREFIX=riscv64-unknown-elf- APP=runtime_test.c BUILD_DIR=build/runtime_test
python3 check_firmware_guards.py
```

`run_iverilog.ps1` 不加 `-RebuildFirmware` 时只使用现有 HEX 做仿真，并不会重编译。缺少任一所需 HEX 时完整回归失败；`-SkipSoc` 只运行 8 项不依赖固件的测试。

## 地址与装载

| 地址 | 当前用途 |
|---|---|
| 指令空间 `0x00000000–0x00003fff` | 16 KiB ROM，包括代码和 RAM 数据初值镜像 |
| 数据空间 `0x00000000–0x00003fff` | 16 KiB RAM；链接器当前使用上半区 `0x2000–0x3fff` |
| `0x10000000` | GPIO，低 8 位有效，四路物理 LED 只观察低 4 位 |
| `0x10000004` | UART，低字节写入发送，读 bit0=ready |
| `0x10000010/14` | 64 位周期计数低/高字，只读 |
| `0x10000018/1c` | 64 位已提交指令计数低/高字，只读 |
| `0x10000020` | 配置时钟频率（Hz），只读，不代表实际频率测量 |
| 数据空间 `0x20000000–0x20003fff` | 同一 ROM 的只读数据映射，供启动代码读取初值；写入忽略 |

链接脚本把 `.rodata/.srodata/.data/.sdata` 共同放入 RAM 的 `.data` 输出段，并用 `AT> ROM` 在 ROM 保存初值。`start.S` 通过 ROM 数据映射逐字复制到 RAM，然后清零 `.bss/.sbss/COMMON`，最后调用 `main`。每次复位均重新执行，因此字符串、带初值全局变量和零初始化变量可正确恢复。

常量在 C 语言中仍为只读对象，但物理位置为 RAM，没有硬件写保护。RAM 阵列本身不复位，启动代码只处理已分配的数据区。栈顶为 `0x4000`，按 ABI 保持 16 字节对齐；顶部预留 1 KiB 栈，静态数据侵占时链接失败。此预留不是运行时栈溢出保护。

## 程序及产物

| 程序 | 产物目录 | 本轮 ROM 大小 | 行为 |
|---|---|---|---|
| `main.c` | `software/build/` | 172 字节，含 8 字节初始化数据 | 常量字符串输出 `OK\r\n`，GPIO `0x5a → 0xa5` |
| `runtime_test.c` | `software/build/runtime_test/` | 396 字节，含 28 字节初始化数据 | 验证初值、16 字节 BSS，修改变量后输出 `RUNTIME OK\r\n`，GPIO 为 `0xa5` |
| `perf_test.c` | `software/build/perf_test/` | 448 字节，含 12 字节初始化数据 | 读取周期/提交数，执行校验和循环，输出 `PERF OK\r\n`；非 CoreMark |

性能计数器的复位、回卷、停机和计时开销语义见 `docs/性能计数与基准测试.md`；软件接口为 `perf.h`。固件来源清单也记录头文件哈希。

每个目录包含 ELF、BIN、按小端 32 位字编码的 HEX、反汇编、map、工具版本及 `firmware.json`。JSON 记录源文件和 ELF/BIN/HEX 的 SHA256。验证脚本检查 ELF32/RISC-V/ILP32、代码指令编码、ROM/RAM 容量、栈对齐、数据装载地址和 ELF/BIN 一致性，拒绝压缩指令、M 扩展以及当前 CPU 不支持的系统指令。

两份固件重复编译后的 ELF/BIN/HEX 六个校验值一致；记录在根目录 `交接记录/2026-10-19_固件重复构建校验.json`。编译检查不能替代完整 ISA 一致性测试。

板级源码包包含主演示固件和构建来源；`prepare_board.ps1 -Target cpu` 会校验源文件及产物哈希，源代码修改后必须先重新构建。PDS 在源码包根目录中创建工程，使 `software/build/firmware.hex` 能被找到，并检查同步 ROM 的双读口及初始化是否被实际综合工具正确处理。

目前为 freestanding 裸机环境，尚未提供完整 libc、堆分配、异常/中断、CSR 或 CoreMark 支持。不能据此宣称任意 C/C++ 工程均可直接运行。
