// Completion-style data bus: requester holds valid/address/data/strobes until
// ready_o. RAM performs each operation once and completes on the next cycle.
module sync_dmem #(
    parameter integer WORDS = 4096,
    // Distributed RAM option: asynchronous read and synchronous byte writes.
    parameter bit ASYNC_READ = 1'b0
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic valid_i,
    input logic write_i,
    input logic [31:0] addr_i,
    input logic [31:0] wdata_i,
    input logic [3:0] wstrb_i,
    output logic [31:0] rdata_o,
    output logic ready_o
);
    localparam integer ADDR_W = (WORDS <= 1) ? 1 : $clog2(WORDS);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] data_q;
    logic in_range_q, response_q;
    integer lane;
    wire access_en = rst_n_i && valid_i && (ASYNC_READ || !response_q);
    wire in_range = addr_i[31:2] < WORDS;
    assign ready_o = ASYNC_READ ? rst_n_i : response_q;
    assign rdata_o = ASYNC_READ ? (in_range ? mem[addr_i[ADDR_W+1:2]] : 32'b0)
                               : (in_range_q ? data_q : 32'b0);
    // No array reset/initialization: startup software owns RAM contents.
    always_ff @(posedge clk_i) begin
        if (access_en) begin
            data_q <= mem[addr_i[ADDR_W+1:2]];
            in_range_q <= in_range;
            if (write_i && in_range) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (wstrb_i[lane]) mem[addr_i[ADDR_W+1:2]][lane*8 +: 8] <= wdata_i[lane*8 +: 8];
            end
        end
    end
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) response_q <= 1'b0;
        else response_q <= valid_i && !response_q;
    end
endmodule
