`timescale 1ns/1ps
module tb_perf_firmware;
    localparam integer BIT_NS = 100;
    logic clk = 0, rst_n = 0;
    wire uart_txd, halted, trap;
    wire [7:0] gpio;
    logic [7:0] value;
    reg [71:0] expected = {"PERF OK", 8'h0d, 8'h0a};
    integer perf_reads = 0;
    rv32i_soc #(.CLOCK_HZ(1_000_000), .BAUD(100_000),
        .MEM_FILE("software/build/perf_test/firmware.hex")) dut (
        .clk_i(clk), .rst_n_i(rst_n), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );
    always #5 clk = ~clk;
    `include "sim/uart_receive.svh"
    always @(posedge clk) if (rst_n && dut.dmem_valid && !dut.dmem_write && dut.perf_selected)
        perf_reads = perf_reads + 1;
    initial begin
        #1000000; $fatal(1, "Performance firmware timeout");
    end
    initial begin
        #1;
        for (integer n = 0; n < 4096; n = n + 1) dut.u_dmem.mem[n] = 'hdeadbeef;
        for (integer run_no = 0; run_no < 2; run_no = run_no + 1) begin
            rst_n = 0;
            perf_reads = 0;
            repeat (4) @(negedge clk); rst_n = 1;
            for (integer n = 0; n < 9; n = n + 1) begin
                receive_byte(value);
                if (value !== expected[71-n*8 -: 8]) $fatal(1, "Performance UART byte %0d: %h", n, value);
            end
            repeat (20) @(negedge clk);
            if (!halted || trap || gpio !== 'ha5 || perf_reads < 13)
                $fatal(1, "Performance firmware result/halt/MMIO mismatch reads=%0d", perf_reads);
        end
        $display("[PASS] perf_firmware real_c timing_workload uart reset_runs=2");
        $finish;
    end
endmodule
