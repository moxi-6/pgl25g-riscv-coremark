module fpga_top #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD     = 115_200,
    parameter         MEM_FILE = "software/build/firmware.hex"
) (
    input  logic       sys_clk_i,
    input  logic       reset_n_i,
    output logic       uart_tx_o,
    output logic [7:0] led_o
);
    logic [1:0] reset_sync_q;
    logic       soc_rst_n;
    logic       halted;
    logic       trap;

    // Asynchronous assertion, synchronous release reset synchronizer.
    always_ff @(posedge sys_clk_i or negedge reset_n_i) begin
        if (!reset_n_i) reset_sync_q <= 2'b00;
        else reset_sync_q <= {reset_sync_q[0], 1'b1};
    end
    assign soc_rst_n = reset_sync_q[1];

    rv32i_soc #(
        .CLOCK_HZ (CLOCK_HZ),
        .BAUD     (BAUD),
        .MEM_FILE (MEM_FILE)
    ) u_soc (
        .clk_i     (sys_clk_i),
        .rst_n_i   (soc_rst_n),
        .uart_tx_o (uart_tx_o),
        .gpio_o    (led_o),
        .halted_o  (halted),
        .trap_o    (trap)
    );
endmodule

