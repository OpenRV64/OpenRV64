`ifndef OPENRV64_BUS_DEFS_V
`define OPENRV64_BUS_DEFS_V

`define OPENRV64_BUS_CONFIG_WIDTH 1
`define OPENRV64_BUS_GEN 1'd0
`define OPENRV64_BUS_AXI 1'd1

`define OPENRV64_AXI_ADDR_WIDTH 64
`define OPENRV64_AXI_DATA_WIDTH 256
`define OPENRV64_AXI_STRB_WIDTH 32
`define OPENRV64_AXI_ID_WIDTH 3

// AXI IDs 0-3 are instruction-line requests.  IDs 4-6 are independent LSU
// transactions; ID 7 remains reserved for the blocking PTW/legacy data path.
`define OPENRV64_LSU_TAG_WIDTH 2
`define OPENRV64_LSU_OUTSTANDING 3

`endif
