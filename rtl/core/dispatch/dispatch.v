`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_dispatch #(
    parameter [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter REGISTERED = 1,
    parameter ENABLE_FORWARDING = 0,
    parameter DECODE_STAGE_1P = 0,
    parameter integer QUEUE_DEPTH_3P = 6,
    parameter integer RETIRE_SLOT_WIDTH_3P = 3,
    parameter integer MAX_READS_PER_REG_3P = 2,
    parameter integer RELAX_WAW_3P = 1,
    parameter integer RELAX_HAZARDS_3P = 0,
    parameter integer MAX_ISSUE_LANES_3P = 3,
    parameter integer FREE_BRANCHES_3P = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING_3P = 1,
    parameter integer DEFER_EQ_BRANCH_PAIRING_3P = 0,
    parameter integer ENABLE_ISSUE_WINDOW_3P = 0,
    parameter integer ENABLE_SPECULATION_WINDOW_3P = 0,
    parameter integer DEFER_WINDOW_GPR_READ_3P = 0,
    parameter integer MAX_WINDOW_ISSUE_LANES_3P = 4,
    parameter integer ISSUE_WINDOW_DEPTH_3P = 16,
    parameter integer RENAME_MODE_3P = 0,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE_3P =
        {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE_3P =
        {`RV64_XLEN{1'b0}},
    parameter integer PHYS_REG_COUNT_3P = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH_3P =
        (PHYS_REG_COUNT_3P < 1) ? 1 :
        $clog2(PHYS_REG_COUNT_3P + 1),
    parameter integer RETIRE_META_WIDTH_3P =
        `OPENRV64_DISPATCH_META_WIDTH + 2*PHYS_REG_ADDR_WIDTH_3P,
    parameter integer COUNT_WIDTH_3P = $clog2(QUEUE_DEPTH_3P + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         scoreboard_clear_1p_i,

    input  wire                         decode_valid_i,
    output wire                         decode_clear_o,
    input  wire [`RV64_XLEN-1:0]        decode_pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] decode_instr_i,
    input  wire [`RV64_XLEN-1:0]        decode_imm_i,
    input  wire                         decode_uses_rs1_i,
    input  wire                         decode_uses_rs2_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs2_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rd_addr_i,
    input  wire [`RV64_ALU_EXT_WIDTH-1:0] decode_alu_ext_i,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] decode_alu_op_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] decode_lsu_op_i,
    input  wire [`RV64_BR_OP_WIDTH-1:0]  decode_br_op_i,
    input  wire                         decode_reg_write_i,
    input  wire                         decode_mem_read_i,
    input  wire                         decode_mem_write_i,
    input  wire                         decode_branch_i,
    input  wire                         decode_jump_i,
    input  wire                         decode_predicted_taken_i,
    input  wire                         decode_word_op_i,
    input  wire                         decode_system_i,
    input  wire                         decode_fence_i,
    input  wire                         decode_illegal_i,
    input  wire                         decode_ebreak_i,
    input  wire                         decode_ecall_i,
    input  wire                         decode_instr_fault_i,
    input  wire                         decode_instr_page_fault_i,

    output wire                         exec_valid_o,
    input  wire                         exec_clear_i,
    input  wire                         exec_alu_ready_i,
    input  wire                         exec_lsu_ready_i,
    input  wire                         exec_br_ready_i,
    input  wire                         exec_system_ready_i,
    input  wire                         forward_ex_valid_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] forward_ex_rd_addr_i,
    input  wire                         forward_mem_valid_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] forward_mem_rd_addr_i,
    output wire [`RV64_XLEN-1:0]        exec_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] exec_instr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] exec_rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] exec_rs2_addr_o,
    output wire [`RV64_XLEN-1:0]        exec_imm_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] exec_rd_addr_o,
    output wire [`RV64_ALU_EXT_WIDTH-1:0] exec_alu_ext_o,
    output wire [`RV64_ALU_OP_WIDTH-1:0] exec_alu_op_o,
    output wire [`RV64_LSU_OP_WIDTH-1:0] exec_lsu_op_o,
    output wire [`RV64_BR_OP_WIDTH-1:0]  exec_br_op_o,
    output wire                         exec_reg_write_o,
    output wire                         exec_mem_read_o,
    output wire                         exec_mem_write_o,
    output wire                         exec_branch_o,
    output wire                         exec_jump_o,
    output wire                         exec_predicted_taken_o,
    output wire                         exec_word_op_o,
    output wire                         exec_system_o,
    output wire                         exec_fence_o,
    output wire                         exec_illegal_o,
    output wire                         exec_ebreak_o,
    output wire                         exec_ecall_o,
    output wire                         exec_instr_fault_o,
    output wire                         exec_instr_page_fault_o,

    input  wire                         retire_valid_i,
    input  wire                         retire_csr_i,
    input  wire                         retire_fence_i,
    input  wire                         retire_uses_rs1_i,
    input  wire                         retire_uses_rs2_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_i,
    input  wire                         retire_reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_i,

    output wire                         raw_hazard_o,
    output wire                         waw_hazard_o,
    output wire                         scoreboard_stall_o,

    input  wire [63:0]                  decode_trace_id_i,
    output wire [63:0]                  exec_trace_id_o,

    // Three-pipe interface.  The selector intentionally carries a superset
    // of the 1P and 3P contracts because operand capture, queue allocation,
    // and completion identity do not fit the old scalar port list.
    input  wire                         squash_frontend_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_3p_i,
    input  wire [RETIRE_SLOT_WIDTH_3P-1:0] squash_slot_3p_i,
    input  wire                         translation_bypass_3p_i,
    input  wire [2:0]                   decode_valid_3p_i,
    output wire [2:0]                   decode_ready_3p_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_3p_i,
    input  wire [2:0]                   decode_uses_rs1_3p_i,
    input  wire [2:0]                   decode_uses_rs2_3p_i,
    output wire [6*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        gpr_read_addr_3p_o,
    output wire [5:0]                   gpr_read_ready_3p_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_3p_i,
    input  wire [5:0]                   candidate_operand_ready_3p_i,
    input  wire [2:0]                   candidate_address_ready_3p_i,
    input  wire                         allocation_ready_3p_i,
    input  wire [1:0]                   rename_free_valid_3p_i,
    input  wire [2*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        rename_free_tag_3p_i,
    input  wire [2:0]                   rename_write_valid_3p_i,
    input  wire [3*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        rename_write_tag_3p_i,
    input  wire [2:0]                   rename_commit_valid_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0]
                                        rename_commit_arch_3p_i,
    input  wire [3*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        rename_commit_phys_3p_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_3p_i,
    input  wire [3*RETIRE_SLOT_WIDTH_3P-1:0] allocation_slot_3p_i,
    output wire [2:0]                   allocation_valid_3p_o,
    output wire [3*RETIRE_META_WIDTH_3P-1:0] allocation_meta_3p_o,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_3p_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_candidate_valid_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*2-1:0]
                                        pipe_age_rank_3p_o,
    input  wire [1:0]                   forward_valid_3p_i,
    input  wire [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr_3p_i,
    input  wire [2:0]                   completion_forward_valid_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0]
                                        completion_forward_rd_addr_3p_i,
    input  wire [3*`RV64_XLEN-1:0]      completion_forward_data_3p_i,
    input  wire [2:0]                   branch_completion_forward_valid_3p_i,
    input  wire [31:0]                  forward_map_valid_3p_i,
    input  wire [32*`RV64_XLEN-1:0]     forward_map_data_3p_i,
    input  wire [2:0]                   completion_valid_3p_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_3p_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        completion_payload_3p_i,
    input  wire                         conditional_resolve_valid_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        conditional_resolve_id_3p_i,
    input  wire [RETIRE_SLOT_WIDTH_3P-1:0]
                                        conditional_resolve_slot_3p_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P-1:0]
                                        pipe_slot_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_uses_rs1_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_uses_rs2_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src1_producer_valid_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src1_producer_id_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src2_producer_valid_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src2_producer_id_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        pipe_src1_phys_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        pipe_src2_phys_3p_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        pipe_destination_phys_3p_o,
    input  wire [2:0]                   retire_valid_3p_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] retire_id_3p_i,
    input  wire [3*RETIRE_SLOT_WIDTH_3P-1:0] retire_slot_3p_i,
    input  wire [2:0]                   retire_uses_rs1_3p_i,
    input  wire [2:0]                   retire_uses_rs2_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_3p_i,
    input  wire [2:0]                   retire_reg_write_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_3p_i,
    input  wire [2:0]                   retire_hard_3p_i,
    input  wire                         recovery_valid_3p_i,
    input  wire                         recovery_reg_write_3p_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] recovery_rd_addr_3p_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id_3p_i,
    input  wire [RETIRE_SLOT_WIDTH_3P-1:0] next_retire_slot_3p_i,
    output wire                         barrier_active_3p_o,
    output wire [2:0]                   raw_hazard_3p_o,
    output wire [2:0]                   waw_hazard_3p_o,
    output wire [2:0]                   read_port_hazard_3p_o,
    output wire [31:0]                  write_busy_3p_o,
    output wire [COUNT_WIDTH_3P-1:0]    queue_count_3p_o,
    output wire [32*PHYS_REG_ADDR_WIDTH_3P-1:0]
                                        committed_map_3p_o
);

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_1P) begin : g_1p
            openrv64_dispatch_1p #(
                .REGISTERED(REGISTERED),
                .ENABLE_FORWARDING(ENABLE_FORWARDING),
                .DECODE_STAGE(DECODE_STAGE_1P)
            ) u_dispatch (
                .scoreboard_clear_i(scoreboard_clear_1p_i),
                .*
            );
            assign decode_ready_3p_o = 3'b000;
            assign gpr_read_addr_3p_o =
                {6*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign gpr_read_ready_3p_o = 6'b111111;
            assign allocation_valid_3p_o = 3'b000;
            assign allocation_meta_3p_o =
                {3*RETIRE_META_WIDTH_3P{1'b0}};
            assign pipe_valid_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_candidate_valid_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_age_rank_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*2{1'b0}};
            assign pipe_id_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign pipe_slot_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P{1'b0}};
            assign pipe_payload_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            assign pipe_uses_rs1_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_uses_rs2_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_src1_producer_valid_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_src1_producer_id_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign pipe_src2_producer_valid_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_src2_producer_id_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign pipe_src1_phys_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign pipe_src2_phys_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign pipe_destination_phys_3p_o =
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign committed_map_3p_o =
                {32*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign barrier_active_3p_o = 1'b0;
            assign raw_hazard_3p_o = 3'b000;
            assign waw_hazard_3p_o = 3'b000;
            assign read_port_hazard_3p_o = 3'b000;
            assign write_busy_3p_o = 32'd0;
            assign queue_count_3p_o = {COUNT_WIDTH_3P{1'b0}};
        end else if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_3p
            wire rename_allocation_ready;
            wire [2:0] strict_decode_ready;
            wire [6*`RV64_REG_ADDR_WIDTH-1:0] strict_gpr_read_addr;
            wire [2:0] strict_allocation_valid;
            wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0]
                strict_allocation_meta;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] strict_pipe_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0] strict_pipe_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P-1:0]
                strict_pipe_slot;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                strict_pipe_payload;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                strict_pipe_src1_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                strict_pipe_src1_producer_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                strict_pipe_src2_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                strict_pipe_src2_producer_id;
            wire strict_barrier;
            wire [2:0] strict_raw_hazard;
            wire [2:0] strict_waw_hazard;
            wire [2:0] strict_read_port_hazard;
            wire [31:0] strict_write_busy;
            wire [$clog2(QUEUE_DEPTH_3P + 1)-1:0]
                strict_queue_count;
            wire [2:0] strict_rename_destination_request;

            // Keep the original instance and hierarchy present regardless of
            // selection.  Existing testbench probes and the default behavior
            // therefore remain unchanged and immediately recoverable.
            openrv64_dispatch_3p #(
                .QUEUE_DEPTH(QUEUE_DEPTH_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .MAX_READS_PER_REG(MAX_READS_PER_REG_3P),
                .RELAX_WAW(RELAX_WAW_3P),
                .RELAX_HAZARDS(RELAX_HAZARDS_3P),
                .MAX_ISSUE_LANES(MAX_ISSUE_LANES_3P),
                .FREE_BRANCHES(FREE_BRANCHES_3P),
                .ENABLE_EQ_BRANCH_PAIRING(
                    (RENAME_MODE_3P == `OPENRV64_RENAME_IDENTITY) ?
                    ENABLE_EQ_BRANCH_PAIRING_3P : 0),
                .DEFER_EQ_BRANCH_PAIRING(DEFER_EQ_BRANCH_PAIRING_3P),
                .ENABLE_CANDIDATE_ADDRESS_READY(
                    RENAME_MODE_3P == `OPENRV64_RENAME_TOMASULO)
            ) u_dispatch (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .decode_valid_i((ENABLE_ISSUE_WINDOW_3P == 0) &&
                                (RENAME_MODE_3P ==
                                 `OPENRV64_RENAME_IDENTITY) ?
                                decode_valid_3p_i : 3'b000),
                .decode_ready_o(strict_decode_ready),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .gpr_read_addr_o(strict_gpr_read_addr),
                .rename_destination_request_o(
                    strict_rename_destination_request),
                .gpr_read_data_i(gpr_read_data_3p_i),
                .candidate_operand_ready_i(
                    candidate_operand_ready_3p_i),
                .candidate_address_ready_i(
                    candidate_address_ready_3p_i),
                .allocation_ready_i(rename_allocation_ready),
                .allocation_id_i(allocation_id_3p_i),
                .allocation_slot_i(allocation_slot_3p_i),
                .allocation_valid_o(strict_allocation_valid),
                .allocation_meta_o(strict_allocation_meta),
                .pipe_ready_i(pipe_ready_3p_i),
                .forward_valid_i(forward_valid_3p_i),
                .forward_rd_addr_i(forward_rd_addr_3p_i),
                .completion_forward_valid_i(
                    completion_forward_valid_3p_i),
                .completion_forward_rd_addr_i(
                    completion_forward_rd_addr_3p_i),
                .completion_forward_data_i(completion_forward_data_3p_i),
                .branch_completion_forward_valid_i(
                    branch_completion_forward_valid_3p_i),
                .forward_map_valid_i(forward_map_valid_3p_i),
                .forward_map_data_i(forward_map_data_3p_i),
                .pipe_valid_o(strict_pipe_valid),
                .pipe_id_o(strict_pipe_id),
                .pipe_slot_o(strict_pipe_slot),
                .pipe_payload_o(strict_pipe_payload),
                .pipe_src1_producer_valid_o(
                    strict_pipe_src1_producer_valid),
                .pipe_src1_producer_id_o(strict_pipe_src1_producer_id),
                .pipe_src2_producer_valid_o(
                    strict_pipe_src2_producer_valid),
                .pipe_src2_producer_id_o(strict_pipe_src2_producer_id),
                .retire_valid_i((ENABLE_ISSUE_WINDOW_3P == 0) &&
                                (RENAME_MODE_3P ==
                                 `OPENRV64_RENAME_IDENTITY) ?
                                retire_valid_3p_i : 3'b000),
                .retire_uses_rs1_i(retire_uses_rs1_3p_i),
                .retire_uses_rs2_i(retire_uses_rs2_3p_i),
                .retire_rs1_addr_i(retire_rs1_addr_3p_i),
                .retire_rs2_addr_i(retire_rs2_addr_3p_i),
                .retire_reg_write_i(retire_reg_write_3p_i),
                .retire_rd_addr_i(retire_rd_addr_3p_i),
                .retire_hard_i(retire_hard_3p_i),
                .recovery_valid_i(recovery_valid_3p_i),
                .recovery_reg_write_i(recovery_reg_write_3p_i),
                .recovery_rd_addr_i(recovery_rd_addr_3p_i),
                .barrier_active_o(strict_barrier),
                .raw_hazard_o(strict_raw_hazard),
                .waw_hazard_o(strict_waw_hazard),
                .read_port_hazard_o(strict_read_port_hazard),
                .write_busy_o(strict_write_busy),
                .queue_count_o(strict_queue_count)
            );

            wire [2:0] window_decode_ready;
            wire [6*`RV64_REG_ADDR_WIDTH-1:0] window_gpr_read_addr;
            wire [2:0] window_allocation_valid;
            wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0]
                window_allocation_meta;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] window_pipe_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                window_pipe_candidate_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*2-1:0]
                window_pipe_age_rank;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0] window_pipe_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P-1:0]
                window_pipe_slot;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                window_pipe_payload;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                window_pipe_uses_rs1;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                window_pipe_uses_rs2;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                window_pipe_src1_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                window_pipe_src1_producer_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                window_pipe_src2_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                window_pipe_src2_producer_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                window_pipe_src1_phys;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                window_pipe_src2_phys;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                window_pipe_destination_phys;
            wire window_barrier;
            wire [2:0] window_raw_hazard;
            wire [2:0] window_waw_hazard;
            wire [2:0] window_read_port_hazard;
            wire [31:0] window_write_busy;
            wire [COUNT_WIDTH_3P-1:0] window_queue_count;

            openrv64_dispatch_window_3p #(
                .ENABLE((ENABLE_ISSUE_WINDOW_3P != 0) &&
                        (RENAME_MODE_3P ==
                         `OPENRV64_RENAME_IDENTITY)),
                .PHYSICAL_RENAME(0),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH_3P),
                .ENABLE_SPECULATION(ENABLE_SPECULATION_WINDOW_3P),
                .DEFER_GPR_READ(DEFER_WINDOW_GPR_READ_3P),
                .MAX_ISSUE_LANES(MAX_WINDOW_ISSUE_LANES_3P),
                .DEPTH(ISSUE_WINDOW_DEPTH_3P),
                .CACHEABLE_BASE(CACHEABLE_BASE_3P),
                .CACHEABLE_SIZE(CACHEABLE_SIZE_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .COUNT_WIDTH(COUNT_WIDTH_3P)
            ) u_window (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .squash_id_i(squash_id_3p_i),
                .translation_bypass_i(translation_bypass_3p_i),
                .decode_valid_i((ENABLE_ISSUE_WINDOW_3P != 0) &&
                                (RENAME_MODE_3P ==
                                 `OPENRV64_RENAME_IDENTITY) ?
                                decode_valid_3p_i : 3'b000),
                .decode_ready_o(window_decode_ready),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .gpr_read_addr_o(window_gpr_read_addr),
                .gpr_read_data_i(gpr_read_data_3p_i),
                .rename_source_phys_i(
                    {6*PHYS_REG_ADDR_WIDTH_3P{1'b0}}),
                .rename_source_ready_i(6'b111111),
                .rename_destination_phys_i(
                    {3*PHYS_REG_ADDR_WIDTH_3P{1'b0}}),
                .physical_writeback_valid_i(3'b000),
                .physical_writeback_tag_i(
                    {3*PHYS_REG_ADDR_WIDTH_3P{1'b0}}),
                .physical_writeback_data_i({3*`RV64_XLEN{1'b0}}),
                .allocation_ready_i(rename_allocation_ready),
                .allocation_id_i(allocation_id_3p_i),
                .allocation_slot_i(allocation_slot_3p_i),
                .allocation_valid_o(window_allocation_valid),
                .allocation_meta_o(window_allocation_meta),
                .pipe_ready_i(pipe_ready_3p_i),
                .pipe_candidate_valid_o(window_pipe_candidate_valid),
                .pipe_age_rank_o(window_pipe_age_rank),
                .pipe_valid_o(window_pipe_valid),
                .pipe_id_o(window_pipe_id),
                .pipe_slot_o(window_pipe_slot),
                .pipe_payload_o(window_pipe_payload),
                .pipe_uses_rs1_o(window_pipe_uses_rs1),
                .pipe_uses_rs2_o(window_pipe_uses_rs2),
                .pipe_src1_producer_valid_o(
                    window_pipe_src1_producer_valid),
                .pipe_src1_producer_id_o(window_pipe_src1_producer_id),
                .pipe_src2_producer_valid_o(
                    window_pipe_src2_producer_valid),
                .pipe_src2_producer_id_o(window_pipe_src2_producer_id),
                .pipe_src1_phys_o(window_pipe_src1_phys),
                .pipe_src2_phys_o(window_pipe_src2_phys),
                .pipe_destination_phys_o(window_pipe_destination_phys),
                .completion_valid_i(completion_valid_3p_i),
                .completion_id_i(completion_id_3p_i),
                .completion_payload_i(completion_payload_3p_i),
                .conditional_resolve_valid_i(
                    conditional_resolve_valid_3p_i),
                .conditional_resolve_id_i(conditional_resolve_id_3p_i),
                .conditional_resolve_slot_i(
                    conditional_resolve_slot_3p_i),
                .retire_valid_i((ENABLE_ISSUE_WINDOW_3P != 0) &&
                                (RENAME_MODE_3P ==
                                 `OPENRV64_RENAME_IDENTITY) ?
                                retire_valid_3p_i : 3'b000),
                .retire_id_i(retire_id_3p_i),
                .retire_slot_i(retire_slot_3p_i),
                .retire_hard_i(retire_hard_3p_i),
                .next_retire_id_i(next_retire_id_3p_i),
                .next_retire_slot_i(next_retire_slot_3p_i),
                .barrier_active_o(window_barrier),
                .raw_hazard_o(window_raw_hazard),
                .waw_hazard_o(window_waw_hazard),
                .read_port_hazard_o(window_read_port_hazard),
                .write_busy_o(window_write_busy),
                .queue_count_o(window_queue_count)
            );

            // Physical tags are state owned by the Tomasulo scheduler.  Use
            // that scheduler even when speculation is disabled; in the
            // strict bring-up configuration it enforces an ordered prefix but
            // still supplies physical source/destination tags to the
            // downstream six-read register-load stage.
            wire use_tomasulo_window =
                (RENAME_MODE_3P == `OPENRV64_RENAME_TOMASULO);
            wire [2:0] tomasulo_decode_ready;
            wire [6*`RV64_REG_ADDR_WIDTH-1:0]
                tomasulo_rename_source_arch;
            wire [2:0] tomasulo_allocation_valid;
            wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0]
                tomasulo_allocation_meta;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] tomasulo_pipe_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                tomasulo_pipe_candidate_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*2-1:0]
                tomasulo_pipe_age_rank;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0] tomasulo_pipe_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH_3P-1:0]
                tomasulo_pipe_slot;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                tomasulo_pipe_payload;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                tomasulo_pipe_uses_rs1;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                tomasulo_pipe_uses_rs2;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                tomasulo_pipe_src1_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                tomasulo_pipe_src1_producer_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                tomasulo_pipe_src2_producer_valid;
            wire [`OPENRV64_EXEC_PIPE_COUNT*
                  `OPENRV64_INSTR_ID_WIDTH-1:0]
                tomasulo_pipe_src2_producer_id;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                tomasulo_pipe_src1_phys;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                tomasulo_pipe_src2_phys;
            wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P-1:0]
                tomasulo_pipe_destination_phys;
            wire tomasulo_barrier;
            wire [2:0] tomasulo_raw_hazard;
            wire [2:0] tomasulo_waw_hazard;
            wire [2:0] tomasulo_read_port_hazard;
            wire [31:0] tomasulo_write_busy;
            wire [COUNT_WIDTH_3P-1:0] tomasulo_queue_count;

            assign decode_ready_3p_o = use_tomasulo_window ?
                tomasulo_decode_ready : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_decode_ready : strict_decode_ready;
            wire [6*`RV64_REG_ADDR_WIDTH-1:0] selected_gpr_read_addr =
                use_tomasulo_window ? tomasulo_rename_source_arch :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_gpr_read_addr : strict_gpr_read_addr;
            wire [2:0] selected_allocation_valid =
                use_tomasulo_window ? tomasulo_allocation_valid :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_allocation_valid : strict_allocation_valid;
            wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0]
                selected_allocation_meta =
                use_tomasulo_window ? tomasulo_allocation_meta :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_allocation_meta : strict_allocation_meta;

            wire [3*`RV64_REG_ADDR_WIDTH-1:0]
                rename_destination_arch;
            assign rename_destination_arch[
                0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                selected_allocation_meta[35 +: `RV64_REG_ADDR_WIDTH];
            assign rename_destination_arch[
                1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                selected_allocation_meta[
                    `OPENRV64_DISPATCH_META_WIDTH + 35 +:
                    `RV64_REG_ADDR_WIDTH];
            assign rename_destination_arch[
                2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                selected_allocation_meta[
                    2*`OPENRV64_DISPATCH_META_WIDTH + 35 +:
                    `RV64_REG_ADDR_WIDTH];

            wire [2:0] rename_destination_valid;
            wire [2:0] tomasulo_destination_request;
            genvar tomasulo_request_lane;
            for (tomasulo_request_lane = 0; tomasulo_request_lane < 3;
                 tomasulo_request_lane = tomasulo_request_lane + 1) begin :
                    g_tomasulo_request
                assign tomasulo_destination_request[
                    tomasulo_request_lane] =
                    decode_valid_3p_i[tomasulo_request_lane] &&
                    decode_payload_3p_i[
                        tomasulo_request_lane*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17] &&
                    (decode_payload_3p_i[
                        tomasulo_request_lane*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +:
                        `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
            end
            wire [2:0] rename_destination_request =
                use_tomasulo_window ? tomasulo_destination_request :
                strict_rename_destination_request;
            assign rename_destination_valid[0] =
                selected_allocation_valid[0] &&
                selected_allocation_meta[17] &&
                (rename_destination_arch[
                    0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
            assign rename_destination_valid[1] =
                selected_allocation_valid[1] &&
                selected_allocation_meta[
                    `OPENRV64_DISPATCH_META_WIDTH + 17] &&
                (rename_destination_arch[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
            assign rename_destination_valid[2] =
                selected_allocation_valid[2] &&
                selected_allocation_meta[
                    2*`OPENRV64_DISPATCH_META_WIDTH + 17] &&
                (rename_destination_arch[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);

            wire [3*PHYS_REG_ADDR_WIDTH_3P-1:0]
                rename_destination_new_phys;
            wire [3*PHYS_REG_ADDR_WIDTH_3P-1:0]
                rename_destination_old_phys;
            wire [5:0] rename_source_ready;
            wire [5:0] rename_source_phys_ready;
            wire [2:0] rename_checkpoint_valid;
            genvar checkpoint_lane;
            for (checkpoint_lane = 0; checkpoint_lane < 3;
                 checkpoint_lane = checkpoint_lane + 1) begin :
                    g_checkpoint_valid
                assign rename_checkpoint_valid[checkpoint_lane] =
                    selected_allocation_valid[checkpoint_lane] &&
                    (selected_allocation_meta[
                        checkpoint_lane*`OPENRV64_DISPATCH_META_WIDTH + 14] ||
                     selected_allocation_meta[
                        checkpoint_lane*`OPENRV64_DISPATCH_META_WIDTH + 13]);
            end
            if (RENAME_MODE_3P == `OPENRV64_RENAME_IDENTITY) begin :
                    g_identity
                    assign rename_allocation_ready = allocation_ready_3p_i;
                    assign rename_source_ready = 6'b111111;
                    assign rename_source_phys_ready = 6'b111111;
                    genvar identity_arch;
                    for (identity_arch = 0; identity_arch < 32;
                         identity_arch = identity_arch + 1) begin :
                            g_committed_identity
                        assign committed_map_3p_o[
                            identity_arch*PHYS_REG_ADDR_WIDTH_3P +:
                            PHYS_REG_ADDR_WIDTH_3P] =
                            PHYS_REG_ADDR_WIDTH_3P'(identity_arch);
                    end
                    openrv64_rename_identity #(
                        .ARCH_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
                        .ARCH_REG_COUNT(32),
                        .PHYS_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH_3P),
                        .PHYS_REG_COUNT(PHYS_REG_COUNT_3P),
                        .LANES(3),
                        .SOURCES_PER_LANE(2)
                    ) u_rename (
                        .source_arch_i(selected_gpr_read_addr),
                        .source_phys_o(gpr_read_addr_3p_o),
                        .destination_valid_i(rename_destination_valid),
                        .destination_arch_i(rename_destination_arch),
                        .destination_new_phys_o(rename_destination_new_phys),
                        .destination_old_phys_o(rename_destination_old_phys)
                    );
            end else begin : g_tomasulo
                    wire rename_destination_ready;
                    wire [5:0] rename_free_count;
                    assign rename_allocation_ready =
                        allocation_ready_3p_i && rename_destination_ready;
                    openrv64_rename_tomasulo #(
                        .ARCH_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
                        .ARCH_REG_COUNT(32),
                        .PHYS_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH_3P),
                        .PHYS_REG_COUNT(PHYS_REG_COUNT_3P),
                        .LANES(3),
                        .SOURCES_PER_LANE(2),
                        .FREE_PORTS(2),
                        .WRITE_PORTS(3),
                        .COMMIT_PORTS(3),
                        .CHECKPOINT_DEPTH(1 << RETIRE_SLOT_WIDTH_3P),
                        .CHECKPOINT_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P)
                    ) u_rename (
                        .clk(clk),
                        .rst_n(rst_n),
                        .flush_i(flush_i),
                        .source_arch_i(selected_gpr_read_addr),
                        .source_phys_o(gpr_read_addr_3p_o),
                        .source_ready_o(rename_source_ready),
                        .destination_request_i(rename_destination_request),
                        .destination_valid_i(rename_destination_valid),
                        .destination_arch_i(rename_destination_arch),
                        .destination_ready_o(rename_destination_ready),
                        .destination_new_phys_o(rename_destination_new_phys),
                        .destination_old_phys_o(rename_destination_old_phys),
                        .free_valid_i(rename_free_valid_3p_i),
                        .free_tag_i(rename_free_tag_3p_i),
                        .write_valid_i(rename_write_valid_3p_i),
                        .write_tag_i(rename_write_tag_3p_i),
                        .commit_valid_i(rename_commit_valid_3p_i),
                        .commit_arch_i(rename_commit_arch_3p_i),
                        .commit_phys_i(rename_commit_phys_3p_i),
                        .checkpoint_valid_i(rename_checkpoint_valid),
                        .checkpoint_slot_i(allocation_slot_3p_i),
                        .recovery_valid_i(squash_frontend_3p_i),
                        .recovery_slot_i(squash_slot_3p_i),
                        .committed_map_o(committed_map_3p_o),
                        .free_count_o(rename_free_count)
                    );
                    assign rename_source_phys_ready = rename_source_ready;
            end

            openrv64_dispatch_3p_tomasulo #(
                .ENABLE_SPECULATION(ENABLE_SPECULATION_WINDOW_3P),
                .MAX_ISSUE_LANES(MAX_WINDOW_ISSUE_LANES_3P),
                .DEPTH(ISSUE_WINDOW_DEPTH_3P),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH_3P),
                .CACHEABLE_BASE(CACHEABLE_BASE_3P),
                .CACHEABLE_SIZE(CACHEABLE_SIZE_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .COUNT_WIDTH(COUNT_WIDTH_3P)
            ) u_tomasulo_window (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .squash_id_i(squash_id_3p_i),
                .translation_bypass_i(translation_bypass_3p_i),
                .decode_valid_i(use_tomasulo_window ?
                    decode_valid_3p_i : 3'b000),
                .decode_ready_o(tomasulo_decode_ready),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .rename_source_arch_o(tomasulo_rename_source_arch),
                .rename_source_phys_i(gpr_read_addr_3p_o),
                .rename_source_ready_i(rename_source_phys_ready),
                .rename_destination_phys_i(rename_destination_new_phys),
                .physical_writeback_valid_i(rename_write_valid_3p_i),
                .physical_writeback_tag_i(rename_write_tag_3p_i),
                .physical_writeback_data_i(
                    completion_forward_data_3p_i),
                .allocation_ready_i(rename_allocation_ready),
                .allocation_id_i(allocation_id_3p_i),
                .allocation_slot_i(allocation_slot_3p_i),
                .allocation_valid_o(tomasulo_allocation_valid),
                .allocation_meta_o(tomasulo_allocation_meta),
                .pipe_ready_i(pipe_ready_3p_i),
                .pipe_candidate_valid_o(tomasulo_pipe_candidate_valid),
                .pipe_age_rank_o(tomasulo_pipe_age_rank),
                .pipe_valid_o(tomasulo_pipe_valid),
                .pipe_id_o(tomasulo_pipe_id),
                .pipe_slot_o(tomasulo_pipe_slot),
                .pipe_payload_o(tomasulo_pipe_payload),
                .pipe_uses_rs1_o(tomasulo_pipe_uses_rs1),
                .pipe_uses_rs2_o(tomasulo_pipe_uses_rs2),
                .pipe_src1_producer_valid_o(
                    tomasulo_pipe_src1_producer_valid),
                .pipe_src1_producer_id_o(
                    tomasulo_pipe_src1_producer_id),
                .pipe_src2_producer_valid_o(
                    tomasulo_pipe_src2_producer_valid),
                .pipe_src2_producer_id_o(
                    tomasulo_pipe_src2_producer_id),
                .pipe_src1_phys_o(tomasulo_pipe_src1_phys),
                .pipe_src2_phys_o(tomasulo_pipe_src2_phys),
                .pipe_destination_phys_o(
                    tomasulo_pipe_destination_phys),
                .completion_valid_i(completion_valid_3p_i),
                .completion_id_i(completion_id_3p_i),
                .completion_payload_i(completion_payload_3p_i),
                .conditional_resolve_valid_i(
                    conditional_resolve_valid_3p_i),
                .conditional_resolve_id_i(
                    conditional_resolve_id_3p_i),
                .conditional_resolve_slot_i(
                    conditional_resolve_slot_3p_i),
                .retire_valid_i(use_tomasulo_window ?
                    retire_valid_3p_i : 3'b000),
                .retire_id_i(retire_id_3p_i),
                .retire_slot_i(retire_slot_3p_i),
                .retire_hard_i(retire_hard_3p_i),
                .next_retire_id_i(next_retire_id_3p_i),
                .next_retire_slot_i(next_retire_slot_3p_i),
                .barrier_active_o(tomasulo_barrier),
                .raw_hazard_o(tomasulo_raw_hazard),
                .waw_hazard_o(tomasulo_waw_hazard),
                .read_port_hazard_o(tomasulo_read_port_hazard),
                .write_busy_o(tomasulo_write_busy),
                .queue_count_o(tomasulo_queue_count)
            );

            assign gpr_read_ready_3p_o = rename_source_ready;

            assign allocation_valid_3p_o = selected_allocation_valid;
            genvar rename_lane;
            for (rename_lane = 0; rename_lane < 3;
                 rename_lane = rename_lane + 1) begin : g_rename_meta
                assign allocation_meta_3p_o[
                    rename_lane*RETIRE_META_WIDTH_3P +:
                    RETIRE_META_WIDTH_3P] = {
                    rename_destination_old_phys[
                        rename_lane*PHYS_REG_ADDR_WIDTH_3P +:
                        PHYS_REG_ADDR_WIDTH_3P],
                    rename_destination_new_phys[
                        rename_lane*PHYS_REG_ADDR_WIDTH_3P +:
                        PHYS_REG_ADDR_WIDTH_3P],
                    selected_allocation_meta[
                        rename_lane*`OPENRV64_DISPATCH_META_WIDTH +:
                        `OPENRV64_DISPATCH_META_WIDTH]
                };
            end
            assign pipe_valid_3p_o = use_tomasulo_window ?
                tomasulo_pipe_valid : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_valid : strict_pipe_valid;
            assign pipe_candidate_valid_3p_o =
                use_tomasulo_window ? tomasulo_pipe_candidate_valid :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_candidate_valid : strict_pipe_valid;
            assign pipe_age_rank_3p_o =
                use_tomasulo_window ? tomasulo_pipe_age_rank :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_age_rank :
                {`OPENRV64_EXEC_PIPE_COUNT*2{1'b0}};
            assign pipe_id_3p_o = use_tomasulo_window ?
                tomasulo_pipe_id : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_id : strict_pipe_id;
            assign pipe_slot_3p_o = use_tomasulo_window ?
                tomasulo_pipe_slot : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_slot : strict_pipe_slot;
            assign pipe_payload_3p_o = use_tomasulo_window ?
                tomasulo_pipe_payload : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_payload : strict_pipe_payload;
            assign pipe_uses_rs1_3p_o = use_tomasulo_window ?
                tomasulo_pipe_uses_rs1 : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_uses_rs1 :
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_uses_rs2_3p_o = use_tomasulo_window ?
                tomasulo_pipe_uses_rs2 : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_uses_rs2 :
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            assign pipe_src1_producer_valid_3p_o =
                use_tomasulo_window ? tomasulo_pipe_src1_producer_valid :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_src1_producer_valid :
                strict_pipe_src1_producer_valid;
            assign pipe_src1_producer_id_3p_o =
                use_tomasulo_window ? tomasulo_pipe_src1_producer_id :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_src1_producer_id :
                strict_pipe_src1_producer_id;
            assign pipe_src2_producer_valid_3p_o =
                use_tomasulo_window ? tomasulo_pipe_src2_producer_valid :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_src2_producer_valid :
                strict_pipe_src2_producer_valid;
            assign pipe_src2_producer_id_3p_o =
                use_tomasulo_window ? tomasulo_pipe_src2_producer_id :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_src2_producer_id :
                strict_pipe_src2_producer_id;
            assign pipe_src1_phys_3p_o = use_tomasulo_window ?
                tomasulo_pipe_src1_phys :
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign pipe_src2_phys_3p_o = use_tomasulo_window ?
                tomasulo_pipe_src2_phys :
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign pipe_destination_phys_3p_o = use_tomasulo_window ?
                tomasulo_pipe_destination_phys :
                {`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH_3P{1'b0}};
            assign barrier_active_3p_o = use_tomasulo_window ?
                tomasulo_barrier : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_barrier : strict_barrier;
            assign raw_hazard_3p_o = use_tomasulo_window ?
                tomasulo_raw_hazard : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_raw_hazard : strict_raw_hazard;
            assign waw_hazard_3p_o = use_tomasulo_window ?
                tomasulo_waw_hazard : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_waw_hazard : strict_waw_hazard;
            assign read_port_hazard_3p_o =
                use_tomasulo_window ? tomasulo_read_port_hazard :
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_read_port_hazard : strict_read_port_hazard;
            assign write_busy_3p_o = use_tomasulo_window ?
                tomasulo_write_busy : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_write_busy : strict_write_busy;
            assign queue_count_3p_o = use_tomasulo_window ?
                tomasulo_queue_count : (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_queue_count : strict_queue_count;

            assign decode_clear_o = 1'b0;
            assign exec_valid_o = 1'b0;
            assign exec_pc_o = {`RV64_XLEN{1'b0}};
            assign exec_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign exec_rs1_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_rs2_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_imm_o = {`RV64_XLEN{1'b0}};
            assign exec_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_alu_ext_o = {`RV64_ALU_EXT_WIDTH{1'b0}};
            assign exec_alu_op_o = {`RV64_ALU_OP_WIDTH{1'b0}};
            assign exec_lsu_op_o = {`RV64_LSU_OP_WIDTH{1'b0}};
            assign exec_br_op_o = {`RV64_BR_OP_WIDTH{1'b0}};
            assign exec_reg_write_o = 1'b0;
            assign exec_mem_read_o = 1'b0;
            assign exec_mem_write_o = 1'b0;
            assign exec_branch_o = 1'b0;
            assign exec_jump_o = 1'b0;
            assign exec_predicted_taken_o = 1'b0;
            assign exec_word_op_o = 1'b0;
            assign exec_system_o = 1'b0;
            assign exec_fence_o = 1'b0;
            assign exec_illegal_o = 1'b0;
            assign exec_ebreak_o = 1'b0;
            assign exec_ecall_o = 1'b0;
            assign exec_instr_fault_o = 1'b0;
            assign exec_instr_page_fault_o = 1'b0;
            assign raw_hazard_o = 1'b0;
            assign waw_hazard_o = 1'b0;
            assign scoreboard_stall_o = 1'b0;
            assign exec_trace_id_o = 64'd0;
        end else begin : g_unsupported
            initial begin
                $error("openrv64_dispatch: backend configuration is not implemented");
            end

            assign decode_clear_o = 1'b0;
            assign exec_valid_o = 1'b0;
            assign exec_pc_o = {`RV64_XLEN{1'b0}};
            assign exec_instr_o = {`RV64_INSTR_WIDTH{1'b0}};
            assign exec_rs1_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_rs2_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_imm_o = {`RV64_XLEN{1'b0}};
            assign exec_rd_addr_o = {`RV64_REG_ADDR_WIDTH{1'b0}};
            assign exec_alu_ext_o = {`RV64_ALU_EXT_WIDTH{1'b0}};
            assign exec_alu_op_o = {`RV64_ALU_OP_WIDTH{1'b0}};
            assign exec_lsu_op_o = {`RV64_LSU_OP_WIDTH{1'b0}};
            assign exec_br_op_o = {`RV64_BR_OP_WIDTH{1'b0}};
            assign exec_reg_write_o = 1'b0;
            assign exec_mem_read_o = 1'b0;
            assign exec_mem_write_o = 1'b0;
            assign exec_branch_o = 1'b0;
            assign exec_jump_o = 1'b0;
            assign exec_predicted_taken_o = 1'b0;
            assign exec_word_op_o = 1'b0;
            assign exec_system_o = 1'b0;
            assign exec_fence_o = 1'b0;
            assign exec_illegal_o = 1'b0;
            assign exec_ebreak_o = 1'b0;
            assign exec_ecall_o = 1'b0;
            assign exec_instr_fault_o = 1'b0;
            assign exec_instr_page_fault_o = 1'b0;
            assign raw_hazard_o = 1'b0;
            assign waw_hazard_o = 1'b0;
            assign scoreboard_stall_o = 1'b0;
            assign exec_trace_id_o = 64'd0;
        end
    endgenerate

endmodule
