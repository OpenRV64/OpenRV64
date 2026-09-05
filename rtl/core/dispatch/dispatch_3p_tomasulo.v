`ifndef OPENRV64_DISPATCH_3P_TOMASULO_V
`define OPENRV64_DISPATCH_3P_TOMASULO_V

`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Dedicated physical-register issue-window variant.  Selection, control, and
// memory-order policy deliberately remain shared with dispatch_window_3p;
// dependency readiness and operand addresses are physical tags supplied by
// the speculative RAT.  Keeping this as a distinct module gives the backend a
// hard configuration boundary instead of leaking rename-mode conditionals
// into the architectural 3P window instantiation.
module openrv64_dispatch_3p_tomasulo #(
    parameter integer ENABLE_SPECULATION = 0,
    parameter integer ENABLE_ALU2 = 0,
    parameter integer ENABLE_ALU_CHAINING = 0,
    parameter integer ENABLE_LOAD_CONFLICT_RECORD = 0,
    parameter integer MAX_ISSUE_LANES = 3,
    parameter integer DEPTH = 16,
    parameter integer PHYS_REG_ADDR_WIDTH = 6,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}},
    parameter integer RETIRE_SLOT_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire clk,
    input  wire rst_n,
    input  wire flush_i,
    input  wire squash_frontend_i,
    input  wire squash_inclusive_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,
    input  wire translation_bypass_i,
    input  wire load_conflict_train_valid_i,
    input  wire [`RV64_XLEN-1:0] load_conflict_train_pc_i,
    input  wire [2:0] decode_valid_i,
    output wire [2:0] decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        decode_payload_i,
    input  wire [2:0] decode_uses_rs1_i,
    input  wire [2:0] decode_uses_rs2_i,
    input  wire prediction_update_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] prediction_update_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] prediction_update_slot_i,
    input  wire prediction_update_taken_i,
    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] rename_source_arch_o,
    input  wire [6*PHYS_REG_ADDR_WIDTH-1:0] rename_source_phys_i,
    input  wire [5:0] rename_source_ready_i,
    input  wire [5:0] rename_source_producer_valid_i,
    input  wire [6*`OPENRV64_INSTR_ID_WIDTH-1:0]
        rename_source_producer_id_i,
    input  wire [3*PHYS_REG_ADDR_WIDTH-1:0] rename_destination_phys_i,
    input  wire [2:0] physical_forward_valid_i,
    input  wire [2:0] physical_writeback_valid_i,
    input  wire [3*PHYS_REG_ADDR_WIDTH-1:0] physical_writeback_tag_i,
    input  wire [3*`RV64_XLEN-1:0] physical_writeback_data_i,
    input  wire [2:0] allocation_ready_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0] allocation_valid_o,
    output wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0] allocation_meta_o,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    input  wire [1:0] chain_producer_valid_i,
    input  wire [2*`OPENRV64_INSTR_ID_WIDTH-1:0] chain_producer_id_i,
    input  wire [2*PHYS_REG_ADDR_WIDTH-1:0] chain_producer_phys_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_candidate_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_squashed_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*2-1:0] pipe_age_rank_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        pipe_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
        pipe_slot_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] pipe_payload_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_uses_rs1_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_uses_rs2_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        pipe_src1_producer_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        pipe_src1_producer_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        pipe_src2_producer_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        pipe_src2_producer_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        pipe_src1_phys_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        pipe_src2_phys_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        pipe_destination_phys_o,
    input  wire [2:0] completion_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        completion_payload_i,
    input  wire conditional_resolve_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] conditional_resolve_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] conditional_resolve_slot_i,
    input  wire [2:0] retire_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] retire_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] retire_slot_i,
    input  wire [2:0] retire_hard_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] next_retire_slot_i,
    output wire barrier_active_o,
    output wire [2:0] raw_hazard_o,
    output wire [2:0] waw_hazard_o,
    output wire [2:0] read_port_hazard_o,
    output wire [31:0] write_busy_o,
    output wire [COUNT_WIDTH-1:0] queue_count_o
);

    function automatic is_fused_producer;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fused_producer =
                payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] &&
                payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_MEM_READ_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_MEM_WRITE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BRANCH_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_JUMP_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FENCE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_SYSTEM_BIT];
        end
    endfunction

    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] decode_payload0 =
        decode_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] decode_payload1 =
        decode_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] decode_payload2 =
        decode_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire decode_fused_pair0 = decode_valid_i[0] && decode_valid_i[1] &&
        is_fused_producer(decode_payload0) &&
        decode_payload1[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] &&
        !is_fused_producer(decode_payload1);
    wire decode_fused_pair1 = decode_valid_i[1] && decode_valid_i[2] &&
        is_fused_producer(decode_payload1) &&
        decode_payload2[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] &&
        !is_fused_producer(decode_payload2);
    wire [2:0] window_decode_ready;
    wire [2:0] window_decode_valid;
    // Keep downstream rename/ROB readiness out of the issue window's ready
    // calculation.  Gating valid with decode_ready_o would make ready depend
    // on itself.  Per-lane allocation readiness is sufficient here: the
    // window applies its own capacity check, including the fused-pair check.
    assign window_decode_valid[0] = decode_valid_i[0] &&
        allocation_ready_i[0] &&
        (!decode_fused_pair0 || allocation_ready_i[1]);
    assign window_decode_valid[1] = decode_valid_i[1] &&
        allocation_ready_i[1] &&
        (!decode_fused_pair0 || allocation_ready_i[0]) &&
        (!decode_fused_pair1 || allocation_ready_i[2]);
    assign window_decode_valid[2] = decode_valid_i[2] &&
        allocation_ready_i[2] &&
        (!decode_fused_pair1 || allocation_ready_i[1]);
    wire [2:0] raw_decode_ready = window_decode_ready & allocation_ready_i;
    assign decode_ready_o[0] = raw_decode_ready[0] &&
        (!decode_fused_pair0 || raw_decode_ready[1]);
    assign decode_ready_o[1] = raw_decode_ready[1] && decode_ready_o[0] &&
        (!decode_fused_pair1 || raw_decode_ready[2]);
    assign decode_ready_o[2] = raw_decode_ready[2] && decode_ready_o[1];

    openrv64_dispatch_window_3p #(
        .ENABLE(1),
        .PHYSICAL_RENAME(1),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ENABLE_SPECULATION(ENABLE_SPECULATION),
        .ENABLE_ALU2(ENABLE_ALU2),
        .ENABLE_ALU_CHAINING(ENABLE_ALU_CHAINING),
        .ENABLE_LOAD_CONFLICT_RECORD(ENABLE_LOAD_CONFLICT_RECORD),
        .DEFER_GPR_READ(1),
        .MAX_ISSUE_LANES(MAX_ISSUE_LANES),
        .DEPTH(DEPTH),
        .CACHEABLE_BASE(CACHEABLE_BASE),
        .CACHEABLE_SIZE(CACHEABLE_SIZE),
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) u_window (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .squash_frontend_i(squash_frontend_i),
        .squash_inclusive_i(squash_inclusive_i),
        .squash_id_i(squash_id_i),
        .translation_bypass_i(translation_bypass_i),
        .load_conflict_train_valid_i(load_conflict_train_valid_i),
        .load_conflict_train_pc_i(load_conflict_train_pc_i),
        // Suppress lanes which cannot also allocate their rename/ROB state.
        // The issue window supplies the capacity half of the handshake.
        .decode_valid_i(window_decode_valid),
        .decode_ready_o(window_decode_ready),
        .decode_payload_i(decode_payload_i),
        .decode_uses_rs1_i(decode_uses_rs1_i),
        .decode_uses_rs2_i(decode_uses_rs2_i),
        .prediction_update_valid_i(prediction_update_valid_i),
        .prediction_update_id_i(prediction_update_id_i),
        .prediction_update_slot_i(prediction_update_slot_i),
        .prediction_update_taken_i(prediction_update_taken_i),
        .gpr_read_addr_o(rename_source_arch_o),
        .gpr_read_data_i({6*`RV64_XLEN{1'b0}}),
        .rename_source_phys_i(rename_source_phys_i),
        .rename_source_ready_i(rename_source_ready_i),
        .rename_source_producer_valid_i(
            rename_source_producer_valid_i),
        .rename_source_producer_id_i(rename_source_producer_id_i),
        .rename_destination_phys_i(rename_destination_phys_i),
        .physical_forward_valid_i(physical_forward_valid_i),
        .physical_writeback_valid_i(physical_writeback_valid_i),
        .physical_writeback_tag_i(physical_writeback_tag_i),
        .physical_writeback_data_i(physical_writeback_data_i),
        .allocation_ready_i(allocation_ready_i[0]),
        .allocation_id_i(allocation_id_i),
        .allocation_slot_i(allocation_slot_i),
        .allocation_valid_o(allocation_valid_o),
        .allocation_meta_o(allocation_meta_o),
        .pipe_ready_i(pipe_ready_i),
        .chain_producer_valid_i(chain_producer_valid_i),
        .chain_producer_id_i(chain_producer_id_i),
        .chain_producer_phys_i(chain_producer_phys_i),
        .pipe_candidate_valid_o(pipe_candidate_valid_o),
        .pipe_squashed_o(pipe_squashed_o),
        .pipe_age_rank_o(pipe_age_rank_o),
        .pipe_valid_o(pipe_valid_o),
        .pipe_id_o(pipe_id_o), .pipe_slot_o(pipe_slot_o),
        .pipe_payload_o(pipe_payload_o),
        .pipe_uses_rs1_o(pipe_uses_rs1_o),
        .pipe_uses_rs2_o(pipe_uses_rs2_o),
        .pipe_src1_producer_valid_o(pipe_src1_producer_valid_o),
        .pipe_src1_producer_id_o(pipe_src1_producer_id_o),
        .pipe_src2_producer_valid_o(pipe_src2_producer_valid_o),
        .pipe_src2_producer_id_o(pipe_src2_producer_id_o),
        .pipe_src1_phys_o(pipe_src1_phys_o),
        .pipe_src2_phys_o(pipe_src2_phys_o),
        .pipe_destination_phys_o(pipe_destination_phys_o),
        .completion_valid_i(completion_valid_i),
        .completion_id_i(completion_id_i),
        .completion_payload_i(completion_payload_i),
        .conditional_resolve_valid_i(conditional_resolve_valid_i),
        .conditional_resolve_id_i(conditional_resolve_id_i),
        .conditional_resolve_slot_i(conditional_resolve_slot_i),
        .retire_valid_i(retire_valid_i),
        .retire_id_i(retire_id_i), .retire_slot_i(retire_slot_i),
        .retire_hard_i(retire_hard_i),
        .next_retire_id_i(next_retire_id_i),
        .next_retire_slot_i(next_retire_slot_i),
        .barrier_active_o(barrier_active_o),
        .raw_hazard_o(raw_hazard_o), .waw_hazard_o(waw_hazard_o),
        .read_port_hazard_o(read_port_hazard_o),
        .write_busy_o(write_busy_o), .queue_count_o(queue_count_o)
    );

endmodule

`endif
