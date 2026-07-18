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
    output wire [2:0]                   pipe_valid_3p_o,
    output wire [3*64-1:0]              pipe_id_3p_o,
    output wire [3*RETIRE_SLOT_WIDTH_3P-1:0] pipe_slot_3p_o,
    output wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_3p_o,
    input  wire [2:0]                   retire_valid_3p_i,
    input  wire [2:0]                   retire_uses_rs1_3p_i,
    input  wire [2:0]                   retire_uses_rs2_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_3p_i,
    input  wire [2:0]                   retire_reg_write_3p_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_3p_i,
    input  wire [2:0]                   retire_hard_3p_i,
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
            openrv64_dispatch_3p #(
                .QUEUE_DEPTH(QUEUE_DEPTH_3P),
                .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH_3P),
                .MAX_READS_PER_REG(MAX_READS_PER_REG_3P)
            ) u_dispatch (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_frontend_i(squash_frontend_3p_i),
                .decode_valid_i(decode_valid_3p_i),
                .decode_ready_o(decode_ready_3p_o),
                .decode_payload_i(decode_payload_3p_i),
                .decode_uses_rs1_i(decode_uses_rs1_3p_i),
                .decode_uses_rs2_i(decode_uses_rs2_3p_i),
                .gpr_read_addr_o(gpr_read_addr_3p_o),
                .gpr_read_data_i(gpr_read_data_3p_i),
                .allocation_ready_i(allocation_ready_3p_i),
                .allocation_id_i(allocation_id_3p_i),
                .allocation_slot_i(allocation_slot_3p_i),
                .allocation_valid_o(allocation_valid_3p_o),
                .allocation_meta_o(allocation_meta_3p_o),
                .pipe_ready_i(pipe_ready_3p_i),
                .forward_valid_i(forward_valid_3p_i),
                .forward_rd_addr_i(forward_rd_addr_3p_i),
                .pipe_valid_o(pipe_valid_3p_o), .pipe_id_o(pipe_id_3p_o),
                .pipe_slot_o(pipe_slot_3p_o),
                .pipe_payload_o(pipe_payload_3p_o),
                .retire_valid_i(retire_valid_3p_i),
                .retire_uses_rs1_i(retire_uses_rs1_3p_i),
                .retire_uses_rs2_i(retire_uses_rs2_3p_i),
                .retire_rs1_addr_i(retire_rs1_addr_3p_i),
                .retire_rs2_addr_i(retire_rs2_addr_3p_i),
                .retire_reg_write_i(retire_reg_write_3p_i),
                .retire_rd_addr_i(retire_rd_addr_3p_i),
                .retire_hard_i(retire_hard_3p_i),
                .barrier_active_o(barrier_active_3p_o),
                .raw_hazard_o(raw_hazard_3p_o),
                .waw_hazard_o(waw_hazard_3p_o),
                .read_port_hazard_o(read_port_hazard_3p_o),
                .write_busy_o(write_busy_3p_o),
                .queue_count_o(queue_count_3p_o)
            );

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
