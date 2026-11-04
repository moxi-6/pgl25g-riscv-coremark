module reset_sync (
    input logic clk_i,
    input logic reset_n_i,
    output logic reset_n_o
);
    logic [1:0] sync_q /* synthesis syn_preserve=1 */;
    // Asynchronous assertion, two-clock synchronous release.
    always_ff @(posedge clk_i or negedge reset_n_i) begin
        if (!reset_n_i) sync_q <= 2'b00;
        else sync_q <= {sync_q[0], 1'b1};
    end
    assign reset_n_o = sync_q[1];
endmodule
