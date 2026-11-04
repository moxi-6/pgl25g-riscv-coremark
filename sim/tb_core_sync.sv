`timescale 1ns/1ps
module tb_core_sync;
    logic clk = 0, rst_n = 0;
    wire [31:0] ia, da, wd, cpc, ci, cd;
    wire iv, dv, dw, cv, crw, halted, trap;
    wire [3:0] strb;
    wire [4:0] crd;
    logic ir, irv = 0, dr = 0;
    logic [31:0] idata = 0, rd = 0;
    logic [31:0] program_mem [0:127];
    logic [31:0] data_mem [0:63];
    integer expected_pc [0:63];
    integer expected_count, commits, cycles, reads, writes;
    integer mode = 0, scenario = 0;
    integer itimer, dtimer;
    logic ipending = 0, dpending = 0;
    logic [31:0] saved_ia, saved_da, saved_wd;
    logic saved_dw;
    logic [3:0] saved_strb;
    logic i_stalled = 0, d_stalled = 0;
    logic [31:0] stalled_ia, stalled_da, stalled_wd;
    logic stalled_dw;
    logic [3:0] stalled_strb;
    integer request_stalls, data_stalls, discarded, buffered_waits;

    rv32i_core_3stage dut (
        .clk_i(clk), .rst_n_i(rst_n), .imem_addr_o(ia), .imem_valid_o(iv),
        .imem_ready_i(ir), .imem_rvalid_i(irv), .imem_rdata_i(idata),
        .dmem_valid_o(dv), .dmem_write_o(dw), .dmem_addr_o(da),
        .dmem_wdata_o(wd), .dmem_wstrb_o(strb), .dmem_rdata_i(rd), .dmem_ready_i(dr),
        .commit_valid_o(cv), .commit_pc_o(cpc), .commit_instr_o(ci),
        .commit_rd_write_o(crw), .commit_rd_o(crd), .commit_data_o(cd),
        .halted_o(halted), .trap_o(trap)
    );
    always #5 clk = ~clk;
    always_comb ir = rst_n && !ipending && ((mode != 2) || ((cycles % 7) == 6));

    function automatic [31:0] imm(input integer n, rs1, f3, dest, opcode);
        imm = {n[11:0], rs1[4:0], f3[2:0], dest[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] store(input integer n, rs2, rs1, f3);
        store = {n[11:5], rs2[4:0], rs1[4:0], f3[2:0], n[4:0], 7'h23};
    endfunction
    function automatic [31:0] branch(input integer n, rs2, rs1, f3);
        branch = {n[12], n[10:5], rs2[4:0], rs1[4:0], f3[2:0], n[4:1], n[11], 7'h63};
    endfunction
    function automatic [31:0] jump(input integer n, dest);
        jump = {n[20], n[10:1], n[11], n[19:12], dest[4:0], 7'h6f};
    endfunction

    // Programmable instruction acceptance delay and response latency.
    // Even while ready is low, valid/address must remain stable across a branch.
    always @(posedge clk) begin
        if (!rst_n) begin
            ipending <= 0; irv <= 0; itimer <= 0;
            dpending <= 0; dr <= 0; dtimer <= 0;
            cycles = 0; commits = 0; reads = 0; writes = 0;
            request_stalls = 0; data_stalls = 0; discarded = 0; buffered_waits = 0;
            i_stalled = 0; d_stalled = 0;
        end else begin
            if (i_stalled && (!iv || ia !== stalled_ia)) $fatal(1, "Fetch request changed under backpressure");
            i_stalled = iv && !ir;
            stalled_ia = ia;
            if (i_stalled) request_stalls = request_stalls + 1;
            if (d_stalled && (!dv || da !== stalled_da || wd !== stalled_wd || dw !== stalled_dw || strb !== stalled_strb))
                $fatal(1, "Data request changed before completion");
            d_stalled = dv && !dr;
            stalled_da = da; stalled_wd = wd; stalled_dw = dw; stalled_strb = strb;
            if (d_stalled) data_stalls = data_stalls + 1;
            // A fast response can coincide with the redirect itself, before
            // discard_q is registered. Both paths intentionally drop it.
            if (dut.g_sync_fetch.pending_q && irv &&
                (dut.g_sync_fetch.discard_q || dut.redirect || dut.stop_ex || halted))
                discarded = discarded + 1;
            if (dut.ex_wait && dut.g_sync_fetch.buffered_q) buffered_waits = buffered_waits + 1;
            if (cv) begin
                if (commits >= expected_count || cpc !== expected_pc[commits])
                    $fatal(1, "Commit order mode=%0d scenario=%0d slot=%0d pc=%h expected=%h", mode, scenario, commits, cpc, expected_pc[commits]);
                if (ci !== program_mem[cpc[8:2]]) $fatal(1, "Commit instruction/PC mismatch");
                if (crw && crd == 0) $fatal(1, "x0 reported writable");
                commits = commits + 1;
            end
            cycles = cycles + 1;
            irv <= 0;
            if (iv && ir) begin
                if (mode == 0) begin
                    irv <= 1;
                    idata <= program_mem[ia[8:2]];
                end else begin
                    ipending <= 1; saved_ia <= ia;
                    itimer <= 2 + ((ia >> 2) % 5);
                end
            end
            if (ipending) begin
                if (itimer == 0) begin
                    irv <= 1; idata <= program_mem[saved_ia[8:2]]; ipending <= 0;
                end else itimer <= itimer - 1;
            end
            dr <= 0;
            if (dv && !dpending && !dr) begin
                dpending <= 1; saved_da <= da; saved_wd <= wd; saved_dw <= dw; saved_strb <= strb;
                dtimer <= 10 + mode*3;
            end
            if (dpending) begin
                if (dtimer == 0) begin
                    if (saved_da[31:2] >= 64) $fatal(1, "Unexpected MMIO/bad path request");
                    rd <= data_mem[saved_da[7:2]];
                    if (saved_dw) begin
                        writes = writes + 1;
                        for (integer b = 0; b < 4; b = b + 1)
                            if (saved_strb[b]) data_mem[saved_da[7:2]][8*b +: 8] <= saved_wd[8*b +: 8];
                    end else reads = reads + 1;
                    dr <= 1; dpending <= 0;
                end else dtimer <= dtimer - 1;
            end
        end
    end

    task automatic initialize_case;
        @(negedge clk); rst_n = 0;
        for (integer n = 0; n < 128; n = n + 1) program_mem[n] = 32'h00100073;
        for (integer n = 0; n < 64; n = n + 1) data_mem[n] = 32'hdeadbeef;
        expected_count = 0;
        repeat (3) @(negedge clk);
    endtask
    task automatic expect_pc(input integer address);
        expected_pc[expected_count] = address;
        expected_count = expected_count + 1;
    endtask
    task automatic run_case(input logic expect_trap);
        rst_n = 1;
        while (!halted && cycles < 4000) @(negedge clk);
        if (!halted || trap !== expect_trap) $fatal(1, "Stop mismatch scenario=%0d trap=%b", scenario, trap);
        // Drain an outstanding wrong-path fetch after halt, and detect repeats.
        repeat (30) @(negedge clk);
        if (commits != expected_count) $fatal(1, "Commit count got=%0d expected=%0d", commits, expected_count);
        if (iv || dv) $fatal(1, "Requests remained after halt drain");
    endtask
    initial begin
        #1000000; $fatal(1, "Sync CPU test timeout");
    end
    initial begin
        for (integer m = 0; m < 3; m = m + 1) begin
            initialize_case(); mode = m; scenario = 0;
            program_mem[0] = imm(128, 0, 0, 1, 'h13);
            program_mem[1] = imm(-128, 0, 0, 2, 'h13);
            program_mem[2] = store(0, 2, 1, 2);
            program_mem[3] = imm(0, 1, 0, 3, 3); // LB
            program_mem[4] = imm(0, 1, 4, 4, 3); // LBU
            program_mem[5] = imm(1, 4, 0, 5, 'h13);
            program_mem[6] = store(1, 5, 1, 0); // SB
            program_mem[7] = imm(0, 1, 1, 6, 3); // LH
            program_mem[8] = imm(0, 1, 5, 7, 3); // LHU
            program_mem[9] = {7'b0, 5'd7, 5'd6, 3'b0, 5'd8, 7'h33};
            program_mem[10] = store(2, 7, 1, 1); // SH
            program_mem[11] = imm(0, 1, 2, 9, 3); // LW
            program_mem[12] = imm(0, 0, 0, 10, 'h13);
            program_mem[13] = branch(12, 2, 3, 0);
            program_mem[14] = store(4, 2, 1, 2); // Wrong path: must never write
            program_mem[15] = 0; // Wrong path: must never trap
            program_mem[16] = branch(8, 2, 9, 1);
            program_mem[17] = 32'h00100073; // Wrong path: must never halt
            program_mem[18] = jump(12, 11);
            program_mem[19] = store(8, 9, 1, 2);
            program_mem[20] = 0;
            program_mem[21] = imm(4, 11, 0, 12, 'h13);
            program_mem[22] = imm(104, 0, 0, 13, 'h13);
            program_mem[23] = imm(0, 13, 0, 14, 'h67);
            program_mem[24] = store(12, 2, 1, 2);
            program_mem[25] = 0;
            program_mem[26] = imm(1, 10, 0, 10, 'h13);
            program_mem[27] = imm(3, 0, 0, 15, 'h13);
            program_mem[28] = imm(-1, 15, 0, 15, 'h13);
            program_mem[29] = branch(-4, 0, 15, 1);
            program_mem[30] = 32'h0000000f; // FENCE
            for (integer n = 0; n <= 13; n = n + 1) expect_pc(n*4);
            expect_pc(64); expect_pc(72); expect_pc(84); expect_pc(88); expect_pc(92); expect_pc(104); expect_pc(108);
            repeat (3) begin expect_pc(112); expect_pc(116); end
            expect_pc(120);
            run_case(0);
            if (reads != 5 || writes != 3) $fatal(1, "Memory transactions reads=%0d writes=%0d", reads, writes);
            if (data_mem[32] !== 32'h81808180 || data_mem[33] !== 32'hdeadbeef ||
                data_mem[34] !== 32'hdeadbeef || data_mem[35] !== 32'hdeadbeef) $fatal(1, "Memory/wrong-path side effect");
            if (dut.u_regfile.regs[3] !== 32'hffffff80 || dut.u_regfile.regs[4] !== 128 ||
                dut.u_regfile.regs[5] !== 129 || dut.u_regfile.regs[6] !== 32'hffff8180 ||
                dut.u_regfile.regs[7] !== 32'h8180 || dut.u_regfile.regs[8] !== 32'h300 ||
                dut.u_regfile.regs[9] !== 32'h81808180 || dut.u_regfile.regs[10] !== 1 ||
                dut.u_regfile.regs[11] !== 76 || dut.u_regfile.regs[12] !== 80 ||
                dut.u_regfile.regs[14] !== 96 || dut.u_regfile.regs[15] !== 0)
                $fatal(1, "Load extension/forwarding/jump result mismatch");
            if (discarded < 1 || buffered_waits < 1 || data_stalls < 1 || (mode == 2 && request_stalls < 1))
                $fatal(1, "Missing wait/flush coverage mode=%0d discarded=%0d buffered_waits=%0d data_stalls=%0d request_stalls=%0d", mode, discarded, buffered_waits, data_stalls, request_stalls);
            $display("sync mode=%0d commits=%0d reads=%0d writes=%0d discarded=%0d fetch_stalls=%0d buffered_waits=%0d", mode, commits, reads, writes, discarded, request_stalls, buffered_waits);
        end
        // Precise stop: no bus access from a misaligned load/store or jump.
        for (integer fault = 1; fault <= 4; fault = fault + 1) begin
            initialize_case(); scenario = fault; mode = 2;
            program_mem[0] = imm(1, 0, 0, 1, 'h13); expect_pc(0);
            case (fault)
                1: program_mem[1] = imm(0, 1, 2, 2, 3);
                2: program_mem[1] = store(0, 1, 1, 2);
                3: program_mem[1] = jump(2, 2);
                4: program_mem[1] = 0;
            endcase
            program_mem[2] = store(0, 1, 0, 2);
            run_case(1);
            if (reads || writes || dut.u_regfile.regs[2] !== 0) $fatal(1, "Fault instruction had side effects");
        end
        // Reset while a fetch response is outstanding, shared reset cancels it.
        initialize_case(); mode = 1; scenario = 5;
        program_mem[0] = imm(7, 0, 0, 2, 'h13); expect_pc(0);
        rst_n = 1;
        wait (ipending); @(negedge clk); rst_n = 0;
        repeat (3) @(negedge clk);
        program_mem[0] = imm(9, 0, 0, 2, 'h13);
        run_case(0);
        if (dut.u_regfile.regs[2] !== 9) $fatal(1, "Stale instruction survived reset");
        $display("[PASS] rv32i_core_sync latency_modes=3 precise_faults=4 reset_pending_fetch commit_scoreboard");
        $finish;
    end
endmodule
