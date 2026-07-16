`timescale 1ns/1ps
`include "core/decode/lsu.v"
`timescale 1ns/1ps

module tb_decode_lsu;

    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic                          valid;
    logic                          illegal;
    logic [`RV64_LSU_OP_WIDTH-1:0] op_sel;
    logic [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
    logic                          load;
    logic                          store;
    logic                          unsigned_load;

    openrv64_decode_lsu dut (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .valid_o(valid),
        .illegal_o(illegal),
        .op_sel_o(op_sel),
        .size_sel_o(size_sel),
        .load_o(load),
        .store_o(store),
        .unsigned_o(unsigned_load)
    );

    task automatic check;
        input [`RV64_OPCODE_WIDTH-1:0] in_opcode;
        input [`RV64_FUNCT3_WIDTH-1:0] in_funct3;
        input                          exp_valid;
        input                          exp_illegal;
        input [`RV64_LSU_OP_WIDTH-1:0] exp_op_sel;
        input [`RV64_LSU_SIZE_WIDTH-1:0] exp_size_sel;
        input                          exp_load;
        input                          exp_store;
        input                          exp_unsigned;
        input [8*32-1:0]               label;
        begin
            opcode = in_opcode;
            funct3 = in_funct3;
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                op_sel !== exp_op_sel ||
                size_sel !== exp_size_sel ||
                load !== exp_load ||
                store !== exp_store ||
                unsigned_load !== exp_unsigned) begin
                $fatal(1,
                    "%0s: valid=%0b expected=%0b illegal=%0b expected=%0b op=%0d expected=%0d size=%0d expected=%0d load=%0b expected=%0b store=%0b expected=%0b unsigned=%0b expected=%0b",
                    label, valid, exp_valid, illegal, exp_illegal, op_sel, exp_op_sel,
                    size_sel, exp_size_sel, load, exp_load, store, exp_store,
                    unsigned_load, exp_unsigned);
            end
        end
    endtask

    initial begin
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LB,
              1'b1, 1'b0, `RV64_LSU_OP_LB, `RV64_LSU_SIZE_BYTE, 1'b1, 1'b0, 1'b0, "lb");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LH,
              1'b1, 1'b0, `RV64_LSU_OP_LH, `RV64_LSU_SIZE_HALF, 1'b1, 1'b0, 1'b0, "lh");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LW,
              1'b1, 1'b0, `RV64_LSU_OP_LW, `RV64_LSU_SIZE_WORD, 1'b1, 1'b0, 1'b0, "lw");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LD,
              1'b1, 1'b0, `RV64_LSU_OP_LD, `RV64_LSU_SIZE_DWORD, 1'b1, 1'b0, 1'b0, "ld");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LBU,
              1'b1, 1'b0, `RV64_LSU_OP_LBU, `RV64_LSU_SIZE_BYTE, 1'b1, 1'b0, 1'b1, "lbu");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LHU,
              1'b1, 1'b0, `RV64_LSU_OP_LHU, `RV64_LSU_SIZE_HALF, 1'b1, 1'b0, 1'b1, "lhu");
        check(`RV64_OPCODE_LOAD, `RV64_FUNCT3_LWU,
              1'b1, 1'b0, `RV64_LSU_OP_LWU, `RV64_LSU_SIZE_WORD, 1'b1, 1'b0, 1'b1, "lwu");

        check(`RV64_OPCODE_STORE, `RV64_FUNCT3_SB,
              1'b1, 1'b0, `RV64_LSU_OP_SB, `RV64_LSU_SIZE_BYTE, 1'b0, 1'b1, 1'b0, "sb");
        check(`RV64_OPCODE_STORE, `RV64_FUNCT3_SH,
              1'b1, 1'b0, `RV64_LSU_OP_SH, `RV64_LSU_SIZE_HALF, 1'b0, 1'b1, 1'b0, "sh");
        check(`RV64_OPCODE_STORE, `RV64_FUNCT3_SW,
              1'b1, 1'b0, `RV64_LSU_OP_SW, `RV64_LSU_SIZE_WORD, 1'b0, 1'b1, 1'b0, "sw");
        check(`RV64_OPCODE_STORE, `RV64_FUNCT3_SD,
              1'b1, 1'b0, `RV64_LSU_OP_SD, `RV64_LSU_SIZE_DWORD, 1'b0, 1'b1, 1'b0, "sd");

        check(`RV64_OPCODE_LOAD, 3'b111,
              1'b0, 1'b1, `RV64_LSU_OP_INVALID, `RV64_LSU_SIZE_BYTE, 1'b1, 1'b0, 1'b0, "invalid load funct3");
        check(`RV64_OPCODE_STORE, 3'b100,
              1'b0, 1'b1, `RV64_LSU_OP_INVALID, `RV64_LSU_SIZE_BYTE, 1'b0, 1'b1, 1'b0, "invalid store funct3");
        check(`RV64_OPCODE_OP, `RV64_FUNCT3_ADD_SUB,
              1'b0, 1'b1, `RV64_LSU_OP_INVALID, `RV64_LSU_SIZE_BYTE, 1'b0, 1'b0, 1'b0, "non-lsu opcode");

        $display("PASS: LSU decode");
        $finish;
    end

endmodule
