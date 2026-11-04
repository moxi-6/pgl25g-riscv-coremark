module atk_l50_lcd (
    input wire sys_clk, sys_rst_n,
    output wire uart_txd,
    output wire [3:0] led,
    output wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_rst, lcd_bl,
    output wire [23:0] lcd_rgb
);
    wire rst_n, frame_tick;
    wire [9:0] x;
    wire [8:0] y;
    wire [23:0] pixel;
    wire [31:0] frames;
    reset_sync u_reset (.clk_i(sys_clk), .reset_n_i(sys_rst_n), .reset_n_o(rst_n));
    lcd_800x480 u_lcd (.clk_i(sys_clk), .rst_n_i(rst_n), .pixel_i(pixel),
        .x_o(x), .y_o(y), .frame_tick_o(frame_tick), .frame_count_o(frames),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_rst(lcd_rst), .lcd_bl(lcd_bl), .lcd_rgb(lcd_rgb));
    lcd_test_pattern u_pattern (.clk_i(sys_clk), .rst_n_i(rst_n), .frame_tick_i(frame_tick),
        .x_i(x), .y_i(y), .frame_count_i(frames), .rgb_o(pixel));
    assign led = {frames[5], 1'b0, lcd_bl, lcd_rst};
    // Periodic UART identity confirms this image runs independently of LCD optics.
    reg [25:0] timer_q;
    reg [4:0] char_q;
    reg sending_q;
    wire tx_ready;
    reg [7:0] tx_data;
    always @* begin
        case (char_q)
            0:tx_data="L"; 1:tx_data="C"; 2:tx_data="D"; 3:tx_data=" ";
            4:tx_data="8"; 5:tx_data="0"; 6:tx_data="0"; 7:tx_data="x";
            8:tx_data="4"; 9:tx_data="8"; 10:tx_data="0"; 11:tx_data=" ";
            12:tx_data="2"; 13:tx_data="5"; 14:tx_data="M"; 15:tx_data="H";
            16:tx_data="z"; 17:tx_data=8'h0d; default:tx_data=8'h0a;
        endcase
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin timer_q<=0; char_q<=0; sending_q<=1; end
        else begin
            if (timer_q==49_999_999) begin timer_q<=0; sending_q<=1; char_q<=0; end
            else timer_q<=timer_q+1;
            if (sending_q && tx_ready) begin
                if (char_q==18) sending_q<=0;
                else char_q<=char_q+1;
            end
        end
    end
    uart_tx #(.CLOCK_HZ(50_000_000), .BAUD(115_200)) u_uart (
        .clk_i(sys_clk), .rst_n_i(rst_n), .valid_i(sending_q), .data_i(tx_data),
        .ready_o(tx_ready), .tx_o(uart_txd));
endmodule
