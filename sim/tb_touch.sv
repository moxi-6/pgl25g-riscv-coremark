// Self-checking testbench for the GT9147 touch driver.
//
// The I2C bus is modelled as a resolved open-drain net: each participant only
// ever pulls SDA low, so the resolved level is 0 when either side drives low
// and 1 otherwise.  This mirrors the real board (external pull-ups) and avoids
// the X results that mixed tri1 / assign statements produce in iverilog.
`timescale 1ns/1ps

module tb_touch;

    localparam int CLK_HZ = 2_000_000;
    localparam int SCL_HZ = 400_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #250 clk = ~clk;          // 2 MHz

    wire  tp_scl, tp_sda_o, tp_sda_oe, tp_int, tp_int_oe, tp_rst;
    logic m_sda_oe, m_sda_o;
    wire  sda = ((tp_sda_oe && !tp_sda_o) || (m_sda_oe && !m_sda_o)) ? 1'b0 : 1'b1;

    wire [15:0] x, y;
    wire [31:0] id;
    wire        pressed, tap;
    wire [4:0]  seq;
    wire [3:0]  cnt;
    wire [2:0]  status;
    wire [31:0] events;
    wire [7:0]  acks, last_reg;

    gt9147_touch #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .tp_scl_o      (tp_scl),
        .tp_sda_o      (tp_sda_o),
        .tp_sda_oe     (tp_sda_oe),
        .tp_sda_i      (sda),
        .tp_rst_o      (tp_rst),
        .tp_int_o      (tp_int),
        .tp_int_oe     (tp_int_oe),
        .x_o           (x),
        .y_o           (y),
        .id_o          (id),
        .pressed_o     (pressed),
        .seq_o         (seq),
        .count_o       (cnt),
        .status_o      (status),
        .event_cnt_o   (events),
        .tap_latch_o   (tap),
        .ack_err_cnt_o (acks),
        .last_reg_o    (last_reg),
        .reinit_i      (1'b0),
        .tap_clear_i   (1'b0)
    );

    gt9147_model u_model (
        .scl_i    (tp_scl),
        .sda_oe_o (m_sda_oe),
        .sda_o_o  (m_sda_o),
        .sda_i    (sda),
        .rst_n_i  (rst_n)
    );

    int errors = 0;
    task automatic check(input bit cond, input string what);
        if (cond) $display("  ok   %s", what);
        else begin $display("  FAIL %s", what); errors++; end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // Power-on: reset pulse, then the init sequence.
        begin : wait_ready
            int guard = 0;
            while (status != 3'd1 && guard < 4_000_000) begin
                @(posedge clk);
                guard++;
            end
        end
        $display("[%0t] status=%0d id=0x%08x acks=%0d last_reg=0x%02x",
                 $time, status, id, acks, last_reg);
        check(status == 3'd1,     "driver reached READY");
        check(id == 32'h3931_3437 || id == 32'h0000_9147, "reads product id 9147");
        check(acks == 8'd0,       "no I2C errors during init");

        // Not touching yet.
        repeat (2000) @(posedge clk);
        check(!pressed, "idle reports no touch");

        // Inject a touch at (300, 220).
        u_model.inject_touch(16'd300, 16'd220);
        begin : wait_touch
            int guard = 0;
            while (!pressed && guard < 2_000_000) begin
                @(posedge clk);
                guard++;
            end
        end
        $display("[%0t] touch pressed=%b x=%0d y=%0d seq=%0d tap=%b",
                 $time, pressed, x, y, seq, tap);
        check(pressed,      "press detected");
        check(x == 16'd300, "x coordinate");
        check(y == 16'd220, "y coordinate");
        check(tap,          "tap latched");

        // Lift: the controller reports zero contacts.
        u_model.inject_release();
        begin : wait_release
            int guard = 0;
            while (pressed && guard < 2_000_000) begin
                @(posedge clk);
                guard++;
            end
        end
        check(!pressed, "release detected");

        repeat (20000) @(posedge clk);
        check(acks == 8'd0, "still no I2C errors");
        $display("[%0t] events=%0d seq=%0d status=%0d", $time, events, seq, status);

        if (errors == 0) $display("*** TOUCH PASS ***");
        else             $display("*** TOUCH FAIL: %0d errors ***", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("*** TOUCH TIMEOUT (status=%0d id=0x%08x acks=%0d last_reg=0x%02x) ***",
                 status, id, acks, last_reg);
        $finish;
    end
endmodule