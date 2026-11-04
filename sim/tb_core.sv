`timescale 1ns/1ps

module tb_core #(parameter integer WAIT_CYCLES = 0);
    logic clk;
    logic rst_n;

    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;
    logic        dmem_valid;
    logic        dmem_write;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_wdata;
    logic [3:0]  dmem_wstrb;
    logic [31:0] dmem_rdata;
    logic        dmem_ready;
    logic        commit_valid;
    logic [31:0] commit_pc;
    logic [31:0] commit_instr;
    logic        commit_rd_write;
    logic [4:0]  commit_rd;
    logic [31:0] commit_data;
    logic        halted;
    logic        trap;

    logic [31:0] imem [0:63];
    logic [31:0] dmem [0:63];
    integer index;
    integer cycles;
    integer commits;
    integer wait_count = 0;
    logic stalled = 0;
    logic [31:0] held_addr, held_data;
    logic [3:0] held_strobes;
    logic held_write;

    rv32i_core_3stage #(.ASYNC_IMEM(1'b1)) dut (
        .clk_i             (clk),
        .rst_n_i           (rst_n),
        .imem_addr_o       (imem_addr),
        .imem_valid_o      (),
        .imem_ready_i      (1'b1),
        .imem_rvalid_i     (1'b1),
        .imem_rdata_i      (imem_rdata),
        .dmem_valid_o      (dmem_valid),
        .dmem_write_o      (dmem_write),
        .dmem_addr_o       (dmem_addr),
        .dmem_wdata_o      (dmem_wdata),
        .dmem_wstrb_o      (dmem_wstrb),
        .dmem_rdata_i      (dmem_rdata),
        .dmem_ready_i      (dmem_ready),
        .commit_valid_o    (commit_valid),
        .commit_pc_o       (commit_pc),
        .commit_instr_o    (commit_instr),
        .commit_rd_write_o (commit_rd_write),
        .commit_rd_o       (commit_rd),
        .commit_data_o     (commit_data),
        .halted_o          (halted),
        .trap_o            (trap)
    );

    always #5 clk = ~clk;

    always_comb begin
        imem_rdata = imem[imem_addr[7:2]];
        dmem_rdata = dmem[dmem_addr[7:2]];
        dmem_ready = (wait_count >= WAIT_CYCLES);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wait_count <= 0;
            stalled <= 0;
        end else begin
            if (stalled && (!dmem_valid || dmem_addr !== held_addr ||
                dmem_wdata !== held_data || dmem_wstrb !== held_strobes || dmem_write !== held_write))
                $fatal(1, "Forwarded memory operands changed during wait");
            stalled <= dmem_valid && !dmem_ready;
            held_addr <= dmem_addr; held_data <= dmem_wdata;
            held_strobes <= dmem_wstrb; held_write <= dmem_write;
            if (dmem_valid && !dmem_ready) wait_count <= wait_count + 1;
            else wait_count <= 0;
        end
        if (dmem_valid && dmem_write && dmem_ready) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[7:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[7:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[7:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[7:2]][31:24] <= dmem_wdata[31:24];
        end
        if (commit_valid) commits <= commits + 1;
    end

    initial begin
        if (WAIT_CYCLES == 0) $dumpfile("build/tb_core.vcd");
        else $dumpfile("build/tb_core_wait.vcd");
        $dumpvars(0, tb_core);

        clk     = 1'b0;
        rst_n   = 1'b0;
        cycles  = 0;
        commits = 0;
        for (index = 0; index < 64; index = index + 1) begin
            imem[index] = 32'h0010_0073;
            dmem[index] = 32'b0;
        end

        // addi x1,x0,5; addi x2,x0,7; add x3,x1,x2
        // sw x3,0(x0); lw x4,0(x0); beq x4,x3,+8
        // addi x5,x0,1 (must be flushed); addi x5,x0,42; ebreak
        imem[0] = 32'h0050_0093;
        imem[1] = 32'h0070_0113;
        imem[2] = 32'h0020_81b3;
        imem[3] = 32'h0030_2023;
        imem[4] = 32'h0000_2203;
        imem[5] = 32'h0032_0463;
        imem[6] = 32'h0010_0293;
        imem[7] = 32'h02a0_0293;
        imem[8] = 32'h0010_0073;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while (!halted && cycles < 100) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;

        if (!halted) $fatal(1, "CPU timeout");
        if (trap) $fatal(1, "CPU stopped with a trap");
        if (dmem[0] !== 32'd12) $fatal(1, "Store/load failed: dmem[0]=%h", dmem[0]);
        if (dut.u_regfile.regs[3] !== 32'd12) $fatal(1, "x3 mismatch");
        if (dut.u_regfile.regs[4] !== 32'd12) $fatal(1, "x4 mismatch");
        if (dut.u_regfile.regs[5] !== 32'd42) $fatal(1, "Branch flush failed: x5=%h", dut.u_regfile.regs[5]);
        if (commits !== 7) $fatal(1, "Unexpected commit count: %0d", commits);

        if (WAIT_CYCLES == 0) $display("[PASS] rv32i_core_3stage cycles=%0d commits=%0d", cycles, commits);
        else $display("[PASS] rv32i_core_wait cycles=%0d commits=%0d wait_cycles=%0d", cycles, commits, WAIT_CYCLES);
        $finish;
    end
endmodule

