`timescale 1ns/1ps
module tb_soc_perf;
    logic clk = 0, rst_n = 0;
    wire halted, trap, tx;
    wire [7:0] gpio;
    reg [63:0] expected_cycles = 0, expected_retired = 0;
    reg [31:0] cycle_lo, cycle_hi, retire_lo, retire_hi;
    integer commits = 0, writes = 0, waits = 0;
    rv32i_soc #(.CLOCK_HZ(1_000_000), .IMEM_WORDS(64),
        .DMEM_WORDS(64), .MEM_FILE("")) dut (
        .clk_i(clk), .rst_n_i(rst_n), .uart_tx_o(tx),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );
    always #5 clk = ~clk;
    function automatic [31:0] load(input integer n, f3, dest);
        load = {n[11:0], 5'd1, f3[2:0], dest[4:0], 7'h03};
    endfunction
    function automatic [31:0] store(input integer n);
        store = {n[11:5], 5'd0, 5'd1, 3'd2, n[4:0], 7'h23};
    endfunction
    always @(posedge clk) begin
        if (!rst_n) begin
            expected_cycles = 0;
            expected_retired = 0;
            commits = 0; writes = 0; waits = 0;
        end else begin
            if (dut.dmem_valid && !dut.dmem_ready) waits = waits + 1;
            if (dut.dmem_valid && dut.dmem_ready && dut.perf_selected) begin
                if (dut.dmem_write) writes = writes + 1;
                else case (dut.dmem_addr)
                    'h10000010: cycle_lo = expected_cycles[31:0];
                    'h10000014: cycle_hi = expected_cycles[63:32];
                    'h10000018: retire_lo = expected_retired[31:0];
                    'h1000001c: retire_hi = expected_retired[63:32];
                endcase
            end
            expected_cycles = expected_cycles + 1;
            if (dut.commit_valid) begin
                expected_retired = expected_retired + 1;
                commits = commits + 1;
            end
        end
        #1;
        if (dut.cycle_count_q !== expected_cycles || dut.instret_count_q !== expected_retired)
            $fatal(1, "Counter mismatch clock=%h/%h retired=%h/%h",
                dut.cycle_count_q, expected_cycles, dut.instret_count_q, expected_retired);
    end
    initial begin
        #100000; $fatal(1, "Performance MMIO timeout");
    end
    initial begin
        #1;
        dut.u_imem.mem[0] = 'h100000b7;
        dut.u_imem.mem[1] = load('h20, 2, 2);
        dut.u_imem.mem[2] = load('h14, 2, 3);
        dut.u_imem.mem[3] = load('h10, 2, 4);
        dut.u_imem.mem[4] = load('h18, 2, 5);
        dut.u_imem.mem[5] = load('h1c, 2, 6);
        dut.u_imem.mem[6] = store('h10);
        dut.u_imem.mem[7] = store('h14);
        dut.u_imem.mem[8] = store('h18);
        dut.u_imem.mem[9] = store('h1c);
        dut.u_imem.mem[10] = store('h20);
        dut.u_imem.mem[11] = 'h05a00393; // ADDI x7,x0,90
        dut.u_imem.mem[12] = 'h00702023; // SW x7,0(x0)
        dut.u_imem.mem[13] = 'h00002403; // LW x8,0(x0)
        dut.u_imem.mem[14] = 'h0080006f; // JAL over wrong-path GPIO write
        dut.u_imem.mem[15] = 'h0070a023;
        dut.u_imem.mem[16] = load('h21, 4, 10); // LBU frequency byte
        dut.u_imem.mem[17] = load('h22, 5, 11); // LHU frequency upper half
        dut.u_imem.mem[18] = load('h24, 2, 12); // Unmapped: zero
        dut.u_imem.mem[19] = 'h00100073;
        for (integer run_no = 0; run_no < 2; run_no = run_no + 1) begin
            rst_n = 0;
            repeat (3) @(negedge clk);
            // Boundary injection exercises real 64-bit carry without waiting
            // billions of clocks. Second run verifies actual reset to zero.
            if (run_no == 0) begin
                dut.cycle_count_q = 64'h00000007fffffff0;
                dut.instret_count_q = 64'h00000000fffffff8;
                expected_cycles = 64'h00000007fffffff0;
                expected_retired = 64'h00000000fffffff8;
            end
            rst_n = 1;
            wait(halted);
            repeat (5) @(negedge clk);
            if (trap || gpio !== 0 || commits != 18 || writes != 5 || waits == 0)
                $fatal(1, "Retirement/writes/waits/flush mismatch commits=%0d writes=%0d waits=%0d", commits, writes, waits);
            if (dut.u_core.u_regfile.regs[2] !== 1_000_000 ||
                dut.u_core.u_regfile.regs[3] !== cycle_hi ||
                dut.u_core.u_regfile.regs[4] !== cycle_lo ||
                dut.u_core.u_regfile.regs[5] !== retire_lo ||
                dut.u_core.u_regfile.regs[6] !== retire_hi ||
                dut.u_core.u_regfile.regs[8] !== 90 ||
                dut.u_core.u_regfile.regs[10] !== 'h42 ||
                dut.u_core.u_regfile.regs[11] !== 'hf ||
                dut.u_core.u_regfile.regs[12] !== 0)
                $fatal(1, "MMIO read/byte/halfword/bounds result mismatch");
            if (run_no == 0 && (dut.cycle_count_q[63:32] !== 8 || dut.instret_count_q[63:32] !== 1))
                $fatal(1, "64-bit rollover not exercised");
        end
        $display("[PASS] soc_perf clock_retirement rollover read_only subwords waits flush halt reset");
        $finish;
    end
endmodule
