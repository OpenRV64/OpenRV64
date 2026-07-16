`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/early-defs.v"

module openrv64_decode_imm (
    input  wire [`RV64_INSTR_WIDTH-1:0]        instr_i,
    input  wire [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_i,

    output reg                                 valid_o,
    output reg                                 has_imm_o,
    output reg [`RV64_XLEN-1:0]                imm_o,
    output wire [`RV64_XLEN-1:0]               imm_i_o,
    output wire [`RV64_XLEN-1:0]               imm_s_o,
    output wire [`RV64_XLEN-1:0]               imm_b_o,
    output wire [`RV64_XLEN-1:0]               imm_u_o,
    output wire [`RV64_XLEN-1:0]               imm_j_o
);

    assign imm_i_o = `RV64_IMM_I(instr_i);
    assign imm_s_o = `RV64_IMM_S(instr_i);
    assign imm_b_o = `RV64_IMM_B(instr_i);
    assign imm_u_o = `RV64_IMM_U(instr_i);
    assign imm_j_o = `RV64_IMM_J(instr_i);

    always @* begin
        valid_o   = 1'b0;
        has_imm_o = 1'b0;
        imm_o     = {`RV64_XLEN{1'b0}};

        case (format_sel_i)
            `RV64_EARLY_FORMAT_R: begin
                valid_o = 1'b1;
            end

            `RV64_EARLY_FORMAT_I: begin
                valid_o   = 1'b1;
                has_imm_o = 1'b1;
                imm_o     = imm_i_o;
            end

            `RV64_EARLY_FORMAT_S: begin
                valid_o   = 1'b1;
                has_imm_o = 1'b1;
                imm_o     = imm_s_o;
            end

            `RV64_EARLY_FORMAT_B: begin
                valid_o   = 1'b1;
                has_imm_o = 1'b1;
                imm_o     = imm_b_o;
            end

            `RV64_EARLY_FORMAT_U: begin
                valid_o   = 1'b1;
                has_imm_o = 1'b1;
                imm_o     = imm_u_o;
            end

            `RV64_EARLY_FORMAT_J: begin
                valid_o   = 1'b1;
                has_imm_o = 1'b1;
                imm_o     = imm_j_o;
            end

            default: begin
            end
        endcase
    end

endmodule
