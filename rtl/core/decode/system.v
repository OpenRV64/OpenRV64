`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"

module openrv64_decode_system (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output reg                          valid_o,
    output reg                          illegal_o,
    output reg                          csr_o,
    output reg                          ecall_o,
    output reg                          ebreak_o,
    output reg                          sret_o,
    output reg                          mret_o
);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire [`RV64_FUNCT3_WIDTH-1:0] funct3 = `RV64_FUNCT3(instr_i);

    always @* begin
        valid_o   = 1'b0;
        illegal_o = 1'b1;
        csr_o     = 1'b0;
        ecall_o   = 1'b0;
        ebreak_o  = 1'b0;
        sret_o    = 1'b0;
        mret_o    = 1'b0;

        if (opcode == `RV64_OPCODE_SYSTEM) begin
            case (funct3)
                `RV64_FUNCT3_SYSTEM_PRIV: begin
                    if (instr_i == `RV64_INSTR_ECALL) begin
                        valid_o   = 1'b1;
                        illegal_o = 1'b0;
                        ecall_o   = 1'b1;
                    end else if (instr_i == `RV64_INSTR_EBREAK) begin
                        valid_o   = 1'b1;
                        illegal_o = 1'b0;
                        ebreak_o  = 1'b1;
                    end else if (instr_i == `RV64_INSTR_SRET) begin
                        valid_o   = 1'b1;
                        illegal_o = 1'b0;
                        sret_o    = 1'b1;
                    end else if (instr_i == `RV64_INSTR_MRET) begin
                        valid_o   = 1'b1;
                        illegal_o = 1'b0;
                        mret_o    = 1'b1;
                    end else if (`RV64_IS_SFENCE_VMA(instr_i)) begin
                        valid_o   = 1'b1;
                        illegal_o = 1'b0;
                    end
                end

                `RV64_ZICSR_FUNCT3_CSRRW,
                `RV64_ZICSR_FUNCT3_CSRRS,
                `RV64_ZICSR_FUNCT3_CSRRC,
                `RV64_ZICSR_FUNCT3_CSRRWI,
                `RV64_ZICSR_FUNCT3_CSRRSI,
                `RV64_ZICSR_FUNCT3_CSRRCI: begin
                    valid_o   = 1'b1;
                    illegal_o = 1'b0;
                    csr_o     = 1'b1;
                end

                default: begin
                end
            endcase
        end
    end

endmodule
