`ifndef OPENRV64_FPU_DECODE_TOP_V
`define OPENRV64_FPU_DECODE_TOP_V
`timescale 1ns/1ps

`include "core/exec/fpu/isa/rv64-d.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/exec/fpu/defs.v"

// F/D composition of the generic integer decoder and extension-decode
// contract.  The integer decoder sees only an opaque extension payload; all
// interpretation of the payload remains below rtl/core/exec/fpu.
module openrv64_fpu_decode_top #(
    parameter ENABLE_RV64M = 1,
    parameter ENABLE_RV64A = 1,
    parameter ENABLE_RV64F = 0,
    parameter ENABLE_RV64D = 0
) (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output wire                         valid_o,
    output wire                         illegal_o,
    output wire [`RV64_OPCODE_WIDTH-1:0] opcode_o,
    output wire [`RV64_FUNCT3_WIDTH-1:0] funct3_o,
    output wire [`RV64_FUNCT7_WIDTH-1:0] funct7_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] funct12_o,
    output wire [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel_o,
    output wire [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_o,

    output wire                         uses_rs1_o,
    output wire                         uses_rs2_o,
    output wire                         uses_rd_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o,
    output wire                         reg_write_o,

    output wire                         imm_valid_o,
    output wire                         has_imm_o,
    output wire [`RV64_XLEN-1:0]        imm_o,
    output wire                         mem_read_o,
    output wire                         mem_write_o,
    output wire                         branch_o,
    output wire                         jump_o,
    output wire                         word_op_o,
    output wire                         system_o,
    output wire                         fence_o,

    output wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext_sel_o,
    output wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_sel_o,
    output wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_sel_o,
    output wire [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size_sel_o,
    output wire                         lsu_unsigned_o,
    output wire [`RV64_BR_OP_WIDTH-1:0] br_op_sel_o,
    output wire                         br_link_o,
    output wire                         br_indirect_o,
    output wire                         subdecode_needed_o,
    output wire                         extension_decode_possible_o,

    output wire                         fp_instr_o,
    output wire                         uses_rs3_o,
    output wire                         src1_fp_o,
    output wire                         src2_fp_o,
    output wire                         src3_fp_o,
    output wire                         fp_reg_write_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr_o,
    output wire [`OPENRV64_FP_OP_WIDTH-1:0] fp_op_sel_o,
    output wire [1:0]                   fp_fmt_o,
    output wire [2:0]                   fp_rm_o,
    output wire [4:0]                   fp_type_o,
    output wire                         fp_fflags_write_o,
    output wire [`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH-1:0]
                                        extension_payload_o
);

    wire extension_candidate;
    wire fd_selected;
    wire fd_valid;
    wire fd_illegal;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] fd_class;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] fd_format;
    wire fd_uses_rs1;
    wire fd_uses_rs2;
    wire fd_uses_rs3;
    wire fd_uses_rd;
    wire fd_src1_fp;
    wire fd_src2_fp;
    wire fd_src3_fp;
    wire fd_gpr_write;
    wire fd_fpr_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] fd_rs1;
    wire [`RV64_REG_ADDR_WIDTH-1:0] fd_rs2;
    wire [`RV64_REG_ADDR_WIDTH-1:0] fd_rs3;
    wire [`RV64_REG_ADDR_WIDTH-1:0] fd_rd;
    wire fd_imm_valid;
    wire fd_has_imm;
    wire [`RV64_XLEN-1:0] fd_imm;
    wire fd_mem_read;
    wire fd_mem_write;
    wire [`RV64_LSU_OP_WIDTH-1:0] fd_lsu_op;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] fd_lsu_size;
    wire [`OPENRV64_FP_OP_WIDTH-1:0] fd_op;
    wire [1:0] fd_fmt;
    wire [2:0] fd_rm;
    wire [4:0] fd_type;
    wire fd_fflags_write;

    wire [`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH-1:0] fd_payload;
    assign fd_payload = {
        fd_mem_write,
        fd_mem_read,
        fd_type,
        fd_rm,
        fd_fmt,
        fd_op,
        fd_rs3,
        fd_fflags_write,
        fd_fpr_write,
        fd_uses_rs3,
        fd_src3_fp,
        fd_src2_fp,
        fd_src1_fp
    };

    openrv64_decode_fd #(
        .ENABLE_RV64F(ENABLE_RV64F),
        .ENABLE_RV64D(ENABLE_RV64D)
    ) u_fd (
        .candidate_i(extension_candidate),
        .instr_i(instr_i),
        .selected_o(fd_selected),
        .valid_o(fd_valid),
        .illegal_o(fd_illegal),
        .class_sel_o(fd_class),
        .format_sel_o(fd_format),
        .uses_rs1_o(fd_uses_rs1),
        .uses_rs2_o(fd_uses_rs2),
        .uses_rs3_o(fd_uses_rs3),
        .uses_rd_o(fd_uses_rd),
        .src1_fp_o(fd_src1_fp),
        .src2_fp_o(fd_src2_fp),
        .src3_fp_o(fd_src3_fp),
        .reg_write_o(fd_gpr_write),
        .fp_reg_write_o(fd_fpr_write),
        .rs1_addr_o(fd_rs1),
        .rs2_addr_o(fd_rs2),
        .rs3_addr_o(fd_rs3),
        .rd_addr_o(fd_rd),
        .imm_valid_o(fd_imm_valid),
        .has_imm_o(fd_has_imm),
        .imm_o(fd_imm),
        .mem_read_o(fd_mem_read),
        .mem_write_o(fd_mem_write),
        .lsu_op_sel_o(fd_lsu_op),
        .lsu_size_sel_o(fd_lsu_size),
        .fp_op_sel_o(fd_op),
        .fp_fmt_o(fd_fmt),
        .fp_rm_o(fd_rm),
        .fp_type_o(fd_type),
        .fp_fflags_write_o(fd_fflags_write)
    );

    openrv64_decode_top #(
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .ENABLE_EXTENSION(1),
        .EXTENSION_PAYLOAD_WIDTH(`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH)
    ) u_integer_decode (
        .instr_i(instr_i),
        .extension_selected_i(fd_selected),
        .extension_valid_i(fd_valid),
        .extension_illegal_i(fd_illegal),
        .extension_class_sel_i(fd_class),
        .extension_format_sel_i(fd_format),
        .extension_uses_rs1_i(fd_uses_rs1),
        .extension_uses_rs2_i(fd_uses_rs2),
        .extension_uses_rd_i(fd_uses_rd),
        .extension_rs1_addr_i(fd_rs1),
        .extension_rs2_addr_i(fd_rs2),
        .extension_rd_addr_i(fd_rd),
        .extension_reg_write_i(fd_gpr_write),
        .extension_imm_valid_i(fd_imm_valid),
        .extension_has_imm_i(fd_has_imm),
        .extension_imm_i(fd_imm),
        .extension_mem_read_i(fd_mem_read),
        .extension_mem_write_i(fd_mem_write),
        .extension_lsu_op_sel_i(fd_lsu_op),
        .extension_lsu_size_sel_i(fd_lsu_size),
        .extension_lsu_unsigned_i(1'b0),
        .extension_payload_i(fd_payload),
        .valid_o(valid_o),
        .illegal_o(illegal_o),
        .opcode_o(opcode_o),
        .funct3_o(funct3_o),
        .funct7_o(funct7_o),
        .funct12_o(funct12_o),
        .class_sel_o(class_sel_o),
        .format_sel_o(format_sel_o),
        .uses_rs1_o(uses_rs1_o),
        .uses_rs2_o(uses_rs2_o),
        .uses_rd_o(uses_rd_o),
        .rs1_addr_o(rs1_addr_o),
        .rs2_addr_o(rs2_addr_o),
        .rd_addr_o(rd_addr_o),
        .reg_write_o(reg_write_o),
        .imm_valid_o(imm_valid_o),
        .has_imm_o(has_imm_o),
        .imm_o(imm_o),
        .mem_read_o(mem_read_o),
        .mem_write_o(mem_write_o),
        .branch_o(branch_o),
        .jump_o(jump_o),
        .word_op_o(word_op_o),
        .system_o(system_o),
        .fence_o(fence_o),
        .alu_ext_sel_o(alu_ext_sel_o),
        .alu_op_sel_o(alu_op_sel_o),
        .lsu_op_sel_o(lsu_op_sel_o),
        .lsu_size_sel_o(lsu_size_sel_o),
        .lsu_unsigned_o(lsu_unsigned_o),
        .br_op_sel_o(br_op_sel_o),
        .br_link_o(br_link_o),
        .br_indirect_o(br_indirect_o),
        .subdecode_needed_o(subdecode_needed_o),
        .extension_decode_possible_o(extension_decode_possible_o),
        .extension_candidate_o(extension_candidate),
        .extension_instr_o(fp_instr_o),
        .extension_payload_o(extension_payload_o)
    );

    assign uses_rs3_o = fp_instr_o && fd_uses_rs3;
    assign src1_fp_o = fp_instr_o && fd_src1_fp;
    assign src2_fp_o = fp_instr_o && fd_src2_fp;
    assign src3_fp_o = fp_instr_o && fd_src3_fp;
    assign fp_reg_write_o = fp_instr_o && fd_fpr_write;
    assign rs3_addr_o = uses_rs3_o ? fd_rs3 : `RV64_REG_X0;
    assign fp_op_sel_o = fp_instr_o ? fd_op : `OPENRV64_FP_OP_INVALID;
    assign fp_fmt_o = fp_instr_o ? fd_fmt : `RV64_FP_FMT_S;
    assign fp_rm_o = fp_instr_o ? fd_rm : `RV64_FP_RM_RNE;
    assign fp_type_o = fp_instr_o ? fd_type : 5'd0;
    assign fp_fflags_write_o = fp_instr_o && fd_fflags_write;

endmodule

`endif
