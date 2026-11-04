module rv32i_regfile (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic [4:0]  rs1_addr_i,
    input  logic [4:0]  rs2_addr_i,
    output logic [31:0] rs1_data_o,
    output logic [31:0] rs2_data_o,
    input  logic        write_en_i,
    input  logic [4:0]  rd_addr_i,
    input  logic [31:0] rd_data_i
    ,input logic [4:0] rs3_addr_i, rs4_addr_i
    ,output logic [31:0] rs3_data_o, rs4_data_o
    ,input logic write2_en_i
    ,input logic [4:0] rd2_addr_i
    ,input logic [31:0] rd2_data_i
);
    logic [31:0] regs [0:31];
    integer index;

    always_comb begin
        rs1_data_o = (rs1_addr_i == 5'd0) ? 32'b0 : regs[rs1_addr_i];
        rs2_data_o = (rs2_addr_i == 5'd0) ? 32'b0 : regs[rs2_addr_i];
        rs3_data_o = (rs3_addr_i == 5'd0) ? 32'b0 : regs[rs3_addr_i];
        rs4_data_o = (rs4_addr_i == 5'd0) ? 32'b0 : regs[rs4_addr_i];
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (index = 0; index < 32; index = index + 1) begin
                regs[index] <= 32'b0;
            end
        end else begin
            if (write_en_i && (rd_addr_i != 5'd0)) begin
                regs[rd_addr_i] <= rd_data_i;
            end
            if (write2_en_i && (rd2_addr_i != 5'd0)) regs[rd2_addr_i] <= rd2_data_i;
            regs[0] <= 32'b0;
        end
    end
endmodule

