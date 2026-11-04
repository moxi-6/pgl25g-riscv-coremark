// GT9147 capacitive touch controller bridge.
//
// The chip sits on its own two-wire bus (SCL/SDA), uses a 16-bit register
// address and reports one to five touch points in a 40-byte buffer.  The
// controller needs a power-on sequence before it answers:
//
//   VDD stable  -> T2 > 10 ms
//   INT level selects the 7-bit I2C address (high -> 0x14, low -> 0x5D)
//   T3 > 100 us
//   RESET low    (T4 > 5 ms)
//   RESET high
//   INT released -> T6 > 50 ms -> touch scanning starts
//
// This module performs that sequence once after reset, verifies the product
// ID ("9147"/"911"), then polls 0x814E and, when a frame is ready, reads the
// coordinates at 0x8150 and writes 0x814E back to zero.  Everything the CPU
// needs is exported as plain values; no software timing is involved.
//
// If the first address attempt fails (no I2C acknowledge) the sequence is
// repeated with the alternate address so a GT911 panel or a board without the
// INT pull-up still has a chance to work.
module gt9147_touch #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 100_000
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    // Board pins.  SDA and INT are bidirectional at the top level.
    output logic        tp_scl_o,
    output logic        tp_sda_o,
    output logic        tp_sda_oe,
    input  logic        tp_sda_i,
    output logic        tp_rst_o,
    output logic        tp_int_o,
    output logic        tp_int_oe,
    // Register file
    output logic [15:0] x_o,
    output logic [15:0] y_o,
    output logic [31:0] id_o,
    output logic        pressed_o,
    output logic [4:0]  seq_o,
    output logic [3:0]  count_o,
    output logic [2:0]  status_o,
    output logic [31:0] event_cnt_o,
    output logic        tap_latch_o,
    output logic [7:0]  ack_err_cnt_o,
    output logic [7:0]  last_reg_o,
    input  logic        reinit_i,
    input  logic        tap_clear_i
);
    localparam integer MS = (CLK_HZ / 1000 < 1) ? 1 : (CLK_HZ / 1000);

    // Scan refresh period of the controller is 7..20 ms; polling slower than
    // that only adds latency, so 10 ms is used.
    localparam [23:0] POLL_MS = 24'd10;

    localparam [3:0]
        S_BOOT     = 4'd0,
        S_ADDR     = 4'd1,
        S_RSTHIGH  = 4'd2,
        S_RELEASE  = 4'd3,
        S_IDREQ    = 4'd4,
        S_IDWAIT   = 4'd5,
        S_IDCHK    = 4'd6,
        S_POLLREQ  = 4'd7,
        S_POLLWAIT = 4'd8,
        S_POLLCHK  = 4'd9,
        S_COORDREQ = 4'd10,
        S_COORDWT  = 4'd11,
        S_COORDDONE= 4'd12,
        S_CLRREQ   = 4'd13,
        S_CLRWAIT  = 4'd14,
        S_WAIT     = 4'd15;

    localparam [3:0] ST_INIT   = 4'd0;
    localparam [3:0] ST_READY  = 4'd1;
    localparam [3:0] ST_NOID   = 4'd2;
    localparam [3:0] ST_IOERR  = 4'd3;

    localparam [6:0] ADDR_A = 7'h14;
    localparam [6:0] ADDR_B = 7'h5D;

    reg [3:0]  state;
    reg [23:0] delay_cnt;
    reg [3:0]  status;
    reg        addr_sel;      // 0 -> 0x14 (INT high), 1 -> 0x5D (INT low)
    reg        start_q;
    reg        req_busy;
    reg        err_seen;

    reg [6:0]  cur_dev;
    reg [15:0] cur_reg;
    reg        cur_write;
    reg [3:0]  cur_len;
    reg [63:0] cur_wdata;

    logic i2c_busy, i2c_done, i2c_ack_err;
    logic [63:0] i2c_rdata;

    reg [7:0]  poll_status;
    reg [15:0] x_q, y_q;
    reg [31:0] id_q;
    reg        pressed_q;
    reg [4:0]  seq_q;
    reg [3:0]  count_q;
    reg [31:0] event_q;
    reg        tap_q;
    reg [7:0]  ack_cnt;
    reg [7:0]  last_reg_q;

    wire [55:0] coord_raw = i2c_rdata[55:0];
    wire [15:0] raw_x = {coord_raw[23:16], coord_raw[15:8]};
    wire [15:0] raw_y = {coord_raw[39:32], coord_raw[31:24]};

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_i2c (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .start_i  (start_q),
        .dev_addr_i (cur_dev),
        .reg_addr_i (cur_reg),
        .write_i  (cur_write),
        .wr_len_i (cur_write ? cur_len : 4'd0),
        .wr_data_i (cur_wdata),
        .rd_len_i (cur_write ? 4'd0 : cur_len),
        .rd_data_o (i2c_rdata),
        .busy_o   (i2c_busy),
        .done_o   (i2c_done),
        .ack_err_o (i2c_ack_err),
        .scl_o    (tp_scl_o),
        .sda_o    (tp_sda_o),
        .sda_oe_o (tp_sda_oe),
        .sda_i    (tp_sda_i)
    );

    function automatic [23:0] ms_cycles(input [23:0] ms);
        ms_cycles = ms * MS[23:0];
    endfunction

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= S_BOOT;
            delay_cnt <= 0;
            status <= ST_INIT;
            addr_sel <= 1'b0;
            start_q <= 1'b0;
            req_busy <= 1'b0;
            err_seen <= 1'b0;
            cur_dev <= ADDR_A;
            cur_reg <= 16'd0;
            cur_write <= 1'b0;
            cur_len <= 4'd0;
            cur_wdata <= 64'd0;
            poll_status <= 8'd0;
            x_q <= 0; y_q <= 0; id_q <= 0;
            pressed_q <= 1'b0;
            seq_q <= 0; count_q <= 0; event_q <= 0; tap_q <= 1'b0;
            ack_cnt <= 8'd0; last_reg_q <= 8'd0;
            tp_rst_o <= 1'b0;
            tp_int_o <= 1'b0;
            tp_int_oe <= 1'b1;    // drive INT low: address 0x5D group
        end else begin
            start_q <= 1'b0;
            if (tap_clear_i) tap_q <= 1'b0;

            if (reinit_i && state != S_BOOT) begin
                state <= S_BOOT;
                delay_cnt <= 0;
                status <= ST_INIT;
                err_seen <= 1'b0;
                pressed_q <= 1'b0;
                seq_q <= 5'd0;
                event_q <= 32'd0;
                tp_rst_o <= 1'b0;
                tp_int_o <= 1'b0;
                tp_int_oe <= 1'b1;
            end else begin
                case (state)
                    S_BOOT: begin
                        tp_rst_o  <= 1'b0;
                        tp_int_o  <= !addr_sel;    // 0x14 needs INT high
                        tp_int_oe <= 1'b1;
                        if (delay_cnt >= ms_cycles(24'd50)) begin
                            delay_cnt <= 0;
                            state <= S_ADDR;
                        end else begin
                            delay_cnt <= delay_cnt + 24'd1;
                        end
                    end

                    S_ADDR: begin
                        // RST already low; hold the address level then release.
                        if (delay_cnt >= ms_cycles(24'd12)) begin
                            delay_cnt <= 0;
                            state <= S_RSTHIGH;
                        end else begin
                            delay_cnt <= delay_cnt + 24'd1;
                        end
                    end

                    S_RSTHIGH: begin
                        tp_rst_o <= 1'b1;
                        if (delay_cnt >= ms_cycles(24'd10)) begin
                            delay_cnt <= 0;
                            state <= S_RELEASE;
                        end else begin
                            delay_cnt <= delay_cnt + 24'd1;
                        end
                    end

                    S_RELEASE: begin
                        if (delay_cnt >= ms_cycles(24'd60)) begin
                            delay_cnt <= 0;
                            // Read the four product-ID bytes at 0x8140.
                            cur_dev   <= addr_sel ? ADDR_B : ADDR_A;
                            cur_reg   <= 16'h8140;
                            cur_write <= 1'b0;
                            cur_len   <= 4'd4;
                            cur_wdata <= 64'd0;
                            err_seen  <= 1'b0;
                            state     <= S_IDREQ;
                        end else begin
                            delay_cnt <= delay_cnt + 24'd1;
                        end
                    end

                    S_IDREQ: begin
                        if (!req_busy) begin
                            start_q  <= 1'b1;
                            req_busy <= 1'b1;
                        end else if (i2c_done) begin
                            req_busy <= 1'b0;
                            id_q     <= {i2c_rdata[7:0], i2c_rdata[15:8],
                                         i2c_rdata[23:16], i2c_rdata[31:24]};
                            err_seen <= i2c_ack_err;
                            if (i2c_ack_err) ack_cnt <= ack_cnt + 8'd1;
                            state    <= S_IDCHK;
                        end
                    end

                    S_IDCHK: begin
                        if (err_seen || id_q == 32'hFFFF_FFFF || id_q == 32'd0) begin
                            if (!addr_sel) begin
                                // Try the other address group once.
                                addr_sel <= 1'b1;
                                delay_cnt <= 0;
                                tp_rst_o <= 1'b0;
                                tp_int_oe <= 1'b1;
                                state <= S_BOOT;
                            end else begin
                                status <= ST_NOID;
                                // Retry the whole sequence after half a second.
                                delay_cnt <= 0;
                                state <= S_WAIT;
                            end
                        end else begin
                            status <= ST_READY;
                            delay_cnt <= 0;
                            state <= S_WAIT;
                        end
                    end

                    S_WAIT: begin
                        if (delay_cnt >= ms_cycles(status == ST_NOID ? 24'd500 : POLL_MS)) begin
                            delay_cnt <= 0;
                            if (status == ST_NOID) begin
                                addr_sel <= 1'b0;
                                state <= S_BOOT;
                            end else begin
                                state <= S_POLLREQ;
                            end
                        end else begin
                            delay_cnt <= delay_cnt + 24'd1;
                        end
                    end

                    S_POLLREQ: begin
                        if (!req_busy) begin
                            cur_dev   <= addr_sel ? ADDR_B : ADDR_A;
                            cur_reg   <= 16'h814E;
                            cur_write <= 1'b0;
                            cur_len   <= 4'd1;
                            start_q   <= 1'b1;
                            req_busy  <= 1'b1;
                        end else if (i2c_done) begin
                            req_busy    <= 1'b0;
                            poll_status <= i2c_rdata[7:0];
                            last_reg_q  <= i2c_rdata[7:0];
                            if (i2c_ack_err) begin
                                ack_cnt <= ack_cnt + 8'd1;
                                status  <= ST_IOERR;
                                delay_cnt <= 0;
                                state   <= S_WAIT;
                            end else begin
                                status <= ST_READY;
                                state  <= S_POLLCHK;
                            end
                        end
                    end

                    S_POLLCHK: begin
                        if (poll_status[7] && (poll_status[3:0] != 4'd0)) begin
                            count_q <= poll_status[3:0];
                            cur_dev   <= addr_sel ? ADDR_B : ADDR_A;
                            cur_reg   <= 16'h8150;
                            cur_write <= 1'b0;
                            cur_len   <= 4'd8;
                            state     <= S_COORDREQ;
                        end else begin
                            if (poll_status[7]) begin
                                // Ready frame with no contacts: release and ack it.
                                pressed_q <= 1'b0;
                                cur_dev   <= addr_sel ? ADDR_B : ADDR_A;
                                cur_reg   <= 16'h814E;
                                cur_write <= 1'b1;
                                cur_len   <= 4'd1;
                                cur_wdata <= 64'd0;
                                state     <= S_CLRREQ;
                            end else begin
                                delay_cnt <= 0;
                                state     <= S_WAIT;
                            end
                        end
                    end

                    S_COORDREQ: begin
                        if (!req_busy) begin
                            start_q  <= 1'b1;
                            req_busy <= 1'b1;
                        end else if (i2c_done) begin
                            req_busy <= 1'b0;
                            if (i2c_ack_err) begin
                                ack_cnt <= ack_cnt + 8'd1;
                                status  <= ST_IOERR;
                                state   <= S_CLRREQ;
                            end else begin
                                state <= S_COORDDONE;
                            end
                        end
                    end

                    S_COORDDONE: begin
                        x_q  <= raw_x;
                        y_q  <= raw_y;
                        seq_q <= seq_q + 5'd1;
                        event_q <= event_q + 32'd1;
                        if (!pressed_q) tap_q <= 1'b1;
                        pressed_q <= 1'b1;
                        cur_dev   <= addr_sel ? ADDR_B : ADDR_A;
                        cur_reg   <= 16'h814E;
                        cur_write <= 1'b1;
                        cur_len   <= 4'd1;
                        cur_wdata <= 64'd0;
                        state     <= S_CLRREQ;
                    end

                    S_CLRREQ: begin
                        if (!req_busy) begin
                            start_q  <= 1'b1;
                            req_busy <= 1'b1;
                        end else if (i2c_done) begin
                            req_busy <= 1'b0;
                            if (i2c_ack_err) ack_cnt <= ack_cnt + 8'd1;
                            delay_cnt <= 0;
                            state <= S_WAIT;
                        end
                    end

                    default: state <= S_BOOT;
                endcase
            end
        end
    end

    assign x_o = x_q;
    assign y_o = y_q;
    assign id_o = id_q;
    assign pressed_o = pressed_q;
    assign seq_o = seq_q;
    assign count_o = count_q;
    assign status_o = status[2:0];
    assign event_cnt_o = event_q;
    assign tap_latch_o = tap_q;
    assign ack_err_cnt_o = ack_cnt;
    assign last_reg_o = last_reg_q;
endmodule