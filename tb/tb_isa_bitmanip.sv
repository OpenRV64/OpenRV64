`timescale 1ns/1ps
`include "core/isa/rv64-b.v"
`include "core/isa/rv64-zbc.v"
`timescale 1ns/1ps

module tb_isa_bitmanip;

    function automatic [31:0] r_type;
        input [6:0] funct7;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            r_type = {funct7, 5'd0, 5'd0, funct3, 5'd0, opcode};
        end
    endfunction

    function automatic [31:0] i_funct12;
        input [11:0] funct12;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            i_funct12 = {funct12, 5'd0, funct3, 5'd0, opcode};
        end
    endfunction

    function automatic [31:0] i_funct6;
        input [5:0] funct6;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            i_funct6 = {funct6, 6'd0, 5'd0, funct3, 5'd0, opcode};
        end
    endfunction

    task automatic check;
        input [31:0] actual;
        input [31:0] expected;
        input [8*16-1:0] name;
        begin
            if (actual !== expected) begin
                $fatal(1, "%0s encoding mismatch: actual=%08x expected=%08x",
                       name, actual, expected);
            end
        end
    endtask

    initial begin
        check(r_type(`RV64_ZBA_FUNCT7_SHADD, `RV64_ZBA_FUNCT3_SH1ADD, `RV64_ZBA_OPCODE_SHADD),
              32'h2000_2033, "sh1add");
        check(r_type(`RV64_ZBA_FUNCT7_ADD_UW, `RV64_ZBA_FUNCT3_ADD_UW, `RV64_ZBA_OPCODE_UW),
              32'h0800_003b, "add.uw");
        check(i_funct6(`RV64_ZBA_FUNCT6_SLLI_UW, `RV64_ZBA_FUNCT3_SLLI_UW, `RV64_ZBA_OPCODE_SLLI_UW),
              32'h0800_101b, "slli.uw");

        check(r_type(`RV64_ZBB_FUNCT7_LOGIC_N, `RV64_ZBB_FUNCT3_ANDN, `RV64_ZBB_OPCODE_REG),
              32'h4000_7033, "andn");
        check(r_type(`RV64_ZBB_FUNCT7_MINMAX, `RV64_ZBB_FUNCT3_MIN, `RV64_ZBB_OPCODE_REG),
              32'h0a00_4033, "min");
        check(i_funct12(`RV64_ZBB_FUNCT12_CLZ, `RV64_ZBB_FUNCT3_UNARY, `RV64_ZBB_OPCODE_IMM),
              32'h6000_1013, "clz");
        check(i_funct12(`RV64_ZBB_FUNCT12_ORC_B, `RV64_ZBB_FUNCT3_ORC_B, `RV64_ZBB_OPCODE_IMM),
              32'h2870_5013, "orc.b");
        check(i_funct12(`RV64_ZBB_FUNCT12_REV8, `RV64_ZBB_FUNCT3_REV8, `RV64_ZBB_OPCODE_IMM),
              32'h6b80_5013, "rev8");
        check(r_type(`RV64_ZBB_FUNCT7_ZEXT_H, `RV64_ZBB_FUNCT3_ZEXT_H, `RV64_ZBB_OPCODE_ZEXT_H),
              32'h0800_403b, "zext.h");

        check(r_type(`RV64_ZBC_FUNCT7_CLMUL, `RV64_ZBC_FUNCT3_CLMUL, `RV64_ZBC_OPCODE),
              32'h0a00_1033, "clmul");

        check(r_type(`RV64_ZBS_FUNCT7_BSET, `RV64_ZBS_FUNCT3_BSET, `RV64_ZBS_OPCODE_REG),
              32'h2800_1033, "bset");
        check(r_type(`RV64_ZBS_FUNCT7_BCLR, `RV64_ZBS_FUNCT3_BCLR, `RV64_ZBS_OPCODE_REG),
              32'h4800_1033, "bclr");
        check(i_funct6(`RV64_ZBS_FUNCT6_BSETI, `RV64_ZBS_FUNCT3_BSETI, `RV64_ZBS_OPCODE_IMM),
              32'h2800_1013, "bseti");
        check(i_funct6(`RV64_ZBS_FUNCT6_BEXTI, `RV64_ZBS_FUNCT3_BEXTI, `RV64_ZBS_OPCODE_IMM),
              32'h4800_5013, "bexti");

        $display("PASS: bitmanip ISA constants");
        $finish;
    end

endmodule
