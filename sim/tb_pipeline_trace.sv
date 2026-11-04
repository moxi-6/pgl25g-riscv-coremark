`include "sim/tb_core_sync.sv"
// Reuse the real synchronous-fetch stress program; add observation only.
module tb_pipeline_trace;
    tb_core_sync run();
    integer csv;
    initial begin
        csv=$fopen("build/pipeline_trace.csv","w");
        if (!csv) $fatal(1,"cannot create pipeline_trace.csv");
        $fwrite(csv,"time_ns,rst_n,mode,scenario,halted,trap,commit,commit_pc,commit_instr,ex_valid,ex_pc,data_wait,fetch_valid,fetch_request,fetch_ready,data_request,data_ready,redirect\n");
        $dumpfile("build/pipeline_trace.vcd");
        $dumpvars(1,run.dut);
        $dumpvars(1,run.dut.g_sync_fetch);
    end
    always @(negedge run.clk) begin
        $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
            $time,run.rst_n,run.mode,run.scenario,run.halted,run.trap,run.cv,run.cpc,run.ci,
            run.dut.ex_valid_q,run.dut.ex_pc_q,run.dut.ex_wait,run.dut.fetch_valid,
            run.iv,run.ir,run.dv,run.dr,run.dut.redirect);
        $fflush(csv);
    end
endmodule
