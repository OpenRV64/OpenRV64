`ifndef OPENRV64_BUS_DEFS_V
`define OPENRV64_BUS_DEFS_V

`define OPENRV64_BUS_CONFIG_WIDTH 1
`define OPENRV64_BUS_GEN 1'd0
`define OPENRV64_BUS_AXI 1'd1

`define OPENRV64_AXI_ADDR_WIDTH 64
`define OPENRV64_AXI_DATA_WIDTH 256
`define OPENRV64_AXI_STRB_WIDTH 32
`define OPENRV64_AXI_ID_WIDTH 3

// In cacheless-L1I mode AXI IDs 0-3 identify instruction-line slots. Native
// L1D and PTW traffic use CCX; the LSU tag namespace is independent of AXI IDs
// and tracks up to eight outstanding operations.
`ifndef OPENRV64_LSU_TAG_WIDTH
`define OPENRV64_LSU_TAG_WIDTH 3
`endif
`ifndef OPENRV64_LSU_OUTSTANDING
`define OPENRV64_LSU_OUTSTANDING 8
`endif

`endif
