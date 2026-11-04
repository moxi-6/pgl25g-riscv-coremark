// Register-addressed I2C master for the GT9147 touch controller.
//
// One transaction is: START, device address + W, 16-nbit register address,
// optional N write bytes, optional repeated START + device address + R,
// optional M read bytes, STOP.  Bytes are packed little-endian into the
// wr_data_i/rd_data_o vectors.  SCL is produced by an integer half-period
// counter derived from the system clock, so no PLL or gated clock is needed;
// SDA is a separate output plus output-enable for an external tri-state buffer.
module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 100_000
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [6:0]  dev_addr_i,
    input  logic [15:0] reg_addr_i,
    input  logic        write_i,
    input  logic [3:0]  wr_len_i,
    input  logic [63:0] wr_data_i,
    input  logic [3:0]  rd_len_i,
    output logic [63:0] rd_data_o,
    output logic        busy_o,
    output logic        done_o,
    output logic        ack_err_o,
    output logic        scl_o,
    output logic        sda_o,
    output logic        sda_oe_o,
    input  logic        sda_i
);
    localparam integer HALF_RAW = CLK_HZ / (SCL_HZ * 2);
    localparam integer HALF = (HALF_RAW < 4) ? 4 : HALF_RAW;

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_START = 3'd1;
    localparam [2:0] S_TX    = 3'd2;
    localparam [2:0] S_REST  = 3'd3;
    localparam [2:0] S_RX    = 3'd4;
    localparam [2:0] S_STOP  = 3'd5;

    // Byte phases of the transaction.
    localparam [3:0] PH_ADDR_W = 4'd0;
    localparam [3:0] PH_REG_H  = 4'd1;
    localparam [3:0] PH_REG_L  = 4'd2;
    localparam [3:0] PH_DATA   = 4'd3;
    localparam [3:0] PH_ADDR_R = 4'd10;

    reg [2:0]  state;
    reg [15:0] cnt;
    reg [2:0]  sub;
    reg        ph;          // SCL level: 0 low, 1 high
    reg [3:0]  nbit;         // 0..7 data bits, 8 = ACK slot
    reg [3:0]  phase;
    reg [3:0]  wr_idx;
    reg [3:0]  rd_idx;
    reg [7:0]  shreg;
    reg [63:0] rd_buf;
    reg        last_rd;
    reg        ack_fail;
    reg [26:0] timeout;

    wire tick = (cnt == HALF - 1);

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= S_IDLE; cnt <= 0; sub <= 0; ph <= 1'b0; nbit <= 0;
            phase <= PH_ADDR_W; wr_idx <= 0; rd_idx <= 0; shreg <= 0;
            rd_buf <= 0; rd_data_o <= 0; busy_o <= 0; done_o <= 0;
            ack_err_o <= 0; ack_fail <= 0; last_rd <= 0; timeout <= 0;
            scl_o <= 1'b1; sda_o <= 1'b1; sda_oe_o <= 1'b0;
        end else begin
            done_o <= 1'b0;

            if (state != S_IDLE) begin
                if (tick) cnt <= 0; else cnt <= cnt + 16'd1;
                if (timeout == 27'd99_999_999) begin
                    state <= S_IDLE; busy_o <= 1'b0; done_o <= 1'b1;
                    ack_err_o <= 1'b1; scl_o <= 1'b1; sda_oe_o <= 1'b0;
                    sda_o <= 1'b1; timeout <= 0;
                end else begin
                    timeout <= timeout + 27'd1;
                end
            end else begin
                timeout <= 0;
            end

            case (state)
                S_IDLE: begin
                    if (start_i) begin
                        busy_o    <= 1'b1;
                        done_o    <= 1'b0;
                        ack_err_o <= 1'b0;
                        ack_fail  <= 1'b0;
                        rd_buf    <= 64'd0;
                        rd_data_o <= 64'd0;
                        wr_idx    <= 0;
                        rd_idx    <= 0;
                        nbit       <= 0;
                        sub       <= 0;
                        ph        <= 1'b0;
                        timeout   <= 0;
                        scl_o     <= 1'b1;
                        sda_o     <= 1'b1;
                        sda_oe_o  <= 1'b1;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    if (tick) begin
                        case (sub)
                            3'd0: begin sda_o <= 1'b0; sub <= 3'd1; end   // START
                            3'd1: begin scl_o <= 1'b0; sub <= 3'd2; end
                            default: begin
                                shreg    <= {dev_addr_i, 1'b0};
                                sda_o    <= dev_addr_i[6];
                                sda_oe_o <= 1'b1;
                                nbit      <= 0;
                                ph       <= 1'b0;
                                phase    <= PH_ADDR_W;
                                state    <= S_TX;
                            end
                        endcase
                    end
                end

                S_TX: begin
                    if (tick) begin
                        if (!ph) begin
                            ph <= 1'b1; scl_o <= 1'b1;
                        end else begin
                            ph <= 1'b0; scl_o <= 1'b0;
                            if (nbit != 4'd8) begin
                                if (nbit == 4'd7) begin
                                    sda_oe_o <= 1'b0; sda_o <= 1'b1;  // ACK slot
                                    nbit <= 4'd8;
                                end else begin
                                    shreg <= {shreg[6:0], 1'b0};
                                    sda_o <= shreg[6];
                                    nbit <= nbit + 4'd1;
                                end
                            end else begin
                                if (sda_i !== 1'b0) ack_fail <= 1'b1;
                                nbit <= 0;
                                case (phase)
                                    PH_ADDR_W: begin
                                        phase    <= PH_REG_H;
                                        shreg    <= reg_addr_i[15:8];
                                        sda_o    <= reg_addr_i[15];
                                        sda_oe_o <= 1'b1;
                                    end
                                    PH_REG_H: begin
                                        phase    <= PH_REG_L;
                                        shreg    <= reg_addr_i[7:0];
                                        sda_o    <= reg_addr_i[7];
                                        sda_oe_o <= 1'b1;
                                    end
                                    PH_REG_L: begin
                                        if (write_i) begin
                                            if (wr_len_i == 4'd0) begin
                                                state <= S_STOP; sub <= 0;
                                                scl_o <= 1'b0; sda_o <= 1'b0;
                                                sda_oe_o <= 1'b1;
                                            end else begin
                                                phase    <= PH_DATA;
                                                wr_idx   <= 0;
                                                shreg    <= wr_data_i[7:0];
                                                sda_o    <= wr_data_i[7];
                                                sda_oe_o <= 1'b1;
                                            end
                                        end else begin
                                            state <= S_REST; sub <= 0;
                                        end
                                    end
                                    PH_DATA: begin
                                        if (wr_idx == wr_len_i - 4'd1) begin
                                            state <= S_STOP; sub <= 0;
                                            scl_o <= 1'b0; sda_o <= 1'b0;
                                            sda_oe_o <= 1'b1;
                                        end else begin
                                            wr_idx   <= wr_idx + 4'd1;
                                            shreg    <= wr_data_i[(wr_idx + 4'd1) * 8 +: 8];
                                            sda_o    <= wr_data_i[(wr_idx + 4'd1) * 8 + 7];
                                            sda_oe_o <= 1'b1;
                                        end
                                    end
                                    PH_ADDR_R: begin
                                        sda_oe_o <= 1'b0; sda_o <= 1'b1;
                                        nbit      <= 0;
                                        ph       <= 1'b0;
                                        sub      <= 0;
                                        rd_idx   <= 0;
                                        last_rd  <= (rd_len_i == 4'd1);
                                        state    <= S_RX;
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end
                end

                S_REST: begin
                    if (tick) begin
                        case (sub)
                            3'd0: begin scl_o <= 1'b1; sub <= 3'd1; end
                            3'd1: begin sda_o <= 1'b0; sda_oe_o <= 1'b1; sub <= 3'd2; end  // repeated START
                            3'd2: begin scl_o <= 1'b0; sub <= 3'd3; end
                            default: begin
                                shreg    <= {dev_addr_i, 1'b1};
                                sda_o    <= dev_addr_i[6];
                                sda_oe_o <= 1'b1;
                                nbit      <= 0;
                                ph       <= 1'b0;
                                phase    <= PH_ADDR_R;
                                state    <= S_TX;
                            end
                        endcase
                    end
                end

                // The read phase samples in the middle of the SCL high phase,
                // one tick away from the falling edge, so the sample never
                // races the slave update that the falling edge triggers.
                S_RX: begin
                    if (tick) begin
                        case (sub)
                            3'd0: begin
                                scl_o <= 1'b1;
                                sub   <= 3'd1;
                            end
                            3'd1: begin
                                // Sample only inside a data bit: the ninth
                                // high phase is the acknowledge slot and its
                                // level is driven by this master.
                                if (nbit != 4'd8) shreg <= {shreg[6:0], sda_i};
                                sub   <= 3'd2;
                            end
                            default: begin
                                scl_o <= 1'b0;
                                sub   <= 3'd0;
                                if (nbit != 4'd8) begin
                                    if (nbit == 4'd7) begin
                                        // Byte received: ACK unless this is the last one.
                                        sda_oe_o <= last_rd ? 1'b0 : 1'b1;
                                        sda_o    <= last_rd;
                                        nbit      <= 4'd8;
                                    end else begin
                                        nbit <= nbit + 4'd1;
                                    end
                                end else begin
                                    sda_oe_o <= 1'b0; sda_o <= 1'b1;
                                    if (rd_idx < 4'd8)
                                        rd_buf[rd_idx * 8 +: 8] <= shreg;
                                    nbit <= 0;
                                    if (last_rd) begin
                                        rd_data_o <= rd_buf | ({56'd0, shreg} << (rd_idx * 8));
                                        state <= S_STOP; sub <= 0;
                                        scl_o <= 1'b0; sda_o <= 1'b0;
                                        sda_oe_o <= 1'b1;
                                    end else begin
                                        rd_idx <= rd_idx + 4'd1;
                                        shreg  <= 8'd0;
                                        if ((rd_idx + 4'd1) == (rd_len_i - 4'd1))
                                            last_rd <= 1'b1;
                                    end
                                end
                            end
                        endcase
                    end
                end

                S_STOP: begin
                    if (tick) begin
                        case (sub)
                            3'd0: begin sda_o <= 1'b0; sda_oe_o <= 1'b1; sub <= 3'd1; end
                            3'd1: begin scl_o <= 1'b1; sub <= 3'd2; end
                            3'd2: begin sda_o <= 1'b1; sub <= 3'd3; end
                            3'd3: begin sda_oe_o <= 1'b0; sub <= 3'd4; end
                            default: begin
                                done_o    <= 1'b1;
                                busy_o    <= 1'b0;
                                ack_err_o <= ack_fail;
                                state     <= S_IDLE;
                            end
                        endcase
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
