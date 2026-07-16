`timescale 1ns/1ps
`include "core/exec/alu/rv64-i.v"
`timescale 1ns/1ps

module tb_exec_alu_rv64i;

    logic [`RV64_ALU_OP_WIDTH-1:0] op_sel;
    logic                          word_op;
    logic [`RV64_XLEN-1:0]         src1;
    logic [`RV64_XLEN-1:0]         src2;
    logic [`RV64_XLEN-1:0]         pc;
    logic                          valid;
    logic                          illegal;
    logic [`RV64_XLEN-1:0]         result;

    openrv64_exec_alu_rv64i dut (
        .op_sel_i(op_sel),
        .word_op_i(word_op),
        .src1_i(src1),
        .src2_i(src2),
        .pc_i(pc),
        .valid_o(valid),
        .illegal_o(illegal),
        .result_o(result)
    );

    task automatic check;
        input [`RV64_ALU_OP_WIDTH-1:0] in_op_sel;
        input                          in_word_op;
        input [`RV64_XLEN-1:0]         in_src1;
        input [`RV64_XLEN-1:0]         in_src2;
        input [`RV64_XLEN-1:0]         in_pc;
        input                          exp_valid;
        input                          exp_illegal;
        input [`RV64_XLEN-1:0]         exp_result;
        input [8*40-1:0]               label;
        begin
            op_sel  = in_op_sel;
            word_op = in_word_op;
            src1    = in_src1;
            src2    = in_src2;
            pc      = in_pc;
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                result !== exp_result) begin
                $fatal(1,
                    "%0s: valid=%0b expected=%0b illegal=%0b expected=%0b result=%016x expected=%016x",
                    label, valid, exp_valid, illegal, exp_illegal, result, exp_result);
            end
        end
    endtask

    initial begin
        check(`RV64_ALU_OP_ADD, 1'b0,
              64'h0000_0000_0000_0003, 64'h0000_0000_0000_0004, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0007, "add");

        check(`RV64_ALU_OP_SUB, 1'b0,
              64'h0000_0000_0000_0003, 64'h0000_0000_0000_0004, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "sub wrap");

        check(`RV64_ALU_OP_SLL, 1'b0,
              64'h0000_0000_0000_0001, 64'h0000_0000_0000_0004, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0010, "sll");

        check(`RV64_ALU_OP_SLT, 1'b0,
              64'hffff_ffff_ffff_ffff, 64'h0000_0000_0000_0001, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0001, "slt signed");

        check(`RV64_ALU_OP_SLTU, 1'b0,
              64'hffff_ffff_ffff_ffff, 64'h0000_0000_0000_0001, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0000, "sltu unsigned");

        check(`RV64_ALU_OP_XOR, 1'b0,
              64'hf0f0_f0f0_aaaa_5555, 64'h0f0f_0f0f_ffff_0000, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_5555_5555, "xor");

        check(`RV64_ALU_OP_SRL, 1'b0,
              64'h8000_0000_0000_0000, 64'h0000_0000_0000_003f, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0001, "srl");

        check(`RV64_ALU_OP_SRA, 1'b0,
              64'h8000_0000_0000_0000, 64'h0000_0000_0000_003f, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "sra");

        check(`RV64_ALU_OP_OR, 1'b0,
              64'hf0f0_0000_aaaa_0000, 64'h0000_0f0f_0000_5555, 64'h0,
              1'b1, 1'b0, 64'hf0f0_0f0f_aaaa_5555, "or");

        check(`RV64_ALU_OP_AND, 1'b0,
              64'hffff_0000_aaaa_5555, 64'h0f0f_0f0f_ffff_0000, 64'h0,
              1'b1, 1'b0, 64'h0f0f_0000_aaaa_0000, "and");

        check(`RV64_ALU_OP_LUI, 1'b0,
              64'h1111_1111_1111_1111, 64'hffff_ffff_8000_0000, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_8000_0000, "lui");

        check(`RV64_ALU_OP_AUIPC, 1'b0,
              64'h0, 64'h0000_0000_0000_2000, 64'h0000_0000_0000_1000,
              1'b1, 1'b0, 64'h0000_0000_0000_3000, "auipc");

        check(`RV64_ALU_OP_ADD, 1'b1,
              64'h0000_0000_7fff_ffff, 64'h0000_0000_0000_0001, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_8000_0000, "addw sign extend");

        check(`RV64_ALU_OP_SUB, 1'b1,
              64'h0000_0000_0000_0000, 64'h0000_0000_0000_0001, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "subw sign extend");

        check(`RV64_ALU_OP_SLL, 1'b1,
              64'h0000_0000_0000_0001, 64'h0000_0000_0000_001f, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_8000_0000, "sllw sign extend");

        check(`RV64_ALU_OP_SRL, 1'b1,
              64'h0000_0000_8000_0000, 64'h0000_0000_0000_001f, 64'h0,
              1'b1, 1'b0, 64'h0000_0000_0000_0001, "srlw sign extend");

        check(`RV64_ALU_OP_SRA, 1'b1,
              64'h0000_0000_8000_0000, 64'h0000_0000_0000_001f, 64'h0,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "sraw sign extend");

        check(`RV64_ALU_OP_MUL, 1'b0,
              64'h2, 64'h3, 64'h0,
              1'b0, 1'b1, 64'h0000_0000_0000_0000, "extension op illegal");

        check(`RV64_ALU_OP_AND, 1'b1,
              64'hffff_ffff_ffff_ffff, 64'h0, 64'h0,
              1'b0, 1'b1, 64'h0000_0000_0000_0000, "invalid word op");

        check(`RV64_ALU_OP_INVALID, 1'b0,
              64'h0, 64'h0, 64'h0,
              1'b0, 1'b1, 64'h0000_0000_0000_0000, "invalid op");

        $display("PASS: RV64I execute ALU");
        $finish;
    end

endmodule
