// Reuses the continuous-U diagnostic while sampling the same physical TX pad.
// O is the IOBUF input path; tx_logic is the independent output drive path.
module atk_l50_uart_pad_diagnostic (
    input wire sys_clk,
    input wire sys_rst_n,
    inout wire uart_txd,
    output wire [3:0] led
);
    (* syn_keep=1 *) wire tx_logic;
    (* syn_keep=1 *) wire uart_pad_sample;
    wire [3:0] logic_led;
    (* syn_preserve=1 *) reg pad_sample_q;
    always @(posedge sys_clk) pad_sample_q <= uart_pad_sample;
    assign led={logic_led[3:1],pad_sample_q};
    atk_l50_uart_diagnostic u_logic (
        .sys_clk(sys_clk),.sys_rst_n(sys_rst_n),.uart_txd(tx_logic),.led(logic_led)
    );
    GTP_IOBUF u_tx_pad (
        .I(tx_logic),.T(1'b0),.O(uart_pad_sample),.IO(uart_txd)
    );
endmodule
