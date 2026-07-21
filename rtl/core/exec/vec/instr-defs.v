`ifndef OPENRV64_EXEC_VEC_INSTR_DEFS_V
`define OPENRV64_EXEC_VEC_INSTR_DEFS_V

// Test-harness instruction encoding for the private vector unit. These are
// deliberately allocated from the RISC-V custom opcode space; they are not
// RVV encodings and are not decoded by the production core.
//
// CUSTOM-0 uses the normal R fields for vector arithmetic:
//   vd=rd, vs1=rs1, vs2=rs2, operation=funct3.
// VSET reads the complete private vtype command from scalar rs1.
`define OPENRV64_VEC_INSTR_OPCODE_ALU 7'b0001011
`define OPENRV64_VEC_INSTR_FUNCT3_VSET 3'b000
`define OPENRV64_VEC_INSTR_FUNCT3_AND  3'b001
`define OPENRV64_VEC_INSTR_FUNCT3_OR   3'b010
`define OPENRV64_VEC_INSTR_FUNCT3_XOR  3'b011
`define OPENRV64_VEC_INSTR_FUNCT3_NOT  3'b100
`define OPENRV64_VEC_INSTR_FUNCT3_FADD 3'b101
`define OPENRV64_VEC_INSTR_FUNCT3_FMUL 3'b110
// VSYNC names one architectural vector register in rs1. It is an explicit
// software dependency barrier, not an implicit hazard check on other ops.
`define OPENRV64_VEC_INSTR_FUNCT3_VSYNC 3'b111

// CUSTOM-1 is the vector memory family. A load uses rd as vd; a store uses
// rs2 as vs3. In both cases scalar rs1 names the pointer GPR requested through
// the LSU's read-only scalar sideband.
`define OPENRV64_VEC_INSTR_OPCODE_LSU 7'b0101011
`define OPENRV64_VEC_INSTR_FUNCT3_LOAD  3'b000
`define OPENRV64_VEC_INSTR_FUNCT3_STORE 3'b001

`endif
