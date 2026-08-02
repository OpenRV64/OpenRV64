`timescale 1ns/1ps
`include "core/exec/fpu/decode_top.v"
`timescale 1ns/1ps

module tb_decode_rv64fd;

    logic [`RV64_INSTR_WIDTH-1:0] instr;
    wire valid;
    wire illegal;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel;
    wire uses_rs1;
    wire uses_rs2;
    wire uses_rs3;
    wire uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;
    wire reg_write;
    wire fp_reg_write;
    wire src1_fp;
    wire src2_fp;
    wire src3_fp;
    wire has_imm;
    wire [`RV64_XLEN-1:0] imm;
    wire mem_read;
    wire mem_write;
    wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size;
    wire fp_instr;
    wire [`OPENRV64_FP_OP_WIDTH-1:0] fp_op;
    wire [1:0] fp_fmt;
    wire [2:0] fp_rm;
    wire [4:0] fp_type;
    wire fp_fflags_write;

    wire f_only_valid;
    wire f_only_illegal;

    openrv64_fpu_decode_top #(
        .ENABLE_RV64F(1),
        .ENABLE_RV64D(1)
    ) dut (
        .instr_i(instr),
        .valid_o(valid),
        .illegal_o(illegal),
        .class_sel_o(class_sel),
        .format_sel_o(format_sel),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rs3_o(uses_rs3),
        .uses_rd_o(uses_rd),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rs3_addr_o(rs3_addr),
        .rd_addr_o(rd_addr),
        .reg_write_o(reg_write),
        .fp_reg_write_o(fp_reg_write),
        .src1_fp_o(src1_fp),
        .src2_fp_o(src2_fp),
        .src3_fp_o(src3_fp),
        .has_imm_o(has_imm),
        .imm_o(imm),
        .mem_read_o(mem_read),
        .mem_write_o(mem_write),
        .lsu_op_sel_o(lsu_op),
        .lsu_size_sel_o(lsu_size),
        .fp_instr_o(fp_instr),
        .fp_op_sel_o(fp_op),
        .fp_fmt_o(fp_fmt),
        .fp_rm_o(fp_rm),
        .fp_type_o(fp_type),
        .fp_fflags_write_o(fp_fflags_write)
    );

    openrv64_fpu_decode_top #(
        .ENABLE_RV64F(1),
        .ENABLE_RV64D(0)
    ) dut_f_only (
        .instr_i(instr),
        .valid_o(f_only_valid),
        .illegal_o(f_only_illegal)
    );

    task automatic expect_valid;
        input [`RV64_EARLY_CLASS_WIDTH-1:0] exp_class;
        input exp_rs1;
        input exp_rs2;
        input exp_rs3;
        input exp_src1_fp;
        input exp_src2_fp;
        input exp_src3_fp;
        input exp_gpr_write;
        input exp_fpr_write;
        input [`OPENRV64_FP_OP_WIDTH-1:0] exp_op;
        input [8*32-1:0] label;
        begin
            #1;
            if (!valid || illegal || !fp_instr ||
                (class_sel != exp_class) ||
                (uses_rs1 != exp_rs1) ||
                (uses_rs2 != exp_rs2) ||
                (uses_rs3 != exp_rs3) ||
                (src1_fp != exp_src1_fp) ||
                (src2_fp != exp_src2_fp) ||
                (src3_fp != exp_src3_fp) ||
                (reg_write != exp_gpr_write) ||
                (fp_reg_write != exp_fpr_write) ||
                (fp_op != exp_op)) begin
                $fatal(1,
                    "%0s: valid=%b illegal=%b fp=%b class=%0d sources=%b%b%b fp_sources=%b%b%b writes=%b%b op=%0d",
                    label, valid, illegal, fp_instr, class_sel,
                    uses_rs1, uses_rs2, uses_rs3,
                    src1_fp, src2_fp, src3_fp,
                    reg_write, fp_reg_write, fp_op);
            end
        end
    endtask

    task automatic expect_illegal;
        input [8*32-1:0] label;
        begin
            #1;
            if (valid || !illegal || fp_instr)
                $fatal(1, "%0s: valid=%b illegal=%b fp=%b",
                       label, valid, illegal, fp_instr);
        end
    endtask

    initial begin
        // flw f3,-16(x4)
        instr = {12'hff0, 5'd4, `RV64_FP_FUNCT3_FLW_FSW, 5'd3,
                 `RV64_FP_OPCODE_LOAD};
        expect_valid(`RV64_EARLY_CLASS_MEM, 1'b1, 1'b0, 1'b0,
                     1'b0, 1'b0, 1'b0, 1'b0, 1'b1,
                     `OPENRV64_FP_OP_INVALID, "flw");
        if (!has_imm || (imm != 64'hffff_ffff_ffff_fff0) || !mem_read ||
            mem_write || (lsu_op != `RV64_LSU_OP_LWU) ||
            (lsu_size != `RV64_LSU_SIZE_WORD) ||
            (rs1_addr != 5'd4) || (rd_addr != 5'd3) ||
            (fp_fmt != `RV64_FP_FMT_S))
            $fatal(1, "flw memory decode mismatch");

        // fsd f7,24(x6)
        instr = {7'd0, 5'd7, 5'd6, `RV64_FP_FUNCT3_FLD_FSD, 5'd24,
                 `RV64_FP_OPCODE_STORE};
        expect_valid(`RV64_EARLY_CLASS_MEM, 1'b1, 1'b1, 1'b0,
                     1'b0, 1'b1, 1'b0, 1'b0, 1'b0,
                     `OPENRV64_FP_OP_INVALID, "fsd");
        if (!has_imm || (imm != 64'd24) || mem_read || !mem_write ||
            (lsu_op != `RV64_LSU_OP_SD) ||
            (lsu_size != `RV64_LSU_SIZE_DWORD) ||
            (rs2_addr != 5'd7) || (fp_fmt != `RV64_FP_FMT_D))
            $fatal(1, "fsd memory decode mismatch");

        // fadd.d f9,f4,f5,rtz
        instr = {`RV64_FP_FUNCT5_ADD, `RV64_FP_FMT_D, 5'd5, 5'd4,
                 `RV64_FP_RM_RTZ, 5'd9, `RV64_FP_OPCODE_OP};
        expect_valid(`RV64_EARLY_CLASS_EXTENSION, 1'b1, 1'b1, 1'b0,
                     1'b1, 1'b1, 1'b0, 1'b0, 1'b1,
                     `OPENRV64_FP_OP_ADD, "fadd.d");
        if ((fp_rm != `RV64_FP_RM_RTZ) || !fp_fflags_write ||
            (fp_fmt != `RV64_FP_FMT_D))
            $fatal(1, "fadd.d operation fields mismatch");

        // fmadd.s f10,f1,f2,f3,dyn
        instr = {5'd3, `RV64_FP_FMT_S, 5'd2, 5'd1,
                 `RV64_FP_RM_DYN, 5'd10, `RV64_FP_OPCODE_MADD};
        expect_valid(`RV64_EARLY_CLASS_EXTENSION, 1'b1, 1'b1, 1'b1,
                     1'b1, 1'b1, 1'b1, 1'b0, 1'b1,
                     `OPENRV64_FP_OP_MADD, "fmadd.s");
        if ((rs3_addr != 5'd3) || !fp_fflags_write)
            $fatal(1, "fmadd.s third operand mismatch");

        // feq.s x8,f6,f7
        instr = {`RV64_FP_FUNCT5_COMPARE, `RV64_FP_FMT_S, 5'd7, 5'd6,
                 `RV64_FP_FUNCT3_FEQ, 5'd8, `RV64_FP_OPCODE_OP};
        expect_valid(`RV64_EARLY_CLASS_EXTENSION, 1'b1, 1'b1, 1'b0,
                     1'b1, 1'b1, 1'b0, 1'b1, 1'b0,
                     `OPENRV64_FP_OP_EQ, "feq.s");

        // fcvt.d.lu f12,x11,rup
        instr = {`RV64_FP_FUNCT5_CVT_FROM_INT, `RV64_FP_FMT_D,
                 `RV64_FP_RS2_LU, 5'd11, `RV64_FP_RM_RUP, 5'd12,
                 `RV64_FP_OPCODE_OP};
        expect_valid(`RV64_EARLY_CLASS_EXTENSION, 1'b1, 1'b0, 1'b0,
                     1'b0, 1'b0, 1'b0, 1'b0, 1'b1,
                     `OPENRV64_FP_OP_CVT_FROM_INT, "fcvt.d.lu");
        if ((fp_type != `RV64_FP_RS2_LU) || !fp_fflags_write)
            $fatal(1, "fcvt.d.lu type mismatch");

        // fcvt.s.d f2,f1,rne
        instr = {`RV64_FP_FUNCT5_CVT_FP, `RV64_FP_FMT_S,
                 `RV64_FP_RS2_D, 5'd1, `RV64_FP_RM_RNE, 5'd2,
                 `RV64_FP_OPCODE_OP};
        expect_valid(`RV64_EARLY_CLASS_EXTENSION, 1'b1, 1'b0, 1'b0,
                     1'b1, 1'b0, 1'b0, 1'b0, 1'b1,
                     `OPENRV64_FP_OP_CVT_FORMAT, "fcvt.s.d");

        // Reserved static rm is illegal.
        instr = {`RV64_FP_FUNCT5_ADD, `RV64_FP_FMT_D, 5'd5, 5'd4,
                 3'b101, 5'd9, `RV64_FP_OPCODE_OP};
        expect_illegal("reserved rm");

        // fsqrt requires rs2=0.
        instr = {`RV64_FP_FUNCT5_SQRT, `RV64_FP_FMT_S, 5'd1, 5'd4,
                 `RV64_FP_RM_RNE, 5'd9, `RV64_FP_OPCODE_OP};
        expect_illegal("fsqrt nonzero rs2");

        // D is not silently accepted by an F-only configuration.
        instr = {`RV64_FP_FUNCT5_ADD, `RV64_FP_FMT_D, 5'd5, 5'd4,
                 `RV64_FP_RM_RNE, 5'd9, `RV64_FP_OPCODE_OP};
        #1;
        if (f_only_valid || !f_only_illegal)
            $fatal(1, "F-only decoder accepted fadd.d");

        $display("PASS: RV64F/RV64D typed decode");
        $finish;
    end

endmodule
