`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_decode_reg_alu (
    input  wire [31:0] instr_i,

    output reg         valid_o,
    output reg         uses_rs1_o,
    output reg         uses_rs2_o,
    output reg         uses_rd_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o
);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);

    always @* begin
        valid_o     = 1'b0;
        uses_rs1_o  = 1'b0;
        uses_rs2_o  = 1'b0;
        uses_rd_o   = 1'b0;
        rs1_addr_o  = 5'd0;
        rs2_addr_o  = 5'd0;
        rd_addr_o   = 5'd0;

        case (opcode)
            `RV64_OPCODE_LUI,
            `RV64_OPCODE_AUIPC: begin
                valid_o    = 1'b1;
                uses_rd_o  = 1'b1;
                rd_addr_o  = `RV64_RD(instr_i);
            end

            `RV64_OPCODE_OP_IMM,
            `RV64_OPCODE_OP_IMM_32: begin
                valid_o     = 1'b1;
                uses_rs1_o  = 1'b1;
                uses_rd_o   = 1'b1;
                rs1_addr_o  = `RV64_RS1(instr_i);
                rd_addr_o   = `RV64_RD(instr_i);
            end

            `RV64_OPCODE_OP,
            `RV64_OPCODE_OP_32: begin
                valid_o     = 1'b1;
                uses_rs1_o  = 1'b1;
                uses_rs2_o  = 1'b1;
                uses_rd_o   = 1'b1;
                rs1_addr_o  = `RV64_RS1(instr_i);
                rs2_addr_o  = `RV64_RS2(instr_i);
                rd_addr_o   = `RV64_RD(instr_i);
            end

            default: begin
            end
        endcase
    end

endmodule
