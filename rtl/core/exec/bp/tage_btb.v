`ifndef OPENRV64_EXEC_BP_TAGE_BTB_V
`define OPENRV64_EXEC_BP_TAGE_BTB_V
`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// One synchronous-read/one-write memory.  The explicit synchronous read and
// reset-free payload are required for FPGA block-RAM inference.  Same-address
// read/write behavior is made write-first so simulation and FPGA behavior do
// not depend on the primitive's configured collision mode.
module openrv64_exec_bp_tage_ram #(
    parameter integer WIDTH = 8,
    parameter integer ENTRIES = 512,
    parameter integer INDEX_WIDTH = $clog2(ENTRIES)
) (
    input  wire                   clk,
    input  wire                   read_enable_i,
    input  wire [INDEX_WIDTH-1:0] read_index_i,
    output reg  [WIDTH-1:0]       read_data_o,
    input  wire                   write_enable_i,
    input  wire [INDEX_WIDTH-1:0] write_index_i,
    input  wire [WIDTH-1:0]       write_data_i
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [WIDTH-1:0] mem_q [0:ENTRIES-1];

    always @(posedge clk) begin
        if (write_enable_i)
            mem_q[write_index_i] <= write_data_i;
        if (read_enable_i) begin
            if (write_enable_i && (write_index_i == read_index_i))
                read_data_o <= write_data_i;
            else
                read_data_o <= mem_q[read_index_i];
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((ENTRIES < 2) || ((1 << INDEX_WIDTH) != ENTRIES))
            $fatal(1, "TAGE RAM entries must be a power of two");
    end
`endif
endmodule

