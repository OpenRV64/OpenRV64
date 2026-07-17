`timescale 1ns/1ps
`include "core/decode/reg/lsu.v"
`timescale 1ns/1ps

module tb_decode_reg_lsu;

    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic valid;
    logic uses_rs1;
    logic uses_rs2;
    logic uses_rd;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;

    openrv64_decode_reg_lsu dut (
        .instr_i(instr),
        .valid_o(valid),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rd_o(uses_rd),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rd_addr_o(rd_addr)
    );

    task automatic check;
        input [`RV64_INSTR_WIDTH-1:0] in_instr;
        input exp_valid;
        input exp_uses_rs1;
        input exp_uses_rs2;
        input exp_uses_rd;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs1_addr;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs2_addr;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rd_addr;
        input [8*32-1:0] label;
        begin
            instr = in_instr;
            #1;

            if (valid !== exp_valid ||
                uses_rs1 !== exp_uses_rs1 ||
                uses_rs2 !== exp_uses_rs2 ||
                uses_rd !== exp_uses_rd ||
                rs1_addr !== exp_rs1_addr ||
                rs2_addr !== exp_rs2_addr ||
                rd_addr !== exp_rd_addr) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b rs1=%0b/%0b:%0d/%0d rs2=%0b/%0b:%0d/%0d rd=%0b/%0b:%0d/%0d",
                    label, valid, exp_valid,
                    uses_rs1, exp_uses_rs1, rs1_addr, exp_rs1_addr,
                    uses_rs2, exp_uses_rs2, rs2_addr, exp_rs2_addr,
                    uses_rd, exp_uses_rd, rd_addr, exp_rd_addr);
            end
        end
    endtask

    initial begin
        check({12'h010, 5'd6, `RV64_FUNCT3_LD, 5'd5, `RV64_OPCODE_LOAD},
              1'b1, 1'b1, 1'b0, 1'b1, 5'd6, `RV64_REG_X0, 5'd5, "load regs");

        check({7'b0000000, 5'd8, 5'd7, `RV64_FUNCT3_SD, 5'b00000, `RV64_OPCODE_STORE},
              1'b1, 1'b1, 1'b1, 1'b0, 5'd7, 5'd8, `RV64_REG_X0, "store regs");

        check({`RV64_AMO_FUNCT5_LR, 2'b00, 5'd0, 5'd7,
               `RV64_AMO_FUNCT3_W, 5'd9, `RV64_OPCODE_AMO},
              1'b1, 1'b1, 1'b0, 1'b1, 5'd7, `RV64_REG_X0, 5'd9,
              "lr regs");

        check({`RV64_AMO_FUNCT5_ADD, 2'b00, 5'd8, 5'd7,
               `RV64_AMO_FUNCT3_D, 5'd9, `RV64_OPCODE_AMO},
              1'b1, 1'b1, 1'b1, 1'b1, 5'd7, 5'd8, 5'd9,
              "amo regs");

        check({`RV64_FUNCT7_ADD, 5'd2, 5'd1, `RV64_FUNCT3_ADD_SUB, 5'd3, `RV64_OPCODE_OP},
              1'b0, 1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, "non lsu");

        $display("PASS: LSU register decode");
        $finish;
    end

endmodule
