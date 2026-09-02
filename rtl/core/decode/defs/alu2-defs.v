`ifndef OPENRV64_DECODE_ALU2_DEFS_V
`define OPENRV64_DECODE_ALU2_DEFS_V

// ALU2 is an area-bounded experiment, not a third copy of the full integer
// execution lane.  These compile-time class switches are shared by dispatch
// and execution so an operation cannot be routed to hardware that is absent.
// A build may override any value before this header is included.
`ifndef OPENRV64_ALU2_ENABLE_ADD_SUB
`define OPENRV64_ALU2_ENABLE_ADD_SUB 0
`endif
`ifndef OPENRV64_ALU2_ENABLE_COMPARE
`define OPENRV64_ALU2_ENABLE_COMPARE 0
`endif
`ifndef OPENRV64_ALU2_ENABLE_UPPER
`define OPENRV64_ALU2_ENABLE_UPPER 0
`endif
`ifndef OPENRV64_ALU2_ENABLE_SHIFT
`define OPENRV64_ALU2_ENABLE_SHIFT 1
`endif
`ifndef OPENRV64_ALU2_ENABLE_LOGIC
`define OPENRV64_ALU2_ENABLE_LOGIC 1
`endif
`ifndef OPENRV64_ALU2_ENABLE_ROTATE
`define OPENRV64_ALU2_ENABLE_ROTATE 1
`endif

`define OPENRV64_ALU2_BASE_OP_SUPPORTED(op) (                         \
    (((`OPENRV64_ALU2_ENABLE_ADD_SUB) != 0) &&                        \
     (((op) == `RV64_ALU_OP_ADD) || ((op) == `RV64_ALU_OP_SUB))) ||  \
    (((`OPENRV64_ALU2_ENABLE_COMPARE) != 0) &&                        \
     (((op) == `RV64_ALU_OP_SLT) || ((op) == `RV64_ALU_OP_SLTU))) || \
    (((`OPENRV64_ALU2_ENABLE_UPPER) != 0) &&                          \
     (((op) == `RV64_ALU_OP_LUI) || ((op) == `RV64_ALU_OP_AUIPC))) ||\
    (((`OPENRV64_ALU2_ENABLE_SHIFT) != 0) &&                          \
     (((op) == `RV64_ALU_OP_SLL) || ((op) == `RV64_ALU_OP_SRL) ||    \
      ((op) == `RV64_ALU_OP_SRA))) ||                                \
    (((`OPENRV64_ALU2_ENABLE_LOGIC) != 0) &&                          \
     (((op) == `RV64_ALU_OP_XOR) || ((op) == `RV64_ALU_OP_OR) ||     \
      ((op) == `RV64_ALU_OP_AND))))

`define OPENRV64_ALU2_ZBB_OP_SUPPORTED(op) (                          \
    (((`OPENRV64_ALU2_ENABLE_LOGIC) != 0) &&                          \
     (((op) == `RV64_ALU_OP_ZBB_ANDN) ||                              \
      ((op) == `RV64_ALU_OP_ZBB_ORN) ||                               \
      ((op) == `RV64_ALU_OP_ZBB_XNOR))) ||                            \
    (((`OPENRV64_ALU2_ENABLE_ROTATE) != 0) &&                         \
     (((op) == `RV64_ALU_OP_ZBB_ROL) ||                               \
      ((op) == `RV64_ALU_OP_ZBB_ROR))))

`define OPENRV64_ALU2_OP_SUPPORTED(ext, op) (                         \
    ((((ext) == `RV64_ALU_EXT_BASE) &&                                \
      `OPENRV64_ALU2_BASE_OP_SUPPORTED(op)) ||                        \
     (((ext) == `RV64_ALU_EXT_ZBB) &&                                 \
      `OPENRV64_ALU2_ZBB_OP_SUPPORTED(op))))

`endif
