`timescale 1ns/1ps
module tb_soc_memory #(parameter bit FAST_DMEM = 1'b0);
    localparam integer BIT_NS = 100;
    logic clk = 0, rst_n = 0;
    wire uart_txd, halted, trap;
    wire [7:0] gpio;
    integer serial_count = 0, uart_writes = 0, gpio_writes = 0, ram_requests = 0;
    logic [7:0] value;
    rv32i_soc #(.CLOCK_HZ(1_000_000), .BAUD(100_000), .IMEM_WORDS(64),
        .DMEM_WORDS(64), .MEM_FILE(""), .FAST_DMEM(FAST_DMEM)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );
    always #5 clk = ~clk;
    `include "sim/uart_receive.svh"
    function automatic [31:0] imm(input integer n, rs1, f3, dest, opcode);
        imm = {n[11:0], rs1[4:0], f3[2:0], dest[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] store(input integer n, rs2, rs1, f3);
        store = {n[11:5], rs2[4:0], rs1[4:0], f3[2:0], n[4:0], 7'h23};
    endfunction
    initial forever begin
        receive_byte(value);
        if (value !== "Z") $fatal(1, "Unexpected serial data: %h", value);
        serial_count = serial_count + 1;
    end
    always @(posedge clk) if (rst_n) begin
        if (dut.uart_valid) uart_writes = uart_writes + 1;
        if (dut.dmem_valid && dut.dmem_write && dut.dmem_ready && dut.gpio_selected && dut.dmem_wstrb[0])
            gpio_writes = gpio_writes + 1;
        if (dut.u_dmem.access_en) ram_requests = ram_requests + 1;
    end
    initial begin
        #100000; $fatal(1, "SoC memory/MMIO timeout");
    end
    initial begin
        #1;
        dut.u_imem.mem[0] = 32'h100000b7; // LUI x1,0x10000
        dut.u_imem.mem[1] = imm(90, 0, 0, 2, 'h13);
        dut.u_imem.mem[2] = store(0, 2, 0, 2);
        dut.u_imem.mem[3] = imm(0, 0, 2, 3, 3);
        dut.u_imem.mem[4] = 32'h00218463; // BEQ x3,x2,+8
        dut.u_imem.mem[5] = store(0, 2, 1, 2); // Wrong-path GPIO
        dut.u_imem.mem[6] = store(5, 2, 1, 0); // UART high byte: no send
        dut.u_imem.mem[7] = store(1, 2, 1, 0); // GPIO high byte: no change
        dut.u_imem.mem[8] = store(4, 3, 1, 0);
        dut.u_imem.mem[9] = imm(90, 0, 0, 4, 'h13);
        dut.u_imem.mem[10] = store(0, 4, 1, 2);
        dut.u_imem.mem[11] = 32'h0080006f; // JAL x0,+8
        dut.u_imem.mem[12] = store(4, 2, 1, 2); // Wrong-path UART
        dut.u_imem.mem[13] = store(4, 2, 1, 0); // Wait for previous frame
        dut.u_imem.mem[14] = imm(165, 0, 0, 5, 'h13);
        dut.u_imem.mem[15] = store(0, 5, 1, 0);
        dut.u_imem.mem[16] = 32'h20000337; // LUI x6,0x20000: read-only ROM alias
        dut.u_imem.mem[17] = imm(160, 6, 2, 7, 3);
        dut.u_imem.mem[18] = store(4, 7, 0, 2);
        dut.u_imem.mem[19] = store(160, 2, 6, 2); // ROM write must be ignored
        dut.u_imem.mem[20] = imm(160, 6, 2, 8, 3);
        dut.u_imem.mem[21] = imm(163, 6, 4, 9, 3); // Upper byte load: 0xaa
        dut.u_imem.mem[22] = imm(256, 6, 2, 10, 3); // Beyond ROM window: zero
        dut.u_imem.mem[40] = 32'haabbccdd;
        repeat (3) @(negedge clk); rst_n = 1;
        wait (halted);
        repeat (250) @(negedge clk); // Finish last frame and detect extras
        if (trap || gpio !== 8'ha5) $fatal(1, "Integrated SoC result mismatch");
        if (serial_count != 2 || uart_writes != 2 || gpio_writes != 2 || ram_requests != 3)
            $fatal(1, "Repeated/wrong-path side effects serial=%0d uart=%0d gpio=%0d ram=%0d", serial_count, uart_writes, gpio_writes, ram_requests);
        if (dut.u_dmem.mem[0] !== 90) $fatal(1, "Integrated synchronous RAM mismatch");
        if (dut.u_dmem.mem[1] !== 32'haabbccdd || dut.u_imem.mem[40] !== 32'haabbccdd ||
            dut.u_core.u_regfile.regs[7] !== 32'haabbccdd || dut.u_core.u_regfile.regs[8] !== 32'haabbccdd ||
            dut.u_core.u_regfile.regs[9] !== 32'haa || dut.u_core.u_regfile.regs[10] !== 0)
            $fatal(1, "ROM data alias/read-only/bounds mismatch");
        $display("[PASS] rv32i_soc_memory ram_load_store mmio_byte_strobes wrong_path uart_backpressure rom_data_alias");
        $finish;
    end
endmodule
