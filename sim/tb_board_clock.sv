`timescale 1ns/1ps
// Run a real CPU program through the board top. The program reads CLOCK_HZ,
// saves it in RAM, transmits 0x55, writes GPIO a5, and halts. No bus is forced.
module tb_board_clock #(
    parameter integer CPU_CLOCK_DIV = 2,
    parameter integer DUT_CLOCK_HZ = 50_000_000 / CPU_CLOCK_DIV
);
    localparam integer EXPECT_CLOCK_HZ = 50_000_000 / CPU_CLOCK_DIV;
    localparam integer CPU_PERIOD_NS = 20 * CPU_CLOCK_DIV;
    localparam integer UART_BIT_NS = CPU_PERIOD_NS * (EXPECT_CLOCK_HZ / 115_200);
    logic sys_clk = 0;
    logic sys_rst_n = 1;
    logic [3:0] key = 4'hf;
    wire uart_txd;
    wire [3:0] led;
    integer source_release_edges = 0, cpu_release_edges = 0;
    integer clock_reads = 0, cpu_edges = 0;
    time last_cpu_edge = 0;

    atk_l50_top #(.CPU_CLOCK_DIV(CPU_CLOCK_DIV), .CLOCK_HZ(DUT_CLOCK_HZ),
        .MEM_FILE("build/board_clock/program.hex"),
        .MEM_EVEN_FILE("build/board_clock/program.hex.even"),
        .MEM_ODD_FILE("build/board_clock/program.hex.odd")) dut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n), .key(key),
        .uart_txd(uart_txd), .led(led)
    );
    always #10 sys_clk = ~sys_clk;

    // Source-domain reset must assert asynchronously and release on exactly
    // the second 50 MHz edge. The direct-clock option intentionally bypasses it.
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) source_release_edges = 0;
        else begin
            source_release_edges = source_release_edges + 1;
            #1;
            if (CPU_CLOCK_DIV != 1 && dut.source_rst_n !== (source_release_edges >= 2))
                $fatal(1, "Source reset release at edge %0d", source_release_edges);
        end
    end

    // Check actual clock edges, including after reset release, rather than just
    // checking parameter values or generated-clock constraints.
    always @(posedge dut.cpu_clk or negedge dut.source_rst_n) begin
        if (!dut.source_rst_n) begin
            cpu_release_edges = 0;
            last_cpu_edge = 0;
        end else begin
            if (last_cpu_edge != 0 && $time - last_cpu_edge != CPU_PERIOD_NS)
                $fatal(1, "CPU period=%0t expected %0d ns", $time-last_cpu_edge, CPU_PERIOD_NS);
            last_cpu_edge = $time;
            cpu_edges = cpu_edges + 1;
            cpu_release_edges = cpu_release_edges + 1;
            #1;
            if (dut.rst_n !== (cpu_release_edges >= 2))
                $fatal(1, "CPU reset release at edge %0d", cpu_release_edges);
        end
    end

    always @(posedge dut.cpu_clk or negedge dut.rst_n) begin
        if (!dut.rst_n) clock_reads = 0;
        else if (dut.u_soc.dmem_valid && dut.u_soc.dmem_ready &&
                 !dut.u_soc.dmem_write && dut.u_soc.dmem_addr == 32'h10000020) begin
            if (dut.u_soc.dmem_rdata !== EXPECT_CLOCK_HZ)
                $fatal(1, "MMIO_CLOCK_MISMATCH got=%0d expected=%0d", dut.u_soc.dmem_rdata, EXPECT_CLOCK_HZ);
            clock_reads = clock_reads + 1;
        end
    end

    task automatic restart(input integer offset_ns);
        // Assert off both clock edges, including while a UART frame is active.
        #(offset_ns);
        sys_rst_n = 0;
        #1;
        if (dut.source_rst_n !== 0 || dut.rst_n !== 0 || uart_txd !== 1 || led !== 0)
            $fatal(1, "Asynchronous board reset failed");
        repeat (5) @(negedge sys_clk);
        #3;
        sys_rst_n = 1;
    endtask

    task automatic receive_and_check;
        time transition_time;
        @(negedge uart_txd);
        transition_time = $time;
        // 0x55 gives an edge at every bit boundary, including start and stop.
        for (integer bit_index = 1; bit_index <= 9; bit_index = bit_index + 1) begin
            @(uart_txd);
            if ($time - transition_time != UART_BIT_NS)
                $fatal(1, "UART bit width=%0t expected=%0d ns", $time-transition_time, UART_BIT_NS);
            if (uart_txd !== (bit_index % 2 == 1))
                $fatal(1, "UART 0x55 framing mismatch at bit %0d", bit_index);
            transition_time = $time;
        end
        #(UART_BIT_NS + 1);
        if (uart_txd !== 1 || dut.u_soc.u_uart_tx.busy_q !== 0)
            $fatal(1, "UART failed to complete frame");
        if (!dut.halted || dut.trap || led !== 4'h5 || dut.gpio !== 8'ha5)
            $fatal(1, "CPU program did not finish normally");
        if (clock_reads != 1 || dut.u_soc.u_dmem.mem[0] !== EXPECT_CLOCK_HZ)
            $fatal(1, "CPU CLOCK_HZ read/store missing or duplicated");
    endtask

    initial begin
        #1;
        restart(2);
        receive_and_check();
        restart(7);
        @(negedge uart_txd);
        #(UART_BIT_NS * 3 + 3);
        if (dut.u_soc.u_uart_tx.busy_q !== 1) $fatal(1, "UART abort test was not active");
        restart(2);
        receive_and_check();
        if (cpu_edges < 100) $fatal(1, "Insufficient live clock evidence");
        $display("[PASS] board_clock div=%0d clock_hz=%0d period_ns=%0d uart_bit_ns=%0d normal_runs=2 interrupted_frames=1 cpu_edges=%0d",
                 CPU_CLOCK_DIV, EXPECT_CLOCK_HZ, CPU_PERIOD_NS, UART_BIT_NS, cpu_edges);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Board divider/reset timeout (clock or reset deadlock)");
    end
endmodule
