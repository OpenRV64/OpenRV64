`timescale 1ns/1ps
`include "core/decode/br.v"
`timescale 1ns/1ps

module tb_decode_br;

    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic valid;
    logic illegal;
    logic [`RV64_BR_OP_WIDTH-1:0] op_sel;
    logic branch;
    logic jump;
    logic link;
    logic indirect;

    openrv64_decode_br dut (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .valid_o(valid),
        .illegal_o(illegal),
        .op_sel_o(op_sel),
        .branch_o(branch),
        .jump_o(jump),
        .link_o(link),
        .indirect_o(indirect)
    );

    task automatic check;
        input [`RV64_OPCODE_WIDTH-1:0] in_opcode;
        input [`RV64_FUNCT3_WIDTH-1:0] in_funct3;
        input exp_valid;
        input exp_illegal;
        input [`RV64_BR_OP_WIDTH-1:0] exp_op_sel;
        input exp_branch;
        input exp_jump;
        input exp_link;
        input exp_indirect;
        input [8*32-1:0] label;
        begin
            opcode = in_opcode;
            funct3 = in_funct3;
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                op_sel !== exp_op_sel ||
                branch !== exp_branch ||
                jump !== exp_jump ||
                link !== exp_link ||
                indirect !== exp_indirect) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b illegal=%0b/%0b op=%0d/%0d branch=%0b/%0b jump=%0b/%0b link=%0b/%0b indirect=%0b/%0b",
                    label, valid, exp_valid, illegal, exp_illegal, op_sel, exp_op_sel,
                    branch, exp_branch, jump, exp_jump, link, exp_link, indirect, exp_indirect);
            end
        end
    endtask

    initial begin
        check(`RV64_OPCODE_BRANCH, `RV64_FUNCT3_BEQ,
              1'b1, 1'b0, `RV64_BR_OP_BEQ, 1'b1, 1'b0, 1'b0, 1'b0, "beq");
        check(`RV64_OPCODE_BRANCH, `RV64_FUNCT3_BGEU,
              1'b1, 1'b0, `RV64_BR_OP_BGEU, 1'b1, 1'b0, 1'b0, 1'b0, "bgeu");
        check(`RV64_OPCODE_JAL, 3'b111,
              1'b1, 1'b0, `RV64_BR_OP_JAL, 1'b0, 1'b1, 1'b1, 1'b0, "jal");
        check(`RV64_OPCODE_JALR, `RV64_FUNCT3_JALR,
              1'b1, 1'b0, `RV64_BR_OP_JALR, 1'b0, 1'b1, 1'b1, 1'b1, "jalr");
        check(`RV64_OPCODE_BRANCH, 3'b010,
              1'b0, 1'b1, `RV64_BR_OP_INVALID, 1'b1, 1'b0, 1'b0, 1'b0, "invalid branch funct3");
        check(`RV64_OPCODE_JALR, 3'b001,
              1'b0, 1'b1, `RV64_BR_OP_INVALID, 1'b0, 1'b1, 1'b0, 1'b1, "invalid jalr funct3");
        check(`RV64_OPCODE_OP, `RV64_FUNCT3_ADD_SUB,
              1'b0, 1'b1, `RV64_BR_OP_INVALID, 1'b0, 1'b0, 1'b0, 1'b0, "non branch");

        $display("PASS: branch decode");
        $finish;
    end

endmodule