// Compact tagged geometric-history predictor.  The direction side is a
// bimodal base plus four tagged tables.  The longest matching tagged table is
// the provider and the next match (or base) is the alternate.
//
// Direction payloads use synchronous inferred RAMs.  A conditional lookup
// therefore requires its caller to retain the lookup record for one cycle
// while the RAM outputs are registered.
// Valid and useful bits are small sidecars: valid bits need architectural reset
// semantics, while useful bits need an incremental aging write independent of
// the tag/counter RAM write port.  The indirect BTB and external RAS retain the
// existing predictor contract and are deliberately not part of this pipeline.
//
// Conditional training is ordered through the in-flight checkpoint queue.  A
// younger branch may resolve early, but cannot update state until every older
// control has resolved.  Each RAM snapshot is forwarded into younger records
// on update, preventing stale read-modify-write state from losing training.
module openrv64_exec_bp_tage_btb #(
    parameter integer BASE_ENTRIES = 2048,
    parameter integer BASE_COUNTER_BITS = 2,
    parameter integer TABLE_ENTRIES = 512,
    parameter integer TABLE_COUNTER_BITS = 3,
    parameter integer USEFUL_BITS = 2,
    parameter integer HISTORY_BITS = 96,
    parameter integer HISTORY0_BITS = 4,
    parameter integer HISTORY1_BITS = 12,
    parameter integer HISTORY2_BITS = 32,
    parameter integer HISTORY3_BITS = 96,
    parameter integer TAG0_BITS = 8,
    parameter integer TAG1_BITS = 9,
    parameter integer TAG2_BITS = 10,
    parameter integer TAG3_BITS = 11,
    parameter integer USE_ALT_COUNTER_BITS = 4,
    parameter integer AGE_INTERVAL = 32768,
    parameter integer BTB_ENTRIES = 256,
    parameter integer BTB_TAG_BITS = 16,
    parameter integer INFLIGHT_DEPTH = 16,
    parameter integer ENABLE_TAGGED_RESOLUTION = 0,
    parameter integer BASE_INDEX_WIDTH = $clog2(BASE_ENTRIES),
    parameter integer TABLE_INDEX_WIDTH = $clog2(TABLE_ENTRIES),
    parameter integer MAX_TAG_BITS = TAG3_BITS,
    parameter integer BTB_INDEX_WIDTH = $clog2(BTB_ENTRIES),
    parameter integer INFLIGHT_PTR_WIDTH = $clog2(INFLIGHT_DEPTH),
    parameter integer INFLIGHT_COUNT_WIDTH = $clog2(INFLIGHT_DEPTH + 1),
    parameter integer AGE_COUNT_WIDTH = $clog2(AGE_INTERVAL)
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
    output wire                         capacity_stall_o,
    output wire                         update_overflow_o,

    output wire                         ordered_ras_update_valid_o,
    output wire [1:0]                   ordered_ras_update_action_o,
    output wire [`RV64_XLEN-1:0]        ordered_ras_update_pc_o,
    output wire                         ordered_ras_pending_o,
    output wire [INFLIGHT_DEPTH-1:0]    ordered_ras_spec_valid_o,
    output wire [2*INFLIGHT_DEPTH-1:0]  ordered_ras_spec_action_o,
    output wire [INFLIGHT_DEPTH*`RV64_XLEN-1:0]
                                        ordered_ras_spec_pc_o,
    output wire                         diag_ordered_ras_pending_unresolved_o,
    output wire                         diag_ordered_ras_pending_resolved_o,
    output wire                         diag_ordered_head_unresolved_o,

    output wire [2:0]                   diag_lookup_provider_o,
    output wire [2:0]                   diag_lookup_alternate_o,
    output wire                         diag_lookup_use_alt_o,
    output wire                         diag_train_valid_o,
    output wire                         diag_train_mispredict_o,
    output wire [2:0]                   diag_train_allocation_o,
    output wire                         diag_train_allocation_failed_o
);
    localparam [2:0] PROVIDER_BASE = 3'd0;
    localparam [2:0] PROVIDER_T0 = 3'd1;
    localparam [2:0] PROVIDER_T1 = 3'd2;
    localparam [2:0] PROVIDER_T2 = 3'd3;
    localparam [2:0] PROVIDER_T3 = 3'd4;
    localparam integer TABLE0_WIDTH = TAG0_BITS + TABLE_COUNTER_BITS;
    localparam integer TABLE1_WIDTH = TAG1_BITS + TABLE_COUNTER_BITS;
    localparam integer TABLE2_WIDTH = TAG2_BITS + TABLE_COUNTER_BITS;
    localparam integer TABLE3_WIDTH = TAG3_BITS + TABLE_COUNTER_BITS;
    localparam integer BTB_WIDTH = BTB_TAG_BITS + `RV64_XLEN;

    localparam [BASE_COUNTER_BITS-1:0] BASE_WEAK_TAKEN =
        {1'b1, {(BASE_COUNTER_BITS-1){1'b0}}};
    localparam [BASE_COUNTER_BITS-1:0] BASE_WEAK_NOT_TAKEN =
        {1'b0, {(BASE_COUNTER_BITS-1){1'b1}}};
    localparam [TABLE_COUNTER_BITS-1:0] TABLE_WEAK_TAKEN =
        {1'b1, {(TABLE_COUNTER_BITS-1){1'b0}}};
    localparam [TABLE_COUNTER_BITS-1:0] TABLE_WEAK_NOT_TAKEN =
        {1'b0, {(TABLE_COUNTER_BITS-1){1'b1}}};

    reg [BASE_ENTRIES-1:0] base_valid_q;
    reg [TABLE_ENTRIES-1:0] table0_valid_q;
    reg [TABLE_ENTRIES-1:0] table1_valid_q;
    reg [TABLE_ENTRIES-1:0] table2_valid_q;
    reg [TABLE_ENTRIES-1:0] table3_valid_q;
    (* ram_style = "distributed" *)
    reg [USEFUL_BITS-1:0] table0_useful_q [0:TABLE_ENTRIES-1];
    (* ram_style = "distributed" *)
    reg [USEFUL_BITS-1:0] table1_useful_q [0:TABLE_ENTRIES-1];
    (* ram_style = "distributed" *)
    reg [USEFUL_BITS-1:0] table2_useful_q [0:TABLE_ENTRIES-1];
    (* ram_style = "distributed" *)
    reg [USEFUL_BITS-1:0] table3_useful_q [0:TABLE_ENTRIES-1];

    reg [USE_ALT_COUNTER_BITS-1:0] use_alt_q;
    reg [HISTORY_BITS-1:0] speculative_history_q;
    reg [HISTORY_BITS-1:0] committed_history_q;

    reg [BTB_ENTRIES-1:0] btb_valid_q;

    reg inflight_branch_q [0:INFLIGHT_DEPTH-1];
    reg inflight_valid_q [0:INFLIGHT_DEPTH-1];
    reg inflight_resolved_q [0:INFLIGHT_DEPTH-1];
    reg inflight_actual_taken_q [0:INFLIGHT_DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        inflight_id_q [0:INFLIGHT_DEPTH-1];
    reg inflight_predicted_taken_q [0:INFLIGHT_DEPTH-1];
    reg inflight_provider_prediction_q [0:INFLIGHT_DEPTH-1];
    reg inflight_alternate_prediction_q [0:INFLIGHT_DEPTH-1];
    reg inflight_provider_weak_q [0:INFLIGHT_DEPTH-1];
    reg inflight_provider_useful_zero_q [0:INFLIGHT_DEPTH-1];
    reg [2:0] inflight_provider_q [0:INFLIGHT_DEPTH-1];
    reg [2:0] inflight_alternate_q [0:INFLIGHT_DEPTH-1];
    reg inflight_target_valid_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_target_q [0:INFLIGHT_DEPTH-1];
    reg [`RV64_XLEN-1:0] inflight_pc_q [0:INFLIGHT_DEPTH-1];
    // {pop, push}.  Reuse inflight_pc_q for the pushed return address;
    // ordered RAS handling therefore adds only these two bits per record.
    reg [1:0] inflight_ras_action_q [0:INFLIGHT_DEPTH-1];
    reg [BASE_INDEX_WIDTH-1:0]
        inflight_base_index_q [0:INFLIGHT_DEPTH-1];
    reg [BASE_COUNTER_BITS-1:0]
        inflight_base_counter_q [0:INFLIGHT_DEPTH-1];
    reg inflight_base_valid_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE_INDEX_WIDTH-1:0]
        inflight_table0_index_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE_INDEX_WIDTH-1:0]
        inflight_table1_index_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE_INDEX_WIDTH-1:0]
        inflight_table2_index_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE_INDEX_WIDTH-1:0]
        inflight_table3_index_q [0:INFLIGHT_DEPTH-1];
    reg [TAG0_BITS-1:0] inflight_table0_tag_q [0:INFLIGHT_DEPTH-1];
    reg [TAG1_BITS-1:0] inflight_table1_tag_q [0:INFLIGHT_DEPTH-1];
    reg [TAG2_BITS-1:0] inflight_table2_tag_q [0:INFLIGHT_DEPTH-1];
    reg [TAG3_BITS-1:0] inflight_table3_tag_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE0_WIDTH-1:0]
        inflight_table0_word_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE1_WIDTH-1:0]
        inflight_table1_word_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE2_WIDTH-1:0]
        inflight_table2_word_q [0:INFLIGHT_DEPTH-1];
    reg [TABLE3_WIDTH-1:0]
        inflight_table3_word_q [0:INFLIGHT_DEPTH-1];
    reg [USEFUL_BITS-1:0]
        inflight_table0_useful_q [0:INFLIGHT_DEPTH-1];
    reg [USEFUL_BITS-1:0]
        inflight_table1_useful_q [0:INFLIGHT_DEPTH-1];
    reg [USEFUL_BITS-1:0]
        inflight_table2_useful_q [0:INFLIGHT_DEPTH-1];
    reg [USEFUL_BITS-1:0]
        inflight_table3_useful_q [0:INFLIGHT_DEPTH-1];
    reg inflight_table0_valid_q [0:INFLIGHT_DEPTH-1];
    reg inflight_table1_valid_q [0:INFLIGHT_DEPTH-1];
    reg inflight_table2_valid_q [0:INFLIGHT_DEPTH-1];
    reg inflight_table3_valid_q [0:INFLIGHT_DEPTH-1];
    reg [HISTORY_BITS-1:0]
        inflight_history_before_q [0:INFLIGHT_DEPTH-1];
    reg [INFLIGHT_PTR_WIDTH-1:0] inflight_head_q;
    reg [INFLIGHT_PTR_WIDTH-1:0] inflight_tail_q;
    reg [INFLIGHT_COUNT_WIDTH-1:0] inflight_count_q;
    reg update_overflow_q;

    reg [AGE_COUNT_WIDTH-1:0] age_period_q;
    reg age_active_q;
    reg [1:0] age_table_q;
    reg [TABLE_INDEX_WIDTH-1:0] age_index_q;

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
            id_is_younger = (distance != 0) &&
                            !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    // Keep every geometry constant at elaboration.  Passing history and tag
    // widths as function inputs produces large dynamic modulo/index networks
    // in some FPGA synthesis tools even though every call is constant.
    function automatic [TABLE_INDEX_WIDTH-1:0] fold_index0;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        begin
            fold_index0 = 0;
            for (bit_index = 0; bit_index < HISTORY0_BITS;
                 bit_index = bit_index + 1)
                fold_index0[bit_index % TABLE_INDEX_WIDTH] =
                    fold_index0[bit_index % TABLE_INDEX_WIDTH] ^
                    history[bit_index];
        end
    endfunction

    function automatic [TABLE_INDEX_WIDTH-1:0] fold_index1;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        begin
            fold_index1 = 0;
            for (bit_index = 0; bit_index < HISTORY1_BITS;
                 bit_index = bit_index + 1)
                fold_index1[bit_index % TABLE_INDEX_WIDTH] =
                    fold_index1[bit_index % TABLE_INDEX_WIDTH] ^
                    history[bit_index];
        end
    endfunction

    function automatic [TABLE_INDEX_WIDTH-1:0] fold_index2;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        begin
            fold_index2 = 0;
            for (bit_index = 0; bit_index < HISTORY2_BITS;
                 bit_index = bit_index + 1)
                fold_index2[bit_index % TABLE_INDEX_WIDTH] =
                    fold_index2[bit_index % TABLE_INDEX_WIDTH] ^
                    history[bit_index];
        end
    endfunction

    function automatic [TABLE_INDEX_WIDTH-1:0] fold_index3;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        begin
            fold_index3 = 0;
            for (bit_index = 0; bit_index < HISTORY3_BITS;
                 bit_index = bit_index + 1)
                fold_index3[bit_index % TABLE_INDEX_WIDTH] =
                    fold_index3[bit_index % TABLE_INDEX_WIDTH] ^
                    history[bit_index];
        end
    endfunction

    // Two differently sized folds reduce the systematic aliases produced by
    // using only one folded history in a tagged table.
    function automatic [TAG0_BITS-1:0] fold_tag0;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        reg [TAG0_BITS-1:0] fold_a;
        reg [TAG0_BITS-2:0] fold_b;
        begin
            fold_a = 0;
            fold_b = 0;
            for (bit_index = 0; bit_index < HISTORY0_BITS;
                 bit_index = bit_index + 1) begin
                fold_a[bit_index % TAG0_BITS] =
                    fold_a[bit_index % TAG0_BITS] ^ history[bit_index];
                fold_b[bit_index % (TAG0_BITS-1)] =
                    fold_b[bit_index % (TAG0_BITS-1)] ^ history[bit_index];
            end
            fold_tag0 = fold_a ^ {fold_b, 1'b0};
        end
    endfunction

    function automatic [TAG1_BITS-1:0] fold_tag1;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        reg [TAG1_BITS-1:0] fold_a;
        reg [TAG1_BITS-2:0] fold_b;
        begin
            fold_a = 0;
            fold_b = 0;
            for (bit_index = 0; bit_index < HISTORY1_BITS;
                 bit_index = bit_index + 1) begin
                fold_a[bit_index % TAG1_BITS] =
                    fold_a[bit_index % TAG1_BITS] ^ history[bit_index];
                fold_b[bit_index % (TAG1_BITS-1)] =
                    fold_b[bit_index % (TAG1_BITS-1)] ^ history[bit_index];
            end
            fold_tag1 = fold_a ^ {fold_b, 1'b0};
        end
    endfunction

    function automatic [TAG2_BITS-1:0] fold_tag2;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        reg [TAG2_BITS-1:0] fold_a;
        reg [TAG2_BITS-2:0] fold_b;
        begin
            fold_a = 0;
            fold_b = 0;
            for (bit_index = 0; bit_index < HISTORY2_BITS;
                 bit_index = bit_index + 1) begin
                fold_a[bit_index % TAG2_BITS] =
                    fold_a[bit_index % TAG2_BITS] ^ history[bit_index];
                fold_b[bit_index % (TAG2_BITS-1)] =
                    fold_b[bit_index % (TAG2_BITS-1)] ^ history[bit_index];
            end
            fold_tag2 = fold_a ^ {fold_b, 1'b0};
        end
    endfunction

    function automatic [TAG3_BITS-1:0] fold_tag3;
        input [HISTORY_BITS-1:0] history;
        integer bit_index;
        reg [TAG3_BITS-1:0] fold_a;
        reg [TAG3_BITS-2:0] fold_b;
        begin
            fold_a = 0;
            fold_b = 0;
            for (bit_index = 0; bit_index < HISTORY3_BITS;
                 bit_index = bit_index + 1) begin
                fold_a[bit_index % TAG3_BITS] =
                    fold_a[bit_index % TAG3_BITS] ^ history[bit_index];
                fold_b[bit_index % (TAG3_BITS-1)] =
                    fold_b[bit_index % (TAG3_BITS-1)] ^ history[bit_index];
            end
            fold_tag3 = fold_a ^ {fold_b, 1'b0};
        end
    endfunction

    function automatic [BASE_COUNTER_BITS-1:0] update_base_counter;
        input [BASE_COUNTER_BITS-1:0] counter;
        input taken;
        begin
            if (taken && (counter != {BASE_COUNTER_BITS{1'b1}}))
                update_base_counter = counter + 1'b1;
            else if (!taken && (counter != 0))
                update_base_counter = counter - 1'b1;
            else
                update_base_counter = counter;
        end
    endfunction

    function automatic [TABLE_COUNTER_BITS-1:0] update_table_counter;
        input [TABLE_COUNTER_BITS-1:0] counter;
        input taken;
        begin
            if (taken && (counter != {TABLE_COUNTER_BITS{1'b1}}))
                update_table_counter = counter + 1'b1;
            else if (!taken && (counter != 0))
                update_table_counter = counter - 1'b1;
            else
                update_table_counter = counter;
        end
    endfunction

    function automatic [USEFUL_BITS-1:0] update_useful;
        input [USEFUL_BITS-1:0] useful;
        input provider_correct;
        input alternate_correct;
        begin
            update_useful = useful;
            if (provider_correct && !alternate_correct &&
                (useful != {USEFUL_BITS{1'b1}}))
                update_useful = useful + 1'b1;
            else if (!provider_correct && alternate_correct && (useful != 0))
                update_useful = useful - 1'b1;
        end
    endfunction

    wire [BASE_INDEX_WIDTH-1:0] launch_base_index =
        lookup_pc_i[BASE_INDEX_WIDTH+1:2];
    wire [TABLE_INDEX_WIDTH-1:0] launch_pc_index =
        lookup_pc_i[TABLE_INDEX_WIDTH+1:2] ^
        lookup_pc_i[2*TABLE_INDEX_WIDTH+1:TABLE_INDEX_WIDTH+2];
    wire [TABLE_INDEX_WIDTH-1:0] launch_table0_index =
        launch_pc_index ^ fold_index0(speculative_history_q);
    wire [TABLE_INDEX_WIDTH-1:0] launch_table1_index =
        launch_pc_index ^ fold_index1(speculative_history_q);
    wire [TABLE_INDEX_WIDTH-1:0] launch_table2_index =
        launch_pc_index ^ fold_index2(speculative_history_q);
    wire [TABLE_INDEX_WIDTH-1:0] launch_table3_index =
        launch_pc_index ^ fold_index3(speculative_history_q);
    wire [MAX_TAG_BITS-1:0] launch_pc_tag =
        lookup_pc_i[MAX_TAG_BITS+1:2] ^
        lookup_pc_i[MAX_TAG_BITS+TABLE_INDEX_WIDTH+1:
                    TABLE_INDEX_WIDTH+2];
    wire [TAG0_BITS-1:0] launch_table0_tag =
        launch_pc_tag[TAG0_BITS-1:0] ^ fold_tag0(speculative_history_q);
    wire [TAG1_BITS-1:0] launch_table1_tag =
        launch_pc_tag[TAG1_BITS-1:0] ^ fold_tag1(speculative_history_q);
    wire [TAG2_BITS-1:0] launch_table2_tag =
        launch_pc_tag[TAG2_BITS-1:0] ^ fold_tag2(speculative_history_q);
    wire [TAG3_BITS-1:0] launch_table3_tag =
        launch_pc_tag[TAG3_BITS-1:0] ^ fold_tag3(speculative_history_q);

    reg lookup_response_valid_q;
    reg [`RV64_XLEN-1:0] lookup_response_pc_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_response_id_q;
    reg lookup_response_backward_q;
    reg [HISTORY_BITS-1:0] lookup_response_history_q;
    reg [BASE_INDEX_WIDTH-1:0] lookup_base_index_q;
    reg [TABLE_INDEX_WIDTH-1:0] lookup_table0_index_q;
    reg [TABLE_INDEX_WIDTH-1:0] lookup_table1_index_q;
    reg [TABLE_INDEX_WIDTH-1:0] lookup_table2_index_q;
    reg [TABLE_INDEX_WIDTH-1:0] lookup_table3_index_q;
    reg [TAG0_BITS-1:0] lookup_table0_tag_q;
    reg [TAG1_BITS-1:0] lookup_table1_tag_q;
    reg [TAG2_BITS-1:0] lookup_table2_tag_q;
    reg [TAG3_BITS-1:0] lookup_table3_tag_q;
    reg lookup_base_valid_q;
    reg lookup_table0_valid_q;
    reg lookup_table1_valid_q;
    reg lookup_table2_valid_q;
    reg lookup_table3_valid_q;
    reg [USEFUL_BITS-1:0] lookup_table0_useful_q;
    reg [USEFUL_BITS-1:0] lookup_table1_useful_q;
    reg [USEFUL_BITS-1:0] lookup_table2_useful_q;
    reg [USEFUL_BITS-1:0] lookup_table3_useful_q;
    reg lookup_btb_response_valid_q;
    reg [`RV64_XLEN-1:0] lookup_btb_response_pc_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_btb_response_id_q;
    reg [BTB_INDEX_WIDTH-1:0] lookup_btb_index_q;
    reg [BTB_TAG_BITS-1:0] lookup_btb_tag_q;
    reg lookup_btb_valid_q;

    // The ID names the eventual backend allocation, not the RAM read.  A
    // control waiting behind frontend compaction can retain the same PC while
    // its projected allocation ID changes.  Reuse that PC-indexed response
    // and record the current lookup_id_i only when allocation is accepted.
    wire lookup_response_match = lookup_response_valid_q &&
        lookup_valid_i && lookup_branch_i &&
        (lookup_response_pc_q == lookup_pc_i);
    wire lookup_read_fire = lookup_valid_i && lookup_branch_i &&
        !(lookup_allocate_i && lookup_response_match);

    reg base_write_enable;
    reg [BASE_INDEX_WIDTH-1:0] base_write_index;
    reg [BASE_COUNTER_BITS-1:0] base_write_data;
    reg table0_write_enable;
    reg table1_write_enable;
    reg table2_write_enable;
    reg table3_write_enable;
    reg [TABLE_INDEX_WIDTH-1:0] table0_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table1_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table2_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table3_write_index;
    reg [TABLE0_WIDTH-1:0] table0_write_data;
    reg [TABLE1_WIDTH-1:0] table1_write_data;
    reg [TABLE2_WIDTH-1:0] table2_write_data;
    reg [TABLE3_WIDTH-1:0] table3_write_data;
    reg table0_useful_write_enable;
    reg table1_useful_write_enable;
    reg table2_useful_write_enable;
    reg table3_useful_write_enable;
    reg [TABLE_INDEX_WIDTH-1:0] table0_useful_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table1_useful_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table2_useful_write_index;
    reg [TABLE_INDEX_WIDTH-1:0] table3_useful_write_index;
    reg [USEFUL_BITS-1:0] table0_useful_write_data;
    reg [USEFUL_BITS-1:0] table1_useful_write_data;
    reg [USEFUL_BITS-1:0] table2_useful_write_data;
    reg [USEFUL_BITS-1:0] table3_useful_write_data;

    wire [BASE_COUNTER_BITS-1:0] base_read_data;
    wire [TABLE0_WIDTH-1:0] table0_read_data;
    wire [TABLE1_WIDTH-1:0] table1_read_data;
    wire [TABLE2_WIDTH-1:0] table2_read_data;
    wire [TABLE3_WIDTH-1:0] table3_read_data;

    openrv64_exec_bp_tage_ram #(
        .WIDTH(BASE_COUNTER_BITS), .ENTRIES(BASE_ENTRIES)
    ) u_base (
        .clk(clk), .read_enable_i(lookup_read_fire),
        .read_index_i(launch_base_index), .read_data_o(base_read_data),
        .write_enable_i(base_write_enable),
        .write_index_i(base_write_index), .write_data_i(base_write_data)
    );
    openrv64_exec_bp_tage_ram #(
        .WIDTH(TABLE0_WIDTH), .ENTRIES(TABLE_ENTRIES)
    ) u_table0 (
        .clk(clk), .read_enable_i(lookup_read_fire),
        .read_index_i(launch_table0_index), .read_data_o(table0_read_data),
        .write_enable_i(table0_write_enable),
        .write_index_i(table0_write_index), .write_data_i(table0_write_data)
    );
    openrv64_exec_bp_tage_ram #(
        .WIDTH(TABLE1_WIDTH), .ENTRIES(TABLE_ENTRIES)
    ) u_table1 (
        .clk(clk), .read_enable_i(lookup_read_fire),
        .read_index_i(launch_table1_index), .read_data_o(table1_read_data),
        .write_enable_i(table1_write_enable),
        .write_index_i(table1_write_index), .write_data_i(table1_write_data)
    );
    openrv64_exec_bp_tage_ram #(
        .WIDTH(TABLE2_WIDTH), .ENTRIES(TABLE_ENTRIES)
    ) u_table2 (
        .clk(clk), .read_enable_i(lookup_read_fire),
        .read_index_i(launch_table2_index), .read_data_o(table2_read_data),
        .write_enable_i(table2_write_enable),
        .write_index_i(table2_write_index), .write_data_i(table2_write_data)
    );
    openrv64_exec_bp_tage_ram #(
        .WIDTH(TABLE3_WIDTH), .ENTRIES(TABLE_ENTRIES)
    ) u_table3 (
        .clk(clk), .read_enable_i(lookup_read_fire),
        .read_index_i(launch_table3_index), .read_data_o(table3_read_data),
        .write_enable_i(table3_write_enable),
        .write_index_i(table3_write_index), .write_data_i(table3_write_data)
    );

    wire [BASE_COUNTER_BITS-1:0] lookup_base_data =
        (base_write_enable &&
         (base_write_index == lookup_base_index_q)) ?
        base_write_data : base_read_data;
    wire [TABLE0_WIDTH-1:0] lookup_table0_word =
        (table0_write_enable &&
         (table0_write_index == lookup_table0_index_q)) ?
        table0_write_data : table0_read_data;
    wire [TABLE1_WIDTH-1:0] lookup_table1_word =
        (table1_write_enable &&
         (table1_write_index == lookup_table1_index_q)) ?
        table1_write_data : table1_read_data;
    wire [TABLE2_WIDTH-1:0] lookup_table2_word =
        (table2_write_enable &&
         (table2_write_index == lookup_table2_index_q)) ?
        table2_write_data : table2_read_data;
    wire [TABLE3_WIDTH-1:0] lookup_table3_word =
        (table3_write_enable &&
         (table3_write_index == lookup_table3_index_q)) ?
        table3_write_data : table3_read_data;
    wire [USEFUL_BITS-1:0] lookup_table0_useful =
        (table0_useful_write_enable &&
         (table0_useful_write_index == lookup_table0_index_q)) ?
        table0_useful_write_data : lookup_table0_useful_q;
    wire [USEFUL_BITS-1:0] lookup_table1_useful =
        (table1_useful_write_enable &&
         (table1_useful_write_index == lookup_table1_index_q)) ?
        table1_useful_write_data : lookup_table1_useful_q;
    wire [USEFUL_BITS-1:0] lookup_table2_useful =
        (table2_useful_write_enable &&
         (table2_useful_write_index == lookup_table2_index_q)) ?
        table2_useful_write_data : lookup_table2_useful_q;
    wire [USEFUL_BITS-1:0] lookup_table3_useful =
        (table3_useful_write_enable &&
         (table3_useful_write_index == lookup_table3_index_q)) ?
        table3_useful_write_data : lookup_table3_useful_q;

    wire [BASE_COUNTER_BITS-1:0] lookup_base_counter =
        lookup_base_valid_q ? lookup_base_data :
        (lookup_response_backward_q ? BASE_WEAK_TAKEN :
                                      BASE_WEAK_NOT_TAKEN);
    wire lookup_base_prediction = lookup_base_counter[BASE_COUNTER_BITS-1];
    wire lookup_base_weak = !lookup_base_valid_q ||
        (lookup_base_counter == BASE_WEAK_TAKEN) ||
        (lookup_base_counter == BASE_WEAK_NOT_TAKEN);
    wire [TABLE_COUNTER_BITS-1:0] lookup_table0_counter =
        lookup_table0_word[TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] lookup_table1_counter =
        lookup_table1_word[TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] lookup_table2_counter =
        lookup_table2_word[TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] lookup_table3_counter =
        lookup_table3_word[TABLE_COUNTER_BITS-1:0];
    wire lookup_table0_match = lookup_table0_valid_q &&
        (lookup_table0_word[TABLE_COUNTER_BITS +: TAG0_BITS] ==
         lookup_table0_tag_q);
    wire lookup_table1_match = lookup_table1_valid_q &&
        (lookup_table1_word[TABLE_COUNTER_BITS +: TAG1_BITS] ==
         lookup_table1_tag_q);
    wire lookup_table2_match = lookup_table2_valid_q &&
        (lookup_table2_word[TABLE_COUNTER_BITS +: TAG2_BITS] ==
         lookup_table2_tag_q);
    wire lookup_table3_match = lookup_table3_valid_q &&
        (lookup_table3_word[TABLE_COUNTER_BITS +: TAG3_BITS] ==
         lookup_table3_tag_q);

    reg [2:0] lookup_provider;
    reg [2:0] lookup_alternate;
    reg lookup_provider_prediction;
    reg lookup_alternate_prediction;
    reg lookup_provider_weak;
    reg [USEFUL_BITS-1:0] lookup_provider_useful;
    always @* begin
        lookup_provider = PROVIDER_BASE;
        lookup_alternate = PROVIDER_BASE;
        lookup_provider_prediction = lookup_base_prediction;
        lookup_alternate_prediction = lookup_base_prediction;
        lookup_provider_weak = lookup_base_weak;
        lookup_provider_useful = {USEFUL_BITS{1'b1}};
        if (lookup_table0_match) begin
            lookup_alternate = lookup_provider;
            lookup_alternate_prediction = lookup_provider_prediction;
            lookup_provider = PROVIDER_T0;
            lookup_provider_prediction =
                lookup_table0_counter[TABLE_COUNTER_BITS-1];
            lookup_provider_weak =
                (lookup_table0_counter == TABLE_WEAK_TAKEN) ||
                (lookup_table0_counter == TABLE_WEAK_NOT_TAKEN);
            lookup_provider_useful = lookup_table0_useful;
        end
        if (lookup_table1_match) begin
            lookup_alternate = lookup_provider;
            lookup_alternate_prediction = lookup_provider_prediction;
            lookup_provider = PROVIDER_T1;
            lookup_provider_prediction =
                lookup_table1_counter[TABLE_COUNTER_BITS-1];
            lookup_provider_weak =
                (lookup_table1_counter == TABLE_WEAK_TAKEN) ||
                (lookup_table1_counter == TABLE_WEAK_NOT_TAKEN);
            lookup_provider_useful = lookup_table1_useful;
        end
        if (lookup_table2_match) begin
            lookup_alternate = lookup_provider;
            lookup_alternate_prediction = lookup_provider_prediction;
            lookup_provider = PROVIDER_T2;
            lookup_provider_prediction =
                lookup_table2_counter[TABLE_COUNTER_BITS-1];
            lookup_provider_weak =
                (lookup_table2_counter == TABLE_WEAK_TAKEN) ||
                (lookup_table2_counter == TABLE_WEAK_NOT_TAKEN);
            lookup_provider_useful = lookup_table2_useful;
        end
        if (lookup_table3_match) begin
            lookup_alternate = lookup_provider;
            lookup_alternate_prediction = lookup_provider_prediction;
            lookup_provider = PROVIDER_T3;
            lookup_provider_prediction =
                lookup_table3_counter[TABLE_COUNTER_BITS-1];
            lookup_provider_weak =
                (lookup_table3_counter == TABLE_WEAK_TAKEN) ||
                (lookup_table3_counter == TABLE_WEAK_NOT_TAKEN);
            lookup_provider_useful = lookup_table3_useful;
        end
    end

    wire lookup_use_alt = (lookup_provider != PROVIDER_BASE) &&
        lookup_provider_weak && (lookup_provider_useful == 0) &&
        use_alt_q[USE_ALT_COUNTER_BITS-1];
    wire conditional_prediction_response = lookup_use_alt ?
        lookup_alternate_prediction : lookup_provider_prediction;
    wire conditional_prediction = lookup_response_match ?
        conditional_prediction_response : lookup_backward_i;
    wire conditional_prediction_weak = !lookup_response_match ||
        ((lookup_provider == PROVIDER_BASE) ? lookup_base_weak :
         (lookup_provider_weak || (lookup_provider_useful == 0) ||
          (lookup_provider_prediction != lookup_alternate_prediction)));

    wire lookup_is_jal =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JAL;
    wire lookup_is_jalr =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JALR;
    wire lookup_rd_link = is_link_reg(`RV64_RD(lookup_instr_i));
    wire lookup_rs1_link = is_link_reg(`RV64_RS1(lookup_instr_i));
    wire lookup_ras_push = lookup_valid_i &&
        (lookup_is_jal || lookup_is_jalr) && lookup_rd_link;
    wire lookup_ras_pop = lookup_valid_i && lookup_is_jalr &&
        lookup_rs1_link &&
        (!lookup_rd_link ||
         (`RV64_RD(lookup_instr_i) != `RV64_RS1(lookup_instr_i)));
    wire [1:0] lookup_ras_action = {lookup_ras_pop, lookup_ras_push};
    wire lookup_return = lookup_valid_i && lookup_indirect_i &&
        lookup_is_jalr && lookup_rs1_link && !lookup_rd_link;
    wire resolve_is_jalr =
        `RV64_OPCODE(resolve_instr_i) == `RV64_OPCODE_JALR;
    wire [BTB_INDEX_WIDTH-1:0] lookup_btb_index =
        lookup_pc_i[BTB_INDEX_WIDTH+1:2];
    wire [BTB_TAG_BITS-1:0] lookup_btb_tag =
        lookup_pc_i[BTB_INDEX_WIDTH+2 +: BTB_TAG_BITS];
    wire lookup_btb_response_match = lookup_btb_response_valid_q &&
        lookup_valid_i && lookup_indirect_i && !lookup_return &&
        (lookup_btb_response_pc_q == lookup_pc_i);
    wire lookup_btb_read_fire = lookup_valid_i && lookup_indirect_i &&
        !lookup_return &&
        !(lookup_allocate_i && lookup_btb_response_match);
    wire [BTB_WIDTH-1:0] btb_read_data;
    wire [BTB_INDEX_WIDTH-1:0] resolve_btb_index =
        resolve_pc_i[BTB_INDEX_WIDTH+1:2];
    wire [BTB_TAG_BITS-1:0] resolve_btb_tag =
        resolve_pc_i[BTB_INDEX_WIDTH+2 +: BTB_TAG_BITS];
    wire btb_write_enable;
    wire [BTB_WIDTH-1:0] btb_write_data;
    openrv64_exec_bp_tage_ram #(
        .WIDTH(BTB_WIDTH), .ENTRIES(BTB_ENTRIES)
    ) u_btb (
        .clk(clk), .read_enable_i(lookup_btb_read_fire),
        .read_index_i(lookup_btb_index), .read_data_o(btb_read_data),
        .write_enable_i(btb_write_enable),
        .write_index_i(resolve_btb_index), .write_data_i(btb_write_data)
    );
    wire [BTB_WIDTH-1:0] lookup_btb_word =
        (btb_write_enable &&
         (resolve_btb_index == lookup_btb_index_q)) ?
        btb_write_data : btb_read_data;
    wire lookup_btb_hit = lookup_btb_response_match &&
        lookup_btb_valid_q &&
        (lookup_btb_word[`RV64_XLEN +: BTB_TAG_BITS] == lookup_btb_tag_q);
    wire btb_prediction_valid = lookup_valid_i && lookup_indirect_i &&
                                !lookup_return && lookup_btb_hit;
    wire selected_target_valid = lookup_return ?
        ras_prediction_valid_i : btb_prediction_valid;
    wire [`RV64_XLEN-1:0] selected_target = lookup_return ?
        ras_prediction_target_i : lookup_btb_word[`RV64_XLEN-1:0];

    wire queue_full = inflight_count_q == INFLIGHT_DEPTH;
    wire accepted_lookup = lookup_allocate_i && !queue_full &&
        (!lookup_branch_i || lookup_response_match) &&
        (!lookup_indirect_i || lookup_return ||
         lookup_btb_response_match);
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
        squash_keep_count = 0;
        recovery_keep_count = 0;
        recovery_younger_found = 1'b0;
        recovery_younger_index = inflight_head_q;
        recovery_younger_id = 0;
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
    wire resolve_has_record = resolve_valid_i && (inflight_count_q != 0) &&
        ((ENABLE_TAGGED_RESOLUTION == 0) || resolve_tag_match);
    assign btb_write_enable = resolve_has_record && resolve_is_jalr &&
                              resolve_taken_i;
    assign btb_write_data = {resolve_btb_tag, resolve_target_i};
    wire resolved_target_valid = inflight_target_valid_q[resolve_index];
    wire head_commit = (inflight_count_q != 0) &&
        inflight_valid_q[inflight_head_q] &&
        inflight_resolved_q[inflight_head_q];
    wire recovery_head_commit = head_commit &&
        !id_is_younger(inflight_id_q[inflight_head_q], recovery_id_i);
    wire record_commit = (ENABLE_TAGGED_RESOLUTION != 0) ?
                         head_commit : resolve_has_record;
    wire [INFLIGHT_PTR_WIDTH-1:0] train_index =
        (ENABLE_TAGGED_RESOLUTION != 0) ? inflight_head_q : resolve_index;
    assign ordered_ras_update_action_o =
        inflight_ras_action_q[train_index];
    assign ordered_ras_update_pc_o = inflight_pc_q[train_index];
    assign ordered_ras_update_valid_o =
        (ENABLE_TAGGED_RESOLUTION != 0) && record_commit && !flush_i &&
        (ordered_ras_update_action_o != 2'b00);
    // Export the speculative RAS delta in program order.  The committed RAS
    // folds this surviving queue over its durable state for lookup.  The
    // current lookup is appended only on the active clock edge, so its own
    // action cannot affect its prediction.
    reg [INFLIGHT_DEPTH-1:0] ordered_ras_spec_valid;
    reg [2*INFLIGHT_DEPTH-1:0] ordered_ras_spec_action;
    reg [INFLIGHT_DEPTH*`RV64_XLEN-1:0] ordered_ras_spec_pc;
    integer ras_spec_offset;
    integer ras_spec_index;
    always @* begin
        ordered_ras_spec_valid = {INFLIGHT_DEPTH{1'b0}};
        ordered_ras_spec_action = {(2*INFLIGHT_DEPTH){1'b0}};
        ordered_ras_spec_pc =
            {(INFLIGHT_DEPTH*`RV64_XLEN){1'b0}};
        for (ras_spec_offset = 0; ras_spec_offset < INFLIGHT_DEPTH;
             ras_spec_offset = ras_spec_offset + 1) begin
            ras_spec_index = (inflight_head_q + ras_spec_offset) &
                             (INFLIGHT_DEPTH - 1);
            if ((ras_spec_offset < inflight_count_q) &&
                inflight_valid_q[ras_spec_index] &&
                (inflight_ras_action_q[ras_spec_index] != 2'b00)) begin
                ordered_ras_spec_valid[ras_spec_offset] = 1'b1;
                ordered_ras_spec_action[2*ras_spec_offset +: 2] =
                    inflight_ras_action_q[ras_spec_index];
                ordered_ras_spec_pc[ras_spec_offset*`RV64_XLEN +:
                                    `RV64_XLEN] =
                    inflight_pc_q[ras_spec_index];
            end
        end
    end
    assign ordered_ras_spec_valid_o =
        (ENABLE_TAGGED_RESOLUTION != 0) ? ordered_ras_spec_valid :
        {INFLIGHT_DEPTH{1'b0}};
    assign ordered_ras_spec_action_o =
        (ENABLE_TAGGED_RESOLUTION != 0) ? ordered_ras_spec_action :
        {(2*INFLIGHT_DEPTH){1'b0}};
    assign ordered_ras_spec_pc_o =
        (ENABLE_TAGGED_RESOLUTION != 0) ? ordered_ras_spec_pc :
        {(INFLIGHT_DEPTH*`RV64_XLEN){1'b0}};
    reg ordered_ras_pending;
    reg ordered_ras_pending_unresolved;
    reg ordered_ras_pending_resolved;
    integer ras_pending_index;
    always @* begin
        ordered_ras_pending = 1'b0;
        ordered_ras_pending_unresolved = 1'b0;
        ordered_ras_pending_resolved = 1'b0;
        for (ras_pending_index = 0;
             ras_pending_index < INFLIGHT_DEPTH;
             ras_pending_index = ras_pending_index + 1)
            if (inflight_valid_q[ras_pending_index] &&
                (inflight_ras_action_q[ras_pending_index] != 2'b00)) begin
                ordered_ras_pending = 1'b1;
                if (inflight_resolved_q[ras_pending_index])
                    ordered_ras_pending_resolved = 1'b1;
                else
                    ordered_ras_pending_unresolved = 1'b1;
            end
    end
    assign ordered_ras_pending_o =
        (ENABLE_TAGGED_RESOLUTION != 0) && ordered_ras_pending;
    assign diag_ordered_ras_pending_unresolved_o =
        (ENABLE_TAGGED_RESOLUTION != 0) &&
        ordered_ras_pending_unresolved;
    assign diag_ordered_ras_pending_resolved_o =
        (ENABLE_TAGGED_RESOLUTION != 0) && ordered_ras_pending_resolved;
    assign diag_ordered_head_unresolved_o =
        (ENABLE_TAGGED_RESOLUTION != 0) && (inflight_count_q != 0) &&
        inflight_valid_q[inflight_head_q] &&
        !inflight_resolved_q[inflight_head_q];
    wire train_valid = record_commit && inflight_branch_q[train_index];
    wire train_taken = (ENABLE_TAGGED_RESOLUTION != 0) ?
        inflight_actual_taken_q[train_index] : resolve_taken_i;
    wire train_mispredict = train_valid &&
        (inflight_predicted_taken_q[train_index] != train_taken);
    wire [HISTORY_BITS-1:0] resolved_history =
        {inflight_history_before_q[resolve_index][HISTORY_BITS-2:0],
         resolve_taken_i};
    wire [HISTORY_BITS-1:0] trained_history =
        {inflight_history_before_q[train_index][HISTORY_BITS-2:0],
         train_taken};

    wire [2:0] train_provider = inflight_provider_q[train_index];
    wire train_provider_prediction =
        inflight_provider_prediction_q[train_index];
    wire train_alternate_prediction =
        inflight_alternate_prediction_q[train_index];
    wire train_provider_weak = inflight_provider_weak_q[train_index];
    wire train_provider_useful_zero =
        inflight_provider_useful_zero_q[train_index];
    wire [TABLE_COUNTER_BITS-1:0] train_table0_counter =
        inflight_table0_word_q[train_index][TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] train_table1_counter =
        inflight_table1_word_q[train_index][TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] train_table2_counter =
        inflight_table2_word_q[train_index][TABLE_COUNTER_BITS-1:0];
    wire [TABLE_COUNTER_BITS-1:0] train_table3_counter =
        inflight_table3_word_q[train_index][TABLE_COUNTER_BITS-1:0];
    wire train_table0_same = inflight_table0_valid_q[train_index] &&
        (inflight_table0_word_q[train_index]
             [TABLE_COUNTER_BITS +: TAG0_BITS] ==
         inflight_table0_tag_q[train_index]);
    wire train_table1_same = inflight_table1_valid_q[train_index] &&
        (inflight_table1_word_q[train_index]
             [TABLE_COUNTER_BITS +: TAG1_BITS] ==
         inflight_table1_tag_q[train_index]);
    wire train_table2_same = inflight_table2_valid_q[train_index] &&
        (inflight_table2_word_q[train_index]
             [TABLE_COUNTER_BITS +: TAG2_BITS] ==
         inflight_table2_tag_q[train_index]);
    wire train_table3_same = inflight_table3_valid_q[train_index] &&
        (inflight_table3_word_q[train_index]
             [TABLE_COUNTER_BITS +: TAG3_BITS] ==
         inflight_table3_tag_q[train_index]);
    wire train_table0_available = !inflight_table0_valid_q[train_index] ||
        (inflight_table0_useful_q[train_index] == 0);
    wire train_table1_available = !inflight_table1_valid_q[train_index] ||
        (inflight_table1_useful_q[train_index] == 0);
    wire train_table2_available = !inflight_table2_valid_q[train_index] ||
        (inflight_table2_useful_q[train_index] == 0);
    wire train_table3_available = !inflight_table3_valid_q[train_index] ||
        (inflight_table3_useful_q[train_index] == 0);

    reg [2:0] train_allocation;
    always @* begin
        train_allocation = 3'd0;
        if (train_mispredict) begin
            if ((train_provider < PROVIDER_T0) && train_table0_available)
                train_allocation = PROVIDER_T0;
            else if ((train_provider < PROVIDER_T1) && train_table1_available)
                train_allocation = PROVIDER_T1;
            else if ((train_provider < PROVIDER_T2) && train_table2_available)
                train_allocation = PROVIDER_T2;
            else if ((train_provider < PROVIDER_T3) && train_table3_available)
                train_allocation = PROVIDER_T3;
        end
    end
    wire train_allocation_failed = train_mispredict &&
        (train_provider != PROVIDER_T3) && (train_allocation == 0);

    always @* begin
        base_write_enable = 1'b0;
        base_write_index = inflight_base_index_q[train_index];
        base_write_data = inflight_base_counter_q[train_index];
        table0_write_enable = 1'b0;
        table1_write_enable = 1'b0;
        table2_write_enable = 1'b0;
        table3_write_enable = 1'b0;
        table0_write_index = inflight_table0_index_q[train_index];
        table1_write_index = inflight_table1_index_q[train_index];
        table2_write_index = inflight_table2_index_q[train_index];
        table3_write_index = inflight_table3_index_q[train_index];
        table0_write_data = inflight_table0_word_q[train_index];
        table1_write_data = inflight_table1_word_q[train_index];
        table2_write_data = inflight_table2_word_q[train_index];
        table3_write_data = inflight_table3_word_q[train_index];
        table0_useful_write_enable = 1'b0;
        table1_useful_write_enable = 1'b0;
        table2_useful_write_enable = 1'b0;
        table3_useful_write_enable = 1'b0;
        table0_useful_write_index = inflight_table0_index_q[train_index];
        table1_useful_write_index = inflight_table1_index_q[train_index];
        table2_useful_write_index = inflight_table2_index_q[train_index];
        table3_useful_write_index = inflight_table3_index_q[train_index];
        table0_useful_write_data = inflight_table0_useful_q[train_index];
        table1_useful_write_data = inflight_table1_useful_q[train_index];
        table2_useful_write_data = inflight_table2_useful_q[train_index];
        table3_useful_write_data = inflight_table3_useful_q[train_index];

        if (train_valid) begin
            base_write_enable = 1'b1;
            base_write_data = inflight_base_valid_q[train_index] ?
                update_base_counter(inflight_base_counter_q[train_index],
                                    train_taken) :
                (train_taken ? BASE_WEAK_TAKEN : BASE_WEAK_NOT_TAKEN);

            case (train_provider)
                PROVIDER_T0: if (train_table0_same) begin
                    table0_write_enable = 1'b1;
                    table0_write_data[TABLE_COUNTER_BITS-1:0] =
                        update_table_counter(train_table0_counter,
                                             train_taken);
                    if (train_provider_prediction !=
                        train_alternate_prediction) begin
                        table0_useful_write_enable = 1'b1;
                        table0_useful_write_data = update_useful(
                            inflight_table0_useful_q[train_index],
                            train_provider_prediction == train_taken,
                            train_alternate_prediction == train_taken);
                    end
                end
                PROVIDER_T1: if (train_table1_same) begin
                    table1_write_enable = 1'b1;
                    table1_write_data[TABLE_COUNTER_BITS-1:0] =
                        update_table_counter(train_table1_counter,
                                             train_taken);
                    if (train_provider_prediction !=
                        train_alternate_prediction) begin
                        table1_useful_write_enable = 1'b1;
                        table1_useful_write_data = update_useful(
                            inflight_table1_useful_q[train_index],
                            train_provider_prediction == train_taken,
                            train_alternate_prediction == train_taken);
                    end
                end
                PROVIDER_T2: if (train_table2_same) begin
                    table2_write_enable = 1'b1;
                    table2_write_data[TABLE_COUNTER_BITS-1:0] =
                        update_table_counter(train_table2_counter,
                                             train_taken);
                    if (train_provider_prediction !=
                        train_alternate_prediction) begin
                        table2_useful_write_enable = 1'b1;
                        table2_useful_write_data = update_useful(
                            inflight_table2_useful_q[train_index],
                            train_provider_prediction == train_taken,
                            train_alternate_prediction == train_taken);
                    end
                end
                PROVIDER_T3: if (train_table3_same) begin
                    table3_write_enable = 1'b1;
                    table3_write_data[TABLE_COUNTER_BITS-1:0] =
                        update_table_counter(train_table3_counter,
                                             train_taken);
                    if (train_provider_prediction !=
                        train_alternate_prediction) begin
                        table3_useful_write_enable = 1'b1;
                        table3_useful_write_data = update_useful(
                            inflight_table3_useful_q[train_index],
                            train_provider_prediction == train_taken,
                            train_alternate_prediction == train_taken);
                    end
                end
                default: begin
                end
            endcase

            case (train_allocation)
                PROVIDER_T0: begin
                    table0_write_enable = 1'b1;
                    table0_write_data = {
                        inflight_table0_tag_q[train_index],
                        train_taken ? TABLE_WEAK_TAKEN :
                                      TABLE_WEAK_NOT_TAKEN};
                    table0_useful_write_enable = 1'b1;
                    table0_useful_write_data = 0;
                end
                PROVIDER_T1: begin
                    table1_write_enable = 1'b1;
                    table1_write_data = {
                        inflight_table1_tag_q[train_index],
                        train_taken ? TABLE_WEAK_TAKEN :
                                      TABLE_WEAK_NOT_TAKEN};
                    table1_useful_write_enable = 1'b1;
                    table1_useful_write_data = 0;
                end
                PROVIDER_T2: begin
                    table2_write_enable = 1'b1;
                    table2_write_data = {
                        inflight_table2_tag_q[train_index],
                        train_taken ? TABLE_WEAK_TAKEN :
                                      TABLE_WEAK_NOT_TAKEN};
                    table2_useful_write_enable = 1'b1;
                    table2_useful_write_data = 0;
                end
                PROVIDER_T3: begin
                    table3_write_enable = 1'b1;
                    table3_write_data = {
                        inflight_table3_tag_q[train_index],
                        train_taken ? TABLE_WEAK_TAKEN :
                                      TABLE_WEAK_NOT_TAKEN};
                    table3_useful_write_enable = 1'b1;
                    table3_useful_write_data = 0;
                end
                default: if (train_allocation_failed) begin
                    if ((train_provider < PROVIDER_T0) &&
                        inflight_table0_valid_q[train_index] &&
                        (inflight_table0_useful_q[train_index] != 0)) begin
                        table0_useful_write_enable = 1'b1;
                        table0_useful_write_data =
                            inflight_table0_useful_q[train_index] - 1'b1;
                    end
                    if ((train_provider < PROVIDER_T1) &&
                        inflight_table1_valid_q[train_index] &&
                        (inflight_table1_useful_q[train_index] != 0)) begin
                        table1_useful_write_enable = 1'b1;
                        table1_useful_write_data =
                            inflight_table1_useful_q[train_index] - 1'b1;
                    end
                    if ((train_provider < PROVIDER_T2) &&
                        inflight_table2_valid_q[train_index] &&
                        (inflight_table2_useful_q[train_index] != 0)) begin
                        table2_useful_write_enable = 1'b1;
                        table2_useful_write_data =
                            inflight_table2_useful_q[train_index] - 1'b1;
                    end
                    if ((train_provider < PROVIDER_T3) &&
                        inflight_table3_valid_q[train_index] &&
                        (inflight_table3_useful_q[train_index] != 0)) begin
                        table3_useful_write_enable = 1'b1;
                        table3_useful_write_data =
                            inflight_table3_useful_q[train_index] - 1'b1;
                    end
                end
            endcase
        end else if (age_active_q) begin
            case (age_table_q)
                2'd0: if (table0_valid_q[age_index_q]) begin
                    table0_useful_write_enable = 1'b1;
                    table0_useful_write_index = age_index_q;
                    table0_useful_write_data =
                        table0_useful_q[age_index_q] >> 1;
                end
                2'd1: if (table1_valid_q[age_index_q]) begin
                    table1_useful_write_enable = 1'b1;
                    table1_useful_write_index = age_index_q;
                    table1_useful_write_data =
                        table1_useful_q[age_index_q] >> 1;
                end
                2'd2: if (table2_valid_q[age_index_q]) begin
                    table2_useful_write_enable = 1'b1;
                    table2_useful_write_index = age_index_q;
                    table2_useful_write_data =
                        table2_useful_q[age_index_q] >> 1;
                end
                2'd3: if (table3_valid_q[age_index_q]) begin
                    table3_useful_write_enable = 1'b1;
                    table3_useful_write_index = age_index_q;
                    table3_useful_write_data =
                        table3_useful_q[age_index_q] >> 1;
                end
            endcase
        end
    end

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
        inflight_target_valid_q[resolve_index] && resolve_taken_i &&
        (resolve_target_i != inflight_target_q[resolve_index]);
    assign allocation_stall_o = lookup_valid_i &&
        (queue_full || (lookup_branch_i && !lookup_response_match) ||
         (lookup_indirect_i && !lookup_return &&
          !lookup_btb_response_match));
    assign capacity_stall_o = queue_full;
    assign update_overflow_o = update_overflow_q;
    assign diag_lookup_provider_o = lookup_response_match ?
                                    lookup_provider : PROVIDER_BASE;
    assign diag_lookup_alternate_o = lookup_response_match ?
                                     lookup_alternate : PROVIDER_BASE;
    assign diag_lookup_use_alt_o = lookup_response_match && lookup_use_alt;
    assign diag_train_valid_o = train_valid;
    assign diag_train_mispredict_o = train_mispredict;
    assign diag_train_allocation_o = train_allocation;
    assign diag_train_allocation_failed_o = train_allocation_failed;

    wire [USE_ALT_COUNTER_BITS-1:0] use_alt_max =
        {USE_ALT_COUNTER_BITS{1'b1}};
    integer reset_index;
    integer forward_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_valid_q <= 0;
            table0_valid_q <= 0;
            table1_valid_q <= 0;
            table2_valid_q <= 0;
            table3_valid_q <= 0;
            btb_valid_q <= 0;
            speculative_history_q <= 0;
            committed_history_q <= 0;
            use_alt_q <= 0;
            inflight_head_q <= 0;
            inflight_tail_q <= 0;
            inflight_count_q <= 0;
            update_overflow_q <= 1'b0;
            age_period_q <= 0;
            age_active_q <= 1'b0;
            age_table_q <= 0;
            age_index_q <= 0;
            lookup_response_valid_q <= 1'b0;
            lookup_response_pc_q <= 0;
            lookup_response_id_q <= 0;
            lookup_response_backward_q <= 1'b0;
            lookup_response_history_q <= 0;
            lookup_base_index_q <= 0;
            lookup_table0_index_q <= 0;
            lookup_table1_index_q <= 0;
            lookup_table2_index_q <= 0;
            lookup_table3_index_q <= 0;
            lookup_table0_tag_q <= 0;
            lookup_table1_tag_q <= 0;
            lookup_table2_tag_q <= 0;
            lookup_table3_tag_q <= 0;
            lookup_base_valid_q <= 1'b0;
            lookup_table0_valid_q <= 1'b0;
            lookup_table1_valid_q <= 1'b0;
            lookup_table2_valid_q <= 1'b0;
            lookup_table3_valid_q <= 1'b0;
            lookup_table0_useful_q <= 0;
            lookup_table1_useful_q <= 0;
            lookup_table2_useful_q <= 0;
            lookup_table3_useful_q <= 0;
            lookup_btb_response_valid_q <= 1'b0;
            lookup_btb_response_pc_q <= 0;
            lookup_btb_response_id_q <= 0;
            lookup_btb_index_q <= 0;
            lookup_btb_tag_q <= 0;
            lookup_btb_valid_q <= 1'b0;
            for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                 reset_index = reset_index + 1) begin
                inflight_valid_q[reset_index] <= 1'b0;
                inflight_resolved_q[reset_index] <= 1'b0;
                inflight_actual_taken_q[reset_index] <= 1'b0;
                inflight_id_q[reset_index] <= 0;
                inflight_branch_q[reset_index] <= 1'b0;
                inflight_predicted_taken_q[reset_index] <= 1'b0;
                inflight_provider_prediction_q[reset_index] <= 1'b0;
                inflight_alternate_prediction_q[reset_index] <= 1'b0;
                inflight_provider_weak_q[reset_index] <= 1'b0;
                inflight_provider_useful_zero_q[reset_index] <= 1'b0;
                inflight_provider_q[reset_index] <= PROVIDER_BASE;
                inflight_alternate_q[reset_index] <= PROVIDER_BASE;
                inflight_target_valid_q[reset_index] <= 1'b0;
                inflight_target_q[reset_index] <= 0;
                inflight_pc_q[reset_index] <= 0;
                inflight_ras_action_q[reset_index] <= 2'b00;
                inflight_base_index_q[reset_index] <= 0;
                inflight_base_counter_q[reset_index] <= 0;
                inflight_base_valid_q[reset_index] <= 1'b0;
                inflight_table0_index_q[reset_index] <= 0;
                inflight_table1_index_q[reset_index] <= 0;
                inflight_table2_index_q[reset_index] <= 0;
                inflight_table3_index_q[reset_index] <= 0;
                inflight_table0_tag_q[reset_index] <= 0;
                inflight_table1_tag_q[reset_index] <= 0;
                inflight_table2_tag_q[reset_index] <= 0;
                inflight_table3_tag_q[reset_index] <= 0;
                inflight_table0_word_q[reset_index] <= 0;
                inflight_table1_word_q[reset_index] <= 0;
                inflight_table2_word_q[reset_index] <= 0;
                inflight_table3_word_q[reset_index] <= 0;
                inflight_table0_useful_q[reset_index] <= 0;
                inflight_table1_useful_q[reset_index] <= 0;
                inflight_table2_useful_q[reset_index] <= 0;
                inflight_table3_useful_q[reset_index] <= 0;
                inflight_table0_valid_q[reset_index] <= 1'b0;
                inflight_table1_valid_q[reset_index] <= 1'b0;
                inflight_table2_valid_q[reset_index] <= 1'b0;
                inflight_table3_valid_q[reset_index] <= 1'b0;
                inflight_history_before_q[reset_index] <= 0;
            end
        end else begin
            if (lookup_allocate_i &&
                (queue_full ||
                 (lookup_branch_i && !lookup_response_match) ||
                 (lookup_indirect_i && !lookup_return &&
                  !lookup_btb_response_match)))
                update_overflow_q <= 1'b1;

            if (flush_i || squash_i || !lookup_valid_i ||
                (accepted_lookup && lookup_branch_i))
                lookup_response_valid_q <= 1'b0;
            else if (lookup_read_fire)
                lookup_response_valid_q <= 1'b1;

            if (flush_i || squash_i || !lookup_valid_i ||
                (accepted_lookup && lookup_indirect_i && !lookup_return))
                lookup_btb_response_valid_q <= 1'b0;
            else if (lookup_btb_read_fire)
                lookup_btb_response_valid_q <= 1'b1;

            if (lookup_btb_read_fire) begin
                lookup_btb_response_pc_q <= lookup_pc_i;
                lookup_btb_response_id_q <= lookup_id_i;
                lookup_btb_index_q <= lookup_btb_index;
                lookup_btb_tag_q <= lookup_btb_tag;
                lookup_btb_valid_q <= btb_write_enable &&
                    (resolve_btb_index == lookup_btb_index) ? 1'b1 :
                    btb_valid_q[lookup_btb_index];
            end

            if (lookup_read_fire) begin
                lookup_response_pc_q <= lookup_pc_i;
                lookup_response_id_q <= lookup_id_i;
                lookup_response_backward_q <= lookup_backward_i;
                lookup_response_history_q <= speculative_history_q;
                lookup_base_index_q <= launch_base_index;
                lookup_table0_index_q <= launch_table0_index;
                lookup_table1_index_q <= launch_table1_index;
                lookup_table2_index_q <= launch_table2_index;
                lookup_table3_index_q <= launch_table3_index;
                lookup_table0_tag_q <= launch_table0_tag;
                lookup_table1_tag_q <= launch_table1_tag;
                lookup_table2_tag_q <= launch_table2_tag;
                lookup_table3_tag_q <= launch_table3_tag;
                lookup_base_valid_q <= base_write_enable &&
                    (base_write_index == launch_base_index) ? 1'b1 :
                    base_valid_q[launch_base_index];
                lookup_table0_valid_q <=
                    ((train_allocation == PROVIDER_T0) && train_valid &&
                     (table0_write_index == launch_table0_index)) ? 1'b1 :
                    table0_valid_q[launch_table0_index];
                lookup_table1_valid_q <=
                    ((train_allocation == PROVIDER_T1) && train_valid &&
                     (table1_write_index == launch_table1_index)) ? 1'b1 :
                    table1_valid_q[launch_table1_index];
                lookup_table2_valid_q <=
                    ((train_allocation == PROVIDER_T2) && train_valid &&
                     (table2_write_index == launch_table2_index)) ? 1'b1 :
                    table2_valid_q[launch_table2_index];
                lookup_table3_valid_q <=
                    ((train_allocation == PROVIDER_T3) && train_valid &&
                     (table3_write_index == launch_table3_index)) ? 1'b1 :
                    table3_valid_q[launch_table3_index];
                lookup_table0_useful_q <= table0_useful_write_enable &&
                    (table0_useful_write_index == launch_table0_index) ?
                    table0_useful_write_data :
                    table0_useful_q[launch_table0_index];
                lookup_table1_useful_q <= table1_useful_write_enable &&
                    (table1_useful_write_index == launch_table1_index) ?
                    table1_useful_write_data :
                    table1_useful_q[launch_table1_index];
                lookup_table2_useful_q <= table2_useful_write_enable &&
                    (table2_useful_write_index == launch_table2_index) ?
                    table2_useful_write_data :
                    table2_useful_q[launch_table2_index];
                lookup_table3_useful_q <= table3_useful_write_enable &&
                    (table3_useful_write_index == launch_table3_index) ?
                    table3_useful_write_data :
                    table3_useful_q[launch_table3_index];
            end

            if (base_write_enable)
                base_valid_q[base_write_index] <= 1'b1;
            if (train_valid && (train_allocation == PROVIDER_T0))
                table0_valid_q[table0_write_index] <= 1'b1;
            if (train_valid && (train_allocation == PROVIDER_T1))
                table1_valid_q[table1_write_index] <= 1'b1;
            if (train_valid && (train_allocation == PROVIDER_T2))
                table2_valid_q[table2_write_index] <= 1'b1;
            if (train_valid && (train_allocation == PROVIDER_T3))
                table3_valid_q[table3_write_index] <= 1'b1;
            if (table0_useful_write_enable)
                table0_useful_q[table0_useful_write_index] <=
                    table0_useful_write_data;
            if (table1_useful_write_enable)
                table1_useful_q[table1_useful_write_index] <=
                    table1_useful_write_data;
            if (table2_useful_write_enable)
                table2_useful_q[table2_useful_write_index] <=
                    table2_useful_write_data;
            if (table3_useful_write_enable)
                table3_useful_q[table3_useful_write_index] <=
                    table3_useful_write_data;

            if (train_valid && (train_provider != PROVIDER_BASE) &&
                train_provider_weak && train_provider_useful_zero &&
                (train_provider_prediction != train_alternate_prediction)) begin
                if ((train_alternate_prediction == train_taken) &&
                    (train_provider_prediction != train_taken) &&
                    (use_alt_q != use_alt_max))
                    use_alt_q <= use_alt_q + 1'b1;
                else if ((train_provider_prediction == train_taken) &&
                         (train_alternate_prediction != train_taken) &&
                         (use_alt_q != 0))
                    use_alt_q <= use_alt_q - 1'b1;
            end

            if (train_valid && !age_active_q) begin
                if (age_period_q == AGE_INTERVAL-1) begin
                    age_period_q <= 0;
                    age_active_q <= 1'b1;
                    age_table_q <= 0;
                    age_index_q <= 0;
                end else
                    age_period_q <= age_period_q + 1'b1;
            end else if (!train_valid && age_active_q) begin
                if (age_index_q == TABLE_ENTRIES-1) begin
                    age_index_q <= 0;
                    if (age_table_q == 2'd3) begin
                        age_table_q <= 0;
                        age_active_q <= 1'b0;
                    end else
                        age_table_q <= age_table_q + 1'b1;
                end else
                    age_index_q <= age_index_q + 1'b1;
            end

            if (btb_write_enable) begin
                btb_valid_q[resolve_btb_index] <= 1'b1;
            end
            if (train_valid)
                committed_history_q <= trained_history;
            if (resolve_has_record && (ENABLE_TAGGED_RESOLUTION != 0)) begin
                inflight_resolved_q[resolve_index] <= 1'b1;
                inflight_actual_taken_q[resolve_index] <= resolve_taken_i;
            end

            // Forward every committed RAM/sidecar update into all younger
            // snapshots before their ordered training turn.
            for (forward_index = 0; forward_index < INFLIGHT_DEPTH;
                 forward_index = forward_index + 1) begin
                if (inflight_valid_q[forward_index]) begin
                    if (base_write_enable &&
                        (inflight_base_index_q[forward_index] ==
                         base_write_index)) begin
                        inflight_base_counter_q[forward_index] <=
                            base_write_data;
                        inflight_base_valid_q[forward_index] <= 1'b1;
                    end
                    if (table0_write_enable &&
                        (inflight_table0_index_q[forward_index] ==
                         table0_write_index))
                        inflight_table0_word_q[forward_index] <=
                            table0_write_data;
                    if (table1_write_enable &&
                        (inflight_table1_index_q[forward_index] ==
                         table1_write_index))
                        inflight_table1_word_q[forward_index] <=
                            table1_write_data;
                    if (table2_write_enable &&
                        (inflight_table2_index_q[forward_index] ==
                         table2_write_index))
                        inflight_table2_word_q[forward_index] <=
                            table2_write_data;
                    if (table3_write_enable &&
                        (inflight_table3_index_q[forward_index] ==
                         table3_write_index))
                        inflight_table3_word_q[forward_index] <=
                            table3_write_data;
                    if (table0_useful_write_enable &&
                        (inflight_table0_index_q[forward_index] ==
                         table0_useful_write_index))
                        inflight_table0_useful_q[forward_index] <=
                            table0_useful_write_data;
                    if (table1_useful_write_enable &&
                        (inflight_table1_index_q[forward_index] ==
                         table1_useful_write_index))
                        inflight_table1_useful_q[forward_index] <=
                            table1_useful_write_data;
                    if (table2_useful_write_enable &&
                        (inflight_table2_index_q[forward_index] ==
                         table2_useful_write_index))
                        inflight_table2_useful_q[forward_index] <=
                            table2_useful_write_data;
                    if (table3_useful_write_enable &&
                        (inflight_table3_index_q[forward_index] ==
                         table3_useful_write_index))
                        inflight_table3_useful_q[forward_index] <=
                            table3_useful_write_data;
                    if (train_valid &&
                        (train_allocation == PROVIDER_T0) &&
                        (inflight_table0_index_q[forward_index] ==
                         table0_write_index))
                        inflight_table0_valid_q[forward_index] <= 1'b1;
                    if (train_valid &&
                        (train_allocation == PROVIDER_T1) &&
                        (inflight_table1_index_q[forward_index] ==
                         table1_write_index))
                        inflight_table1_valid_q[forward_index] <= 1'b1;
                    if (train_valid &&
                        (train_allocation == PROVIDER_T2) &&
                        (inflight_table2_index_q[forward_index] ==
                         table2_write_index))
                        inflight_table2_valid_q[forward_index] <= 1'b1;
                    if (train_valid &&
                        (train_allocation == PROVIDER_T3) &&
                        (inflight_table3_index_q[forward_index] ==
                         table3_write_index))
                        inflight_table3_valid_q[forward_index] <= 1'b1;
                end
            end

            if (flush_i) begin
                inflight_head_q <= 0;
                inflight_tail_q <= 0;
                inflight_count_q <= 0;
                for (reset_index = 0; reset_index < INFLIGHT_DEPTH;
                     reset_index = reset_index + 1) begin
                    inflight_valid_q[reset_index] <= 1'b0;
                    inflight_resolved_q[reset_index] <= 1'b0;
                    inflight_ras_action_q[reset_index] <= 2'b00;
                end
                speculative_history_q <= train_valid ?
                    trained_history : committed_history_q;
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
                    speculative_history_q <=
                        inflight_history_before_q[recovery_younger_index];
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
                speculative_history_q <= inflight_branch_q[resolve_index] ?
                    resolved_history :
                    inflight_history_before_q[resolve_index];
            end else begin
                case ({accepted_lookup, record_commit})
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

                if (accepted_lookup) begin
                    inflight_valid_q[inflight_tail_q] <= 1'b1;
                    inflight_resolved_q[inflight_tail_q] <= 1'b0;
                    inflight_actual_taken_q[inflight_tail_q] <= 1'b0;
                    inflight_id_q[inflight_tail_q] <= lookup_id_i;
                    inflight_branch_q[inflight_tail_q] <= lookup_branch_i;
                    inflight_predicted_taken_q[inflight_tail_q] <=
                        prediction_taken_o;
                    inflight_provider_prediction_q[inflight_tail_q] <=
                        lookup_provider_prediction;
                    inflight_alternate_prediction_q[inflight_tail_q] <=
                        lookup_alternate_prediction;
                    inflight_provider_weak_q[inflight_tail_q] <=
                        lookup_provider_weak;
                    inflight_provider_useful_zero_q[inflight_tail_q] <=
                        lookup_provider_useful == 0;
                    inflight_provider_q[inflight_tail_q] <= lookup_provider;
                    inflight_alternate_q[inflight_tail_q] <= lookup_alternate;
                    inflight_target_valid_q[inflight_tail_q] <=
                        prediction_target_valid_o;
                    inflight_target_q[inflight_tail_q] <= prediction_target_o;
                    inflight_pc_q[inflight_tail_q] <= lookup_pc_i;
                    inflight_ras_action_q[inflight_tail_q] <=
                        lookup_ras_action;
                    inflight_base_index_q[inflight_tail_q] <=
                        lookup_base_index_q;
                    inflight_base_counter_q[inflight_tail_q] <=
                        lookup_base_data;
                    inflight_base_valid_q[inflight_tail_q] <=
                        lookup_base_valid_q ||
                        (base_write_enable &&
                         (base_write_index == lookup_base_index_q));
                    inflight_table0_index_q[inflight_tail_q] <=
                        lookup_table0_index_q;
                    inflight_table1_index_q[inflight_tail_q] <=
                        lookup_table1_index_q;
                    inflight_table2_index_q[inflight_tail_q] <=
                        lookup_table2_index_q;
                    inflight_table3_index_q[inflight_tail_q] <=
                        lookup_table3_index_q;
                    inflight_table0_tag_q[inflight_tail_q] <=
                        lookup_table0_tag_q;
                    inflight_table1_tag_q[inflight_tail_q] <=
                        lookup_table1_tag_q;
                    inflight_table2_tag_q[inflight_tail_q] <=
                        lookup_table2_tag_q;
                    inflight_table3_tag_q[inflight_tail_q] <=
                        lookup_table3_tag_q;
                    inflight_table0_word_q[inflight_tail_q] <=
                        lookup_table0_word;
                    inflight_table1_word_q[inflight_tail_q] <=
                        lookup_table1_word;
                    inflight_table2_word_q[inflight_tail_q] <=
                        lookup_table2_word;
                    inflight_table3_word_q[inflight_tail_q] <=
                        lookup_table3_word;
                    inflight_table0_useful_q[inflight_tail_q] <=
                        lookup_table0_useful;
                    inflight_table1_useful_q[inflight_tail_q] <=
                        lookup_table1_useful;
                    inflight_table2_useful_q[inflight_tail_q] <=
                        lookup_table2_useful;
                    inflight_table3_useful_q[inflight_tail_q] <=
                        lookup_table3_useful;
                    inflight_table0_valid_q[inflight_tail_q] <=
                        lookup_table0_valid_q ||
                        (train_valid &&
                         (train_allocation == PROVIDER_T0) &&
                         (table0_write_index == lookup_table0_index_q));
                    inflight_table1_valid_q[inflight_tail_q] <=
                        lookup_table1_valid_q ||
                        (train_valid &&
                         (train_allocation == PROVIDER_T1) &&
                         (table1_write_index == lookup_table1_index_q));
                    inflight_table2_valid_q[inflight_tail_q] <=
                        lookup_table2_valid_q ||
                        (train_valid &&
                         (train_allocation == PROVIDER_T2) &&
                         (table2_write_index == lookup_table2_index_q));
                    inflight_table3_valid_q[inflight_tail_q] <=
                        lookup_table3_valid_q ||
                        (train_valid &&
                         (train_allocation == PROVIDER_T3) &&
                         (table3_write_index == lookup_table3_index_q));
                    inflight_history_before_q[inflight_tail_q] <=
                        lookup_response_history_q;
                    if (lookup_branch_i)
                        speculative_history_q <= {
                            lookup_response_history_q[HISTORY_BITS-2:0],
                            conditional_prediction_response};
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((BASE_ENTRIES < 2) ||
            ((1 << BASE_INDEX_WIDTH) != BASE_ENTRIES) ||
            (BASE_COUNTER_BITS < 2))
            $fatal(1, "TAGE base geometry is invalid");
        if ((TABLE_ENTRIES < 2) ||
            ((1 << TABLE_INDEX_WIDTH) != TABLE_ENTRIES) ||
            (TABLE_COUNTER_BITS < 2) || (USEFUL_BITS < 1))
            $fatal(1, "TAGE tagged-table geometry is invalid");
        if ((HISTORY0_BITS < 2) ||
            (HISTORY0_BITS >= HISTORY1_BITS) ||
            (HISTORY1_BITS >= HISTORY2_BITS) ||
            (HISTORY2_BITS >= HISTORY3_BITS) ||
            (HISTORY3_BITS != HISTORY_BITS))
            $fatal(1, "TAGE history lengths must increase to HISTORY_BITS");
        if ((TAG0_BITS < 4) || (TAG0_BITS > TAG1_BITS) ||
            (TAG1_BITS > TAG2_BITS) || (TAG2_BITS > TAG3_BITS) ||
            (TAG3_BITS != MAX_TAG_BITS))
            $fatal(1, "TAGE tag widths are invalid");
        if ((BTB_ENTRIES < 2) ||
            ((1 << BTB_INDEX_WIDTH) != BTB_ENTRIES))
            $fatal(1, "TAGE BTB entries must be a power of two");
        if ((BTB_TAG_BITS < 4) ||
            (BTB_INDEX_WIDTH + BTB_TAG_BITS + 2 > `RV64_XLEN))
            $fatal(1, "TAGE BTB tag width is out of range");
        if ((INFLIGHT_DEPTH < 2) ||
            ((1 << INFLIGHT_PTR_WIDTH) != INFLIGHT_DEPTH))
            $fatal(1, "TAGE inflight depth must be a power of two");
        if (INFLIGHT_DEPTH >=
            (1 << (`OPENRV64_INSTR_ID_WIDTH - 1)))
            $fatal(1, "TAGE inflight depth exceeds modular ID half-range");
        if ((AGE_INTERVAL < 2) ||
            ((1 << AGE_COUNT_WIDTH) != AGE_INTERVAL))
            $fatal(1, "TAGE age interval must be a power of two");
    end

    always @(posedge clk) begin
        if (rst_n && lookup_allocate_i && lookup_branch_i &&
            !lookup_response_match)
            $error("TAGE conditional lookup allocated without RAM response");
        if (rst_n && resolve_valid_i &&
            (ENABLE_TAGGED_RESOLUTION != 0) && !resolve_tag_match)
            $error("TAGE tagged resolution missed id=%016x pc=%016x",
                   resolve_id_i, resolve_pc_i);
        if (rst_n && resolve_has_record &&
            (ENABLE_TAGGED_RESOLUTION == 0) &&
            (resolve_pc_i != inflight_pc_q[resolve_index]))
            $error("TAGE resolution order mismatch: got pc=%016x expected=%016x",
                   resolve_pc_i, inflight_pc_q[resolve_index]);
        if (rst_n && resolve_has_record &&
            (resolve_branch_i != inflight_branch_q[resolve_index]))
            $error("TAGE resolution kind mismatch at pc=%016x", resolve_pc_i);
    end
`endif
endmodule

`endif
