`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zifencei.v"

module openrv64_decode_fence (
    input  wire [`RV64_OPCODE_WIDTH-1:0] opcode_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,

    output reg                          valid_o,
    output reg                          illegal_o
);

    always @* begin
        valid_o = 1'b0;
        illegal_o = 1'b1;

        if (opcode_i == `RV64_OPCODE_MISC_MEM) begin
            case (funct3_i)
                `RV64_FUNCT3_FENCE,
                `RV64_ZIFENCEI_FUNCT3_FENCE_I: begin
                    valid_o = 1'b1;
                    illegal_o = 1'b0;
                end
                default: begin
                end
            endcase
        end
    end

endmodule
