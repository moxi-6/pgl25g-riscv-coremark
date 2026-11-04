# 实板验收与 ILA 采样计划

2026-10-28。此文是待执行方案，所有未采集字段都保持“待实测”。不需要为编写本方案连接开发板。

## 验收顺序

1. 固定并校验发布包、固件 HEX 哈希和约束版本；先打开 UART，再写易失 SRAM。恢复输出后，按键复位重复两次，确认同一程序都能完成。下载 DONE/回读通过与 CPU 运行分别记录。
2. 运行 perf_report，保存完整原始字节和 CLOCK_HZ、ACC、CYCLES、INSTRET。CLOCK_HZ 是配置值，不是电气主频测量。相同工作区间计算 CPI=CYCLES/INSTRET。
3. 运行板级 CoreMark 镜像，让自动标定完成。保存完整报告而非仅截取结尾；检查 ≥10 秒、seedcrc 和三项算法 CRC。标记真实 BoardCapture 后再计算可发布指标。
4. 对执行 CoreMark 的 CPU 插入官方 FIC/ILA，重新检查时序与资源。诊断镜像、非插核 CPU 和插核 CPU 的位流分别记录，不能混用身份或资源数据。

## 建议采样信号

| 层次/信号 | 用途 |
|---|---|
| atk_l50_top.rst_n | 确认内部复位释放 |
| u_soc.u_core.ex_valid_q / ex_pc_q / ex_instr_q | 标记执行区间和算法 |
| u_soc.u_core.commit_valid_o / commit_pc_o / commit_instr_o | 提交顺序与速率 |
| u_soc.u_core.ex_wait | 数据事务引起的 EX 停顿 |
| u_soc.u_core.imem_valid_o / imem_ready_i / imem_rvalid_i | 取指接受与返回延迟 |
| u_soc.u_core.fetch_valid / g_sync_fetch.buffered_q / discard_q | 缓冲命中与错误路径丢弃 |
| u_soc.u_core.dmem_valid_o / dmem_ready_i / dmem_write_o / dmem_addr_o | 访存类别和等待区间 |
| u_soc.u_core.redirect / control_target | 分支、跳转带来的清除开销 |
| u_soc.halted_o / trap_o / gpio_o | 完成、异常与完成标记 |
| u_soc.cycle_count_q / instret_count_q | 长区间计数，避免只用短波形推断总体 CPI |

这些是 RTL 层次名；综合会扁平化或重命名，实际 FIC 必须依据对应 synth/adf 中的网名重连。不能把上述列表直接当成已经插核成功的配置。建议先采 512–2048 点小窗口，再按剩余 BRAM 和时序余量扩展。

## 算法触发条件

先读取本次固件 ELF/map，找到 iterate、core_bench_list、core_bench_matrix、core_bench_state、start_time、stop_time 的地址。当前板级固件 map 的例子为 iterate=0x68、list=0xd18、matrix=0x1ba8、state=0x2050；**重编译后必须重新核对，专用仿真镜像也不能直接套用板级地址**。

触发条件建议为 ex_valid_q=1 且 ex_pc_q 进入选定函数区间。每类至少保存一段包含 load-use、数据等待和控制转移的波形。导出 DPRJ、FIC、WDF/CSV 和可阅读的波形截图，并附位流、HEX、约束与工具版本哈希。

## 分析方法与证据边界

- 计数区间固定为同一 begin/end 事件；CPI=区间周期/提交数，不能把包含 UART 打印的总时长和算法指令数混算。
- 统计 ex_wait、取指反压、无有效 EX、redirect 等现象；这些分类可能重叠，应给交集或明确统计口径。
- 仿真 VCD 与硬件 ILA 分开标注。已有《性能分析报告_离线版》的 VCD 只是分析方法示例。
- 完成后把真实报告填入实板结果表，保留原始证据。不以“估计约 16.8 分”替代测量。

## 判分命令

```powershell
& .\scripts\score_coremark.ps1 -CapturePath <完整报告.txt> -EvidenceKind BoardCapture -ClockHz 50000000 -LutCount <该版本实际LUT数>
```

BoardCapture 标签表示调用者明确声明该文件来自实板，脚本本身不能认证来源。输出 PASS 仍须与原始串口记录、固件和位流身份一起归档。
