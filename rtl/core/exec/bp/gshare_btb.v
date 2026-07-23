`ifndef OPENRV64_EXEC_BP_GSHARE_BTB_V
`define OPENRV64_EXEC_BP_GSHARE_BTB_V
`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// Speculative global-history direction predictor plus an indirect-target
// table.  Every admitted control transfer gets an ordered record.  Besides
// carrying the exact PHT index used at prediction time, that record is the
// history checkpoint used after a redirect and qualifies target comparisons;
// a target predicted for a younger return can therefore never be compared
// against an older direct jump.
//
// Direct branches and JALs do not consume BTB entries because their targets
// are available from decode.  RISC-V return hints use the external RAS and
// deliberately do not fall back to the BTB when the RAS is empty.
module openrv64_exec_bp_gshare_btb #(
    parameter integer PHT_ENTRIES = 256,
    parameter integer COUNTER_BITS = 3,
    parameter integer BTB_ENTRIES = 256,
    parameter integer BTB_TAG_BITS = 16,
    parameter integer INFLIGHT_DEPTH = 16,
    parameter integer ENABLE_TAGGED_RESOLUTION = 0,
    parameter integer PHT_INDEX_WIDTH = $clog2(PHT_ENTRIES),
    parameter integer BTB_INDEX_WIDTH = $clog2(BTB_ENTRIES),
    parameter integer INFLIGHT_PTR_WIDTH = $clog2(INFLIGHT_DEPTH),
    parameter integer INFLIGHT_COUNT_WIDTH = $clog2(INFLIGHT_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_i,

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

    localparam [COUNTER_BITS-1:0] WEAK_TAKEN =
        {1'b1, {(COUNTER_BITS-1){1'b0}}};
    localparam [COUNTER_BITS-1:0] WEAK_NOT_TAKEN =
        {1'b0, {(COUNTER_BITS-1){1'b1}}};

    reg [PHT_ENTRIES-1:0] pht_valid_q;
    reg [COUNTER_BITS-1:0] pht_counter_q [0:PHT_ENTRIES-1];
    reg [PHT_INDEX_WIDTH-1:0] speculative_ghr_q;
    reg [PHT_INDEX_WIDTH-1:0] committed_ghr_q;

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
    reg inflight_target_valid_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_target_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_pc_q [0:INFLIGHT_DEPTH-1];
    reg [PHT_INDEX_WIDTH-1:0] inflight_pht_index_q
        [0:INFLIGHT_DEPTH-1];
    reg [PHT_INDEX_WIDTH-1:0] inflight_ghr_before_q
        [0:INFLIGHT_DEPTH-1];
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

    wire [PHT_INDEX_WIDTH-1:0] lookup_pc_index =
        lookup_pc_i[PHT_INDEX_WIDTH+1:2];
    wire [PHT_INDEX_WIDTH-1:0] lookup_pht_index =
        lookup_pc_index ^ speculative_ghr_q;
    wire learned_direction =
        pht_counter_q[lookup_pht_index][COUNTER_BITS-1];
    wire conditional_prediction = pht_valid_q[lookup_pht_index] ?
        learned_direction : lookup_backward_i;
    // A counter is direction-confident only when its two most-significant
    // bits agree.  This keeps the backup fetch active throughout the middle
    // half of the hysteresis range, not just at the direction boundary.
    wire learned_prediction_weak =
        pht_counter_q[lookup_pht_index][COUNTER_BITS-1] !=
        pht_counter_q[lookup_pht_index][COUNTER_BITS-2];

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
    integer search_index;
    always @* begin
        resolve_tag_match = 1'b0;
        resolve_tag_index = inflight_head_q;
        squash_keep_count = {INFLIGHT_COUNT_WIDTH{1'b0}};
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
        (!pht_valid_q[lookup_pht_index] || learned_prediction_weak);
    assign prediction_target_valid_o = lookup_valid_i &&
                                       selected_target_valid;
    assign prediction_target_o = selected_target;
    assign target_mispredict_o = resolve_has_record &&
        resolved_target_valid && resolve_taken_i &&
        (resolve_target_i != inflight_target_q[resolve_index]);
    assign allocation_stall_o = lookup_valid_i && queue_full;
    assign update_overflow_o = update_overflow_q;

    wire [COUNTER_BITS-1:0] counter_max = {COUNTER_BITS{1'b1}};
    wire [PHT_INDEX_WIDTH-1:0] resolved_pht_index =
        inflight_pht_index_q[resolve_index];
    wire [PHT_INDEX_WIDTH-1:0] resolved_history =
        {inflight_ghr_before_q[resolve_index][PHT_INDEX_WIDTH-2:0],
         resolve_taken_i};
    wire head_commit = (inflight_count_q != 0) &&
                       inflight_valid_q[inflight_head_q] &&
                       inflight_resolved_q[inflight_head_q];
    wire [PHT_INDEX_WIDTH-1:0] committed_head_history =
        {inflight_ghr_before_q[inflight_head_q][PHT_INDEX_WIDTH-2:0],
         inflight_actual_taken_q[inflight_head_q]};
    wire record_commit = (ENABLE_TAGGED_RESOLUTION != 0) ?
                         head_commit : resolve_has_record;
    wire record_commit_branch = (ENABLE_TAGGED_RESOLUTION != 0) ?
        inflight_branch_q[inflight_head_q] :
        inflight_branch_q[resolve_index];
    wire [PHT_INDEX_WIDTH-1:0] record_commit_history =
        (ENABLE_TAGGED_RESOLUTION != 0) ?
            committed_head_history : resolved_history;
    wire [BTB_INDEX_WIDTH-1:0] resolve_btb_index =
        resolve_pc_i[BTB_INDEX_WIDTH+1:2];
    wire [BTB_TAG_BITS-1:0] resolve_btb_tag =
        resolve_pc_i[BTB_INDEX_WIDTH+2 +: BTB_TAG_BITS];

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pht_valid_q <= {PHT_ENTRIES{1'b0}};
            speculative_ghr_q <= {PHT_INDEX_WIDTH{1'b0}};
            committed_ghr_q <= {PHT_INDEX_WIDTH{1'b0}};
            btb_valid_q <= {BTB_ENTRIES{1'b0}};
            inflight_head_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
            inflight_tail_q <= {INFLIGHT_PTR_WIDTH{1'b0}};
            inflight_count_q <= {INFLIGHT_COUNT_WIDTH{1'b0}};
            update_overflow_q <= 1'b0;
            for (reset_index = 0; reset_index < PHT_ENTRIES;
                 reset_index = reset_index + 1)
                pht_counter_q[reset_index] <= {COUNTER_BITS{1'b0}};
            for (reset_index = 0; reset_index < BTB_ENTRIES;
                 reset_index = reset_index + 1) begin
                btb_tag_q[reset_index] <= {BTB_TAG_BITS{1'b0}};
                btb_target_q[reset_index] <= {`RV64_XLEN{1'b0}};
            end
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

            // Direction updates use the prediction-time gshare index, not a
            // recomputed index after younger speculative history has changed.
            // Tagged speculation may resolve branches out of order, but the
            // committed history below still advances only from the queue head.
            if (resolve_has_record &&
                inflight_branch_q[resolve_index]) begin
                if (!pht_valid_q[resolved_pht_index]) begin
                    pht_valid_q[resolved_pht_index] <= 1'b1;
                    pht_counter_q[resolved_pht_index] <= resolve_taken_i ?
                        WEAK_TAKEN : WEAK_NOT_TAKEN;
                end else if (resolve_taken_i) begin
                    if (pht_counter_q[resolved_pht_index] != counter_max)
                        pht_counter_q[resolved_pht_index] <=
                            pht_counter_q[resolved_pht_index] + 1'b1;
                end else if (pht_counter_q[resolved_pht_index] != 0) begin
                    pht_counter_q[resolved_pht_index] <=
                        pht_counter_q[resolved_pht_index] - 1'b1;
                end
            end

            if (resolve_has_record && resolve_is_jalr && resolve_taken_i) begin
                btb_valid_q[resolve_btb_index] <= 1'b1;
                btb_tag_q[resolve_btb_index] <= resolve_btb_tag;
                btb_target_q[resolve_btb_index] <= resolve_target_i;
            end

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
                    committed_ghr_q <= resolved_history;
                    speculative_ghr_q <= resolved_history;
                end else if (record_commit) begin
                    speculative_ghr_q <= record_commit_history;
                end else begin
                    speculative_ghr_q <= committed_ghr_q;
                end
            end else if (squash_i && resolve_has_record &&
                         (ENABLE_TAGGED_RESOLUTION != 0)) begin
                // Keep the resolving branch and every older checkpoint.  New
                // correct-path predictions append immediately after it.  The
                // bounded live set makes modular ID ordering unambiguous.
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
                    resolved_history :
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
                    inflight_target_valid_q[inflight_tail_q] <=
                        prediction_target_valid_o;
                    inflight_target_q[inflight_tail_q] <=
                        prediction_target_o;
                    inflight_pc_q[inflight_tail_q] <= lookup_pc_i;
                    inflight_pht_index_q[inflight_tail_q] <=
                        lookup_pht_index;
                    inflight_ghr_before_q[inflight_tail_q] <=
                        speculative_ghr_q;
                    if (lookup_branch_i)
                        speculative_ghr_q <=
                            {speculative_ghr_q[PHT_INDEX_WIDTH-2:0],
                             conditional_prediction};
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((PHT_ENTRIES < 2) ||
            ((1 << PHT_INDEX_WIDTH) != PHT_ENTRIES))
            $fatal(1, "gshare PHT_ENTRIES must be a power of two >= 2");
        if (COUNTER_BITS < 2)
            $fatal(1, "gshare COUNTER_BITS must be >= 2");
        if ((BTB_ENTRIES < 2) ||
            ((1 << BTB_INDEX_WIDTH) != BTB_ENTRIES))
            $fatal(1, "gshare BTB_ENTRIES must be a power of two >= 2");
        if ((BTB_TAG_BITS < 4) ||
            (BTB_INDEX_WIDTH + BTB_TAG_BITS + 2 > `RV64_XLEN))
            $fatal(1, "gshare BTB_TAG_BITS is out of range");
        if ((INFLIGHT_DEPTH < 2) ||
            ((1 << INFLIGHT_PTR_WIDTH) != INFLIGHT_DEPTH))
            $fatal(1,
                   "gshare INFLIGHT_DEPTH must be a power of two >= 2");
        if (INFLIGHT_DEPTH >=
            (1 << (`OPENRV64_INSTR_ID_WIDTH - 1)))
            $fatal(1,
                   "gshare INFLIGHT_DEPTH must fit the modular ID half-range");
    end

    always @(posedge clk) begin
        if (rst_n && resolve_valid_i &&
            (ENABLE_TAGGED_RESOLUTION != 0) && !resolve_tag_match)
            $error("gshare tagged resolution missed id=%016x pc=%016x",
                   resolve_id_i, resolve_pc_i);
        if (rst_n && resolve_has_record &&
            (ENABLE_TAGGED_RESOLUTION == 0) &&
            (resolve_pc_i != inflight_pc_q[resolve_index]))
            $error("gshare resolution order mismatch: got pc=%016x expected=%016x",
                   resolve_pc_i, inflight_pc_q[resolve_index]);
        if (rst_n && resolve_has_record &&
            (resolve_branch_i != inflight_branch_q[resolve_index]))
            $error("gshare resolution kind mismatch at pc=%016x",
                   resolve_pc_i);
    end
`endif

endmodule

`endif
