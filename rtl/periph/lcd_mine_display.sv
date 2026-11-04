// Hardware grid renderer for the minesweeper firmware.
//
// The board is 9x9 cells of 48x48 px, centred in the 640x480 picture area at
// (104, 24).  The CPU never writes pixels: it only publishes one 4-bit state
// per tile (see software/mine.c) plus a cursor, and this block turns that into
// RGB.  Everything is combinational, the same style as lcd_shooter_display.
//
// tile state encoding
//   0      covered
//   1..8   revealed, that many neighbouring mines
//   9      revealed, no neighbouring mines
//   10     flagged
//   11     mine revealed at game over
//   12     the mine the player stepped on (red background)
//   13     wrong flag at game over
module lcd_mine_display #(
    parameter FONT_FILE = "rtl/periph/mine_font.hex"
) (
    input  wire        clk_i,
    input  wire [9:0]  x_i,
    input  wire [8:0]  y_i,
    input  wire [511:0] mine_i,
    output reg  [23:0] rgb_o
);
    localparam [23:0] C_BG      = 24'h0c121c;
    localparam [23:0] C_BAR     = 24'h16202e;
    localparam [23:0] C_COVER   = 24'h3a4658;
    localparam [23:0] C_COVER_HI= 24'h53637a;
    localparam [23:0] C_OPEN    = 24'h1a222e;
    localparam [23:0] C_GRID    = 24'h24303f;
    localparam [23:0] C_CURSOR  = 24'hffd24a;
    localparam [23:0] C_FLAG    = 24'he8443a;
    localparam [23:0] C_MINE    = 24'h0a0d12;
    localparam [23:0] C_BOOM    = 24'h8f1f1a;
    localparam [23:0] C_FRAME   = 24'h6684a4;

    // Cursor / flags word lives in bits [383:352] of the packed payload.
    wire [3:0] cur_col = mine_i[355:352];
    wire [3:0] cur_row = mine_i[359:356];
    wire       show_all= mine_i[360];
    wire       won     = mine_i[361];
    wire [7:0] level = mine_i[391:384];
    wire [7:0] total_mines = mine_i[399:392];
    wire [7:0] flags = mine_i[407:400];
    wire [7:0] safe_left = mine_i[415:408];
    wire [1:0] theme = mine_i[449:448];
    wire flag_mode = mine_i[456], placed = mine_i[457], lost = mine_i[458];
    wire [9:0] seconds = mine_i[425:416] > 999 ? 10'd999 : mine_i[425:416];
    reg [15:0] font [0:2047];
    reg [15:0] font_row_q;
    reg [6:0] code;
    integer line, col_text, tx, ty, gx, gy;
    reg text_on;
    initial $readmemh(FONT_FILE, font);
    always @(posedge clk_i) font_row_q <= font[{code,gy[3:0]}];
    // BEGIN_GENERATED_MINE_FONT
    function automatic [6:0] text_id(input integer line,input integer col);
        begin case(line)
            0: case(col)
                0:text_id=7'd1;
                1:text_id=7'd2;
                2:text_id=7'd3;
                3:text_id=7'd4;
                default:text_id=0; endcase
            1: case(col)
                0:text_id=7'd5;
                1:text_id=7'd6;
                2:text_id=7'd0;
                3:text_id=7'd7;
                4:text_id=7'd8;
                5:text_id=7'd9;
                default:text_id=0; endcase
            2: case(col)
                0:text_id=7'd10;
                1:text_id=7'd11;
                default:text_id=0; endcase
            3: case(col)
                0:text_id=7'd10;
                1:text_id=7'd4;
                2:text_id=7'd0;
                3:text_id=7'd12;
                4:text_id=7'd12;
                default:text_id=0; endcase
            4: case(col)
                0:text_id=7'd13;
                1:text_id=7'd14;
                2:text_id=7'd0;
                3:text_id=7'd12;
                4:text_id=7'd12;
                default:text_id=0; endcase
            5: case(col)
                0:text_id=7'd15;
                1:text_id=7'd16;
                2:text_id=7'd0;
                3:text_id=7'd12;
                4:text_id=7'd12;
                default:text_id=0; endcase
            6: case(col)
                0:text_id=7'd17;
                1:text_id=7'd18;
                2:text_id=7'd12;
                3:text_id=7'd12;
                4:text_id=7'd12;
                5:text_id=7'd19;
                default:text_id=0; endcase
            7: case(col)
                0:text_id=7'd20;
                1:text_id=7'd21;
                2:text_id=7'd22;
                3:text_id=7'd23;
                default:text_id=0; endcase
            8: case(col)
                0:text_id=7'd24;
                1:text_id=7'd25;
                2:text_id=7'd26;
                3:text_id=7'd27;
                4:text_id=7'd4;
                5:text_id=7'd24;
                default:text_id=0; endcase
            9: case(col)
                0:text_id=7'd28;
                1:text_id=7'd16;
                2:text_id=7'd23;
                3:text_id=7'd29;
                4:text_id=7'd22;
                5:text_id=7'd23;
                6:text_id=7'd30;
                default:text_id=0; endcase
            10: case(col)
                0:text_id=7'd12;
                1:text_id=7'd31;
                2:text_id=7'd0;
                3:text_id=7'd7;
                4:text_id=7'd32;
                5:text_id=7'd0;
                6:text_id=7'd33;
                7:text_id=7'd34;
                default:text_id=0; endcase
            11: case(col)
                0:text_id=7'd35;
                1:text_id=7'd36;
                2:text_id=7'd37;
                3:text_id=7'd38;
                4:text_id=7'd39;
                5:text_id=7'd40;
                6:text_id=7'd28;
                7:text_id=7'd16;
                default:text_id=0; endcase
            12: case(col)
                0:text_id=7'd41;
                1:text_id=7'd40;
                2:text_id=7'd13;
                3:text_id=7'd14;
                default:text_id=0; endcase
            13: case(col)
                0:text_id=7'd1;
                1:text_id=7'd2;
                2:text_id=7'd21;
                3:text_id=7'd30;
                4:text_id=7'd28;
                5:text_id=7'd16;
                default:text_id=0; endcase
            14: case(col)
                default:text_id=0; endcase
            15: case(col)
                default:text_id=0; endcase
            16: case(col)
                0:text_id=7'd42;
                1:text_id=7'd43;
                2:text_id=7'd44;
                3:text_id=7'd45;
                default:text_id=0; endcase
            17: case(col)
                0:text_id=7'd46;
                1:text_id=7'd47;
                2:text_id=7'd48;
                3:text_id=7'd49;
                default:text_id=0; endcase
            18: case(col)
                0:text_id=7'd50;
                1:text_id=7'd51;
                2:text_id=7'd52;
                3:text_id=7'd53;
                default:text_id=0; endcase
            19: case(col)
                0:text_id=7'd54;
                1:text_id=7'd55;
                2:text_id=7'd56;
                3:text_id=7'd57;
                default:text_id=0; endcase
            20: case(col)
                0:text_id=7'd58;
                1:text_id=7'd59;
                2:text_id=7'd60;
                3:text_id=7'd4;
                default:text_id=0; endcase
            21: case(col)
                0:text_id=7'd61;
                1:text_id=7'd4;
                2:text_id=7'd62;
                3:text_id=7'd63;
                default:text_id=0; endcase
            22: case(col)
                0:text_id=7'd5;
                1:text_id=7'd6;
                2:text_id=7'd64;
                3:text_id=7'd65;
                default:text_id=0; endcase
            23: case(col)
                0:text_id=7'd1;
                1:text_id=7'd2;
                2:text_id=7'd21;
                3:text_id=7'd30;
                4:text_id=7'd13;
                5:text_id=7'd14;
                default:text_id=0; endcase
            24: case(col)
                0:text_id=7'd66;
                1:text_id=7'd67;
                2:text_id=7'd68;
                3:text_id=7'd28;
                4:text_id=7'd16;
                default:text_id=0; endcase
            25: case(col)
                0:text_id=7'd66;
                1:text_id=7'd67;
                2:text_id=7'd68;
                3:text_id=7'd13;
                4:text_id=7'd14;
                default:text_id=0; endcase
            26: case(col)
                0:text_id=7'd69;
                1:text_id=7'd16;
                2:text_id=7'd70;
                3:text_id=7'd5;
                default:text_id=0; endcase
            27: case(col)
                0:text_id=7'd34;
                1:text_id=7'd71;
                2:text_id=7'd5;
                default:text_id=0; endcase
            28: case(col)
                0:text_id=7'd23;
                1:text_id=7'd29;
                2:text_id=7'd72;
                3:text_id=7'd5;
                4:text_id=7'd69;
                5:text_id=7'd73;
                default:text_id=0; endcase
            29: case(col)
                0:text_id=7'd20;
                1:text_id=7'd21;
                2:text_id=7'd74;
                3:text_id=7'd75;
                4:text_id=7'd76;
                5:text_id=7'd4;
                6:text_id=7'd0;
                7:text_id=7'd32;
                8:text_id=7'd77;
                9:text_id=7'd78;
                10:text_id=7'd79;
                11:text_id=7'd80;
                12:text_id=7'd13;
                13:text_id=7'd14;
                default:text_id=0; endcase
            30: case(col)
                0:text_id=7'd61;
                1:text_id=7'd4;
                2:text_id=7'd81;
                3:text_id=7'd82;
                4:text_id=7'd40;
                5:text_id=7'd83;
                6:text_id=7'd84;
                7:text_id=7'd85;
                8:text_id=7'd86;
                9:text_id=7'd32;
                10:text_id=7'd77;
                11:text_id=7'd40;
                12:text_id=7'd87;
                13:text_id=7'd69;
                14:text_id=7'd16;
                default:text_id=0; endcase
            31: case(col)
                0:text_id=7'd88;
                1:text_id=7'd5;
                2:text_id=7'd82;
                3:text_id=7'd40;
                4:text_id=7'd83;
                5:text_id=7'd84;
                6:text_id=7'd85;
                7:text_id=7'd86;
                8:text_id=7'd32;
                9:text_id=7'd77;
                10:text_id=7'd40;
                11:text_id=7'd87;
                12:text_id=7'd89;
                13:text_id=7'd90;
                default:text_id=0; endcase
            32: case(col)
                0:text_id=7'd12;
                1:text_id=7'd7;
                2:text_id=7'd33;
                3:text_id=7'd38;
                4:text_id=7'd91;
                5:text_id=7'd92;
                6:text_id=7'd93;
                7:text_id=7'd94;
                8:text_id=7'd9;
                9:text_id=7'd95;
                default:text_id=0; endcase
            default:text_id=0; endcase end
    endfunction
    function automatic [6:0] digit_id(input integer n);
        begin case(n)
            0:digit_id=7'd12;
            1:digit_id=7'd7;
            2:digit_id=7'd33;
            3:digit_id=7'd38;
            4:digit_id=7'd91;
            5:digit_id=7'd92;
            6:digit_id=7'd93;
            7:digit_id=7'd94;
            8:digit_id=7'd9;
            9:digit_id=7'd95;
            default:digit_id=0; endcase end
    endfunction
    // END_GENERATED_MINE_FONT

    // 5x7 digit glyphs, bit 4 is the leftmost column.
    function automatic [4:0] glyph(input [3:0] d, input [2:0] r);
        case (d)
            4'd1: case (r)
                3'd0: glyph = 5'b00100; 3'd1: glyph = 5'b01100;
                3'd2: glyph = 5'b00100; 3'd3: glyph = 5'b00100;
                3'd4: glyph = 5'b00100; 3'd5: glyph = 5'b00100;
                default: glyph = 5'b01110; endcase
            4'd2: case (r)
                3'd0: glyph = 5'b01110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b00001; 3'd3: glyph = 5'b00110;
                3'd4: glyph = 5'b01000; 3'd5: glyph = 5'b10000;
                default: glyph = 5'b11111; endcase
            4'd3: case (r)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b00010;
                3'd2: glyph = 5'b00100; 3'd3: glyph = 5'b00010;
                3'd4: glyph = 5'b00001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110; endcase
            4'd4: case (r)
                3'd0: glyph = 5'b00010; 3'd1: glyph = 5'b00110;
                3'd2: glyph = 5'b01010; 3'd3: glyph = 5'b10010;
                3'd4: glyph = 5'b11111; 3'd5: glyph = 5'b00010;
                default: glyph = 5'b00010; endcase
            4'd5: case (r)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b10000;
                3'd2: glyph = 5'b11110; 3'd3: glyph = 5'b00001;
                3'd4: glyph = 5'b00001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110; endcase
            4'd6: case (r)
                3'd0: glyph = 5'b00110; 3'd1: glyph = 5'b01000;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110; endcase
            4'd7: case (r)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b00001;
                3'd2: glyph = 5'b00010; 3'd3: glyph = 5'b00100;
                3'd4: glyph = 5'b01000; 3'd5: glyph = 5'b01000;
                default: glyph = 5'b01000; endcase
            4'd8: case (r)
                3'd0: glyph = 5'b01110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b01110;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110; endcase
            default: glyph = 5'b00000;
        endcase
    endfunction

    function automatic [23:0] digit_color(input [3:0] d);
        case (d)
            4'd1: digit_color = 24'h4fa8ff;
            4'd2: digit_color = 24'h39d353;
            4'd3: digit_color = 24'hff6b6b;
            4'd4: digit_color = 24'hb07cff;
            4'd5: digit_color = 24'hffa33e;
            4'd6: digit_color = 24'h36d6c3;
            4'd7: digit_color = 24'he8ecf4;
            default: digit_color = 24'h9aa4b8;
        endcase
    endfunction

    // Board geometry helpers.
    wire [9:0] bx = x_i - 10'd104;
    wire [9:0] by = {1'b0, y_i} - 10'd24;
    wire [21:0] mx = bx * 12'd2731;   // bx/48  ~= (bx*2731)>>17
    wire [21:0] my = by * 12'd2731;
    wire [4:0]  col = mx[21:17];
    wire [4:0]  row = my[21:17];
    wire [9:0]  col48 = {1'b0, col[3:0], 5'b0} + {2'b0, col[3:0], 4'b0};  // col*48
    wire [9:0]  row48 = {1'b0, row[3:0], 5'b0} + {2'b0, row[3:0], 4'b0};
    wire [9:0]  fx  = bx - col48;
    wire [9:0]  fy  = by - row48;
    wire        in_board = (x_i >= 10'd104) && (x_i < 10'd536) &&
                           (y_i >= 9'd24)  && (y_i < 9'd456);
    wire [8:0]  cell_idx = {1'b0, row[3:0], 3'b0} + {4'b0, row[3:0]} + {4'b0, col[3:0]};
    wire [3:0]  tile     = mine_i[cell_idx*4 +: 4];

    // Digit window inside the 48x48 tile: 10x14 at (19,17), doubled pixels.
    wire [9:0]  dx = fx - 10'd19;
    wire [9:0]  dy = fy - 10'd17;
    wire        in_dig  = (fx >= 10'd19) && (fx < 10'd29) &&
                          (fy >= 10'd17) && (fy < 10'd31);
    wire [2:0]  lx      = dx[4:1];
    wire [2:0]  ly      = dy[4:1];
    wire [4:0]  g_row   = glyph(tile, ly);
    wire        digit_px = in_dig && g_row[3'd4 - lx];

    // Flag: pole at x=26, cloth triangle to the left of it.
    wire        flag_px = (tile == 4'd10 || tile == 4'd13) &&
                          ((fx >= 10'd25 && fx < 10'd27 && fy >= 10'd12 && fy < 10'd35) ||
                           ((fx >= 10'd17 && fx < 10'd26) && (fy >= 10'd12 && fy < 10'd22) &&
                            ((fx - 10'd17) + (fy - 10'd12) < 10'd10)));

    // Mine: filled disc, radius 9, with a small highlight.
    wire [9:0] ddx = (fx > 10'd24) ? (fx - 10'd24) : (10'd24 - fx);
    wire [9:0] ddy = (fy > 10'd24) ? (fy - 10'd24) : (10'd24 - fy);
    wire mine_px;
    assign mine_px = ((tile == 4'd11) || (tile == 4'd12)) &&
                    (ddx <= 8 && ddy <= 8 && ddx + ddy <= 12);
    wire shine;
    assign shine = mine_px && (fx < 10'd24 && fy < 10'd24) && (ddx + ddy < 10'd9);

    wire        cursor_px = (col[3:0] == cur_col) && (row[3:0] == cur_row);

    always @* begin
        rgb_o = C_BG;
        case(theme)
            1: rgb_o=24'h152b2b;
            2: rgb_o=24'h282039;
            3: rgb_o=24'h30231c;
            default: rgb_o=C_BG;
        endcase
        if (x_i >= 640) begin
            rgb_o = C_BAR;
        end else if (in_board) begin
            if (fx < 10'd2 || fx > 10'd45 || fy < 10'd2 || fy > 10'd45) begin
                rgb_o = C_GRID;
            end else if (tile == 4'd0) begin
                rgb_o = C_COVER;
                if (fx < 10'd4 || fy < 10'd4) rgb_o = C_COVER_HI;
            end else if (tile == 4'd14) begin
                rgb_o = ((fx[3:0]==0) || (fy[3:0]==0)) ? 24'h516274 : 24'h283848;
            end else if (tile == 4'd12) begin
                rgb_o = C_BOOM;
            end else begin
                rgb_o = C_OPEN;
            end
            if (digit_px) rgb_o = digit_color(tile);
            if (flag_px)  rgb_o = (tile == 4'd13) ? 24'hff8a80 : C_FLAG;
            if (mine_px)  rgb_o = shine ? 24'he8ecf4 : C_MINE;
            // Cursor ring is drawn last so it stays visible over every state.
            if (cursor_px && (fx < 10'd3 || fx > 10'd44 || fy < 10'd3 || fy > 10'd44))
                rgb_o = (won || show_all) ? 24'h39d353 : C_CURSOR;
        end
        if (x_i == 10'd0 || x_i == 10'd799 || y_i == 9'd0 || y_i == 9'd479)
            rgb_o = C_FRAME;
        if (x_i>=648 && x_i<792 && y_i>=360 && y_i<400)
            rgb_o = flag_mode ? 24'h88483c : 24'h215d68;
        if (x_i>=648 && x_i<792 && y_i>=416 && y_i<456)
            rgb_o = won ? 24'h287148 : 24'h34465b;
        text_on=0;code=0;line=0;col_text=0;gx=0;gy=0;tx=0;ty=0;
        if(x_i>=648 && x_i<792 && y_i>=16 && y_i<352) begin
            tx=x_i-648;ty=y_i-16;line=ty/24;col_text=tx>>4;gx=tx&15;gy=ty%24;
            text_on=gy<16;
            if(line==2) line=16+theme;
            if(line==7) line=lost ? 21 : (won ? 22 : (placed ? 20 : 7));
            if(line==13 && flag_mode) line=23;
            code=text_id(line,col_text);
            if(line==1 && col_text==3) code=digit_id(level);
            if(line==3 && col_text==3) code=digit_id(total_mines/10);
            if(line==3 && col_text==4) code=digit_id(total_mines%10);
            if(line==4 && col_text==3) code=digit_id(flags/10);
            if(line==4 && col_text==4) code=digit_id(flags%10);
            if(line==5 && col_text==3) code=digit_id(safe_left/10);
            if(line==5 && col_text==4) code=digit_id(safe_left%10);
            if(line==6 && col_text==2) code=digit_id(seconds/100);
            if(line==6 && col_text==3) code=digit_id((seconds/10)%10);
            if(line==6 && col_text==4) code=digit_id(seconds%10);
        end else if(x_i>=656 && x_i<784 && ((y_i>=372 && y_i<388)||(y_i>=428 && y_i<444))) begin
            tx=x_i-656;gx=tx&15;gy=y_i&15;col_text=tx>>4;text_on=1;
            if(y_i<400) begin gy=y_i-372;line=flag_mode ? 25 : 24;end
            else begin gy=y_i-428;line=won ? (level==8 ? 28 : 27) : 26;end
            code=text_id(line,col_text);
        end else if(x_i>=104 && x_i<584 && y_i>=460 && y_i<476) begin
            tx=x_i-104;col_text=tx>>4;gx=tx&15;gy=y_i-460;text_on=1;
            code=text_id(lost ? 30 : (won ? 31 : 29),col_text);
        end
        if(text_on && font_row_q[15-gx]) rgb_o=(line==21 ? 24'hff9a90 : 24'hebf3fa);
    end
endmodule
