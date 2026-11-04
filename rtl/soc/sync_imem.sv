// Request acceptance: valid_i && ready_o. Exactly one registered response
// pulse on the following cycle. Both requester and memory share reset.
module sync_imem #(
    parameter integer WORDS = 4096,
    parameter bit FETCH_PAIR = 1'b0,
    parameter INIT_FILE = "software/build/firmware.hex",
    parameter INIT_EVEN_FILE = "software/build/firmware.hex.even",
    parameter INIT_ODD_FILE = "software/build/firmware.hex.odd"
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic valid_i,
    input logic [31:0] addr_i,
    output logic ready_o,
    output logic rvalid_o,
    output logic [31:0] rdata_o,
    output logic [31:0] rdata_next_o,
    // Independent synchronous read port for startup copies from ROM.
    // Completion-style handshake, like sync_dmem; writes are decoded outside.
    input logic data_valid_i,
    input logic [31:0] data_addr_i,
    output logic data_ready_o,
    output logic [31:0] data_rdata_o
);
    localparam integer ADDR_W = (WORDS <= 1) ? 1 : $clog2(WORDS);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] even_mem [0:(WORDS+1)/2-1], odd_mem [0:(WORDS+1)/2-1];
    logic [31:0] data_q;
    logic in_range_q;
    logic data_response_q, data_in_range_q;
    logic [31:0] data_port_q;
    integer i;
    initial begin
        if (FETCH_PAIR) begin
            // Initialize each inferred RAM directly. PDS does not preserve a
            // $readmemh temporary array copied into another RAM in initial.
            // scripts/split_imem_banks.py produces these two companion files.
            for (i=0;i<(WORDS+1)/2;i=i+1) begin
                even_mem[i]=32'h00100073;
                odd_mem[i]=32'h00100073;
            end
            if (INIT_FILE != "") begin
                $readmemh(INIT_EVEN_FILE, even_mem);
                $readmemh(INIT_ODD_FILE, odd_mem);
            end
        end else begin
            // PDS limits a single elaboration loop to 10,000 iterations.
            for (i = 0; i < WORDS; i = i + 2) begin
                mem[i] = 32'h0010_0073;
                if (i + 1 < WORDS) mem[i + 1] = 32'h0010_0073;
            end
            if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
        end
    end
    // Out-of-range fetch is an illegal instruction, never an address alias.
    assign data_ready_o = data_response_q;
    generate if (!FETCH_PAIR) begin : g_scalar
    assign ready_o = rst_n_i;
    assign rdata_o = in_range_q ? data_q : 32'h0000_0000;
    assign rdata_next_o = 32'b0;
    assign data_rdata_o = data_in_range_q ? data_port_q : 32'b0;
    // Keep reset off the memory data register for block RAM inference.
    always_ff @(posedge clk_i) begin
        if (valid_i && ready_o) begin
            data_q <= mem[addr_i[ADDR_W+1:2]];
            in_range_q <= (addr_i[31:2] < WORDS) && (addr_i[1:0] == 0);
        end
    end
    always_ff @(posedge clk_i) begin
        if (rst_n_i && data_valid_i && !data_response_q) begin
            data_port_q <= mem[data_addr_i[ADDR_W+1:2]];
            data_in_range_q <= data_addr_i[31:2] < WORDS;
        end
    end
    end else begin : g_pair
        localparam integer BANK_W=(ADDR_W > 1) ? ADDR_W-1 : 1;
        logic [31:0] first_even_q, first_odd_q;
        logic parity_q, rom_parity_q, next_range_q;
        // A one-word bank has no address bits. Keep declarations/slices legal
        // for WORDS=1/2 and let the existing full-address guards reject misses.
        wire [BANK_W-1:0] bank_index=(WORDS <= 2) ? '0 : addr_i[BANK_W+2:3];
        wire [BANK_W-1:0] even_index=(WORDS <= 2) ? '0 : bank_index+addr_i[2];
        wire [BANK_W-1:0] data_bank_index=(WORDS <= 2) ? '0 : data_addr_i[BANK_W+2:3];
        // Share one physical synchronous read per bank. PDS duplicates a ROM
        // with two inferred reads, which would double the 64 KiB ROM footprint.
        // ROM data reads (startup copies/constants) win arbitration; fetch
        // keeps its request stable until ready_o grants the next available edge.
        wire data_request = rst_n_i && data_valid_i && !data_response_q;
        wire fetch_request = valid_i && ready_o;
        wire [BANK_W-1:0] read_even_index = data_request ? data_bank_index : even_index;
        wire [BANK_W-1:0] read_odd_index = data_request ? data_bank_index : bank_index;
        assign ready_o = rst_n_i && !data_request;
        assign rdata_o = in_range_q ? (parity_q ? first_odd_q:first_even_q) : 32'b0;
        assign rdata_next_o = next_range_q ? (parity_q ? first_even_q:first_odd_q) : 32'b0;
        assign data_rdata_o = data_in_range_q ? (rom_parity_q ? first_odd_q:first_even_q) : 32'b0;
        always_ff @(posedge clk_i) begin
            if (data_request || fetch_request) begin
                first_even_q <= even_mem[read_even_index];
                first_odd_q <= odd_mem[read_odd_index];
            end
            if (fetch_request) begin
                parity_q <= addr_i[2];
                in_range_q <= addr_i[31:2]<WORDS && addr_i[1:0]==0;
                next_range_q <= addr_i[31:2]<WORDS-1 && addr_i[1:0]==0;
            end
            if (data_request) begin
                rom_parity_q <= data_addr_i[2];
                data_in_range_q <= data_addr_i[31:2]<WORDS;
            end
        end
    end endgenerate
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            rvalid_o <= 1'b0;
            data_response_q <= 1'b0;
        end else begin
            rvalid_o <= valid_i && ready_o;
            data_response_q <= data_valid_i && !data_response_q;
        end
    end
endmodule
