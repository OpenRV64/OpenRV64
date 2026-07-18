`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// Complete three-pipe backend.  Decode supplies up to three static packets per
// cycle; the dispatch queue may burst three old packets to EX0, EX1, and MEM.
// Operands are captured at issue, results may complete out of order, and the
// retirement queue exposes only the maximal contiguous in-order prefix.
module openrv64_backend_3p #(
    parameter integer RETIRE_DEPTH = 8,
    parameter integer DISPATCH_DEPTH = 6,
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer ENABLE_RV64M = 1,
    parameter integer SLOT_WIDTH = $clog2(RETIRE_DEPTH),
    parameter integer RETIRE_COUNT_WIDTH = $clog2(RETIRE_DEPTH + 1),
    parameter integer DISPATCH_COUNT_WIDTH = $clog2(DISPATCH_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,
    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_write_addr_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,

    input  wire                         irq_pending_i,
    input  wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause_i,

    output wire                         redirect_valid_o,
    output wire [63:0]                  redirect_id_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,

    output wire [2:0]                   retire_arch_o,
    output wire [1:0]                   retire_count_o,
    output wire                         exception_o,
    output wire                         halt_o,
    output wire                         irq_o,
    output wire                         mret_o,
    output wire                         sret_o,
    output wire                         fence_i_o,
    output wire                         sfence_vma_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output wire [`RV64_XLEN-1:0]        retire_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_next_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_tval_o,
    output wire [63:0]                  retire_trace_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] retire_instr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_o,
    output wire [`RV64_XLEN-1:0]        retire_wdata_o,

    output wire [2:0]                   issue_valid_o,
    output wire [2:0]                   complete_valid_o,
    output wire [31:0]                  write_busy_o,
    output wire                         barrier_active_o,
    output wire [RETIRE_COUNT_WIDTH-1:0] retire_occupancy_o,
    output wire [DISPATCH_COUNT_WIDTH-1:0] dispatch_occupancy_o
);

    wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr;
    wire [6*`RV64_XLEN-1:0] gpr_read_data;
    wire [2:0] gpr_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] gpr_write_addr;
    wire [3*`RV64_XLEN-1:0] gpr_write_data;

    wire allocation_ready;
    wire queue_allocation_ready;
    wire [2:0] allocation_valid;
    wire [3*64-1:0] allocation_id;
    wire [3*SLOT_WIDTH-1:0] allocation_slot;
    wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0] allocation_meta;

    wire [2:0] pipe_ready;
    wire [2:0] pipe_valid;
    wire [3*64-1:0] pipe_id;
    wire [3*SLOT_WIDTH-1:0] pipe_slot;
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] pipe_payload;
    wire [2:0] pipe_unsupported;

    wire [2:0] complete_valid;
    wire [3*64-1:0] complete_id;
    wire [3*SLOT_WIDTH-1:0] complete_slot;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        complete_payload;

    wire [2:0] queue_retire_valid;
    wire [2:0] queue_retire_accept;
    wire [3*64-1:0] queue_retire_id;
    wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0] queue_retire_meta;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        queue_retire_result;
    wire [63:0] next_retire_id;
    wire [SLOT_WIDTH-1:0] next_retire_slot;

    wire [2:0] release_valid;
    wire [2:0] release_uses_rs1;
    wire [2:0] release_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs2_addr;
    wire [2:0] release_reg_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rd_addr;
    wire [2:0] retire_hard;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;

    // Dispatch receives only enough metadata to route a dependent instruction
    // back to the completing ALU pipe.  The 64-bit values stay local to EX0 and
    // EX1 and feed their operand muxes directly.
    wire [1:0] local_forward_valid;
    wire [2*`RV64_REG_ADDR_WIDTH-1:0] local_forward_rd_addr;
    assign local_forward_valid[0] = complete_valid[0] &&
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_valid[1] = complete_valid[1] &&
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_rd_addr[0*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];
    assign local_forward_rd_addr[1*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];

    // Deliberately conservative capacity gate: issue resumes with room for a
    // complete three-entry group.  This breaks the alloc-valid/ready loop and
    // leaves exact-width admission as a later timing optimization.
    assign allocation_ready = queue_allocation_ready &&
                              (retire_occupancy_o <= RETIRE_DEPTH - 3);

    openrv64_dispatch #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .QUEUE_DEPTH_3P(DISPATCH_DEPTH),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH),
        .MAX_READS_PER_REG_3P(MAX_READS_PER_REG)
    ) u_dispatch (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .decode_valid_i(1'b0), .decode_pc_i(64'd0),
        .decode_instr_i(32'd0), .decode_imm_i(64'd0),
        .decode_uses_rs1_i(1'b0), .decode_uses_rs2_i(1'b0),
        .decode_rs1_addr_i(5'd0), .decode_rs2_addr_i(5'd0),
        .decode_rd_addr_i(5'd0),
        .decode_alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .decode_alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .decode_lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .decode_br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .decode_reg_write_i(1'b0), .decode_mem_read_i(1'b0),
        .decode_mem_write_i(1'b0), .decode_branch_i(1'b0),
        .decode_jump_i(1'b0), .decode_predicted_taken_i(1'b0),
        .decode_word_op_i(1'b0), .decode_system_i(1'b0),
        .decode_fence_i(1'b0), .decode_illegal_i(1'b0),
        .decode_ebreak_i(1'b0), .decode_ecall_i(1'b0),
        .decode_instr_fault_i(1'b0),
        .decode_instr_page_fault_i(1'b0),
        .exec_clear_i(1'b0), .exec_alu_ready_i(1'b0),
        .exec_lsu_ready_i(1'b0), .exec_br_ready_i(1'b0),
        .exec_system_ready_i(1'b0), .forward_ex_valid_i(1'b0),
        .forward_ex_rd_addr_i(5'd0), .forward_mem_valid_i(1'b0),
        .forward_mem_rd_addr_i(5'd0),
        .retire_valid_i(1'b0), .retire_csr_i(1'b0),
        .retire_fence_i(1'b0), .retire_uses_rs1_i(1'b0),
        .retire_uses_rs2_i(1'b0), .retire_rs1_addr_i(5'd0),
        .retire_rs2_addr_i(5'd0), .retire_reg_write_i(1'b0),
        .retire_rd_addr_i(5'd0), .decode_trace_id_i(64'd0),
        .squash_frontend_3p_i(squash_frontend_i),
        .decode_valid_3p_i(decode_valid_i),
        .decode_ready_3p_o(decode_ready_o),
        .decode_payload_3p_i(decode_payload_i),
        .decode_uses_rs1_3p_i(decode_uses_rs1_i),
        .decode_uses_rs2_3p_i(decode_uses_rs2_i),
        .gpr_read_addr_3p_o(gpr_read_addr),
        .gpr_read_data_3p_i(gpr_read_data),
        .allocation_ready_3p_i(allocation_ready),
        .allocation_id_3p_i(allocation_id),
        .allocation_slot_3p_i(allocation_slot),
        .allocation_valid_3p_o(allocation_valid),
        .allocation_meta_3p_o(allocation_meta),
        .pipe_ready_3p_i(pipe_ready),
        .forward_valid_3p_i(local_forward_valid),
        .forward_rd_addr_3p_i(local_forward_rd_addr),
        .pipe_valid_3p_o(pipe_valid),
        .pipe_id_3p_o(pipe_id), .pipe_slot_3p_o(pipe_slot),
        .pipe_payload_3p_o(pipe_payload),
        .retire_valid_3p_i(release_valid),
        .retire_uses_rs1_3p_i(release_uses_rs1),
        .retire_uses_rs2_3p_i(release_uses_rs2),
        .retire_rs1_addr_3p_i(release_rs1_addr),
        .retire_rs2_addr_3p_i(release_rs2_addr),
        .retire_reg_write_3p_i(release_reg_write),
        .retire_rd_addr_3p_i(release_rd_addr),
        .retire_hard_3p_i(retire_hard),
        .barrier_active_3p_o(barrier_active_o),
        .raw_hazard_3p_o(raw_hazard), .waw_hazard_3p_o(waw_hazard),
        .read_port_hazard_3p_o(read_port_hazard),
        .write_busy_3p_o(write_busy_o),
        .queue_count_3p_o(dispatch_occupancy_o)
    );

    openrv64_rv64i_gpr_3p u_gpr (
        .clk(clk), .rst_n(rst_n),
        .read_addr_i(gpr_read_addr), .read_data_o(gpr_read_data),
        .write_valid_i(gpr_write), .write_addr_i(gpr_write_addr),
        .write_data_i(gpr_write_data)
    );

    // Order checks use the head after the retirement occurring on this edge.
    // The GPR bank has same-edge retirement bypass, so a dependent branch or
    // store sees the committed operand while issuing beside the older prefix.
    // If retirement drains the queue, the oldest dispatch candidate is the
    // prospective head, just as it is for an initially empty backend.
    wire [1:0] release_count =
        {1'b0, release_valid[0]} +
        {1'b0, release_valid[1]} +
        {1'b0, release_valid[2]};
    wire retire_entries_remain =
        retire_occupancy_o > {{(RETIRE_COUNT_WIDTH-2){1'b0}}, release_count};
    wire [63:0] post_retire_id = next_retire_id + release_count;
    wire [SLOT_WIDTH:0] post_retire_slot_sum =
        {1'b0, next_retire_slot} + release_count;
    wire [SLOT_WIDTH-1:0] post_retire_slot =
        (post_retire_slot_sum >= RETIRE_DEPTH) ?
        post_retire_slot_sum - RETIRE_DEPTH :
        post_retire_slot_sum[SLOT_WIDTH-1:0];
    wire ordered_head_valid = !flush_i &&
        (retire_entries_remain || (dispatch_occupancy_o != 0));
    wire [63:0] ordered_head_id = retire_entries_remain ?
        post_retire_id : allocation_id[0 +: 64];
    wire [SLOT_WIDTH-1:0] ordered_head_slot = retire_entries_remain ?
        post_retire_slot : allocation_slot[0 +: SLOT_WIDTH];

    openrv64_exec_top #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH), .ENABLE_RV64M(ENABLE_RV64M)
    ) u_exec (
        .clk(clk), .rst_n(rst_n), .flush_3p_i(flush_i),
        .valid_i(1'b0), .flush_ex_mem_i(1'b0),
        .flush_mem_wb_i(1'b0), .pc_i(64'd0), .instr_i(32'd0),
        .rs1_addr_i(5'd0), .rs2_addr_i(5'd0), .rs1_data_i(64'd0),
        .rs2_data_i(64'd0), .imm_i(64'd0), .rd_addr_i(5'd0),
        .alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .reg_write_i(1'b0), .mem_read_i(1'b0), .mem_write_i(1'b0),
        .branch_i(1'b0), .jump_i(1'b0), .predicted_taken_i(1'b0),
        .word_op_i(1'b0), .system_i(1'b0), .fence_i(1'b0),
        .illegal_i(1'b0), .ebreak_i(1'b0), .ecall_i(1'b0),
        .instr_access_fault_i(1'b0), .instr_page_fault_i(1'b0),
        .priv_mode_i({`RV64_PRIV_WIDTH{1'b0}}),
        .sret_allowed_i(1'b0), .sfence_vma_allowed_i(1'b0),
        .wb_clear_i(1'b0), .trace_id_i(64'd0),
        .issue_valid_3p_i(pipe_valid), .issue_ready_3p_o(pipe_ready),
        .issue_unsupported_3p_o(pipe_unsupported),
        .issue_id_3p_i(pipe_id), .issue_slot_3p_i(pipe_slot),
        .issue_payload_3p_i(pipe_payload),
        .ordered_head_valid_3p_i(ordered_head_valid),
        .ordered_head_id_3p_i(ordered_head_id),
        .ordered_head_slot_3p_i(ordered_head_slot),
        .complete_valid_3p_o(complete_valid),
        .complete_ready_3p_i(3'b111),
        .complete_id_3p_o(complete_id),
        .complete_slot_3p_o(complete_slot),
        .complete_payload_3p_o(complete_payload),
        .redirect_valid_o(redirect_valid_o),
        .redirect_id_3p_o(redirect_id_o),
        .redirect_target_o(redirect_target_o),
        .branch_resolved_o(branch_resolved_o),
        .branch_conditional_o(branch_conditional_o),
        .branch_taken_o(branch_taken_o),
        .csr_addr_o(csr_addr_o), .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i), .csr_writable_i(csr_writable_i),
        .mem_valid_o(mem_valid_o), .mem_ready_i(mem_ready_i),
        .mem_tag_o(mem_tag_o), .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_ready_o(mem_resp_ready_o),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_error_i(mem_error_i), .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(mem_access_allowed_i),
        .mem_write_o(mem_write_o), .mem_addr_o(mem_addr_o),
        .mem_wdata_o(mem_wdata_o), .mem_wstrb_o(mem_wstrb_o),
        .mem_access_o(mem_access_o),
        .mem_effective_addr_o(mem_effective_addr_o),
        .mem_size_o(mem_size_o), .mem_rdata_i(mem_rdata_i)
    );

    openrv64_retire_queue_3p #(
        .DEPTH(RETIRE_DEPTH), .ID_WIDTH(64),
        .META_WIDTH(`OPENRV64_RETIRE_META_WIDTH),
        .RESULT_WIDTH(`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH)
    ) u_retire_queue (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .alloc_valid_i(allocation_valid),
        .alloc_ready_o(queue_allocation_ready),
        .alloc_meta_i(allocation_meta), .alloc_id_o(allocation_id),
        .alloc_slot_o(allocation_slot),
        .complete_valid_i(complete_valid), .complete_id_i(complete_id),
        .complete_slot_i(complete_slot),
        .complete_result_i(complete_payload),
        .retire_valid_o(queue_retire_valid),
        .retire_accept_i(queue_retire_accept),
        .retire_id_o(queue_retire_id), .retire_meta_o(queue_retire_meta),
        .retire_result_o(queue_retire_result),
        .occupancy_o(retire_occupancy_o),
        .next_retire_id_o(next_retire_id),
        .next_retire_slot_o(next_retire_slot)
    );

    openrv64_retire_3p u_retire (
        .queue_valid_i(queue_retire_valid),
        .queue_meta_i(queue_retire_meta),
        .queue_result_i(queue_retire_result),
        .queue_accept_o(queue_retire_accept),
        .irq_pending_i(irq_pending_i), .irq_cause_i(irq_cause_i),
        .retire_arch_o(retire_arch_o), .retire_count_o(retire_count_o),
        .retire_hard_o(retire_hard),
        .release_valid_o(release_valid),
        .release_uses_rs1_o(release_uses_rs1),
        .release_uses_rs2_o(release_uses_rs2),
        .release_rs1_addr_o(release_rs1_addr),
        .release_rs2_addr_o(release_rs2_addr),
        .release_reg_write_o(release_reg_write),
        .release_rd_addr_o(release_rd_addr),
        .gpr_write_o(gpr_write), .gpr_rd_addr_o(gpr_write_addr),
        .gpr_rd_data_o(gpr_write_data),
        .csr_write_o(csr_write_o), .csr_addr_o(csr_write_addr_o),
        .csr_wdata_o(csr_wdata_o),
        .exception_o(exception_o), .halt_o(halt_o), .irq_o(irq_o),
        .mret_o(mret_o), .sret_o(sret_o), .fence_i_o(fence_i_o),
        .sfence_vma_o(sfence_vma_o), .cause_o(cause_o),
        .pc_o(retire_pc_o), .next_pc_o(retire_next_pc_o),
        .tval_o(retire_tval_o), .trace_id_o(retire_trace_id_o),
        .instr_o(retire_instr_o), .trace_rd_o(retire_rd_o),
        .trace_wdata_o(retire_wdata_o)
    );

    assign issue_valid_o = pipe_valid;
    assign complete_valid_o = complete_valid;

    wire unused_diagnostics = |{
        queue_retire_id, pipe_unsupported, raw_hazard, waw_hazard,
        read_port_hazard
    };

endmodule
