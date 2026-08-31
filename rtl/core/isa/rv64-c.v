`ifndef OPENRV64_RV64_C_V
`define OPENRV64_RV64_C_V

`include "core/isa/rv64-i.v"

// RV64C parcel encoding.  A 16-bit parcel whose low pair is not 2'b11 is a
// compressed instruction; the pair selects one of three quadrants.  The
// 2'b11 pair is not a quadrant: it opens the ordinary 32-bit encoding
// space, in which [4:2] == 3'b111 marks a 48-bit-or-longer instruction.
`define RV64_C_QUADRANT_BITS 1:0
`define RV64_C_QUADRANT(instr) instr[`RV64_C_QUADRANT_BITS]
`define RV64_C_QUADRANT_0 2'b00
`define RV64_C_QUADRANT_1 2'b01
`define RV64_C_QUADRANT_2 2'b10
`define RV64_C_QUADRANT_UNCOMPRESSED 2'b11

`define RV64_INSTR_IS_C(instr) \
    (`RV64_C_QUADRANT(instr) != `RV64_C_QUADRANT_UNCOMPRESSED)

`define RV64_C_FUNCT3_BITS 15:13
`define RV64_C_FUNCT3(instr) instr[`RV64_C_FUNCT3_BITS]

// Three-bit rs1'/rs2' specifiers address the x8-x15 window.
`define RV64_C_REG_PRIME(r) {2'b01, r}

`endif
