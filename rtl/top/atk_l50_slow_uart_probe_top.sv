// Slow-UART pin-ring verifier top level.
//
// Same IOBUF structure as atk_l50_uart_pad_diagnostic: one GTP_IOBUF drives the
// physical C15 pad and simultaneously samples it back through O. Routing the
// transmit line through a real IOBUF (rather than assigning the port directly)
// is what makes this path identical to the one the CPU design uses.
//
// The core (atk_l50_slow_uart_probe) transmits 0xA5 once every 10 s at BAUD=1,
// so each bit lasts 1.0 s -- long enough for the JTAG boundary-scan sampler
// (~0.4 s/sample) to resolve every bit of the frame.
//
// led[0]: core running (startup delay elapsed)
// led[1]: frame in progress
// led[2]: bit-tick pulse (high for one clock per bit boundary)
// led[3]: frame-start beacon (high during the start-bit window)
module atk_l50_slow_uart_probe_top (
    input  wire sys_clk,
    input  wire sys_rst_n,
    inout  wire uart_txd,
    output wire [3:0] led
);
    (* syn_keep=1 *) wire tx_logic;
    (* syn_keep=1 *) wire uart_pad_sample;

    GTP_IOBUF u_tx_pad (
        .I(tx_logic), .T(1'b0), .O(uart_pad_sample), .IO(uart_txd)
    );

    atk_l50_slow_uart_probe #(
        .CLOCK_HZ(50_000_000),
        .CLKS_PER_BIT(1_600_000_000)
    ) u_core (
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .uart_txd(tx_logic),
        .led(led)
    );
endmodule