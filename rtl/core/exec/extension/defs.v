`ifndef OPENRV64_EXEC_EXTENSION_DEFS_V
`define OPENRV64_EXEC_EXTENSION_DEFS_V

// Generic extension integration contract.
//
// The integer core owns program order and identifies every operation with the
// pair (retirement slot, instruction ID).  An extension owns its opaque decode
// payload, private register state, execution results, and architectural side
// effects.  It reports completion only after those results have been captured
// in extension-owned storage.  Retirement returns the same identity pair.
// IDs wrap; every live structure must fit within half of the ID namespace.
//
// Four unresolved branches may be represented in an extension request.  The
// meaning and allocation of individual bits is owned by the parent window.
`define OPENRV64_EXTENSION_BRANCH_COUNT 4

`define OPENRV64_EXTENSION_DEST_NONE    2'd0
`define OPENRV64_EXTENSION_DEST_GPR     2'd1
`define OPENRV64_EXTENSION_DEST_PRIVATE 2'd2

`endif
