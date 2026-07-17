`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"

module openrv64_decode_reg_system (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output reg                          valid_o,
    output reg                          uses_rs1_o,
    output reg                          uses_rs2_o,
    output reg                          uses_rd_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output reg [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o
);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire [`RV64_FUNCT3_WIDTH-1:0] funct3 = `RV64_FUNCT3(instr_i);

    always @* begin
        valid_o    = 1'b0;
        uses_rs1_o = 1'b0;
        uses_rs2_o = 1'b0;
        uses_rd_o  = 1'b0;
        rs1_addr_o = `RV64_REG_X0;
        rs2_addr_o = `RV64_REG_X0;
        rd_addr_o  = `RV64_REG_X0;

        if (opcode == `RV64_OPCODE_SYSTEM) begin
            case (funct3)
                `RV64_FUNCT3_SYSTEM_PRIV: begin
                    valid_o = 1'b1;
                end

                `RV64_ZICSR_FUNCT3_CSRRW,
                `RV64_ZICSR_FUNCT3_CSRRS,
                `RV64_ZICSR_FUNCT3_CSRRC: begin
                    valid_o    = 1'b1;
                    uses_rs1_o = 1'b1;
                    uses_rd_o  = 1'b1;
                    rs1_addr_o = `RV64_RS1(instr_i);
                    rd_addr_o  = `RV64_RD(instr_i);
                end

                `RV64_ZICSR_FUNCT3_CSRRWI,
                `RV64_ZICSR_FUNCT3_CSRRSI,
                `RV64_ZICSR_FUNCT3_CSRRCI: begin
                    valid_o   = 1'b1;
                    uses_rd_o = 1'b1;
                    rd_addr_o = `RV64_RD(instr_i);
                end

                default: begin
                end
            endcase
        end
    end

endmodule
