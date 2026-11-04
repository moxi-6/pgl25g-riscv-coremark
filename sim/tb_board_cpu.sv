`timescale 1ns/1ps
module tb_board_cpu;
    localparam integer BIT_NS = 100;
    logic clk = 0;
    logic reset_n = 0;
    logic [3:0] key = 4'hf;
    wire uart_txd;
    wire [3:0] led;
    logic [7:0] value;
    reg [31:0] expected = {"OK", 8'h0d, 8'h0a};
    // Preserve the accelerated, scalar main-firmware regression independently
    // of the board's current CoreMark defaults. Real divider timing is covered
    // by tb_board_clock with the vendor global-buffer simulation model.
    atk_l50_top #(.INPUT_CLOCK_HZ(1_000_000), .CLOCK_HZ(1_000_000),
        .CPU_CLOCK_DIV(1), .BAUD(100_000), .DUAL_ISSUE(1'b0),
        .DMEM_WORDS(4096)) dut (
        .sys_clk(clk), .sys_rst_n(reset_n), .key(key), .uart_txd(uart_txd), .led(led)
    );
    always #5 clk = ~clk;
    `include "sim/uart_receive.svh"
    initial begin
        #100000;
        $fatal(1, "Board CPU timeout");
    end
    initial begin
        for (integer run_no = 0; run_no < 2; run_no = run_no + 1) begin
            reset_n = 0;
            repeat (4) @(negedge clk);
            if (led !== 0 || uart_txd !== 1'b1) $fatal(1, "Board reset mismatch");
            #2 reset_n = 1;
            repeat (3) @(negedge clk);
            #2 key = 4'he;
            @(posedge clk); #1;
            if (dut.u_soc.key_i !== 4'hf) $fatal(1, "Asynchronous key bypassed synchronizer");
            @(posedge clk); #1;
            if (dut.u_soc.key_i !== 4'he) $fatal(1, "Key press did not reach MMIO after two clocks");
            @(negedge clk); key = 4'hf;
            repeat (2) @(posedge clk); #1;
            if (dut.u_soc.key_i !== 4'hf) $fatal(1, "Key release did not reach MMIO");
            for (integer n = 0; n < 4; n = n + 1) begin
                receive_byte(value);
                if (value !== expected[31 - n*8 -: 8]) $fatal(1, "Board UART byte %0d: %h", n, value);
            end
            repeat (10) @(negedge clk);
            if (!dut.halted || dut.trap) $fatal(1, "CPU halt/trap mismatch");
            if (dut.gpio !== 8'ha5 || led !== 4'h5) $fatal(1, "Board GPIO/LED mapping mismatch");
        end
        $display("[PASS] atk_l50_cpu serial=OK_CR_LF gpio=a5 led=5 reset_runs=2");
        $finish;
    end
endmodule
