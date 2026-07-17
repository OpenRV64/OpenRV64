`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/decode/defs/lsu-defs.v"

module openrv64_decode_lsu #(
    parameter ENABLE_RV64A = 1
) (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output reg                           valid_o,
    output reg                           illegal_o,
    output reg [`RV64_LSU_OP_WIDTH-1:0]  op_sel_o,
    output reg [`RV64_LSU_SIZE_WIDTH-1:0] size_sel_o,
    output reg                           load_o,
    output reg                           store_o,
    output reg                           unsigned_o
);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire [`RV64_FUNCT3_WIDTH-1:0] funct3 = `RV64_FUNCT3(instr_i);
    wire [4:0] amo_funct5 = `RV64_AMO_FUNCT5(instr_i);

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

    task automatic accept_atomic;
        input [`RV64_LSU_OP_WIDTH-1:0] op_sel;
        input [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
        input is_load;
        input is_store;
        begin
            valid_o    = 1'b1;
            illegal_o  = 1'b0;
            op_sel_o   = op_sel;
            size_sel_o = size_sel;
            load_o     = is_load;
            store_o    = is_store;
            unsigned_o = 1'b0;
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

        case (opcode)
            `RV64_OPCODE_LOAD: begin
                load_o = 1'b1;

                case (funct3)
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

                case (funct3)
                    `RV64_FUNCT3_SB: accept(`RV64_LSU_OP_SB, `RV64_LSU_SIZE_BYTE,  1'b0, 1'b0);
                    `RV64_FUNCT3_SH: accept(`RV64_LSU_OP_SH, `RV64_LSU_SIZE_HALF,  1'b0, 1'b0);
                    `RV64_FUNCT3_SW: accept(`RV64_LSU_OP_SW, `RV64_LSU_SIZE_WORD,  1'b0, 1'b0);
                    `RV64_FUNCT3_SD: accept(`RV64_LSU_OP_SD, `RV64_LSU_SIZE_DWORD, 1'b0, 1'b0);
                    default: begin
                    end
                endcase
            end

            `RV64_OPCODE_AMO: begin
                if (ENABLE_RV64A &&
                    ((funct3 == `RV64_AMO_FUNCT3_W) ||
                     (funct3 == `RV64_AMO_FUNCT3_D))) begin
                    case (amo_funct5)
                        `RV64_AMO_FUNCT5_LR: begin
                            if (`RV64_RS2(instr_i) == `RV64_REG_X0) begin
                                accept_atomic(`RV64_LSU_OP_LR,
                                    (funct3 == `RV64_AMO_FUNCT3_W) ?
                                        `RV64_LSU_SIZE_WORD :
                                        `RV64_LSU_SIZE_DWORD,
                                    1'b1, 1'b0);
                            end
                        end
                        `RV64_AMO_FUNCT5_SC:
                            accept_atomic(`RV64_LSU_OP_SC,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b0, 1'b1);
                        `RV64_AMO_FUNCT5_SWAP:
                            accept_atomic(`RV64_LSU_OP_AMOSWAP,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_ADD:
                            accept_atomic(`RV64_LSU_OP_AMOADD,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_XOR:
                            accept_atomic(`RV64_LSU_OP_AMOXOR,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_AND:
                            accept_atomic(`RV64_LSU_OP_AMOAND,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_OR:
                            accept_atomic(`RV64_LSU_OP_AMOOR,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_MIN:
                            accept_atomic(`RV64_LSU_OP_AMOMIN,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_MAX:
                            accept_atomic(`RV64_LSU_OP_AMOMAX,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_MINU:
                            accept_atomic(`RV64_LSU_OP_AMOMINU,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        `RV64_AMO_FUNCT5_MAXU:
                            accept_atomic(`RV64_LSU_OP_AMOMAXU,
                                (funct3 == `RV64_AMO_FUNCT3_W) ?
                                    `RV64_LSU_SIZE_WORD :
                                    `RV64_LSU_SIZE_DWORD,
                                1'b1, 1'b1);
                        default: begin
                        end
                    endcase
                end
            end

            default: begin
            end
        endcase
    end

endmodule
