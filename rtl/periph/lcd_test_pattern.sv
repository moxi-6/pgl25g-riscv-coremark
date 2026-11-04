// Small ROM font and procedural graphics; no frame buffer or external RAM.
module lcd_test_pattern (
    input wire clk_i, rst_n_i, frame_tick_i,
    input wire [9:0] x_i,
    input wire [8:0] y_i,
    input wire [31:0] frame_count_i,
    output reg [23:0] rgb_o
);
    reg [9:0] sprite_x_q;
    reg moving_left_q;
    reg [7:0] character;
    reg [34:0] glyph;
    reg [4:0] column;
    reg [2:0] glyph_x, glyph_y;
    reg text_pixel;
    function [7:0] title_char(input [4:0] n);
        begin
            case (n)
                0:title_char="R"; 1:title_char="G"; 2:title_char="B";
                4:title_char="L"; 5:title_char="C"; 6:title_char="D";
                8:title_char="8"; 9:title_char="0"; 10:title_char="0";
                11:title_char="X"; 12:title_char="4"; 13:title_char="8"; 14:title_char="0";
                default:title_char=" ";
            endcase
        end
    endfunction
    function [34:0] font(input [7:0] ch);
        begin
            case (ch)
                "0":font=35'b01110_10001_10011_10101_11001_10001_01110;
                "1":font=35'b00100_01100_00100_00100_00100_00100_01110;
                "2":font=35'b01110_10001_00001_00010_00100_01000_11111;
                "3":font=35'b11110_00001_00001_01110_00001_00001_11110;
                "4":font=35'b00010_00110_01010_10010_11111_00010_00010;
                "5":font=35'b11111_10000_10000_11110_00001_00001_11110;
                "6":font=35'b01110_10000_10000_11110_10001_10001_01110;
                "7":font=35'b11111_00001_00010_00100_01000_01000_01000;
                "8":font=35'b01110_10001_10001_01110_10001_10001_01110;
                "9":font=35'b01110_10001_10001_01111_00001_00001_01110;
                "A":font=35'b01110_10001_10001_11111_10001_10001_10001;
                "B":font=35'b11110_10001_10001_11110_10001_10001_11110;
                "C":font=35'b01111_10000_10000_10000_10000_10000_01111;
                "D":font=35'b11110_10001_10001_10001_10001_10001_11110;
                "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
                "F":font=35'b11111_10000_10000_11110_10000_10000_10000;
                "G":font=35'b01111_10000_10000_10111_10001_10001_01111;
                "L":font=35'b10000_10000_10000_10000_10000_10000_11111;
                "R":font=35'b11110_10001_10001_11110_10100_10010_10001;
                "X":font=35'b10001_10001_01010_00100_01010_10001_10001;
                default:font=35'd0;
            endcase
        end
    endfunction
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin sprite_x_q <= 16; moving_left_q <= 0; end
        else if (frame_tick_i) begin
            if (!moving_left_q) begin
                if (sprite_x_q >= 748) begin sprite_x_q <= 748; moving_left_q <= 1; end
                else sprite_x_q <= sprite_x_q + 4;
            end else begin
                if (sprite_x_q <= 20) begin sprite_x_q <= 16; moving_left_q <= 0; end
                else sprite_x_q <= sprite_x_q - 4;
            end
        end
    end
    always @* begin
        // 32-pixel character cells: a 5x7 font enlarged four times.
        column = (x_i - 32) >> 5;
        glyph_x = (x_i - 32) >> 2;
        glyph_y = (y_i - 24) >> 2;
        character = title_char(column);
        if (y_i >= 400 && y_i < 428) begin
            glyph_y = (y_i - 400) >> 2;
            if (column < 8) begin
                character = (frame_count_i >> ((7-column)*4)) & 15;
                character = character < 10 ? character + "0" : character - 10 + "A";
            end else character = " ";
        end
        glyph = font(character);
        text_pixel = x_i >= 32 && x_i < 512 && glyph_x < 5 && glyph_y < 7 &&
                     ((y_i >= 24 && y_i < 52) || (y_i >= 400 && y_i < 428)) &&
                     glyph[34-(glyph_y*5+glyph_x)];
        rgb_o = 24'h101c30;
        if (y_i >= 80 && y_i < 240) begin
            if (x_i < 100) rgb_o=24'hffffff;
            else if (x_i < 200) rgb_o=24'hffff00;
            else if (x_i < 300) rgb_o=24'h00ffff;
            else if (x_i < 400) rgb_o=24'h00ff00;
            else if (x_i < 500) rgb_o=24'hff00ff;
            else if (x_i < 600) rgb_o=24'hff0000;
            else if (x_i < 700) rgb_o=24'h0000ff;
            else rgb_o=24'h000000;
        end
        if (x_i >= sprite_x_q && x_i < sprite_x_q+32 && y_i >= 300 && y_i < 332)
            rgb_o=24'h00ffb0;
        if (text_pixel) rgb_o=24'hffffff;
        // One-pixel border exposes cropped or shifted active windows.
        if (x_i==0 || x_i==799 || y_i==0 || y_i==479) rgb_o=24'hffffff;
    end
endmodule
