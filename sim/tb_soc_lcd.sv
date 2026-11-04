`timescale 1ns/1ps
module tb_soc_lcd;
    reg clk=0, rst=0;
    always #5 clk=~clk;
    wire halted, trap;
    wire [127:0] state;
    integer commits=0;
    rv32i_soc #(.IMEM_WORDS(64), .DMEM_WORDS(64), .MEM_FILE(""), .LCD_ENABLE(1)) dut (
        .clk_i(clk), .rst_n_i(rst), .key_i(4'hf), .halted_o(halted), .trap_o(trap), .lcd_state_o(state));
    function [31:0] st(input integer off, f3);
        st={off[11:5],5'd2,5'd1,f3[2:0],off[4:0],7'h23};
    endfunction
    function [31:0] ld(input integer off, rd);
        ld={off[11:0],5'd1,3'd2,rd[4:0],7'h03};
    endfunction
    always @(posedge clk) begin
        if(!rst) commits=0;
        else if(dut.dmem_valid && dut.dmem_ready && dut.dmem_write && dut.dmem_addr==32'h10000030) begin
            commits=commits+1;
            #1;
            if(commits==1 && state!==128'h00000067_00000045_00000123_00000302)
                $fatal(1,"initial bundle not atomic: %h",state);
            if(commits==2 && state!==128'h00000067_00000045_00007f23_00000303)
                $fatal(1,"byte staging/halfword publish failed: %h",state);
        end else if(rst) begin
            #1;
            if(commits==0 && state!==0) $fatal(1,"staging leaked before commit");
            if(commits==1 && state!==128'h00000067_00000045_00000123_00000302)
                $fatal(1,"bundle changed without publish");
        end
    end
    initial begin
        #1;
        dut.u_imem.mem[0]=32'h100000b7;
        dut.u_imem.mem[1]=32'h12300113;
        dut.u_imem.mem[2]=st('h34,2);
        dut.u_imem.mem[3]=32'h04500113;
        dut.u_imem.mem[4]=st('h38,2);
        dut.u_imem.mem[5]=32'h06700113;
        dut.u_imem.mem[6]=st('h3c,2);
        dut.u_imem.mem[7]=32'h30200113;
        dut.u_imem.mem[8]=st('h30,2);
        dut.u_imem.mem[9]=ld('h34,3);
        dut.u_imem.mem[10]=32'h07f00113;
        dut.u_imem.mem[11]=st('h35,0);
        dut.u_imem.mem[12]=ld('h34,4);
        dut.u_imem.mem[13]=32'h0080006f;
        dut.u_imem.mem[14]=st('h30,2);
        dut.u_imem.mem[15]=32'h30300113;
        dut.u_imem.mem[16]=st('h30,1);
        dut.u_imem.mem[17]=ld('h40,5);
        dut.u_imem.mem[18]=32'h00100073;
        repeat(2) begin
            rst=0; repeat(3) @(negedge clk); rst=1;
            wait(halted); @(negedge clk);
            if(trap || commits!=2 || dut.u_core.u_regfile.regs[3]!==32'h123 ||
                dut.u_core.u_regfile.regs[4]!==32'h7f23 || dut.u_core.u_regfile.regs[5]!==0)
                $fatal(1,"CPU MMIO readback/bounds/flush mismatch");
        end
        $display("[PASS] soc_lcd: atomic publish, staged byte/halfword, readback, wrong-path squash, bounds, reset");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
