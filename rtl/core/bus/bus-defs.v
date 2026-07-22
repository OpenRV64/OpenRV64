`ifndef OPENRV64_BUS_DEFS_V
`define OPENRV64_BUS_DEFS_V

`define OPENRV64_BUS_CONFIG_WIDTH 1
`define OPENRV64_BUS_GEN 1'd0
`define OPENRV64_BUS_AXI 1'd1

`define OPENRV64_AXI_ADDR_WIDTH 64
`define OPENRV64_AXI_DATA_WIDTH 256
`define OPENRV64_AXI_STRB_WIDTH 32
`define OPENRV64_AXI_ID_WIDTH 3

// In cacheless-L1I mode AXI ID 0 is the instruction-line request.  IDs 4-6
// are reserved LSU pipeline slots and ID 7 is the serialized PTW path.  With
// L1I enabled, instruction lines use native CCX rather than AXI IDs.
`define OPENRV64_LSU_TAG_WIDTH 2
`define OPENRV64_LSU_OUTSTANDING 3

`endif
