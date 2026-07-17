`timescale 1ns/1ps
`include "core/decode/alu.v"
`timescale 1ns/1ps

module tb_decode_alu;

    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic [`RV64_FUNCT7_WIDTH-1:0] funct7;

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

    openrv64_decode_alu #(
        .ENABLE_RV64M(1)
    ) dut_m (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .funct7_i(funct7),
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
        .valid_o(valid_nom),
        .illegal_o(illegal_nom),
        .ext_sel_o(ext_nom),
        .op_sel_o(op_nom),
        .word_op_o(word_nom)
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
            #1;

            check_enabled(exp_valid_m, exp_illegal_m, exp_ext_m, exp_op_m, exp_word_m);
            check_disabled(exp_valid_nom, exp_illegal_nom, exp_ext_nom, exp_op_nom, exp_word_nom);
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

        $display("PASS: ALU decode base and M extension routing");
        $finish;
    end

endmodule
