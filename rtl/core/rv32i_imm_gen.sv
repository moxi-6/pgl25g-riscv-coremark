module rv32i_imm_gen (
    input  logic [31:0] instr_i,
    output logic [31:0] imm_i_o,
    output logic [31:0] imm_s_o,
    output logic [31:0] imm_b_o,
    output logic [31:0] imm_u_o,
    output logic [31:0] imm_j_o
);
    always_comb begin
        imm_i_o = {{20{instr_i[31]}}, instr_i[31:20]};
        imm_s_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        imm_b_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                   instr_i[30:25], instr_i[11:8], 1'b0};
        imm_u_o = {instr_i[31:12], 12'b0};
        imm_j_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                   instr_i[20], instr_i[30:21], 1'b0};
    end
endmodule

