// Physical LEDs are active high (NPN transistor drivers).
module atk_l50_top #(
    parameter integer INPUT_CLOCK_HZ = 50_000_000,
    parameter integer CLOCK_HZ = 25_000_000,
    parameter integer CPU_CLOCK_DIV = 2,
    parameter integer BAUD = 115_200,
    parameter bit ZMMUL_ENABLE = 1'b1,
    parameter bit BITMANIP_ENABLE = 1'b1,
    parameter bit DUAL_ISSUE = 1'b1,
    parameter bit FAST_DMEM = 1'b1,
    parameter bit PIPELINE_DECODE = 1'b0,
    parameter integer BTB_ENTRIES = 16,
    parameter integer MUL_CYCLES = 2,
    parameter integer DMEM_WORDS = 2048,
    parameter MEM_FILE = "software/build/firmware.hex",
    parameter MEM_EVEN_FILE = "software/build/firmware.hex.even",
    parameter MEM_ODD_FILE = "software/build/firmware.hex.odd"
) (
    input logic sys_clk,
    input logic sys_rst_n,
    // KEY0..KEY3 on the ATK-L50 base board; active low with external pull-ups.
    input logic [3:0] key,
    output logic uart_txd,
    output logic [3:0] led
);
    logic rst_n, source_rst_n, cpu_clk;
    logic [7:0] gpio;
    logic halted, trap;
    // Synchronize each asynchronous button before exposing it through MMIO.
    // Mechanical debounce remains in the game firmware.
    (* syn_preserve = 1 *) logic [3:0] key_meta, key_sync;
    generate if (CPU_CLOCK_DIV == 1) begin : g_direct_clock
        assign cpu_clk = sys_clk;
        assign source_rst_n = sys_rst_n;
    end else begin : g_divided_clock
        logic [1:0] div_q;
        wire divided_clk = CPU_CLOCK_DIV == 4 ? div_q[1] : div_q[0];
        reset_sync u_source_reset (.clk_i(sys_clk), .reset_n_i(sys_rst_n), .reset_n_o(source_rst_n));
        always_ff @(posedge sys_clk or negedge source_rst_n)
            if (!source_rst_n) div_q <= 0;
            else div_q <= div_q + 1'b1;
        GTP_CLKBUFG u_cpu_clk_buf (.CLKIN(divided_clk), .CLKOUT(cpu_clk));
    end endgenerate
    reset_sync u_reset (.clk_i(cpu_clk), .reset_n_i(source_rst_n), .reset_n_o(rst_n));
    always_ff @(posedge cpu_clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 4'hf;
            key_sync <= 4'hf;
        end else begin
            key_meta <= key;
            key_sync <= key_meta;
        end
    end
    rv32i_soc #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD), .MEM_FILE(MEM_FILE),
        .MEM_EVEN_FILE(MEM_EVEN_FILE), .MEM_ODD_FILE(MEM_ODD_FILE), .ZMMUL_ENABLE(ZMMUL_ENABLE),
        .BITMANIP_ENABLE(BITMANIP_ENABLE), .DUAL_ISSUE(DUAL_ISSUE),
        .FAST_DMEM(FAST_DMEM), .PIPELINE_DECODE(PIPELINE_DECODE),
        .BTB_ENTRIES(BTB_ENTRIES), .MUL_CYCLES(MUL_CYCLES), .DMEM_WORDS(DMEM_WORDS)) u_soc (
        .clk_i(cpu_clk), .rst_n_i(rst_n), .key_i(key_sync), .uart_tx_o(uart_txd),
        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)
    );
    assign led = gpio[3:0];
endmodule
