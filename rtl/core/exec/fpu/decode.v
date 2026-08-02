`ifndef OPENRV64_DECODE_FD_V
`define OPENRV64_DECODE_FD_V
`timescale 1ns/1ps

`include "core/exec/fpu/isa/rv64-d.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/exec/fpu/defs.v"

// F/D client of the generic extension-decode contract.  early.v only identifies an otherwise-unowned
// 32-bit opcode as an extension candidate.  The detailed decoder below owns
// F/D opcode selection, funct-field legality, and typed register metadata.
module openrv64_decode_fd #(
    parameter ENABLE_RV64F = 0,
    parameter ENABLE_RV64D = 0
) (
    input  wire                         candidate_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output wire                         selected_o,
    output wire                         valid_o,
    output wire                         illegal_o,
    output wire [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel_o,
    output wire [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_o,

    output wire                         uses_rs1_o,
    output wire                         uses_rs2_o,
    output wire                         uses_rs3_o,
    output wire                         uses_rd_o,
    output wire                         src1_fp_o,
    output wire                         src2_fp_o,
    output wire                         src3_fp_o,
    output wire                         reg_write_o,
    output wire                         fp_reg_write_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o,

    output wire                         imm_valid_o,
    output wire                         has_imm_o,
    output wire [`RV64_XLEN-1:0]        imm_o,
    output wire                         mem_read_o,
    output wire                         mem_write_o,
    output wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_sel_o,
    output wire [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size_sel_o,

    output wire [`OPENRV64_FP_OP_WIDTH-1:0] fp_op_sel_o,
    output wire [1:0]                   fp_fmt_o,
    output wire [2:0]                   fp_rm_o,
    output wire [4:0]                   fp_type_o,
    output wire                         fp_fflags_write_o
);

    wire fd_selected;
    wire fd_valid;
    wire fd_illegal;

    openrv64_decode_rv64fd #(
        .ENABLE_RV64F(ENABLE_RV64F),
        .ENABLE_RV64D(ENABLE_RV64D)
    ) u_rv64fd (
        .instr_i(instr_i),
        .selected_o(fd_selected),
        .valid_o(fd_valid),
        .illegal_o(fd_illegal),
        .class_sel_o(class_sel_o),
        .format_sel_o(format_sel_o),
        .uses_rs1_o(uses_rs1_o),
        .uses_rs2_o(uses_rs2_o),
        .uses_rs3_o(uses_rs3_o),
        .uses_rd_o(uses_rd_o),
        .src1_fp_o(src1_fp_o),
        .src2_fp_o(src2_fp_o),
        .src3_fp_o(src3_fp_o),
        .reg_write_o(reg_write_o),
        .fp_reg_write_o(fp_reg_write_o),
        .rs1_addr_o(rs1_addr_o),
        .rs2_addr_o(rs2_addr_o),
        .rs3_addr_o(rs3_addr_o),
        .rd_addr_o(rd_addr_o),
        .imm_valid_o(imm_valid_o),
        .has_imm_o(has_imm_o),
        .imm_o(imm_o),
        .mem_read_o(mem_read_o),
        .mem_write_o(mem_write_o),
        .lsu_op_sel_o(lsu_op_sel_o),
        .lsu_size_sel_o(lsu_size_sel_o),
        .fp_op_sel_o(fp_op_sel_o),
        .fp_fmt_o(fp_fmt_o),
        .fp_rm_o(fp_rm_o),
        .fp_type_o(fp_type_o),
        .fp_fflags_write_o(fp_fflags_write_o)
    );

    assign selected_o = candidate_i && fd_selected;
    assign valid_o = selected_o && fd_valid && !fd_illegal;
    assign illegal_o = selected_o && (!fd_valid || fd_illegal);

endmodule

`endif
