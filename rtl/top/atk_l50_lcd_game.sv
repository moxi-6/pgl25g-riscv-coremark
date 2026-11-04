// CPU-controlled game HUD. LED onset is the reaction-time reference;
// the LCD shows frame-latched status/results and live counter snapshots.
module atk_l50_lcd_game #(
    parameter MEM_FILE="software/build/firmware.hex"
) (
    input wire sys_clk, sys_rst_n,
    input wire [3:0] key,
    output wire uart_txd,
    output wire [3:0] led,
    output wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_rst, lcd_bl,
    output wire [23:0] lcd_rgb
);
    wire rst_n, tick, halted, trap;
    wire [9:0] x;
    wire [8:0] y;
    wire [23:0] pixel;
    wire [31:0] frames, cycles, instret;
    wire [127:0] state;
    wire [7:0] gpio;
    (* syn_preserve=1 *) reg [3:0] key_meta, key_sync;
    reset_sync u_reset (.clk_i(sys_clk), .reset_n_i(sys_rst_n), .reset_n_o(rst_n));
    always @(posedge sys_clk or negedge rst_n) begin
        if(!rst_n) begin key_meta<=4'hf; key_sync<=4'hf; end
        else begin key_meta<=key; key_sync<=key_meta; end
    end
    rv32i_soc #(.MEM_FILE(MEM_FILE), .LCD_ENABLE(1)) u_soc (
        .clk_i(sys_clk), .rst_n_i(rst_n), .key_i(key_sync), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap), .lcd_state_o(state),
        .cycle_lo_o(cycles), .instret_lo_o(instret));
    assign led=gpio[3:0];
    lcd_800x480 u_lcd (.clk_i(sys_clk), .rst_n_i(rst_n), .pixel_i(pixel),
        .x_o(x), .y_o(y), .frame_tick_o(tick), .frame_count_o(frames),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_rst(lcd_rst), .lcd_bl(lcd_bl), .lcd_rgb(lcd_rgb));
    lcd_game_display u_display (.clk_i(sys_clk), .rst_n_i(rst_n), .frame_tick_i(tick),
        .x_i(x), .y_i(y), .state_i(state), .cycles_i(cycles), .instret_i(instret),
        .gpio_i(gpio[3:0]), .trap_i(trap), .rgb_o(pixel));
endmodule
