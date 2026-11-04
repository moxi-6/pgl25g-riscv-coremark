// ATK-L50 shooter/mini-game board: RGB LCD picture + UART console + I2C touch.
// The touch bus is a plain open-drain pair; the FPGA only drives it low, and the
// panel-side pull-ups (plus the PULLUP constraint on these pads) restore the high
// level.  TP_INT is an input from the GT9147, TP_RST an output.
module atk_l50_shooter #(
    parameter MEM_FILE     = "software/build/firmware.hex",
    parameter TOUCH_ENABLE = 1
) (
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire [3:0] key,
    output wire       uart_txd,
    output wire [3:0] led,
    output wire       lcd_pclk,
    output wire       lcd_de,
    output wire       lcd_hs,
    output wire       lcd_vs,
    output wire       lcd_rst,
    output wire       lcd_bl,
    output wire [23:0] lcd_rgb,
    // Touch panel.
    output wire       tp_scl,
    inout  wire       tp_sda,
    output wire       tp_rst,
    input  wire       tp_int
);
    wire rst_n, tick, halted, trap;
    wire [9:0] x;
    wire [8:0] y;
    wire [23:0] pixel;
    wire [31:0] frames;
    wire [1023:0] sprites;
    wire [127:0] hud;
    wire [7:0] gpio;

    // Touch bus triplets.
    wire tp_scl_o, tp_sda_o, tp_sda_oe, tp_sda_i, tp_int_o, tp_int_oe;

    (* syn_preserve=1 *) reg [3:0] key_meta, key_sync;
    reset_sync u_reset (.clk_i(sys_clk), .reset_n_i(sys_rst_n), .reset_n_o(rst_n));
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 15;
            key_sync <= 15;
        end else begin
            key_meta <= key;
            key_sync <= key_meta;
        end
    end

    // Open-drain: the pad is only ever pulled low, never driven high.
    assign tp_sda = (tp_sda_oe && !tp_sda_o) ? 1'b0 : 1'bz;
    assign tp_sda_i   = tp_sda;
    assign tp_scl     = tp_scl_o;
    assign tp_rst     = tp_rst_o;

    rv32i_soc #(
        .MEM_FILE    (MEM_FILE),
        .LCD_ENABLE  (1),
        .VIDEO_ENABLE(1),
        .TOUCH_ENABLE(TOUCH_ENABLE)
    ) u_soc (
        .clk_i          (sys_clk),
        .rst_n_i        (rst_n),
        .key_i          (key_sync),
        .uart_tx_o      (uart_txd),
        .gpio_o         (gpio),
        .halted_o       (halted),
        .trap_o         (trap),
        .video_frame_i  (tick),
        .video_sprites_o(sprites),
        .video_hud_o    (hud),
        .tp_scl_o       (tp_scl_o),
        .tp_sda_o       (tp_sda_o),
        .tp_sda_oe      (tp_sda_oe),
        .tp_sda_i       (tp_sda_i),
        .tp_int_i       (tp_int),
        .tp_rst_o       (tp_rst_o),
        .tp_int_o       (tp_int_o),
        .tp_int_oe      (tp_int_oe)
    );

    assign led = trap ? 4'hf : gpio[3:0];

    lcd_800x480 u_lcd (
        .clk_i          (sys_clk),
        .rst_n_i        (rst_n),
        .pixel_i        (pixel),
        .x_o            (x),
        .y_o            (y),
        .frame_tick_o   (tick),
        .frame_count_o  (frames),
        .lcd_pclk       (lcd_pclk),
        .lcd_de         (lcd_de),
        .lcd_hs         (lcd_hs),
        .lcd_vs         (lcd_vs),
        .lcd_rst        (lcd_rst),
        .lcd_bl         (lcd_bl),
        .lcd_rgb        (lcd_rgb)
    );

    lcd_shooter_display u_display (
        .clk_i     (sys_clk),
        .x_i       (x),
        .y_i       (y),
        .sprites_i (sprites),
        .hud_i     (hud),
        .rgb_o     (pixel)
    );
endmodule