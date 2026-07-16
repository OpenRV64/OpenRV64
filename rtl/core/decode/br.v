`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/br-defs.v"

module openrv64_decode_br (
    input  wire [`RV64_OPCODE_WIDTH-1:0] opcode_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,

    output reg                           valid_o,
    output reg                           illegal_o,
    output reg [`RV64_BR_OP_WIDTH-1:0]   op_sel_o,
    output reg                           branch_o,
    output reg                           jump_o,
    output reg                           link_o,
    output reg                           indirect_o
);

    task automatic accept;
        input [`RV64_BR_OP_WIDTH-1:0] op_sel;
        input is_branch;
        input is_jump;
        input is_indirect;
        begin
            valid_o    = 1'b1;
            illegal_o  = 1'b0;
            op_sel_o   = op_sel;
            branch_o   = is_branch;
            jump_o     = is_jump;
            link_o     = is_jump;
            indirect_o = is_indirect;
        end
    endtask

    always @* begin
        valid_o    = 1'b0;
        illegal_o  = 1'b1;
        op_sel_o   = `RV64_BR_OP_INVALID;
        branch_o   = 1'b0;
        jump_o     = 1'b0;
        link_o     = 1'b0;
        indirect_o = 1'b0;

        case (opcode_i)
            `RV64_OPCODE_BRANCH: begin
                branch_o = 1'b1;

                case (funct3_i)
                    `RV64_FUNCT3_BEQ:  accept(`RV64_BR_OP_BEQ,  1'b1, 1'b0, 1'b0);
                    `RV64_FUNCT3_BNE:  accept(`RV64_BR_OP_BNE,  1'b1, 1'b0, 1'b0);
                    `RV64_FUNCT3_BLT:  accept(`RV64_BR_OP_BLT,  1'b1, 1'b0, 1'b0);
                    `RV64_FUNCT3_BGE:  accept(`RV64_BR_OP_BGE,  1'b1, 1'b0, 1'b0);
                    `RV64_FUNCT3_BLTU: accept(`RV64_BR_OP_BLTU, 1'b1, 1'b0, 1'b0);
                    `RV64_FUNCT3_BGEU: accept(`RV64_BR_OP_BGEU, 1'b1, 1'b0, 1'b0);
                    default: begin
                    end
                endcase
            end

            `RV64_OPCODE_JAL: begin
                accept(`RV64_BR_OP_JAL, 1'b0, 1'b1, 1'b0);
            end

            `RV64_OPCODE_JALR: begin
                jump_o     = 1'b1;
                indirect_o = 1'b1;

                if (funct3_i == `RV64_FUNCT3_JALR) begin
                    accept(`RV64_BR_OP_JALR, 1'b0, 1'b1, 1'b1);
                end
            end

            default: begin
            end
        endcase
    end

endmodule
