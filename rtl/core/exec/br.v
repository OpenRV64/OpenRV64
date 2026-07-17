`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/br-defs.v"

module openrv64_exec_br (
    input  wire [`RV64_BR_OP_WIDTH-1:0] op_sel_i,
    input  wire [`RV64_XLEN-1:0]        pc_i,
    input  wire [`RV64_XLEN-1:0]        src1_i,
    input  wire [`RV64_XLEN-1:0]        src2_i,
    input  wire [`RV64_XLEN-1:0]        imm_i,

    output reg                          valid_o,
    output reg                          illegal_o,
    output reg                          taken_o,
    output reg [`RV64_XLEN-1:0]         target_o,
    output reg                          link_o,
    output reg [`RV64_XLEN-1:0]         link_data_o
);

    wire [`RV64_XLEN-1:0] pc_plus_4 = pc_i + 64'd4;
    wire [`RV64_XLEN-1:0] pc_relative_target = pc_i + imm_i;
    wire [`RV64_XLEN-1:0] jalr_target = (src1_i + imm_i) & ~64'd1;

    task automatic accept_branch;
        input condition;
        begin
            valid_o     = 1'b1;
            illegal_o   = 1'b0;
            taken_o     = condition;
            target_o    = condition ? pc_relative_target : pc_plus_4;
            link_o      = 1'b0;
            link_data_o = {`RV64_XLEN{1'b0}};
        end
    endtask

    task automatic accept_jump;
        input [`RV64_XLEN-1:0] target;
        begin
            valid_o     = 1'b1;
            illegal_o   = 1'b0;
            taken_o     = 1'b1;
            target_o    = target;
            link_o      = 1'b1;
            link_data_o = pc_plus_4;
        end
    endtask

    always @* begin
        valid_o     = 1'b0;
        illegal_o   = 1'b1;
        taken_o     = 1'b0;
        target_o    = pc_plus_4;
        link_o      = 1'b0;
        link_data_o = {`RV64_XLEN{1'b0}};

        case (op_sel_i)
            `RV64_BR_OP_BEQ: begin
                accept_branch(src1_i == src2_i);
            end

            `RV64_BR_OP_BNE: begin
                accept_branch(src1_i != src2_i);
            end

            `RV64_BR_OP_BLT: begin
                accept_branch($signed(src1_i) < $signed(src2_i));
            end

            `RV64_BR_OP_BGE: begin
                accept_branch($signed(src1_i) >= $signed(src2_i));
            end

            `RV64_BR_OP_BLTU: begin
                accept_branch(src1_i < src2_i);
            end

            `RV64_BR_OP_BGEU: begin
                accept_branch(src1_i >= src2_i);
            end

            `RV64_BR_OP_JAL: begin
                accept_jump(pc_relative_target);
            end

            `RV64_BR_OP_JALR: begin
                accept_jump(jalr_target);
            end

            default: begin
            end
        endcase
    end

endmodule
