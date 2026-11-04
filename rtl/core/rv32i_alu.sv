module rv32i_alu (
    input  logic [31:0]             lhs_i,
    input  logic [31:0]             rhs_i,
    input  logic [5:0]       op_i,
    output logic [31:0]             result_o
);
    import rv32i_pkg::*;
    integer bit_index;
    logic [5:0] leading_zeros, trailing_zeros, population;
    always_comb begin
        leading_zeros=32;
        trailing_zeros=32;
        population=0;
        for (bit_index=0;bit_index<32;bit_index=bit_index+1) begin
            if (lhs_i[bit_index]) leading_zeros=31-bit_index;
            if (lhs_i[31-bit_index]) trailing_zeros=31-bit_index;
            population=population+{5'b0,lhs_i[bit_index]};
        end
    end

    always_comb begin
        result_o = 32'b0;
        unique case (op_i)
            ALU_ADD:    result_o = lhs_i + rhs_i;
            ALU_SUB:    result_o = lhs_i - rhs_i;
            ALU_SLL:    result_o = lhs_i << rhs_i[4:0];
            ALU_SLT:    result_o = {31'b0, $signed(lhs_i) < $signed(rhs_i)};
            ALU_SLTU:   result_o = {31'b0, lhs_i < rhs_i};
            ALU_XOR:    result_o = lhs_i ^ rhs_i;
            ALU_SRL:    result_o = lhs_i >> rhs_i[4:0];
            ALU_SRA:    result_o = $signed(lhs_i) >>> rhs_i[4:0];
            ALU_OR:     result_o = lhs_i | rhs_i;
            ALU_AND:    result_o = lhs_i & rhs_i;
            ALU_COPY_B: result_o = rhs_i;
            ALU_SH1ADD: result_o = (lhs_i << 1) + rhs_i;
            ALU_SH2ADD: result_o = (lhs_i << 2) + rhs_i;
            ALU_SH3ADD: result_o = (lhs_i << 3) + rhs_i;
            ALU_ANDN: result_o = lhs_i & ~rhs_i;
            ALU_ORN: result_o = lhs_i | ~rhs_i;
            ALU_XNOR: result_o = ~(lhs_i ^ rhs_i);
            ALU_CLZ: result_o = {26'b0,leading_zeros};
            ALU_CTZ: result_o = {26'b0,trailing_zeros};
            ALU_CPOP: result_o = {26'b0,population};
            ALU_MIN: result_o = $signed(lhs_i)<$signed(rhs_i) ? lhs_i:rhs_i;
            ALU_MAX: result_o = $signed(lhs_i)>$signed(rhs_i) ? lhs_i:rhs_i;
            ALU_MINU: result_o = lhs_i<rhs_i ? lhs_i:rhs_i;
            ALU_MAXU: result_o = lhs_i>rhs_i ? lhs_i:rhs_i;
            ALU_SEXTB: result_o = {{24{lhs_i[7]}},lhs_i[7:0]};
            ALU_SEXTH: result_o = {{16{lhs_i[15]}},lhs_i[15:0]};
            ALU_ZEXTH: result_o = {16'b0,lhs_i[15:0]};
            ALU_ROL: result_o = (lhs_i << rhs_i[4:0]) | (lhs_i >> (32-{1'b0,rhs_i[4:0]}));
            ALU_ROR: result_o = (lhs_i >> rhs_i[4:0]) | (lhs_i << (32-{1'b0,rhs_i[4:0]}));
            ALU_ORCB: result_o = {{8{|lhs_i[31:24]}},{8{|lhs_i[23:16]}},{8{|lhs_i[15:8]}},{8{|lhs_i[7:0]}}};
            ALU_REV8: result_o = {lhs_i[7:0],lhs_i[15:8],lhs_i[23:16],lhs_i[31:24]};
            default:    result_o = 32'b0;
        endcase
    end
endmodule

