`timescale 1ns/1ps
module tb_bringup;
    localparam integer BIT_NS = 100; // 10 clocks per UART bit
    logic clk = 0;
    logic reset_n = 0;
    wire uart_txd;
    wire [3:0] led;
    logic [7:0] value;
    logic [3:0] previous_led;
    integer led_steps = 0;
    integer stable_cycles = 0;
    reg [95:0] expected = {"ATK-L50 OK", 8'h0d, 8'h0a};
    atk_l50_bringup #(.CLOCK_HZ(1_000_000), .BAUD(100_000),
        .LED_STEP_CYCLES(17), .MESSAGE_PERIOD_CYCLES(1300)) dut (
        .sys_clk(clk), .sys_rst_n(reset_n), .uart_txd(uart_txd), .led(led)
    );
    always #5 clk = ~clk;
    `include "sim/uart_receive.svh"
    // Verify order and exact divider, independent of internal LED counter.
    always @(negedge clk) begin
        if (!dut.rst_n) begin
            if (led !== 4'b0001) $fatal(1, "LED reset mismatch");
            previous_led = 4'b0001;
            stable_cycles = 0;
        end else begin
            stable_cycles = stable_cycles + 1;
            if (led !== previous_led) begin
                // The first active interval starts after synchronizer release.
                if (stable_cycles != 18 && led_steps == 0) $fatal(1, "First LED interval mismatch");
                if (led_steps != 0 && stable_cycles != 17) $fatal(1, "LED divider mismatch");
                if (led !== {previous_led[2:0], previous_led[3]}) $fatal(1, "LED rotation mismatch");
                previous_led = led;
                stable_cycles = 0;
                led_steps = led_steps + 1;
            end
        end
    end
    initial begin
        #1000000;
        $fatal(1, "Bringup timeout");
    end
    initial begin
        for (integer run_no = 0; run_no < 2; run_no = run_no + 1) begin
            reset_n = 0;
            led_steps = 0;
            repeat (4) @(negedge clk);
            if (uart_txd !== 1'b1) $fatal(1, "UART reset must be idle");
            #2 reset_n = 1;
            for (integer n = 0; n < 24; n = n + 1) begin
                receive_byte(value);
                if (value !== expected[95 - (n % 12)*8 -: 8])
                    $fatal(1, "Bringup UART byte %0d mismatch: %h", n, value);
            end
            if (led_steps < 8) $fatal(1, "Insufficient LED rotations");
            // Assert reset during the next start bit, then verify restart.
            @(negedge uart_txd);
            #23;
        end
        reset_n = 0;
        #1;
        if (uart_txd !== 1'b1) $fatal(1, "Async reset did not abort UART");
        $display("[PASS] atk_l50_bringup serial=48_bytes reset=mid_frame led=rotation_and_divider");
        $finish;
    end
endmodule
