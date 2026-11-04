`timescale 1ns/1ps
// Full software/CPU/SoC/GT9147 integration. Only the video frame strobe is
// accelerated; every input still traverses KEY MMIO or the real I2C driver.
module tb_mine;
    `include "build/mine_checks/mine_symbols.svh"
    logic clk=0, rst_n=0;
    logic [3:0] keys=15;
    logic tick=0;
    wire [511:0] state_bus;
    wire uart, halted, trap, scl, sda_o, sda_oe, tp_rst, int_o, int_oe;
    wire [7:0] gpio;
    wire model_oe, model_o;
    wire sda=((sda_oe&&!sda_o)||(model_oe&&!model_o)) ? 1'b0 : 1'b1;
    integer cycles=0, publications=0, assertions=0, i,j,k,level_no, target, bad_flag;
    integer mine_count, active_count, previous_active=81;
    integer previous_mines=0, previous_layout=0, layout=0;
    integer snapshot;
    always #5 clk=~clk;
    always @(negedge clk) begin
        cycles=cycles+1;
        tick=(cycles%5000)==0;
        if(cycles>25_000_000) $fatal(1,"mine integration timeout pc=%h",dut.u_core.ex_pc_q);
        if(trap || halted) $fatal(1,"mine firmware unexpectedly stopped pc=%h trap=%b",dut.u_core.ex_pc_q,trap);
    end
    always @(posedge clk) if(dut.dmem_valid && dut.dmem_ready && dut.dmem_write && dut.dmem_addr==32'h100000e0)
        publications=publications+1;
    rv32i_soc #(.CLOCK_HZ(200000),.BAUD(100000),.MEM_FILE("software/build/mine_sim/firmware.hex"),
        .VIDEO_ENABLE(1),.MINE_ENABLE(1),.TOUCH_ENABLE(1),.TOUCH_SCL_HZ(50000)) dut(
        .clk_i(clk),.rst_n_i(rst_n),.key_i(keys),.uart_tx_o(uart),.gpio_o(gpio),.halted_o(halted),.trap_o(trap),
        .video_frame_i(tick),.video_mine_o(state_bus),.tp_scl_o(scl),.tp_sda_o(sda_o),.tp_sda_oe(sda_oe),
        .tp_sda_i(sda),.tp_int_i(1'b1),.tp_rst_o(tp_rst),.tp_int_o(int_o),.tp_int_oe(int_oe));
    gt9147_model panel(.scl_i(scl),.sda_oe_o(model_oe),.sda_o_o(model_o),.sda_i(sda),.rst_n_i(rst_n));

    function automatic integer byte_at(input integer address);
        reg [31:0] word_value;
        begin word_value=dut.u_dmem.mem[(address-32'h40000000)>>2];
            byte_at=(word_value >> ((address&3)*8))&255; end
    endfunction
    function automatic integer tile_at(input integer index);
        tile_at=state_bus[index*4 +:4];
    endfunction
    task automatic check(input bit condition,input string message);
        if(!condition) $fatal(1,"%s level=%0d cycles=%0d",message,state_bus[391:384],cycles);
        else assertions=assertions+1;
    endtask
    task automatic settled;
        integer before_count,guard;
        begin before_count=publications;guard=0;
            while(publications<before_count+2 && guard<400000) begin @(negedge clk);guard=guard+1;end
            check(guard<400000,"firmware published fresh tile state");
            repeat(5002) @(negedge clk);
        end
    endtask
    task automatic press_key(input integer key_index,input integer hold_frames);
        begin
            @(negedge clk);keys=15^(1<<key_index);
            repeat(hold_frames*5000) @(negedge clk);
            keys=15;settled();
        end
    endtask
    task automatic tap(input integer x,input integer y);
        integer guard;
        begin
            // Deliver the controller's next report after the preceding
            // status-register acknowledgement, just like a scan boundary.
            wait(dut.g_touch.u_touch.state==15 && !dut.g_touch.u_touch.req_busy);
            @(negedge clk);
            $display("[INPUT] tap %0d,%0d cycles=%0d pressed=%b status=%0d",x,y,cycles,dut.tp_pressed,dut.tp_status);
            panel.inject_touch(x,y);guard=0;
            while(!dut.tp_tap && guard<100000) begin @(negedge clk);guard=guard+1;end
            if(guard>=100000) $display("[DEBUG] tp state=%0d pressed=%b acks=%0d status=%0d model_status=%h",dut.g_touch.u_touch.state,dut.tp_pressed,dut.tp_acks,dut.tp_status,panel.regs[11'h14e]);
            check(guard<100000,"I2C touch reached tap latch");
            guard=0;
            while(dut.tp_tap && guard<400000) begin @(negedge clk);guard=guard+1;end
            check(guard<400000,"firmware acknowledged tap latch");
            panel.inject_release();guard=0;
            while(dut.tp_pressed && guard<100000) begin @(negedge clk);guard=guard+1;end
            check(guard<100000,"I2C release detected");
            settled();
        end
    endtask
    task automatic tap_cell(input integer index);
        tap(104+(index%9)*48+24,24+(index/9)*48+24);
    endtask
    task automatic save_state(input string path);
        integer file;
        begin file=$fopen(path,"w");$fdisplay(file,"%0128h",state_bus);$fclose(file);end
    endtask
    task automatic verify_placement(input integer safe);
        integer n,r,c;
        begin
            mine_count=0;active_count=0;layout=0;
            for(n=0;n<81;n=n+1) begin
                mine_count=mine_count+byte_at(ADDR_MINE+n);
                active_count=active_count+!byte_at(ADDR_BLOCKED+n);
                layout=layout^(byte_at(ADDR_MINE+n)<<(n%30));
                check(!(byte_at(ADDR_BLOCKED+n)&&byte_at(ADDR_MINE+n)),"walls never contain mines");
                r=n/9;c=n%9;
                if(r>=safe/9-1 && r<=safe/9+1 && c>=safe%9-1 && c<=safe%9+1)
                    check(byte_at(ADDR_MINE+n)==0,"first touch and its neighbours are safe");
            end
            check(mine_count==state_bus[399:392],"exact configured mine count");
            check(tile_at(safe)==9,"first touch opens a blank region");
            check(state_bus[415:408]==active_count-mine_count-state_bus[487:480],"safe-cell HUD accounting");
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        wait(dut.tp_status==1);settled();
        check(dut.tp_acks==0,"GT9147 initialized without bus errors");
        check(state_bus[391:384]==1 && state_bus[399:392]==10,"initial stage and difficulty");
        save_state("build/mine_checks/initial.hex");
        press_key(0,4);check(state_bus[355:352]==3,"KEY0 left");
        press_key(1,4);check(state_bus[355:352]==4,"KEY1 right");
        press_key(2,4);check(state_bus[359:356]==5,"KEY2 down");
        press_key(3,4);verify_placement(49);
        tap(720,436);check(state_bus[457]==0,"touch restart clears placement");
        tap(720,380);check(state_bus[456]==1,"touch switches to flag mode");
        tap_cell(0);check(tile_at(0)==10 && state_bus[407:400]==1 && !state_bus[457],"flag before first open");
        tap_cell(0);check(tile_at(0)==0 && state_bus[407:400]==0,"touch removes flag");
        tap(720,380);tap_cell(40);verify_placement(40);
        target=-1;bad_flag=-1;
        for(i=0;i<81;i=i+1) begin
            if(byte_at(ADDR_MINE+i)) target=i;
            else if(tile_at(i)==0) bad_flag=i;
        end
        check(target>=0 && bad_flag>=0,"test board contains covered mine and safe cell");
        tap(720,380);tap_cell(target);check(tile_at(target)==10,"touch flags a mine");
        press_key(3,21);check(tile_at(target)==0,"KEY3 hold toggles flag");
        tap_cell(bad_flag);check(tile_at(bad_flag)==10,"wrong flag prepared");
        tap(720,380);tap_cell(target);
        check(state_bus[458] && tile_at(target)==12,"mine touch loses and marks blast");
        check(tile_at(bad_flag)==13,"loss distinguishes wrong flag");
        for(i=0;i<81;i=i+1) if(byte_at(ADDR_MINE+i)) check(tile_at(i)==11 || tile_at(i)==12,"loss reveals every mine");
        save_state("build/mine_checks/lost.hex");
        repeat(150000) @(negedge clk);check(state_bus[458],"finished board stays until explicit restart");
        press_key(0,4);check(!state_bus[458] && !state_bus[457],"key restarts failed stage");
        // White-box selection only observes RAM to choose safe inputs. It never
        // modifies firmware state, CPU memory, tiles, or the touch driver.
        for(level_no=1;level_no<=8;level_no=level_no+1) begin
            check(state_bus[391:384]==level_no,"stage progression");
            tap_cell(40);verify_placement(40);
            check(mine_count>previous_mines,"difficulty increases mine count");
            previous_mines=mine_count;
            if(level_no>1) check(layout!=previous_layout,"new stage changes mine layout");
            previous_layout=layout;
            if(level_no==2) check(active_count<81,"second map changes traversable terrain");
            if(level_no==3) save_state("build/mine_checks/stage3.hex");
            for(i=0;i<81;i=i+1)
                if(!byte_at(ADDR_MINE+i) && !byte_at(ADDR_BLOCKED+i) && !byte_at(ADDR_OPEN_CELL+i)) tap_cell(i);
            check(state_bus[459] && state_bus[415:408]==0,"all safe cells produce victory");
            $display("[PASS] mine stage=%0d mines=%0d active=%0d cycles=%0d",level_no,mine_count,active_count,cycles);
            if(level_no==8) save_state("build/mine_checks/won.hex");
            tap(720,436);
        end
        check(state_bus[391:384]==1 && !state_bus[457],"eighth stage wraps to fresh first stage");
        check(dut.tp_acks==0,"no I2C errors after all gameplay");
        $display("[PASS] mine_integration assertions=%0d cycles=%0d publications=%0d stages=8",assertions,cycles,publications);
        $finish;
    end
endmodule
