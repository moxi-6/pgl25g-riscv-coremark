module uart_tx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD     = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_n_i,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    output logic       ready_o,
    output logic       tx_o
);
    localparam integer CLKS_PER_BIT = CLOCK_HZ / BAUD;
    localparam integer COUNT_WIDTH  = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    logic [9:0] shift_q;
    logic [3:0] bit_index_q;
    logic [COUNT_WIDTH-1:0] clock_count_q;
    logic busy_q;

    assign ready_o = !busy_q;
    assign tx_o    = busy_q ? shift_q[0] : 1'b1;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            shift_q       <= 10'h3ff;
            bit_index_q   <= 4'd0;
            clock_count_q <= '0;
            busy_q        <= 1'b0;
        end else begin
            if (!busy_q) begin
                if (valid_i) begin
                    // UART frame: one start bit, eight data bits, one stop bit.
                    shift_q       <= {1'b1, data_i, 1'b0};
                    bit_index_q   <= 4'd0;
                    clock_count_q <= '0;
                    busy_q        <= 1'b1;
                end
            end else if (clock_count_q == CLKS_PER_BIT - 1) begin
                clock_count_q <= '0;
                shift_q       <= {1'b1, shift_q[9:1]};
                if (bit_index_q == 4'd9) begin
                    busy_q <= 1'b0;
                end else begin
                    bit_index_q <= bit_index_q + 4'd1;
                end
            end else begin
                clock_count_q <= clock_count_q + 1'b1;
            end
        end
    end
endmodule

