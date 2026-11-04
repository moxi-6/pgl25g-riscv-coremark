// Standalone board test: no CPU or firmware required.
module atk_l50_bringup #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer LED_STEP_CYCLES = CLOCK_HZ / 2,
    parameter integer MESSAGE_PERIOD_CYCLES = CLOCK_HZ
) (
    input logic sys_clk,
    input logic sys_rst_n,
    output logic uart_txd,
    output logic [3:0] led
);
    localparam integer LED_W = (LED_STEP_CYCLES <= 1) ? 1 : $clog2(LED_STEP_CYCLES);
    localparam integer PERIOD_W = (MESSAGE_PERIOD_CYCLES <= 1) ? 1 : $clog2(MESSAGE_PERIOD_CYCLES);
    logic rst_n;
    logic [LED_W-1:0] led_count_q;
    logic [PERIOD_W-1:0] period_count_q;
    logic [3:0] message_index_q;
    logic sending_q, ready, valid;
    logic [7:0] data;
    reset_sync u_reset (.clk_i(sys_clk), .reset_n_i(sys_rst_n), .reset_n_o(rst_n));
    // Indexed constants avoid initialized ROM requirements in this board test.
    always_comb begin
        case (message_index_q)
            0: data = "A"; 1: data = "T"; 2: data = "K"; 3: data = "-";
            4: data = "L"; 5: data = "5"; 6: data = "0"; 7: data = " ";
            8: data = "O"; 9: data = "K"; 10: data = 8'h0d;
            default: data = 8'h0a;
        endcase
    end
    assign valid = sending_q && ready;
    uart_tx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) u_uart (
        .clk_i(sys_clk), .rst_n_i(rst_n), .valid_i(valid), .data_i(data),
        .ready_o(ready), .tx_o(uart_txd)
    );
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            led <= 4'b0001;
            led_count_q <= '0;
            period_count_q <= '0;
            message_index_q <= '0;
            sending_q <= 1'b1;
        end else begin
            if (led_count_q == LED_STEP_CYCLES - 1) begin
                led_count_q <= '0;
                led <= {led[2:0], led[3]};
            end else led_count_q <= led_count_q + 1'b1;
            // Period measured from acceptance of the previous message's LF.
            if (sending_q) begin
                if (valid) begin
                    if (message_index_q == 11) begin
                        message_index_q <= '0;
                        sending_q <= 1'b0;
                        period_count_q <= '0;
                    end else message_index_q <= message_index_q + 1'b1;
                end
            end else if (period_count_q == MESSAGE_PERIOD_CYCLES - 1) begin
                period_count_q <= '0;
                sending_q <= 1'b1;
            end else period_count_q <= period_count_q + 1'b1;
        end
    end
endmodule
