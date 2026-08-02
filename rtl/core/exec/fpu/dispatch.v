`ifndef OPENRV64_FD_DISPATCH_V
`define OPENRV64_FD_DISPATCH_V
`timescale 1ns/1ps

`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/exec/fpu/defs.v"

// F/D client of the generic extension scheduling contract.
//
// The parent window remains the only owner of program age, global issue
// eligibility, control recovery, memory ordering, and retirement slots.  This
// sidecar is indexed by those same slots and owns only F/D-specific state:
// FPR producer tags, retire-only FPR wakeup, FPU selection/backpressure, and
// the small LSU/FPR transfer buffer.
//
// No FPR value forwarding is performed.  A consumer waiting on an FPR producer
// becomes ready only when that exact producer retires.  Operand values are then
// read from the architectural FPR when the instruction is selected.
module openrv64_fd_dispatch #(
    parameter integer WINDOW_DEPTH = 16,
    parameter integer TRANSFER_DEPTH = 2,
    parameter integer RETIRE_SLOT_WIDTH = $clog2(WINDOW_DEPTH),
    parameter integer TRANSFER_COUNT_WIDTH = $clog2(TRANSFER_DEPTH + 1)
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
    input  wire [WINDOW_DEPTH*`RV64_XLEN-1:0] window_src1_data_i,
    input  wire [WINDOW_DEPTH*`RV64_XLEN-1:0] window_src2_data_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] next_retire_slot_i,

    output reg  [WINDOW_DEPTH-1:0]      entry_fp_valid_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_compute_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_load_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_fp_store_o,
    output reg  [WINDOW_DEPTH-1:0]      entry_operand_ready_o,
    output reg  [WINDOW_DEPTH*`RV64_XLEN-1:0] entry_mem_store_data_o,
    output wire                         fp_mem_load_ready_o,

    output reg  [3*`RV64_REG_ADDR_WIDTH-1:0] fpr_read_addr_o,
    input  wire [3*`RV64_XLEN-1:0]      fpr_read_data_i,

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

    // One FP memory operation is presented by the parent after its ordinary
    // memory-order selection.  Candidate-valid is independent of readiness;
    // fire records the coupled sidecar/LSU acceptance.  A load reserves
    // transfer capacity before LSU acceptance.  A store is ready only after
    // its FPR data has been captured.
    input  wire                         fp_mem_issue_valid_i,
    input  wire                         fp_mem_issue_fire_i,
    input  wire                         fp_mem_issue_is_load_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fp_mem_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fp_mem_issue_slot_i,
    output reg                          fp_mem_issue_ready_o,
    output reg  [`RV64_XLEN-1:0]        fp_mem_store_data_o,

    input  wire                         fp_load_result_valid_i,
    output wire                         fp_load_result_match_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fp_load_result_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fp_load_result_slot_i,
    input  wire [`RV64_XLEN-1:0]        fp_load_result_data_i,

    input  wire                         fp_mem_complete_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fp_mem_complete_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fp_mem_complete_slot_i,

    // Memory exceptions remain ordinary LSU/retirement exceptions.  The
    // sidecar needs only the matching identity so a faulting load does not
    // wait forever for transfer data that architecturally must not arrive.
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

    output wire [31:0]                  fp_write_busy_o,
    output wire [TRANSFER_COUNT_WIDTH-1:0] transfer_count_o
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

    reg [31:0] owner_valid_q;
    reg [ID_WIDTH-1:0] owner_id_q [0:31];

    // Sparse in use even though it shares the parent window's slot index:
    // result_valid_q and complete_pending_q are set only for F/D operations.
    // Integer retirement stores no F/D data.
    reg result_valid_q [0:WINDOW_DEPTH-1];
    reg [`RV64_XLEN-1:0] result_data_q [0:WINDOW_DEPTH-1];
    reg [4:0] result_fflags_q [0:WINDOW_DEPTH-1];
    reg result_unsupported_q [0:WINDOW_DEPTH-1];
    reg result_mem_fault_q [0:WINDOW_DEPTH-1];
    reg complete_pending_q [0:WINDOW_DEPTH-1];

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

    // Ordered admission view: retirement removes current owners first, then
    // later allocation lanes observe FPR writers from earlier lanes.
    reg [31:0] owner_valid_view;
    reg [ID_WIDTH-1:0] owner_id_view [0:31];
    reg admit_src1_ready [0:2];
    reg admit_src2_ready [0:2];
    reg admit_src3_ready [0:2];
    reg [ID_WIDTH-1:0] admit_src1_tag [0:2];
    reg [ID_WIDTH-1:0] admit_src2_tag [0:2];
    reg [ID_WIDTH-1:0] admit_src3_tag [0:2];
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
             view_owner_idx = view_owner_idx + 1)
            owner_id_view[view_owner_idx] = owner_id_q[view_owner_idx];

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

            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC1_PRIVATE_BIT] &&
                owner_valid_view[admit_rs1]) begin
                admit_src1_ready[view_admit_lane] = 1'b0;
                admit_src1_tag[view_admit_lane] = owner_id_view[admit_rs1];
            end
            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC2_PRIVATE_BIT] &&
                owner_valid_view[admit_rs2]) begin
                admit_src2_ready[view_admit_lane] = 1'b0;
                admit_src2_tag[view_admit_lane] = owner_id_view[admit_rs2];
            end
            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][`OPENRV64_FPU_USES_SRC3_BIT] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_SRC3_PRIVATE_BIT] &&
                owner_valid_view[admit_rs3]) begin
                admit_src3_ready[view_admit_lane] = 1'b0;
                admit_src3_tag[view_admit_lane] = owner_id_view[admit_rs3];
            end

            if (allocation_valid_i[view_admit_lane] &&
                admit_payload[view_admit_lane][
                    `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT]) begin
                owner_valid_view[admit_rd] = 1'b1;
                owner_id_view[admit_rd] = admit_id;
            end
        end
    end

    // Rebuild the youngest surviving FPR owner after selective recovery.
    reg [31:0] survivor_owner_valid;
    reg [ID_WIDTH-1:0] survivor_owner_id [0:31];
    reg survivor_retiring;
    integer survivor_idx;
    integer survivor_lane;
    integer survivor_owner_idx;
    always_comb begin
        survivor_owner_valid = 32'd0;
        for (survivor_owner_idx = 0; survivor_owner_idx < 32;
             survivor_owner_idx = survivor_owner_idx + 1)
            survivor_owner_id[survivor_owner_idx] = {ID_WIDTH{1'b0}};
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
            end
        end
    end

    // Two-entry transfer buffer by default.  The flattened state is used for
    // associative matching against window entries and retirement lanes.
    wire transfer_reserve_ready;
    reg transfer_reserve_valid;
    reg transfer_reserve_is_load;
    reg [ID_WIDTH-1:0] transfer_reserve_id;
    reg [RETIRE_SLOT_WIDTH-1:0] transfer_reserve_slot;
    reg [`RV64_XLEN-1:0] transfer_reserve_data;
    reg [3:0] transfer_consume_valid;
    reg [4*ID_WIDTH-1:0] transfer_consume_id;
    reg [4*RETIRE_SLOT_WIDTH-1:0] transfer_consume_slot;
    wire [TRANSFER_DEPTH-1:0] transfer_valid;
    wire [TRANSFER_DEPTH-1:0] transfer_is_load;
    wire [TRANSFER_DEPTH-1:0] transfer_data_valid;
    wire [TRANSFER_DEPTH*ID_WIDTH-1:0] transfer_id;
    wire [TRANSFER_DEPTH*RETIRE_SLOT_WIDTH-1:0] transfer_slot;
    wire [TRANSFER_DEPTH*`RV64_XLEN-1:0] transfer_data;

    openrv64_fd_transfer_buffer #(
        .DEPTH(TRANSFER_DEPTH),
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .COUNT_WIDTH(TRANSFER_COUNT_WIDTH)
    ) u_transfer (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .squash_i(squash_i), .squash_id_i(squash_id_i),
        .reserve_valid_i(transfer_reserve_valid),
        .reserve_ready_o(transfer_reserve_ready),
        .reserve_is_load_i(transfer_reserve_is_load),
        .reserve_id_i(transfer_reserve_id),
        .reserve_slot_i(transfer_reserve_slot),
        .reserve_data_i(transfer_reserve_data),
        .fill_valid_i(fp_load_result_valid_i),
        .fill_match_o(fp_load_result_match_o),
        .fill_id_i(fp_load_result_id_i),
        .fill_slot_i(fp_load_result_slot_i),
        .fill_data_i(fp_load_result_data_i),
        .consume_valid_i(transfer_consume_valid),
        .consume_id_i(transfer_consume_id),
        .consume_slot_i(transfer_consume_slot),
        .entry_valid_o(transfer_valid),
        .entry_is_load_o(transfer_is_load),
        .entry_data_valid_o(transfer_data_valid),
        .entry_id_o(transfer_id),
        .entry_slot_o(transfer_slot),
        .entry_data_o(transfer_data),
        .count_o(transfer_count_o)
    );

`ifndef SYNTHESIS
    // Simulation-only dependency attribution.  A blocked operand is
    // "forwardable" only when every currently blocked FPR source already has
    // an exact-tag value resident in the sidecar result bank or load-transfer
    // buffer.  Such an instruction could issue under a bypass policy without
    // changing architectural retirement.  A pending count instead means at
    // least one producer value does not exist yet, so forwarding alone cannot
    // make that entry issue in the current cycle.
    localparam integer TRACE_COUNT_WIDTH = $clog2(WINDOW_DEPTH + 1);

    function automatic trace_producer_value_available;
        input [ID_WIDTH-1:0] producer_id;
        integer trace_producer_slot;
        integer trace_transfer_idx;
        begin
            trace_producer_value_available = 1'b0;
            for (trace_producer_slot = 0;
                 trace_producer_slot < WINDOW_DEPTH;
                 trace_producer_slot = trace_producer_slot + 1) begin
                if (meta_valid_q[trace_producer_slot] &&
                    (id_q[trace_producer_slot] == producer_id)) begin
                    if (!fp_load_q[trace_producer_slot] &&
                        !fp_store_q[trace_producer_slot] &&
                        result_valid_q[trace_producer_slot])
                        trace_producer_value_available = 1'b1;
                    if (fp_load_q[trace_producer_slot]) begin
                        for (trace_transfer_idx = 0;
                             trace_transfer_idx < TRANSFER_DEPTH;
                             trace_transfer_idx = trace_transfer_idx + 1) begin
                            if (transfer_valid[trace_transfer_idx] &&
                                transfer_is_load[trace_transfer_idx] &&
                                transfer_data_valid[trace_transfer_idx] &&
                                (transfer_id[
                                    trace_transfer_idx*ID_WIDTH +:
                                    ID_WIDTH] == producer_id) &&
                                (transfer_slot[
                                    trace_transfer_idx*RETIRE_SLOT_WIDTH +:
                                    RETIRE_SLOT_WIDTH] ==
                                 trace_producer_slot[
                                    RETIRE_SLOT_WIDTH-1:0]))
                                trace_producer_value_available = 1'b1;
                        end
                    end
                end
            end
            if (fpu_result_valid_i &&
                (fpu_result_id_i == producer_id))
                trace_producer_value_available = 1'b1;
            if (fp_load_result_valid_i &&
                (fp_load_result_id_i == producer_id))
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
                                src1_tag_q[trace_dependency_slot]);
                        if (!trace_source_available)
                            trace_all_blocked_sources_available = 1'b0;
                    end
                    if (src2_fp_q[trace_dependency_slot] &&
                        !src2_ready_q[trace_dependency_slot]) begin
                        trace_has_blocked_source = 1'b1;
                        trace_source_available =
                            trace_producer_value_available(
                                src2_tag_q[trace_dependency_slot]);
                        if (!trace_source_available)
                            trace_all_blocked_sources_available = 1'b0;
                    end
                    if (src3_fp_q[trace_dependency_slot] &&
                        !src3_ready_q[trace_dependency_slot]) begin
                        trace_has_blocked_source = 1'b1;
                        trace_source_available =
                            trace_producer_value_available(
                                src3_tag_q[trace_dependency_slot]);
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
                        src2_tag_q[trace_dependency_slot]))
                    trace_store_source_forwardable_count =
                        trace_store_source_forwardable_count + 1'b1;
            end
        end
    end
`endif

    reg store_transfer_ready [0:WINDOW_DEPTH-1];
    integer ready_slot;
    integer transfer_idx;
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
            store_transfer_ready[ready_slot] = 1'b0;
            for (transfer_idx = 0; transfer_idx < TRANSFER_DEPTH;
                 transfer_idx = transfer_idx + 1) begin
                if (transfer_valid[transfer_idx] &&
                    (transfer_id[transfer_idx*ID_WIDTH +: ID_WIDTH] ==
                     id_q[ready_slot]) &&
                    (transfer_slot[
                        transfer_idx*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH] ==
                     ready_slot[RETIRE_SLOT_WIDTH-1:0])) begin
                    if (!transfer_is_load[transfer_idx] &&
                        transfer_data_valid[transfer_idx]) begin
                        store_transfer_ready[ready_slot] = 1'b1;
                        entry_mem_store_data_o[
                            ready_slot*`RV64_XLEN +: `RV64_XLEN] =
                            transfer_data[
                                transfer_idx*`RV64_XLEN +: `RV64_XLEN];
                    end
                end
            end
            entry_fp_valid_o[ready_slot] = meta_valid_q[ready_slot];
            entry_fp_compute_o[ready_slot] =
                is_fp_compute_slot(ready_slot);
            entry_fp_load_o[ready_slot] =
                meta_valid_q[ready_slot] && fp_load_q[ready_slot];
            entry_fp_store_o[ready_slot] =
                meta_valid_q[ready_slot] && fp_store_q[ready_slot];
            if (meta_valid_q[ready_slot]) begin
                entry_operand_ready_o[ready_slot] =
                    (!src1_fp_q[ready_slot] || src1_ready_q[ready_slot]) &&
                    (!src2_fp_q[ready_slot] || src2_ready_q[ready_slot]) &&
                    (!src3_fp_q[ready_slot] || src3_ready_q[ready_slot]);
                if (fp_store_q[ready_slot])
                    entry_operand_ready_o[ready_slot] =
                        entry_operand_ready_o[ready_slot] &&
                        store_transfer_ready[ready_slot];
            end
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
    // read data must not appear in the select process: the real combinational
    // FPR is addressed from the selected slot, and merging these two concerns
    // creates a false read-address/data feedback loop during elaboration.
    always_comb begin
        fpu_valid_o = fpu_selected;
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
            fpu_src1_o = src1_fp_q[fpu_slot_index] ?
                fpr_read_data_i[0*`RV64_XLEN +: `RV64_XLEN] :
                window_src1_data_i[
                    fpu_slot_index*`RV64_XLEN +: `RV64_XLEN];
            fpu_src2_o = src2_fp_q[fpu_slot_index] ?
                fpr_read_data_i[1*`RV64_XLEN +: `RV64_XLEN] :
                window_src2_data_i[
                    fpu_slot_index*`RV64_XLEN +: `RV64_XLEN];
            fpu_src3_o = src3_fp_q[fpu_slot_index] ?
                fpr_read_data_i[2*`RV64_XLEN +: `RV64_XLEN] :
                {`RV64_XLEN{1'b0}};
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

    // Capture one store source opportunistically when the FPU is not using
    // the three-read FPR port.  Loads presented by the parent receive reserve
    // priority, preventing a speculative store capture from consuming the
    // final transfer entry needed by an already-selected load.
    reg store_capture_selected;
    integer store_capture_slot;
    integer store_select_offset;
    integer store_select_slot;
    always_comb begin
        store_capture_selected = 1'b0;
        store_capture_slot = 0;
        for (store_select_offset = 0; store_select_offset < WINDOW_DEPTH;
             store_select_offset = store_select_offset + 1) begin
            store_select_slot =
                {{(32-RETIRE_SLOT_WIDTH){1'b0}}, next_retire_slot_i};
            store_select_slot = store_select_slot + store_select_offset;
            if (store_select_slot >= WINDOW_DEPTH)
                store_select_slot = store_select_slot - WINDOW_DEPTH;
            if (!store_capture_selected && meta_valid_q[store_select_slot] &&
                fp_store_q[store_select_slot] &&
                !window_issued_i[store_select_slot] &&
                src2_ready_q[store_select_slot] &&
                !store_transfer_ready[store_select_slot]) begin
                store_capture_selected = 1'b1;
                store_capture_slot = store_select_slot;
            end
        end

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
        end else if (store_capture_selected) begin
            fpr_read_addr_o[1*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = rs2_q[store_capture_slot];
        end
    end

    integer mem_lookup_idx;
    reg mem_store_match;
    always_comb begin
        mem_store_match = 1'b0;
        fp_mem_store_data_o = {`RV64_XLEN{1'b0}};
        for (mem_lookup_idx = 0; mem_lookup_idx < TRANSFER_DEPTH;
             mem_lookup_idx = mem_lookup_idx + 1) begin
            if (!mem_store_match && transfer_valid[mem_lookup_idx] &&
                !transfer_is_load[mem_lookup_idx] &&
                transfer_data_valid[mem_lookup_idx] &&
                (transfer_id[mem_lookup_idx*ID_WIDTH +: ID_WIDTH] ==
                 fp_mem_issue_id_i) &&
                (transfer_slot[
                    mem_lookup_idx*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH] == fp_mem_issue_slot_i)) begin
                mem_store_match = 1'b1;
                fp_mem_store_data_o = transfer_data[
                    mem_lookup_idx*`RV64_XLEN +: `RV64_XLEN];
            end
        end
    end

    always_comb begin
        fp_mem_issue_ready_o = fp_mem_issue_is_load_i ?
                               transfer_reserve_ready : mem_store_match;
    end
    assign fp_mem_load_ready_o = transfer_reserve_ready;

    integer mem_consume_retire_lane;
    always_comb begin
        transfer_consume_valid = 4'b0000;
        transfer_consume_id = {4*ID_WIDTH{1'b0}};
        transfer_consume_slot = {4*RETIRE_SLOT_WIDTH{1'b0}};
        for (mem_consume_retire_lane = 0; mem_consume_retire_lane < 3;
             mem_consume_retire_lane = mem_consume_retire_lane + 1) begin
            transfer_consume_valid[mem_consume_retire_lane] =
                retire_fire[mem_consume_retire_lane];
            transfer_consume_id[
                mem_consume_retire_lane*ID_WIDTH +: ID_WIDTH] =
                retire_id_i[mem_consume_retire_lane*ID_WIDTH +: ID_WIDTH];
            transfer_consume_slot[
                mem_consume_retire_lane*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] =
                retire_slot_i[
                    mem_consume_retire_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
        end
        transfer_consume_valid[3] = fp_mem_issue_fire_i &&
                                    !fp_mem_issue_is_load_i &&
                                    fp_mem_issue_ready_o;
        transfer_consume_id[3*ID_WIDTH +: ID_WIDTH] = fp_mem_issue_id_i;
        transfer_consume_slot[
            3*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] = fp_mem_issue_slot_i;
    end

    always_comb begin
        transfer_reserve_valid = 1'b0;
        transfer_reserve_is_load = 1'b0;
        transfer_reserve_id = {ID_WIDTH{1'b0}};
        transfer_reserve_slot = {RETIRE_SLOT_WIDTH{1'b0}};
        transfer_reserve_data = {`RV64_XLEN{1'b0}};
        if (fp_mem_issue_valid_i && fp_mem_issue_is_load_i) begin
            // Drive the candidate identity even before acceptance so the
            // registered-capacity/duplicate readiness query cannot depend on
            // fire.  Only fire mutates the transfer buffer.
            transfer_reserve_valid = fp_mem_issue_fire_i;
            transfer_reserve_is_load = 1'b1;
            transfer_reserve_id = fp_mem_issue_id_i;
            transfer_reserve_slot = fp_mem_issue_slot_i;
        end else if (!fpu_selected && store_capture_selected) begin
            transfer_reserve_valid = 1'b1;
            transfer_reserve_is_load = 1'b0;
            transfer_reserve_id = id_q[store_capture_slot];
            transfer_reserve_slot =
                store_capture_slot[RETIRE_SLOT_WIDTH-1:0];
            transfer_reserve_data = fpr_read_data_i[
                1*`RV64_XLEN +: `RV64_XLEN];
        end
    end

    // Load data is visible to ordered retirement only after a matching LSU
    // fill.  Arithmetic results remain in the FPU-owned result bank above.
    integer retire_lookup_lane;
    integer retire_transfer_idx;
    always_comb begin
        retire_load_data_valid_o = 3'b000;
        retire_load_data_o = {3*`RV64_XLEN{1'b0}};
        for (retire_lookup_lane = 0; retire_lookup_lane < 3;
             retire_lookup_lane = retire_lookup_lane + 1) begin
            for (retire_transfer_idx = 0;
                 retire_transfer_idx < TRANSFER_DEPTH;
                 retire_transfer_idx = retire_transfer_idx + 1) begin
                if (!retire_load_data_valid_o[retire_lookup_lane] &&
                    retire_valid_i[retire_lookup_lane] &&
                    transfer_valid[retire_transfer_idx] &&
                    transfer_is_load[retire_transfer_idx] &&
                    transfer_data_valid[retire_transfer_idx] &&
                    (transfer_id[
                        retire_transfer_idx*ID_WIDTH +: ID_WIDTH] ==
                     retire_id_i[
                        retire_lookup_lane*ID_WIDTH +: ID_WIDTH]) &&
                    (transfer_slot[
                        retire_transfer_idx*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH] == retire_slot_i[
                        retire_lookup_lane*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH])) begin
                    retire_load_data_valid_o[retire_lookup_lane] = 1'b1;
                    retire_load_data_o[
                        retire_lookup_lane*`RV64_XLEN +: `RV64_XLEN] =
                        transfer_data[
                            retire_transfer_idx*`RV64_XLEN +: `RV64_XLEN];
                end
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
                    retire_load_data_valid_o[retire_result_lane] ||
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

    wire fp_load_completion_live = fp_load_result_valid_i &&
        fp_load_result_match_o &&
        meta_valid_q[fp_load_result_slot_i] &&
        fp_load_q[fp_load_result_slot_i] &&
        (id_q[fp_load_result_slot_i] == fp_load_result_id_i);
    wire fp_store_completion_live = fp_mem_complete_valid_i &&
        meta_valid_q[fp_mem_complete_slot_i] &&
        fp_store_q[fp_mem_complete_slot_i] &&
        (id_q[fp_mem_complete_slot_i] == fp_mem_complete_id_i) &&
        (!squash_i ||
         !id_is_younger(fp_mem_complete_id_i, squash_id_i));
    wire fp_mem_fault_live = fp_mem_fault_valid_i &&
        meta_valid_q[fp_mem_fault_slot_i] &&
        (fp_load_q[fp_mem_fault_slot_i] ||
         fp_store_q[fp_mem_fault_slot_i]) &&
        (id_q[fp_mem_fault_slot_i] == fp_mem_fault_id_i) &&
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
            end
        end else if (flush_i) begin
            for (result_seq_slot = 0; result_seq_slot < WINDOW_DEPTH;
                 result_seq_slot = result_seq_slot + 1) begin
                result_valid_q[result_seq_slot] <= 1'b0;
                result_mem_fault_q[result_seq_slot] <= 1'b0;
                complete_pending_q[result_seq_slot] <= 1'b0;
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
                end

                result_update_slot = allocation_slot_i[
                    result_seq_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
                if (allocation_valid_i[result_seq_lane]) begin
                    result_valid_q[result_update_slot] <= 1'b0;
                    result_mem_fault_q[result_update_slot] <= 1'b0;
                    complete_pending_q[result_update_slot] <= 1'b0;
                end
            end

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

            if (fp_load_completion_live)
                complete_pending_q[fp_load_result_slot_i] <= 1'b1;

            if (fp_store_completion_live)
                complete_pending_q[fp_mem_complete_slot_i] <= 1'b1;

            if (fp_mem_fault_live) begin
                result_mem_fault_q[fp_mem_fault_slot_i] <= 1'b1;
                complete_pending_q[fp_mem_fault_slot_i] <= 1'b1;
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
                 seq_owner_idx = seq_owner_idx + 1)
                owner_id_q[seq_owner_idx] <= {ID_WIDTH{1'b0}};
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
            end
        end else if (flush_i) begin
            owner_valid_q <= 32'd0;
            for (seq_entry_idx = 0; seq_entry_idx < WINDOW_DEPTH;
                 seq_entry_idx = seq_entry_idx + 1)
                meta_valid_q[seq_entry_idx] <= 1'b0;
        end else if (squash_i) begin
            owner_valid_q <= survivor_owner_valid;
            for (seq_owner_idx = 0; seq_owner_idx < 32;
                 seq_owner_idx = seq_owner_idx + 1)
                owner_id_q[seq_owner_idx] <=
                    survivor_owner_id[seq_owner_idx];
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
                     id_is_younger(id_q[seq_entry_idx], squash_id_i)))
                    meta_valid_q[seq_entry_idx] <= 1'b0;
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
                 seq_owner_idx = seq_owner_idx + 1)
                owner_id_q[seq_owner_idx] <= owner_id_view[seq_owner_idx];

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
                        seq_retire_lane*ID_WIDTH +: ID_WIDTH]))
                    meta_valid_q[update_slot] <= 1'b0;
            end

            for (seq_admit_lane = 0; seq_admit_lane < 3;
                 seq_admit_lane = seq_admit_lane + 1) begin
                update_slot = allocation_slot_i[
                    seq_admit_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (allocation_valid_i[seq_admit_lane]) begin
                    meta_valid_q[update_slot] <= 1'b1;
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
                end
            end
        end
    end

    assign fp_write_busy_o = owner_valid_q;

`ifndef SYNTHESIS
    initial begin
        if (WINDOW_DEPTH < 1)
            $fatal(1, "F/D dispatch window depth must be positive");
        if (TRANSFER_DEPTH < 1)
            $fatal(1, "F/D transfer depth must be positive");
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
