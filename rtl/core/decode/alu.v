`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-m.v"
`include "core/decode/defs/alu-defs.v"

module openrv64_decode_alu #(
    parameter ENABLE_RV64M = 1
) (
    input  wire [`RV64_OPCODE_WIDTH-1:0] opcode_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,
    input  wire [`RV64_FUNCT7_WIDTH-1:0] funct7_i,

    output reg                         valid_o,
    output reg                         illegal_o,
    output reg [`RV64_ALU_EXT_WIDTH-1:0] ext_sel_o,
    output reg [`RV64_ALU_OP_WIDTH-1:0] op_sel_o,
    output reg                         word_op_o
);

    task automatic accept;
        input [`RV64_ALU_EXT_WIDTH-1:0] ext_sel;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        begin
            valid_o   = 1'b1;
            illegal_o = 1'b0;
            ext_sel_o = ext_sel;
            op_sel_o  = op_sel;
        end
    endtask

    always @* begin
        valid_o   = 1'b0;
        illegal_o = 1'b1;
        ext_sel_o = `RV64_ALU_EXT_INVALID;
        op_sel_o  = `RV64_ALU_OP_INVALID;
        word_op_o = 1'b0;

        case (opcode_i)
            `RV64_OPCODE_LUI: begin
                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_LUI);
            end

            `RV64_OPCODE_AUIPC: begin
                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_AUIPC);
            end

            `RV64_OPCODE_OP_IMM: begin
                ext_sel_o = `RV64_ALU_EXT_BASE;

                case (funct3_i)
                    `RV64_FUNCT3_ADD_SUB: accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD);
                    `RV64_FUNCT3_SLT:     accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLT);
                    `RV64_FUNCT3_SLTU:    accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLTU);
                    `RV64_FUNCT3_XOR:     accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_XOR);
                    `RV64_FUNCT3_OR:      accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_OR);
                    `RV64_FUNCT3_AND:     accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_AND);

                    `RV64_FUNCT3_SLL: begin
                        if (funct7_i[6:1] == `RV64_FUNCT6_SLLI) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLL);
                        end
                    end

                    `RV64_FUNCT3_SRL_SRA: begin
                        if (funct7_i[6:1] == `RV64_FUNCT6_SRLI) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRL);
                        end else if (funct7_i[6:1] == `RV64_FUNCT6_SRAI) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA);
                        end
                    end

                    default: begin
                    end
                endcase
            end

            `RV64_OPCODE_OP_IMM_32: begin
                word_op_o = 1'b1;
                ext_sel_o = `RV64_ALU_EXT_BASE;

                case (funct3_i)
                    `RV64_FUNCT3_ADD_SUB: accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD);

                    `RV64_FUNCT3_SLL: begin
                        if (funct7_i == `RV64_FUNCT7_SLLIW) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLL);
                        end
                    end

                    `RV64_FUNCT3_SRL_SRA: begin
                        if (funct7_i == `RV64_FUNCT7_SRLIW) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRL);
                        end else if (funct7_i == `RV64_FUNCT7_SRAIW) begin
                            accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA);
                        end
                    end

                    default: begin
                    end
                endcase
            end

            `RV64_OPCODE_OP,
            `RV64_OPCODE_OP_32: begin
                word_op_o = (opcode_i == `RV64_OPCODE_OP_32);

                if (funct7_i == `RV64_M_FUNCT7) begin
                    ext_sel_o = `RV64_ALU_EXT_M;

                    if (ENABLE_RV64M) begin
                        if (opcode_i == `RV64_OPCODE_OP_32) begin
                            case (funct3_i)
                                `RV64_M_FUNCT3_MUL:  accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_MUL);
                                `RV64_M_FUNCT3_DIV:  accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_DIV);
                                `RV64_M_FUNCT3_DIVU: accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_DIVU);
                                `RV64_M_FUNCT3_REM:  accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_REM);
                                `RV64_M_FUNCT3_REMU: accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_REMU);
                                default: begin
                                end
                            endcase
                        end else begin
                            case (funct3_i)
                                `RV64_M_FUNCT3_MUL:    accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_MUL);
                                `RV64_M_FUNCT3_MULH:   accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_MULH);
                                `RV64_M_FUNCT3_MULHSU: accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_MULHSU);
                                `RV64_M_FUNCT3_MULHU:  accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_MULHU);
                                `RV64_M_FUNCT3_DIV:    accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_DIV);
                                `RV64_M_FUNCT3_DIVU:   accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_DIVU);
                                `RV64_M_FUNCT3_REM:    accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_REM);
                                `RV64_M_FUNCT3_REMU:   accept(`RV64_ALU_EXT_M, `RV64_ALU_OP_REMU);
                                default: begin
                                end
                            endcase
                        end
                    end
                end else begin
                    ext_sel_o = `RV64_ALU_EXT_BASE;

                    case (funct3_i)
                        `RV64_FUNCT3_ADD_SUB: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_ADD);
                            end else if (funct7_i == `RV64_FUNCT7_SUB) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SUB);
                            end
                        end

                        `RV64_FUNCT3_SLL: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLL);
                            end
                        end

                        `RV64_FUNCT3_SLT: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLT);
                            end
                        end

                        `RV64_FUNCT3_SLTU: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SLTU);
                            end
                        end

                        `RV64_FUNCT3_XOR: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_XOR);
                            end
                        end

                        `RV64_FUNCT3_SRL_SRA: begin
                            if (funct7_i == `RV64_FUNCT7_SRL) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRL);
                            end else if (funct7_i == `RV64_FUNCT7_SRA) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_SRA);
                            end
                        end

                        `RV64_FUNCT3_OR: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_OR);
                            end
                        end

                        `RV64_FUNCT3_AND: begin
                            if (funct7_i == `RV64_FUNCT7_ADD) begin
                                accept(`RV64_ALU_EXT_BASE, `RV64_ALU_OP_AND);
                            end
                        end

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
