`timescale 1ns/1ps
// Independent value/handshake model for the banked fetch ROM. The companion
// runner creates a partial initialization file with a distinct value per word.
module tb_imem_pair;
    parameter integer WORDS = 16384;
    parameter INIT_FILE = "build/imem_pair/input.hex";
    localparam integer INIT_WORDS = WORDS > 4 ? WORDS - 3 : WORDS - 1;
    logic clk = 0, rst_n = 0, valid = 0, data_valid = 0;
    logic [31:0] addr = 0, data_addr = 0;
    wire ready, rvalid, data_ready;
    wire [31:0] rdata, next_data, data_rdata;
    integer checks = 0, fetches = 0, data_reads = 0, k;
    logic previous_data_response = 0;
    logic expected_fetch, expected_data;
    logic expected_ready;
    logic [31:0] expected_first, expected_next, expected_rom;
    logic [31:0] random_q = 32'h6ab7c931;

    sync_imem #(.WORDS(WORDS), .FETCH_PAIR(1), .INIT_FILE(INIT_FILE),
        .INIT_EVEN_FILE({INIT_FILE,".even"}), .INIT_ODD_FILE({INIT_FILE,".odd"})) dut (
        .clk_i(clk), .rst_n_i(rst_n), .valid_i(valid), .addr_i(addr),
        .ready_o(ready), .rvalid_o(rvalid), .rdata_o(rdata),
        .rdata_next_o(next_data), .data_valid_i(data_valid),
        .data_addr_i(data_addr), .data_ready_o(data_ready), .data_rdata_o(data_rdata)
    );
    always #5 clk = ~clk;

    function automatic [31:0] word_at(input logic [31:0] index);
        if (index >= WORDS) word_at = 0;
        else if (index >= INIT_WORDS) word_at = 32'h00100073;
        else word_at = 32'h9e3779b9 ^ (index * 32'h01010203);
    endfunction

    task automatic cycle(input logic reset_value, fetch_valid, rom_valid,
                         input logic [31:0] fetch_addr, rom_addr);
        logic [31:0] held_first, held_next, held_rom;
        @(negedge clk);
        held_first = rdata;
        held_next = next_data;
        held_rom = data_rdata;
        rst_n = reset_value;
        valid = fetch_valid;
        data_valid = rom_valid;
        addr = fetch_addr;
        data_addr = rom_addr;
        #1;
        if (fetches > 0 && (rdata !== held_first || next_data !== held_next))
            $fatal(1, "instruction output changed before the capture edge");
        if (data_reads > 0 && data_rdata !== held_rom)
            $fatal(1, "ROM data output changed before the capture edge");
        if (!reset_value) begin
            previous_data_response = 0;
            if (rvalid !== 0 || data_ready !== 0)
                $fatal(1, "reset did not cancel outstanding responses");
        end
        expected_data = reset_value && rom_valid && !previous_data_response;
        expected_ready = reset_value && !expected_data;
        if (ready !== expected_ready) $fatal(1, "fetch grant disagrees with ROM data arbitration");
        expected_fetch = expected_ready && fetch_valid;
        expected_first = fetch_addr[1:0] == 0 ? word_at(fetch_addr >> 2) : 0;
        expected_next = fetch_addr[1:0] == 0 ? word_at((fetch_addr >> 2) + 1) : 0;
        // The ROM data port returns the containing word; the CPU/SoC handles
        // byte selection and load alignment independently.
        expected_rom = word_at(rom_addr >> 2);
        @(posedge clk); #1;
        if (rvalid !== expected_fetch || data_ready !== expected_data)
            $fatal(1, "response handshake mismatch cycle=%0d fetch=%b/%b data=%b/%b",
                   checks, rvalid, expected_fetch, data_ready, expected_data);
        if (expected_fetch) begin
            if (rdata !== expected_first || next_data !== expected_next)
                $fatal(1, "pair addr=%h first=%h/%h next=%h/%h", fetch_addr,
                       rdata, expected_first, next_data, expected_next);
            fetches = fetches + 1;
        end
        if (expected_data) begin
            if (data_rdata !== expected_rom)
                $fatal(1, "ROM data addr=%h got=%h expected=%h", rom_addr, data_rdata, expected_rom);
            data_reads = data_reads + 1;
        end
        previous_data_response = expected_data;
        checks = checks + 1;
    endtask

    initial begin
        #10000000; $fatal(1, "banked ROM timeout");
    end
    initial begin
        cycle(0, 1, 1, 0, 4);
        cycle(1, 0, 0, 0, 0);
        // Exhaustive fetch at both parities while ROM data requests contend.
        // Keep each unaccepted instruction address stable until its grant.
        k = 0;
        while (k < WORDS) begin
            cycle(1, 1, 1, k * 4, (WORDS - 1 - k) * 4);
            if (expected_fetch) k = k + 1;
        end
        // With no ROM data reads, pairs must be accepted on every clock.
        for (k = 0; k < WORDS; k = k + 1)
            cycle(1, 1, 0, k * 4, 0);
        // Request/response spacing allowing every ROM data word to be read.
        for (k = 0; k < WORDS; k = k + 1) begin
            cycle(1, 1, 1, ((k * 13) % WORDS) * 4, k * 4);
            cycle(1, 0, 0, 0, 0);
        end
        // Last-word successor must be zero, and high bits must never alias.
        cycle(1, 1, 0, (WORDS - 1) * 4, 0);
        cycle(1, 1, 0, WORDS * 4, 0);
        cycle(1, 1, 0, WORDS * 4 + 4, 0);
        cycle(1, 1, 0, 32'h80000000, 0);
        cycle(1, 1, 0, 32'hfffffffc, 0);
        for (k = 1; k < 4; k = k + 1) begin
            cycle(1, 1, 0, k, 0);
            cycle(1, 1, 0, (WORDS - 1) * 4 + k, 0);
        end
        cycle(1, 1, 1, 0, WORDS * 4);
        cycle(1, 1, 0, 0, 0);
        cycle(1, 1, 1, 0, 32'hfffffffc);
        cycle(1, 1, 0, 0, 0);
        for (k = 1; k < 4; k = k + 1) begin
            cycle(1, 1, 1, 0, k);
            cycle(1, 1, 0, 0, 0);
        end
        // Pseudorandom addresses, bubbles and simultaneous port operation.
        for (k = 0; k < 1024; k = k + 1) begin
            random_q = {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
            cycle(1, random_q[2], random_q[3],
                  ((random_q[19:4] % (WORDS + 4)) * 4) + (random_q[0] ? random_q[1:0] : 0),
                  (random_q[31:16] % (WORDS + 4)) * 4);
        end
        // Reset while requests are active cancels both completion channels.
        cycle(1, 1, 0, 0, 0);
        cycle(1, 1, 1, 4, 4);
        cycle(0, 1, 1, 8, 8);
        cycle(0, 0, 0, 0, 0);
        cycle(1, 0, 0, 0, 0);
        cycle(1, 1, 1, 0, 0);
        cycle(1, 0, 0, 0, 0);
        $display("[PASS] imem_pair WORDS=%0d cycles=%0d fetches=%0d data_reads=%0d", WORDS, checks, fetches, data_reads);
        $finish;
    end
endmodule
