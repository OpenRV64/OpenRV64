`timescale 1ns/1ps
`include "core/decode/imm.v"
`timescale 1ns/1ps

module tb_decode_imm;

    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel;
    logic valid;
    logic has_imm;
    logic [`RV64_XLEN-1:0] imm;
    logic [`RV64_XLEN-1:0] imm_i;
    logic [`RV64_XLEN-1:0] imm_s;
    logic [`RV64_XLEN-1:0] imm_b;
    logic [`RV64_XLEN-1:0] imm_u;
    logic [`RV64_XLEN-1:0] imm_j;

    openrv64_decode_imm dut (
        .instr_i(instr),
        .format_sel_i(format_sel),
        .valid_o(valid),
        .has_imm_o(has_imm),
        .imm_o(imm),
        .imm_i_o(imm_i),
        .imm_s_o(imm_s),
        .imm_b_o(imm_b),
        .imm_u_o(imm_u),
        .imm_j_o(imm_j)
    );

    task automatic check;
        input [`RV64_INSTR_WIDTH-1:0] in_instr;
        input [`RV64_EARLY_FORMAT_WIDTH-1:0] in_format_sel;
        input exp_valid;
        input exp_has_imm;
        input [`RV64_XLEN-1:0] exp_imm;
        input [8*32-1:0] label;
        begin
            instr = in_instr;
            format_sel = in_format_sel;
            #1;

            if (valid !== exp_valid ||
                has_imm !== exp_has_imm ||
                imm !== exp_imm) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b has=%0b/%0b imm=%016x/%016x",
                    label, valid, exp_valid, has_imm, exp_has_imm, imm, exp_imm);
            end
        end
    endtask

    initial begin
        check({12'hfff, 5'd1, `RV64_FUNCT3_ADD_SUB, 5'd2, `RV64_OPCODE_OP_IMM},
              `RV64_EARLY_FORMAT_I, 1'b1, 1'b1, 64'hffff_ffff_ffff_ffff, "i immediate");

        check({7'b1000000, 5'd3, 5'd4, `RV64_FUNCT3_SD, 5'b00000, `RV64_OPCODE_STORE},
              `RV64_EARLY_FORMAT_S, 1'b1, 1'b1, 64'hffff_ffff_ffff_f800, "s immediate");

        check({1'b0, 6'b000000, 5'd3, 5'd4, `RV64_FUNCT3_BEQ, 4'b1000, 1'b0, `RV64_OPCODE_BRANCH},
              `RV64_EARLY_FORMAT_B, 1'b1, 1'b1, 64'h0000_0000_0000_0010, "b immediate");

        check({20'h12345, 5'd5, `RV64_OPCODE_LUI},
              `RV64_EARLY_FORMAT_U, 1'b1, 1'b1, 64'h0000_0000_1234_5000, "u immediate");

        check({1'b0, 10'b0000000000, 1'b1, 8'h00, 5'd1, `RV64_OPCODE_JAL},
              `RV64_EARLY_FORMAT_J, 1'b1, 1'b1, 64'h0000_0000_0000_0800, "j immediate");

        check({`RV64_FUNCT7_ADD, 5'd2, 5'd1, `RV64_FUNCT3_ADD_SUB, 5'd3, `RV64_OPCODE_OP},
              `RV64_EARLY_FORMAT_R, 1'b1, 1'b0, 64'h0000_0000_0000_0000, "r format");

        check(32'h0000_0000,
              `RV64_EARLY_FORMAT_INVALID, 1'b0, 1'b0, 64'h0000_0000_0000_0000, "invalid format");

        $display("PASS: immediate decode");
        $finish;
    end

endmodule
