`timescale 1ns/1ps
module tb_lcd_game_display;
    reg clk=0,rst=1,tick=0;
    always #5 clk=~clk;
    reg [9:0] x=0;
    reg [8:0] y=0;
    reg [127:0] state=0;
    reg [31:0] cycles=32'h01234567,instret=32'h000abcde;
    wire [23:0] rgb;
    lcd_game_display dut(.clk_i(clk), .rst_n_i(rst), .frame_tick_i(tick),
        .x_i(x),.y_i(y),.state_i(state),.cycles_i(cycles),.instret_i(instret),
        .gpio_i(4'b0100),.trap_i(1'b0),.rgb_o(rgb));
    integer fd,xx,yy;
    task character(input integer row,col,input [7:0] expected);
        begin x=16+col*32; y=8+row*64; #1;
            if(dut.ch!==expected) $fatal(1,"HUD char row=%0d col=%0d expected=%c actual=%c",row,col,expected,dut.ch);
        end
    endtask
    initial begin
        #1; rst=0; #10; rst=1;
        state=128'h00000248_00030005_00000317_00000203;
        @(negedge clk); tick=1; @(negedge clk); tick=0;
        character(2,11,"2"); character(2,20,"0"); character(2,21,"5");
        character(3,5,"0"); character(3,6,"3");
        character(3,15,"0"); character(3,16,"3"); character(3,17,"1"); character(3,18,"7");
        character(4,6,"2"); character(4,7,"4"); character(4,8,"8");
        character(5,8,"0"); character(5,15,"7"); character(6,15,"E");
        state=0; cycles=0; instret=0;
        repeat(5) @(negedge clk);
        if(dut.state_q!==128'h00000248_00030005_00000317_00000203)
            $fatal(1,"mid-frame input change tore snapshot");
        fd=$fopen("build/lcd_game_frame.ppm","wb");
        if(!fd) $fatal(1,"cannot open frame");
        $fwrite(fd,"P6\n800 480\n255\n");
        for(yy=0;yy<480;yy=yy+1) for(xx=0;xx<800;xx=xx+1) begin
            x=xx;y=yy;#1;$fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
        end
        $fclose(fd);
        @(negedge clk);tick=1;@(negedge clk);tick=0;
        if(dut.state_q!==0 || dut.cycles_q!==0 || dut.instret_q!==0) $fatal(1,"next frame did not update");
        $display("[PASS] lcd_game_display: BCD/hex fields and atomic frame snapshots"); $finish;
    end
endmodule
