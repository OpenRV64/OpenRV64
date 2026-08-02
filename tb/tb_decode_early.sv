`timescale 1ns/1ps
`include "core/decode/early.v"
`timescale 1ns/1ps

module tb_decode_early;

    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic valid;
    logic [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel;
    logic [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel;
    logic uses_rs1;
    logic uses_rs2;
    logic uses_rd;
    logic reg_write;
    logic mem_read;
    logic mem_write;
    logic branch;
    logic jump;
    logic word_op;
    logic subdecode_needed;
    logic extension_decode_possible;

    openrv64_decode_early dut (
        .opcode_i(opcode),
        .valid_o(valid),
        .class_sel_o(class_sel),
        .format_sel_o(format_sel),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rd_o(uses_rd),
        .reg_write_o(reg_write),
        .mem_read_o(mem_read),
        .mem_write_o(mem_write),
        .branch_o(branch),
        .jump_o(jump),
        .word_op_o(word_op),
        .subdecode_needed_o(subdecode_needed),
        .extension_decode_possible_o(extension_decode_possible)
    );

    task automatic check(
        input logic [`RV64_OPCODE_WIDTH-1:0] op,
        input logic exp_valid,
        input logic [`RV64_EARLY_CLASS_WIDTH-1:0] exp_class,
        input logic [`RV64_EARLY_FORMAT_WIDTH-1:0] exp_format,
        input logic exp_uses_rs1,
        input logic exp_uses_rs2,
        input logic exp_uses_rd,
        input logic exp_reg_write,
        input logic exp_mem_read,
        input logic exp_mem_write,
        input logic exp_branch,
        input logic exp_jump,
        input logic exp_word_op,
        input logic exp_subdecode_needed,
        input logic exp_extension_decode_possible
    );
        begin
            opcode = op;
            #1;

            if (valid !== exp_valid ||
                class_sel !== exp_class ||
                format_sel !== exp_format ||
                uses_rs1 !== exp_uses_rs1 ||
                uses_rs2 !== exp_uses_rs2 ||
                uses_rd !== exp_uses_rd ||
                reg_write !== exp_reg_write ||
                mem_read !== exp_mem_read ||
                mem_write !== exp_mem_write ||
                branch !== exp_branch ||
                jump !== exp_jump ||
                word_op !== exp_word_op ||
                subdecode_needed !== exp_subdecode_needed ||
                extension_decode_possible !== exp_extension_decode_possible) begin
                $fatal(1,
                    "decode mismatch opcode=%07b valid=%0b class=%0d format=%0d rs1=%0b rs2=%0b rd=%0b regw=%0b memr=%0b memw=%0b br=%0b j=%0b word=%0b sub=%0b ext=%0b",
                    op, valid, class_sel, format_sel, uses_rs1,
                    uses_rs2, uses_rd, reg_write, mem_read, mem_write, branch,
                    jump, word_op, subdecode_needed, extension_decode_possible);
            end
        end
    endtask

    initial begin
        check(`RV64_OPCODE_LUI, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_U,
              1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        check(`RV64_OPCODE_AUIPC, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_U,
              1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        check(`RV64_OPCODE_JAL, 1'b1, `RV64_EARLY_CLASS_JUMP, `RV64_EARLY_FORMAT_J,
              1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);

        check(`RV64_OPCODE_JALR, 1'b1, `RV64_EARLY_CLASS_JUMP, `RV64_EARLY_FORMAT_I,
              1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_BRANCH, 1'b1, `RV64_EARLY_CLASS_BRANCH, `RV64_EARLY_FORMAT_B,
              1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_LOAD, 1'b1, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_I,
              1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_STORE, 1'b1, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_S,
              1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_OP_IMM, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_I,
              1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_OP_IMM_32, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_I,
              1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0);

        check(`RV64_OPCODE_OP, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_R,
              1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);

        check(`RV64_OPCODE_OP_32, 1'b1, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_R,
              1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);

        check(`RV64_OPCODE_MISC_MEM, 1'b1, `RV64_EARLY_CLASS_FENCE, `RV64_EARLY_FORMAT_I,
              1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

        check(`RV64_OPCODE_SYSTEM, 1'b1, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
              1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

        // An otherwise-unowned 32-bit major opcode is an extension candidate.
        // No particular extension or operand format is identified here.
        check(7'b0001011, 1'b1, `RV64_EARLY_CLASS_EXTENSION,
              `RV64_EARLY_FORMAT_INVALID,
              1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);

        check(7'b0000000, 1'b0, `RV64_EARLY_CLASS_INVALID, `RV64_EARLY_FORMAT_INVALID,
              1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        $display("PASS: early decoder opcode classification");
        $finish;
    end

endmodule
