// Minimal bus-scope for one read transaction: prints the resolved SDA level
// and both ends' state on every SCL edge so protocol slips are visible.
`timescale 1ns/1ps
module dbg_i2c;
    localparam int CLK_HZ = 1_000_000;
    localparam int SCL_HZ = 100_000;

    logic clk = 1'b0, rst_n = 1'b0;
    always #500 clk = ~clk;

    logic scl, dut_oe, dut_o, m_oe, m_o;
    wire  sda = ((dut_oe && !dut_o) || (m_oe && !m_o)) ? 1'b0 : 1'b1;

    logic start = 0, wr = 0;
    logic [6:0] dev = 7'h14;
    logic [15:0] regaddr = 16'h8140;
    logic [3:0] wlen = 0, rlen = 4'd4;
    logic [63:0] wdata = 0, rdata;
    logic busy, done, ackerr;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .start_i(start),
        .dev_addr_i(dev), .reg_addr_i(regaddr),
        .write_i(wr), .wr_len_i(wlen), .wr_data_i(wdata),
        .rd_len_i(rlen), .rd_data_o(rdata),
        .busy_o(busy), .done_o(done), .ack_err_o(ackerr),
        .scl_o(scl), .sda_o(dut_o), .sda_oe_o(dut_oe), .sda_i(sda)
    );

    gt9147_model u_model (
        .scl_i(scl), .sda_oe_o(m_oe), .sda_o_o(m_o), .sda_i(sda), .rst_n_i(rst_n)
    );

    int ev = 0;
    always @(posedge scl) begin
        if (ev < 120)
            $display("[%0t] SCL^ sda=%b  dut:st=%0d nbit=%0d ph=%0d oeb=%b | mdl:st=%0d rxcnt=%0d txcnt=%0d oeb=%b txsh=%02x rxsh=%02x",
                     $time, sda, dut.state, dut.nbit, dut.ph, dut_oe,
                     u_model.st, u_model.rxcnt, u_model.txcnt, m_oe, u_model.txsh, u_model.rxsh);
        ev++;
    end

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        begin : run
            int g = 0;
            while (!done && g < 200000) begin @(posedge clk); g++; end
        end
        $display("RESULT rdata=0x%016x ackerr=%b", rdata, ackerr);
        $finish;
    end
endmodule