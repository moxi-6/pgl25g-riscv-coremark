`timescale 1ns/1ps
// Reflex-game regression: the real game firmware (built with -DGAME_FAST_SIM so
// two short rounds replace ten 3-second ones) runs on the SoC while this
// testbench plays the human. It watches gpio_o for the target LED, presses the
// matching KEY one simulated millisecond later in round 1 and a wrong KEY in
// round 2, then requires the UART to report "Match: 1/2 hit".
//
// One software millisecond is 50 000 core cycles (game.c models a 50 MHz
// clock), so every delay below is expressed in those cycles rather than in
// wall-clock nanoseconds.
module tb_game;
    localparam integer MS = 50000;
    localparam integer MAX_CYCLES = 8_000_000;

    logic clk = 0;
    logic rst_n = 0;
    wire uart_tx;
    wire [7:0] gpio;
    wire halted;
    wire trap;
    wire [127:0] lcd_state;
    integer lcd_hit_seen=0, lcd_wrong_seen=0;
    logic [3:0] key = 4'hF;

    integer uart_count = 0;
    integer pat_idx = 0;
    integer pat_len = 0;
    logic [7:0] pattern [0:31];
    logic [7:0] capture [0:4095];
    logic matched = 0;
    integer total_cycles = 0;

    rv32i_soc #(
        .CLOCK_HZ (1_000_000),
        .LCD_ENABLE(1),
        .BAUD     (100_000),
        .MEM_FILE ("software/build/game_sim/firmware.hex")
    ) dut (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .uart_tx_o (uart_tx),
        .gpio_o    (gpio),
        .key_i     (key),
        .halted_o  (halted),
        .trap_o    (trap),
        .lcd_state_o(lcd_state)
    );

    always #5 clk = ~clk;

    initial begin
        pattern[0]  = "M"; pattern[1]  = "a"; pattern[2]  = "t"; pattern[3]  = "c";
        pattern[4]  = "h"; pattern[5]  = ":"; pattern[6]  = " "; pattern[7]  = "1";
        pattern[8]  = "/"; pattern[9]  = "2"; pattern[10] = " "; pattern[11] = "h";
        pattern[12] = "i"; pattern[13] = "t";
        pat_len = 14;
    end

    always @(posedge clk) begin
        total_cycles <= total_cycles + 1;
        if(lcd_state[3:0]==3) lcd_hit_seen=1;
        if(lcd_state[3:0]==4) lcd_wrong_seen=1;
        if (total_cycles % 500_000 == 0) begin
            $display("[tb_game] t=%0d gpio=%h key=%h uart=%0d pc=%h",
                     total_cycles, gpio, key, uart_count, dut.u_core.if_pc_q);
            $write("[tb_game] tail: ");
            for (integer n = (uart_count > 80 ? uart_count - 80 : 0); n < uart_count && n < 4096; n = n + 1) begin
                if (capture[n] >= 8'h20 || capture[n] == 8'h0d || capture[n] == 8'h0a) $write("%c", capture[n]);
            end
            $write("\n");
            $fflush();
        end
        if (dut.uart_valid) begin
            if (uart_count < 4096) capture[uart_count] = dut.dmem_wdata[7:0];
            uart_count <= uart_count + 1;
            if (dut.dmem_wdata[7:0] == pattern[pat_idx]) begin
                pat_idx <= pat_idx + 1;
                if (pat_idx + 1 == pat_len) matched <= 1'b1;
            end else if (dut.dmem_wdata[7:0] == pattern[0]) begin
                pat_idx <= 1;
            end else begin
                pat_idx <= 0;
            end
        end
    end

    // Play the human: wait for an LED, press after 1 ms, release once the LED
    // goes dark (the firmware clears GPIO_OUT right after it samples the key).
    integer target;
    integer wrong;
    integer held;
    initial begin : player
        repeat (10) @(posedge clk);
        for (integer round = 1; round <= 2; round++) begin
            wait (gpio != 0);
            target = 0;
            if (gpio[1]) target = 1;
            if (gpio[2]) target = 2;
            if (gpio[3]) target = 3;
            repeat (MS) @(posedge clk);
            if (round == 1) begin
                key <= ~(4'b0001 << target);
                $display("[tb_game] round %0d: LED%0d -> pressing KEY%0d", round, target, target);
            end else begin
                wrong = (target + 1) & 3;
                key <= ~(4'b0001 << wrong);
                $display("[tb_game] round %0d: LED%0d -> pressing KEY%0d (wrong)", round, target, wrong);
            end
            held = 0;
            while (held < 40 * MS && gpio != 0) begin
                @(posedge clk);
                held = held + 1;
            end
            key <= 4'hF;
            repeat (8 * MS) @(posedge clk);
        end
    end

    initial begin
        #1;
        repeat (4) @(negedge clk);
        rst_n = 1;
        while (!matched && total_cycles < MAX_CYCLES) begin
            @(posedge clk);
        end
        if (!matched) begin
            for (integer n = 0; n < uart_count && n < 4096; n++) begin
                $write("%c", capture[n]);
            end
            $fatal(1, "game UART did not report 'Match: 1/2 hit' (%0d bytes)", uart_count);
        end
        if (!lcd_hit_seen || !lcd_wrong_seen || lcd_state[3:0]!=6 ||
            lcd_state[71:64]!=8'h02 || lcd_state[87:80]!=8'h01)
            $fatal(1,"LCD game state/summary mismatch: %h", lcd_state);
        $display("[PASS] reflex_game captured %0d UART bytes in %0d cycles, Match 1/2 (one OK, one WRONG KEY), LCD summary verified",
                 uart_count, total_cycles);
        $finish;
    end
endmodule
