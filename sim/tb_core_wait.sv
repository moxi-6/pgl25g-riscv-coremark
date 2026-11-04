`include "sim/tb_core.sv"
module tb_core_wait;
    tb_core #(.WAIT_CYCLES(5)) u_test();
endmodule
