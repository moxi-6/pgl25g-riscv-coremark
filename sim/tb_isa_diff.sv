`timescale 1ns/1ps
// Commit-by-commit comparison with an independent Python architectural model.
module tb_isa_diff #(
    parameter bit ZMMUL_ENABLE = 1'b0,
    parameter bit PIPELINE_DECODE = 1'b1,
    parameter bit BITMANIP_ENABLE = 1'b0,
    parameter bit DUAL_ISSUE = 1'b0,
    parameter integer MUL_CYCLES = 3
);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire [31:0] ia, da, wd, cpc, ci, cd;
    wire iv, dv, dw, cv, crw, halted, trap;
    wire [3:0] strb;
    wire [4:0] crd;
    reg irv=0, dr=0;
    reg [31:0] idata=0, rd=0;
    reg [31:0] idata2=0;
    wire cv2,crw2;
    wire [31:0] cpc2,ci2,cd2;
    wire [4:0] crd2;
    wire ir;
    reg [31:0] rom[0:8191], ram[0:255], final_ram[0:255];
    reg [127:0] expected[0:8191];
    reg [31:0] config_words[0:3];
    reg [31:0] saved_ia, saved_da, saved_wd;
    reg saved_dw;
    reg [3:0] saved_strb;
    reg ipending=0, dpending=0;
    reg i_stalled=0, d_stalled=0;
    reg [31:0] stalled_ia, stalled_da, stalled_wd;
    reg stalled_dw;
    reg [3:0] stalled_strb;
    integer itimer=0, dtimer=0, cycles=0, commits=0, reads=0, writes=0;
    integer mode=0, inject_mismatch=0;
    reg [127:0] want;
    string case_dir;
    assign ir=rst_n && !ipending && (mode==0 || cycles%7==6);
    rv32i_core_3stage #(.ZMMUL_ENABLE(ZMMUL_ENABLE), .PIPELINE_DECODE(PIPELINE_DECODE),
        .BITMANIP_ENABLE(BITMANIP_ENABLE),.DUAL_ISSUE(DUAL_ISSUE),.MUL_CYCLES(MUL_CYCLES)) dut (
        .clk_i(clk),.rst_n_i(rst_n),.imem_addr_o(ia),.imem_valid_o(iv),
        .imem_ready_i(ir),.imem_rvalid_i(irv),.imem_rdata_i(idata),
        .imem_rdata_next_i(idata2),
        .dmem_valid_o(dv),.dmem_write_o(dw),.dmem_addr_o(da),
        .dmem_wdata_o(wd),.dmem_wstrb_o(strb),.dmem_rdata_i(rd),.dmem_ready_i(dr),
        .commit_valid_o(cv),.commit_pc_o(cpc),.commit_instr_o(ci),
        .commit_rd_write_o(crw),.commit_rd_o(crd),.commit_data_o(cd),
        .commit2_valid_o(cv2),.commit2_pc_o(cpc2),.commit2_instr_o(ci2),
        .commit2_rd_write_o(crw2),.commit2_rd_o(crd2),.commit2_data_o(cd2),
        .halted_o(halted),.trap_o(trap)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            ipending<=0; dpending<=0; irv<=0; dr<=0;
            cycles=0; commits=0; reads=0; writes=0; i_stalled=0; d_stalled=0;
        end else begin
            if (i_stalled && (!iv || ia!==stalled_ia)) $fatal(1,"unstable instruction request");
            if (d_stalled && (!dv || da!==stalled_da || wd!==stalled_wd || dw!==stalled_dw || strb!==stalled_strb))
                $fatal(1,"unstable data request");
            i_stalled=iv&&!ir; stalled_ia=ia;
            d_stalled=dv&&!dr; stalled_da=da; stalled_wd=wd; stalled_dw=dw; stalled_strb=strb;
            if (cv) begin
                if (commits>=config_words[0]) $fatal(1,"unexpected extra commit pc=%h",cpc);
                want=expected[commits];
                if (cpc!==want[127:96] || ci!==want[95:64] || crw!==want[37])
                    $fatal(1,"commit=%0d pc=%h expected_pc=%h instr=%h expected_instr=%h write=%b expected_write=%b",commits,cpc,want[127:96],ci,want[95:64],crw,want[37]);
                if (crw && (crd!==want[36:32] || cd!==want[31:0]))
                    $fatal(1,"commit=%0d x%0d=%h expected x%0d=%h",commits,crd,cd,want[36:32],want[31:0]);
                commits=commits+1;
            end
            if (dut.u_regfile.regs[0] !== 0) $fatal(1,"x0 changed");
            if (cv2) begin
                if (!cv || commits>=config_words[0]) $fatal(1,"unexpected second commit");
                want=expected[commits];
                if (cpc2!==want[127:96] || ci2!==want[95:64] || crw2!==want[37])
                    $fatal(1,"commit2=%0d pc=%h expected=%h instr=%h expected=%h",commits,cpc2,want[127:96],ci2,want[95:64]);
                if (crw2 && (crd2!==want[36:32] || cd2!==want[31:0]))
                    $fatal(1,"commit2=%0d x%0d=%h expected x%0d=%h",commits,crd2,cd2,want[36:32],want[31:0]);
                commits=commits+1;
            end
            cycles=cycles+1;
            irv<=0;
            if (iv&&ir) begin
                ipending<=1; saved_ia<=ia; itimer<=mode==0?0:2+((ia>>2)%5);
            end
            if (ipending) begin
                if (itimer==0) begin
                    if (saved_ia[1:0]!=0 || saved_ia[31:2]>=8192) idata<=0;
                    else idata<=rom[saved_ia[14:2]];
                    idata2 <= saved_ia[31:2]<8191 ? rom[saved_ia[14:2]+1] : 32'b0;
                    irv<=1; ipending<=0;
                end else itimer<=itimer-1;
            end
            dr<=0;
            if (dv&&!dpending&&!dr) begin
                dpending<=1; saved_da<=da; saved_wd<=wd; saved_dw<=dw; saved_strb<=strb;
                dtimer<=mode==0?0:2+((da>>2)%4)+mode*3;
            end
            if (dpending) begin
                if (dtimer==0) begin
                    if (saved_da[31:2]>=256) $fatal(1,"unexpected out-of-range data request");
                    rd<=ram[saved_da[9:2]];
                    if (saved_dw) begin
                        writes=writes+1;
                        for (integer b=0;b<4;b=b+1)
                            if (saved_strb[b]) ram[saved_da[9:2]][b*8+:8]<=saved_wd[b*8+:8];
                    end else reads=reads+1;
                    dr<=1; dpending<=0;
                end else dtimer<=dtimer-1;
            end
        end
    end
    initial begin
        if (!$value$plusargs("case_dir=%s",case_dir)) $fatal(1,"missing case_dir");
        if (!$value$plusargs("latency_mode=%d",mode)) mode=0;
        if (!$value$plusargs("inject_mismatch=%d",inject_mismatch)) inject_mismatch=0;
        $readmemh({case_dir,"/config.hex"},config_words);
        $readmemh({case_dir,"/program.hex"},rom);
        $readmemh({case_dir,"/initial_ram.hex"},ram);
        $readmemh({case_dir,"/final_ram.hex"},final_ram);
        if (config_words[0]>0) $readmemh({case_dir,"/trace.hex"},expected,0,config_words[0]-1);
        if (inject_mismatch) expected[0][127:96]=32'hffff_fffc;
        repeat(4) @(negedge clk);
        rst_n=1;
        while (!halted && cycles<100000) @(negedge clk);
        if (!halted || trap!==config_words[1][0]) $fatal(1,"termination mismatch trap=%b expected=%b",trap,config_words[1][0]);
        repeat(30) @(negedge clk);
        if (commits!==config_words[0] || reads!==config_words[2] || writes!==config_words[3])
            $fatal(1,"transaction totals commits=%0d/%0d loads=%0d/%0d stores=%0d/%0d",commits,config_words[0],reads,config_words[2],writes,config_words[3]);
        for (integer n=0;n<256;n=n+1)
            if (ram[n]!==final_ram[n]) $fatal(1,"final memory mismatch word=%0d got=%h expected=%h",n,ram[n],final_ram[n]);
        if (iv||dv) $fatal(1,"requests active after halt drain");
        $display("[PASS] isa_diff mode=%0d commits=%0d cycles=%0d loads=%0d stores=%0d trap=%b",mode,commits,cycles,reads,writes,trap);
        $finish;
    end
    initial begin #2000000; $fatal(1,"ISA differential watchdog"); end
endmodule
