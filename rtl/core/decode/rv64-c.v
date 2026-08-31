`ifndef OPENRV64_DECODE_RV64_C_V
`define OPENRV64_DECODE_RV64_C_V

`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-c.v"

// RV64C integer decompressor.
//
// instr_i is a little-endian instruction window: the first 16-bit parcel is
// instr_i[15:0].  Ratified C instructions are exactly 16 bits, but an RVC
// instruction stream can freely mix 16-bit and 32-bit instructions.  Prefixes
// for 48-bit-or-longer instructions are rejected because this core has ILEN=32.
//
// Legal integer C instructions are expanded to canonical RV64I instructions
// for openrv64_decode_top.  The caller must combine illegal_o with the normal
// decoder's illegal result when constructing the dispatch payload.  It must
// also carry instr_bytes_o with the instruction: sequential PCs and the
// C.JALR link value advance by two bytes, not the canonical instruction's four.
module openrv64_decode_rv64c (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    output reg  [`RV64_INSTR_WIDTH-1:0] instr_o,
    output reg                          compressed_o,
    output reg                          illegal_o,
    output reg                          unsupported_length_o,
    // 2 for C, 4 for ordinary 32-bit instructions, 0 for unsupported length.
    output reg  [2:0]                   instr_bytes_o
);

    wire [15:0] c_instr = instr_i[15:0];
    wire [4:0] c_rd = c_instr[11:7];
    wire [4:0] c_rs1_prime = `RV64_C_REG_PRIME(c_instr[9:7]);
    wire [4:0] c_rs2_prime = `RV64_C_REG_PRIME(c_instr[4:2]);

    reg [11:0] imm12;
    reg [12:0] imm13;
    reg [19:0] imm20;
    reg [20:0] imm21;

    function automatic [31:0] encode_i;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_i = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_r;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_r = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_s;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            encode_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
        end
    endfunction

    function automatic [31:0] encode_b;
        input [12:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            encode_b = {
                imm[12],
                imm[10:5],
                rs2,
                rs1,
                funct3,
                imm[4:1],
                imm[11],
                opcode
            };
        end
    endfunction

    function automatic [31:0] encode_u;
        input [19:0] imm;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_u = {imm, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_j;
        input [20:0] imm;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_j = {
                imm[20],
                imm[10:1],
                imm[11],
                imm[19:12],
                rd,
                opcode
            };
        end
    endfunction

    always @* begin
        instr_o = `RV64_INSTR_NOP;
        compressed_o = 1'b0;
        illegal_o = 1'b0;
        unsupported_length_o = 1'b0;
        instr_bytes_o = 3'd4;
        imm12 = 12'd0;
        imm13 = 13'd0;
        imm20 = 20'd0;
        imm21 = 21'd0;

        if (`RV64_INSTR_IS_C(instr_i)) begin
            compressed_o = 1'b1;
            instr_bytes_o = 3'd2;

            case (`RV64_C_QUADRANT(instr_i))
                `RV64_C_QUADRANT_0: begin
                    case (`RV64_C_FUNCT3(c_instr))
                        3'b000: begin // C.ADDI4SPN
                            imm12 = {
                                2'b00,
                                c_instr[10:7],
                                c_instr[12:11],
                                c_instr[5],
                                c_instr[6],
                                2'b00
                            };
                            if (imm12 == 12'd0)
                                illegal_o = 1'b1;
                            else
                                instr_o = encode_i(
                                    imm12,
                                    `RV64_REG_X2,
                                    `RV64_FUNCT3_ADD_SUB,
                                    c_rs2_prime,
                                    `RV64_OPCODE_OP_IMM
                                );
                        end

                        3'b010: begin // C.LW
                            imm12 = {
                                5'b00000,
                                c_instr[5],
                                c_instr[12:10],
                                c_instr[6],
                                2'b00
                            };
                            instr_o = encode_i(
                                imm12,
                                c_rs1_prime,
                                `RV64_FUNCT3_LW,
                                c_rs2_prime,
                                `RV64_OPCODE_LOAD
                            );
                        end

                        3'b011: begin // C.LD (RV64)
                            imm12 = {
                                4'b0000,
                                c_instr[6:5],
                                c_instr[12:10],
                                3'b000
                            };
                            instr_o = encode_i(
                                imm12,
                                c_rs1_prime,
                                `RV64_FUNCT3_LD,
                                c_rs2_prime,
                                `RV64_OPCODE_LOAD
                            );
                        end

                        3'b110: begin // C.SW
                            imm12 = {
                                5'b00000,
                                c_instr[5],
                                c_instr[12:10],
                                c_instr[6],
                                2'b00
                            };
                            instr_o = encode_s(
                                imm12,
                                c_rs2_prime,
                                c_rs1_prime,
                                `RV64_FUNCT3_SW,
                                `RV64_OPCODE_STORE
                            );
                        end

                        3'b111: begin // C.SD (RV64)
                            imm12 = {
                                4'b0000,
                                c_instr[6:5],
                                c_instr[12:10],
                                3'b000
                            };
                            instr_o = encode_s(
                                imm12,
                                c_rs2_prime,
                                c_rs1_prime,
                                `RV64_FUNCT3_SD,
                                `RV64_OPCODE_STORE
                            );
                        end

                        // C.FLD/C.FSD and the reserved quadrant-0 encoding are
                        // not part of the integer-only downstream decode.
                        default: illegal_o = 1'b1;
                    endcase
                end

                `RV64_C_QUADRANT_1: begin
                    case (`RV64_C_FUNCT3(c_instr))
                        3'b000: begin // C.NOP / C.ADDI / HINT
                            imm12 = {
                                {6{c_instr[12]}},
                                c_instr[12],
                                c_instr[6:2]
                            };
                            instr_o = encode_i(
                                imm12,
                                c_rd,
                                `RV64_FUNCT3_ADD_SUB,
                                c_rd,
                                `RV64_OPCODE_OP_IMM
                            );
                        end

                        3'b001: begin // C.ADDIW (RV64)
                            imm12 = {
                                {6{c_instr[12]}},
                                c_instr[12],
                                c_instr[6:2]
                            };
                            if (c_rd == `RV64_REG_X0)
                                illegal_o = 1'b1;
                            else
                                instr_o = encode_i(
                                    imm12,
                                    c_rd,
                                    `RV64_FUNCT3_ADD_SUB,
                                    c_rd,
                                    `RV64_OPCODE_OP_IMM_32
                                );
                        end

                        3'b010: begin // C.LI / HINT
                            imm12 = {
                                {6{c_instr[12]}},
                                c_instr[12],
                                c_instr[6:2]
                            };
                            instr_o = encode_i(
                                imm12,
                                `RV64_REG_X0,
                                `RV64_FUNCT3_ADD_SUB,
                                c_rd,
                                `RV64_OPCODE_OP_IMM
                            );
                        end

                        3'b011: begin
                            if (c_rd == `RV64_REG_X2) begin // C.ADDI16SP
                                imm12 = {
                                    {2{c_instr[12]}},
                                    c_instr[12],
                                    c_instr[4:3],
                                    c_instr[5],
                                    c_instr[2],
                                    c_instr[6],
                                    4'b0000
                                };
                                if (imm12 == 12'd0)
                                    illegal_o = 1'b1;
                                else
                                    instr_o = encode_i(
                                        imm12,
                                        `RV64_REG_X2,
                                        `RV64_FUNCT3_ADD_SUB,
                                        `RV64_REG_X2,
                                        `RV64_OPCODE_OP_IMM
                                    );
                            end else begin // C.LUI / HINT
                                imm20 = {
                                    {14{c_instr[12]}},
                                    c_instr[12],
                                    c_instr[6:2]
                                };
                                if ({c_instr[12], c_instr[6:2]} == 6'd0)
                                    illegal_o = 1'b1;
                                else
                                    instr_o = encode_u(
                                        imm20,
                                        c_rd,
                                        `RV64_OPCODE_LUI
                                    );
                            end
                        end

                        3'b100: begin
                            case (c_instr[11:10])
                                2'b00: begin // C.SRLI / HINT
                                    imm12 = {
                                        `RV64_FUNCT6_SRLI,
                                        c_instr[12],
                                        c_instr[6:2]
                                    };
                                    instr_o = encode_i(
                                        imm12,
                                        c_rs1_prime,
                                        `RV64_FUNCT3_SRL_SRA,
                                        c_rs1_prime,
                                        `RV64_OPCODE_OP_IMM
                                    );
                                end

                                2'b01: begin // C.SRAI / HINT
                                    imm12 = {
                                        `RV64_FUNCT6_SRAI,
                                        c_instr[12],
                                        c_instr[6:2]
                                    };
                                    instr_o = encode_i(
                                        imm12,
                                        c_rs1_prime,
                                        `RV64_FUNCT3_SRL_SRA,
                                        c_rs1_prime,
                                        `RV64_OPCODE_OP_IMM
                                    );
                                end

                                2'b10: begin // C.ANDI
                                    imm12 = {
                                        {6{c_instr[12]}},
                                        c_instr[12],
                                        c_instr[6:2]
                                    };
                                    instr_o = encode_i(
                                        imm12,
                                        c_rs1_prime,
                                        `RV64_FUNCT3_AND,
                                        c_rs1_prime,
                                        `RV64_OPCODE_OP_IMM
                                    );
                                end

                                2'b11: begin
                                    if (!c_instr[12]) begin
                                        case (c_instr[6:5])
                                            2'b00: instr_o = encode_r( // C.SUB
                                                `RV64_FUNCT7_SUB,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_ADD_SUB,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP
                                            );
                                            2'b01: instr_o = encode_r( // C.XOR
                                                `RV64_FUNCT7_ADD,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_XOR,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP
                                            );
                                            2'b10: instr_o = encode_r( // C.OR
                                                `RV64_FUNCT7_ADD,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_OR,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP
                                            );
                                            2'b11: instr_o = encode_r( // C.AND
                                                `RV64_FUNCT7_ADD,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_AND,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP
                                            );
                                        endcase
                                    end else begin
                                        case (c_instr[6:5])
                                            2'b00: instr_o = encode_r( // C.SUBW
                                                `RV64_FUNCT7_SUB,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_ADD_SUB,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP_32
                                            );
                                            2'b01: instr_o = encode_r( // C.ADDW
                                                `RV64_FUNCT7_ADD,
                                                c_rs2_prime,
                                                c_rs1_prime,
                                                `RV64_FUNCT3_ADD_SUB,
                                                c_rs1_prime,
                                                `RV64_OPCODE_OP_32
                                            );
                                            default: illegal_o = 1'b1;
                                        endcase
                                    end
                                end
                            endcase
                        end

                        3'b101: begin // C.J
                            imm21 = {
                                {9{c_instr[12]}},
                                c_instr[12],
                                c_instr[8],
                                c_instr[10:9],
                                c_instr[6],
                                c_instr[7],
                                c_instr[2],
                                c_instr[11],
                                c_instr[5:3],
                                1'b0
                            };
                            instr_o = encode_j(
                                imm21,
                                `RV64_REG_X0,
                                `RV64_OPCODE_JAL
                            );
                        end

                        3'b110: begin // C.BEQZ
                            imm13 = {
                                {4{c_instr[12]}},
                                c_instr[12],
                                c_instr[6:5],
                                c_instr[2],
                                c_instr[11:10],
                                c_instr[4:3],
                                1'b0
                            };
                            instr_o = encode_b(
                                imm13,
                                `RV64_REG_X0,
                                c_rs1_prime,
                                `RV64_FUNCT3_BEQ,
                                `RV64_OPCODE_BRANCH
                            );
                        end

                        3'b111: begin // C.BNEZ
                            imm13 = {
                                {4{c_instr[12]}},
                                c_instr[12],
                                c_instr[6:5],
                                c_instr[2],
                                c_instr[11:10],
                                c_instr[4:3],
                                1'b0
                            };
                            instr_o = encode_b(
                                imm13,
                                `RV64_REG_X0,
                                c_rs1_prime,
                                `RV64_FUNCT3_BNE,
                                `RV64_OPCODE_BRANCH
                            );
                        end
                    endcase
                end

                `RV64_C_QUADRANT_2: begin
                    case (`RV64_C_FUNCT3(c_instr))
                        3'b000: begin // C.SLLI / HINT
                            imm12 = {
                                `RV64_FUNCT6_SLLI,
                                c_instr[12],
                                c_instr[6:2]
                            };
                            instr_o = encode_i(
                                imm12,
                                c_rd,
                                `RV64_FUNCT3_SLL,
                                c_rd,
                                `RV64_OPCODE_OP_IMM
                            );
                        end

                        3'b010: begin // C.LWSP
                            imm12 = {
                                4'b0000,
                                c_instr[3:2],
                                c_instr[12],
                                c_instr[6:4],
                                2'b00
                            };
                            if (c_rd == `RV64_REG_X0)
                                illegal_o = 1'b1;
                            else
                                instr_o = encode_i(
                                    imm12,
                                    `RV64_REG_X2,
                                    `RV64_FUNCT3_LW,
                                    c_rd,
                                    `RV64_OPCODE_LOAD
                                );
                        end

                        3'b011: begin // C.LDSP (RV64)
                            imm12 = {
                                3'b000,
                                c_instr[4:2],
                                c_instr[12],
                                c_instr[6:5],
                                3'b000
                            };
                            if (c_rd == `RV64_REG_X0)
                                illegal_o = 1'b1;
                            else
                                instr_o = encode_i(
                                    imm12,
                                    `RV64_REG_X2,
                                    `RV64_FUNCT3_LD,
                                    c_rd,
                                    `RV64_OPCODE_LOAD
                                );
                        end

                        3'b100: begin
                            if (!c_instr[12]) begin
                                if (c_instr[6:2] == 5'd0) begin // C.JR
                                    if (c_rd == `RV64_REG_X0)
                                        illegal_o = 1'b1;
                                    else
                                        instr_o = encode_i(
                                            12'd0,
                                            c_rd,
                                            `RV64_FUNCT3_JALR,
                                            `RV64_REG_X0,
                                            `RV64_OPCODE_JALR
                                        );
                                end else begin // C.MV / HINT
                                    instr_o = encode_r(
                                        `RV64_FUNCT7_ADD,
                                        c_instr[6:2],
                                        `RV64_REG_X0,
                                        `RV64_FUNCT3_ADD_SUB,
                                        c_rd,
                                        `RV64_OPCODE_OP
                                    );
                                end
                            end else begin
                                if (c_instr[6:2] == 5'd0) begin
                                    if (c_rd == `RV64_REG_X0) begin // C.EBREAK
                                        instr_o = `RV64_INSTR_EBREAK;
                                    end else begin // C.JALR
                                        instr_o = encode_i(
                                            12'd0,
                                            c_rd,
                                            `RV64_FUNCT3_JALR,
                                            `RV64_REG_X1,
                                            `RV64_OPCODE_JALR
                                        );
                                    end
                                end else begin // C.ADD / HINT
                                    instr_o = encode_r(
                                        `RV64_FUNCT7_ADD,
                                        c_instr[6:2],
                                        c_rd,
                                        `RV64_FUNCT3_ADD_SUB,
                                        c_rd,
                                        `RV64_OPCODE_OP
                                    );
                                end
                            end
                        end

                        3'b110: begin // C.SWSP
                            imm12 = {
                                4'b0000,
                                c_instr[8:7],
                                c_instr[12:9],
                                2'b00
                            };
                            instr_o = encode_s(
                                imm12,
                                c_instr[6:2],
                                `RV64_REG_X2,
                                `RV64_FUNCT3_SW,
                                `RV64_OPCODE_STORE
                            );
                        end

                        3'b111: begin // C.SDSP (RV64)
                            imm12 = {
                                3'b000,
                                c_instr[9:7],
                                c_instr[12:10],
                                3'b000
                            };
                            instr_o = encode_s(
                                imm12,
                                c_instr[6:2],
                                `RV64_REG_X2,
                                `RV64_FUNCT3_SD,
                                `RV64_OPCODE_STORE
                            );
                        end

                        // C.FLDSP/C.FSDSP are not part of the integer-only
                        // downstream decode.
                        default: illegal_o = 1'b1;
                    endcase
                end

                default: begin
                    // This branch is unreachable because 2'b11 is handled
                    // below, but keep deterministic outputs under X-free input.
                    illegal_o = 1'b1;
                end
            endcase
        end else if (instr_i[4:2] == 3'b111) begin
            // Prefix for a 48-bit-or-longer instruction.  ILEN=32 cannot
            // consume it, and the 32-bit window cannot report its full length.
            illegal_o = 1'b1;
            unsupported_length_o = 1'b1;
            instr_bytes_o = 3'd0;
        end else begin
            instr_o = instr_i;
        end
    end

endmodule

`endif
