`timescale 1ns/1ps
module tb_sync_memory;
    logic clk = 0, rst_n = 0;
    logic iv = 0, ir, irv;
    logic [31:0] ia = 0, idata;
    logic rom_dv = 0, rom_dr;
    logic [31:0] rom_da = 0, rom_rd;
    logic dv = 0, dw = 0, dr;
    logic [31:0] da = 0, wd = 0, rd;
    logic [3:0] strb = 0;
    integer writes = 0;
    sync_imem #(.WORDS(5), .INIT_FILE("")) rom (
        .clk_i(clk), .rst_n_i(rst_n), .valid_i(iv), .addr_i(ia),
        .ready_o(ir), .rvalid_o(irv), .rdata_o(idata),
        .data_valid_i(rom_dv), .data_addr_i(rom_da), .data_ready_o(rom_dr), .data_rdata_o(rom_rd)
    );
    sync_dmem #(.WORDS(5)) ram (
        .clk_i(clk), .rst_n_i(rst_n), .valid_i(dv), .write_i(dw),
        .addr_i(da), .wdata_i(wd), .wstrb_i(strb), .rdata_o(rd), .ready_o(dr)
    );
    always #5 clk = ~clk;
    always @(posedge clk) if (ram.access_en && dw && da[31:2] < 5) writes = writes + 1;
    task automatic transfer(input logic wr, input logic [31:0] address, data,
                            input logic [3:0] lanes, input logic [31:0] expected);
        @(negedge clk); dv = 1; dw = wr; da = address; wd = data; strb = lanes;
        if (dr !== 0) $fatal(1, "RAM must wait before registered completion");
        @(posedge clk); #1;
        if (dr !== 1) $fatal(1, "RAM missing completion");
        if (!wr && rd !== expected) $fatal(1, "RAM read addr=%h got=%h expected=%h", address, rd, expected);
        @(posedge clk); #1;
        if (dr !== 0) $fatal(1, "RAM repeated completion");
        @(negedge clk); dv = 0;
    endtask
    task automatic fetch(input logic [31:0] address, expected);
        @(negedge clk); iv = 1; ia = address;
        @(posedge clk); #1;
        if (!irv || idata !== expected) $fatal(1, "ROM addr=%h got=%h expected=%h", address, idata, expected);
        @(negedge clk); iv = 0;
        @(posedge clk); #1;
        if (irv) $fatal(1, "ROM duplicated response");
    endtask
    initial begin
        #10000; $fatal(1, "Memory test timeout");
    end
    initial begin
        #1;
        rom.mem[0] = 32'h11223344;
        rom.mem[4] = 32'haabbccdd;
        repeat (3) @(negedge clk);
        rst_n = 1;
        fetch(0, 32'h11223344);
        fetch(16, 32'haabbccdd);
        fetch(20, 0); // Non-power-of-two upper boundary
        fetch(32'h100, 0); // High address bits must not alias
        fetch(1, 0); // Misaligned fetch
        // Consecutive requests and registered-data hold before the next edge.
        @(negedge clk); iv = 1; ia = 0;
        @(posedge clk); #1;
        if (idata !== 32'h11223344) $fatal(1, "ROM first pipelined read");
        @(negedge clk); ia = 16; #1;
        if (idata !== 32'h11223344) $fatal(1, "ROM unexpectedly combinational");
        @(posedge clk); #1;
        if (idata !== 32'haabbccdd || !irv) $fatal(1, "ROM back-to-back read");
        @(negedge clk); iv = 0;
        // Independent fetch/data ports read different words on the same edge.
        @(negedge clk); iv = 1; ia = 0; rom_dv = 1; rom_da = 16;
        @(posedge clk); #1;
        if (!irv || !rom_dr || idata !== 32'h11223344 || rom_rd !== 32'haabbccdd)
            $fatal(1, "ROM dual-port read mismatch");
        @(posedge clk); #1;
        if (rom_dr) $fatal(1, "ROM data port repeated completion");
        @(negedge clk); iv = 0; rom_dv = 0;
        @(negedge clk); rom_dv = 1; rom_da = 20;
        @(posedge clk); #1;
        if (!rom_dr || rom_rd !== 0) $fatal(1, "ROM data port bounds alias");
        @(posedge clk);
        @(negedge clk); rom_dv = 0;
        transfer(1, 0, 32'h12345678, 4'b1111, 0);
        transfer(1, 0, 32'hab000000, 4'b1000, 0);
        transfer(1, 0, 32'h00cd0000, 4'b0100, 0);
        transfer(1, 0, 32'h0000ef00, 4'b0010, 0);
        transfer(1, 0, 32'h00000090, 4'b0001, 0);
        transfer(0, 0, 0, 0, 32'habcdef90);
        transfer(1, 0, 32'hffffffff, 4'b0000, 0);
        transfer(0, 0, 0, 0, 32'habcdef90);
        transfer(1, 16, 32'h87654321, 4'b1111, 0);
        transfer(0, 16, 0, 0, 32'h87654321);
        transfer(1, 20, 32'hffffffff, 4'b1111, 0);
        transfer(1, 32'h100, 32'hffffffff, 4'b1111, 0);
        transfer(0, 20, 0, 0, 0);
        transfer(0, 0, 0, 0, 32'habcdef90);
        if (writes != 7) $fatal(1, "RAM requests repeated: %0d", writes);
        // Reset cancels response metadata, but does not erase RAM.
        @(negedge clk); dv = 1; dw = 0; da = 0; iv = 1; ia = 0;
        @(posedge clk); #1;
        if (!dr || !irv) $fatal(1, "Missing responses before reset");
        #1 rst_n = 0; #1;
        if (dr !== 0 || irv !== 0) $fatal(1, "Reset left stale responses");
        dv = 0; iv = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;
        @(posedge clk); #1;
        if (dr || irv) $fatal(1, "Ghost response after reset");
        transfer(0, 0, 0, 0, 32'habcdef90);
        $display("[PASS] sync_memory registered_reads byte_lanes bounds reset single_completion");
        $finish;
    end
endmodule
