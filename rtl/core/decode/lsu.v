`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/lsu-defs.v"

module openrv64_decode_lsu (
    input  wire [`RV64_OPCODE_WIDTH-1:0] opcode_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,

    output reg                           valid_o,
    output reg                           illegal_o,
    output reg [`RV64_LSU_OP_WIDTH-1:0]  op_sel_o,
    output reg [`RV64_LSU_SIZE_WIDTH-1:0] size_sel_o,
    output reg                           load_o,
    output reg                           store_o,
    output reg                           unsigned_o
);

    task automatic accept;
        input [`RV64_LSU_OP_WIDTH-1:0] op_sel;
        input [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
        input is_load;
        input is_unsigned;
        begin
            valid_o    = 1'b1;
            illegal_o  = 1'b0;
            op_sel_o   = op_sel;
            size_sel_o = size_sel;
            load_o     = is_load;
            store_o    = !is_load;
            unsigned_o = is_unsigned;
        end
    endtask

    always @* begin
        valid_o    = 1'b0;
        illegal_o  = 1'b1;
        op_sel_o   = `RV64_LSU_OP_INVALID;
        size_sel_o = `RV64_LSU_SIZE_BYTE;
        load_o     = 1'b0;
        store_o    = 1'b0;
        unsigned_o = 1'b0;

        case (opcode_i)
            `RV64_OPCODE_LOAD: begin
                load_o = 1'b1;

                case (funct3_i)
                    `RV64_FUNCT3_LB:  accept(`RV64_LSU_OP_LB,  `RV64_LSU_SIZE_BYTE,  1'b1, 1'b0);
                    `RV64_FUNCT3_LH:  accept(`RV64_LSU_OP_LH,  `RV64_LSU_SIZE_HALF,  1'b1, 1'b0);
                    `RV64_FUNCT3_LW:  accept(`RV64_LSU_OP_LW,  `RV64_LSU_SIZE_WORD,  1'b1, 1'b0);
                    `RV64_FUNCT3_LD:  accept(`RV64_LSU_OP_LD,  `RV64_LSU_SIZE_DWORD, 1'b1, 1'b0);
                    `RV64_FUNCT3_LBU: accept(`RV64_LSU_OP_LBU, `RV64_LSU_SIZE_BYTE,  1'b1, 1'b1);
                    `RV64_FUNCT3_LHU: accept(`RV64_LSU_OP_LHU, `RV64_LSU_SIZE_HALF,  1'b1, 1'b1);
                    `RV64_FUNCT3_LWU: accept(`RV64_LSU_OP_LWU, `RV64_LSU_SIZE_WORD,  1'b1, 1'b1);
                    default: begin
                    end
                endcase
            end

            `RV64_OPCODE_STORE: begin
                store_o = 1'b1;

                case (funct3_i)
                    `RV64_FUNCT3_SB: accept(`RV64_LSU_OP_SB, `RV64_LSU_SIZE_BYTE,  1'b0, 1'b0);
                    `RV64_FUNCT3_SH: accept(`RV64_LSU_OP_SH, `RV64_LSU_SIZE_HALF,  1'b0, 1'b0);
                    `RV64_FUNCT3_SW: accept(`RV64_LSU_OP_SW, `RV64_LSU_SIZE_WORD,  1'b0, 1'b0);
                    `RV64_FUNCT3_SD: accept(`RV64_LSU_OP_SD, `RV64_LSU_SIZE_DWORD, 1'b0, 1'b0);
                    default: begin
                    end
                endcase
            end

            default: begin
            end
        endcase
    end

endmodule
