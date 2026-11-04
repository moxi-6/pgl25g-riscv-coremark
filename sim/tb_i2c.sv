// Isolated bus-level check: i2c_master against the GT9147 model.
`timescale 1ns/1ps

module tb_i2c;

    localparam int CLK_HZ = 1_000_000;
    localparam int SCL_HZ = 100_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #500 clk = ~clk;

    tri1  sda;
    wire  scl;
    wire  sda_o;
    wire  sda_oe;
    assign sda = sda_oe ? sda_o : 1'bz;

    logic       start;
    logic [6:0] dev;
    logic [15:0] regaddr;
    logic       wr;
    logic [3:0] wlen;
    logic [63:0] wdata;
    logic [3:0] rlen;
    wire  [63:0] rdata;
    wire        busy, done, ackerr;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .start_i(start),
        .dev_addr_i(dev), .reg_addr_i(regaddr), .write_i(wr),
        .wr_len_i(wlen), .wr_data_i(wdata), .rd_len_i(rlen),
        .rd_data_o(rdata), .busy_o(busy), .done_o(done), .ack_err_o(ackerr),
        .scl_o(scl), .sda_o(sda_o), .sda_oe_o(sda_oe), .sda_i(sda)
    );

    gt9147_model u_model (.scl_i(scl), .sda(sda), .rst_n_i(rst_n));

    task automatic xfer(input [6:0] d, input [15:0] ra, input w,
                        input [3:0] wl, input [63:0] wd, input [3:0] rl,
                        output [63:0] out);
        dev = d; regaddr = ra; wr = w; wlen = wl; wdata = wd; rlen = rl;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        wait (done == 1'b1);
        @(posedge clk);
        out = rdata;
        repeat (20) @(posedge clk);
    endtask

    logic [63:0] got;

    initial begin
        start = 0; dev = 7'h14; regaddr = 0; wr = 0; wlen = 0; wdata = 0; rlen = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        xfer(7'h14, 16'h8140, 1'b0, 4'd0, 64'd0, 4'd4, got);
        $display("ID  read = 0x%016x  (ackerr=%b)", got, ackerr);

        xfer(7'h14, 16'h814E, 1'b0, 4'd0, 64'd0, 4'd1, got);
        $display("0x814E   = 0x%02x", got[7:0]);

        u_model.inject_touch(16'd400, 16'd240);

        xfer(7'h14, 16'h814E, 1'b0, 4'd0, 64'd0, 4'd1, got);
        $display("0x814E   = 0x%02x (after touch)", got[7:0]);

        xfer(7'h14, 16'h8150, 1'b0, 4'd0, 64'd0, 4'd8, got);
        $display("0x8150   = 0x%016x", got);

        xfer(7'h14, 16'h81CE, 1'b1, 4'd1, 64'd0, 4'd0, got);
        $display("write 0x814E=0: reg now 0x%02x", u_model.regs[11'h14E]);

        $finish;
    end

    initial begin
        #5_000_000;   // 5 ms in simulated time
        $display("TIMEOUT");
        $finish;
    end
endmodule