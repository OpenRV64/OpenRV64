`ifndef OPENRV64_RV64_F_V
`define OPENRV64_RV64_F_V

`include "core/isa/rv64-i.v"

// Ratified F-extension instruction fields.  This file is intentionally an
// encoding contract only; decode, F-register state, fcsr, and execution are
// separate integration concerns.
`define RV64_FP_OPCODE_LOAD       7'b0000111
`define RV64_FP_OPCODE_STORE      7'b0100111
`define RV64_FP_OPCODE_MADD       7'b1000011
`define RV64_FP_OPCODE_MSUB       7'b1000111
`define RV64_FP_OPCODE_NMSUB      7'b1001011
`define RV64_FP_OPCODE_NMADD      7'b1001111
`define RV64_FP_OPCODE_OP         7'b1010011

`define RV64_FP_RS3_BITS          31:27
`define RV64_FP_FMT_BITS          26:25
`define RV64_FP_RM_BITS           14:12
`define RV64_FP_RS3(instr)        instr[`RV64_FP_RS3_BITS]
`define RV64_FP_FMT(instr)        instr[`RV64_FP_FMT_BITS]
`define RV64_FP_RM(instr)         instr[`RV64_FP_RM_BITS]

`define RV64_FP_FMT_S             2'b00
`define RV64_FP_FMT_D             2'b01
`define RV64_FP_FMT_H             2'b10
`define RV64_FP_FMT_Q             2'b11

`define RV64_FP_RM_RNE            3'b000
`define RV64_FP_RM_RTZ            3'b001
`define RV64_FP_RM_RDN            3'b010
`define RV64_FP_RM_RUP            3'b011
`define RV64_FP_RM_RMM            3'b100
`define RV64_FP_RM_DYN            3'b111

`define RV64_FP_CSR_FFLAGS         12'h001
`define RV64_FP_CSR_FRM            12'h002
`define RV64_FP_CSR_FCSR           12'h003

// fflags bit positions and masks: NV, DZ, OF, UF, NX.
`define RV64_FP_FFLAG_NX_BIT       0
`define RV64_FP_FFLAG_UF_BIT       1
`define RV64_FP_FFLAG_OF_BIT       2
`define RV64_FP_FFLAG_DZ_BIT       3
`define RV64_FP_FFLAG_NV_BIT       4
`define RV64_FP_FFLAG_NX           5'b00001
`define RV64_FP_FFLAG_UF           5'b00010
`define RV64_FP_FFLAG_OF           5'b00100
`define RV64_FP_FFLAG_DZ           5'b01000
`define RV64_FP_FFLAG_NV           5'b10000

`define RV64_FP_FUNCT3_FLW_FSW     3'b010

// OP-FP funct5 occupies instruction bits [31:27].  Bits [26:25] are fmt.
`define RV64_FP_FUNCT5_ADD          5'b00000
`define RV64_FP_FUNCT5_SUB          5'b00001
`define RV64_FP_FUNCT5_MUL          5'b00010
`define RV64_FP_FUNCT5_DIV          5'b00011
`define RV64_FP_FUNCT5_SGNJ         5'b00100
`define RV64_FP_FUNCT5_MINMAX       5'b00101
`define RV64_FP_FUNCT5_CVT_FP       5'b01000
`define RV64_FP_FUNCT5_SQRT         5'b01011
`define RV64_FP_FUNCT5_COMPARE      5'b10100
`define RV64_FP_FUNCT5_CVT_TO_INT   5'b11000
`define RV64_FP_FUNCT5_CVT_FROM_INT 5'b11010
`define RV64_FP_FUNCT5_MV_X_CLASS   5'b11100
`define RV64_FP_FUNCT5_MV_F_X       5'b11110

`define RV64_FP_FUNCT3_SGNJ         3'b000
`define RV64_FP_FUNCT3_SGNJN        3'b001
`define RV64_FP_FUNCT3_SGNJX        3'b010
`define RV64_FP_FUNCT3_MIN          3'b000
`define RV64_FP_FUNCT3_MAX          3'b001
`define RV64_FP_FUNCT3_FLE          3'b000
`define RV64_FP_FUNCT3_FLT          3'b001
`define RV64_FP_FUNCT3_FEQ          3'b010
`define RV64_FP_FUNCT3_MV           3'b000
`define RV64_FP_FUNCT3_CLASS        3'b001

`define RV64_FP_RS2_W               5'b00000
`define RV64_FP_RS2_WU              5'b00001
`define RV64_FP_RS2_L               5'b00010
`define RV64_FP_RS2_LU              5'b00011
`define RV64_FP_RS2_S               5'b00000
`define RV64_FP_RS2_D               5'b00001
`define RV64_FP_RS2_ZERO            5'b00000

// Architectural FLEN=64 representation of an F result.
`define RV64_FP_NANBOX_S(value)     {32'hffff_ffff, value}
`define RV64_FP_CANONICAL_NAN_S     32'h7fc0_0000
`define RV64_FP_CANONICAL_NAN_D     64'h7ff8_0000_0000_0000

// FCLASS result bits, from negative infinity through quiet NaN.
`define RV64_FP_CLASS_NEG_INF        10'b0000000001
`define RV64_FP_CLASS_NEG_NORMAL     10'b0000000010
`define RV64_FP_CLASS_NEG_SUBNORMAL  10'b0000000100
`define RV64_FP_CLASS_NEG_ZERO       10'b0000001000
`define RV64_FP_CLASS_POS_ZERO       10'b0000010000
`define RV64_FP_CLASS_POS_SUBNORMAL  10'b0000100000
`define RV64_FP_CLASS_POS_NORMAL     10'b0001000000
`define RV64_FP_CLASS_POS_INF        10'b0010000000
`define RV64_FP_CLASS_SNAN           10'b0100000000
`define RV64_FP_CLASS_QNAN           10'b1000000000

`endif
