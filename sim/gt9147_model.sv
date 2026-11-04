// Behavioural GT9147 touch controller model for simulation.
//
// Implements the subset of the I2C protocol the driver uses: device address
// match (0x14 or 0x5D), 16-bit register addressing, single/multi byte writes,
// register-auto-increment reads, and the registers that matter:
//
//   0x8140  product ID ("9147")
//   0x814E  buffer status (bit7 ready, bits3:0 contact count)
//   0x8150  first touch point (track id, x low/high, y low/high, 3 spare)
//
// The bus is open drain: the model only pulls SDA low, so it exports a
// drive-low flag and an output level that the testbench ORs together with the
// master's contribution.  Every byte is clocked MSB first with the ninth SCL
// high reserved for the acknowledge slot, exactly like the real part.
`timescale 1ns/1ps

module gt9147_model (
    input  logic scl_i,
    output logic sda_oe_o,      // 1: model drives SDA
    output logic sda_o_o,       // level driven when sda_oe_o is 1
    input  logic sda_i,         // resolved bus level
    input  logic rst_n_i
);
    localparam [6:0] ADDR_A = 7'h14;
    localparam [6:0] ADDR_B = 7'h5D;

    localparam [10:0] IDX_ID     = 11'h140;
    localparam [10:0] IDX_STATUS = 11'h14E;
    localparam [10:0] IDX_PT1    = 11'h150;

    reg [7:0] regs [0:2047];

    localparam [2:0] ST_IDLE = 3'd0, ST_ADDR = 3'd1, ST_REGH = 3'd2,
                     ST_REGL = 3'd3, ST_WR = 3'd4, ST_RD = 3'd5;

    reg [2:0]  st;

    // Receive side: rxcnt SCL highs in the current byte, rxskip swallows the
    // acknowledge slot, rxdone marks a complete byte waiting for its ACK.
    reg [3:0]  rxcnt;
    reg [7:0]  rxsh;
    reg        rxdone;
    reg        rxskip;

    // Transmit side: txcnt data bits already driven, txack marks the slot the
    // host uses to acknowledge, txload asks for the next register byte.
    reg [3:0]  txcnt;
    reg [7:0]  txsh;
    reg        txack;
    reg        txload;

    reg [15:0] regptr;
    reg        release_hold;    // stay in the "ready, no contact" state

    integer i;
    initial begin
        for (i = 0; i < 2048; i = i + 1) regs[i] = 8'h00;
        regs[IDX_ID + 0] = 8'h39;   // '9'
        regs[IDX_ID + 1] = 8'h31;   // '1'
        regs[IDX_ID + 2] = 8'h34;   // '4'
        regs[IDX_ID + 3] = 8'h37;   // '7'
        st = ST_IDLE;
        rxcnt = 0; rxsh = 0; rxdone = 0; rxskip = 0;
        txcnt = 0; txsh = 0; txack = 0; txload = 0;
        regptr = 0;
        release_hold = 1'b0;
        sda_oe_o = 1'b0;
        sda_o_o  = 1'b1;
    end

    task automatic inject_touch(input [15:0] x, input [15:0] y);
        release_hold = 1'b0;
        regs[IDX_PT1 + 0] = 8'h01;
        regs[IDX_PT1 + 1] = x[7:0];
        regs[IDX_PT1 + 2] = x[15:8];
        regs[IDX_PT1 + 3] = y[7:0];
        regs[IDX_PT1 + 4] = y[15:8];
        regs[IDX_STATUS]  = 8'h81;   // ready, one contact
    endtask

    task automatic inject_release;
        release_hold     = 1'b1;
        regs[IDX_STATUS] = 8'h80;    // ready, zero contacts
    endtask

    // START, including a repeated START: SDA falls while SCL is high and the
    // model itself is not the one driving SDA.
    always @(negedge sda_i) begin
        if (rst_n_i && scl_i === 1'b1 && !sda_oe_o) begin
            st       <= ST_ADDR;
            rxcnt    <= 4'd0; rxdone <= 1'b0; rxskip <= 1'b0;
            txcnt    <= 4'd0; txack  <= 1'b0; txload <= 1'b0;
            sda_oe_o <= 1'b0;
        end
    end

    // STOP: SDA rises while SCL is high.
    always @(posedge sda_i) begin
        if (rst_n_i && scl_i === 1'b1 && !sda_oe_o) begin
            st       <= ST_IDLE;
            rxcnt    <= 4'd0; rxdone <= 1'b0; rxskip <= 1'b0;
            txcnt    <= 4'd0; txack  <= 1'b0; txload <= 1'b0;
            sda_oe_o <= 1'b0;
        end
    end

    // SCL rising edge.
    always @(posedge scl_i) begin
        if (rst_n_i) begin
            if (st != ST_IDLE && st != ST_RD) begin
                if (rxskip) begin
                    rxskip <= 1'b0;                 // this is the ACK slot
                end else if (rxcnt < 4'd8) begin
                    rxsh  <= {rxsh[6:0], sda_i};
                    rxcnt <= rxcnt + 4'd1;
                    if (rxcnt == 4'd7) rxdone <= 1'b1;
                end
            end
            if (st == ST_RD && txack) begin
                txack    <= 1'b0;
                sda_oe_o <= 1'b0;
                if (sda_i === 1'b0) begin
                    regptr <= regptr + 16'd1;       // host acknowledged, next byte
                    txload <= 1'b1;
                end else begin
                    txload <= 1'b0;                 // NACK: stop after this byte
                end
            end
        end
    end

    // SCL falling edge: acknowledge received bytes and drive outgoing bits.
    always @(negedge scl_i) begin
        if (rst_n_i && st != ST_IDLE) begin
            if (rxdone) begin
                rxdone <= 1'b0;
                rxskip <= 1'b1;
                rxcnt  <= 4'd0;
                case (st)
                    ST_ADDR: begin
                        if (rxsh[7:1] == ADDR_A || rxsh[7:1] == ADDR_B) begin
                            sda_oe_o <= 1'b1;
                            sda_o_o  <= 1'b0;       // ACK
                            if (rxsh[0]) begin
                                st    <= ST_RD;
                                txsh  <= regs[regptr[10:0]];
                                txcnt <= 4'd0;
                            end else begin
                                regptr <= 16'd0;
                                st     <= ST_REGH;
                            end
                        end else begin
                            st       <= ST_IDLE;
                            sda_oe_o <= 1'b0;
                        end
                    end
                    ST_REGH: begin
                        regptr[15:8] <= rxsh;
                        sda_oe_o <= 1'b1; sda_o_o <= 1'b0;
                        st <= ST_REGL;
                    end
                    ST_REGL: begin
                        regptr[7:0] <= rxsh;
                        sda_oe_o <= 1'b1; sda_o_o <= 1'b0;
                        st <= ST_WR;
                    end
                    ST_WR: begin
                        // Clearing the status register re-arms the next scan
                        // frame, so a held release keeps reporting ready/zero.
                        if (regptr[10:0] == IDX_STATUS && release_hold && rxsh == 8'h00)
                            regs[IDX_STATUS] <= 8'h80;
                        else
                            regs[regptr[10:0]] <= rxsh;
                        regptr <= regptr + 16'd1;
                        sda_oe_o <= 1'b1; sda_o_o <= 1'b0;
                    end
                    default: ;
                endcase
            end else if (st == ST_RD) begin
                if (txload) begin
                    txsh     <= {regs[regptr[10:0]][6:0], 1'b1};
                    sda_o_o  <= regs[regptr[10:0]][7];
                    sda_oe_o <= 1'b1;
                    txcnt    <= 4'd1;
                    txload   <= 1'b0;
                end else if (txack) begin
                    sda_oe_o <= 1'b0;               // stay released for the ACK slot
                end else if (txcnt < 4'd8) begin
                    sda_o_o  <= txsh[7];
                    txsh     <= {txsh[6:0], 1'b1};
                    sda_oe_o <= 1'b1;
                    txcnt    <= txcnt + 4'd1;
                end else begin
                    sda_oe_o <= 1'b0;               // hand the bus to the host
                    txack    <= 1'b1;
                end
            end else if (sda_oe_o) begin
                sda_oe_o <= 1'b0;                   // release SDA after an ACK
            end
        end
    end
endmodule