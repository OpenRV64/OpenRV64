`ifndef OPENRV64_BACKEND_DEFS_V
`define OPENRV64_BACKEND_DEFS_V

`define OPENRV64_BACKEND_CONFIG_WIDTH 2
`define OPENRV64_BACKEND_1P 2'd0
`define OPENRV64_BACKEND_2P 2'd1
`define OPENRV64_BACKEND_3P 2'd2

`define OPENRV64_EXEC_PIPE_WIDTH 2
`define OPENRV64_EXEC_PIPE_EX0 2'd0
`define OPENRV64_EXEC_PIPE_EX1 2'd1
`define OPENRV64_EXEC_PIPE_MEM0 2'd2
`define OPENRV64_EXEC_PIPE_MEM1 2'd3
`define OPENRV64_EXEC_PIPE_MEM `OPENRV64_EXEC_PIPE_MEM0
`define OPENRV64_EXEC_PIPE_COUNT 4

// Internal instruction identity used to match issue, completion, redirect,
// and retirement state.  This is deliberately separate from the 64-bit trace
// ID embedded in the payload.  Age comparisons are modulo this width and are
// valid while fewer than half the namespace (512 IDs) can remain live.
`define OPENRV64_INSTR_ID_WIDTH 10

// Default integer physical-register configuration. PHYS_REG_COUNT counts
// stored, writable registers; hardwired p0 is part of the tag namespace but
// consumes no PRF entry. The current 3P renamer maps xN to pN. Live 3P
// composition derives the tag and retirement-metadata widths from the count;
// these macros retain the default shape for fixed-width unit wrappers.
`define OPENRV64_PHYS_REG_COUNT 31
`define OPENRV64_PHYS_REG_ADDR_WIDTH 5

// Fixed-width portion of a three-pipe issue packet.  Instruction identity and
// retire-queue slot are carried separately because slot width follows queue
// depth.  The payload is packed, most-significant field first, as:
//
//   trace_id, pc, instr, rs1_addr, rs2_addr, rs1_data, rs2_data, imm,
//   rd_addr, alu_ext, alu_op, lsu_op, br_op, reg_write, mem_read,
//   mem_write, branch, jump, predicted_taken, word_op, system, fence,
//   illegal, ebreak, ecall, instr_access_fault, instr_page_fault,
//   priv_mode, sret_allowed, sfence_vma_allowed
//
// Operands are values captured when dispatch accepts the instruction.  The
// execution cluster never reads the architectural register file directly.
`define OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH 402

// Fixed-width portion of a completion packet, packed as:
//
//   trace_id, pc, next_pc, instr, data, rs1_addr, rs2_addr, rd_addr,
//   reg_write, illegal, ebreak, ecall, exception, halt, cause, tval,
//   mret, sret, csr_write, csr_addr, csr_wdata
//
// CSR writes are intents.  The retirement side applies them only when the
// instruction retires; execution is not itself an architectural commit point.
`define OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH 457

// Frequently consumed completion fields, expressed as offsets from the
// least-significant bit of one completion payload.
`define OPENRV64_COMPLETE_EXCEPTION_BIT 149
`define OPENRV64_COMPLETE_ILLEGAL_BIT 152
`define OPENRV64_COMPLETE_REG_WRITE_BIT 153
`define OPENRV64_COMPLETE_RD_LSB 154
`define OPENRV64_COMPLETE_DATA_LSB 169

// Metadata produced internally by the strict and window dispatch engines.
// Packing from MSB to LSB is:
//
//   hard_order, uses_rs2, uses_rs1, issue_payload
`define OPENRV64_DISPATCH_META_WIDTH 405

// The common rename layer augments dispatch metadata before ROB allocation.
// old_phys is retained even by the identity implementation because a dynamic
// renamer must return it to the free list only when the instruction commits.
// Packing from MSB to LSB is:
//
//   old_phys, new_phys, hard_order, uses_rs2, uses_rs1, issue_payload
`define OPENRV64_RETIRE_META_WIDTH \
    (`OPENRV64_DISPATCH_META_WIDTH + 2*`OPENRV64_PHYS_REG_ADDR_WIDTH)

`endif
