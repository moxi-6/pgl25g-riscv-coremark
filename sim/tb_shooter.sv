`timescale 1ns/1ps
module tb_shooter;
    reg clk=0,rst=0;
    always #5 clk=~clk;
    reg [3:0] keys=15;
    reg frame=0;
    wire [1023:0] sprites;
    wire [127:0] hud;
    wire trap,halted;
    integer count=0,frames=0,jump_seen=0,hit_seen=0;
    rv32i_soc #(.CLOCK_HZ(1000000),.BAUD(100000),.MEM_FILE("software/build/shooter/firmware.hex"),
        .LCD_ENABLE(1),.VIDEO_ENABLE(1)) dut(.clk_i(clk),.rst_n_i(rst),.key_i(keys),
        .trap_o(trap),.halted_o(halted),.video_frame_i(frame),.video_sprites_o(sprites),.video_hud_o(hud));
    always @(negedge clk) begin
        if(!rst)begin count=0;frame=0;end
        else if(count==11999)begin count=0;frame=1;frames=frames+1;end
        else begin count=count+1;frame=0;end
        if(rst && (trap || halted))$fatal(1,"CPU stopped");
        if(hud[3:0]==1 && sprites[24:16]<390)jump_seen=1;
        if(hud[47:32]!=0)hit_seen=1;
        if(frames>400)$fatal(1,"shooter progression timeout state=%h",hud);
    end
    task wait_frames(input integer n);
        integer limit;
        begin limit=frames+n;wait(frames>=limit);@(negedge clk);end
    endtask
    reg [1023:0] last_sprites;
    reg [127:0] last_hud;
    always @(posedge clk)begin
        if(rst)begin
            last_sprites=sprites;last_hud=hud;
            if(!frame)begin #1;if(sprites!==last_sprites || hud!==last_hud)$fatal(1,"video changed outside frame boundary");end
        end
    end
    initial begin
        repeat(5)@(negedge clk);rst=1;
        wait_frames(3);
        if(hud[3:0]!==0)$fatal(1,"title state missing");
        keys=7;wait_frames(2);keys=15;wait_frames(3);
        if(hud[3:0]!==1 || hud[11:8]!=3)$fatal(1,"game did not start");
        keys=11;wait_frames(2);keys=15;wait_frames(30);
        if(!jump_seen)$fatal(1,"jump not observed");
        keys=7;
        wait(hud[27:24]==0 && hud[3:0]==1);
        keys=15;wait_frames(2);
        if(!hit_seen || hud[47:32]!=16'h0030)$fatal(1,"shooting/score mismatch %h",hud);
        keys=13;
        wait(hud[19:16]==2);
        keys=15;wait_frames(2);
        if(hud[11:8]!=3 || hud[27:24]!=3)$fatal(1,"level reset mismatch");
        if(hud[95:64]==0 || hud[127:96]==0)$fatal(1,"performance counters missing");
        $display("[PASS] shooter: real RV32I title/start/jump/fire/3 kills/score30/next-level/frame-atomic/perf");
        $finish;
    end
endmodule
