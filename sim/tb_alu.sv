`timescale 1ns/1ps

module tb_alu;
    import rv32i_pkg::*;

    logic [31:0] lhs;
    logic [31:0] rhs;
    logic [3:0]     op;
    logic [31:0] result;

    rv32i_alu dut (
        .lhs_i    (lhs),
        .rhs_i    (rhs),
        .op_i     (op),
        .result_o (result)
    );

    task automatic check(
        input logic [3:0] test_op,
        input logic [31:0] test_lhs,
        input logic [31:0] test_rhs,
        input logic [31:0] expected
    );
        begin
            op  = test_op;
            lhs = test_lhs;
            rhs = test_rhs;
            #1;
            if (result !== expected) begin
                $fatal(1, "ALU mismatch: op=%0d lhs=%h rhs=%h got=%h expected=%h",
                       test_op, test_lhs, test_rhs, result, expected);
            end
        end
    endtask

    initial begin
        check(ALU_ADD,    32'd10,        32'd20, 32'd30);
        check(ALU_SUB,    32'd10,        32'd20, 32'hffff_fff6);
        check(ALU_SLL,    32'h0000_0001, 32'd31, 32'h8000_0000);
        check(ALU_SLT,    32'hffff_ffff, 32'd1,  32'd1);
        check(ALU_SLTU,   32'hffff_ffff, 32'd1,  32'd0);
        check(ALU_XOR,    32'ha5a5_0000, 32'hffff_00ff, 32'h5a5a_00ff);
        check(ALU_SRL,    32'h8000_0000, 32'd31, 32'd1);
        check(ALU_SRA,    32'h8000_0000, 32'd31, 32'hffff_ffff);
        check(ALU_OR,     32'h0f00_0000, 32'h00f0_0000, 32'h0ff0_0000);
        check(ALU_AND,    32'hffff_00ff, 32'h0f0f_0f0f, 32'h0f0f_000f);
        check(ALU_COPY_B, 32'hdead_beef, 32'h1234_5678, 32'h1234_5678);

        $display("[PASS] rv32i_alu");
        $finish;
    end
endmodule

