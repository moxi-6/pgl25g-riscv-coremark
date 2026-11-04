module rv32i_soc #(
    parameter integer CLOCK_HZ   = 50_000_000,
    parameter integer BAUD       = 115_200,
    parameter integer IMEM_WORDS = 16384,
    parameter integer DMEM_WORDS = 4096,
    parameter bit ZMMUL_ENABLE = 1'b0,
    parameter bit BITMANIP_ENABLE = 1'b0,
    parameter bit PIPELINE_DECODE = 1'b1,
    parameter bit FAST_DMEM = 1'b0,
    parameter bit DUAL_ISSUE = 1'b0,
    parameter integer BTB_ENTRIES = 16,
    parameter integer MUL_CYCLES = 3,
    parameter integer LCD_ENABLE = 0,
    parameter integer VIDEO_ENABLE = 0,
    // Touch controller bridge.  When enabled the SoC owns the four panel
    // signals and publishes the decoded position through MMIO 0x1000_0054\.
    parameter integer TOUCH_ENABLE = 0,
    parameter integer TOUCH_SCL_HZ = 100_000,
    // Tile-grid channel used by the minesweeper renderer: 0x1000_00A0 holds a
    // 16-word window onto the packed 9x9 cell array plus the cursor block.
    parameter integer MINE_ENABLE = 0,
    parameter         MEM_FILE   = "software/build/firmware.hex",
    parameter MEM_EVEN_FILE = "software/build/firmware.hex.even",
    parameter MEM_ODD_FILE = "software/build/firmware.hex.odd"
) (
    input  logic       clk_i,
    input  logic       rst_n_i,
    // Four board push buttons, active low (external pull-ups). Read-only MMIO;
    // debouncing and edge detection live in software so the logic stays small.
    input  logic [3:0] key_i,
    output logic       uart_tx_o,
    output logic [7:0] gpio_o,
    output logic       halted_o,
    output logic       trap_o,
    output logic [127:0] lcd_state_o,
    output wire [31:0] cycle_lo_o,
    output wire [31:0] instret_lo_o,
    input wire video_frame_i,
    output reg [1023:0] video_sprites_o,
    output reg [127:0] video_hud_o,
    // Packed minesweeper state for the hardware grid renderer.
    output reg [511:0] video_mine_o,
    // Touch panel (GT9147 on a private I2C bus).
    output logic       tp_scl_o,
    output logic       tp_sda_o,
    output logic       tp_sda_oe,
    input  logic       tp_sda_i,
    input  logic       tp_int_i,
    output logic       tp_rst_o,
    output logic       tp_int_o,
    output logic       tp_int_oe
);
    localparam logic [31:0] GPIO_ADDR = 32'h1000_0000;
    localparam logic [31:0] UART_ADDR = 32'h1000_0004;
    localparam logic [31:0] KEY_ADDR  = 32'h1000_0008;
    localparam logic [31:0] TOUCH_X_ADDR   = 32'h1000_0054;
    localparam logic [31:0] TOUCH_Y_ADDR   = 32'h1000_0058;
    localparam logic [31:0] TOUCH_STAT_ADDR= 32'h1000_005C;
    localparam logic [31:0] TOUCH_EVT_ADDR = 32'h1000_0060;
    localparam logic [31:0] ROM_DATA_BASE = 32'h2000_0000;
    // Instruction and data memories are independent 16 KiB arrays that both
    // decode from address zero, so their natural address ranges overlap
    // completely. GNU ld models one flat address space and refuses to place
    // .text and .data that way, which forced an artificially small RAM window
    // in linker.ld. RAM_DATA_BASE gives the data memory a second, non-
    // overlapping view of the same storage so the linker can lay out a large
    // image while the hardware still sees one array. The low alias is kept so
    // every existing firmware image continues to run unchanged.
    localparam logic [31:0] RAM_DATA_BASE = 32'h4000_0000;

    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;
    logic [31:0] imem_rdata_next;
    logic commit2_valid;
    logic imem_valid, imem_ready, imem_rvalid;
    logic        dmem_valid;
    logic        dmem_write;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_wdata;
    logic [3:0]  dmem_wstrb;
    logic [31:0] dmem_rdata;
    logic        dmem_ready;

    logic [31:0] ram_rdata;
    logic ram_ready;
    logic rom_selected, rom_ready;
    logic [31:0] rom_offset, rom_rdata;
    logic [31:0] ram_offset, ram_alias_offset;
    logic ram_selected;
    logic        gpio_selected;
    logic        key_selected;
    logic        uart_selected;
    logic        uart_valid;
    logic        uart_ready;
    logic        commit_valid;
    logic        perf_selected;
    logic [63:0] cycle_count_q, instret_count_q;
    wire lcd_selected = LCD_ENABLE && dmem_addr >= 32'h1000_0030 && dmem_addr < 32'h1000_0040;
    wire touch_selected = TOUCH_ENABLE && dmem_addr >= 32'h1000_0054 && dmem_addr < 32'h1000_0064;
    wire mine_selected = MINE_ENABLE && dmem_addr >= 32'h1000_00A0 && dmem_addr < 32'h1000_00E0;
    wire [3:0] mine_idx = (dmem_addr[7:0] - 8'hA0) >> 2;
    wire mine_commit_selected = MINE_ENABLE && dmem_addr[31:2] == (32'h100000e0 >> 2);
    logic [511:0] mine_stage_q;
    logic mine_pending_q;
    reg [31:0] lcd_stage_q [0:3];
    reg [31:0] lcd_merged;
    integer lcd_byte, lcd_word;
    reg [31:0] video_stage_q [0:31];
    reg [31:0] video_frames_q;
    reg video_pending_q;
    integer video_word, video_byte;
    wire video_selected = VIDEO_ENABLE && dmem_addr >= 32'h1000_0100 && dmem_addr < 32'h1000_0180;
    always @(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            video_sprites_o<=0; video_hud_o<=0; video_frames_q<=0; video_pending_q<=0;
            for(video_word=0;video_word<32;video_word=video_word+1) video_stage_q[video_word]<=0;
        end else if(VIDEO_ENABLE) begin
            if(video_frame_i) begin
                video_frames_q<=video_frames_q+1;
                if(video_pending_q) begin
                    for(video_word=0;video_word<32;video_word=video_word+1)
                        video_sprites_o[video_word*32 +:32]<=video_stage_q[video_word];
                    video_hud_o<={lcd_stage_q[3],lcd_stage_q[2],lcd_stage_q[1],lcd_stage_q[0]};
                    video_pending_q<=0;
                end
            end
            if(dmem_valid && dmem_write && dmem_ready) begin
                if(video_selected)
                    for(video_byte=0;video_byte<4;video_byte=video_byte+1)
                        if(dmem_wstrb[video_byte]) video_stage_q[dmem_addr[6:2]][video_byte*8 +:8]<=dmem_wdata[video_byte*8 +:8];
                if(dmem_addr[31:2]==30'h04000014 && dmem_wstrb[0]) video_pending_q<=1;
            end
        end
    end
    assign cycle_lo_o = cycle_count_q[31:0];
    assign instret_lo_o = instret_count_q[31:0];
    always @* begin
        lcd_merged = lcd_stage_q[dmem_addr[3:2]];
        for (lcd_byte=0; lcd_byte<4; lcd_byte=lcd_byte+1)
            if (dmem_wstrb[lcd_byte]) lcd_merged[lcd_byte*8 +: 8] = dmem_wdata[lcd_byte*8 +: 8];
    end
    // Stage data at 0x34/38/3c, then write status at 0x30 to publish one atomic
    // bundle. The display takes a second snapshot only at its frame boundary.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            lcd_state_o <= 0;
            for (lcd_word=0; lcd_word<4; lcd_word=lcd_word+1) lcd_stage_q[lcd_word] <= 0;
        end else if (lcd_selected && dmem_valid && dmem_write && dmem_ready && |dmem_wstrb) begin
            lcd_stage_q[dmem_addr[3:2]] <= lcd_merged;
            if (dmem_addr[3:2]==0)
                lcd_state_o <= {lcd_stage_q[3],lcd_stage_q[2],lcd_stage_q[1],lcd_merged};
        end
    end

    // Free-running elapsed-clock counter and successful WB events. EBREAK and
    // faulting instructions do not produce commit_valid in the current core.
    // Read-only MMIO avoids requiring a CSR extension just to time benchmarks.
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            cycle_count_q <= 64'b0;
            instret_count_q <= 64'b0;
        end else begin
            cycle_count_q <= cycle_count_q + 64'd1;
            instret_count_q <= instret_count_q + {63'b0,commit_valid} + {63'b0,commit2_valid};
        end
    end

    sync_imem #(
        .WORDS     (IMEM_WORDS),
        .FETCH_PAIR(DUAL_ISSUE),
        .INIT_FILE (MEM_FILE), .INIT_EVEN_FILE(MEM_EVEN_FILE), .INIT_ODD_FILE(MEM_ODD_FILE)
    ) u_imem (
        .clk_i (clk_i),
        .rst_n_i (rst_n_i),
        .valid_i (imem_valid),
        .ready_o (imem_ready),
        .rvalid_o (imem_rvalid),
        .addr_i  (imem_addr),
        .rdata_o (imem_rdata),
        .rdata_next_o(imem_rdata_next),
        .data_valid_i(dmem_valid && rom_selected),
        .data_addr_i(rom_offset),
        .data_ready_o(rom_ready),
        .data_rdata_o(rom_rdata)
    );

    rv32i_core_3stage #(.ZMMUL_ENABLE(ZMMUL_ENABLE), .PIPELINE_DECODE(PIPELINE_DECODE),
        .BITMANIP_ENABLE(BITMANIP_ENABLE),.DUAL_ISSUE(DUAL_ISSUE),.BTB_ENTRIES(BTB_ENTRIES),
        .MUL_CYCLES(MUL_CYCLES)) u_core (
        .clk_i             (clk_i),
        .rst_n_i           (rst_n_i),
        .imem_addr_o       (imem_addr),
        .imem_valid_o      (imem_valid),
        .imem_ready_i      (imem_ready),
        .imem_rvalid_i     (imem_rvalid),
        .imem_rdata_i      (imem_rdata),
        .imem_rdata_next_i (imem_rdata_next),
        .dmem_valid_o      (dmem_valid),
        .dmem_write_o      (dmem_write),
        .dmem_addr_o       (dmem_addr),
        .dmem_wdata_o      (dmem_wdata),
        .dmem_wstrb_o      (dmem_wstrb),
        .dmem_rdata_i      (dmem_rdata),
        .dmem_ready_i      (dmem_ready),
        .commit_valid_o    (commit_valid),
        .commit2_valid_o   (commit2_valid),
        .commit_pc_o       (),
        .commit_instr_o    (),
        .commit_rd_write_o (),
        .commit_rd_o       (),
        .commit_data_o     (),
        .halted_o          (halted_o),
        .trap_o            (trap_o)
    );

    assign ram_offset = (dmem_addr >= RAM_DATA_BASE) ? ram_alias_offset : dmem_addr;
    assign ram_alias_offset = dmem_addr - RAM_DATA_BASE;
    assign ram_selected  = (dmem_addr[31:2] < DMEM_WORDS) ||
                           ((dmem_addr >= RAM_DATA_BASE) && (ram_alias_offset[31:2] < DMEM_WORDS));
    assign gpio_selected = (dmem_addr[31:2] == GPIO_ADDR[31:2]);
    assign key_selected  = (dmem_addr[31:2] == KEY_ADDR[31:2]);
    assign uart_selected = (dmem_addr[31:2] == UART_ADDR[31:2]);
    assign perf_selected = (dmem_addr >= 32'h1000_0010) && (dmem_addr < 32'h1000_0024);
    assign rom_offset = dmem_addr - ROM_DATA_BASE;
    assign rom_selected = (dmem_addr >= ROM_DATA_BASE) && (rom_offset[31:2] < IMEM_WORDS);

    sync_dmem #(.WORDS(DMEM_WORDS), .ASYNC_READ(FAST_DMEM)) u_dmem (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .valid_i(dmem_valid && ram_selected), .write_i(dmem_write),
        .addr_i(ram_offset), .wdata_i(dmem_wdata), .wstrb_i(dmem_wstrb),
        .rdata_o(ram_rdata), .ready_o(ram_ready)
    );

    // RAM has registered read data and a completion cycle. GPIO is immediate;
    // a UART byte write waits until the transmitter can accept the byte.
    always_comb begin
        dmem_ready = 1'b1;
        dmem_rdata = 32'b0;

        if (ram_selected) begin
            dmem_rdata = ram_rdata;
            dmem_ready = ram_ready;
        end else if (rom_selected) begin
            dmem_rdata = rom_rdata;
            dmem_ready = rom_ready;
        end else if (gpio_selected) begin
            dmem_rdata = {24'b0, gpio_o};
        end else if (key_selected) begin
            dmem_rdata = {28'b0, key_i};
        end else if (uart_selected) begin
            dmem_ready = !dmem_write || !dmem_wstrb[0] || uart_ready;
            dmem_rdata = {31'b0, uart_ready};
        end else if (lcd_selected) begin
            dmem_rdata = lcd_stage_q[dmem_addr[3:2]];
        end else if (touch_selected) begin
            case (dmem_addr[3:2])
                2'd1:    dmem_rdata = {16'b0, tp_x};                                   // 0x54
                2'd2:    dmem_rdata = {16'b0, tp_y};                                   // 0x58
                2'd3:    dmem_rdata = {18'b0, tp_seq, tp_count, tp_status,            // 0x5C
                                       tp_tap, tp_pressed};
                2'd0:    dmem_rdata = {8'b0, tp_acks, tp_events[15:0]};                // 0x60
                default: dmem_rdata = 32'b0;
            endcase
        end else if (video_selected) begin
            dmem_rdata = video_stage_q[dmem_addr[6:2]];
        end else if (mine_selected) begin
            dmem_rdata = mine_stage_q[mine_idx*32 +: 32];
        end else if (mine_commit_selected) begin
            dmem_rdata = {31'b0,mine_pending_q};
        end else if (VIDEO_ENABLE && dmem_addr[31:2]==30'h04000011) begin
            dmem_rdata = video_frames_q;
        end else if (VIDEO_ENABLE && dmem_addr[31:2]==30'h04000014) begin
            dmem_rdata = {31'b0,video_pending_q};
        end else if (perf_selected) begin
            case (dmem_addr[4:2])
                3'd4: dmem_rdata = cycle_count_q[31:0];   // 0x10
                3'd5: dmem_rdata = cycle_count_q[63:32];  // 0x14
                3'd6: dmem_rdata = instret_count_q[31:0]; // 0x18
                3'd7: dmem_rdata = instret_count_q[63:32];// 0x1c
                3'd0: dmem_rdata = CLOCK_HZ;             // 0x20 (configured)
                default: dmem_rdata = 32'b0;
            endcase
        end
    end

    assign uart_valid = dmem_valid && dmem_write && dmem_wstrb[0] && uart_selected && uart_ready;

    uart_tx #(
        .CLOCK_HZ (CLOCK_HZ),
        .BAUD     (BAUD)
    ) u_uart_tx (
        .clk_i   (clk_i),
        .rst_n_i (rst_n_i),
        .valid_i (uart_valid),
        .data_i  (dmem_wdata[7:0]),
        .ready_o (uart_ready),
        .tx_o    (uart_tx_o)
    );

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            gpio_o <= 8'b0;
        end else if (dmem_valid && dmem_write && dmem_ready) begin
            if (gpio_selected) begin
                if (dmem_wstrb[0]) gpio_o <= dmem_wdata[7:0];
            end
        end
    end

    // ------------------------------------------------------------------
    // Publish a complete tile/HUD snapshot only at the next frame boundary.
    // Software waits for pending=0 before editing staging, then writes E0=1.
    // ------------------------------------------------------------------
    integer mine_byte;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            video_mine_o <= 512'b0;
            mine_stage_q <= 512'b0;
            mine_pending_q <= 1'b0;
        end else if (MINE_ENABLE) begin
            if (video_frame_i && mine_pending_q) begin
                video_mine_o <= mine_stage_q;
                mine_pending_q <= 1'b0;
            end
            if (dmem_valid && dmem_write && dmem_ready) begin
                if (mine_selected && !mine_pending_q) begin
                    for (mine_byte = 0; mine_byte < 4; mine_byte = mine_byte + 1) begin
                        if (dmem_wstrb[mine_byte])
                            mine_stage_q[mine_idx*32 + mine_byte*8 +: 8] <= dmem_wdata[mine_byte*8 +: 8];
                    end
                end
                if (mine_commit_selected && dmem_wstrb[0] && dmem_wdata[0]) mine_pending_q <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Touch panel bridge
    // ------------------------------------------------------------------
    wire [15:0] tp_x, tp_y;
    wire [31:0] tp_id;
    wire        tp_pressed, tp_tap;
    wire [4:0]  tp_seq;
    wire [3:0]  tp_count;
    wire [2:0]  tp_status;
    wire [31:0] tp_events;
    wire [7:0]  tp_acks, tp_last_reg;

    // Writing the status register clears the latched tap so the next frame can
    // queue another one; bit 0 of the event register restarts the controller.
    wire tp_tap_clear = dmem_valid && dmem_write && dmem_ready && touch_selected &&
                        (dmem_addr[3:2] == 2'd3) && dmem_wstrb[0];
    wire tp_reinit    = dmem_valid && dmem_write && dmem_ready && touch_selected &&
                        (dmem_addr[3:2] == 2'd0) && dmem_wstrb[0] && dmem_wdata[0];

    generate
        if (TOUCH_ENABLE) begin : g_touch
            gt9147_touch #(
                .CLK_HZ (CLOCK_HZ),
                .SCL_HZ (TOUCH_SCL_HZ)
            ) u_touch (
                .clk_i         (clk_i),
                .rst_n_i       (rst_n_i),
                .tp_scl_o      (tp_scl_o),
                .tp_sda_o      (tp_sda_o),
                .tp_sda_oe     (tp_sda_oe),
                .tp_sda_i      (tp_sda_i),
                .tp_rst_o      (tp_rst_o),
                .tp_int_o      (tp_int_o),
                .tp_int_oe     (tp_int_oe),
                .x_o           (tp_x),
                .y_o           (tp_y),
                .id_o          (tp_id),
                .pressed_o     (tp_pressed),
                .seq_o         (tp_seq),
                .count_o       (tp_count),
                .status_o      (tp_status),
                .event_cnt_o   (tp_events),
                .tap_latch_o   (tp_tap),
                .ack_err_cnt_o (tp_acks),
                .last_reg_o    (tp_last_reg),
                .reinit_i      (tp_reinit),
                .tap_clear_i   (tp_tap_clear)
            );
        end else begin : g_no_touch
            assign tp_x = 16'b0;
            assign tp_y = 16'b0;
            assign tp_id = 32'b0;
            assign tp_pressed = 1'b0;
            assign tp_tap = 1'b0;
            assign tp_seq = 5'b0;
            assign tp_count = 4'b0;
            assign tp_status = 3'b0;
            assign tp_events = 32'b0;
            assign tp_acks = 8'b0;
            assign tp_last_reg = 8'b0;
            assign tp_scl_o = 1'b1;
            assign tp_sda_o = 1'b1;
            assign tp_sda_oe = 1'b0;
            assign tp_rst_o = 1'b0;
            assign tp_int_o = 1'b1;
            assign tp_int_oe = 1'b0;
        end
    endgenerate
endmodule
