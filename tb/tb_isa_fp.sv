`timescale 1ns/1ps
`include "core/exec/fpu/isa/rv64-d.v"

module tb_isa_fp;

    function automatic [31:0] fp_r;
        input [4:0] funct5;
        input [1:0] fmt;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] rm;
        input [4:0] rd;
        begin
            fp_r = {funct5, fmt, rs2, rs1, rm, rd,
                    `RV64_FP_OPCODE_OP};
        end
    endfunction

    function automatic [31:0] fp_r4;
        input [6:0] opcode;
        input [4:0] rs3;
        input [1:0] fmt;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] rm;
        input [4:0] rd;
        begin
            fp_r4 = {rs3, fmt, rs2, rs1, rm, rd, opcode};
        end
    endfunction

    task automatic check;
        input [31:0] actual;
        input [31:0] expected;
        input [8*24-1:0] label;
        begin
            if (actual !== expected)
                $fatal(1, "%0s encoding=%08x expected=%08x",
                       label, actual, expected);
        end
    endtask

    initial begin
        check(fp_r(`RV64_FP_FUNCT5_ADD, `RV64_FP_FMT_S,
                   5'd3, 5'd2, `RV64_FP_RM_RNE, 5'd1),
              32'h0031_00d3, "fadd.s f1,f2,f3");
        check(fp_r(`RV64_FP_FUNCT5_ADD, `RV64_FP_FMT_D,
                   5'd3, 5'd2, `RV64_FP_RM_RNE, 5'd1),
              32'h0231_00d3, "fadd.d f1,f2,f3");
        check(fp_r(`RV64_FP_FUNCT5_SQRT, `RV64_FP_FMT_D,
                   `RV64_FP_RS2_ZERO, 5'd2, `RV64_FP_RM_RNE, 5'd1),
              32'h5a01_00d3, "fsqrt.d f1,f2");
        check(fp_r(`RV64_FP_FUNCT5_COMPARE, `RV64_FP_FMT_S,
                   5'd3, 5'd2, `RV64_FP_FUNCT3_FEQ, 5'd1),
              32'ha031_20d3, "feq.s x1,f2,f3");
        check(fp_r(`RV64_FP_FUNCT5_CVT_TO_INT, `RV64_FP_FMT_D,
                   `RV64_FP_RS2_L, 5'd2, `RV64_FP_RM_RTZ, 5'd1),
              32'hc221_10d3, "fcvt.l.d x1,f2,rtz");
        check(fp_r(`RV64_FP_FUNCT5_CVT_FP, `RV64_FP_FMT_S,
                   `RV64_FP_RS2_D, 5'd2, `RV64_FP_RM_RNE, 5'd1),
              32'h4011_00d3, "fcvt.s.d f1,f2");
        check(fp_r4(`RV64_FP_OPCODE_MADD, 5'd4, `RV64_FP_FMT_D,
                    5'd3, 5'd2, `RV64_FP_RM_RNE, 5'd1),
              32'h2231_00c3, "fmadd.d f1,f2,f3,f4");

        if (`RV64_FP_FUNCT3_FLW_FSW != 3'b010 ||
            `RV64_FP_FUNCT3_FLD_FSD != 3'b011 ||
            `RV64_FP_FUNCT7_FMV_X_D != 7'b1110001 ||
            `RV64_FP_FUNCT7_FMV_D_X != 7'b1111001)
            $fatal(1, "floating load/store or move constants mismatch");
        if (`RV64_FP_CSR_FFLAGS != 12'h001 ||
            `RV64_FP_CSR_FRM != 12'h002 ||
            `RV64_FP_CSR_FCSR != 12'h003 ||
            `RV64_FP_CLASS_NEG_INF != 10'b0000000001 ||
            `RV64_FP_CLASS_QNAN != 10'b1000000000)
            $fatal(1, "floating CSR or FCLASS constants mismatch");

        $display("PASS: RV64F/RV64D ISA constants");
        $finish;
    end

endmodule
