`timescale 1ns/1ps
/* Board-side performance report check.
 *
 * Runs the real perf_report.c image through the real SoC and decodes the UART
 * stream. The exact cycle/instruction counts are implementation details, so
 * this checks the printed values are structurally valid: the configured clock
 * is reported, the instruction count is non-zero, the cycle count is not below
 * the instruction count, and the workload lands in a physically plausible
 * window for the simulated configuration.
 *
 * Watchdog length: the decimal print helper costs roughly 10^5 cycles at the
 * simulated 1 MHz clock with a 100 kHz simulated line rate.
 */
module tb_perf_report;
    /* 100 kHz simulated line rate at a 1 MHz simulated clock: one bit spans
     * 10 clocks of 10 ns each. Keep in step with the rv32i_soc CLOCK_HZ/BAUD
     * overrides below. */
    localparam integer BIT_NS = 100;
    localparam integer WATCHDOG_NS = 400000000;

    logic clk = 0, rst_n = 0;
    wire uart_txd, halted, trap;
    wire [7:0] gpio;

    integer line_count = 0;
    integer current_line = 0;
    integer current_len = 0;
    logic [7:0] lines [0:15][0:95];
    integer lengths [0:15];

    rv32i_soc #(.CLOCK_HZ(1_000_000), .BAUD(100_000),
        .MEM_FILE("software/build/perf_report/firmware.hex")) dut (
        .clk_i(clk), .rst_n_i(rst_n), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );

    always #5 clk = ~clk;

    `include "sim/uart_receive.svh"

    /* Parse the decimal value of a captured line of the form LABEL=<digits>.
     * Skip the label and separator, then accumulate the digit run. This must
     * not assume the digits are the first characters: every report line starts
     * with an alphabetic label, so a leading-character parse yields zero. */
    function automatic [63:0] parse_leading_u64(input integer line);
        integer index;
        reg [63:0] value;
        reg in_digits;
        begin
            value = 64'd0;
            index = 0;
            in_digits = 1'b0;
            while (index < lengths[line]) begin
                if (lines[line][index] >= 8'h30 && lines[line][index] <= 8'h39) begin
                    value = value * 64'd10 + (lines[line][index] - 8'h30);
                    in_digits = 1'b1;
                end else if (in_digits) begin
                    index = lengths[line];
                end
                index = index + 1;
            end
            parse_leading_u64 = value;
        end
    endfunction

    function automatic string line_text(input integer line);
        string text;
        integer index;
        begin
            text = "";
            for (index = 0; index < lengths[line]; index = index + 1)
                text = {text, string'(lines[line][index])};
            line_text = text;
        end
    endfunction

    function automatic integer line_starts_with(input integer line, input string prefix);
        integer index;
        begin
            line_starts_with = 0;
            if (lengths[line] >= prefix.len()) begin
                line_starts_with = 1;
                for (index = 0; index < prefix.len(); index = index + 1)
                    if (lines[line][index] != prefix[index]) line_starts_with = 0;
            end
        end
    endfunction

    task automatic capture_byte(input logic [7:0] byte_value);
        begin
            if (byte_value == 8'h0d) begin
                line_count = line_count + 1;
                current_line = current_line + 1;
                current_len = 0;
            end else if (byte_value != 8'h0a) begin
                if (current_line < 16) begin
                    if (current_len < 96) begin
                        lines[current_line][current_len] = byte_value;
                        current_len = current_len + 1;
                        lengths[current_line] = current_len;
                    end
                end
            end
        end
    endtask

    integer run_no, index;
    logic [7:0] observed;
    /* The firmware prints the banner, four report lines, and the trailer. Each
     * report line carries both a decimal and a hex rendering, so the stream is
     * far longer than the decimal digits alone suggest: the measured run emits
     * 488 bytes. Rather than hard-code a count that drifts whenever the
     * formatter or the measured values change, read until the core halts. The
     * cap only bounds a runaway image; it must stay comfortably above the
     * real total. */
    localparam integer MIN_BYTES = 32;
    localparam integer MAX_BYTES = 1024;
    reg [63:0] cycles_value, instret_value, clock_value;
    integer clock_line, acc_line, cycles_line, instret_line, done_line;

    initial begin
        for (index = 0; index < 16; index = index + 1) begin
            lengths[index] = 0;
            for (integer col = 0; col < 96; col = col + 1) lines[index][col] = 8'h00;
        end
        #WATCHDOG_NS; $fatal(1, "Performance report firmware timeout");
    end

    initial begin
        #1;
        for (integer n = 0; n < 4096; n = n + 1) dut.u_dmem.mem[n] = 'hdeadbeef;
        for (run_no = 0; run_no < 1; run_no = run_no + 1) begin
            rst_n = 0;
            repeat (4) @(negedge clk); rst_n = 1;
            for (index = 0; index < MAX_BYTES; index = index + 1) begin
                if (index >= MIN_BYTES && halted) index = MAX_BYTES;
                else begin
                    receive_byte(observed);
                    capture_byte(observed);
                end
            end
        end
        repeat (20) @(negedge clk);
        if (trap) $fatal(1, "Performance report firmware trapped");
        if (!halted) $fatal(1, "Performance report firmware did not halt");
        if (gpio !== 'ha5) $fatal(1, "Performance report GPIO=%h expected a5", gpio);

        clock_line = -1; acc_line = -1; cycles_line = -1; instret_line = -1; done_line = -1;
        for (index = 0; index <= current_line && index < 16; index = index + 1) begin
            if (line_starts_with(index, "CLOCK_HZ")) clock_line = index;
            if (line_starts_with(index, "ACC")) acc_line = index;
            if (line_starts_with(index, "CYCLES")) cycles_line = index;
            if (line_starts_with(index, "INSTRET")) instret_line = index;
            if (line_starts_with(index, "PERF DONE")) done_line = index;
        end
        if (clock_line < 0 || acc_line < 0 || cycles_line < 0 || instret_line < 0 || done_line < 0)
            $fatal(1, "Performance report: missing key lines (lines seen=%0d)", current_line);
        for (index = 0; index <= done_line; index = index + 1)
            $display("UART[%0d] %s", index, line_text(index));

        clock_value = parse_leading_u64(clock_line);
        cycles_value = parse_leading_u64(cycles_line);
        instret_value = parse_leading_u64(instret_line);
        if (clock_value != 64'd1000000) $fatal(1, "CLOCK_HZ reported %0d", clock_value);
        if (instret_value == 0) $fatal(1, "INSTRET reported zero");
        if (cycles_value < instret_value) $fatal(1, "CYCLES < INSTRET");
        /* 2048 workload iterations plus the print helper cannot fit in 20k
         * cycles, and cannot plausibly reach 10M. */
        if (cycles_value < 64'd20000 || cycles_value > 64'd10000000)
            $fatal(1, "CYCLES %0d outside plausible window", cycles_value);
        $display("[PASS] perf_report firmware uart_lines=%0d clock=%0d cycles=%0d instret=%0d",
                 current_line, clock_value, cycles_value, instret_value);
        $finish;
    end
endmodule