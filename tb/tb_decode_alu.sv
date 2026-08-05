`timescale 1ns/1ps
`include "core/decode/alu.v"
`timescale 1ns/1ps

module tb_decode_alu;

    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic [`RV64_FUNCT7_WIDTH-1:0] funct7;
    logic [`RV64_FUNCT12_WIDTH-1:0] funct12;

    logic valid_m;
    logic illegal_m;
    logic [`RV64_ALU_EXT_WIDTH-1:0] ext_m;
    logic [`RV64_ALU_OP_WIDTH-1:0] op_m;
    logic word_m;

    logic valid_nom;
    logic illegal_nom;
    logic [`RV64_ALU_EXT_WIDTH-1:0] ext_nom;
    logic [`RV64_ALU_OP_WIDTH-1:0] op_nom;
    logic word_nom;

    logic valid_zbb;
    logic illegal_zbb;
    logic [`RV64_ALU_EXT_WIDTH-1:0] ext_zbb;
    logic [`RV64_ALU_OP_WIDTH-1:0] op_zbb;
    logic word_zbb;

    openrv64_decode_alu #(
        .ENABLE_RV64M(1)
    ) dut_m (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .funct7_i(funct7),
        .funct12_i(funct12),
        .valid_o(valid_m),
        .illegal_o(illegal_m),
        .ext_sel_o(ext_m),
        .op_sel_o(op_m),
        .word_op_o(word_m)
    );

    openrv64_decode_alu #(
        .ENABLE_RV64M(0)
    ) dut_nom (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .funct7_i(funct7),
        .funct12_i(funct12),
        .valid_o(valid_nom),
        .illegal_o(illegal_nom),
        .ext_sel_o(ext_nom),
        .op_sel_o(op_nom),
        .word_op_o(word_nom)
    );

    openrv64_decode_alu #(
        .ENABLE_RV64M(1),
        .ENABLE_RV64ZBB(1)
    ) dut_zbb (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .funct7_i(funct7),
        .funct12_i(funct12),
        .valid_o(valid_zbb),
        .illegal_o(illegal_zbb),
        .ext_sel_o(ext_zbb),
        .op_sel_o(op_zbb),
        .word_op_o(word_zbb)
    );

    task automatic check_enabled(
        input logic exp_valid,
        input logic exp_illegal,
        input logic [`RV64_ALU_EXT_WIDTH-1:0] exp_ext,
        input logic [`RV64_ALU_OP_WIDTH-1:0] exp_op,
        input logic exp_word
    );
        begin
            if (valid_m !== exp_valid ||
                illegal_m !== exp_illegal ||
                ext_m !== exp_ext ||
                op_m !== exp_op ||
                word_m !== exp_word) begin
                $fatal(1,
                    "enabled ALU mismatch opcode=%07b funct3=%03b funct7=%07b valid=%0b illegal=%0b ext=%0d op=%0d word=%0b",
                    opcode, funct3, funct7, valid_m, illegal_m, ext_m, op_m, word_m);
            end
        end
    endtask

    task automatic check_disabled(
        input logic exp_valid,
        input logic exp_illegal,
        input logic [`RV64_ALU_EXT_WIDTH-1:0] exp_ext,
        input logic [`RV64_ALU_OP_WIDTH-1:0] exp_op,
        input logic exp_word
    );
        begin
            if (valid_nom !== exp_valid ||
                illegal_nom !== exp_illegal ||
                ext_nom !== exp_ext ||
                op_nom !== exp_op ||
                word_nom !== exp_word) begin
                $fatal(1,
                    "disabled ALU mismatch opcode=%07b funct3=%03b funct7=%07b valid=%0b illegal=%0b ext=%0d op=%0d word=%0b",
                    opcode, funct3, funct7, valid_nom, illegal_nom, ext_nom, op_nom, word_nom);
            end
        end
    endtask

    task automatic check(
        input logic [`RV64_OPCODE_WIDTH-1:0] in_opcode,
        input logic [`RV64_FUNCT3_WIDTH-1:0] in_funct3,
        input logic [`RV64_FUNCT7_WIDTH-1:0] in_funct7,
        input logic exp_valid_m,
        input logic exp_illegal_m,
        input logic [`RV64_ALU_EXT_WIDTH-1:0] exp_ext_m,
        input logic [`RV64_ALU_OP_WIDTH-1:0] exp_op_m,
        input logic exp_word_m,
        input logic exp_valid_nom,
        input logic exp_illegal_nom,
        input logic [`RV64_ALU_EXT_WIDTH-1:0] exp_ext_nom,
        input logic [`RV64_ALU_OP_WIDTH-1:0] exp_op_nom,
        input logic exp_word_nom
    );
        begin
            opcode = in_opcode;
            funct3 = in_funct3;
            funct7 = in_funct7;
            funct12 = {in_funct7, 5'd0};
            #1;

            check_enabled(exp_valid_m, exp_illegal_m, exp_ext_m, exp_op_m, exp_word_m);
            check_disabled(exp_valid_nom, exp_illegal_nom, exp_ext_nom, exp_op_nom, exp_word_nom);
            if (valid_zbb !== exp_valid_m ||
                illegal_zbb !== exp_illegal_m ||
                ext_zbb !== exp_ext_m ||
                op_zbb !== exp_op_m ||
                word_zbb !== exp_word_m)
                $fatal(1, "Zbb-enabled decoder changed base/M decode");
        end
    endtask

    task automatic check_zbb(
        input logic [`RV64_OPCODE_WIDTH-1:0] in_opcode,
        input logic [`RV64_FUNCT3_WIDTH-1:0] in_funct3,
        input logic [`RV64_FUNCT12_WIDTH-1:0] in_funct12,
        input logic [`RV64_ALU_OP_WIDTH-1:0] exp_op,
        input logic exp_word
    );
        begin
            opcode = in_opcode;
            funct3 = in_funct3;
            funct7 = in_funct12[11:5];
            funct12 = in_funct12;
            #1;

            if (!valid_zbb || illegal_zbb ||
                (ext_zbb != `RV64_ALU_EXT_ZBB) ||
                (op_zbb != exp_op) || (word_zbb != exp_word))
                $fatal(1,
                    "Zbb decode mismatch opcode=%07b funct3=%03b funct12=%012b valid=%0b illegal=%0b ext=%0d op=%0d word=%0b",
                    opcode, funct3, funct12, valid_zbb, illegal_zbb,
                    ext_zbb, op_zbb, word_zbb);
            if (valid_m || !illegal_m || valid_nom || !illegal_nom)
                $fatal(1, "Zbb decoded when ENABLE_RV64ZBB=0");
        end
    endtask

    initial begin
        check(`RV64_OPCODE_LUI, 3'b000, 7'b0000000,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_LUI, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_LUI, 1'b0);

        check(`RV64_OPCODE_AUIPC, 3'b000, 7'b0000000,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_AUIPC, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_AUIPC, 1'b0);

        check(`RV64_OPCODE_OP_IMM, `RV64_FUNCT3_ADD_SUB, 7'b1111111,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD, 1'b0);

        check(`RV64_OPCODE_OP_IMM, `RV64_FUNCT3_SRL_SRA, 7'b0100001,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA, 1'b0);

        check(`RV64_OPCODE_OP_IMM_32, `RV64_FUNCT3_SLL, `RV64_FUNCT7_SLLIW,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLL, 1'b1,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLL, 1'b1);

        check(`RV64_OPCODE_OP_IMM_32, `RV64_FUNCT3_SLL, 7'b0000001,
              1'b0, 1'b1, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_INVALID, 1'b1,
              1'b0, 1'b1, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_INVALID, 1'b1);

        check(`RV64_OPCODE_OP, `RV64_FUNCT3_ADD_SUB, `RV64_FUNCT7_ADD,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD, 1'b0);

        check(`RV64_OPCODE_OP, `RV64_FUNCT3_ADD_SUB, `RV64_FUNCT7_SUB,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SUB, 1'b0,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SUB, 1'b0);

        check(`RV64_OPCODE_OP_32, `RV64_FUNCT3_SRL_SRA, `RV64_FUNCT7_SRA,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA, 1'b1,
              1'b1, 1'b0, `RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA, 1'b1);

        check(`RV64_OPCODE_OP, `RV64_M_FUNCT3_MUL, `RV64_M_FUNCT7,
              1'b1, 1'b0, `RV64_ALU_EXT_M, `RV64_ALU_OP_MUL, 1'b0,
              1'b0, 1'b1, `RV64_ALU_EXT_M, `RV64_ALU_OP_INVALID, 1'b0);

        check(`RV64_OPCODE_OP_32, `RV64_M_FUNCT3_DIVU, `RV64_M_FUNCT7,
              1'b1, 1'b0, `RV64_ALU_EXT_M, `RV64_ALU_OP_DIVU, 1'b1,
              1'b0, 1'b1, `RV64_ALU_EXT_M, `RV64_ALU_OP_INVALID, 1'b1);

        check(`RV64_OPCODE_OP_32, `RV64_M_FUNCT3_MULH, `RV64_M_FUNCT7,
              1'b0, 1'b1, `RV64_ALU_EXT_M, `RV64_ALU_OP_INVALID, 1'b1,
              1'b0, 1'b1, `RV64_ALU_EXT_M, `RV64_ALU_OP_INVALID, 1'b1);

        check(`RV64_OPCODE_LOAD, 3'b000, 7'b0000000,
              1'b0, 1'b1, `RV64_ALU_EXT_INVALID, `RV64_ALU_OP_INVALID, 1'b0,
              1'b0, 1'b1, `RV64_ALU_EXT_INVALID, `RV64_ALU_OP_INVALID, 1'b0);

        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_ANDN,
                  {`RV64_ZBB_FUNCT7_LOGIC_N, 5'd2},
                  `RV64_ALU_OP_ZBB_ANDN, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_ORN,
                  {`RV64_ZBB_FUNCT7_LOGIC_N, 5'd2},
                  `RV64_ALU_OP_ZBB_ORN, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_XNOR,
                  {`RV64_ZBB_FUNCT7_LOGIC_N, 5'd2},
                  `RV64_ALU_OP_ZBB_XNOR, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_MIN,
                  {`RV64_ZBB_FUNCT7_MINMAX, 5'd2},
                  `RV64_ALU_OP_ZBB_MIN, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_MINU,
                  {`RV64_ZBB_FUNCT7_MINMAX, 5'd2},
                  `RV64_ALU_OP_ZBB_MINU, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_MAX,
                  {`RV64_ZBB_FUNCT7_MINMAX, 5'd2},
                  `RV64_ALU_OP_ZBB_MAX, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_MAXU,
                  {`RV64_ZBB_FUNCT7_MINMAX, 5'd2},
                  `RV64_ALU_OP_ZBB_MAXU, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_ROL,
                  {`RV64_ZBB_FUNCT7_ROTATE, 5'd2},
                  `RV64_ALU_OP_ZBB_ROL, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG, `RV64_ZBB_FUNCT3_ROR,
                  {`RV64_ZBB_FUNCT7_ROTATE, 5'd2},
                  `RV64_ALU_OP_ZBB_ROR, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_REG_32, `RV64_ZBB_FUNCT3_ROL,
                  {`RV64_ZBB_FUNCT7_ROTATE, 5'd2},
                  `RV64_ALU_OP_ZBB_ROL, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_REG_32, `RV64_ZBB_FUNCT3_ROR,
                  {`RV64_ZBB_FUNCT7_ROTATE, 5'd2},
                  `RV64_ALU_OP_ZBB_ROR, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CLZ,
                  `RV64_ALU_OP_ZBB_CLZ, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CTZ,
                  `RV64_ALU_OP_ZBB_CTZ, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CPOP,
                  `RV64_ALU_OP_ZBB_CPOP, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM_32, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CLZW,
                  `RV64_ALU_OP_ZBB_CLZ, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_IMM_32, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CTZW,
                  `RV64_ALU_OP_ZBB_CTZ, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_IMM_32, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_CPOPW,
                  `RV64_ALU_OP_ZBB_CPOP, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_SEXT_B,
                  `RV64_ALU_OP_ZBB_SEXT_B, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_UNARY,
                  `RV64_ZBB_FUNCT12_SEXT_H,
                  `RV64_ALU_OP_ZBB_SEXT_H, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_RORI,
                  {`RV64_ZBB_FUNCT6_RORI, 6'd37},
                  `RV64_ALU_OP_ZBB_ROR, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM_32, `RV64_ZBB_FUNCT3_RORI,
                  {`RV64_ZBB_FUNCT7_ROTATE, 5'd13},
                  `RV64_ALU_OP_ZBB_ROR, 1'b1);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_ORC_B,
                  `RV64_ZBB_FUNCT12_ORC_B,
                  `RV64_ALU_OP_ZBB_ORC_B, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_IMM, `RV64_ZBB_FUNCT3_REV8,
                  `RV64_ZBB_FUNCT12_REV8,
                  `RV64_ALU_OP_ZBB_REV8, 1'b0);
        check_zbb(`RV64_ZBB_OPCODE_ZEXT_H, `RV64_ZBB_FUNCT3_ZEXT_H,
                  {`RV64_ZBB_FUNCT7_ZEXT_H, `RV64_ZBB_RS2_ZEXT_H},
                  `RV64_ALU_OP_ZBB_ZEXT_H, 1'b1);

        opcode = `RV64_ZBB_OPCODE_ZEXT_H;
        funct3 = `RV64_ZBB_FUNCT3_ZEXT_H;
        funct7 = `RV64_ZBB_FUNCT7_ZEXT_H;
        funct12 = {`RV64_ZBB_FUNCT7_ZEXT_H, 5'd1};
        #1;
        if (valid_zbb || !illegal_zbb)
            $fatal(1, "zext.h accepted nonzero rs2");

        $display("PASS: ALU decode base, M, and 3P-gated Zbb routing");
        $finish;
    end

endmodule
