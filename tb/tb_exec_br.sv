`timescale 1ns/1ps
`include "core/exec/br.v"
`timescale 1ns/1ps

module tb_exec_br;

    logic [`RV64_BR_OP_WIDTH-1:0] op_sel;
    logic [`RV64_XLEN-1:0] pc;
    logic [`RV64_XLEN-1:0] src1;
    logic [`RV64_XLEN-1:0] src2;
    logic [`RV64_XLEN-1:0] imm;
    logic valid;
    logic illegal;
    logic taken;
    logic [`RV64_XLEN-1:0] target;
    logic link;
    logic [`RV64_XLEN-1:0] link_data;

    openrv64_exec_br dut (
        .op_sel_i(op_sel),
        .pc_i(pc),
        .src1_i(src1),
        .src2_i(src2),
        .imm_i(imm),
        .valid_o(valid),
        .illegal_o(illegal),
        .taken_o(taken),
        .target_o(target),
        .link_o(link),
        .link_data_o(link_data)
    );

    task automatic check;
        input [`RV64_BR_OP_WIDTH-1:0] in_op_sel;
        input [`RV64_XLEN-1:0] in_pc;
        input [`RV64_XLEN-1:0] in_src1;
        input [`RV64_XLEN-1:0] in_src2;
        input [`RV64_XLEN-1:0] in_imm;
        input exp_valid;
        input exp_illegal;
        input exp_taken;
        input [`RV64_XLEN-1:0] exp_target;
        input exp_link;
        input [`RV64_XLEN-1:0] exp_link_data;
        input [8*32-1:0] label;
        begin
            op_sel = in_op_sel;
            pc = in_pc;
            src1 = in_src1;
            src2 = in_src2;
            imm = in_imm;
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                taken !== exp_taken ||
                target !== exp_target ||
                link !== exp_link ||
                link_data !== exp_link_data) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b illegal=%0b/%0b taken=%0b/%0b target=%016x/%016x link=%0b/%0b link_data=%016x/%016x",
                    label, valid, exp_valid, illegal, exp_illegal, taken, exp_taken,
                    target, exp_target, link, exp_link, link_data, exp_link_data);
            end
        end
    endtask

    initial begin
        check(`RV64_BR_OP_BEQ, 64'h1000, 64'h5, 64'h5, 64'h20,
              1'b1, 1'b0, 1'b1, 64'h1020, 1'b0, 64'h0, "beq taken");
        check(`RV64_BR_OP_BEQ, 64'h1000, 64'h5, 64'h6, 64'h20,
              1'b1, 1'b0, 1'b0, 64'h1004, 1'b0, 64'h0, "beq not taken");
        check(`RV64_BR_OP_BLT, 64'h1000, 64'hffff_ffff_ffff_ffff, 64'h1, 64'hffff_ffff_ffff_fff0,
              1'b1, 1'b0, 1'b1, 64'h0ff0, 1'b0, 64'h0, "blt signed");
        check(`RV64_BR_OP_BLTU, 64'h1000, 64'hffff_ffff_ffff_ffff, 64'h1, 64'h20,
              1'b1, 1'b0, 1'b0, 64'h1004, 1'b0, 64'h0, "bltu not taken");
        check(`RV64_BR_OP_JAL, 64'h1000, 64'h0, 64'h0, 64'h80,
              1'b1, 1'b0, 1'b1, 64'h1080, 1'b1, 64'h1004, "jal");
        check(`RV64_BR_OP_JALR, 64'h1000, 64'h2003, 64'h0, 64'h4,
              1'b1, 1'b0, 1'b1, 64'h2006, 1'b1, 64'h1004, "jalr clear low bit");
        check(`RV64_BR_OP_INVALID, 64'h1000, 64'h0, 64'h0, 64'h0,
              1'b0, 1'b1, 1'b0, 64'h1004, 1'b0, 64'h0, "invalid");

        $display("PASS: branch execute");
        $finish;
    end

endmodule
