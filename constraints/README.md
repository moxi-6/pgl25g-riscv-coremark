# PDS 约束接入说明

2026-10-19 更新：ATK-L50 制作入口见 `../boards/atk_l50/README.md`。已从现有官方 FDC 提取 `atk_l50_reference.fdc`，匹配新顶层 `atk_l50_bringup` / `atk_l50_top` 的端口。该文件是待核验参考约束：时钟/复位 IO 标准与指南不同，LED Bank 电源也需按核心板版本确认。以下旧说明仅供其他板型参考。

其他板型不能使用 ATK-L50 引脚：RK3568_MES2L100H、盘古 676、盘古 50 和 SoPC 板卡的器件与管脚不同。

上板时执行以下步骤：

1. 从开发板配套资料取得官方 PDS 示例工程和原理图；
2. 复制示例中的系统时钟、复位、LED 和 UART TX 约束；
3. 将约束端口名改为 `sys_clk_i`、`reset_n_i`、`led_o[7:0]`、`uart_tx_o`；
4. 确认每个 Bank 的 IO 标准和电压；
5. 为 `sys_clk_i` 建立主时钟约束；
6. 如果实际时钟不是 50 MHz，修改 `fpga_top.CLOCK_HZ`；
7. 若使用 PLL，约束输入时钟，并把 PLL 的 locked 信号加入复位释放条件；
8. 综合后检查未约束时钟、未约束 IO、setup/hold 和 worst slack。

第一版只约束 LED 和 UART。DDR3、HDMI、PCIe、摄像头等接口应从厂商示例工程逐项加入，不要凭猜测填写管脚。

