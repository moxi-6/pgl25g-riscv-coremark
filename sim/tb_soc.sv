`timescale 1ns/1ps

module tb_soc;
    logic clk;
    logic rst_n;
    logic uart_tx;
    logic [7:0] gpio;
    logic halted;
    logic trap;

    integer cycles;
    integer uart_count;
    logic [7:0] uart_bytes [0:3];

    rv32i_soc #(
        .CLOCK_HZ (1_000_000),
        .BAUD     (100_000),
        .MEM_FILE ("software/build/firmware.hex")
    ) dut (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .uart_tx_o (uart_tx),
        .gpio_o    (gpio),
        .halted_o  (halted),
        .trap_o    (trap)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (dut.uart_valid && uart_count < 4) begin
            uart_bytes[uart_count] <= dut.dmem_wdata[7:0];
            uart_count <= uart_count + 1;
        end
    end

    initial begin
        $dumpfile("build/tb_soc.vcd");
        $dumpvars(0, tb_soc);

        clk        = 1'b0;
        rst_n      = 1'b0;
        cycles     = 0;
        uart_count = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while (!halted && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;

        if (!halted) $fatal(1, "SoC timeout");
        if (trap) $fatal(1, "SoC stopped with a trap");
        if (gpio !== 8'ha5) $fatal(1, "GPIO mismatch: %h", gpio);
        if (uart_count !== 4) $fatal(1, "UART byte count mismatch: %0d", uart_count);
        if (uart_bytes[0] !== "O" || uart_bytes[1] !== "K" ||
            uart_bytes[2] !== 8'h0d || uart_bytes[3] !== 8'h0a) begin
            $fatal(1, "UART data mismatch: %h %h %h %h",
                   uart_bytes[0], uart_bytes[1], uart_bytes[2], uart_bytes[3]);
        end

        $display("[PASS] rv32i_soc cycles=%0d uart=%c%c\\r\\n gpio=%h",
                 cycles, uart_bytes[0], uart_bytes[1], gpio);
        $finish;
    end
endmodule

