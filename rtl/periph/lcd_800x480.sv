// ATK 800x480 RGB panel, DE mode. All logic stays in the 50 MHz domain.
// RGB/DE change on the falling edge of the 25 MHz forwarded pixel clock.
module lcd_800x480 #(
    parameter integer RESET_CYCLES = 500_000,
    parameter integer BACKLIGHT_FRAMES = 2
) (
    input wire clk_i, rst_n_i,
    input wire [23:0] pixel_i,
    output wire [9:0] x_o,
    output wire [8:0] y_o,
    output wire frame_tick_o,
    output reg [31:0] frame_count_o,
    output reg lcd_pclk, lcd_de,
    output wire lcd_hs, lcd_vs, lcd_rst, lcd_bl,
    output reg [23:0] lcd_rgb
);
    // Development guide table 27.1.3: H=128+88+800+40, V=2+33+480+10.
    // The guide's clk_div uses 25 MHz for 7084/4384 (45.09 frames/s).
    localparam integer HTOTAL = 1056, VTOTAL = 525;
    reg [10:0] h_q;
    reg [9:0] v_q;
    reg [31:0] reset_count_q;
    wire ready = reset_count_q == RESET_CYCLES;
    wire active = h_q >= 216 && h_q < 1016 && v_q >= 35 && v_q < 515;
    assign x_o = active ? h_q - 10'd216 : 10'd0;
    assign y_o = active ? v_q - 10'd35 : 10'd0;
    assign frame_tick_o = ready && lcd_pclk && h_q == HTOTAL-1 && v_q == VTOTAL-1;
    assign lcd_hs = 1'b1;
    assign lcd_vs = 1'b1;
    assign lcd_rst = rst_n_i && ready;
    assign lcd_bl = lcd_rst && frame_count_o >= BACKLIGHT_FRAMES;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            reset_count_q <= 0;
            lcd_pclk <= 0;
            lcd_de <= 0;
            lcd_rgb <= 0;
            h_q <= 0;
            v_q <= 0;
            frame_count_o <= 0;
        end else if (!ready) begin
            reset_count_q <= reset_count_q + 1;
        end else begin
            lcd_pclk <= ~lcd_pclk;
            if (lcd_pclk) begin
                lcd_de <= active;
                lcd_rgb <= active ? pixel_i : 24'd0;
                if (h_q == HTOTAL-1) begin
                    h_q <= 0;
                    if (v_q == VTOTAL-1) begin
                        v_q <= 0;
                        frame_count_o <= frame_count_o + 1;
                    end else v_q <= v_q + 1;
                end else h_q <= h_q + 1;
            end
        end
    end
endmodule
