`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/early-defs.v"

module openrv64_decode_early (
    input  wire [`RV64_OPCODE_WIDTH-1:0] opcode_i,

    output reg                         valid_o,
    output reg [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel_o,
    output reg [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_o,

    output reg                         uses_rs1_o,
    output reg                         uses_rs2_o,
    output reg                         uses_rd_o,
    output reg                         reg_write_o,

    output reg                         mem_read_o,
    output reg                         mem_write_o,
    output reg                         branch_o,
    output reg                         jump_o,
    output reg                         word_op_o,

    output reg                         subdecode_needed_o,
    output reg                         extension_decode_possible_o
);

    always @* begin
        valid_o                     = 1'b0;
        class_sel_o                 = `RV64_EARLY_CLASS_INVALID;
        format_sel_o                = `RV64_EARLY_FORMAT_INVALID;
        uses_rs1_o                  = 1'b0;
        uses_rs2_o                  = 1'b0;
        uses_rd_o                   = 1'b0;
        reg_write_o                 = 1'b0;
        mem_read_o                  = 1'b0;
        mem_write_o                 = 1'b0;
        branch_o                    = 1'b0;
        jump_o                      = 1'b0;
        word_op_o                   = 1'b0;
        subdecode_needed_o          = 1'b0;
        extension_decode_possible_o = 1'b0;

        case (opcode_i)
            `RV64_OPCODE_LUI,
            `RV64_OPCODE_AUIPC: begin
                valid_o      = 1'b1;
                class_sel_o  = `RV64_EARLY_CLASS_ALU;
                format_sel_o = `RV64_EARLY_FORMAT_U;
                uses_rd_o    = 1'b1;
                reg_write_o  = 1'b1;
            end

            `RV64_OPCODE_JAL: begin
                valid_o      = 1'b1;
                class_sel_o  = `RV64_EARLY_CLASS_JUMP;
                format_sel_o = `RV64_EARLY_FORMAT_J;
                uses_rd_o    = 1'b1;
                reg_write_o  = 1'b1;
                jump_o       = 1'b1;
            end

            `RV64_OPCODE_JALR: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_JUMP;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                uses_rs1_o         = 1'b1;
                uses_rd_o          = 1'b1;
                reg_write_o        = 1'b1;
                jump_o             = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_BRANCH: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_BRANCH;
                format_sel_o       = `RV64_EARLY_FORMAT_B;
                uses_rs1_o         = 1'b1;
                uses_rs2_o         = 1'b1;
                branch_o           = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_LOAD: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_MEM;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                uses_rs1_o         = 1'b1;
                uses_rd_o          = 1'b1;
                reg_write_o        = 1'b1;
                mem_read_o         = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_STORE: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_MEM;
                format_sel_o       = `RV64_EARLY_FORMAT_S;
                uses_rs1_o         = 1'b1;
                uses_rs2_o         = 1'b1;
                mem_write_o        = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_OP_IMM: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_ALU;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                uses_rs1_o         = 1'b1;
                uses_rd_o          = 1'b1;
                reg_write_o        = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_OP_IMM_32: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_ALU;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                uses_rs1_o         = 1'b1;
                uses_rd_o          = 1'b1;
                reg_write_o        = 1'b1;
                word_op_o          = 1'b1;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_OP: begin
                valid_o                     = 1'b1;
                class_sel_o                 = `RV64_EARLY_CLASS_ALU;
                format_sel_o                = `RV64_EARLY_FORMAT_R;
                uses_rs1_o                  = 1'b1;
                uses_rs2_o                  = 1'b1;
                uses_rd_o                   = 1'b1;
                reg_write_o                 = 1'b1;
                subdecode_needed_o          = 1'b1;
                extension_decode_possible_o = 1'b1;
            end

            `RV64_OPCODE_OP_32: begin
                valid_o                     = 1'b1;
                class_sel_o                 = `RV64_EARLY_CLASS_ALU;
                format_sel_o                = `RV64_EARLY_FORMAT_R;
                uses_rs1_o                  = 1'b1;
                uses_rs2_o                  = 1'b1;
                uses_rd_o                   = 1'b1;
                reg_write_o                 = 1'b1;
                word_op_o                   = 1'b1;
                subdecode_needed_o          = 1'b1;
                extension_decode_possible_o = 1'b1;
            end

            `RV64_OPCODE_MISC_MEM: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_FENCE;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                subdecode_needed_o = 1'b1;
            end

            `RV64_OPCODE_SYSTEM: begin
                valid_o            = 1'b1;
                class_sel_o        = `RV64_EARLY_CLASS_SYSTEM;
                format_sel_o       = `RV64_EARLY_FORMAT_I;
                subdecode_needed_o = 1'b1;
            end

            default: begin
                valid_o = 1'b0;
            end
        endcase
    end

endmodule
