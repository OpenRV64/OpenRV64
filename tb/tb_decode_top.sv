`timescale 1ns/1ps
`include "core/decode/decode_top.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zifencei.v"
`timescale 1ns/1ps

module tb_decode_top;

    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic valid;
    logic illegal;
    logic [`RV64_OPCODE_WIDTH-1:0] opcode;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic [`RV64_FUNCT7_WIDTH-1:0] funct7;
    logic [`RV64_FUNCT12_WIDTH-1:0] funct12;
    logic [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel;
    logic [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel;
    logic uses_rs1;
    logic uses_rs2;
    logic uses_rd;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;
    logic reg_write;
    logic imm_valid;
    logic has_imm;
    logic [`RV64_XLEN-1:0] imm;
    logic mem_read;
    logic mem_write;
    logic branch;
    logic jump;
    logic word_op;
    logic system_instr;
    logic fence_instr;
    logic [`RV64_ALU_EXT_WIDTH-1:0] alu_ext;
    logic [`RV64_ALU_OP_WIDTH-1:0] alu_op;
    logic [`RV64_LSU_OP_WIDTH-1:0] lsu_op;
    logic [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size;
    logic lsu_unsigned;
    logic [`RV64_BR_OP_WIDTH-1:0] br_op;
    logic br_link;
    logic br_indirect;
    logic subdecode_needed;
    logic extension_decode_possible;

    openrv64_decode_top dut (
        .instr_i(instr),
        .extension_selected_i(1'b0),
        .extension_valid_i(1'b0),
        .extension_illegal_i(1'b0),
        .extension_class_sel_i({`RV64_EARLY_CLASS_WIDTH{1'b0}}),
        .extension_format_sel_i({`RV64_EARLY_FORMAT_WIDTH{1'b0}}),
        .extension_uses_rs1_i(1'b0),
        .extension_uses_rs2_i(1'b0),
        .extension_uses_rd_i(1'b0),
        .extension_rs1_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rs2_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rd_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_reg_write_i(1'b0),
        .extension_imm_valid_i(1'b0),
        .extension_has_imm_i(1'b0),
        .extension_imm_i({`RV64_XLEN{1'b0}}),
        .extension_mem_read_i(1'b0),
        .extension_mem_write_i(1'b0),
        .extension_lsu_op_sel_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .extension_lsu_size_sel_i({`RV64_LSU_SIZE_WIDTH{1'b0}}),
        .extension_lsu_unsigned_i(1'b0),
        .extension_payload_i(1'b0),
        .valid_o(valid),
        .illegal_o(illegal),
        .opcode_o(opcode),
        .funct3_o(funct3),
        .funct7_o(funct7),
        .funct12_o(funct12),
        .class_sel_o(class_sel),
        .format_sel_o(format_sel),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rd_o(uses_rd),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rd_addr_o(rd_addr),
        .reg_write_o(reg_write),
        .imm_valid_o(imm_valid),
        .has_imm_o(has_imm),
        .imm_o(imm),
        .mem_read_o(mem_read),
        .mem_write_o(mem_write),
        .branch_o(branch),
        .jump_o(jump),
        .word_op_o(word_op),
        .system_o(system_instr),
        .fence_o(fence_instr),
        .alu_ext_sel_o(alu_ext),
        .alu_op_sel_o(alu_op),
        .lsu_op_sel_o(lsu_op),
        .lsu_size_sel_o(lsu_size),
        .lsu_unsigned_o(lsu_unsigned),
        .br_op_sel_o(br_op),
        .br_link_o(br_link),
        .br_indirect_o(br_indirect),
        .subdecode_needed_o(subdecode_needed),
        .extension_decode_possible_o(extension_decode_possible)
    );

    task automatic check_common;
        input exp_valid;
        input exp_illegal;
        input [`RV64_EARLY_CLASS_WIDTH-1:0] exp_class;
        input [`RV64_EARLY_FORMAT_WIDTH-1:0] exp_format;
        input exp_uses_rs1;
        input exp_uses_rs2;
        input exp_uses_rd;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs1_addr;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs2_addr;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rd_addr;
        input exp_reg_write;
        input exp_has_imm;
        input [`RV64_XLEN-1:0] exp_imm;
        input exp_mem_read;
        input exp_mem_write;
        input exp_branch;
        input exp_jump;
        input [`RV64_ALU_OP_WIDTH-1:0] exp_alu_op;
        input [`RV64_LSU_OP_WIDTH-1:0] exp_lsu_op;
        input [`RV64_BR_OP_WIDTH-1:0] exp_br_op;
        input [8*40-1:0] label;
        begin
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                class_sel !== exp_class ||
                format_sel !== exp_format ||
                uses_rs1 !== exp_uses_rs1 ||
                uses_rs2 !== exp_uses_rs2 ||
                uses_rd !== exp_uses_rd ||
                rs1_addr !== exp_rs1_addr ||
                rs2_addr !== exp_rs2_addr ||
                rd_addr !== exp_rd_addr ||
                reg_write !== exp_reg_write ||
                has_imm !== exp_has_imm ||
                imm !== exp_imm ||
                mem_read !== exp_mem_read ||
                mem_write !== exp_mem_write ||
                branch !== exp_branch ||
                jump !== exp_jump ||
                alu_op !== exp_alu_op ||
                lsu_op !== exp_lsu_op ||
                br_op !== exp_br_op) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b illegal=%0b/%0b class=%0d/%0d fmt=%0d/%0d rs1=%0b:%0d/%0b:%0d rs2=%0b:%0d/%0b:%0d rd=%0b:%0d/%0b:%0d regw=%0b/%0b has_imm=%0b/%0b imm=%016x/%016x memr=%0b/%0b memw=%0b/%0b br=%0b/%0b jump=%0b/%0b alu=%0d/%0d lsu=%0d/%0d br_op=%0d/%0d",
                    label,
                    valid, exp_valid,
                    illegal, exp_illegal,
                    class_sel, exp_class,
                    format_sel, exp_format,
                    uses_rs1, rs1_addr, exp_uses_rs1, exp_rs1_addr,
                    uses_rs2, rs2_addr, exp_uses_rs2, exp_rs2_addr,
                    uses_rd, rd_addr, exp_uses_rd, exp_rd_addr,
                    reg_write, exp_reg_write,
                    has_imm, exp_has_imm,
                    imm, exp_imm,
                    mem_read, exp_mem_read,
                    mem_write, exp_mem_write,
                    branch, exp_branch,
                    jump, exp_jump,
                    alu_op, exp_alu_op,
                    lsu_op, exp_lsu_op,
                    br_op, exp_br_op);
            end
        end
    endtask

    initial begin
        instr = {`RV64_FUNCT7_ADD, 5'd2, 5'd1, `RV64_FUNCT3_ADD_SUB, 5'd3, `RV64_OPCODE_OP};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_R,
                     1'b1, 1'b1, 1'b1, 5'd1, 5'd2, 5'd3, 1'b1,
                     1'b0, 64'h0, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_ADD, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "add");

        instr = {12'hfff, 5'd6, `RV64_FUNCT3_ADD_SUB, 5'd5, `RV64_OPCODE_OP_IMM};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_ALU, `RV64_EARLY_FORMAT_I,
                     1'b1, 1'b0, 1'b1, 5'd6, `RV64_REG_X0, 5'd5, 1'b1,
                     1'b1, 64'hffff_ffff_ffff_ffff, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_ADD, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "addi");

        instr = {12'd16, 5'd6, `RV64_FUNCT3_LD, 5'd5, `RV64_OPCODE_LOAD};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_I,
                     1'b1, 1'b0, 1'b1, 5'd6, `RV64_REG_X0, 5'd5, 1'b1,
                     1'b1, 64'h10, 1'b1, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_LD, `RV64_BR_OP_INVALID,
                     "ld");

        instr = {7'd1, 5'd8, 5'd7, `RV64_FUNCT3_SD, 5'd0, `RV64_OPCODE_STORE};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_S,
                     1'b1, 1'b1, 1'b0, 5'd7, 5'd8, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h20, 1'b0, 1'b1, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_SD, `RV64_BR_OP_INVALID,
                     "sd");

        instr = {`RV64_AMO_FUNCT5_LR, 2'b11, 5'd0, 5'd7,
                 `RV64_AMO_FUNCT3_W, 5'd9, `RV64_OPCODE_AMO};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_R,
                     1'b1, 1'b0, 1'b1, 5'd7, `RV64_REG_X0, 5'd9, 1'b1,
                     1'b0, 64'h0, 1'b1, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_LR, `RV64_BR_OP_INVALID,
                     "lr.w aqrl");

        instr = {`RV64_AMO_FUNCT5_ADD, 2'b00, 5'd8, 5'd7,
                 `RV64_AMO_FUNCT3_D, 5'd9, `RV64_OPCODE_AMO};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_MEM, `RV64_EARLY_FORMAT_R,
                     1'b1, 1'b1, 1'b1, 5'd7, 5'd8, 5'd9, 1'b1,
                     1'b0, 64'h0, 1'b1, 1'b1, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_AMOADD,
                     `RV64_BR_OP_INVALID, "amoadd.d");

        instr = {1'b0, 6'b000000, 5'd2, 5'd1, `RV64_FUNCT3_BEQ, 4'b1000, 1'b0, `RV64_OPCODE_BRANCH};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_BRANCH, `RV64_EARLY_FORMAT_B,
                     1'b1, 1'b1, 1'b0, 5'd1, 5'd2, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h10, 1'b0, 1'b0, 1'b1, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_BEQ,
                     "beq");

        instr = {1'b0, 10'b0000000000, 1'b1, 8'h00, 5'd1, `RV64_OPCODE_JAL};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_JUMP, `RV64_EARLY_FORMAT_J,
                     1'b0, 1'b0, 1'b1, `RV64_REG_X0, `RV64_REG_X0, 5'd1, 1'b1,
                     1'b1, 64'h800, 1'b0, 1'b0, 1'b0, 1'b1,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_JAL,
                     "jal");

        if (!br_link) begin
            $fatal(1, "jal did not assert branch link output");
        end

        instr = {12'h010, 5'd3, `RV64_FUNCT3_JALR, 5'd4, `RV64_OPCODE_JALR};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_JUMP, `RV64_EARLY_FORMAT_I,
                     1'b1, 1'b0, 1'b1, 5'd3, `RV64_REG_X0, 5'd4, 1'b1,
                     1'b1, 64'h10, 1'b0, 1'b0, 1'b0, 1'b1,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_JALR,
                     "jalr");

        if (!br_link || !br_indirect) begin
            $fatal(1, "jalr did not assert link/indirect outputs");
        end

        instr = 32'h0ff0_000f;
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_FENCE, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h0ff, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "fence");
        if (!fence_instr) begin
            $fatal(1, "fence did not assert fence output");
        end

        instr = `RV64_INSTR_FENCE_I;
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_FENCE, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h0, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "fence.i");
        if (!fence_instr) begin
            $fatal(1, "fence.i did not assert fence output");
        end

        instr = 32'h0000_200f;
        check_common(1'b0, 1'b1, `RV64_EARLY_CLASS_FENCE, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h0, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "invalid misc-mem funct3");

        instr = {`RV64_CSR_MTVEC, 5'd4,
                 `RV64_ZICSR_FUNCT3_CSRRW, 5'd5,
                 `RV64_OPCODE_SYSTEM};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b1, 1'b0, 1'b1, 5'd4, `RV64_REG_X0, 5'd5, 1'b1,
                     1'b1, 64'h305, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "csrrw");

        if (!system_instr) begin
            $fatal(1, "csrrw did not assert system output");
        end

        instr = {`RV64_CSR_MSTATUS, 5'd7,
                 `RV64_ZICSR_FUNCT3_CSRRWI, 5'd6,
                 `RV64_OPCODE_SYSTEM};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b1, `RV64_REG_X0, `RV64_REG_X0, 5'd6, 1'b1,
                     1'b1, 64'h300, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "csrrwi");

        instr = `RV64_INSTR_MRET;
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h302, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "mret");

        instr = `RV64_INSTR_SRET;
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h102, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "sret");

        instr = `RV64_INSTR_WFI;
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0,
                     `RV64_REG_X0, 1'b0, 1'b1, 64'h105,
                     1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID,
                     `RV64_BR_OP_INVALID, "wfi hint");

        instr = {`RV64_PRIV_FUNCT7_SFENCE_VMA, 5'd2, 5'd1,
                 `RV64_FUNCT3_SYSTEM_PRIV, 5'd0, `RV64_OPCODE_SYSTEM};
        check_common(1'b1, 1'b0, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h122, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "sfence.vma full-flush decode");
        if (!system_instr) begin
            $fatal(1, "sfence.vma did not assert system output");
        end

        instr = {12'h300, 5'd0, 3'b100, 5'd0, `RV64_OPCODE_SYSTEM};
        check_common(1'b0, 1'b1, `RV64_EARLY_CLASS_SYSTEM, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h300, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "invalid system funct3");

        instr = {12'h000, 5'd1, 3'b001, 5'd2, `RV64_OPCODE_JALR};
        check_common(1'b0, 1'b1, `RV64_EARLY_CLASS_JUMP, `RV64_EARLY_FORMAT_I,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b1, 64'h0, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "invalid jalr funct3");

        // An unclaimed extension opcode reaches ordinary illegal-instruction
        // handling in the legacy integer-only configuration.
        instr = {25'd0, 7'b0001011};
        check_common(1'b0, 1'b1, `RV64_EARLY_CLASS_EXTENSION,
                     `RV64_EARLY_FORMAT_INVALID,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0,
                     `RV64_REG_X0, 1'b0, 1'b0, 64'h0,
                     1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID,
                     `RV64_BR_OP_INVALID, "unclaimed extension opcode");

        instr = 32'h0000_0000;
        check_common(1'b0, 1'b1, `RV64_EARLY_CLASS_INVALID, `RV64_EARLY_FORMAT_INVALID,
                     1'b0, 1'b0, 1'b0, `RV64_REG_X0, `RV64_REG_X0, `RV64_REG_X0, 1'b0,
                     1'b0, 64'h0, 1'b0, 1'b0, 1'b0, 1'b0,
                     `RV64_ALU_OP_INVALID, `RV64_LSU_OP_INVALID, `RV64_BR_OP_INVALID,
                     "invalid opcode");

        $display("PASS: decode top routing");
        $finish;
    end

endmodule
