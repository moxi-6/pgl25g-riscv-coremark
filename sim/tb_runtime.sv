`timescale 1ns/1ps
module tb_runtime;
    localparam integer BIT_NS = 100;
    logic clk = 0, rst_n = 0;
    wire uart_txd, halted, trap;
    wire [7:0] gpio;
    logic [7:0] value;
    reg [95:0] expected = {"RUNTIME OK", 8'h0d, 8'h0a};
    rv32i_soc #(.CLOCK_HZ(1_000_000), .BAUD(100_000),
        .MEM_FILE("software/build/runtime_test/firmware.hex")) dut (
        .clk_i(clk), .rst_n_i(rst_n), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );
    always #5 clk = ~clk;
    `include "sim/uart_receive.svh"
    initial begin
        #1000000;
        $fatal(1, "C runtime timeout (missing initialization or UART output)");
    end
    initial begin
        // BSS must be cleared by startup, not accidentally zero in simulation.
        #1;
        for (integer n = 0; n < 4096; n = n + 1) dut.u_dmem.mem[n] = 32'hdeadbeef;
        for (integer run_no = 0; run_no < 2; run_no = run_no + 1) begin
            rst_n = 0;
            repeat (4) @(negedge clk); rst_n = 1;
            for (integer n = 0; n < 12; n = n + 1) begin
                receive_byte(value);
                if (value !== expected[95-n*8 -: 8]) $fatal(1, "Runtime UART byte %0d: %h", n, value);
            end
            repeat (20) @(negedge clk);
            if (!halted || trap || gpio !== 8'ha5) $fatal(1, "Runtime stop/result mismatch");
            // RAM remains mutated after this run. Reset must restore data/BSS.
        end
        $display("[PASS] c_runtime rodata initialized_data poisoned_bss reset_restores_state serial_runs=2");
        $finish;
    end
endmodule
