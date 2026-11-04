`timescale 1ns/1ps
module tb_mine_render;
    reg clk=0;
    reg [9:0] x=0;
    reg [8:0] y=0;
    reg [511:0] state_data[0:0];
    wire [23:0] rgb;
    integer fd,xx,yy;
    string state_path,ppm_path;
    lcd_mine_display dut(.clk_i(clk),.x_i(x),.y_i(y),.mine_i(state_data[0]),.rgb_o(rgb));
    initial begin
        if(!$value$plusargs("state=%s",state_path) || !$value$plusargs("ppm=%s",ppm_path)) $fatal(1,"need state and ppm");
        $readmemh(state_path,state_data);
        fd=$fopen(ppm_path,"wb");$fwrite(fd,"P6\n800 480\n255\n");
        for(yy=0;yy<480;yy=yy+1) for(xx=0;xx<800;xx=xx+1) begin
            x=xx;y=yy;clk=0;#1;clk=1;#1;
            if(^rgb===1'bx) $fatal(1,"unknown rendered pixel x=%0d y=%0d",xx,yy);
            $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
        end
        $fclose(fd);$display("[PASS] mine_render %s",ppm_path);$finish;
    end
endmodule
