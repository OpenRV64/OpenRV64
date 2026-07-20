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
    parameter integer QUEUE_DEPTH_3P = 6,
    parameter integer RETIRE_SLOT_WIDTH_3P = 3,
    parameter integer MAX_READS_PER_REG_3P = 2,
    parameter integer RELAX_WAW_3P = 1,
    parameter integer RELAX_HAZARDS_3P = 0,
    parameter integer FREE_BRANCHES_3P = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING_3P = 1,
    parameter integer ENABLE_ISSUE_WINDOW_3P = 0,
    parameter integer ENABLE_SPECULATION_WINDOW_3P = 0,
    parameter integer ISSUE_WINDOW_DEPTH_3P = 16,
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_BASE_3P = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] SPEC_LOAD_SIZE_3P = {`RV64_XLEN{1'b0}},
    parameter integer COUNT_WIDTH_3P = $clog2(QUEUE_DEPTH_3P + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

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
    input  wire [63:0]                  squash_id_3p_i,
    input  wire [2:0]                   decode_valid_3p_i,
    output wire [2:0]                   decode_ready_3p_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_3p_i,
    input  wire [2:0]                   decode_uses_rs1_3p_i,
    input  wire [2:0]                   decode_uses_rs2_3p_i,
    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_3p_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_3p_i,
    input  wire                         allocation_ready_3p_i,
    input  wire [3*64-1:0]              allocation_id_3p_i,
    input  wire [3*RETIRE_SLOT_WIDTH_3P-1:0] allocation_slot_3p_i,
    output wire [2:0]                   allocation_valid_3p_o,
    output wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0] allocation_meta_3p_o,
    input  wire [2:0]                   pipe_ready_3p_i,
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
    input  wire [3*64-1:0]              completion_id_3p_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        completion_payload_3p_i,
    output wire [2:0]                   pipe_valid_3p_o,
    output wire [3*64-1:0]              pipe_id_3p_o,
    output wire [3*RETIRE_SLOT_WIDTH_3P-1:0] pipe_slot_3p_o,
    output wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_3p_o,
    input  wire [2:0]                   retire_valid_3p_i,
    input  wire [3*64-1:0]              retire_id_3p_i,
    input  wire [3*RETIRE_SLOT_WIDTH_3P-1:0] retire_slot_3p_i,
    input  wire [2:0]                   retire_uses_rs1_3p_i,
    input  wire [2:0]                   retire_uses_rs2_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_3p_i,
    input  wire [2:0]                   retire_reg_write_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_3p_i,
    input  wire [2:0]                   retire_hard_3p_i,
    input  wire [63:0]                  next_retire_id_3p_i,
    input  wire [RETIRE_SLOT_WIDTH_3P-1:0] next_retire_slot_3p_i,
    output wire                         barrier_active_3p_o,
    output wire [2:0]                   raw_hazard_3p_o,
    output wire [2:0]                   waw_hazard_3p_o,
    output wire [2:0]                   read_port_hazard_3p_o,
    output wire [31:0]                  write_busy_3p_o,
    output wire [COUNT_WIDTH_3P-1:0]    queue_count_3p_o
);

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_1P) begin : g_1p
            openrv64_dispatch_1p #(
                .REGISTERED(REGISTERED),
                .ENABLE_FORWARDING(ENABLE_FORWARDING)
            ) u_dispatch (.*);
            assign decode_ready_3p_o = 3'b000;
            assign gpr_read_addr_3p_o = {6*`RV64_REG_ADDR_WIDTH{1'b0}};
            assign allocation_valid_3p_o = 3'b000;
            assign allocation_meta_3p_o =
                {3*`OPENRV64_RETIRE_META_WIDTH{1'b0}};
            assign pipe_valid_3p_o = 3'b000;
            assign pipe_id_3p_o = {3*64{1'b0}};
            assign pipe_slot_3p_o = {3*RETIRE_SLOT_WIDTH_3P{1'b0}};
            assign pipe_payload_3p_o =
                {3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            assign barrier_active_3p_o = 1'b0;
            assign raw_hazard_3p_o = 3'b000;
            assign waw_hazard_3p_o = 3'b000;
            assign read_port_hazard_3p_o = 3'b000;
            assign write_busy_3p_o = 32'd0;
            assign queue_count_3p_o = {COUNT_WIDTH_3P{1'b0}};
        end else if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_3p
            wire [2:0] strict_decode_ready;
            wire [6*`RV64_REG_ADDR_WIDTH-1:0] strict_gpr_read_addr;
            wire [2:0] strict_allocation_valid;
            wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0]
                strict_allocation_meta;
            wire [2:0] strict_pipe_valid;
            wire [3*64-1:0] strict_pipe_id;
            wire [3*RETIRE_SLOT_WIDTH_3P-1:0] strict_pipe_slot;
            wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                strict_pipe_payload;
            wire strict_barrier;
            wire [2:0] strict_raw_hazard;
            wire [2:0] strict_waw_hazard;
            wire [2:0] strict_read_port_hazard;
            wire [31:0] strict_write_busy;
            wire [COUNT_WIDTH_3P-1:0] strict_queue_count;

            // Keep the original instance and hierarchy present regardless of
            // selection.  Existing testbench probes and the default behavior
            // therefore remain unchanged and immediately recoverable.
            openrv64_dispatch_3p #(
                .QUEUE_DEPTH(QUEUE_DEPTH_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .MAX_READS_PER_REG(MAX_READS_PER_REG_3P),
                .RELAX_WAW(RELAX_WAW_3P),
                .RELAX_HAZARDS(RELAX_HAZARDS_3P),
                .FREE_BRANCHES(FREE_BRANCHES_3P),
                .ENABLE_EQ_BRANCH_PAIRING(ENABLE_EQ_BRANCH_PAIRING_3P)
            ) u_dispatch (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .decode_valid_i((ENABLE_ISSUE_WINDOW_3P == 0) ?
                                decode_valid_3p_i : 3'b000),
                .decode_ready_o(strict_decode_ready),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .gpr_read_addr_o(strict_gpr_read_addr),
                .gpr_read_data_i(gpr_read_data_3p_i),
                .allocation_ready_i(allocation_ready_3p_i),
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
                .retire_valid_i((ENABLE_ISSUE_WINDOW_3P == 0) ?
                                retire_valid_3p_i : 3'b000),
                .retire_uses_rs1_i(retire_uses_rs1_3p_i),
                .retire_uses_rs2_i(retire_uses_rs2_3p_i),
                .retire_rs1_addr_i(retire_rs1_addr_3p_i),
                .retire_rs2_addr_i(retire_rs2_addr_3p_i),
                .retire_reg_write_i(retire_reg_write_3p_i),
                .retire_rd_addr_i(retire_rd_addr_3p_i),
                .retire_hard_i(retire_hard_3p_i),
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
            wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0]
                window_allocation_meta;
            wire [2:0] window_pipe_valid;
            wire [3*64-1:0] window_pipe_id;
            wire [3*RETIRE_SLOT_WIDTH_3P-1:0] window_pipe_slot;
            wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                window_pipe_payload;
            wire window_barrier;
            wire [2:0] window_raw_hazard;
            wire [2:0] window_waw_hazard;
            wire [2:0] window_read_port_hazard;
            wire [31:0] window_write_busy;
            wire [COUNT_WIDTH_3P-1:0] window_queue_count;

            openrv64_dispatch_window_3p #(
                .ENABLE(ENABLE_ISSUE_WINDOW_3P),
                .ENABLE_SPECULATION(ENABLE_SPECULATION_WINDOW_3P),
                .DEPTH(ISSUE_WINDOW_DEPTH_3P),
                .SPEC_LOAD_BASE(SPEC_LOAD_BASE_3P),
                .SPEC_LOAD_SIZE(SPEC_LOAD_SIZE_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .COUNT_WIDTH(COUNT_WIDTH_3P)
            ) u_window (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .squash_id_i(squash_id_3p_i),
                .decode_valid_i((ENABLE_ISSUE_WINDOW_3P != 0) ?
                                decode_valid_3p_i : 3'b000),
                .decode_ready_o(window_decode_ready),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .gpr_read_addr_o(window_gpr_read_addr),
                .gpr_read_data_i(gpr_read_data_3p_i),
                .allocation_ready_i(allocation_ready_3p_i),
                .allocation_id_i(allocation_id_3p_i),
                .allocation_slot_i(allocation_slot_3p_i),
                .allocation_valid_o(window_allocation_valid),
                .allocation_meta_o(window_allocation_meta),
                .pipe_ready_i(pipe_ready_3p_i),
                .pipe_valid_o(window_pipe_valid),
                .pipe_id_o(window_pipe_id),
                .pipe_slot_o(window_pipe_slot),
                .pipe_payload_o(window_pipe_payload),
                .completion_valid_i(completion_valid_3p_i),
                .completion_id_i(completion_id_3p_i),
                .completion_payload_i(completion_payload_3p_i),
                .retire_valid_i((ENABLE_ISSUE_WINDOW_3P != 0) ?
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

            assign decode_ready_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_decode_ready : strict_decode_ready;
            assign gpr_read_addr_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_gpr_read_addr : strict_gpr_read_addr;
            assign allocation_valid_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_allocation_valid : strict_allocation_valid;
            assign allocation_meta_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_allocation_meta : strict_allocation_meta;
            assign pipe_valid_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_valid : strict_pipe_valid;
            assign pipe_id_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_id : strict_pipe_id;
            assign pipe_slot_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_slot : strict_pipe_slot;
            assign pipe_payload_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_pipe_payload : strict_pipe_payload;
            assign barrier_active_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_barrier : strict_barrier;
            assign raw_hazard_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_raw_hazard : strict_raw_hazard;
            assign waw_hazard_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_waw_hazard : strict_waw_hazard;
            assign read_port_hazard_3p_o =
                (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_read_port_hazard : strict_read_port_hazard;
            assign write_busy_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
                window_write_busy : strict_write_busy;
            assign queue_count_3p_o = (ENABLE_ISSUE_WINDOW_3P != 0) ?
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
