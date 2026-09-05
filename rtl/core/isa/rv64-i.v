`ifndef OPENRV64_RV64_I_V
`define OPENRV64_RV64_I_V

// Base RV64I instruction field layout.
`define RV64_XLEN 64
`define RV64_INSTR_WIDTH 32
`define RV64_OPCODE_WIDTH 7
`define RV64_REG_ADDR_WIDTH 5
`define RV64_FUNCT3_WIDTH 3
`define RV64_FUNCT6_WIDTH 6
`define RV64_FUNCT7_WIDTH 7
`define RV64_FUNCT12_WIDTH 12

`define RV64_OPCODE_BITS 6:0
`define RV64_RD_BITS 11:7
`define RV64_FUNCT3_BITS 14:12
`define RV64_RS1_BITS 19:15
`define RV64_RS2_BITS 24:20
`define RV64_FUNCT7_BITS 31:25
`define RV64_FUNCT6_BITS 31:26
`define RV64_FUNCT12_BITS 31:20
`define RV64_CSR_BITS 31:20
`define RV64_SHAMT_BITS 25:20
`define RV64_SHAMT32_BITS 24:20

`define RV64_OPCODE(instr) instr[`RV64_OPCODE_BITS]
`define RV64_RD(instr) instr[`RV64_RD_BITS]
`define RV64_FUNCT3(instr) instr[`RV64_FUNCT3_BITS]
`define RV64_RS1(instr) instr[`RV64_RS1_BITS]
`define RV64_RS2(instr) instr[`RV64_RS2_BITS]
`define RV64_FUNCT7(instr) instr[`RV64_FUNCT7_BITS]
`define RV64_FUNCT6(instr) instr[`RV64_FUNCT6_BITS]
`define RV64_FUNCT12(instr) instr[`RV64_FUNCT12_BITS]
`define RV64_CSR(instr) instr[`RV64_CSR_BITS]
`define RV64_SHAMT(instr) instr[`RV64_SHAMT_BITS]
`define RV64_SHAMT32(instr) instr[`RV64_SHAMT32_BITS]

// Sign-extended immediates as 64-bit values.
`define RV64_IMM_I(instr) {{52{instr[31]}}, instr[31:20]}
`define RV64_IMM_S(instr) {{52{instr[31]}}, instr[31:25], instr[11:7]}
`define RV64_IMM_B(instr) {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}
`define RV64_IMM_U(instr) {{32{instr[31]}}, instr[31:12], 12'b0}
`define RV64_IMM_J(instr) {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}

// Register numbers.
`define RV64_REG_X0 5'd0
`define RV64_REG_X1 5'd1
`define RV64_REG_X2 5'd2
`define RV64_REG_X3 5'd3
`define RV64_REG_X4 5'd4
`define RV64_REG_X5 5'd5
`define RV64_REG_X6 5'd6
`define RV64_REG_X7 5'd7
`define RV64_REG_X8 5'd8
`define RV64_REG_X9 5'd9
`define RV64_REG_X10 5'd10
`define RV64_REG_X11 5'd11
`define RV64_REG_X12 5'd12
`define RV64_REG_X13 5'd13
`define RV64_REG_X14 5'd14
`define RV64_REG_X15 5'd15
`define RV64_REG_X16 5'd16
`define RV64_REG_X17 5'd17
`define RV64_REG_X18 5'd18
`define RV64_REG_X19 5'd19
`define RV64_REG_X20 5'd20
`define RV64_REG_X21 5'd21
`define RV64_REG_X22 5'd22
`define RV64_REG_X23 5'd23
`define RV64_REG_X24 5'd24
`define RV64_REG_X25 5'd25
`define RV64_REG_X26 5'd26
`define RV64_REG_X27 5'd27
`define RV64_REG_X28 5'd28
`define RV64_REG_X29 5'd29
`define RV64_REG_X30 5'd30
`define RV64_REG_X31 5'd31

// Base opcode map.
`define RV64_OPCODE_LOAD 7'b0000011
`define RV64_OPCODE_MISC_MEM 7'b0001111
`define RV64_OPCODE_OP_IMM 7'b0010011
`define RV64_OPCODE_AUIPC 7'b0010111
`define RV64_OPCODE_OP_IMM_32 7'b0011011
`define RV64_OPCODE_STORE 7'b0100011
`define RV64_OPCODE_OP 7'b0110011
`define RV64_OPCODE_LUI 7'b0110111
`define RV64_OPCODE_OP_32 7'b0111011
`define RV64_OPCODE_BRANCH 7'b1100011
`define RV64_OPCODE_JALR 7'b1100111
`define RV64_OPCODE_JAL 7'b1101111
`define RV64_OPCODE_SYSTEM 7'b1110011

// Jumps and branches.
`define RV64_FUNCT3_JALR 3'b000
`define RV64_FUNCT3_BEQ 3'b000
`define RV64_FUNCT3_BNE 3'b001
`define RV64_FUNCT3_BLT 3'b100
`define RV64_FUNCT3_BGE 3'b101
`define RV64_FUNCT3_BLTU 3'b110
`define RV64_FUNCT3_BGEU 3'b111

// Full-pattern predicates used by decode-side macro-fusion.  Keep the
// architectural encodings here while fusion classes remain in decode/defs.
`define RV64_INSTR_IS_AUIPC(instr) \
    (`RV64_OPCODE(instr) == `RV64_OPCODE_AUIPC)
`define RV64_INSTR_IS_ADDI(instr) \
    ((`RV64_OPCODE(instr) == `RV64_OPCODE_OP_IMM) && \
     (`RV64_FUNCT3(instr) == `RV64_FUNCT3_ADD_SUB))
`define RV64_INSTR_IS_JALR(instr) \
    ((`RV64_OPCODE(instr) == `RV64_OPCODE_JALR) && \
     (`RV64_FUNCT3(instr) == `RV64_FUNCT3_JALR))
`define RV64_INSTR_IS_NOP(instr) \
    ((instr) == `RV64_INSTR_NOP)

// Loads and stores.
`define RV64_FUNCT3_LB 3'b000
`define RV64_FUNCT3_LH 3'b001
`define RV64_FUNCT3_LW 3'b010
`define RV64_FUNCT3_LD 3'b011
`define RV64_FUNCT3_LBU 3'b100
`define RV64_FUNCT3_LHU 3'b101
`define RV64_FUNCT3_LWU 3'b110

`define RV64_FUNCT3_SB 3'b000
`define RV64_FUNCT3_SH 3'b001
`define RV64_FUNCT3_SW 3'b010
`define RV64_FUNCT3_SD 3'b011

// Integer ALU funct3 values. These are shared by OP-IMM, OP, OP-IMM-32, and OP-32
// where the instruction family supports the operation.
`define RV64_FUNCT3_ADD_SUB 3'b000
`define RV64_FUNCT3_SLL 3'b001
`define RV64_FUNCT3_SLT 3'b010
`define RV64_FUNCT3_SLTU 3'b011
`define RV64_FUNCT3_XOR 3'b100
`define RV64_FUNCT3_SRL_SRA 3'b101
`define RV64_FUNCT3_OR 3'b110
`define RV64_FUNCT3_AND 3'b111

`define RV64_FUNCT7_ADD 7'b0000000
`define RV64_FUNCT7_SUB 7'b0100000
`define RV64_FUNCT7_SRL 7'b0000000
`define RV64_FUNCT7_SRA 7'b0100000

// RV64 shift-immediate encodings use funct6 in bits [31:26].
`define RV64_FUNCT6_SLLI 6'b000000
`define RV64_FUNCT6_SRLI 6'b000000
`define RV64_FUNCT6_SRAI 6'b010000

// RV64 W shift-immediate encodings use funct7 in bits [31:25].
`define RV64_FUNCT7_SLLIW 7'b0000000
`define RV64_FUNCT7_SRLIW 7'b0000000
`define RV64_FUNCT7_SRAIW 7'b0100000

// FENCE and SYSTEM base encodings.
`define RV64_FUNCT3_FENCE 3'b000
`define RV64_FUNCT3_SYSTEM_PRIV 3'b000

`define RV64_FUNCT12_ECALL 12'h000
`define RV64_FUNCT12_EBREAK 12'h001

// Full instruction constants used by early bring-up and tests.
`define RV64_INSTR_NOP 32'h0000_0013
`define RV64_INSTR_ECALL 32'h0000_0073
`define RV64_INSTR_EBREAK 32'h0010_0073

// Repository-local test-control tags.  ADDI x0,x0,imm is an architectural
// HINT, so these words have no GPR side effect.  When test-marker support is
// enabled, an immediately following 32-bit EBREAK names the corresponding
// marker instead of taking the ordinary breakpoint/halt path.
`define OPENRV64_INSTR_START_TEST_HINT 32'h7a10_0013
`define OPENRV64_INSTR_START_TRACE_HINT 32'h7a20_0013
`define OPENRV64_INSTR_END_TRACE_HINT   32'h7a30_0013

`endif
