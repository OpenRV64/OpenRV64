`ifndef OPENRV64_BACKEND_DEFS_V
`define OPENRV64_BACKEND_DEFS_V

`define OPENRV64_BACKEND_CONFIG_WIDTH 2
`define OPENRV64_BACKEND_1P 2'd0
`define OPENRV64_BACKEND_2P 2'd1
`define OPENRV64_BACKEND_3P 2'd2

`define OPENRV64_EXEC_PIPE_WIDTH 2
`define OPENRV64_EXEC_PIPE_EX0 2'd0
`define OPENRV64_EXEC_PIPE_EX1 2'd1
`define OPENRV64_EXEC_PIPE_MEM 2'd2

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

// Retirement metadata is the original issue payload plus source-use and
// hard-order classification bits.  Packing from MSB to LSB is:
//
//   hard_order, uses_rs2, uses_rs1, issue_payload
`define OPENRV64_RETIRE_META_WIDTH 405

`endif
