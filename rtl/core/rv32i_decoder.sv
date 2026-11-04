module rv32i_decoder #(
    parameter bit ZMMUL_ENABLE = 1'b0,
    parameter bit BITMANIP_ENABLE = 1'b0
) (
    input  logic [31:0]                  instr_i,
    output logic [4:0]                   rs1_o,
    output logic [4:0]                   rs2_o,
    output logic [4:0]                   rd_o,
    output logic                         reg_write_o,
    output logic [5:0] alu_op_o,
    output logic                         alu_lhs_pc_o,
    output logic                         alu_rhs_imm_o,
    output logic [31:0]                  imm_o,
    output logic [2:0] branch_op_o,
    output logic                         jump_o,
    output logic                         jalr_o,
    output logic                         mem_read_o,
    output logic                         mem_write_o,
    output logic [1:0] mem_size_o,
    output logic                         load_unsigned_o,
    output logic                         illegal_o,
    output logic                         ebreak_o
);
    import rv32i_pkg::*;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_u;
    logic [31:0] imm_j;

    assign opcode = instr_i[6:0];
    assign funct3 = instr_i[14:12];
    assign funct7 = instr_i[31:25];
    assign rs1_o  = instr_i[19:15];
    assign rs2_o  = instr_i[24:20];
    assign rd_o   = instr_i[11:7];

    rv32i_imm_gen u_imm_gen (
        .instr_i (instr_i),
        .imm_i_o (imm_i),
        .imm_s_o (imm_s),
        .imm_b_o (imm_b),
        .imm_u_o (imm_u),
        .imm_j_o (imm_j)
    );

    always_comb begin
        reg_write_o     = 1'b0;
        alu_op_o        = ALU_ADD;
        alu_lhs_pc_o    = 1'b0;
        alu_rhs_imm_o   = 1'b0;
        imm_o           = 32'b0;
        branch_op_o     = BR_NONE;
        jump_o          = 1'b0;
        jalr_o          = 1'b0;
        mem_read_o      = 1'b0;
        mem_write_o     = 1'b0;
        mem_size_o      = MEM_WORD;
        load_unsigned_o = 1'b0;
        illegal_o       = 1'b0;
        ebreak_o        = 1'b0;

        unique case (opcode)
            7'b0110111: begin // LUI
                reg_write_o   = 1'b1;
                alu_op_o      = ALU_COPY_B;
                alu_rhs_imm_o = 1'b1;
                imm_o         = imm_u;
            end

            7'b0010111: begin // AUIPC
                reg_write_o   = 1'b1;
                alu_op_o      = ALU_ADD;
                alu_lhs_pc_o  = 1'b1;
                alu_rhs_imm_o = 1'b1;
                imm_o         = imm_u;
            end

            7'b1101111: begin // JAL
                reg_write_o = 1'b1;
                jump_o      = 1'b1;
                imm_o       = imm_j;
            end

            7'b1100111: begin // JALR
                if (funct3 == 3'b000) begin
                    reg_write_o = 1'b1;
                    jump_o      = 1'b1;
                    jalr_o      = 1'b1;
                    imm_o       = imm_i;
                end else begin
                    illegal_o = 1'b1;
                end
            end

            7'b1100011: begin // BRANCH
                imm_o = imm_b;
                unique case (funct3)
                    3'b000: branch_op_o = BR_EQ;
                    3'b001: branch_op_o = BR_NE;
                    3'b100: branch_op_o = BR_LT;
                    3'b101: branch_op_o = BR_GE;
                    3'b110: branch_op_o = BR_LTU;
                    3'b111: branch_op_o = BR_GEU;
                    default: illegal_o = 1'b1;
                endcase
            end

            7'b0000011: begin // LOAD
                reg_write_o   = 1'b1;
                mem_read_o    = 1'b1;
                alu_op_o      = ALU_ADD;
                alu_rhs_imm_o = 1'b1;
                imm_o         = imm_i;
                unique case (funct3)
                    3'b000: mem_size_o = MEM_BYTE; // LB
                    3'b001: mem_size_o = MEM_HALF; // LH
                    3'b010: mem_size_o = MEM_WORD; // LW
                    3'b100: begin mem_size_o = MEM_BYTE; load_unsigned_o = 1'b1; end
                    3'b101: begin mem_size_o = MEM_HALF; load_unsigned_o = 1'b1; end
                    default: illegal_o = 1'b1;
                endcase
            end

            7'b0100011: begin // STORE
                mem_write_o   = 1'b1;
                alu_op_o      = ALU_ADD;
                alu_rhs_imm_o = 1'b1;
                imm_o         = imm_s;
                unique case (funct3)
                    3'b000: mem_size_o = MEM_BYTE;
                    3'b001: mem_size_o = MEM_HALF;
                    3'b010: mem_size_o = MEM_WORD;
                    default: illegal_o = 1'b1;
                endcase
            end

            7'b0010011: begin // OP-IMM
                reg_write_o   = 1'b1;
                alu_rhs_imm_o = 1'b1;
                imm_o         = imm_i;
                unique case (funct3)
                    3'b000: alu_op_o = ALU_ADD;  // ADDI
                    3'b010: alu_op_o = ALU_SLT;  // SLTI
                    3'b011: alu_op_o = ALU_SLTU; // SLTIU
                    3'b100: alu_op_o = ALU_XOR;  // XORI
                    3'b110: alu_op_o = ALU_OR;   // ORI
                    3'b111: alu_op_o = ALU_AND;  // ANDI
                    3'b001: begin
                        alu_op_o = ALU_SLL;
                        if (funct7 != 7'b0000000) illegal_o = 1'b1;
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) alu_op_o = ALU_SRL;
                        else if (funct7 == 7'b0100000) alu_op_o = ALU_SRA;
                        else illegal_o = 1'b1;
                    end
                    default: illegal_o = 1'b1;
                endcase
            end

            7'b0110011: begin // OP
                reg_write_o = 1'b1;
                if (ZMMUL_ENABLE && funct7 == 7'b0000001 && !funct3[2]) begin
                    case (funct3[1:0])
                        2'b00: alu_op_o = ALU_MUL;
                        2'b01: alu_op_o = ALU_MULH;
                        2'b10: alu_op_o = ALU_MULHSU;
                        2'b11: alu_op_o = ALU_MULHU;
                    endcase
                end else begin
                unique case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0000000) alu_op_o = ALU_ADD;
                        else if (funct7 == 7'b0100000) alu_op_o = ALU_SUB;
                        else illegal_o = 1'b1;
                    end
                    3'b001: begin alu_op_o = ALU_SLL;  if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    3'b010: begin alu_op_o = ALU_SLT;  if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    3'b011: begin alu_op_o = ALU_SLTU; if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    3'b100: begin alu_op_o = ALU_XOR;  if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    3'b101: begin
                        if (funct7 == 7'b0000000) alu_op_o = ALU_SRL;
                        else if (funct7 == 7'b0100000) alu_op_o = ALU_SRA;
                        else illegal_o = 1'b1;
                    end
                    3'b110: begin alu_op_o = ALU_OR;  if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    3'b111: begin alu_op_o = ALU_AND; if (funct7 != 7'b0000000) illegal_o = 1'b1; end
                    default: illegal_o = 1'b1;
                endcase
                end
            end

            7'b0001111: begin // FENCE: teaching core treats it as a NOP
                if (funct3 != 3'b000) illegal_o = 1'b1;
            end

            7'b1110011: begin // SYSTEM
                if (instr_i == 32'h0010_0073) ebreak_o = 1'b1;
                else illegal_o = 1'b1;
            end

            default: illegal_o = 1'b1;
        endcase

        // Standard RV32 Zba/Zbb encodings override only exact matches. All
        // other reserved encodings retain the base decoder's illegal status.
        if (BITMANIP_ENABLE) begin
            if (opcode == 7'h33) begin
                case ({funct7,funct3})
                    {7'h10,3'h2}: begin alu_op_o=ALU_SH1ADD; illegal_o=0; end
                    {7'h10,3'h4}: begin alu_op_o=ALU_SH2ADD; illegal_o=0; end
                    {7'h10,3'h6}: begin alu_op_o=ALU_SH3ADD; illegal_o=0; end
                    {7'h20,3'h7}: begin alu_op_o=ALU_ANDN; illegal_o=0; end
                    {7'h20,3'h6}: begin alu_op_o=ALU_ORN; illegal_o=0; end
                    {7'h20,3'h4}: begin alu_op_o=ALU_XNOR; illegal_o=0; end
                    {7'h05,3'h4}: begin alu_op_o=ALU_MIN; illegal_o=0; end
                    {7'h05,3'h5}: begin alu_op_o=ALU_MINU; illegal_o=0; end
                    {7'h05,3'h6}: begin alu_op_o=ALU_MAX; illegal_o=0; end
                    {7'h05,3'h7}: begin alu_op_o=ALU_MAXU; illegal_o=0; end
                    {7'h30,3'h1}: begin alu_op_o=ALU_ROL; illegal_o=0; end
                    {7'h30,3'h5}: begin alu_op_o=ALU_ROR; illegal_o=0; end
                    {7'h04,3'h4}: if (rs2_o==0) begin alu_op_o=ALU_ZEXTH; illegal_o=0; end
                    default: begin end
                endcase
            end else if (opcode == 7'h13) begin
                case ({instr_i[31:20],funct3})
                    {12'h600,3'h1}: begin alu_op_o=ALU_CLZ; illegal_o=0; end
                    {12'h601,3'h1}: begin alu_op_o=ALU_CTZ; illegal_o=0; end
                    {12'h602,3'h1}: begin alu_op_o=ALU_CPOP; illegal_o=0; end
                    {12'h604,3'h1}: begin alu_op_o=ALU_SEXTB; illegal_o=0; end
                    {12'h605,3'h1}: begin alu_op_o=ALU_SEXTH; illegal_o=0; end
                    {12'h287,3'h5}: begin alu_op_o=ALU_ORCB; illegal_o=0; end
                    {12'h698,3'h5}: begin alu_op_o=ALU_REV8; illegal_o=0; end
                    default: begin end
                endcase
                if (funct7==7'h30 && funct3==3'h5) begin alu_op_o=ALU_ROR; illegal_o=0; end
            end
        end
        if (illegal_o) begin
            reg_write_o = 1'b0;
            mem_read_o  = 1'b0;
            mem_write_o = 1'b0;
            jump_o      = 1'b0;
            branch_op_o = BR_NONE;
        end
    end
endmodule
