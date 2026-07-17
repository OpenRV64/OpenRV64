`timescale 1ns/1ps
`include "core/decode/lsu.v"
`timescale 1ns/1ps

module tb_decode_lsu;

    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic                          valid;
    logic                          illegal;
    logic [`RV64_LSU_OP_WIDTH-1:0] op_sel;
    logic [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
    logic                          load;
    logic                          store;
    logic                          unsigned_load;
    logic                          disabled_valid;
    logic                          disabled_illegal;

    openrv64_decode_lsu dut (
        .instr_i(instr),
        .valid_o(valid),
        .illegal_o(illegal),
        .op_sel_o(op_sel),
        .size_sel_o(size_sel),
        .load_o(load),
        .store_o(store),
        .unsigned_o(unsigned_load)
    );

    openrv64_decode_lsu #(
        .ENABLE_RV64A(0)
    ) disabled_dut (
        .instr_i(instr),
        .valid_o(disabled_valid),
        .illegal_o(disabled_illegal)
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
            instr = {17'd0, in_funct3, 5'd0, in_opcode};
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

    task automatic check_atomic;
        input [4:0]                    in_funct5;
        input [`RV64_FUNCT3_WIDTH-1:0] in_funct3;
        input [`RV64_REG_ADDR_WIDTH-1:0] in_rs2;
        input                          exp_valid;
        input [`RV64_LSU_OP_WIDTH-1:0] exp_op_sel;
        input                          exp_load;
        input                          exp_store;
        input [8*32-1:0]               label;
        begin
            instr = {in_funct5, 2'b11, in_rs2, 5'd3, in_funct3,
                     5'd4, `RV64_OPCODE_AMO};
            #1;

            if (valid !== exp_valid || illegal !== !exp_valid ||
                op_sel !== exp_op_sel ||
                size_sel !== (!exp_valid ? `RV64_LSU_SIZE_BYTE :
                    (in_funct3 == `RV64_AMO_FUNCT3_W) ?
                    `RV64_LSU_SIZE_WORD :
                    (in_funct3 == `RV64_AMO_FUNCT3_D) ?
                    `RV64_LSU_SIZE_DWORD : `RV64_LSU_SIZE_BYTE) ||
                load !== exp_load || store !== exp_store) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b illegal=%0b op=%0d/%0d size=%0d load=%0b/%0b store=%0b/%0b",
                    label, valid, exp_valid, illegal, op_sel, exp_op_sel,
                    size_sel, load, exp_load, store, exp_store);
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

        check_atomic(`RV64_AMO_FUNCT5_LR, `RV64_AMO_FUNCT3_W, 5'd0,
                     1'b1, `RV64_LSU_OP_LR, 1'b1, 1'b0, "lr.w aqrl");
        check_atomic(`RV64_AMO_FUNCT5_LR, `RV64_AMO_FUNCT3_D, 5'd1,
                     1'b0, `RV64_LSU_OP_INVALID, 1'b0, 1'b0,
                     "lr.d nonzero rs2");
        check_atomic(`RV64_AMO_FUNCT5_SC, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_SC, 1'b0, 1'b1, "sc.d");
        check_atomic(`RV64_AMO_FUNCT5_SWAP, `RV64_AMO_FUNCT3_W, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOSWAP, 1'b1, 1'b1, "amoswap.w");
        check_atomic(`RV64_AMO_FUNCT5_ADD, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOADD, 1'b1, 1'b1, "amoadd.d");
        check_atomic(`RV64_AMO_FUNCT5_XOR, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOXOR, 1'b1, 1'b1, "amoxor.d");
        check_atomic(`RV64_AMO_FUNCT5_OR, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOOR, 1'b1, 1'b1, "amoor.d");
        check_atomic(`RV64_AMO_FUNCT5_AND, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOAND, 1'b1, 1'b1, "amoand.d");
        check_atomic(`RV64_AMO_FUNCT5_MIN, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOMIN, 1'b1, 1'b1, "amomin.d");
        check_atomic(`RV64_AMO_FUNCT5_MAX, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOMAX, 1'b1, 1'b1, "amomax.d");
        check_atomic(`RV64_AMO_FUNCT5_MINU, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOMINU, 1'b1, 1'b1, "amominu.d");
        check_atomic(`RV64_AMO_FUNCT5_MAXU, `RV64_AMO_FUNCT3_D, 5'd5,
                     1'b1, `RV64_LSU_OP_AMOMAXU, 1'b1, 1'b1, "amomaxu.d");
        check_atomic(`RV64_AMO_FUNCT5_ADD, 3'b001, 5'd5,
                     1'b0, `RV64_LSU_OP_INVALID, 1'b0, 1'b0,
                     "invalid amo size");

        instr = {`RV64_AMO_FUNCT5_ADD, 2'b00, 5'd5, 5'd3,
                 `RV64_AMO_FUNCT3_D, 5'd4, `RV64_OPCODE_AMO};
        #1;
        if (disabled_valid || !disabled_illegal) begin
            $fatal(1, "disabled RV64A decoder accepted AMO");
        end

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
