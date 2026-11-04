// Board diagnosis without CPU, firmware, or external-reset dependence.
// FPGA configuration INIT must set startup_q=0 (check the synthesized netlist).
// TX continuously sends ASCII U (0x55), making baud and pin activity observable.
module atk_l50_uart_diagnostic #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
) (
    input wire sys_clk,
    input wire sys_rst_n,
    output wire uart_txd,
    output wire [3:0] led
);
    logic [24:0] count_q = 25'b0;
    logic [5:0] startup_q = 6'b0;
    wire uart_reset_n = &startup_q;
    always_ff @(posedge sys_clk) begin
        count_q <= count_q + 1'b1;
        if (!uart_reset_n) startup_q <= startup_q + 1'b1;
    end
    assign led[0] = 1'b1;
    assign led[1] = 1'b0;
    assign led[2] = count_q[24];
    assign led[3] = ~sys_rst_n;
    uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) u_uart (
        .clk_i(sys_clk),.rst_n_i(uart_reset_n),
        .valid_i(1'b1),.data_i(8'h55),.ready_o(),.tx_o(uart_txd)
    );
endmodule
