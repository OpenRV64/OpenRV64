`timescale 1ns/1ps
`include "core/decode/reg/alu.v"
`timescale 1ns/1ps

module tb_decode_reg_alu;

    logic [31:0] instr;
    logic        valid;
    logic        uses_rs1;
    logic        uses_rs2;
    logic        uses_rd;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;

    openrv64_decode_reg_alu dut (
        .instr_i(instr),
        .valid_o(valid),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rd_o(uses_rd),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rd_addr_o(rd_addr)
    );

    function automatic [31:0] make_r;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            make_r = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] make_i;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            make_i = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] make_u;
        input [19:0] imm;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            make_u = {imm, rd, opcode};
        end
    endfunction

    task automatic check(
        input logic [31:0] in_instr,
        input logic exp_valid,
        input logic exp_uses_rs1,
        input logic exp_uses_rs2,
        input logic exp_uses_rd,
        input logic [`RV64_REG_ADDR_WIDTH-1:0] exp_rs1,
        input logic [`RV64_REG_ADDR_WIDTH-1:0] exp_rs2,
        input logic [`RV64_REG_ADDR_WIDTH-1:0] exp_rd
    );
        begin
            instr = in_instr;
            #1;

            if (valid !== exp_valid ||
                uses_rs1 !== exp_uses_rs1 ||
                uses_rs2 !== exp_uses_rs2 ||
                uses_rd !== exp_uses_rd ||
                rs1_addr !== exp_rs1 ||
                rs2_addr !== exp_rs2 ||
                rd_addr !== exp_rd) begin
                $fatal(1,
                    "ALU reg decode mismatch instr=%08x valid=%0b rs1_en=%0b rs2_en=%0b rd_en=%0b rs1=%0d rs2=%0d rd=%0d",
                    in_instr, valid, uses_rs1, uses_rs2, uses_rd,
                    rs1_addr, rs2_addr, rd_addr);
            end
        end
    endtask

    initial begin
        check(make_u(20'h12345, 5'd6, `RV64_OPCODE_LUI),
              1'b1, 1'b0, 1'b0, 1'b1, 5'd0, 5'd0, 5'd6);

        check(make_u(20'hfedcb, 5'd7, `RV64_OPCODE_AUIPC),
              1'b1, 1'b0, 1'b0, 1'b1, 5'd0, 5'd0, 5'd7);

        check(make_i(12'h010, 5'd2, `RV64_FUNCT3_ADD_SUB, 5'd10, `RV64_OPCODE_OP_IMM),
              1'b1, 1'b1, 1'b0, 1'b1, 5'd2, 5'd0, 5'd10);

        check(make_i(12'h001, 5'd3, `RV64_FUNCT3_ADD_SUB, 5'd11, `RV64_OPCODE_OP_IMM_32),
              1'b1, 1'b1, 1'b0, 1'b1, 5'd3, 5'd0, 5'd11);

        check(make_r(`RV64_FUNCT7_ADD, 5'd4, 5'd3, `RV64_FUNCT3_ADD_SUB, 5'd5, `RV64_OPCODE_OP),
              1'b1, 1'b1, 1'b1, 1'b1, 5'd3, 5'd4, 5'd5);

        check(make_r(`RV64_FUNCT7_ADD, 5'd9, 5'd8, `RV64_FUNCT3_ADD_SUB, 5'd12, `RV64_OPCODE_OP_32),
              1'b1, 1'b1, 1'b1, 1'b1, 5'd8, 5'd9, 5'd12);

        check(make_i(12'h000, 5'd2, `RV64_FUNCT3_LD, 5'd1, `RV64_OPCODE_LOAD),
              1'b0, 1'b0, 1'b0, 1'b0, 5'd0, 5'd0, 5'd0);

        $display("PASS: ALU register decode");
        $finish;
    end

endmodule
