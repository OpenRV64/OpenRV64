`ifndef OPENRV64_FD_DISPATCH_V
`define OPENRV64_FD_DISPATCH_V
`timescale 1ns/1ps

`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/exec/fpu/defs.v"
`include "core/exec/fpu/isa/rv64-f.v"

// F/D client of the generic extension scheduling contract.
//
// The parent window remains the only owner of program age, global issue
// eligibility, control recovery, memory ordering, and retirement slots.  This
// sidecar is indexed by those same slots and owns only F/D-specific state:
// FPR producer tags, tagged pending results, FPU selection/backpressure, and
// ordered architectural FPR commit.  FPU and LSU-load results use the same
// slot-indexed result cells and exact-tag operand bypass.
module openrv64_fd_dispatch #(
    parameter integer WINDOW_DEPTH = 16,
    parameter integer RETIRE_SLOT_WIDTH = $clog2(WINDOW_DEPTH)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,

    // Qualified by the F/D decode claim.  Integer instructions do not
    // allocate metadata or result cells in this sidecar.
    input  wire [2:0]                   allocation_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        allocation_base_payload_i,
    input  wire [3*`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH-1:0]
                                        allocation_payload_i,
    input  wire [3*`OPENRV64_EXTENSION_BRANCH_COUNT-1:0]
                                        allocation_branch_mask_i,

    // The parent computes these after combining GPR, control, memory-order,
    // and sidecar operand readiness.  issued prevents store-data recapture
    // while the macro-instruction remains resident until retirement.
    input  wire [WINDOW_DEPTH-1:0]      window_eligible_i,
    input  wire [WINDOW_DEPTH-1:0]      window_issued_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] next_retire_slot_i,

    // F/D compute operations normally read FPRs.  Integer-to-FP moves and
    // conversions request their one scalar operand only after this sidecar has
    // selected a slot; the parent window either resolves its dependency or
    // lends a spare GPR read port.
    output reg                          scalar_read_valid_o,
    output reg  [`RV64_REG_ADDR_WIDTH-1:0] scalar_read_addr_o,
    input  wire                         scalar_read_ready_i,
    input  wire [`RV64_XLEN-1:0]        scalar_read_data_i,

    output reg  [WINDOW_DEPTH-1:0]      entry_fp_valid_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_compute_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_load_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_store_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_operand_ready_o,
    output reg  [WINDOW_DEPTH*`RV64_XLEN-1:0] entry_mem_store_data_o,
    output wire                         fp_mem_load_ready_o,

    output reg  [3*`RV64_REG_ADDR_WIDTH-1:0] fpr_read_addr_o,
    input  wire [3*`RV64_XLEN-1:0]      fpr_read_data_i,
    output reg  [`RV64_REG_ADDR_WIDTH-1:0] fpr_store_read_addr_o,
    input  wire [`RV64_XLEN-1:0]        fpr_store_read_data_i,

    input  wire                         fpu_ready_i,
    output reg                          fpu_valid_o,
    output wire                         fpu_fire_o,
    output reg  [`OPENRV64_INSTR_ID_WIDTH-1:0] fpu_id_o,
    output reg  [RETIRE_SLOT_WIDTH-1:0] fpu_slot_o,
    output reg  [`OPENRV64_FP_OP_WIDTH-1:0] fpu_op_o,
    output reg  [1:0]                   fpu_fmt_o,
    output reg  [2:0]                   fpu_rm_o,
    output reg  [4:0]                   fpu_type_o,
    output reg  [`RV64_XLEN-1:0]        fpu_src1_o,
    output reg  [`RV64_XLEN-1:0]        fpu_src2_o,
    output reg  [`RV64_XLEN-1:0]        fpu_src3_o,
    output reg  [`RV64_REG_ADDR_WIDTH-1:0] fpu_rd_o,
    output reg                          fpu_fp_reg_write_o,
    output reg                          fpu_int_reg_write_o,
    output reg                          fpu_fflags_write_o,
    output reg  [`OPENRV64_EXTENSION_BRANCH_COUNT-1:0] fpu_branch_mask_o,

    // FPU results are captured in an extension-owned, slot-indexed bank.
    // Completion is reported separately to the generic integer retirement
    // queue only after the data and status are resident here.
    input  wire                         fpu_result_valid_i,
    output wire                         fpu_result_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fpu_result_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fpu_result_slot_i,
    input  wire                         fpu_result_is_int_i,
    input  wire [`RV64_XLEN-1:0]        fpu_result_fp_i,
    input  wire [`RV64_XLEN-1:0]        fpu_result_int_i,
    input  wire [4:0]                   fpu_result_fflags_i,
    input  wire                         fpu_result_unsupported_i,

    output reg                          completion_valid_o,
    input  wire                         completion_accept_i,
    output reg  [`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_o,
    output reg  [RETIRE_SLOT_WIDTH-1:0] completion_slot_o,

    // The generic LSU pulses this when a load is accepted.  Decode has
    // already reserved the private destination; this exact-tagged event
    // confirms that the reservation reached the shared LSQ.
    input  wire                         fp_load_assignment_valid_i,
    output wire                         fp_load_assignment_match_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        fp_load_assignment_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0]
                                        fp_load_assignment_slot_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        fp_load_assignment_rd_i,
    input  wire [2:0]                   fp_load_assignment_size_i,

    input  wire                         fp_load_result_valid_i,
    output wire                         fp_load_result_match_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fp_load_result_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fp_load_result_slot_i,
    input  wire [`RV64_XLEN-1:0]        fp_load_result_data_i,

    // Memory exceptions remain ordinary LSU/retirement exceptions.  The
    // sidecar needs only the matching identity so a faulting load does not
    // wait forever for result data that architecturally must not arrive.
    input  wire                         fp_mem_fault_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fp_mem_fault_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fp_mem_fault_slot_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_accept_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] retire_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] retire_slot_i,
    output reg  [2:0]                   retire_ready_o,
    output reg  [2:0]                   retire_load_data_valid_o,
    output reg  [3*`RV64_XLEN-1:0]      retire_load_data_o,
    output reg  [2:0]                   retire_result_valid_o,
    output reg  [2:0]                   retire_private_write_o,
    output reg  [2:0]                   retire_gpr_write_o,
    output reg  [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_o,
    output reg  [3*`RV64_XLEN-1:0]      retire_result_data_o,
    output reg  [2:0]                   retire_fflags_valid_o,
    output reg  [3*5-1:0]               retire_fflags_o,
    output reg  [2:0]                   retire_unsupported_o,

    output wire [31:0]                  fp_write_busy_o
);

    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer BASE_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer PAYLOAD_WIDTH = `OPENRV64_FPU_DECODE_PAYLOAD_WIDTH;
    wire [2:0] retire_fire = retire_valid_i & retire_accept_i;

    reg meta_valid_q [0:WINDOW_DEPTH-1];
    reg [ID_WIDTH-1:0] id_q [0:WINDOW_DEPTH-1];
    reg src1_fp_q [0:WINDOW_DEPTH-1];
    reg src2_fp_q [0:WINDOW_DEPTH-1];
    reg src3_fp_q [0:WINDOW_DEPTH-1];
    reg fp_reg_write_q [0:WINDOW_DEPTH-1];
    reg int_reg_write_q [0:WINDOW_DEPTH-1];
    reg fflags_write_q [0:WINDOW_DEPTH-1];
    reg fp_load_q [0:WINDOW_DEPTH-1];
    reg fp_store_q [0:WINDOW_DEPTH-1];
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs1_q [0:WINDOW_DEPTH-1];
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs2_q [0:WINDOW_DEPTH-1];
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs3_q [0:WINDOW_DEPTH-1];
    reg [`RV64_REG_ADDR_WIDTH-1:0] rd_q [0:WINDOW_DEPTH-1];
    reg [`OPENRV64_FP_OP_WIDTH-1:0] op_q [0:WINDOW_DEPTH-1];
    reg [1:0] fmt_q [0:WINDOW_DEPTH-1];
    reg [2:0] rm_q [0:WINDOW_DEPTH-1];
    reg [4:0] type_q [0:WINDOW_DEPTH-1];
    reg [`OPENRV64_EXTENSION_BRANCH_COUNT-1:0]
        branch_mask_q [0:WINDOW_DEPTH-1];

    reg src1_ready_q [0:WINDOW_DEPTH-1];
    reg src2_ready_q [0:WINDOW_DEPTH-1];
    reg src3_ready_q [0:WINDOW_DEPTH-1];
    reg [ID_WIDTH-1:0] src1_tag_q [0:WINDOW_DEPTH-1];
    reg [ID_WIDTH-1:0] src2_tag_q [0:WINDOW_DEPTH-1];
    reg [ID_WIDTH-1:0] src3_tag_q [0:WINDOW_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] src1_slot_q [0:WINDOW_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] src2_slot_q [0:WINDOW_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] src3_slot_q [0:WINDOW_DEPTH-1];

    reg [31:0] owner_valid_q;
    reg [ID_WIDTH-1:0] owner_id_q [0:31];
    reg [RETIRE_SLOT_WIDTH-1:0] owner_slot_q [0:31];

    // Sparse in use even though it shares the parent window's slot index:
    // result_valid_q and complete_pending_q are set only for F/D operations.
    // Integer retirement stores no F/D data.
    reg result_valid_q [0:WINDOW_DEPTH-1];
    reg [`RV64_XLEN-1:0] result_data_q [0:WINDOW_DEPTH-1];
    reg [4:0] result_fflags_q [0:WINDOW_DEPTH-1];
    reg result_unsupported_q [0:WINDOW_DEPTH-1];
    reg result_mem_fault_q [0:WINDOW_DEPTH-1];
    reg complete_pending_q [0:WINDOW_DEPTH-1];
    reg load_assigned_q [0:WINDOW_DEPTH-1];
    // Store operands are pre-read through the dedicated FPR port and retained
    // in their owning window slots.  The LSU sees registered data only, so no
    // private-register path participates in integer LSU ready/valid.
    reg store_data_valid_q [0:WINDOW_DEPTH-1];
    reg [`RV64_XLEN-1:0] store_data_q [0:WINDOW_DEPTH-1];

    function automatic id_is_younger;
        input [ID_WIDTH-1:0] candidate;
        input [ID_WIDTH-1:0] reference;
        reg [ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger = (distance != {ID_WIDTH{1'b0}}) &&
                            !distance[ID_WIDTH-1];
        end
    endfunction

    function automatic is_fp_compute_slot;
        input integer slot;
        begin
            is_fp_compute_slot = meta_valid_q[slot] &&
                                 !fp_load_q[slot] && !fp_store_q[slot];
        end
    endfunction

    // A live FPR producer keeps its value in the slot-indexed result bank
    // until ordered retirement writes the architectural FPR.  Consumers use
    // the full {slot, instruction-ID} producer identity rather than an
    // architectural register number so slot reuse and later writers cannot
    // alias the bypass.  The slot makes this a direct lookup, not a window CAM.
    function automatic producer_result_available;
        input [ID_WIDTH-1:0] producer_id;
        input [RETIRE_SLOT_WIDTH-1:0] producer_slot;
        begin
            producer_result_available =
                (producer_slot < WINDOW_DEPTH) &&
                meta_valid_q[producer_slot] &&
                fp_reg_write_q[producer_slot] &&
                result_valid_q[producer_slot] &&
                (id_q[producer_slot] == producer_id);
        end
    endfunction

    function automatic [`RV64_XLEN-1:0] producer_result_data;
        input [ID_WIDTH-1:0] producer_id;
        input [RETIRE_SLOT_WIDTH-1:0] producer_slot;
        begin
            producer_result_data = {`RV64_XLEN{1'b0}};
            if ((producer_slot < WINDOW_DEPTH) &&
                meta_valid_q[producer_slot] &&
                fp_reg_write_q[producer_slot] &&
                result_valid_q[producer_slot] &&
                (id_q[producer_slot] == producer_id))
                producer_result_data = result_data_q[producer_slot];
        end
    endfunction

    // Ordered admission view: retirement removes current owners first, then
    // later allocation lanes observe FPR writers from earlier lanes.
    reg [31:0] owner_valid_view;
    reg [ID_WIDTH-1:0] owner_id_view [0:31];
    reg [RETIRE_SLOT_WIDTH-1:0] owner_slot_view [0:31];
    reg admit_src1_ready [0:2];
    reg admit_src2_ready [0:2];
    reg admit_src3_ready [0:2];
    reg [ID_WIDTH-1:0] admit_src1_tag [0:2];
    reg [ID_WIDTH-1:0] admit_src2_tag [0:2];
    reg [ID_WIDTH-1:0] admit_src3_tag [0:2];
    reg [RETIRE_SLOT_WIDTH-1:0] admit_src1_slot [0:2];
    reg [RETIRE_SLOT_WIDTH-1:0] admit_src2_slot [0:2];
    reg [RETIRE_SLOT_WIDTH-1:0] admit_src3_slot [0:2];
    reg [BASE_WIDTH-1:0] admit_base_payload [0:2];
    reg [PAYLOAD_WIDTH-1:0] admit_payload [0:2];
    reg [`RV64_REG_ADDR_WIDTH-1:0] admit_rs1;
    reg [`RV64_REG_ADDR_WIDTH-1:0] admit_rs2;
    reg [`RV64_REG_ADDR_WIDTH-1:0] admit_rs3;
    reg [`RV64_REG_ADDR_WIDTH-1:0] admit_rd;
    reg [ID_WIDTH-1:0] admit_id;
    integer view_owner_idx;
    integer view_admit_lane;
    integer view_retire_lane;

    always_comb begin
        owner_valid_view = owner_valid_q;
        for (view_owner_idx = 0; view_owner_idx < 32;
             view_owner_idx = view_owner_idx + 1) begin
            owner_id_view[view_owner_idx] = owner_id_q[view_owner_idx];
            owner_slot_view[view_owner_idx] = owner_slot_q[view_owner_idx];
        end

        for (view_retire_lane = 0; view_retire_lane < 3;
             view_retire_lane = view_retire_lane + 1) begin
            for (view_owner_idx = 0; view_owner_idx < 32;
                 view_owner_idx = view_owner_idx + 1) begin
                if (retire_fire[view_retire_lane] &&
                    owner_valid_view[view_owner_idx] &&
                    (owner_id_view[view_owner_idx] == retire_id_i[
                        view_retire_lane*ID_WIDTH +: ID_WIDTH]))
                    owner_valid_view[view_owner_idx] = 1'b0;
            end
        end

        for (view_admit_lane = 0; view_admit_lane < 3;
            view_admit_lane = view_admit_lane + 1) begin
            admit_payload[view_admit_lane] = allocation_payload_i[
                view_admit_lane*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
            admit_base_payload[view_admit_lane] = allocation_base_payload_i[
                view_admit_lane*BASE_WIDTH +: BASE_WIDTH];
            admit_rs1 = admit_base_payload[view_admit_lane][237 +:
                `RV64_REG_ADDR_WIDTH];
            admit_rs2 = admit_base_payload[view_admit_lane][232 +:
                `RV64_REG_ADDR_WIDTH];
            admit_rs3 = admit_payload[view_admit_lane][
                `OPENRV64_FPU_RS3_ADDR_LSB +: `RV64_REG_ADDR_WIDTH];
            admit_rd = admit_base_payload[view_admit_lane][35 +:
                `RV64_REG_ADDR_WIDTH];
            admit_id = allocation_id_i[
                view_admit_lane*ID_WIDTH +: ID_WIDTH];

            admit_src1_ready[view_admit_lane] = 1'b1;
            admit_src2_ready[view_admit_lane] = 1'b1;
            admit_src3_ready[view_admit_lane] = 1'b1;
            admit_src1_tag[view_admit_lane] = {ID_WIDTH{1'b0}};
            admit_src2_tag[view_admit_lane] = {ID_WIDTH{1'b0}};
            admit_src3_tag[view_admit_lane] = {ID_WIDTH{1'b0}};
            admit_src1_slot[view_admit_lane] =
                {RETIRE_SLOT_WIDTH{1'b0}};
            admit_src2_slot[view_admit_lane] =
                {RETIRE_SLOT_WIDTH{1'b0}};
            admit_src3_slot[view_admit_lane] =
                {RETIRE_SLOT_WIDTH{1'b0}};

            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC1_PRIVATE_BIT] &&
                owner_valid_view[admit_rs1]) begin
                admit_src1_ready[view_admit_lane] = 1'b0;
                admit_src1_tag[view_admit_lane] = owner_id_view[admit_rs1];
                admit_src1_slot[view_admit_lane] =
                    owner_slot_view[admit_rs1];
            end
            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC2_PRIVATE_BIT] &&
                owner_valid_view[admit_rs2]) begin
                admit_src2_ready[view_admit_lane] = 1'b0;
                admit_src2_tag[view_admit_lane] = owner_id_view[admit_rs2];
                admit_src2_slot[view_admit_lane] =
                    owner_slot_view[admit_rs2];
            end
            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][`OPENRV64_FPU_USES_SRC3_BIT] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC3_PRIVATE_BIT] &&
                owner_valid_view[admit_rs3]) begin
                admit_src3_ready[view_admit_lane] = 1'b0;
                admit_src3_tag[view_admit_lane] = owner_id_view[admit_rs3];
                admit_src3_slot[view_admit_lane] =
                    owner_slot_view[admit_rs3];
            end

            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT]) begin
                owner_valid_view[admit_rd] = 1'b1;
                owner_id_view[admit_rd] = admit_id;
                owner_slot_view[admit_rd] = allocation_slot_i[
                    view_admit_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
            end
        end
    end

    // Rebuild the youngest surviving FPR owner after selective recovery.
    reg [31:0] survivor_owner_valid;
    reg [ID_WIDTH-1:0] survivor_owner_id [0:31];
    reg [RETIRE_SLOT_WIDTH-1:0] survivor_owner_slot [0:31];
    reg survivor_retiring;
    integer survivor_idx;
    integer survivor_lane;
    integer survivor_owner_idx;
    always_comb begin
        survivor_owner_valid = 32'd0;
        for (survivor_owner_idx = 0; survivor_owner_idx < 32;
             survivor_owner_idx = survivor_owner_idx + 1) begin
            survivor_owner_id[survivor_owner_idx] = {ID_WIDTH{1'b0}};
            survivor_owner_slot[survivor_owner_idx] =
                {RETIRE_SLOT_WIDTH{1'b0}};
        end
        for (survivor_idx = 0; survivor_idx < WINDOW_DEPTH;
             survivor_idx = survivor_idx + 1) begin
            survivor_retiring = 1'b0;
            for (survivor_lane = 0; survivor_lane < 3;
                 survivor_lane = survivor_lane + 1) begin
                if (retire_fire[survivor_lane] &&
                    (retire_id_i[survivor_lane*ID_WIDTH +: ID_WIDTH] ==
                     id_q[survivor_idx]))
                    survivor_retiring = 1'b1;
            end
            if (meta_valid_q[survivor_idx] && !survivor_retiring &&
                !id_is_younger(id_q[survivor_idx], squash_id_i) &&
                fp_reg_write_q[survivor_idx] &&
                (!survivor_owner_valid[rd_q[survivor_idx]] ||
                 id_is_younger(id_q[survivor_idx],
                               survivor_owner_id[rd_q[survivor_idx]]))) begin
                survivor_owner_valid[rd_q[survivor_idx]] = 1'b1;
                survivor_owner_id[rd_q[survivor_idx]] = id_q[survivor_idx];
                survivor_owner_slot[rd_q[survivor_idx]] =
                    survivor_idx[RETIRE_SLOT_WIDTH-1:0];
            end
        end
    end

`ifndef SYNTHESIS
    // Simulation-only dependency attribution.  A blocked operand is
    // "forwardable" only when every currently blocked FPR source has a value
    // arriving on a completion input in this cycle.  Values already resident
    // in the common result bank participate in normal operand readiness.
    localparam integer TRACE_COUNT_WIDTH = $clog2(WINDOW_DEPTH + 1);

    function automatic trace_producer_value_available;
        input [ID_WIDTH-1:0] producer_id;
        input [RETIRE_SLOT_WIDTH-1:0] producer_slot;
        begin
            trace_producer_value_available =
                producer_result_available(producer_id, producer_slot);
            if (fpu_result_valid_i &&
                (fpu_result_id_i == producer_id) &&
                (fpu_result_slot_i == producer_slot))
                trace_producer_value_available = 1'b1;
            if (fp_load_result_valid_i &&
                (fp_load_result_id_i == producer_id) &&
                (fp_load_result_slot_i == producer_slot))
                trace_producer_value_available = 1'b1;
        end
    endfunction

    reg [TRACE_COUNT_WIDTH-1:0] trace_compute_unissued_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_compute_operand_ready_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_compute_eligible_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_compute_forwardable_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_compute_producer_pending_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_store_source_block_count;
    reg [TRACE_COUNT_WIDTH-1:0] trace_store_source_forwardable_count;
    integer trace_dependency_slot;
    reg trace_has_blocked_source;
    reg trace_all_blocked_sources_available;
    reg trace_source_available;

    always_comb begin
        trace_compute_unissued_count = {TRACE_COUNT_WIDTH{1'b0}};
        trace_compute_operand_ready_count = {TRACE_COUNT_WIDTH{1'b0}};
        trace_compute_eligible_count = {TRACE_COUNT_WIDTH{1'b0}};
        trace_compute_forwardable_count = {TRACE_COUNT_WIDTH{1'b0}};
        trace_compute_producer_pending_count =
            {TRACE_COUNT_WIDTH{1'b0}};
        trace_store_source_block_count = {TRACE_COUNT_WIDTH{1'b0}};
        trace_store_source_forwardable_count =
            {TRACE_COUNT_WIDTH{1'b0}};
        trace_has_blocked_source = 1'b0;
        trace_all_blocked_sources_available = 1'b0;
        trace_source_available = 1'b0;

        for (trace_dependency_slot = 0;
             trace_dependency_slot < WINDOW_DEPTH;
             trace_dependency_slot = trace_dependency_slot + 1) begin
            if (meta_valid_q[trace_dependency_slot] &&
                !window_issued_i[trace_dependency_slot] &&
                is_fp_compute_slot(trace_dependency_slot)) begin
                trace_compute_unissued_count =
                    trace_compute_unissued_count + 1'b1;
                if (entry_operand_ready_o[trace_dependency_slot])
                    trace_compute_operand_ready_count =
                        trace_compute_operand_ready_count + 1'b1;
                if (window_eligible_i[trace_dependency_slot])
                    trace_compute_eligible_count =
                        trace_compute_eligible_count + 1'b1;

                if (!entry_operand_ready_o[trace_dependency_slot]) begin
                    trace_has_blocked_source = 1'b0;
                    trace_all_blocked_sources_available = 1'b1;
                    if (src1_fp_q[trace_dependency_slot] &&
                        !src1_ready_q[trace_dependency_slot]) begin
                        trace_has_blocked_source = 1'b1;
                            trace_source_available =
                            trace_producer_value_available(
                                src1_tag_q[trace_dependency_slot],
                                src1_slot_q[trace_dependency_slot]);
                        if (!trace_source_available)
                            trace_all_blocked_sources_available = 1'b0;
                    end
                    if (src2_fp_q[trace_dependency_slot] &&
                        !src2_ready_q[trace_dependency_slot]) begin
                        trace_has_blocked_source = 1'b1;
                            trace_source_available =
                            trace_producer_value_available(
                                src2_tag_q[trace_dependency_slot],
                                src2_slot_q[trace_dependency_slot]);
                        if (!trace_source_available)
                            trace_all_blocked_sources_available = 1'b0;
                    end
                    if (src3_fp_q[trace_dependency_slot] &&
                        !src3_ready_q[trace_dependency_slot]) begin
                        trace_has_blocked_source = 1'b1;
                            trace_source_available =
                            trace_producer_value_available(
                                src3_tag_q[trace_dependency_slot],
                                src3_slot_q[trace_dependency_slot]);
                        if (!trace_source_available)
                            trace_all_blocked_sources_available = 1'b0;
                    end
                    if (trace_has_blocked_source &&
                        trace_all_blocked_sources_available)
                        trace_compute_forwardable_count =
                            trace_compute_forwardable_count + 1'b1;
                    else
                        trace_compute_producer_pending_count =
                            trace_compute_producer_pending_count + 1'b1;
                end
            end

            if (meta_valid_q[trace_dependency_slot] &&
                fp_store_q[trace_dependency_slot] &&
                !window_issued_i[trace_dependency_slot] &&
                src2_fp_q[trace_dependency_slot] &&
                !src2_ready_q[trace_dependency_slot]) begin
                trace_store_source_block_count =
                    trace_store_source_block_count + 1'b1;
                if (trace_producer_value_available(
                        src2_tag_q[trace_dependency_slot],
                        src2_slot_q[trace_dependency_slot]))
                    trace_store_source_forwardable_count =
                        trace_store_source_forwardable_count + 1'b1;
            end
        end
    end
`endif

    reg src1_ready_now [0:WINDOW_DEPTH-1];
    reg src2_ready_now [0:WINDOW_DEPTH-1];
    reg src3_ready_now [0:WINDOW_DEPTH-1];
    integer ready_slot;
    always_comb begin
        entry_fp_valid_o = {WINDOW_DEPTH{1'b0}};
        entry_fp_compute_o = {WINDOW_DEPTH{1'b0}};
        entry_fp_load_o = {WINDOW_DEPTH{1'b0}};
        entry_fp_store_o = {WINDOW_DEPTH{1'b0}};
        entry_operand_ready_o = {WINDOW_DEPTH{1'b1}};
        entry_mem_store_data_o =
            {WINDOW_DEPTH*`RV64_XLEN{1'b0}};
        for (ready_slot = 0; ready_slot < WINDOW_DEPTH;
            ready_slot = ready_slot + 1) begin
            src1_ready_now[ready_slot] = src1_ready_q[ready_slot] ||
                (src1_fp_q[ready_slot] &&
                 producer_result_available(src1_tag_q[ready_slot],
                                           src1_slot_q[ready_slot]));
            src2_ready_now[ready_slot] = src2_ready_q[ready_slot] ||
                (src2_fp_q[ready_slot] &&
                 producer_result_available(src2_tag_q[ready_slot],
                                           src2_slot_q[ready_slot]));
            src3_ready_now[ready_slot] = src3_ready_q[ready_slot] ||
                (src3_fp_q[ready_slot] &&
                 producer_result_available(src3_tag_q[ready_slot],
                                           src3_slot_q[ready_slot]));
            entry_fp_valid_o[ready_slot] = meta_valid_q[ready_slot];
            entry_fp_compute_o[ready_slot] =
                is_fp_compute_slot(ready_slot);
            entry_fp_load_o[ready_slot] =
                meta_valid_q[ready_slot] && fp_load_q[ready_slot];
            entry_fp_store_o[ready_slot] =
                meta_valid_q[ready_slot] && fp_store_q[ready_slot];
            if (meta_valid_q[ready_slot]) begin
                if (fp_store_q[ready_slot])
                    entry_operand_ready_o[ready_slot] =
                        store_data_valid_q[ready_slot];
                else
                    entry_operand_ready_o[ready_slot] =
                        (!src1_fp_q[ready_slot] ||
                         src1_ready_now[ready_slot]) &&
                        (!src2_fp_q[ready_slot] ||
                         src2_ready_now[ready_slot]) &&
                        (!src3_fp_q[ready_slot] ||
                         src3_ready_now[ready_slot]);
            end
            entry_mem_store_data_o[
                ready_slot*`RV64_XLEN +: `RV64_XLEN] =
                store_data_q[ready_slot];
        end
    end

    // FPU selection is age ordered over the globally eligible mask supplied
    // by the parent window.  Payload is independent of ready, preserving the
    // normal ready/valid backpressure contract.
    reg fpu_selected;
    integer fpu_select_offset;
    integer fpu_select_slot;
    integer fpu_slot_index;
    always_comb begin
        fpu_selected = 1'b0;
        fpu_slot_index = 0;
        for (fpu_select_offset = 0; fpu_select_offset < WINDOW_DEPTH;
             fpu_select_offset = fpu_select_offset + 1) begin
            fpu_select_slot =
                {{(32-RETIRE_SLOT_WIDTH){1'b0}}, next_retire_slot_i};
            fpu_select_slot = fpu_select_slot + fpu_select_offset;
            if (fpu_select_slot >= WINDOW_DEPTH)
                fpu_select_slot = fpu_select_slot - WINDOW_DEPTH;
            if (!fpu_selected && window_eligible_i[fpu_select_slot] &&
                entry_operand_ready_o[fpu_select_slot] &&
                !window_issued_i[fpu_select_slot] &&
                is_fp_compute_slot(fpu_select_slot)) begin
                fpu_selected = 1'b1;
                fpu_slot_index = fpu_select_slot;
            end
        end
    end

    // Keep payload generation separate from selection.  In particular, FPR
    // and scalar read data must not appear in the select process: both register
    // files are addressed from the selected slot, and merging these concerns
    // creates read-address/data feedback during elaboration.
    always_comb begin
        fpu_valid_o = fpu_selected;
        scalar_read_valid_o = 1'b0;
        scalar_read_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
        fpu_id_o = {ID_WIDTH{1'b0}};
        fpu_slot_o = {RETIRE_SLOT_WIDTH{1'b0}};
        fpu_op_o = `OPENRV64_FP_OP_INVALID;
        fpu_fmt_o = 2'd0;
        fpu_rm_o = 3'd0;
        fpu_type_o = 5'd0;
        fpu_src1_o = {`RV64_XLEN{1'b0}};
        fpu_src2_o = {`RV64_XLEN{1'b0}};
        fpu_src3_o = {`RV64_XLEN{1'b0}};
        fpu_rd_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
        fpu_fp_reg_write_o = 1'b0;
        fpu_int_reg_write_o = 1'b0;
        fpu_fflags_write_o = 1'b0;
        fpu_branch_mask_o = {`OPENRV64_EXTENSION_BRANCH_COUNT{1'b0}};
        if (fpu_selected) begin
            fpu_id_o = id_q[fpu_slot_index];
            fpu_slot_o = fpu_slot_index[RETIRE_SLOT_WIDTH-1:0];
            fpu_op_o = op_q[fpu_slot_index];
            fpu_fmt_o = fmt_q[fpu_slot_index];
            fpu_rm_o = rm_q[fpu_slot_index];
            fpu_type_o = type_q[fpu_slot_index];
            if (src1_fp_q[fpu_slot_index]) begin
                fpu_src1_o = src1_ready_q[fpu_slot_index] ?
                    fpr_read_data_i[0*`RV64_XLEN +: `RV64_XLEN] :
                    producer_result_data(src1_tag_q[fpu_slot_index],
                                         src1_slot_q[fpu_slot_index]);
            end else begin
                scalar_read_valid_o = 1'b1;
                scalar_read_addr_o = rs1_q[fpu_slot_index];
                fpu_src1_o = scalar_read_data_i;
                if (!scalar_read_ready_i)
                    fpu_valid_o = 1'b0;
            end
            if (src2_fp_q[fpu_slot_index]) begin
                fpu_src2_o = src2_ready_q[fpu_slot_index] ?
                    fpr_read_data_i[1*`RV64_XLEN +: `RV64_XLEN] :
                    producer_result_data(src2_tag_q[fpu_slot_index],
                                         src2_slot_q[fpu_slot_index]);
            end else begin
                // No standard F/D compute operation has a second scalar GPR
                // operand.  Non-private src2 is an unused encoded field.
                fpu_src2_o = {`RV64_XLEN{1'b0}};
            end
            if (src3_fp_q[fpu_slot_index]) begin
                fpu_src3_o = src3_ready_q[fpu_slot_index] ?
                    fpr_read_data_i[2*`RV64_XLEN +: `RV64_XLEN] :
                    producer_result_data(src3_tag_q[fpu_slot_index],
                                         src3_slot_q[fpu_slot_index]);
            end
            fpu_rd_o = rd_q[fpu_slot_index];
            fpu_fp_reg_write_o = fp_reg_write_q[fpu_slot_index];
            fpu_int_reg_write_o = int_reg_write_q[fpu_slot_index];
            fpu_fflags_write_o = fflags_write_q[fpu_slot_index];
            fpu_branch_mask_o = branch_mask_q[fpu_slot_index];
        end
    end
    assign fpu_fire_o = fpu_valid_o && fpu_ready_i;

    wire fpu_result_live = fpu_result_valid_i && !flush_i &&
        meta_valid_q[fpu_result_slot_i] &&
        !fp_load_q[fpu_result_slot_i] &&
        !fp_store_q[fpu_result_slot_i] &&
        (id_q[fpu_result_slot_i] == fpu_result_id_i) &&
        (!squash_i ||
         !id_is_younger(fpu_result_id_i, squash_id_i));
    wire fpu_result_capture = fpu_result_live &&
        !result_valid_q[fpu_result_slot_i];

    // Every slot has exactly one result cell, so a live first result can
    // always be absorbed.  Stale and duplicate responses are drained; they
    // never generate a parent completion token.
    assign fpu_result_ready_o = 1'b1;

    reg completion_selected;
    integer completion_offset;
    integer completion_index;
    integer completion_slot_index;
    always_comb begin
        completion_selected = 1'b0;
        completion_slot_index = 0;
        for (completion_offset = 0; completion_offset < WINDOW_DEPTH;
             completion_offset = completion_offset + 1) begin
            completion_index =
                {{(32-RETIRE_SLOT_WIDTH){1'b0}}, next_retire_slot_i};
            completion_index = completion_index + completion_offset;
            if (completion_index >= WINDOW_DEPTH)
                completion_index = completion_index - WINDOW_DEPTH;
            if (!completion_selected &&
                complete_pending_q[completion_index] &&
                meta_valid_q[completion_index]) begin
                completion_selected = 1'b1;
                completion_slot_index = completion_index;
            end
        end

        completion_valid_o = completion_selected;
        completion_id_o = {ID_WIDTH{1'b0}};
        completion_slot_o = {RETIRE_SLOT_WIDTH{1'b0}};
        if (completion_selected) begin
            completion_id_o = id_q[completion_slot_index];
            completion_slot_o =
                completion_slot_index[RETIRE_SLOT_WIDTH-1:0];
        end
    end

    // Computational operands use the three normal FPR read ports.
    always_comb begin
        fpr_read_addr_o = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        if (fpu_selected) begin
            if (src1_fp_q[fpu_slot_index])
                fpr_read_addr_o[0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] = rs1_q[fpu_slot_index];
            if (src2_fp_q[fpu_slot_index])
                fpr_read_addr_o[1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] = rs2_q[fpu_slot_index];
            if (src3_fp_q[fpu_slot_index])
                fpr_read_addr_o[2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] = rs3_q[fpu_slot_index];
        end
    end

    // Pre-read at most one store operand per cycle, oldest first.  This is a
    // buffered FPR read port, not a second memory queue: address translation,
    // ordering, faults, and completion remain entirely in the ordinary LSU.
    reg store_capture_selected;
    integer store_capture_offset;
    integer store_capture_index;
    integer store_capture_slot;
    reg [`RV64_XLEN-1:0] store_capture_data;
    always_comb begin
        store_capture_selected = 1'b0;
        store_capture_slot = 0;
        fpr_store_read_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
        for (store_capture_offset = 0;
             store_capture_offset < WINDOW_DEPTH;
             store_capture_offset = store_capture_offset + 1) begin
            store_capture_index =
                {{(32-RETIRE_SLOT_WIDTH){1'b0}}, next_retire_slot_i};
            store_capture_index = store_capture_index + store_capture_offset;
            if (store_capture_index >= WINDOW_DEPTH)
                store_capture_index = store_capture_index - WINDOW_DEPTH;
            if (!store_capture_selected &&
                meta_valid_q[store_capture_index] &&
                fp_store_q[store_capture_index] &&
                !store_data_valid_q[store_capture_index] &&
                src2_ready_now[store_capture_index]) begin
                store_capture_selected = 1'b1;
                store_capture_slot = store_capture_index;
            end
        end
        if (store_capture_selected)
            fpr_store_read_addr_o = rs2_q[store_capture_slot];
    end

    // Keep returned FPR data out of the address-selection process.  The shared
    // PRF is combinational; mixing address and returned data in one process
    // obscures the one-way dependency and creates a false combinational loop.
    always_comb begin
        store_capture_data = {`RV64_XLEN{1'b0}};
        if (store_capture_selected) begin
            store_capture_data = src2_ready_q[store_capture_slot] ?
                fpr_store_read_data_i :
                producer_result_data(src2_tag_q[store_capture_slot],
                                     src2_slot_q[store_capture_slot]);
        end
    end
    assign fp_mem_load_ready_o = 1'b1;

    // Compatibility view of load results at ordered retirement.  Loads and
    // arithmetic now occupy the same tagged result bank.
    integer retire_lookup_lane;
    integer retire_lookup_slot;
    always_comb begin
        retire_load_data_valid_o = 3'b000;
        retire_load_data_o = {3*`RV64_XLEN{1'b0}};
        for (retire_lookup_lane = 0; retire_lookup_lane < 3;
             retire_lookup_lane = retire_lookup_lane + 1) begin
            retire_lookup_slot = retire_slot_i[
                retire_lookup_lane*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH];
            if (retire_valid_i[retire_lookup_lane] &&
                meta_valid_q[retire_lookup_slot] &&
                fp_load_q[retire_lookup_slot] &&
                result_valid_q[retire_lookup_slot] &&
                (id_q[retire_lookup_slot] == retire_id_i[
                    retire_lookup_lane*ID_WIDTH +: ID_WIDTH])) begin
                retire_load_data_valid_o[retire_lookup_lane] = 1'b1;
                retire_load_data_o[
                    retire_lookup_lane*`RV64_XLEN +: `RV64_XLEN] =
                    result_data_q[retire_lookup_slot];
            end
        end
    end

    integer retire_result_lane;
    integer retire_result_slot;
    reg retire_private_port_used;
    reg retire_entry_match;
    reg retire_entry_data_ready;
    always_comb begin
        retire_ready_o = 3'b111;
        retire_result_valid_o = 3'b000;
        retire_private_write_o = 3'b000;
        retire_gpr_write_o = 3'b000;
        retire_rd_o = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        retire_result_data_o = {3*`RV64_XLEN{1'b0}};
        retire_fflags_valid_o = 3'b000;
        retire_fflags_o = 15'd0;
        retire_unsupported_o = 3'b000;
        retire_private_port_used = 1'b0;

        for (retire_result_lane = 0; retire_result_lane < 3;
             retire_result_lane = retire_result_lane + 1) begin
            retire_result_slot = retire_slot_i[
                retire_result_lane*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH];
            retire_entry_match = retire_valid_i[retire_result_lane] &&
                meta_valid_q[retire_result_slot] &&
                (id_q[retire_result_slot] == retire_id_i[
                    retire_result_lane*ID_WIDTH +: ID_WIDTH]);
            retire_entry_data_ready = 1'b1;
            if (retire_entry_match && fp_load_q[retire_result_slot])
                retire_entry_data_ready =
                    result_valid_q[retire_result_slot] ||
                    result_mem_fault_q[retire_result_slot];
            else if (retire_entry_match &&
                     !fp_store_q[retire_result_slot])
                retire_entry_data_ready = result_valid_q[retire_result_slot];
            if (retire_entry_match &&
                fp_reg_write_q[retire_result_slot] &&
                retire_private_port_used)
                retire_ready_o[retire_result_lane] = 1'b0;
            else if (retire_entry_match)
                retire_ready_o[retire_result_lane] =
                    retire_entry_data_ready;

            if (retire_entry_match &&
                retire_ready_o[retire_result_lane]) begin
                retire_result_valid_o[retire_result_lane] = 1'b1;
                retire_private_write_o[retire_result_lane] =
                    fp_reg_write_q[retire_result_slot];
                retire_gpr_write_o[retire_result_lane] =
                    int_reg_write_q[retire_result_slot];
                retire_rd_o[
                    retire_result_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] = rd_q[retire_result_slot];
                if (fp_load_q[retire_result_slot]) begin
                    retire_result_data_o[
                        retire_result_lane*`RV64_XLEN +: `RV64_XLEN] =
                        retire_load_data_o[
                            retire_result_lane*`RV64_XLEN +: `RV64_XLEN];
                end else if (!fp_store_q[retire_result_slot]) begin
                    retire_result_data_o[
                        retire_result_lane*`RV64_XLEN +: `RV64_XLEN] =
                        result_data_q[retire_result_slot];
                    retire_fflags_valid_o[retire_result_lane] =
                        fflags_write_q[retire_result_slot];
                    retire_fflags_o[retire_result_lane*5 +: 5] =
                        result_fflags_q[retire_result_slot];
                    retire_unsupported_o[retire_result_lane] =
                        result_unsupported_q[retire_result_slot];
                end
                if (fp_reg_write_q[retire_result_slot])
                    retire_private_port_used = 1'b1;
            end
        end
    end

    wire fp_load_assignment_identity_match =
        meta_valid_q[fp_load_assignment_slot_i] &&
        fp_load_q[fp_load_assignment_slot_i] &&
        (id_q[fp_load_assignment_slot_i] == fp_load_assignment_id_i) &&
        (!squash_i ||
         !id_is_younger(fp_load_assignment_id_i, squash_id_i));
    wire fp_load_assignment_format_match =
        ((fmt_q[fp_load_assignment_slot_i] == `RV64_FP_FMT_S) &&
         (fp_load_assignment_size_i ==
          {1'b0, `RV64_LSU_SIZE_WORD})) ||
        ((fmt_q[fp_load_assignment_slot_i] == `RV64_FP_FMT_D) &&
         (fp_load_assignment_size_i ==
          {1'b0, `RV64_LSU_SIZE_DWORD}));
    assign fp_load_assignment_match_o =
        fp_load_assignment_valid_i &&
        fp_load_assignment_identity_match &&
        (rd_q[fp_load_assignment_slot_i] == fp_load_assignment_rd_i) &&
        fp_load_assignment_format_match;

    assign fp_load_result_match_o =
        meta_valid_q[fp_load_result_slot_i] &&
        fp_load_q[fp_load_result_slot_i] &&
        (id_q[fp_load_result_slot_i] == fp_load_result_id_i) &&
        (!squash_i ||
         !id_is_younger(fp_load_result_id_i, squash_id_i));
    wire fp_load_result_assigned_now =
        fp_load_assignment_match_o &&
        (fp_load_assignment_id_i == fp_load_result_id_i) &&
        (fp_load_assignment_slot_i == fp_load_result_slot_i);
    wire fp_load_completion_live = fp_load_result_valid_i &&
        fp_load_result_match_o &&
        (load_assigned_q[fp_load_result_slot_i] ||
         fp_load_result_assigned_now) &&
        !result_valid_q[fp_load_result_slot_i];
    wire fp_mem_fault_is_load =
        meta_valid_q[fp_mem_fault_slot_i] &&
        fp_load_q[fp_mem_fault_slot_i];
    wire fp_mem_fault_assigned_now =
        fp_load_assignment_match_o &&
        (fp_load_assignment_id_i == fp_mem_fault_id_i) &&
        (fp_load_assignment_slot_i == fp_mem_fault_slot_i);
    wire fp_mem_fault_live = fp_mem_fault_valid_i &&
        meta_valid_q[fp_mem_fault_slot_i] &&
        (fp_load_q[fp_mem_fault_slot_i] ||
         fp_store_q[fp_mem_fault_slot_i]) &&
        (id_q[fp_mem_fault_slot_i] == fp_mem_fault_id_i) &&
        (!fp_mem_fault_is_load ||
         load_assigned_q[fp_mem_fault_slot_i] ||
         fp_mem_fault_assigned_now) &&
        (!squash_i ||
         !id_is_younger(fp_mem_fault_id_i, squash_id_i));

    integer result_seq_slot;
    integer result_seq_lane;
    reg [RETIRE_SLOT_WIDTH-1:0] result_update_slot;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (result_seq_slot = 0; result_seq_slot < WINDOW_DEPTH;
                 result_seq_slot = result_seq_slot + 1) begin
                result_valid_q[result_seq_slot] <= 1'b0;
                result_data_q[result_seq_slot] <= {`RV64_XLEN{1'b0}};
                result_fflags_q[result_seq_slot] <= 5'd0;
                result_unsupported_q[result_seq_slot] <= 1'b0;
                result_mem_fault_q[result_seq_slot] <= 1'b0;
                complete_pending_q[result_seq_slot] <= 1'b0;
                load_assigned_q[result_seq_slot] <= 1'b0;
            end
        end else if (flush_i) begin
            for (result_seq_slot = 0; result_seq_slot < WINDOW_DEPTH;
                 result_seq_slot = result_seq_slot + 1) begin
                result_valid_q[result_seq_slot] <= 1'b0;
                result_mem_fault_q[result_seq_slot] <= 1'b0;
                complete_pending_q[result_seq_slot] <= 1'b0;
                load_assigned_q[result_seq_slot] <= 1'b0;
            end
        end else begin
            if (squash_i) begin
                for (result_seq_slot = 0; result_seq_slot < WINDOW_DEPTH;
                     result_seq_slot = result_seq_slot + 1) begin
                    if (meta_valid_q[result_seq_slot] &&
                        id_is_younger(id_q[result_seq_slot], squash_id_i)) begin
                        result_valid_q[result_seq_slot] <= 1'b0;
                        result_mem_fault_q[result_seq_slot] <= 1'b0;
                        complete_pending_q[result_seq_slot] <= 1'b0;
                        load_assigned_q[result_seq_slot] <= 1'b0;
                    end
                end
            end

            if (completion_valid_o && completion_accept_i)
                complete_pending_q[completion_slot_index] <= 1'b0;

            for (result_seq_lane = 0; result_seq_lane < 3;
                 result_seq_lane = result_seq_lane + 1) begin
                result_update_slot = retire_slot_i[
                    result_seq_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
                if (retire_fire[result_seq_lane]) begin
                    result_valid_q[result_update_slot] <= 1'b0;
                    result_mem_fault_q[result_update_slot] <= 1'b0;
                    complete_pending_q[result_update_slot] <= 1'b0;
                    load_assigned_q[result_update_slot] <= 1'b0;
                end

                result_update_slot = allocation_slot_i[
                    result_seq_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
                if (allocation_valid_i[result_seq_lane]) begin
                    result_valid_q[result_update_slot] <= 1'b0;
                    result_mem_fault_q[result_update_slot] <= 1'b0;
                    complete_pending_q[result_update_slot] <= 1'b0;
                    load_assigned_q[result_update_slot] <= 1'b0;
                end
            end

            if (fp_load_assignment_match_o)
                load_assigned_q[fp_load_assignment_slot_i] <= 1'b1;

            if (fpu_result_capture) begin
                result_valid_q[fpu_result_slot_i] <= 1'b1;
                result_data_q[fpu_result_slot_i] <=
                    fpu_result_is_int_i ? fpu_result_int_i :
                    fpu_result_fp_i;
                result_fflags_q[fpu_result_slot_i] <=
                    fpu_result_fflags_i;
                result_unsupported_q[fpu_result_slot_i] <=
                    fpu_result_unsupported_i;
                complete_pending_q[fpu_result_slot_i] <= 1'b1;
            end

            if (fp_load_completion_live) begin
                result_valid_q[fp_load_result_slot_i] <= 1'b1;
                result_data_q[fp_load_result_slot_i] <=
                    fp_load_result_data_i;
                result_fflags_q[fp_load_result_slot_i] <= 5'd0;
                result_unsupported_q[fp_load_result_slot_i] <= 1'b0;
            end

            if (fp_mem_fault_live) begin
                result_mem_fault_q[fp_mem_fault_slot_i] <= 1'b1;
            end

        end
    end

    integer seq_entry_idx;
    integer seq_wake_lane;
    integer seq_owner_idx;
    integer seq_retire_lane;
    integer seq_admit_lane;
    reg seq_recover_retiring;
    reg [RETIRE_SLOT_WIDTH-1:0] update_slot;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner_valid_q <= 32'd0;
            for (seq_owner_idx = 0; seq_owner_idx < 32;
                 seq_owner_idx = seq_owner_idx + 1) begin
                owner_id_q[seq_owner_idx] <= {ID_WIDTH{1'b0}};
                owner_slot_q[seq_owner_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
            end
            for (seq_entry_idx = 0; seq_entry_idx < WINDOW_DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                meta_valid_q[seq_entry_idx] <= 1'b0;
                id_q[seq_entry_idx] <= {ID_WIDTH{1'b0}};
                src1_fp_q[seq_entry_idx] <= 1'b0;
                src2_fp_q[seq_entry_idx] <= 1'b0;
                src3_fp_q[seq_entry_idx] <= 1'b0;
                fp_reg_write_q[seq_entry_idx] <= 1'b0;
                int_reg_write_q[seq_entry_idx] <= 1'b0;
                fflags_write_q[seq_entry_idx] <= 1'b0;
                fp_load_q[seq_entry_idx] <= 1'b0;
                fp_store_q[seq_entry_idx] <= 1'b0;
                rs1_q[seq_entry_idx] <= {`RV64_REG_ADDR_WIDTH{1'b0}};
                rs2_q[seq_entry_idx] <= {`RV64_REG_ADDR_WIDTH{1'b0}};
                rs3_q[seq_entry_idx] <= {`RV64_REG_ADDR_WIDTH{1'b0}};
                rd_q[seq_entry_idx] <= {`RV64_REG_ADDR_WIDTH{1'b0}};
                op_q[seq_entry_idx] <= `OPENRV64_FP_OP_INVALID;
                fmt_q[seq_entry_idx] <= 2'd0;
                rm_q[seq_entry_idx] <= 3'd0;
                type_q[seq_entry_idx] <= 5'd0;
                branch_mask_q[seq_entry_idx] <=
                    {`OPENRV64_EXTENSION_BRANCH_COUNT{1'b0}};
                src1_ready_q[seq_entry_idx] <= 1'b1;
                src2_ready_q[seq_entry_idx] <= 1'b1;
                src3_ready_q[seq_entry_idx] <= 1'b1;
                src1_tag_q[seq_entry_idx] <= {ID_WIDTH{1'b0}};
                src2_tag_q[seq_entry_idx] <= {ID_WIDTH{1'b0}};
                src3_tag_q[seq_entry_idx] <= {ID_WIDTH{1'b0}};
                src1_slot_q[seq_entry_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                src2_slot_q[seq_entry_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                src3_slot_q[seq_entry_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                store_data_valid_q[seq_entry_idx] <= 1'b0;
                store_data_q[seq_entry_idx] <= {`RV64_XLEN{1'b0}};
            end
        end else if (flush_i) begin
            owner_valid_q <= 32'd0;
            for (seq_entry_idx = 0; seq_entry_idx < WINDOW_DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                meta_valid_q[seq_entry_idx] <= 1'b0;
                store_data_valid_q[seq_entry_idx] <= 1'b0;
            end
        end else if (squash_i) begin
            owner_valid_q <= survivor_owner_valid;
            for (seq_owner_idx = 0; seq_owner_idx < 32;
                 seq_owner_idx = seq_owner_idx + 1) begin
                owner_id_q[seq_owner_idx] <=
                    survivor_owner_id[seq_owner_idx];
                owner_slot_q[seq_owner_idx] <=
                    survivor_owner_slot[seq_owner_idx];
            end
            for (seq_entry_idx = 0; seq_entry_idx < WINDOW_DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                seq_recover_retiring = 1'b0;
                for (seq_wake_lane = 0; seq_wake_lane < 3;
                     seq_wake_lane = seq_wake_lane + 1) begin
                    if (retire_fire[seq_wake_lane] &&
                        (retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH] ==
                         id_q[seq_entry_idx]))
                        seq_recover_retiring = 1'b1;
                end
                if (meta_valid_q[seq_entry_idx] &&
                    (seq_recover_retiring ||
                     id_is_younger(id_q[seq_entry_idx], squash_id_i))) begin
                    meta_valid_q[seq_entry_idx] <= 1'b0;
                    store_data_valid_q[seq_entry_idx] <= 1'b0;
                end
                for (seq_wake_lane = 0; seq_wake_lane < 3;
                     seq_wake_lane = seq_wake_lane + 1) begin
                    if (retire_fire[seq_wake_lane] &&
                        !src1_ready_q[seq_entry_idx] &&
                        (src1_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src1_ready_q[seq_entry_idx] <= 1'b1;
                    if (retire_fire[seq_wake_lane] &&
                        !src2_ready_q[seq_entry_idx] &&
                        (src2_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src2_ready_q[seq_entry_idx] <= 1'b1;
                    if (retire_fire[seq_wake_lane] &&
                        !src3_ready_q[seq_entry_idx] &&
                        (src3_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src3_ready_q[seq_entry_idx] <= 1'b1;
                end
            end
        end else begin
            owner_valid_q <= owner_valid_view;
            for (seq_owner_idx = 0; seq_owner_idx < 32;
                 seq_owner_idx = seq_owner_idx + 1) begin
                owner_id_q[seq_owner_idx] <= owner_id_view[seq_owner_idx];
                owner_slot_q[seq_owner_idx] <=
                    owner_slot_view[seq_owner_idx];
            end

            for (seq_entry_idx = 0; seq_entry_idx < WINDOW_DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                for (seq_wake_lane = 0; seq_wake_lane < 3;
                     seq_wake_lane = seq_wake_lane + 1) begin
                    if (retire_fire[seq_wake_lane] &&
                        !src1_ready_q[seq_entry_idx] &&
                        (src1_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src1_ready_q[seq_entry_idx] <= 1'b1;
                    if (retire_fire[seq_wake_lane] &&
                        !src2_ready_q[seq_entry_idx] &&
                        (src2_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src2_ready_q[seq_entry_idx] <= 1'b1;
                    if (retire_fire[seq_wake_lane] &&
                        !src3_ready_q[seq_entry_idx] &&
                        (src3_tag_q[seq_entry_idx] == retire_id_i[
                            seq_wake_lane*ID_WIDTH +: ID_WIDTH]))
                        src3_ready_q[seq_entry_idx] <= 1'b1;
                end
            end

            for (seq_retire_lane = 0; seq_retire_lane < 3;
                 seq_retire_lane = seq_retire_lane + 1) begin
                update_slot = retire_slot_i[
                    seq_retire_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (retire_fire[seq_retire_lane] &&
                    meta_valid_q[update_slot] &&
                    (id_q[update_slot] == retire_id_i[
                        seq_retire_lane*ID_WIDTH +: ID_WIDTH])) begin
                    meta_valid_q[update_slot] <= 1'b0;
                    store_data_valid_q[update_slot] <= 1'b0;
                end
            end

            for (seq_admit_lane = 0; seq_admit_lane < 3;
                 seq_admit_lane = seq_admit_lane + 1) begin
                update_slot = allocation_slot_i[
                    seq_admit_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (allocation_valid_i[seq_admit_lane]) begin
                    meta_valid_q[update_slot] <= 1'b1;
                    store_data_valid_q[update_slot] <= 1'b0;
                    id_q[update_slot] <= allocation_id_i[
                        seq_admit_lane*ID_WIDTH +: ID_WIDTH];
                    src1_fp_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_SRC1_PRIVATE_BIT];
                    src2_fp_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_SRC2_PRIVATE_BIT];
                    src3_fp_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_SRC3_PRIVATE_BIT];
                    fp_reg_write_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT];
                    int_reg_write_q[update_slot] <= allocation_base_payload_i[
                        seq_admit_lane*BASE_WIDTH + 17];
                    fflags_write_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_STATE_WRITE_BIT];
                    fp_load_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_LOAD_BIT];
                    fp_store_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_STORE_BIT];
                    rs1_q[update_slot] <= allocation_base_payload_i[
                        seq_admit_lane*BASE_WIDTH + 237 +:
                        `RV64_REG_ADDR_WIDTH];
                    rs2_q[update_slot] <= allocation_base_payload_i[
                        seq_admit_lane*BASE_WIDTH + 232 +:
                        `RV64_REG_ADDR_WIDTH];
                    rs3_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_RS3_ADDR_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                    rd_q[update_slot] <= allocation_base_payload_i[
                        seq_admit_lane*BASE_WIDTH + 35 +:
                        `RV64_REG_ADDR_WIDTH];
                    op_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_OP_LSB +:
                        `OPENRV64_FP_OP_WIDTH];
                    fmt_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_FMT_LSB +: 2];
                    rm_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_RM_LSB +: 3];
                    type_q[update_slot] <= allocation_payload_i[
                        seq_admit_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_TYPE_LSB +: 5];
                    branch_mask_q[update_slot] <= allocation_branch_mask_i[
                        seq_admit_lane*`OPENRV64_EXTENSION_BRANCH_COUNT +:
                        `OPENRV64_EXTENSION_BRANCH_COUNT];
                    src1_ready_q[update_slot] <=
                        admit_src1_ready[seq_admit_lane];
                    src2_ready_q[update_slot] <=
                        admit_src2_ready[seq_admit_lane];
                    src3_ready_q[update_slot] <=
                        admit_src3_ready[seq_admit_lane];
                    src1_tag_q[update_slot] <=
                        admit_src1_tag[seq_admit_lane];
                    src2_tag_q[update_slot] <=
                        admit_src2_tag[seq_admit_lane];
                    src3_tag_q[update_slot] <=
                        admit_src3_tag[seq_admit_lane];
                    src1_slot_q[update_slot] <=
                        admit_src1_slot[seq_admit_lane];
                    src2_slot_q[update_slot] <=
                        admit_src2_slot[seq_admit_lane];
                    src3_slot_q[update_slot] <=
                        admit_src3_slot[seq_admit_lane];
                end
            end

            if (store_capture_selected) begin
                store_data_valid_q[store_capture_slot] <= 1'b1;
                store_data_q[store_capture_slot] <= store_capture_data;
            end
        end
    end

    assign fp_write_busy_o = owner_valid_q;

`ifndef SYNTHESIS
    initial begin
        if (WINDOW_DEPTH < 1)
            $fatal(1, "F/D dispatch window depth must be positive");
    end

    integer assert_lane;
    always @(posedge clk) begin
        if (rst_n && !flush_i) begin
            if (fpu_result_valid_i && fpu_result_live &&
                result_valid_q[fpu_result_slot_i])
                $fatal(1, "duplicate live FPU result for slot=%0d id=%0d",
                       fpu_result_slot_i, fpu_result_id_i);
            if (fpu_result_capture &&
                (fpu_result_is_int_i !=
                 int_reg_write_q[fpu_result_slot_i]))
                $fatal(1, "FPU result domain disagrees with decoded destination");
            if ((retire_accept_i & ~retire_ready_o) != 3'b000)
                $fatal(1, "parent retired an unready FPU sidecar entry");
            if (fp_load_assignment_valid_i &&
                fp_load_assignment_identity_match &&
                (rd_q[fp_load_assignment_slot_i] !=
                 fp_load_assignment_rd_i))
                $fatal(1,
                    "LSU load assignment destination mismatch slot=%0d id=%0d",
                    fp_load_assignment_slot_i,
                    fp_load_assignment_id_i);
            if (fp_load_assignment_valid_i &&
                fp_load_assignment_identity_match &&
                !fp_load_assignment_format_match)
                $fatal(1,
                    "LSU load assignment width mismatch slot=%0d id=%0d size=%0d fmt=%0d",
                    fp_load_assignment_slot_i,
                    fp_load_assignment_id_i,
                    fp_load_assignment_size_i,
                    fmt_q[fp_load_assignment_slot_i]);
            if (fp_load_assignment_match_o &&
                load_assigned_q[fp_load_assignment_slot_i])
                $fatal(1,
                    "duplicate LSU load assignment slot=%0d id=%0d",
                    fp_load_assignment_slot_i,
                    fp_load_assignment_id_i);
            if (fp_load_result_valid_i && fp_load_result_match_o &&
                !load_assigned_q[fp_load_result_slot_i] &&
                !fp_load_result_assigned_now)
                $fatal(1,
                    "FP load result arrived without LSU assignment slot=%0d id=%0d",
                    fp_load_result_slot_i, fp_load_result_id_i);
            if (fp_mem_fault_valid_i && fp_mem_fault_is_load &&
                (id_q[fp_mem_fault_slot_i] == fp_mem_fault_id_i) &&
                !load_assigned_q[fp_mem_fault_slot_i] &&
                !fp_mem_fault_assigned_now)
                $fatal(1,
                    "FP load fault arrived without LSU assignment slot=%0d id=%0d",
                    fp_mem_fault_slot_i, fp_mem_fault_id_i);
            for (assert_lane = 0; assert_lane < 3;
                 assert_lane = assert_lane + 1) begin
                if (allocation_valid_i[assert_lane] &&
                    allocation_payload_i[
                        assert_lane*PAYLOAD_WIDTH +
                        `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT] &&
                    allocation_base_payload_i[
                        assert_lane*BASE_WIDTH + 17])
                    $fatal(1, "FPU uop cannot write GPR and FPR together");
            end
        end
    end
`endif

endmodule

`endif
