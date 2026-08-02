`ifndef OPENRV64_DECODE_RV64_FD_V
`define OPENRV64_DECODE_RV64_FD_V
`timescale 1ns/1ps

`include "core/exec/fpu/isa/rv64-d.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/exec/fpu/defs.v"

// FPU-owned typed RV64F/RV64D decode.  Register-use outputs describe architectural
// operands; src*_fp_o and fp_reg_write_o identify their register-file domain.
// Dynamic rounding-mode legality depends on frm and is therefore checked when
// the instruction issues, not here.
module openrv64_decode_rv64fd #(
    parameter ENABLE_RV64F = 0,
    parameter ENABLE_RV64D = 0
) (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output reg                          selected_o,
    output reg                          valid_o,
    output reg                          illegal_o,
    output reg [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel_o,
    output reg [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_o,

    output reg                          uses_rs1_o,
    output reg                          uses_rs2_o,
    output reg                          uses_rs3_o,
    output reg                          uses_rd_o,
    output reg                          src1_fp_o,
    output reg                          src2_fp_o,
    output reg                          src3_fp_o,
    output reg                          reg_write_o,
    output reg                          fp_reg_write_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o,

    output reg                          imm_valid_o,
    output reg                          has_imm_o,
    output reg [`RV64_XLEN-1:0]         imm_o,
    output reg                          mem_read_o,
    output reg                          mem_write_o,
    output reg [`RV64_LSU_OP_WIDTH-1:0] lsu_op_sel_o,
    output reg [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size_sel_o,

    output reg [`OPENRV64_FP_OP_WIDTH-1:0] fp_op_sel_o,
    output reg [1:0]                    fp_fmt_o,
    output reg [2:0]                    fp_rm_o,
    output reg [4:0]                    fp_type_o,
    output reg                          fp_fflags_write_o
);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire [`RV64_FUNCT3_WIDTH-1:0] funct3 = `RV64_FUNCT3(instr_i);
    wire [4:0] funct5 = instr_i[31:27];
    wire [1:0] fmt = `RV64_FP_FMT(instr_i);
    wire [2:0] rm = `RV64_FP_RM(instr_i);
    wire [4:0] rs2 = `RV64_RS2(instr_i);

    function automatic format_enabled;
        input [1:0] format;
        begin
            case (format)
                `RV64_FP_FMT_S: format_enabled = ENABLE_RV64F;
                `RV64_FP_FMT_D: format_enabled = ENABLE_RV64F && ENABLE_RV64D;
                default:        format_enabled = 1'b0;
            endcase
        end
    endfunction

    function automatic rounding_valid;
        input [2:0] rounding;
        begin
            rounding_valid = (rounding <= `RV64_FP_RM_RMM) ||
                             (rounding == `RV64_FP_RM_DYN);
        end
    endfunction

    function automatic integer_type_valid;
        input [4:0] int_type;
        begin
            integer_type_valid =
                (int_type == `RV64_FP_RS2_W) ||
                (int_type == `RV64_FP_RS2_WU) ||
                (int_type == `RV64_FP_RS2_L) ||
                (int_type == `RV64_FP_RS2_LU);
        end
    endfunction

    task automatic accept_fp_binary;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        input writes_flags;
        begin
            if (format_enabled(fmt)) begin
                valid_o = 1'b1;
                illegal_o = 1'b0;
                uses_rs1_o = 1'b1;
                uses_rs2_o = 1'b1;
                uses_rd_o = 1'b1;
                src1_fp_o = 1'b1;
                src2_fp_o = 1'b1;
                fp_reg_write_o = 1'b1;
                fp_op_sel_o = operation;
                fp_fflags_write_o = writes_flags;
            end
        end
    endtask

    task automatic accept_fp_binary_rounded;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        begin
            if (format_enabled(fmt) && rounding_valid(rm))
                accept_fp_binary(operation, 1'b1);
        end
    endtask

    task automatic accept_fma;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        begin
            if (format_enabled(fmt) && rounding_valid(rm)) begin
                valid_o = 1'b1;
                illegal_o = 1'b0;
                uses_rs1_o = 1'b1;
                uses_rs2_o = 1'b1;
                uses_rs3_o = 1'b1;
                uses_rd_o = 1'b1;
                src1_fp_o = 1'b1;
                src2_fp_o = 1'b1;
                src3_fp_o = 1'b1;
                fp_reg_write_o = 1'b1;
                fp_op_sel_o = operation;
                fp_fflags_write_o = 1'b1;
            end
        end
    endtask

    always @* begin
        selected_o = 1'b0;
        valid_o = 1'b0;
        illegal_o = 1'b0;
        class_sel_o = `RV64_EARLY_CLASS_INVALID;
        format_sel_o = `RV64_EARLY_FORMAT_INVALID;

        uses_rs1_o = 1'b0;
        uses_rs2_o = 1'b0;
        uses_rs3_o = 1'b0;
        uses_rd_o = 1'b0;
        src1_fp_o = 1'b0;
        src2_fp_o = 1'b0;
        src3_fp_o = 1'b0;
        reg_write_o = 1'b0;
        fp_reg_write_o = 1'b0;
        rs1_addr_o = `RV64_RS1(instr_i);
        rs2_addr_o = `RV64_RS2(instr_i);
        rs3_addr_o = `RV64_FP_RS3(instr_i);
        rd_addr_o = `RV64_RD(instr_i);

        imm_valid_o = 1'b0;
        has_imm_o = 1'b0;
        imm_o = {`RV64_XLEN{1'b0}};
        mem_read_o = 1'b0;
        mem_write_o = 1'b0;
        lsu_op_sel_o = `RV64_LSU_OP_INVALID;
        lsu_size_sel_o = `RV64_LSU_SIZE_BYTE;

        fp_op_sel_o = `OPENRV64_FP_OP_INVALID;
        fp_fmt_o = fmt;
        fp_rm_o = rm;
        fp_type_o = 5'd0;
        fp_fflags_write_o = 1'b0;

        case (opcode)
            `RV64_FP_OPCODE_LOAD: begin
                selected_o = 1'b1;
                illegal_o = 1'b1;
                class_sel_o = `RV64_EARLY_CLASS_MEM;
                format_sel_o = `RV64_EARLY_FORMAT_I;
                imm_valid_o = 1'b1;
                has_imm_o = 1'b1;
                imm_o = `RV64_IMM_I(instr_i);
                if ((funct3 == `RV64_FP_FUNCT3_FLW_FSW) && ENABLE_RV64F) begin
                    valid_o = 1'b1;
                    illegal_o = 1'b0;
                    uses_rs1_o = 1'b1;
                    uses_rd_o = 1'b1;
                    fp_reg_write_o = 1'b1;
                    mem_read_o = 1'b1;
                    lsu_op_sel_o = `RV64_LSU_OP_LWU;
                    lsu_size_sel_o = `RV64_LSU_SIZE_WORD;
                    fp_fmt_o = `RV64_FP_FMT_S;
                end else if ((funct3 == `RV64_FP_FUNCT3_FLD_FSD) &&
                             ENABLE_RV64F && ENABLE_RV64D) begin
                    valid_o = 1'b1;
                    illegal_o = 1'b0;
                    uses_rs1_o = 1'b1;
                    uses_rd_o = 1'b1;
                    fp_reg_write_o = 1'b1;
                    mem_read_o = 1'b1;
                    lsu_op_sel_o = `RV64_LSU_OP_LD;
                    lsu_size_sel_o = `RV64_LSU_SIZE_DWORD;
                    fp_fmt_o = `RV64_FP_FMT_D;
                end
            end

            `RV64_FP_OPCODE_STORE: begin
                selected_o = 1'b1;
                illegal_o = 1'b1;
                class_sel_o = `RV64_EARLY_CLASS_MEM;
                format_sel_o = `RV64_EARLY_FORMAT_S;
                imm_valid_o = 1'b1;
                has_imm_o = 1'b1;
                imm_o = `RV64_IMM_S(instr_i);
                if ((funct3 == `RV64_FP_FUNCT3_FLW_FSW) && ENABLE_RV64F) begin
                    valid_o = 1'b1;
                    illegal_o = 1'b0;
                    uses_rs1_o = 1'b1;
                    uses_rs2_o = 1'b1;
                    src2_fp_o = 1'b1;
                    mem_write_o = 1'b1;
                    lsu_op_sel_o = `RV64_LSU_OP_SW;
                    lsu_size_sel_o = `RV64_LSU_SIZE_WORD;
                    fp_fmt_o = `RV64_FP_FMT_S;
                end else if ((funct3 == `RV64_FP_FUNCT3_FLD_FSD) &&
                             ENABLE_RV64F && ENABLE_RV64D) begin
                    valid_o = 1'b1;
                    illegal_o = 1'b0;
                    uses_rs1_o = 1'b1;
                    uses_rs2_o = 1'b1;
                    src2_fp_o = 1'b1;
                    mem_write_o = 1'b1;
                    lsu_op_sel_o = `RV64_LSU_OP_SD;
                    lsu_size_sel_o = `RV64_LSU_SIZE_DWORD;
                    fp_fmt_o = `RV64_FP_FMT_D;
                end
            end

            `RV64_FP_OPCODE_MADD,
            `RV64_FP_OPCODE_MSUB,
            `RV64_FP_OPCODE_NMSUB,
            `RV64_FP_OPCODE_NMADD: begin
                selected_o = 1'b1;
                illegal_o = 1'b1;
                class_sel_o = `RV64_EARLY_CLASS_EXTENSION;
                format_sel_o = `RV64_EARLY_FORMAT_R;
                imm_valid_o = 1'b1;
                case (opcode)
                    `RV64_FP_OPCODE_MADD:  accept_fma(`OPENRV64_FP_OP_MADD);
                    `RV64_FP_OPCODE_MSUB:  accept_fma(`OPENRV64_FP_OP_MSUB);
                    `RV64_FP_OPCODE_NMSUB: accept_fma(`OPENRV64_FP_OP_NMSUB);
                    default:               accept_fma(`OPENRV64_FP_OP_NMADD);
                endcase
            end

            `RV64_FP_OPCODE_OP: begin
                selected_o = 1'b1;
                illegal_o = 1'b1;
                class_sel_o = `RV64_EARLY_CLASS_EXTENSION;
                format_sel_o = `RV64_EARLY_FORMAT_R;
                imm_valid_o = 1'b1;

                case (funct5)
                    `RV64_FP_FUNCT5_ADD:
                        accept_fp_binary_rounded(`OPENRV64_FP_OP_ADD);
                    `RV64_FP_FUNCT5_SUB:
                        accept_fp_binary_rounded(`OPENRV64_FP_OP_SUB);
                    `RV64_FP_FUNCT5_MUL:
                        accept_fp_binary_rounded(`OPENRV64_FP_OP_MUL);
                    `RV64_FP_FUNCT5_DIV:
                        accept_fp_binary_rounded(`OPENRV64_FP_OP_DIV);

                    `RV64_FP_FUNCT5_SQRT: begin
                        if (format_enabled(fmt) &&
                            (rs2 == `RV64_FP_RS2_ZERO) && rounding_valid(rm)) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            src1_fp_o = 1'b1;
                            fp_reg_write_o = 1'b1;
                            fp_op_sel_o = `OPENRV64_FP_OP_SQRT;
                            fp_fflags_write_o = 1'b1;
                        end
                    end

                    `RV64_FP_FUNCT5_SGNJ: begin
                        case (funct3)
                            `RV64_FP_FUNCT3_SGNJ:
                                accept_fp_binary(`OPENRV64_FP_OP_SGNJ, 1'b0);
                            `RV64_FP_FUNCT3_SGNJN:
                                accept_fp_binary(`OPENRV64_FP_OP_SGNJN, 1'b0);
                            `RV64_FP_FUNCT3_SGNJX:
                                accept_fp_binary(`OPENRV64_FP_OP_SGNJX, 1'b0);
                            default: begin
                            end
                        endcase
                    end

                    `RV64_FP_FUNCT5_MINMAX: begin
                        case (funct3)
                            `RV64_FP_FUNCT3_MIN:
                                accept_fp_binary(`OPENRV64_FP_OP_MIN, 1'b1);
                            `RV64_FP_FUNCT3_MAX:
                                accept_fp_binary(`OPENRV64_FP_OP_MAX, 1'b1);
                            default: begin
                            end
                        endcase
                    end

                    `RV64_FP_FUNCT5_COMPARE: begin
                        if (format_enabled(fmt)) begin
                            case (funct3)
                                `RV64_FP_FUNCT3_FLE: begin
                                    valid_o = 1'b1;
                                    fp_op_sel_o = `OPENRV64_FP_OP_LE;
                                end
                                `RV64_FP_FUNCT3_FLT: begin
                                    valid_o = 1'b1;
                                    fp_op_sel_o = `OPENRV64_FP_OP_LT;
                                end
                                `RV64_FP_FUNCT3_FEQ: begin
                                    valid_o = 1'b1;
                                    fp_op_sel_o = `OPENRV64_FP_OP_EQ;
                                end
                                default: begin
                                end
                            endcase
                            if (valid_o) begin
                                illegal_o = 1'b0;
                                uses_rs1_o = 1'b1;
                                uses_rs2_o = 1'b1;
                                uses_rd_o = 1'b1;
                                src1_fp_o = 1'b1;
                                src2_fp_o = 1'b1;
                                reg_write_o = 1'b1;
                                fp_fflags_write_o = 1'b1;
                            end
                        end
                    end

                    `RV64_FP_FUNCT5_CVT_TO_INT: begin
                        if (format_enabled(fmt) && integer_type_valid(rs2) &&
                            rounding_valid(rm)) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            src1_fp_o = 1'b1;
                            reg_write_o = 1'b1;
                            fp_op_sel_o = `OPENRV64_FP_OP_CVT_TO_INT;
                            fp_type_o = rs2;
                            fp_fflags_write_o = 1'b1;
                        end
                    end

                    `RV64_FP_FUNCT5_CVT_FROM_INT: begin
                        if (format_enabled(fmt) && integer_type_valid(rs2) &&
                            rounding_valid(rm)) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            fp_reg_write_o = 1'b1;
                            fp_op_sel_o = `OPENRV64_FP_OP_CVT_FROM_INT;
                            fp_type_o = rs2;
                            fp_fflags_write_o = 1'b1;
                        end
                    end

                    `RV64_FP_FUNCT5_CVT_FP: begin
                        if (ENABLE_RV64F && ENABLE_RV64D &&
                            rounding_valid(rm) &&
                            (((fmt == `RV64_FP_FMT_S) &&
                              (rs2 == `RV64_FP_RS2_D)) ||
                             ((fmt == `RV64_FP_FMT_D) &&
                              (rs2 == `RV64_FP_RS2_S)))) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            src1_fp_o = 1'b1;
                            fp_reg_write_o = 1'b1;
                            fp_op_sel_o = `OPENRV64_FP_OP_CVT_FORMAT;
                            fp_type_o = rs2;
                            fp_fflags_write_o = 1'b1;
                        end
                    end

                    `RV64_FP_FUNCT5_MV_X_CLASS: begin
                        if (format_enabled(fmt) &&
                            (rs2 == `RV64_FP_RS2_ZERO) &&
                            ((funct3 == `RV64_FP_FUNCT3_MV) ||
                             (funct3 == `RV64_FP_FUNCT3_CLASS))) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            src1_fp_o = 1'b1;
                            reg_write_o = 1'b1;
                            fp_op_sel_o =
                                (funct3 == `RV64_FP_FUNCT3_CLASS) ?
                                    `OPENRV64_FP_OP_CLASS :
                                    `OPENRV64_FP_OP_MV_X_F;
                        end
                    end

                    `RV64_FP_FUNCT5_MV_F_X: begin
                        if (format_enabled(fmt) &&
                            (rs2 == `RV64_FP_RS2_ZERO) &&
                            (funct3 == `RV64_FP_FUNCT3_MV)) begin
                            valid_o = 1'b1;
                            illegal_o = 1'b0;
                            uses_rs1_o = 1'b1;
                            uses_rd_o = 1'b1;
                            fp_reg_write_o = 1'b1;
                            fp_op_sel_o = `OPENRV64_FP_OP_MV_F_X;
                        end
                    end

                    default: begin
                    end
                endcase
            end

            default: begin
            end
        endcase
    end

endmodule

`endif
