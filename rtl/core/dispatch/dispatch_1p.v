`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_dispatch_1p #(
    parameter REGISTERED = 1,
    parameter ENABLE_FORWARDING = 0,
    parameter DECODE_STAGE = 0
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
    output wire [63:0]                  exec_trace_id_o
);

    localparam DISPATCH_WIDTH = 270;
    localparam DECODE_STAGE_WIDTH = DISPATCH_WIDTH + 2;
    wire [DISPATCH_WIDTH-1:0] decode_data = {
        decode_trace_id_i,
        decode_pc_i,
        decode_instr_i,
        decode_rs1_addr_i,
        decode_rs2_addr_i,
        decode_imm_i,
        decode_rd_addr_i,
        decode_alu_ext_i,
        decode_alu_op_i,
        decode_lsu_op_i,
        decode_br_op_i,
        decode_reg_write_i,
        decode_mem_read_i,
        decode_mem_write_i,
        decode_branch_i,
        decode_jump_i,
        decode_predicted_taken_i,
        decode_word_op_i,
        decode_system_i,
        decode_fence_i,
        decode_illegal_i,
        decode_ebreak_i,
        decode_ecall_i,
        decode_instr_fault_i,
        decode_instr_page_fault_i
    };

    wire [DECODE_STAGE_WIDTH-1:0] decode_stage_data = {
        decode_uses_rs1_i,
        decode_uses_rs2_i,
        decode_data
    };
    wire candidate_valid;
    wire candidate_clear;
    wire [DECODE_STAGE_WIDTH-1:0] candidate_stage_data;
    wire candidate_uses_rs1;
    wire candidate_uses_rs2;
    wire [DISPATCH_WIDTH-1:0] candidate_data;

    assign {
        candidate_uses_rs1,
        candidate_uses_rs2,
        candidate_data
    } = candidate_stage_data;

    wire [63:0] candidate_trace_id;
    wire [`RV64_XLEN-1:0] candidate_pc;
    wire [`RV64_INSTR_WIDTH-1:0] candidate_instr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] candidate_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] candidate_rs2_addr;
    wire [`RV64_XLEN-1:0] candidate_imm;
    wire [`RV64_REG_ADDR_WIDTH-1:0] candidate_rd_addr;
    wire [`RV64_ALU_EXT_WIDTH-1:0] candidate_alu_ext;
    wire [`RV64_ALU_OP_WIDTH-1:0] candidate_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] candidate_lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] candidate_br_op;
    wire candidate_reg_write;
    wire candidate_mem_read;
    wire candidate_mem_write;
    wire candidate_branch;
    wire candidate_jump;
    wire candidate_predicted_taken;
    wire candidate_word_op;
    wire candidate_system;
    wire candidate_fence;
    wire candidate_illegal;
    wire candidate_ebreak;
    wire candidate_ecall;
    wire candidate_instr_fault;
    wire candidate_instr_page_fault;

    assign {
        candidate_trace_id,
        candidate_pc,
        candidate_instr,
        candidate_rs1_addr,
        candidate_rs2_addr,
        candidate_imm,
        candidate_rd_addr,
        candidate_alu_ext,
        candidate_alu_op,
        candidate_lsu_op,
        candidate_br_op,
        candidate_reg_write,
        candidate_mem_read,
        candidate_mem_write,
        candidate_branch,
        candidate_jump,
        candidate_predicted_taken,
        candidate_word_op,
        candidate_system,
        candidate_fence,
        candidate_illegal,
        candidate_ebreak,
        candidate_ecall,
        candidate_instr_fault,
        candidate_instr_page_fault
    } = candidate_data;

    wire candidate_writes_rd = candidate_reg_write &&
                               !candidate_illegal &&
                               !candidate_ebreak &&
                               (candidate_rd_addr != `RV64_REG_X0);
    wire candidate_uses_lsu_unit = candidate_mem_read ||
                                   candidate_mem_write;
    wire candidate_uses_br_unit = candidate_branch || candidate_jump;
    wire candidate_uses_system_unit = candidate_system ||
                                      candidate_fence ||
                                      candidate_illegal ||
                                      candidate_ebreak ||
                                      candidate_ecall;
    wire candidate_is_csr = candidate_system &&
                            (`RV64_FUNCT3(candidate_instr) !=
                             `RV64_FUNCT3_SYSTEM_PRIV);
    wire candidate_unit_ready = candidate_uses_br_unit ? exec_br_ready_i :
                                candidate_uses_lsu_unit ? exec_lsu_ready_i :
                                candidate_uses_system_unit ?
                                    exec_system_ready_i : exec_alu_ready_i;

    generate
        if (DECODE_STAGE != 0) begin : g_decode_stage
            openrv64_stage #(
                .WIDTH(DECODE_STAGE_WIDTH),
                .REGISTERED(1)
            ) u_decode_stage (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_i),
                .in_valid_i(decode_valid_i && !flush_i),
                .in_clear_o(decode_clear_o),
                .in_data_i(decode_stage_data),
                .out_valid_o(candidate_valid),
                .out_clear_i(candidate_clear),
                .out_data_o(candidate_stage_data)
            );
        end else begin : g_decode_bypass
            assign decode_clear_o = candidate_clear;
            assign candidate_valid = decode_valid_i;
            assign candidate_stage_data = decode_stage_data;
        end
    endgenerate

    wire [DISPATCH_WIDTH-1:0] exec_data;
    reg csr_active_q;
    reg fence_active_q;
    wire csr_active = csr_active_q;
    wire fence_active = fence_active_q;
    wire csr_allocate = candidate_valid &&
                        candidate_clear &&
                        candidate_is_csr &&
                        !flush_i;
    wire fence_allocate = candidate_valid &&
                          candidate_clear &&
                          candidate_fence &&
                          !flush_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_active_q <= 1'b0;
        end else if (flush_i) begin
            csr_active_q <= 1'b0;
        end else if (csr_allocate) begin
            csr_active_q <= 1'b1;
        end else if (retire_valid_i && retire_csr_i) begin
            csr_active_q <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fence_active_q <= 1'b0;
        end else if (flush_i) begin
            fence_active_q <= 1'b0;
        end else if (fence_allocate) begin
            fence_active_q <= 1'b1;
        end else if (retire_valid_i && retire_fence_i) begin
            fence_active_q <= 1'b0;
        end
    end

    assign {
        exec_trace_id_o,
        exec_pc_o,
        exec_instr_o,
        exec_rs1_addr_o,
        exec_rs2_addr_o,
        exec_imm_o,
        exec_rd_addr_o,
        exec_alu_ext_o,
        exec_alu_op_o,
        exec_lsu_op_o,
        exec_br_op_o,
        exec_reg_write_o,
        exec_mem_read_o,
        exec_mem_write_o,
        exec_branch_o,
        exec_jump_o,
        exec_predicted_taken_o,
        exec_word_op_o,
        exec_system_o,
        exec_fence_o,
        exec_illegal_o,
        exec_ebreak_o,
        exec_ecall_o,
        exec_instr_fault_o,
        exec_instr_page_fault_o
    } = exec_data;

    generate
        if (REGISTERED != 0) begin : g_registered
            reg                         active_q;
            reg [DISPATCH_WIDTH-1:0]    data_q;
            reg                         active_uses_rs1_q;
            reg                         active_uses_rs2_q;
            reg [`RV64_REG_ADDR_WIDTH-1:0] active_rs1_addr_q;
            reg [`RV64_REG_ADDR_WIDTH-1:0] active_rs2_addr_q;
            reg                         active_reg_write_q;
            reg [`RV64_REG_ADDR_WIDTH-1:0] active_rd_addr_q;
            reg                         active_uses_lsu_unit_q;
            reg                         active_uses_br_unit_q;
            reg                         active_uses_system_unit_q;

            wire active_unit_ready = active_uses_br_unit_q ? exec_br_ready_i :
                                     active_uses_lsu_unit_q ? exec_lsu_ready_i :
                                     active_uses_system_unit_q ? exec_system_ready_i :
                                     exec_alu_ready_i;
            wire exec_accept = exec_clear_i && active_unit_ready;
            wire stage_can_accept = !active_q || exec_accept;
            wire reg_map_raw_hazard;
            wire reg_map_war_hazard;
            wire reg_map_waw_hazard;
            wire reg_map_read_full_hazard;
            wire reg_map_can_allocate;
            wire can_dispatch = stage_can_accept &&
                                candidate_unit_ready &&
                                reg_map_can_allocate;
            wire [31:0] unused_alloc_read_hot;
            wire [31:0] forward_ex_write_hot =
                (ENABLE_FORWARDING && forward_ex_valid_i) ?
                (32'h0000_0001 << forward_ex_rd_addr_i) : 32'h0;
            wire [31:0] forward_mem_write_hot =
                (ENABLE_FORWARDING && forward_mem_valid_i) ?
                (32'h0000_0001 << forward_mem_rd_addr_i) : 32'h0;
            wire scoreboard_stall = candidate_valid && !flush_i &&
                                    !reg_map_can_allocate;
            wire capture = candidate_valid && candidate_clear && !flush_i;
            wire unused_reg_map_hazards = |{
                reg_map_war_hazard,
                reg_map_read_full_hazard
            };

            openrv64_dispatch_reg_map #(
                .ENABLE_FORWARDING(ENABLE_FORWARDING)
            ) u_reg_map (
                .clk(clk),
                .rst_n(rst_n),
                .clear_i(flush_i),
                .alloc_valid_i(candidate_valid && !flush_i),
                .alloc_fire_i(capture),
                .alloc_uses_rs1_i(candidate_uses_rs1),
                .alloc_uses_rs2_i(candidate_uses_rs2),
                .alloc_rs1_addr_i(candidate_rs1_addr),
                .alloc_rs2_addr_i(candidate_rs2_addr),
                .alloc_reg_write_i(candidate_writes_rd),
                .alloc_rd_addr_i(candidate_rd_addr),
                .alloc_read_hot_i(32'h0000_0000),
                .forward_ex_write_hot_i(forward_ex_write_hot),
                .forward_mem_write_hot_i(forward_mem_write_hot),
                .alloc_read_hot_o(unused_alloc_read_hot),
                .retire_valid_i(retire_valid_i),
                .retire_uses_rs1_i(retire_uses_rs1_i),
                .retire_uses_rs2_i(retire_uses_rs2_i),
                .retire_rs1_addr_i(retire_rs1_addr_i),
                .retire_rs2_addr_i(retire_rs2_addr_i),
                .retire_reg_write_i(retire_reg_write_i),
                .retire_rd_addr_i(retire_rd_addr_i),
                .rollback_valid_i(flush_i && active_q),
                .rollback_uses_rs1_i(active_uses_rs1_q),
                .rollback_uses_rs2_i(active_uses_rs2_q),
                .rollback_rs1_addr_i(active_rs1_addr_q),
                .rollback_rs2_addr_i(active_rs2_addr_q),
                .rollback_reg_write_i(active_reg_write_q),
                .rollback_rd_addr_i(active_rd_addr_q),
                .raw_hazard_o(reg_map_raw_hazard),
                .war_hazard_o(reg_map_war_hazard),
                .waw_hazard_o(reg_map_waw_hazard),
                .read_full_hazard_o(reg_map_read_full_hazard),
                .can_allocate_o(reg_map_can_allocate)
            );

            assign raw_hazard_o = candidate_valid && !flush_i &&
                                  reg_map_raw_hazard;
            assign waw_hazard_o = candidate_valid && !flush_i &&
                                  reg_map_waw_hazard;
            assign scoreboard_stall_o = scoreboard_stall;
            assign candidate_clear = flush_i ||
                                     (can_dispatch &&
                                      !csr_active &&
                                      !fence_active);
            // flush_i is sampled by the state update below.  Keep the current
            // payload and valid bit stable until the edge; the core separately
            // inhibits issue during the flush-decision cycle.
            assign exec_valid_o = active_q;
            assign exec_data = data_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    active_q           <= 1'b0;
                    data_q             <= {DISPATCH_WIDTH{1'b0}};
                    active_uses_rs1_q  <= 1'b0;
                    active_uses_rs2_q  <= 1'b0;
                    active_rs1_addr_q  <= `RV64_REG_X0;
                    active_rs2_addr_q  <= `RV64_REG_X0;
                    active_reg_write_q <= 1'b0;
                    active_rd_addr_q   <= `RV64_REG_X0;
                    active_uses_lsu_unit_q <= 1'b0;
                    active_uses_br_unit_q <= 1'b0;
                    active_uses_system_unit_q <= 1'b0;
                end else begin
                    if (flush_i) begin
                        active_q           <= 1'b0;
                        data_q             <= {DISPATCH_WIDTH{1'b0}};
                        active_uses_rs1_q  <= 1'b0;
                        active_uses_rs2_q  <= 1'b0;
                        active_rs1_addr_q  <= `RV64_REG_X0;
                        active_rs2_addr_q  <= `RV64_REG_X0;
                        active_reg_write_q <= 1'b0;
                        active_rd_addr_q   <= `RV64_REG_X0;
                        active_uses_lsu_unit_q <= 1'b0;
                        active_uses_br_unit_q <= 1'b0;
                        active_uses_system_unit_q <= 1'b0;
                    end else if (candidate_clear) begin
                        active_q <= candidate_valid;

                        if (candidate_valid) begin
                            data_q             <= candidate_data;
                            active_uses_rs1_q  <= candidate_uses_rs1;
                            active_uses_rs2_q  <= candidate_uses_rs2;
                            active_rs1_addr_q  <= candidate_rs1_addr;
                            active_rs2_addr_q  <= candidate_rs2_addr;
                            active_reg_write_q <= candidate_writes_rd;
                            active_rd_addr_q   <= candidate_rd_addr;
                            active_uses_lsu_unit_q <=
                                candidate_uses_lsu_unit;
                            active_uses_br_unit_q <= candidate_uses_br_unit;
                            active_uses_system_unit_q <=
                                candidate_uses_system_unit;
                        end else begin
                            active_uses_rs1_q <= 1'b0;
                            active_uses_rs2_q <= 1'b0;
                            active_rs1_addr_q <= `RV64_REG_X0;
                            active_rs2_addr_q <= `RV64_REG_X0;
                            active_reg_write_q <= 1'b0;
                            active_rd_addr_q   <= `RV64_REG_X0;
                            active_uses_lsu_unit_q <= 1'b0;
                            active_uses_br_unit_q <= 1'b0;
                            active_uses_system_unit_q <= 1'b0;
                        end
                    end else if (exec_accept) begin
                        active_q <= 1'b0;
                    end
                end
            end
        end else begin : g_bypass
            wire reg_map_raw_hazard;
            wire reg_map_war_hazard;
            wire reg_map_waw_hazard;
            wire reg_map_read_full_hazard;
            wire reg_map_can_allocate;
            wire [31:0] unused_alloc_read_hot;
            wire [31:0] forward_mem_write_hot =
                (ENABLE_FORWARDING && forward_mem_valid_i) ?
                (32'h0000_0001 << forward_mem_rd_addr_i) : 32'h0;
            wire scoreboard_stall = candidate_valid && !flush_i &&
                                    !reg_map_can_allocate;
            wire issue_accept = candidate_valid && candidate_clear && !flush_i;
            wire can_dispatch = exec_clear_i &&
                                candidate_unit_ready &&
                                reg_map_can_allocate;
            wire unused_reg_map_hazards = |{
                reg_map_war_hazard,
                reg_map_read_full_hazard
            };

            openrv64_dispatch_reg_map #(
                .ENABLE_FORWARDING(ENABLE_FORWARDING)
            ) u_reg_map (
                .clk(clk),
                .rst_n(rst_n),
                .clear_i(flush_i),
                .alloc_valid_i(candidate_valid && !flush_i),
                .alloc_fire_i(issue_accept),
                .alloc_uses_rs1_i(candidate_uses_rs1),
                .alloc_uses_rs2_i(candidate_uses_rs2),
                .alloc_rs1_addr_i(candidate_rs1_addr),
                .alloc_rs2_addr_i(candidate_rs2_addr),
                .alloc_reg_write_i(candidate_writes_rd),
                .alloc_rd_addr_i(candidate_rd_addr),
                .alloc_read_hot_i(32'h0000_0000),
                .forward_ex_write_hot_i(32'h0000_0000),
                .forward_mem_write_hot_i(forward_mem_write_hot),
                .alloc_read_hot_o(unused_alloc_read_hot),
                .retire_valid_i(retire_valid_i),
                .retire_uses_rs1_i(retire_uses_rs1_i),
                .retire_uses_rs2_i(retire_uses_rs2_i),
                .retire_rs1_addr_i(retire_rs1_addr_i),
                .retire_rs2_addr_i(retire_rs2_addr_i),
                .retire_reg_write_i(retire_reg_write_i),
                .retire_rd_addr_i(retire_rd_addr_i),
                .rollback_valid_i(1'b0),
                .rollback_uses_rs1_i(1'b0),
                .rollback_uses_rs2_i(1'b0),
                .rollback_rs1_addr_i(`RV64_REG_X0),
                .rollback_rs2_addr_i(`RV64_REG_X0),
                .rollback_reg_write_i(1'b0),
                .rollback_rd_addr_i(`RV64_REG_X0),
                .raw_hazard_o(reg_map_raw_hazard),
                .war_hazard_o(reg_map_war_hazard),
                .waw_hazard_o(reg_map_waw_hazard),
                .read_full_hazard_o(reg_map_read_full_hazard),
                .can_allocate_o(reg_map_can_allocate)
            );

            assign raw_hazard_o = candidate_valid && !flush_i &&
                                  reg_map_raw_hazard;
            assign waw_hazard_o = candidate_valid && !flush_i &&
                                  reg_map_waw_hazard;
            assign scoreboard_stall_o = scoreboard_stall;
            assign candidate_clear = flush_i ||
                                     (can_dispatch &&
                                      !csr_active &&
                                      !fence_active);
            assign exec_valid_o = candidate_valid &&
                                  !flush_i &&
                                  !csr_active &&
                                  !fence_active &&
                                  !scoreboard_stall;
            assign exec_data = exec_valid_o ? candidate_data :
                                               {DISPATCH_WIDTH{1'b0}};
        end
    endgenerate

endmodule
