`timescale 1ns/1ps
module tb_lcd;
    reg clk=0, rst_n=1;
    always #10 clk=~clk;
    wire [9:0] x;
    wire [8:0] y;
    wire [23:0] pixel, rgb;
    wire [31:0] frames;
    wire tick, pclk, de, hs, vs, reset_out, bl;
    lcd_800x480 #(.RESET_CYCLES(8)) dut (.clk_i(clk), .rst_n_i(rst_n),
        .pixel_i(pixel), .x_o(x), .y_o(y), .frame_tick_o(tick), .frame_count_o(frames),
        .lcd_pclk(pclk), .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_rst(reset_out),
        .lcd_bl(bl), .lcd_rgb(rgb));
    lcd_test_pattern pattern (.clk_i(clk), .rst_n_i(rst_n), .frame_tick_i(tick),
        .x_i(x), .y_i(y), .frame_count_i(frames), .rgb_o(pixel));
    integer f, h, v, n, count, line_count, fd, px, py;
    reg expected_de;
    reg [23:0] expected_rgb, before_rgb;
    reg before_de;
    time last_edge;
    initial begin
        #1; rst_n=0;
        #1;
        if (bl !== 0 || de !== 0) $fatal(1,"reset must blank display");
        #40; rst_n=1;
        repeat(7) begin @(posedge clk); #1; if(reset_out || bl || pclk) $fatal(1,"reset hold too short"); end
        wait(reset_out);
        if(bl) $fatal(1,"backlight enabled before full frames");
        @(negedge pclk);
        last_edge=$time;
        fd=$fopen("build/lcd_frame.ppm", "wb");
        if(!fd) $fatal(1,"frame output open failed");
        $fwrite(fd,"P6\n800 480\n255\n");
        for(f=0; f<2; f=f+1) begin
            count=0;
            for(v=0; v<525; v=v+1) begin
                line_count=0;
                for(h=0; h<1056; h=h+1) begin
                    @(posedge pclk); #1;
                    if($time-last_edge != 21) $fatal(1,"pclk half-period wrong");
                    before_rgb=rgb; before_de=de;
                    expected_de=h>=216 && h<1016 && v>=35 && v<515;
                    if(de !== expected_de) $fatal(1,"DE mismatch frame=%0d h=%0d v=%0d",f,h,v);
                    if(hs !== 1 || vs !== 1 || !reset_out) $fatal(1,"DE mode pins wrong");
                    if(!de && rgb !== 0) $fatal(1,"blanking RGB not zero");
                    if(de) begin
                        count=count+1; line_count=line_count+1;
                        px=h-216; py=v-35;
                        if(f==0) $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
                        if(px==0 || px==799 || py==0 || py==479) begin
                            if(rgb !== 24'hffffff) $fatal(1,"edge border missing");
                        end else if(py==160) begin
                            case(px/100)
                                0:expected_rgb=24'hffffff; 1:expected_rgb=24'hffff00;
                                2:expected_rgb=24'h00ffff; 3:expected_rgb=24'h00ff00;
                                4:expected_rgb=24'hff00ff; 5:expected_rgb=24'hff0000;
                                6:expected_rgb=24'h0000ff; 7:expected_rgb=24'h000000;
                            endcase
                            if(rgb !== expected_rgb) $fatal(1,"color bar mismatch x=%0d",px);
                        end
                        if(px==33 && py==24 && rgb!==24'hffffff) $fatal(1,"title glyph missing");
                        if(py==310 && px==16) begin
                            expected_rgb=f==0 ? 24'h00ffb0 : 24'h101c30;
                            if(rgb!==expected_rgb) $fatal(1,"sprite did not move at frame boundary");
                        end
                    end
                    #9;
                    if(rgb!==before_rgb || de!==before_de) $fatal(1,"data changed while pclk high");
                    @(negedge pclk); last_edge=$time;
                end
                if(line_count != ((v>=35 && v<515) ? 800:0)) $fatal(1,"line width mismatch");
            end
            if(count!=384000) $fatal(1,"frame pixel count mismatch");
        end
        $fclose(fd);
        #1;
        if(!bl || frames!=2) $fatal(1,"backlight/frame count mismatch");
        rst_n=0; #1;
        if(bl || de || reset_out || rgb!=0 || frames!=0) $fatal(1,"midstream reset failed");
        #38; rst_n=1;
        wait(reset_out);
        @(negedge pclk); @(posedge pclk); #1;
        if(de || bl || frames!=0 || pattern.sprite_x_q!=16) $fatal(1,"restart failed");
        $display("[PASS] lcd: 2 full frames, 800x480 DE, 25MHz edges, RGB bars, glyph, motion, reset, backlight");
        $finish;
    end
    initial begin #100_000_000; $fatal(1,"LCD simulation timeout"); end
endmodule
