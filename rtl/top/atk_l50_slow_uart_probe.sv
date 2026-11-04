// Slow-UART pin-ring verifier.
//
// Purpose: prove on silicon that the pin actually carries the bit pattern the
// design intends, without a scope and without any user hardware action.
//
// MEASURED: a cfg_debug_operate boundary-scan sample costs ~1.57 s of wall
// clock (313.7 s for 200 samples), not the ~0.4 s the command's own timing
// report suggests. A 115200-baud frame is therefore invisible to this path.
//
// So the bit period must be set well above the 1.57 s sample interval: this
// design uses CLKS_PER_BIT = 50,000,000 * 32 = 1.6e9 cycles = 32 s per bit and
// 320 s per frame, giving roughly 20 samples per bit. The first attempt used
// BAUD=1 (1.0 s per bit, 2.5 samples per bit) and was under-sampled -- the idle
// level between frames aliased into what looked like activity.
//
// The frame is a hard-coded 0xA5. Every value is chosen so the expected pin
// waveform is unambiguous:
//   0xA5 = 1010_0101, sent LSB first -> data bits 1,0,1,0,0,1,0,1
//   full frame: start(0) 1 0 1 0 0 1 0 1 stop(1)
//              = 0 1 0 1 0 0 1 0 1 1
// A continuous sender repeats this every 10 s. Any deviation -- wrong bit order,
// wrong frame length, a stuck pin -- changes the decoded pattern.
//
// led[3] is a frame-start beacon: it is high for exactly one bit time at the
// beginning of each frame, giving the decoder an anchor.
module atk_l50_slow_uart_probe #(
    parameter integer CLOCK_HZ = 50_000_000,
    // Cycles per bit. 32 s per bit at 50 MHz: ~20 JTAG samples per bit.
    parameter integer CLKS_PER_BIT = 1_600_000_000
) (
    input  wire sys_clk,
    input  wire sys_rst_n,
    output wire uart_txd,
    output wire [3:0] led
);
    logic [31:0] bit_count_q;
    logic [3:0]  bit_index_q;
    logic        busy_q;
    logic [9:0]  shift_q;
    logic        startup_q;

    // Startup delay so configuration settles before the first frame.
    logic [7:0] startup_count_q = 8'd0;
    wire        run = &startup_count_q;

    always_ff @(posedge sys_clk) begin
        if (!run) startup_count_q <= startup_count_q + 1'b1;
    end

    wire tick = (bit_count_q == CLKS_PER_BIT - 1);

    always_ff @(posedge sys_clk) begin
        if (!run) begin
            bit_count_q <= 32'd0;
            bit_index_q <= 4'd0;
            busy_q      <= 1'b0;
            shift_q     <= 10'h3ff;
        end else if (!busy_q) begin
            // Frame: start bit 0, 0xA5 LSB first, stop bit 1.
            shift_q     <= {1'b1, 8'hA5, 1'b0};
            bit_index_q <= 4'd0;
            bit_count_q <= 32'd0;
            busy_q      <= 1'b1;
        end else if (tick) begin
            bit_count_q <= 32'd0;
            if (bit_index_q == 4'd9) begin
                busy_q  <= 1'b0;
                shift_q <= 10'h3ff;
            end else begin
                bit_index_q <= bit_index_q + 4'd1;
                shift_q     <= {1'b1, shift_q[9:1]};
            end
        end else begin
            bit_count_q <= bit_count_q + 32'd1;
        end
    end

    assign uart_txd = busy_q ? shift_q[0] : 1'b1;

    // led[3] marks the first bit time of each frame (the start bit window).
    assign led[0] = run;
    assign led[1] = busy_q;
    assign led[2] = tick;
    assign led[3] = busy_q && (bit_index_q == 4'd0);
endmodule