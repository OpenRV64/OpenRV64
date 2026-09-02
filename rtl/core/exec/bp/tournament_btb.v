`ifndef OPENRV64_EXEC_BP_TOURNAMENT_BTB_V
`define OPENRV64_EXEC_BP_TOURNAMENT_BTB_V
`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// Speculative gshare plus per-PC local history, selected by a PC-indexed
// chooser.  Target prediction and recovery use the same ordered checkpoint
// contract as the gshare/BTB predictor.
module openrv64_exec_bp_tournament_btb #(
    parameter integer GLOBAL_PHT_ENTRIES = 2048,
    parameter integer GLOBAL_COUNTER_BITS = 3,
    parameter integer GLOBAL_HISTORY_BITS = 11,
    parameter integer LOCAL_HISTORY_ENTRIES = 512,
    parameter integer LOCAL_HISTORY_BITS = 10,
    parameter integer LOCAL_PHT_ENTRIES = 1024,
    parameter integer LOCAL_COUNTER_BITS = 3,
    parameter integer CHOOSER_ENTRIES = 512,
    parameter integer CHOOSER_COUNTER_BITS = 2,
    parameter integer BTB_ENTRIES = 256,
    parameter integer BTB_TAG_BITS = 16,
    parameter integer INFLIGHT_DEPTH = 16,
    parameter integer ENABLE_TAGGED_RESOLUTION = 0,
    parameter integer GLOBAL_INDEX_WIDTH = $clog2(GLOBAL_PHT_ENTRIES),
    parameter integer LOCAL_HISTORY_INDEX_WIDTH =
        $clog2(LOCAL_HISTORY_ENTRIES),
    parameter integer LOCAL_PHT_INDEX_WIDTH = $clog2(LOCAL_PHT_ENTRIES),
    parameter integer CHOOSER_INDEX_WIDTH = $clog2(CHOOSER_ENTRIES),
    parameter integer BTB_INDEX_WIDTH = $clog2(BTB_ENTRIES),
    parameter integer INFLIGHT_PTR_WIDTH = $clog2(INFLIGHT_DEPTH),
    parameter integer INFLIGHT_COUNT_WIDTH = $clog2(INFLIGHT_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_i,
    input  wire                         recovery_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] recovery_id_i,

    input  wire                         lookup_valid_i,
    input  wire                         lookup_branch_i,
    input  wire                         lookup_jump_i,
    input  wire                         lookup_indirect_i,
    input  wire                         lookup_backward_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] lookup_instr_i,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_id_i,
    input  wire                         lookup_allocate_i,
    input  wire                         ras_prediction_valid_i,
    input  wire [`RV64_XLEN-1:0]        ras_prediction_target_i,

    input  wire                         resolve_valid_i,
    input  wire                         resolve_branch_i,
    input  wire                         resolve_taken_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] resolve_instr_i,
    input  wire [`RV64_XLEN-1:0]        resolve_pc_i,
    input  wire [`RV64_XLEN-1:0]        resolve_target_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] resolve_id_i,

    output wire                         prediction_taken_o,
    output wire                         prediction_weak_o,
    output wire                         prediction_target_valid_o,
    output wire [`RV64_XLEN-1:0]        prediction_target_o,
    output wire                         target_mispredict_o,
    output wire                         allocation_stall_o,
    output wire                         update_overflow_o
);

    localparam [GLOBAL_COUNTER_BITS-1:0] GLOBAL_WEAK_TAKEN =
        {1'b1, {(GLOBAL_COUNTER_BITS-1){1'b0}}};
    localparam [GLOBAL_COUNTER_BITS-1:0] GLOBAL_WEAK_NOT_TAKEN =
        {1'b0, {(GLOBAL_COUNTER_BITS-1){1'b1}}};
    localparam [LOCAL_COUNTER_BITS-1:0] LOCAL_WEAK_TAKEN =
        {1'b1, {(LOCAL_COUNTER_BITS-1){1'b0}}};
    localparam [LOCAL_COUNTER_BITS-1:0] LOCAL_WEAK_NOT_TAKEN =
        {1'b0, {(LOCAL_COUNTER_BITS-1){1'b1}}};
    localparam [CHOOSER_COUNTER_BITS-1:0] CHOOSER_WEAK_GLOBAL =
        {1'b0, {(CHOOSER_COUNTER_BITS-1){1'b1}}};

    reg [GLOBAL_PHT_ENTRIES-1:0] global_valid_q;
    reg [GLOBAL_COUNTER_BITS-1:0]
        global_counter_q [0:GLOBAL_PHT_ENTRIES-1];
    reg [GLOBAL_HISTORY_BITS-1:0] speculative_ghr_q;
    reg [GLOBAL_HISTORY_BITS-1:0] committed_ghr_q;

    reg [LOCAL_HISTORY_BITS-1:0]
        local_history_q [0:LOCAL_HISTORY_ENTRIES-1];
    reg [LOCAL_HISTORY_ENTRIES-1:0] local_history_valid_q;
    reg [LOCAL_PHT_ENTRIES-1:0] local_valid_q;
    reg [LOCAL_COUNTER_BITS-1:0]
        local_counter_q [0:LOCAL_PHT_ENTRIES-1];
    reg [CHOOSER_COUNTER_BITS-1:0]
        chooser_counter_q [0:CHOOSER_ENTRIES-1];
    reg [CHOOSER_ENTRIES-1:0] chooser_valid_q;

    reg [BTB_ENTRIES-1:0] btb_valid_q;
    reg [BTB_TAG_BITS-1:0] btb_tag_q [0:BTB_ENTRIES-1];
    reg [`RV64_XLEN-1:0] btb_target_q [0:BTB_ENTRIES-1];

    reg inflight_branch_q [0:INFLIGHT_DEPTH-1];
    reg inflight_valid_q [0:INFLIGHT_DEPTH-1];
    reg inflight_resolved_q [0:INFLIGHT_DEPTH-1];
    reg inflight_actual_taken_q [0:INFLIGHT_DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        inflight_id_q [0:INFLIGHT_DEPTH-1];
    reg inflight_predicted_taken_q [0:INFLIGHT_DEPTH-1];
    reg inflight_global_prediction_q [0:INFLIGHT_DEPTH-1];
    reg inflight_local_prediction_q [0:INFLIGHT_DEPTH-1];
    reg inflight_target_valid_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_target_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_pc_q [0:INFLIGHT_DEPTH-1];
    reg [GLOBAL_INDEX_WIDTH-1:0]
        inflight_global_index_q [0:INFLIGHT_DEPTH-1];
    reg [GLOBAL_HISTORY_BITS-1:0]
        inflight_ghr_before_q [0:INFLIGHT_DEPTH-1];
    reg [LOCAL_HISTORY_INDEX_WIDTH-1:0]
        inflight_local_history_index_q [0:INFLIGHT_DEPTH-1];
    reg [LOCAL_PHT_INDEX_WIDTH-1:0]
        inflight_local_pht_index_q [0:INFLIGHT_DEPTH-1];
    reg [CHOOSER_INDEX_WIDTH-1:0]
        inflight_chooser_index_q [0:INFLIGHT_DEPTH-1];
    reg [INFLIGHT_PTR_WIDTH-1:0] inflight_head_q;
    reg [INFLIGHT_PTR_WIDTH-1:0] inflight_tail_q;
    reg [INFLIGHT_COUNT_WIDTH-1:0] inflight_count_q;
    reg update_overflow_q;

    function automatic is_link_reg;
        input [`RV64_REG_ADDR_WIDTH-1:0] reg_addr;
        begin
            is_link_reg = (reg_addr == 5'd1) || (reg_addr == 5'd5);
        end
    endfunction

    function automatic id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    wire lookup_is_jalr =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JALR;
    wire lookup_return = lookup_valid_i && lookup_indirect_i &&
                         lookup_is_jalr &&
                         is_link_reg(`RV64_RS1(lookup_instr_i)) &&
                         !is_link_reg(`RV64_RD(lookup_instr_i));
    wire resolve_is_jalr =
        `RV64_OPCODE(resolve_instr_i) == `RV64_OPCODE_JALR;

    wire [GLOBAL_INDEX_WIDTH-1:0] lookup_global_pc_index =
        lookup_pc_i[GLOBAL_INDEX_WIDTH+1:2];
    wire [GLOBAL_INDEX_WIDTH-1:0] lookup_global_index =
        lookup_global_pc_index ^
        speculative_ghr_q[GLOBAL_INDEX_WIDTH-1:0];
    wire [LOCAL_HISTORY_INDEX_WIDTH-1:0] lookup_local_history_index =
        lookup_pc_i[LOCAL_HISTORY_INDEX_WIDTH+1:2];
    wire [LOCAL_HISTORY_BITS-1:0] lookup_local_history =
        local_history_valid_q[lookup_local_history_index] ?
            local_history_q[lookup_local_history_index] :
            {LOCAL_HISTORY_BITS{1'b0}};
    wire [LOCAL_PHT_INDEX_WIDTH-1:0] lookup_local_pht_index =
        lookup_local_history[LOCAL_PHT_INDEX_WIDTH-1:0];
    wire [CHOOSER_INDEX_WIDTH-1:0] lookup_chooser_index =
        lookup_pc_i[CHOOSER_INDEX_WIDTH+1:2];

    wire global_learned_direction =
        global_counter_q[lookup_global_index][GLOBAL_COUNTER_BITS-1];
    wire local_learned_direction =
        local_counter_q[lookup_local_pht_index][LOCAL_COUNTER_BITS-1];
    wire global_prediction = global_valid_q[lookup_global_index] ?
        global_learned_direction : lookup_backward_i;
    wire local_prediction = local_valid_q[lookup_local_pht_index] ?
        local_learned_direction : lookup_backward_i;
    wire [CHOOSER_COUNTER_BITS-1:0] lookup_chooser_counter =
        chooser_valid_q[lookup_chooser_index] ?
            chooser_counter_q[lookup_chooser_index] :
            CHOOSER_WEAK_GLOBAL;
    wire chooser_select_local =
        lookup_chooser_counter[CHOOSER_COUNTER_BITS-1];
    wire conditional_prediction =
        chooser_select_local ? local_prediction : global_prediction;
    // FAL is useful when either direction component is cold for this branch or
    // when the trained component predictions disagree. Counter strength and
    // chooser confidence do not affect this signal.
    wire conditional_prediction_weak =
        !global_valid_q[lookup_global_index] ||
        !local_history_valid_q[lookup_local_history_index] ||
        !local_valid_q[lookup_local_pht_index] ||
        (global_prediction != local_prediction);

    wire [BTB_INDEX_WIDTH-1:0] lookup_btb_index =
        lookup_pc_i[BTB_INDEX_WIDTH+1:2];
    wire [BTB_TAG_BITS-1:0] lookup_btb_tag =
        lookup_pc_i[BTB_INDEX_WIDTH+2 +: BTB_TAG_BITS];
    wire lookup_btb_hit = btb_valid_q[lookup_btb_index] &&
        (btb_tag_q[lookup_btb_index] == lookup_btb_tag);
    wire btb_prediction_valid = lookup_valid_i && lookup_indirect_i &&
                                !lookup_return && lookup_btb_hit;
    wire selected_target_valid = lookup_return ?
        ras_prediction_valid_i : btb_prediction_valid;
    wire [`RV64_XLEN-1:0] selected_target = lookup_return ?
        ras_prediction_target_i : btb_target_q[lookup_btb_index];

    wire queue_full = inflight_count_q == INFLIGHT_DEPTH;
    reg resolve_tag_match;
    reg [INFLIGHT_PTR_WIDTH-1:0] resolve_tag_index;
    reg [INFLIGHT_COUNT_WIDTH-1:0] squash_keep_count;
    reg [INFLIGHT_COUNT_WIDTH-1:0] recovery_keep_count;
    reg recovery_younger_found;
    reg [INFLIGHT_PTR_WIDTH-1:0] recovery_younger_index;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] recovery_younger_id;
    integer search_index;
    always @* begin
        resolve_tag_match = 1'b0;
        resolve_tag_index = inflight_head_q;
        squash_keep_count = {INFLIGHT_COUNT_WIDTH{1'b0}};
        recovery_keep_count = {INFLIGHT_COUNT_WIDTH{1'b0}};
        recovery_younger_found = 1'b0;
        recovery_younger_index = inflight_head_q;
        recovery_younger_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        for (search_index = 0; search_index < INFLIGHT_DEPTH;
             search_index = search_index + 1) begin
            if (inflight_valid_q[search_index] &&
                (inflight_id_q[search_index] == resolve_id_i) &&
                !resolve_tag_match) begin
                resolve_tag_match = 1'b1;
                resolve_tag_index = search_index[INFLIGHT_PTR_WIDTH-1:0];
            end
            if (inflight_valid_q[search_index] &&
                !id_is_younger(inflight_id_q[search_index], resolve_id_i))
                squash_keep_count = squash_keep_count + 1'b1;
            if (inflight_valid_q[search_index] &&
                !id_is_younger(inflight_id_q[search_index], recovery_id_i))
                recovery_keep_count = recovery_keep_count + 1'b1;
            if (inflight_valid_q[search_index] &&
                id_is_younger(inflight_id_q[search_index], recovery_id_i) &&
                (!recovery_younger_found ||
                 id_is_younger(recovery_younger_id,
                               inflight_id_q[search_index]))) begin
                recovery_younger_found = 1'b1;
                recovery_younger_index =
                    search_index[INFLIGHT_PTR_WIDTH-1:0];
                recovery_younger_id = inflight_id_q[search_index];
            end
        end
    end

    wire [INFLIGHT_PTR_WIDTH-1:0] resolve_index =
        (ENABLE_TAGGED_RESOLUTION != 0) ?
            resolve_tag_index : inflight_head_q;
    wire resolve_has_record = resolve_valid_i &&
        (inflight_count_q != 0) &&
        ((ENABLE_TAGGED_RESOLUTION == 0) || resolve_tag_match);
    wire resolved_target_valid = inflight_target_valid_q[resolve_index];

    assign prediction_taken_o = lookup_valid_i &&
        ((lookup_branch_i && conditional_prediction) ||
         (lookup_jump_i && !lookup_indirect_i) ||
         (lookup_indirect_i && selected_target_valid));
    assign prediction_weak_o = lookup_valid_i && lookup_branch_i &&
                               conditional_prediction_weak;
    assign prediction_target_valid_o = lookup_valid_i &&
                                       selected_target_valid;
    assign prediction_target_o = selected_target;
    assign target_mispredict_o = resolve_has_record &&
        resolved_target_valid && resolve_taken_i &&
        (resolve_target_i != inflight_target_q[resolve_index]);
    assign allocation_stall_o = lookup_valid_i && queue_full;
    assign update_overflow_o = update_overflow_q;

    wire [GLOBAL_COUNTER_BITS-1:0] global_counter_max =
        {GLOBAL_COUNTER_BITS{1'b1}};
    wire [LOCAL_COUNTER_BITS-1:0] local_counter_max =
        {LOCAL_COUNTER_BITS{1'b1}};
    wire [CHOOSER_COUNTER_BITS-1:0] chooser_counter_max =
        {CHOOSER_COUNTER_BITS{1'b1}};
    wire [GLOBAL_INDEX_WIDTH-1:0] resolved_global_index =
        inflight_global_index_q[resolve_index];
    wire [LOCAL_HISTORY_INDEX_WIDTH-1:0]
        resolved_local_history_index =
            inflight_local_history_index_q[resolve_index];
    wire [LOCAL_PHT_INDEX_WIDTH-1:0] resolved_local_pht_index =
        inflight_local_pht_index_q[resolve_index];
    wire [CHOOSER_INDEX_WIDTH-1:0] resolved_chooser_index =
        inflight_chooser_index_q[resolve_index];
    wire [CHOOSER_COUNTER_BITS-1:0] resolved_chooser_counter =
        chooser_valid_q[resolved_chooser_index] ?
            chooser_counter_q[resolved_chooser_index] :
            CHOOSER_WEAK_GLOBAL;
    wire [GLOBAL_HISTORY_BITS-1:0] resolved_global_history =
        {inflight_ghr_before_q[resolve_index][GLOBAL_HISTORY_BITS-2:0],
         resolve_taken_i};
    wire [LOCAL_HISTORY_BITS-1:0] resolved_local_history =
        {inflight_local_pht_index_q[resolve_index]
            [LOCAL_HISTORY_BITS-2:0], resolve_taken_i};
    wire head_commit = (inflight_count_q != 0) &&
                       inflight_valid_q[inflight_head_q] &&
                       inflight_resolved_q[inflight_head_q];
    wire recovery_head_commit = head_commit &&
        !id_is_younger(inflight_id_q[inflight_head_q], recovery_id_i);
    wire [GLOBAL_HISTORY_BITS-1:0] committed_head_history =
        {inflight_ghr_before_q[inflight_head_q]
            [GLOBAL_HISTORY_BITS-2:0],
         inflight_actual_taken_q[inflight_head_q]};
    wire record_commit = (ENABLE_TAGGED_RESOLUTION != 0) ?
                         head_commit : resolve_has_record;
    wire record_commit_branch = (ENABLE_TAGGED_RESOLUTION != 0) ?
        inflight_branch_q[inflight_head_q] :
        inflight_branch_q[resolve_index];
    wire [GLOBAL_HISTORY_BITS-1:0] record_commit_history =
        (ENABLE_TAGGED_RESOLUTION != 0) ?
            committed_head_history : resolved_global_history;
    wire [BTB_INDEX_WIDTH-1:0] resolve_btb_index =
        resolve_pc_i[BTB_INDEX_WIDTH+1:2];
    wire [BTB_TAG_BITS-1:0] resolve_btb_tag =
        resolve_pc_i[BTB_INDEX_WIDTH+2 +: BTB_TAG_BITS];

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_valid_q <= {GLOBAL_PHT_ENTRIES{1'b0}};
            speculative_ghr_q <= {GLOBAL_HISTORY_BITS{1'b0}};
            committed_ghr_q <= {GLOBAL_HISTORY_BITS{1'b0}};
            local_history_valid_q <= {LOCAL_HISTORY_ENTRIES{1'b0}};
            local_valid_q <= {LOCAL_PHT_ENTRIES{1'b0}};
            chooser_valid_q <= {CHOOSER_ENTRIES{1'b0}};
            btb_valid_q <= {BTB_ENTRIES{1'b0}};
            inflight_head_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
            inflight_tail_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
            inflight_count_q <= {INFLIGHT_COUNT_WIDTH{1'b0}};
            update_overflow_q <= 1'b0;
            for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                 reset_index = reset_index + 1) begin
                inflight_valid_q[reset_index] <= 1'b0;
                inflight_resolved_q[reset_index] <= 1'b0;
                inflight_actual_taken_q[reset_index] <= 1'b0;
                inflight_id_q[reset_index] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            end
        end else begin
            if (lookup_allocate_i && queue_full)
                update_overflow_q <= 1'b1;

            if (resolve_has_record &&
                inflight_branch_q[resolve_index]) begin
                global_valid_q[resolved_global_index] <= 1'b1;
                local_valid_q[resolved_local_pht_index] <= 1'b1;

                if (inflight_global_prediction_q[resolve_index] !=
                    inflight_local_prediction_q[resolve_index])
                    chooser_valid_q[resolved_chooser_index] <= 1'b1;

                // Conditional resolution is program ordered at the scalar
                // branch port.  The saved prediction-time history avoids a
                // lookup-time alias changing the local update destination.
                local_history_valid_q[resolved_local_history_index] <= 1'b1;
            end

            if (resolve_has_record && resolve_is_jalr && resolve_taken_i)
                btb_valid_q[resolve_btb_index] <= 1'b1;

            if (record_commit && record_commit_branch)
                committed_ghr_q <= record_commit_history;

            if (resolve_has_record &&
                (ENABLE_TAGGED_RESOLUTION != 0)) begin
                inflight_resolved_q[resolve_index] <= 1'b1;
                inflight_actual_taken_q[resolve_index] <= resolve_taken_i;
            end

            if (flush_i) begin
                inflight_head_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
                inflight_tail_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
                inflight_count_q <= {INFLIGHT_COUNT_WIDTH{1'b0}};
                for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                     reset_index = reset_index + 1) begin
                    inflight_valid_q[reset_index] <= 1'b0;
                    inflight_resolved_q[reset_index] <= 1'b0;
                end
                if (resolve_has_record &&
                    (resolve_index == inflight_head_q) &&
                    inflight_branch_q[resolve_index]) begin
                    committed_ghr_q <= resolved_global_history;
                    speculative_ghr_q <= resolved_global_history;
                end else if (record_commit) begin
                    speculative_ghr_q <= record_commit_history;
                end else begin
                    speculative_ghr_q <= committed_ghr_q;
                end
            end else if (recovery_i &&
                         (ENABLE_TAGGED_RESOLUTION != 0)) begin
                inflight_tail_q <= inflight_head_q + recovery_keep_count;
                inflight_count_q <= recovery_keep_count -
                    {{(INFLIGHT_COUNT_WIDTH-1){1'b0}},
                     recovery_head_commit};
                if (recovery_head_commit) begin
                    inflight_valid_q[inflight_head_q] <= 1'b0;
                    inflight_resolved_q[inflight_head_q] <= 1'b0;
                    inflight_head_q <= inflight_head_q + 1'b1;
                end
                for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                     reset_index = reset_index + 1) begin
                    if (inflight_valid_q[reset_index] &&
                        id_is_younger(inflight_id_q[reset_index],
                                      recovery_id_i)) begin
                        inflight_valid_q[reset_index] <= 1'b0;
                        inflight_resolved_q[reset_index] <= 1'b0;
                    end
                end
                if (recovery_younger_found)
                    speculative_ghr_q <=
                        inflight_ghr_before_q[recovery_younger_index];
            end else if (squash_i && resolve_has_record &&
                         (ENABLE_TAGGED_RESOLUTION != 0)) begin
                inflight_tail_q <= resolve_index + 1'b1;
                inflight_count_q <= squash_keep_count -
                    {{(INFLIGHT_COUNT_WIDTH-1){1'b0}}, head_commit};
                if (head_commit) begin
                    inflight_valid_q[inflight_head_q] <= 1'b0;
                    inflight_resolved_q[inflight_head_q] <= 1'b0;
                    inflight_head_q <= inflight_head_q + 1'b1;
                end
                for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                     reset_index = reset_index + 1) begin
                    if (inflight_valid_q[reset_index] &&
                        id_is_younger(inflight_id_q[reset_index],
                                      resolve_id_i)) begin
                        inflight_valid_q[reset_index] <= 1'b0;
                        inflight_resolved_q[reset_index] <= 1'b0;
                    end
                end
                inflight_resolved_q[resolve_index] <= 1'b1;
                inflight_actual_taken_q[resolve_index] <= resolve_taken_i;
                speculative_ghr_q <= inflight_branch_q[resolve_index] ?
                    resolved_global_history :
                    inflight_ghr_before_q[resolve_index];
            end else begin
                case ({lookup_allocate_i && !queue_full,
                       record_commit})
                    2'b10: begin
                        inflight_tail_q <= inflight_tail_q + 1'b1;
                        inflight_count_q <= inflight_count_q + 1'b1;
                    end
                    2'b01: begin
                        inflight_head_q <= inflight_head_q + 1'b1;
                        inflight_count_q <= inflight_count_q - 1'b1;
                        inflight_valid_q[inflight_head_q] <= 1'b0;
                        inflight_resolved_q[inflight_head_q] <= 1'b0;
                    end
                    2'b11: begin
                        inflight_tail_q <= inflight_tail_q + 1'b1;
                        inflight_head_q <= inflight_head_q + 1'b1;
                        inflight_valid_q[inflight_head_q] <= 1'b0;
                        inflight_resolved_q[inflight_head_q] <= 1'b0;
                    end
                    default: begin
                    end
                endcase

                if (lookup_allocate_i && !queue_full) begin
                    inflight_valid_q[inflight_tail_q] <= 1'b1;
                    inflight_resolved_q[inflight_tail_q] <= 1'b0;
                    inflight_actual_taken_q[inflight_tail_q] <= 1'b0;
                    inflight_id_q[inflight_tail_q] <= lookup_id_i;
                    inflight_branch_q[inflight_tail_q] <= lookup_branch_i;
                    inflight_predicted_taken_q[inflight_tail_q] <=
                        prediction_taken_o;
                    inflight_global_prediction_q[inflight_tail_q] <=
                        global_prediction;
                    inflight_local_prediction_q[inflight_tail_q] <=
                        local_prediction;
                    inflight_target_valid_q[inflight_tail_q] <=
                        prediction_target_valid_o;
                    inflight_target_q[inflight_tail_q] <=
                        prediction_target_o;
                    inflight_pc_q[inflight_tail_q] <= lookup_pc_i;
                    inflight_global_index_q[inflight_tail_q] <=
                        lookup_global_index;
                    inflight_ghr_before_q[inflight_tail_q] <=
                        speculative_ghr_q;
                    inflight_local_history_index_q[inflight_tail_q] <=
                        lookup_local_history_index;
                    inflight_local_pht_index_q[inflight_tail_q] <=
                        lookup_local_pht_index;
                    inflight_chooser_index_q[inflight_tail_q] <=
                        lookup_chooser_index;
                    if (lookup_branch_i)
                        speculative_ghr_q <=
                            {speculative_ghr_q[GLOBAL_HISTORY_BITS-2:0],
                             conditional_prediction};
                end
            end
        end
    end

    // Table contents are deliberately reset-free.  Separate resettable valid
    // vectors define cold state without turning the data arrays into flops.
    always @(posedge clk) begin
        if (rst_n && resolve_has_record &&
            inflight_branch_q[resolve_index]) begin
            if (!global_valid_q[resolved_global_index])
                global_counter_q[resolved_global_index] <=
                    resolve_taken_i ? GLOBAL_WEAK_TAKEN :
                                      GLOBAL_WEAK_NOT_TAKEN;
            else if (resolve_taken_i) begin
                if (global_counter_q[resolved_global_index] !=
                    global_counter_max)
                    global_counter_q[resolved_global_index] <=
                        global_counter_q[resolved_global_index] + 1'b1;
            end else if (global_counter_q[resolved_global_index] != 0)
                global_counter_q[resolved_global_index] <=
                    global_counter_q[resolved_global_index] - 1'b1;

            if (!local_valid_q[resolved_local_pht_index])
                local_counter_q[resolved_local_pht_index] <=
                    resolve_taken_i ? LOCAL_WEAK_TAKEN :
                                      LOCAL_WEAK_NOT_TAKEN;
            else if (resolve_taken_i) begin
                if (local_counter_q[resolved_local_pht_index] !=
                    local_counter_max)
                    local_counter_q[resolved_local_pht_index] <=
                        local_counter_q[resolved_local_pht_index] + 1'b1;
            end else if (local_counter_q[resolved_local_pht_index] != 0)
                local_counter_q[resolved_local_pht_index] <=
                    local_counter_q[resolved_local_pht_index] - 1'b1;

            if (inflight_global_prediction_q[resolve_index] !=
                inflight_local_prediction_q[resolve_index]) begin
                if (inflight_local_prediction_q[resolve_index] ==
                    resolve_taken_i) begin
                    if (resolved_chooser_counter != chooser_counter_max)
                        chooser_counter_q[resolved_chooser_index] <=
                            resolved_chooser_counter + 1'b1;
                end else if
                    (inflight_global_prediction_q[resolve_index] ==
                     resolve_taken_i) begin
                    if (resolved_chooser_counter != 0)
                        chooser_counter_q[resolved_chooser_index] <=
                            resolved_chooser_counter - 1'b1;
                end
            end

            local_history_q[resolved_local_history_index] <=
                resolved_local_history;
        end

        if (rst_n && resolve_has_record &&
            resolve_is_jalr && resolve_taken_i) begin
            btb_tag_q[resolve_btb_index] <= resolve_btb_tag;
            btb_target_q[resolve_btb_index] <= resolve_target_i;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((GLOBAL_PHT_ENTRIES < 2) ||
            ((1 << GLOBAL_INDEX_WIDTH) != GLOBAL_PHT_ENTRIES))
            $fatal(1,
                   "tournament GLOBAL_PHT_ENTRIES must be a power of two");
        if ((GLOBAL_HISTORY_BITS < 2) ||
            (GLOBAL_HISTORY_BITS < GLOBAL_INDEX_WIDTH))
            $fatal(1,
                   "tournament global history must cover its PHT index");
        if (GLOBAL_COUNTER_BITS < 2)
            $fatal(1, "tournament global counters must be >= 2 bits");
        if ((LOCAL_HISTORY_ENTRIES < 2) ||
            ((1 << LOCAL_HISTORY_INDEX_WIDTH) != LOCAL_HISTORY_ENTRIES))
            $fatal(1,
                   "tournament local-history entries must be a power of two");
        if ((LOCAL_HISTORY_BITS < 2) ||
            ((1 << LOCAL_PHT_INDEX_WIDTH) != LOCAL_PHT_ENTRIES) ||
            (LOCAL_HISTORY_BITS != LOCAL_PHT_INDEX_WIDTH))
            $fatal(1,
                   "tournament local PHT must have 2^LOCAL_HISTORY_BITS entries");
        if (LOCAL_COUNTER_BITS < 2)
            $fatal(1, "tournament local counters must be >= 2 bits");
        if ((CHOOSER_ENTRIES < 2) ||
            ((1 << CHOOSER_INDEX_WIDTH) != CHOOSER_ENTRIES) ||
            (CHOOSER_COUNTER_BITS < 2))
            $fatal(1, "tournament chooser geometry is invalid");
        if ((BTB_ENTRIES < 2) ||
            ((1 << BTB_INDEX_WIDTH) != BTB_ENTRIES))
            $fatal(1, "tournament BTB entries must be a power of two");
        if ((BTB_TAG_BITS < 4) ||
            (BTB_INDEX_WIDTH + BTB_TAG_BITS + 2 > `RV64_XLEN))
            $fatal(1, "tournament BTB tag width is out of range");
        if ((INFLIGHT_DEPTH < 2) ||
            ((1 << INFLIGHT_PTR_WIDTH) != INFLIGHT_DEPTH))
            $fatal(1,
                   "tournament inflight depth must be a power of two");
        if (INFLIGHT_DEPTH >=
            (1 << (`OPENRV64_INSTR_ID_WIDTH - 1)))
            $fatal(1,
                   "tournament inflight depth exceeds modular ID half-range");
    end

    always @(posedge clk) begin
        if (rst_n && resolve_valid_i &&
            (ENABLE_TAGGED_RESOLUTION != 0) && !resolve_tag_match)
            $error("tournament tagged resolution missed id=%016x pc=%016x",
                   resolve_id_i, resolve_pc_i);
        if (rst_n && resolve_has_record &&
            (ENABLE_TAGGED_RESOLUTION == 0) &&
            (resolve_pc_i != inflight_pc_q[resolve_index]))
            $error("tournament resolution order mismatch: got pc=%016x expected=%016x",
                   resolve_pc_i, inflight_pc_q[resolve_index]);
        if (rst_n && resolve_has_record &&
            (resolve_branch_i != inflight_branch_q[resolve_index]))
            $error("tournament resolution kind mismatch at pc=%016x",
                   resolve_pc_i);
    end
`endif

endmodule

`endif
