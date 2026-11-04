`timescale 1ns/1ps
module tb_shooter_display;
    reg clk=0;
    always #5 clk=~clk;
    reg [9:0] x=1023;
    reg [8:0] y=511;
    reg [1023:0] sprites=0;
    reg [127:0] hud=128'h00001234_00003456_00000020_03010300;
    wire [23:0] rgb;
    lcd_shooter_display dut(.clk_i(clk),.x_i(x),.y_i(y),.sprites_i(sprites),.hud_i(hud),.rgb_o(rgb));
    integer fd,xx,yy,mode,bright=0;
    initial begin
        for(mode=0;mode<2;mode=mode+1)begin
            if(mode==0)fd=$fopen("build/shooter_title.ppm","wb");
            else begin
                fd=$fopen("build/shooter_play.ppm","wb");hud[3:0]=1;
                sprites[63:0]={32'h00001c14,32'h91940030};
                sprites[127:64]={32'h00001818,32'ha1980140};
                sprites[191:128]={32'h00000408,32'hb1a000a0};
            end
            if(!fd)$fatal(1,"frame open failed");
            $fwrite(fd,"P6\n800 480\n255\n");
            for(yy=0;yy<480;yy=yy+1)for(xx=0;xx<800;xx=xx+1)begin
                @(negedge clk);x=xx;y=yy;@(posedge clk);#1;
                if(^rgb===1'bx)$fatal(1,"unknown pixel");
                if(xx>=648 && yy<48 && rgb==24'hf4f7ff)bright=bright+1;
                $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
            end
            $fclose(fd);
        end
        if(bright<100)$fatal(1,"Chinese glyphs missing");
        $display("[PASS] shooter_display: synchronous Chinese font ROM and two complete renderings");$finish;
    end
endmodule
