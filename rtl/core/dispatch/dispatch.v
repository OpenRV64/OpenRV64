`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_dispatch #(
    parameter REGISTERED = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         decode_valid_i,
    output wire                         decode_clear_o,
    input  wire [`RV64_XLEN-1:0]        decode_pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] decode_instr_i,
    input  wire [`RV64_XLEN-1:0]        decode_rs1_data_i,
    input  wire [`RV64_XLEN-1:0]        decode_rs2_data_i,
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
    input  wire                         decode_word_op_i,
    input  wire                         decode_system_i,
    input  wire                         decode_fence_i,
    input  wire                         decode_illegal_i,
    input  wire                         decode_ebreak_i,
    input  wire                         decode_ecall_i,

    output wire                         exec_valid_o,
    input  wire                         exec_clear_i,
    input  wire                         exec_alu_ready_i,
    input  wire                         exec_lsu_ready_i,
    input  wire                         exec_br_ready_i,
    input  wire                         exec_system_ready_i,
    output wire [`RV64_XLEN-1:0]        exec_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] exec_instr_o,
    output wire [`RV64_XLEN-1:0]        exec_rs1_data_o,
    output wire [`RV64_XLEN-1:0]        exec_rs2_data_o,
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
    output wire                         exec_word_op_o,
    output wire                         exec_system_o,
    output wire                         exec_fence_o,
    output wire                         exec_illegal_o,
    output wire                         exec_ebreak_o,
    output wire                         exec_ecall_o,

    input  wire                         wb_valid_i,
    input  wire                         wb_reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr_i,

    output wire                         raw_hazard_o,
    output wire                         waw_hazard_o,
    output wire                         scoreboard_stall_o
);

    localparam DISPATCH_WIDTH = 320;

    wire decode_writes_rd = decode_reg_write_i &&
                            !decode_illegal_i &&
                            !decode_ebreak_i &&
                            (decode_rd_addr_i != `RV64_REG_X0);
    wire decode_uses_lsu_unit = decode_mem_read_i || decode_mem_write_i;
    wire decode_uses_br_unit = decode_branch_i || decode_jump_i;
    wire decode_uses_system_unit = decode_system_i ||
                                   decode_fence_i ||
                                   decode_illegal_i ||
                                   decode_ebreak_i ||
                                   decode_ecall_i;
    wire decode_unit_ready = decode_uses_br_unit ? exec_br_ready_i :
                             decode_uses_lsu_unit ? exec_lsu_ready_i :
                             decode_uses_system_unit ? exec_system_ready_i :
                             exec_alu_ready_i;
    wire wb_clears_rd = wb_valid_i &&
                        wb_reg_write_i &&
                        (wb_rd_addr_i != `RV64_REG_X0);
    wire [31:0] wb_clear_mask = wb_clears_rd ?
                                (32'h0000_0001 << wb_rd_addr_i) :
                                32'h0000_0000;
    wire [DISPATCH_WIDTH-1:0] decode_data = {
        decode_pc_i,
        decode_instr_i,
        decode_rs1_data_i,
        decode_rs2_data_i,
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
        decode_word_op_i,
        decode_system_i,
        decode_fence_i,
        decode_illegal_i,
        decode_ebreak_i,
        decode_ecall_i
    };

    wire [DISPATCH_WIDTH-1:0] exec_data;

    assign {
        exec_pc_o,
        exec_instr_o,
        exec_rs1_data_o,
        exec_rs2_data_o,
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
        exec_word_op_o,
        exec_system_o,
        exec_fence_o,
        exec_illegal_o,
        exec_ebreak_o,
        exec_ecall_o
    } = exec_data;

    generate
        if (REGISTERED != 0) begin : g_registered
            reg                         active_q;
            reg [DISPATCH_WIDTH-1:0]    data_q;
            reg [31:0]                  busy_q;
            reg                         active_reg_write_q;
            reg [`RV64_REG_ADDR_WIDTH-1:0] active_rd_addr_q;
            reg                         active_uses_lsu_unit_q;
            reg                         active_uses_br_unit_q;
            reg                         active_uses_system_unit_q;

            wire active_writes_rd = active_q &&
                                    active_reg_write_q &&
                                    (active_rd_addr_q != `RV64_REG_X0);
            wire [31:0] active_flush_mask = (flush_i && active_writes_rd) ?
                                            (32'h0000_0001 << active_rd_addr_q) :
                                            32'h0000_0000;
            wire [31:0] busy_after_clears = busy_q &
                                            ~wb_clear_mask &
                                            ~active_flush_mask;
            wire rs1_busy = decode_uses_rs1_i &&
                            (decode_rs1_addr_i != `RV64_REG_X0) &&
                            busy_after_clears[decode_rs1_addr_i];
            wire rs2_busy = decode_uses_rs2_i &&
                            (decode_rs2_addr_i != `RV64_REG_X0) &&
                            busy_after_clears[decode_rs2_addr_i];
            wire rd_busy = decode_writes_rd &&
                           busy_after_clears[decode_rd_addr_i];
            wire active_unit_ready = active_uses_br_unit_q ? exec_br_ready_i :
                                     active_uses_lsu_unit_q ? exec_lsu_ready_i :
                                     active_uses_system_unit_q ? exec_system_ready_i :
                                     exec_alu_ready_i;
            wire exec_accept = exec_clear_i && active_unit_ready;
            wire stage_can_accept = !active_q || exec_accept;
            wire scoreboard_stall = decode_valid_i && !flush_i &&
                                    (rs1_busy || rs2_busy || rd_busy);
            wire capture = decode_valid_i && decode_clear_o && !flush_i;
            wire [31:0] decode_set_mask = (capture && decode_writes_rd) ?
                                          (32'h0000_0001 << decode_rd_addr_i) :
                                          32'h0000_0000;

            assign raw_hazard_o = decode_valid_i && !flush_i && (rs1_busy || rs2_busy);
            assign waw_hazard_o = decode_valid_i && !flush_i && rd_busy;
            assign scoreboard_stall_o = scoreboard_stall;
            assign decode_clear_o = flush_i ||
                                    (stage_can_accept && decode_unit_ready && !scoreboard_stall);
            assign exec_valid_o = active_q && !flush_i && active_unit_ready;
            assign exec_data = exec_valid_o ? data_q : {DISPATCH_WIDTH{1'b0}};

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    active_q           <= 1'b0;
                    data_q             <= {DISPATCH_WIDTH{1'b0}};
                    busy_q             <= 32'h0000_0000;
                    active_reg_write_q <= 1'b0;
                    active_rd_addr_q   <= `RV64_REG_X0;
                    active_uses_lsu_unit_q <= 1'b0;
                    active_uses_br_unit_q <= 1'b0;
                    active_uses_system_unit_q <= 1'b0;
                end else begin
                    busy_q <= busy_after_clears | decode_set_mask;

                    if (flush_i) begin
                        active_q           <= 1'b0;
                        data_q             <= {DISPATCH_WIDTH{1'b0}};
                        active_reg_write_q <= 1'b0;
                        active_rd_addr_q   <= `RV64_REG_X0;
                        active_uses_lsu_unit_q <= 1'b0;
                        active_uses_br_unit_q <= 1'b0;
                        active_uses_system_unit_q <= 1'b0;
                    end else if (decode_clear_o) begin
                        active_q <= decode_valid_i;

                        if (decode_valid_i) begin
                            data_q             <= decode_data;
                            active_reg_write_q <= decode_writes_rd;
                            active_rd_addr_q   <= decode_rd_addr_i;
                            active_uses_lsu_unit_q <= decode_uses_lsu_unit;
                            active_uses_br_unit_q <= decode_uses_br_unit;
                            active_uses_system_unit_q <= decode_uses_system_unit;
                        end else begin
                            active_reg_write_q <= 1'b0;
                            active_rd_addr_q   <= `RV64_REG_X0;
                            active_uses_lsu_unit_q <= 1'b0;
                            active_uses_br_unit_q <= 1'b0;
                            active_uses_system_unit_q <= 1'b0;
                        end
                    end
                end
            end
        end else begin : g_bypass
            reg [31:0] busy_q;

            wire [31:0] busy_after_wb = busy_q & ~wb_clear_mask;
            wire rs1_busy = decode_uses_rs1_i &&
                            (decode_rs1_addr_i != `RV64_REG_X0) &&
                            busy_after_wb[decode_rs1_addr_i];
            wire rs2_busy = decode_uses_rs2_i &&
                            (decode_rs2_addr_i != `RV64_REG_X0) &&
                            busy_after_wb[decode_rs2_addr_i];
            wire rd_busy = decode_writes_rd &&
                           busy_after_wb[decode_rd_addr_i];
            wire scoreboard_stall = decode_valid_i && !flush_i &&
                                    (rs1_busy || rs2_busy || rd_busy);
            wire issue_accept = exec_valid_o && exec_clear_i;
            wire [31:0] decode_set_mask = (issue_accept && decode_writes_rd) ?
                                          (32'h0000_0001 << decode_rd_addr_i) :
                                          32'h0000_0000;

            assign raw_hazard_o = decode_valid_i && !flush_i && (rs1_busy || rs2_busy);
            assign waw_hazard_o = decode_valid_i && !flush_i && rd_busy;
            assign scoreboard_stall_o = scoreboard_stall;
            assign decode_clear_o = flush_i ||
                                    (exec_clear_i && decode_unit_ready && !scoreboard_stall);
            assign exec_valid_o = decode_valid_i &&
                                  !flush_i &&
                                  decode_unit_ready &&
                                  !scoreboard_stall;
            assign exec_data = exec_valid_o ? decode_data : {DISPATCH_WIDTH{1'b0}};

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    busy_q <= 32'h0000_0000;
                end else if (flush_i) begin
                    busy_q <= busy_after_wb;
                end else begin
                    busy_q <= busy_after_wb | decode_set_mask;
                end
            end
        end
    endgenerate

endmodule
