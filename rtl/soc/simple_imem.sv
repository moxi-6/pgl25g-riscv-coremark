module simple_imem #(
    parameter integer WORDS = 4096,
    parameter         INIT_FILE = "software/build/firmware.hex"
) (
    input  logic [31:0] addr_i,
    output logic [31:0] rdata_o
);
    logic [31:0] mem [0:WORDS-1];
    integer index;

    initial begin
        for (index = 0; index < WORDS; index = index + 1) begin
            mem[index] = 32'h0010_0073; // EBREAK beyond the loaded program
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always_comb begin
        if (addr_i[31:2] < WORDS) rdata_o = mem[addr_i[31:2]];
        else rdata_o = 32'h0010_0073;
    end
endmodule

