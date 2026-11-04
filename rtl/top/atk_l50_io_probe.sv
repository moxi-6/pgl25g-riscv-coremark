// Board diagnosis independent of the reset synchronizer and LED ring state.
// ADS maps the free-running counter to DFFs with INIT=0 (check the netlist).
module atk_l50_io_probe (
    input wire sys_clk,
    input wire sys_rst_n,
    output wire uart_txd,
    output wire [3:0] led
);
    logic [24:0] count_q;
    always_ff @(posedge sys_clk) count_q <= count_q + 1'b1;
    assign led[0] = 1'b1;
    assign led[1] = 1'b0;
    assign led[2] = count_q[24];
    assign led[3] = ~sys_rst_n;
    assign uart_txd = 1'b1;
endmodule
