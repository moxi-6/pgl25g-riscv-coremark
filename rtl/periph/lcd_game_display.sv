module lcd_game_display (
    input wire clk_i, rst_n_i, frame_tick_i,
    input wire [9:0] x_i,
    input wire [8:0] y_i,
    input wire [127:0] state_i,
    input wire [31:0] cycles_i, instret_i,
    input wire [3:0] gpio_i,
    input wire trap_i,
    output reg [23:0] rgb_o
);
    reg [127:0] state_q;
    reg [31:0] cycles_q, instret_q;
    reg [3:0] gpio_q;
    reg trap_q;
    reg [191:0] line_text;
    reg [7:0] ch;
    reg [34:0] glyph;
    wire [9:0] local_x = x_i - 16;
    wire [8:0] local_y = y_i - 8;
    wire [4:0] col = local_x[9:5];
    wire [2:0] row = local_y[8:6];
    wire [2:0] gx = local_x[4:2];
    wire [3:0] gy = local_y[5:2];
    function [7:0] hexchar(input [3:0] n);
        begin hexchar = n<10 ? "0"+n : "A"+n-10; end
    endfunction
    function [34:0] font(input [7:0] ch);
        begin
            case(ch)
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
            "H":font=35'b10001_10001_10001_11111_10001_10001_10001;
            "I":font=35'b01110_00100_00100_00100_00100_00100_01110;
            "J":font=35'b00111_00010_00010_00010_10010_10010_01100;
            "K":font=35'b10001_10010_10100_11000_10100_10010_10001;
            "L":font=35'b10000_10000_10000_10000_10000_10000_11111;
            "M":font=35'b10001_11011_10101_10101_10001_10001_10001;
            "N":font=35'b10001_11001_10101_10011_10001_10001_10001;
            "O":font=35'b01110_10001_10001_10001_10001_10001_01110;
            "P":font=35'b11110_10001_10001_11110_10000_10000_10000;
            "Q":font=35'b01110_10001_10001_10001_10101_10010_01101;
            "R":font=35'b11110_10001_10001_11110_10100_10010_10001;
            "S":font=35'b01111_10000_10000_01110_00001_00001_11110;
            "T":font=35'b11111_00100_00100_00100_00100_00100_00100;
            "U":font=35'b10001_10001_10001_10001_10001_10001_01110;
            "V":font=35'b10001_10001_10001_10001_10001_01010_00100;
            "W":font=35'b10001_10001_10001_10101_10101_11011_10001;
            "X":font=35'b10001_10001_01010_00100_01010_10001_10001;
            "Y":font=35'b10001_10001_01010_00100_00100_00100_00100;
            "Z":font=35'b11111_00001_00010_00100_01000_10000_11111;
            "-":font=35'b00000_00000_00000_11111_00000_00000_00000;
            default:font=0;
            endcase
        end
    endfunction
    always @(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin state_q<=0; cycles_q<=0; instret_q<=0; gpio_q<=0; trap_q<=0; end
        else if(frame_tick_i) begin
            state_q<=state_i; cycles_q<=cycles_i; instret_q<=instret_i;
            gpio_q<=gpio_i; trap_q<=trap_i;
        end
    end
    always @* begin
        case(row)
            0:line_text="RISC V REFLEX           ";
            1:begin
                case(state_q[3:0])
                    1:line_text="WAIT FOR BOARD LED      ";
                    2:line_text="GO - PRESS MATCHING KEY ";
                    3:line_text="HIT                     ";
                    4:line_text="WRONG KEY               ";
                    5:line_text="TIMEOUT                 ";
                    6:line_text="MATCH END - KEY TO START";
                    default:line_text="BOOT                    ";
                endcase
                if(trap_q) line_text="CPU TRAP                ";
            end
            2:line_text="TARGET KEY 0  ROUND 00  ";
            3:line_text=state_q[3:0]==6 ? "HITS 00    AVG 0000 MS  " : "HITS 00   TIME 0000 MS  ";
            4:line_text="BEST 0000 MS            ";
            5:line_text="CYCLES  00000000 HEX    ";
            6:line_text="INSTRET 00000000 HEX    ";
            default:line_text="                        ";
        endcase
        ch = col<24 ? line_text[191-col*8 -:8] : " ";
        if(row==2) begin
            if(col==11) ch=(state_q[3:0]>=2 && state_q[3:0]<=5) ? hexchar({2'b0,state_q[9:8]}) : "-";
            if(col==20) ch=hexchar(state_q[71:68]);
            if(col==21) ch=hexchar(state_q[67:64]);
        end
        if(row==3) begin
            if(col==5) ch=hexchar(state_q[87:84]);
            if(col==6) ch=hexchar(state_q[83:80]);
            if(col>=15 && col<19) ch=hexchar(state_q >> (32+(18-col)*4));
        end
        if(row==4 && col>=5 && col<9) ch=hexchar(state_q >> (96+(8-col)*4));
        if(row==5 && col>=8 && col<16) ch=hexchar(cycles_q >> ((15-col)*4));
        if(row==6 && col>=8 && col<16) ch=hexchar(instret_q >> ((15-col)*4));
        glyph=font(ch);
        rgb_o=24'h101c30;
        if(y_i>=64 && y_i<128) begin
            if(state_q[3:0]==2 || state_q[3:0]==3) rgb_o=24'h086038;
            else if(state_q[3:0]==4 || state_q[3:0]==5 || trap_q) rgb_o=24'h701c24;
            else rgb_o=24'h263b56;
        end
        if(y_i>=440 && y_i<468) begin
            if(x_i>=32 && x_i<160) rgb_o=gpio_q[0] ? 24'h00ff80:24'h263b56;
            if(x_i>=224 && x_i<352) rgb_o=gpio_q[1] ? 24'h00ff80:24'h263b56;
            if(x_i>=416 && x_i<544) rgb_o=gpio_q[2] ? 24'h00ff80:24'h263b56;
            if(x_i>=608 && x_i<736) rgb_o=gpio_q[3] ? 24'h00ff80:24'h263b56;
        end
        if(x_i>=16 && x_i<784 && y_i>=8 && row<7 && gx<5 && gy<7 &&
           glyph[34-(gy*5+gx)]) rgb_o=24'hffffff;
        if(x_i==0 || x_i==799 || y_i==0 || y_i==479) rgb_o=24'hffffff;
    end
endmodule

