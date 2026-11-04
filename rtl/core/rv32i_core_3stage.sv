module rv32i_core_3stage #(
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0000,
    // Legacy combinational ROM mode is retained only for baseline comparison.
    parameter bit ASYNC_IMEM = 1'b0,
    parameter bit PREDICT_ENABLE = 1'b1,
    parameter integer BTB_ENTRIES = 16,
    parameter bit PIPELINE_DECODE = 1'b1,
    parameter bit ZMMUL_ENABLE = 1'b0,
    parameter bit BITMANIP_ENABLE = 1'b0,
    parameter bit DUAL_ISSUE = 1'b0,
    parameter integer MUL_CYCLES = 3
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    output logic [31:0] imem_addr_o,
    output logic        imem_valid_o,
    input  logic        imem_ready_i,
    input  logic        imem_rvalid_i,
    input  logic [31:0] imem_rdata_i,
    input  logic [31:0] imem_rdata_next_i,

    output logic        dmem_valid_o,
    output logic        dmem_write_o,
    output logic [31:0] dmem_addr_o,
    output logic [31:0] dmem_wdata_o,
    output logic [3:0]  dmem_wstrb_o,
    input  logic [31:0] dmem_rdata_i,
    input  logic        dmem_ready_i,

    output logic        commit_valid_o,
    output logic [31:0] commit_pc_o,
    output logic [31:0] commit_instr_o,
    output logic        commit_rd_write_o,
    output logic [4:0]  commit_rd_o,
    output logic [31:0] commit_data_o,
    output logic commit2_valid_o,
    output logic [31:0] commit2_pc_o, commit2_instr_o, commit2_data_o,
    output logic commit2_rd_write_o,
    output logic [4:0] commit2_rd_o,

    output logic        halted_o,
    output logic        trap_o
);
    import rv32i_pkg::*;

    // IF stage state
    logic [31:0] if_pc_q;
    logic fetch_valid, fetch_take;
    logic [31:0] fetch_pc, fetch_instr;
    logic [31:0] fetch_predicted_next, ex_predicted_next_q;
    logic [31:0] actual_next, first_actual_next;
    logic redirect, first_redirect, stop_ex;
    logic [31:0] fetch_instr2, ex_instr2_q, ex_packet_next_q;
    logic fetch_pair, ex_pair_q, pair_execute, serialize_pair;
    logic wb2_valid_q, wb2_reg_write_q;
    logic [4:0] wb2_rd_q;
    logic [31:0] wb2_pc_q, wb2_instr_q, wb2_data_q;

    // EX stage state
    logic        ex_valid_q;
    logic [31:0] ex_pc_q;
    logic [31:0] ex_instr_q;

    // Optional ID stage separates instruction decode from register read/ALU.
    localparam bit DECODE_PIPELINED = PIPELINE_DECODE && !ASYNC_IMEM && !DUAL_ISSUE;
    logic id_valid_q;
    logic [31:0] id_pc_q, id_instr_q, id_predicted_next_q;
    wire [31:0] decode_instr = DECODE_PIPELINED ? id_instr_q : ex_instr_q;

    // WB stage state
    logic        wb_valid_q;
    logic [31:0] wb_pc_q;
    logic [31:0] wb_instr_q;
    logic        wb_reg_write_q;
    logic [4:0]  wb_rd_q;
    logic [31:0] wb_data_q;

    // Decoded EX-stage controls
    logic [4:0]    ex_rs1;
    logic [4:0]    ex_rs2;
    logic [4:0]    ex_rd;
    logic          ex_reg_write;
    logic [5:0]       ex_alu_op;
    logic          ex_alu_lhs_pc;
    logic          ex_alu_rhs_imm;
    logic [31:0]   ex_imm;
    logic [2:0]    ex_branch_op;
    logic          ex_jump;
    logic          ex_jalr;
    logic          ex_mem_read;
    logic          ex_mem_write;
    logic [1:0]     ex_mem_size;
    logic          ex_load_unsigned;
    logic          ex_illegal;
    logic          ex_ebreak;

    logic [31:0] rf_rs1_data;
    logic [31:0] rf_rs2_data;
    logic [31:0] ex_rs1_value;
    logic [31:0] ex_rs2_value;
    logic [31:0] alu_lhs;
    logic [31:0] alu_rhs;
    logic [31:0] alu_result;

    logic        branch_condition;
    logic        control_taken;
    logic [31:0] control_target;
    logic        instruction_misaligned;
    logic        data_misaligned;
    logic        ex_fault;
    logic        ex_wait;

    logic [31:0] shifted_load_data;
    logic [31:0] load_result;
    logic [31:0] ex_result;

    assign first_actual_next = control_taken ? control_target : ex_pc_q + 32'd4;
    assign actual_next = pair_execute ? ex2_actual_next : first_actual_next;
    assign first_redirect = first_actual_next != ex_predicted_next_q;
    assign redirect = ex_valid_q && !ex_wait && !ex_fault && !ex_ebreak &&
                      (first_redirect || (pair_execute && ex2_actual_next != ex_packet_next_q));
    assign stop_ex = ex_valid_q && !ex_wait && (ex_fault || ex_ebreak);
    assign fetch_take = fetch_valid && !halted_o && !ex_wait && !redirect && !stop_ex && !serialize_pair;

    generate
        if (ASYNC_IMEM) begin : g_async_fetch
            assign imem_addr_o = if_pc_q;
            assign imem_valid_o = !halted_o;
            assign fetch_valid = 1'b1;
            assign fetch_pc = if_pc_q;
            assign fetch_instr = imem_rdata_i;
            assign fetch_instr2 = 32'b0;
            assign fetch_pair = 1'b0;
            assign fetch_predicted_next = if_pc_q + 32'd4;
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) if_pc_q <= RESET_VECTOR;
                else if (!halted_o) begin
                    if (redirect) if_pc_q <= actual_next;
                    else if (fetch_take) if_pc_q <= if_pc_q + 32'd4;
                end
            end
        end else begin : g_sync_fetch
            // One accepted request and one reserved response slot. A response
            // can feed EX directly while its successor is accepted on this edge.
            // A request stalled by memory is registered and remains immutable
            // across redirects until acceptance, then drains as a stale response.
            logic request_q, request_discard_q;
            logic pending_q, discard_q, buffered_q;
            logic [31:0] request_pc_q, pending_pc_q;
            logic [31:0] buffered_pc_q, buffered_instr_q;
            logic [31:0] buffered_instr2_q;
            logic request_pair_q, pending_pair_q, buffered_pair_q, predicted_pair, issued_pair;
            logic [31:0] request_next_q, pending_next_q, buffered_next_q;
            logic [31:0] predicted_next, issued_next;
            logic response_valid, can_issue, request_accept;
            localparam integer BTB_INDEX_W = $clog2(BTB_ENTRIES);
            logic [BTB_ENTRIES-1:0] btb_valid_q;
            logic [29-BTB_INDEX_W:0] btb_tag_q [0:BTB_ENTRIES-1];
            logic [31:0] btb_target_q [0:BTB_ENTRIES-1];
            logic [1:0] btb_counter_q [0:BTB_ENTRIES-1];
            wire [BTB_INDEX_W-1:0] predict_index = if_pc_q[BTB_INDEX_W+1:2];
            wire [31:0] second_pc = if_pc_q + 32'd4;
            wire [31:0] update2_pc = ex_pc_q + 32'd4;
            wire [BTB_INDEX_W-1:0] predict2_index = second_pc[BTB_INDEX_W+1:2];
            wire [BTB_INDEX_W-1:0] update2_index = update2_pc[BTB_INDEX_W+1:2];
            wire [BTB_INDEX_W-1:0] update_index = ex_pc_q[BTB_INDEX_W+1:2];
            wire update_hit = btb_valid_q[update_index] &&
                              btb_tag_q[update_index] == ex_pc_q[31:BTB_INDEX_W+2];
            wire predict_hit = PREDICT_ENABLE && btb_valid_q[predict_index] &&
                               btb_tag_q[predict_index] == if_pc_q[31:BTB_INDEX_W+2];
            wire predict2_hit = PREDICT_ENABLE && DUAL_ISSUE && btb_valid_q[predict2_index] &&
                               btb_tag_q[predict2_index] == second_pc[31:BTB_INDEX_W+2];
            wire update2_hit = btb_valid_q[update2_index] &&
                               btb_tag_q[update2_index] == update2_pc[31:BTB_INDEX_W+2];
            assign predicted_pair = DUAL_ISSUE && !(predict_hit && btb_counter_q[predict_index][1]);
            assign predicted_next = predict_hit && btb_counter_q[predict_index][1]
                                  ? btb_target_q[predict_index]
                                  : (predict2_hit && btb_counter_q[predict2_index][1]
                                     ? btb_target_q[predict2_index] : if_pc_q + (DUAL_ISSUE ? 32'd8 : 32'd4));
            assign issued_next = request_q ? request_next_q : predicted_next;
            assign issued_pair = request_q ? request_pair_q : predicted_pair;

            // Resolve and train only an instruction which can complete EX.
            // Tags prevent a different PC from using an aliased target.
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) btb_valid_q <= '0;
                else if (PREDICT_ENABLE && ex_valid_q && !ex_wait && !ex_fault && !ex_ebreak) begin
                    if (ex_jump || ex_branch_op != BR_NONE) begin
                        btb_valid_q[update_index] <= 1'b1;
                        btb_tag_q[update_index] <= ex_pc_q[31:BTB_INDEX_W+2];
                        btb_target_q[update_index] <= control_target;
                        if (!update_hit || ex_jump)
                            btb_counter_q[update_index] <= control_taken ? 2'b11 : 2'b01;
                        else if (control_taken && btb_counter_q[update_index] != 2'b11)
                            btb_counter_q[update_index] <= btb_counter_q[update_index] + 1'b1;
                        else if (!control_taken && btb_counter_q[update_index] != 2'b00)
                            btb_counter_q[update_index] <= btb_counter_q[update_index] - 1'b1;
                    end else if (update_hit) btb_valid_q[update_index] <= 1'b0;
                    // Adjacent instructions have distinct indices (BTB_ENTRIES >= 2).
                    // A lane-2 branch trains even when its prediction redirects IF.
                    if (pair_execute && !first_redirect) begin
                        if (ex2_jump || ex2_branch != BR_NONE) begin
                            btb_valid_q[update2_index] <= 1'b1;
                            btb_tag_q[update2_index] <= update2_pc[31:BTB_INDEX_W+2];
                            btb_target_q[update2_index] <= ex2_target;
                            if (!update2_hit || ex2_jump)
                                btb_counter_q[update2_index] <= ex2_taken ? 2'b11 : 2'b01;
                            else if (ex2_taken && btb_counter_q[update2_index] != 2'b11)
                                btb_counter_q[update2_index] <= btb_counter_q[update2_index] + 1'b1;
                            else if (!ex2_taken && btb_counter_q[update2_index] != 2'b00)
                                btb_counter_q[update2_index] <= btb_counter_q[update2_index] - 1'b1;
                        end else if (update2_hit) btb_valid_q[update2_index] <= 1'b0;
                    end
                end
            end

            assign response_valid = pending_q && imem_rvalid_i && !discard_q;
            assign fetch_valid = buffered_q || response_valid;
            assign fetch_pc = buffered_q ? buffered_pc_q : pending_pc_q;
            assign fetch_instr = buffered_q ? buffered_instr_q : imem_rdata_i;
            assign fetch_instr2 = buffered_q ? buffered_instr2_q : imem_rdata_next_i;
            assign fetch_pair = DUAL_ISSUE && (buffered_q ? buffered_pair_q : pending_pair_q);
            assign fetch_predicted_next = buffered_q ? buffered_next_q : pending_next_q;
            assign can_issue = (!pending_q || imem_rvalid_i) &&
                               (!buffered_q || fetch_take) &&
                               (!response_valid || fetch_take) &&
                               !halted_o && !redirect && !stop_ex;
            assign imem_valid_o = rst_n_i && (request_q || can_issue);
            assign imem_addr_o = request_q ? request_pc_q : if_pc_q;
            assign request_accept = imem_valid_o && imem_ready_i;

            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    if_pc_q <= RESET_VECTOR;
                    request_q <= 1'b0;
                    request_discard_q <= 1'b0;
                    request_pc_q <= RESET_VECTOR;
                    pending_q <= 1'b0;
                    discard_q <= 1'b0;
                    buffered_q <= 1'b0;
                    pending_pc_q <= RESET_VECTOR;
                    buffered_pc_q <= RESET_VECTOR;
                    buffered_instr_q <= 32'h0000_0013;
                    buffered_instr2_q <= 32'h0000_0013;
                    request_pair_q <= 0;
                    pending_pair_q <= 0;
                    buffered_pair_q <= 0;
                    request_next_q <= RESET_VECTOR;
                    pending_next_q <= RESET_VECTOR;
                    buffered_next_q <= RESET_VECTOR;
                end else begin
                    if (fetch_take) buffered_q <= 1'b0;
                    if (pending_q && imem_rvalid_i) begin
                        pending_q <= 1'b0;
                        discard_q <= 1'b0;
                        if (response_valid && !fetch_take && !redirect && !stop_ex && !halted_o) begin
                            buffered_q <= 1'b1;
                            buffered_pc_q <= pending_pc_q;
                            buffered_instr_q <= imem_rdata_i;
                            buffered_instr2_q <= imem_rdata_next_i;
                            buffered_pair_q <= pending_pair_q;
                            buffered_next_q <= pending_next_q;
                        end
                    end
                    if (imem_valid_o && !imem_ready_i && !request_q) begin
                        request_q <= 1'b1;
                        request_pc_q <= imem_addr_o;
                        request_next_q <= predicted_next;
                        request_pair_q <= predicted_pair;
                        request_discard_q <= 1'b0;
                    end
                    if (request_accept) begin
                        request_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        pending_q <= 1'b1;
                        pending_pc_q <= imem_addr_o;
                        pending_next_q <= issued_next;
                        pending_pair_q <= issued_pair;
                        discard_q <= request_discard_q || redirect || stop_ex || halted_o;
                        if (!request_discard_q) if_pc_q <= issued_next;
                    end
                    if (redirect || stop_ex || halted_o) begin
                        buffered_q <= 1'b0;
                        if (request_q && !request_accept) request_discard_q <= 1'b1;
                        if (pending_q && !imem_rvalid_i) discard_q <= 1'b1;
                        if (redirect) if_pc_q <= actual_next;
                    end
                end
            end
        end
    endgenerate

    logic [4:0] decoded_rs1;
    logic [4:0] decoded_rs2;
    logic [4:0] decoded_rd;
    logic  decoded_reg_write;
    logic [5:0] decoded_alu_op;
    logic  decoded_alu_lhs_pc;
    logic  decoded_alu_rhs_imm;
    logic [31:0] decoded_imm;
    logic [2:0] decoded_branch_op;
    logic  decoded_jump;
    logic  decoded_jalr;
    logic  decoded_mem_read;
    logic  decoded_mem_write;
    logic [1:0] decoded_mem_size;
    logic  decoded_load_unsigned;
    logic  decoded_illegal;
    logic  decoded_ebreak;
    generate
        if (DECODE_PIPELINED) begin : g_decode_pipeline
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    id_valid_q <= 1'b0;
                    id_pc_q <= RESET_VECTOR;
                    id_instr_q <= 32'h00000013;
                    id_predicted_next_q <= RESET_VECTOR;
                    ex_rs1 <= '0;
                    ex_rs2 <= '0;
                    ex_rd <= '0;
                    ex_reg_write <= '0;
                    ex_alu_op <= '0;
                    ex_alu_lhs_pc <= '0;
                    ex_alu_rhs_imm <= '0;
                    ex_imm <= '0;
                    ex_branch_op <= '0;
                    ex_jump <= '0;
                    ex_jalr <= '0;
                    ex_mem_read <= '0;
                    ex_mem_write <= '0;
                    ex_mem_size <= '0;
                    ex_load_unsigned <= '0;
                    ex_illegal <= '0;
                    ex_ebreak <= '0;
                end else if (redirect || stop_ex || halted_o) begin
                    id_valid_q <= 1'b0;
                end else if (!ex_wait) begin
                    id_valid_q <= fetch_valid;
                    id_pc_q <= fetch_pc;
                    id_instr_q <= fetch_instr;
                    id_predicted_next_q <= fetch_predicted_next;
                    ex_rs1 <= decoded_rs1;
                    ex_rs2 <= decoded_rs2;
                    ex_rd <= decoded_rd;
                    ex_reg_write <= decoded_reg_write;
                    ex_alu_op <= decoded_alu_op;
                    ex_alu_lhs_pc <= decoded_alu_lhs_pc;
                    ex_alu_rhs_imm <= decoded_alu_rhs_imm;
                    ex_imm <= decoded_imm;
                    ex_branch_op <= decoded_branch_op;
                    ex_jump <= decoded_jump;
                    ex_jalr <= decoded_jalr;
                    ex_mem_read <= decoded_mem_read;
                    ex_mem_write <= decoded_mem_write;
                    ex_mem_size <= decoded_mem_size;
                    ex_load_unsigned <= decoded_load_unsigned;
                    ex_illegal <= decoded_illegal;
                    ex_ebreak <= decoded_ebreak;
                end
            end
        end else begin : g_comb_decode
            assign ex_rs1 = decoded_rs1;
            assign ex_rs2 = decoded_rs2;
            assign ex_rd = decoded_rd;
            assign ex_reg_write = decoded_reg_write;
            assign ex_alu_op = decoded_alu_op;
            assign ex_alu_lhs_pc = decoded_alu_lhs_pc;
            assign ex_alu_rhs_imm = decoded_alu_rhs_imm;
            assign ex_imm = decoded_imm;
            assign ex_branch_op = decoded_branch_op;
            assign ex_jump = decoded_jump;
            assign ex_jalr = decoded_jalr;
            assign ex_mem_read = decoded_mem_read;
            assign ex_mem_write = decoded_mem_write;
            assign ex_mem_size = decoded_mem_size;
            assign ex_load_unsigned = decoded_load_unsigned;
            assign ex_illegal = decoded_illegal;
            assign ex_ebreak = decoded_ebreak;
            assign id_valid_q = 1'b0;
            assign id_pc_q = 32'b0;
            assign id_instr_q = 32'h00000013;
            assign id_predicted_next_q = 32'b0;
        end
    endgenerate

    rv32i_decoder #(.ZMMUL_ENABLE(ZMMUL_ENABLE), .BITMANIP_ENABLE(BITMANIP_ENABLE)) u_decoder (
        .instr_i          (decode_instr),
        .rs1_o            (decoded_rs1),
        .rs2_o            (decoded_rs2),
        .rd_o             (decoded_rd),
        .reg_write_o      (decoded_reg_write),
        .alu_op_o         (decoded_alu_op),
        .alu_lhs_pc_o     (decoded_alu_lhs_pc),
        .alu_rhs_imm_o    (decoded_alu_rhs_imm),
        .imm_o            (decoded_imm),
        .branch_op_o      (decoded_branch_op),
        .jump_o           (decoded_jump),
        .jalr_o           (decoded_jalr),
        .mem_read_o       (decoded_mem_read),
        .mem_write_o      (decoded_mem_write),
        .mem_size_o       (decoded_mem_size),
        .load_unsigned_o  (decoded_load_unsigned),
        .illegal_o        (decoded_illegal),
        .ebreak_o         (decoded_ebreak)
    );

    rv32i_regfile u_regfile (
        .clk_i       (clk_i),
        .rst_n_i     (rst_n_i),
        .rs1_addr_i  (ex_rs1),
        .rs2_addr_i  (ex_rs2),
        .rs1_data_o  (rf_rs1_data),
        .rs2_data_o  (rf_rs2_data),
        .write_en_i  (wb_valid_q && wb_reg_write_q),
        .rd_addr_i   (wb_rd_q),
        .rd_data_i   (wb_data_q)
        ,.rs3_addr_i(ex2_rs1), .rs4_addr_i(ex2_rs2),
        .rs3_data_o(rf3), .rs4_data_o(rf4),
        .write2_en_i(wb2_valid_q && wb2_reg_write_q), .rd2_addr_i(wb2_rd_q), .rd2_data_i(wb2_data_q)
    );

    // WB-to-EX forwarding; stalled operands subsequently come from the RF
    // after the one WB event has completed.
    always_comb begin
        ex_rs1_value = rf_rs1_data;
        ex_rs2_value = rf_rs2_data;
        if (wb_valid_q && wb_reg_write_q && (wb_rd_q != 5'd0)) begin
            if (wb_rd_q == ex_rs1) ex_rs1_value = wb_data_q;
            if (wb_rd_q == ex_rs2) ex_rs2_value = wb_data_q;
        end
        if (wb2_valid_q && wb2_reg_write_q && wb2_rd_q != 0) begin
            if (wb2_rd_q == ex_rs1) ex_rs1_value = wb2_data_q;
            if (wb2_rd_q == ex_rs2) ex_rs2_value = wb2_data_q;
        end
    end

    assign alu_lhs = ex_alu_lhs_pc  ? ex_pc_q : ex_rs1_value;
    assign alu_rhs = ex_alu_rhs_imm ? ex_imm  : ex_rs2_value;

    rv32i_alu u_alu (
        .lhs_i    (alu_lhs),
        .rhs_i    (alu_rhs),
        .op_i     (ex_alu_op),
        .result_o (alu_result)
    );

    always_comb begin
        branch_condition = 1'b0;
        unique case (ex_branch_op)
            BR_EQ:  branch_condition = (ex_rs1_value == ex_rs2_value);
            BR_NE:  branch_condition = (ex_rs1_value != ex_rs2_value);
            BR_LT:  branch_condition = ($signed(ex_rs1_value) < $signed(ex_rs2_value));
            BR_GE:  branch_condition = ($signed(ex_rs1_value) >= $signed(ex_rs2_value));
            BR_LTU: branch_condition = (ex_rs1_value < ex_rs2_value);
            BR_GEU: branch_condition = (ex_rs1_value >= ex_rs2_value);
            default: branch_condition = 1'b0;
        endcase
    end

    assign control_taken  = ex_jump || ((ex_branch_op != BR_NONE) && branch_condition);
    assign control_target = ex_jalr
                          ? ((ex_rs1_value + ex_imm) & 32'hffff_fffe)
                          : (ex_pc_q + ex_imm);

    assign instruction_misaligned = control_taken && (control_target[1:0] != 2'b00);
    assign data_misaligned = (ex_mem_read || ex_mem_write) &&
                             (((ex_mem_size == MEM_HALF) && alu_result[0]) ||
                              ((ex_mem_size == MEM_WORD) && (alu_result[1:0] != 2'b00)));
    assign ex_fault = ex_illegal || instruction_misaligned || data_misaligned;

    // Data memory uses a 32-bit word plus byte strobes. The address keeps its
    // original low bits so the memory-mapped interconnect can inspect them.
    always_comb begin
        dmem_valid_o = ex_valid_q && (ex_mem_read || ex_mem_write) && !ex_fault && !halted_o;
        dmem_write_o = ex_mem_write;
        dmem_addr_o  = alu_result;
        dmem_wdata_o = ex_rs2_value;
        dmem_wstrb_o = 4'b0000;

        unique case (ex_mem_size)
            MEM_BYTE: begin
                dmem_wstrb_o = 4'b0001 << alu_result[1:0];
                dmem_wdata_o = ex_rs2_value << (8 * alu_result[1:0]);
            end
            MEM_HALF: begin
                dmem_wstrb_o = alu_result[1] ? 4'b1100 : 4'b0011;
                dmem_wdata_o = ex_rs2_value << (16 * alu_result[1]);
            end
            default: begin
                dmem_wstrb_o = 4'b1111;
                dmem_wdata_o = ex_rs2_value;
            end
        endcase
    end

    // Three EX cycles isolate forwarded operands before the DSP. The optional
    // two-cycle path captures the product directly from forwarded operands;
    // both variants retain registered product and signed-high correction.
    wire ex_mul = ZMMUL_ENABLE && (ex_alu_op >= ALU_MUL) && (ex_alu_op <= ALU_MULHU);
    logic [31:0] mul_result;
    logic mul_wait;
    generate
        if (ZMMUL_ENABLE) begin : g_zmmul
            logic [1:0] phase_q;
            logic [31:0] lhs_q, rhs_q;
            logic [63:0] product_q;
            logic [31:0] high_result;
            assign mul_wait = ex_valid_q && ex_mul && !ex_fault && phase_q != MUL_CYCLES-1;
            always_comb begin
                high_result = product_q[63:32];
                if ((ex_alu_op == ALU_MULH || ex_alu_op == ALU_MULHSU) && lhs_q[31])
                    high_result = high_result - rhs_q;
                if (ex_alu_op == ALU_MULH && rhs_q[31])
                    high_result = high_result - lhs_q;
                mul_result = ex_alu_op == ALU_MUL ? product_q[31:0] : high_result;
            end
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) phase_q <= 0;
                else if (halted_o || !ex_valid_q || !ex_mul || ex_fault || phase_q == MUL_CYCLES-1)
                    phase_q <= 0;
                else phase_q <= phase_q + 1'b1;
            end
            // Datapath registers have no reset so FPGA DSP registers can absorb
            // them. phase_q guarantees none is consumed before it is written.
            always_ff @(posedge clk_i) begin
                if (rst_n_i && ex_valid_q && ex_mul && !ex_fault && !halted_o) begin
                    if (phase_q == 0) begin
                        lhs_q <= ex_rs1_value;
                        rhs_q <= ex_rs2_value;
                    end
                    if (MUL_CYCLES == 2) begin
                        if (phase_q == 0) product_q <= ex_rs1_value * ex_rs2_value;
                    end else if (phase_q == 1) product_q <= lhs_q * rhs_q;
                end
            end
        end else begin : g_no_zmmul
            assign mul_wait = 1'b0;
            assign mul_result = 32'b0;
        end
    endgenerate
    assign ex_wait = (dmem_valid_o && !dmem_ready_i) || mul_wait;

    always_comb begin
        shifted_load_data = dmem_rdata_i >> (8 * alu_result[1:0]);
        unique case (ex_mem_size)
            MEM_BYTE: begin
                load_result = ex_load_unsigned
                            ? {24'b0, shifted_load_data[7:0]}
                            : {{24{shifted_load_data[7]}}, shifted_load_data[7:0]};
            end
            MEM_HALF: begin
                load_result = ex_load_unsigned
                            ? {16'b0, shifted_load_data[15:0]}
                            : {{16{shifted_load_data[15]}}, shifted_load_data[15:0]};
            end
            default: load_result = shifted_load_data;
        endcase
    end

    always_comb begin
        if (ex_mem_read) ex_result = load_result;
        else if (ex_jump) ex_result = ex_pc_q + 32'd4;
        else if (ex_mul) ex_result = mul_result;
        else ex_result = alu_result;
    end

    assign commit_valid_o    = wb_valid_q;
    assign commit_pc_o       = wb_pc_q;
    assign commit_instr_o    = wb_instr_q;
    assign commit_rd_write_o = wb_reg_write_q && (wb_rd_q != 5'd0);
    assign commit_rd_o       = wb_rd_q;
    assign commit_data_o     = wb_data_q;
    assign commit2_valid_o = wb2_valid_q;
    assign commit2_pc_o = wb2_pc_q;
    assign commit2_instr_o = wb2_instr_q;
    assign commit2_data_o = wb2_data_q;
    assign commit2_rd_o = wb2_rd_q;
    assign commit2_rd_write_o = wb2_reg_write_q && wb2_rd_q != 0;

    // The second lane accepts ALU and control instructions. A faulting second
    // instruction is serialized so the older instruction retires before the trap.
    logic [4:0] ex2_rs1, ex2_rs2, ex2_rd;
    logic [5:0] ex2_op;
    logic ex2_write, ex2_pc_lhs, ex2_imm_rhs, ex2_jump, ex2_jalr;
    logic ex2_load, ex2_store, ex2_unsigned, ex2_illegal, ex2_ebreak;
    logic [2:0] ex2_branch;
    logic [1:0] ex2_size;
    logic [31:0] ex2_imm, rf3, rf4, ex2_a, ex2_b, ex2_result, ex2_alu_result;
    logic ex2_condition, ex2_taken, ex2_misaligned;
    logic [31:0] ex2_target, ex2_actual_next;
    rv32i_decoder #(.ZMMUL_ENABLE(ZMMUL_ENABLE),.BITMANIP_ENABLE(BITMANIP_ENABLE)) u_decoder2 (
        .instr_i(ex_instr2_q), .rs1_o(ex2_rs1),.rs2_o(ex2_rs2),.rd_o(ex2_rd),
        .reg_write_o(ex2_write),.alu_op_o(ex2_op),.alu_lhs_pc_o(ex2_pc_lhs),.alu_rhs_imm_o(ex2_imm_rhs),
        .imm_o(ex2_imm),.branch_op_o(ex2_branch),.jump_o(ex2_jump),.jalr_o(ex2_jalr),
        .mem_read_o(ex2_load),.mem_write_o(ex2_store),.mem_size_o(ex2_size),
        .load_unsigned_o(ex2_unsigned),.illegal_o(ex2_illegal),.ebreak_o(ex2_ebreak));
    always_comb begin
        ex2_a=rf3;
        ex2_b=rf4;
        if (wb_valid_q && wb_reg_write_q && wb_rd_q!=0) begin
            if (ex2_rs1==wb_rd_q) ex2_a=wb_data_q;
            if (ex2_rs2==wb_rd_q) ex2_b=wb_data_q;
        end
        if (wb2_valid_q && wb2_reg_write_q && wb2_rd_q!=0) begin
            if (ex2_rs1==wb2_rd_q) ex2_a=wb2_data_q;
            if (ex2_rs2==wb2_rd_q) ex2_b=wb2_data_q;
        end
        if (ex_reg_write && ex_rd!=0) begin
            if (ex2_rs1==ex_rd) ex2_a=ex_result;
            if (ex2_rs2==ex_rd) ex2_b=ex_result;
        end
    end
    rv32i_alu u_alu2 (.lhs_i(ex2_pc_lhs ? ex_pc_q+32'd4 : ex2_a),
        .rhs_i(ex2_imm_rhs ? ex2_imm : ex2_b),.op_i(ex2_op),.result_o(ex2_alu_result));
    always_comb begin
        case (ex2_branch)
            BR_EQ: ex2_condition = ex2_a == ex2_b;
            BR_NE: ex2_condition = ex2_a != ex2_b;
            BR_LT: ex2_condition = $signed(ex2_a) < $signed(ex2_b);
            BR_GE: ex2_condition = $signed(ex2_a) >= $signed(ex2_b);
            BR_LTU: ex2_condition = ex2_a < ex2_b;
            BR_GEU: ex2_condition = ex2_a >= ex2_b;
            default: ex2_condition = 1'b0;
        endcase
    end
    assign ex2_taken = ex2_jump || (ex2_branch != BR_NONE && ex2_condition);
    assign ex2_target = ex2_jalr ? ((ex2_a + ex2_imm) & 32'hfffffffe) : ex_pc_q + 32'd4 + ex2_imm;
    assign ex2_actual_next = ex2_taken ? ex2_target : ex_pc_q + 32'd8;
    assign ex2_misaligned = ex2_taken && ex2_target[1:0] != 0;
    assign ex2_result = ex2_jump ? ex_pc_q + 32'd8 : ex2_alu_result;
    assign pair_execute = DUAL_ISSUE && ex_pair_q && !ex2_load && !ex2_store &&
        !ex2_misaligned && !ex2_illegal && !ex2_ebreak &&
        !(ex2_op>=ALU_MUL && ex2_op<=ALU_MULHU) && !control_taken && !ex_fault && !ex_ebreak;
    assign serialize_pair = DUAL_ISSUE && ex_valid_q && ex_pair_q && !pair_execute;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            ex_valid_q     <= 1'b0;
            ex_pc_q        <= 32'b0;
            ex_instr_q     <= 32'h0000_0013;
            ex_pair_q <= 0;
            ex_instr2_q <= 0;
            ex_packet_next_q <= RESET_VECTOR;
            wb2_valid_q <= 0;
            wb2_reg_write_q <= 0;
            wb2_rd_q <= 0;
            wb2_data_q <= 0;
            wb2_pc_q <= 0;
            wb2_instr_q <= 0;
            ex_predicted_next_q <= RESET_VECTOR;
            wb_valid_q     <= 1'b0;
            wb_pc_q        <= 32'b0;
            wb_instr_q     <= 32'h0000_0013;
            wb_reg_write_q <= 1'b0;
            wb_rd_q        <= 5'b0;
            wb_data_q      <= 32'b0;
            halted_o       <= 1'b0;
            trap_o         <= 1'b0;
        end else if (!halted_o) begin
            if (ex_wait) begin
                // Keep IF and EX stable while memory is busy. Clear WB so an
                // already retired instruction cannot be reported twice.
                wb_valid_q <= 1'b0;
                wb2_valid_q <= 0;
            end else begin
                wb_valid_q     <= ex_valid_q && !ex_fault && !ex_ebreak;
                wb_pc_q        <= ex_pc_q;
                wb_instr_q     <= ex_instr_q;
                wb_reg_write_q <= ex_reg_write;
                wb_rd_q        <= ex_rd;
                wb_data_q      <= ex_result;
                wb2_valid_q <= ex_valid_q && pair_execute && !first_redirect;
                wb2_reg_write_q <= ex2_write;
                wb2_rd_q <= ex2_rd;
                wb2_data_q <= ex2_result;
                wb2_pc_q <= ex_pc_q+32'd4;
                wb2_instr_q <= ex_instr2_q;

                if (ex_valid_q && (ex_fault || ex_ebreak)) begin
                    halted_o   <= 1'b1;
                    trap_o     <= ex_fault;
                    ex_valid_q <= 1'b0;
                    wb_valid_q <= 1'b0;
                    wb2_valid_q <= 0;
                    ex_pair_q <= 0;
                end else if (redirect) begin
                    // Flush EX input. The fetch frontend redirects and drains
                    // any outstanding response from the previous path.
                    ex_valid_q <= 1'b0;
                    ex_pair_q <= 0;
                end else if (serialize_pair) begin
                    ex_pair_q <= 0;
                    ex_pc_q <= ex_pc_q+32'd4;
                    ex_instr_q <= ex_instr2_q;
                    ex_predicted_next_q <= ex_packet_next_q;
                end else begin
                    ex_valid_q <= DECODE_PIPELINED ? id_valid_q : fetch_valid;
                    ex_pc_q    <= DECODE_PIPELINED ? id_pc_q : fetch_pc;
                    ex_instr_q <= DECODE_PIPELINED ? id_instr_q : fetch_instr;
                    ex_predicted_next_q <= DECODE_PIPELINED ? id_predicted_next_q :
                        (fetch_pair ? fetch_pc+32'd4 : fetch_predicted_next);
                    ex_pair_q <= DUAL_ISSUE && fetch_valid && fetch_pair;
                    ex_instr2_q <= fetch_instr2;
                    ex_packet_next_q <= fetch_predicted_next;
                end
            end
        end else begin
            wb_valid_q <= 1'b0;
            wb2_valid_q <= 0;
        end
    end
endmodule
