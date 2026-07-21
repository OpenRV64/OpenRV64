`ifndef OPENRV64_COMPLEX_BUS_DEFS_V
`define OPENRV64_COMPLEX_BUS_DEFS_V

// Elaboration-time choices for the external bus below the core complex.
// These values are deliberately separate from rtl/core/bus/bus-defs.v: that
// file selects the current core-local memory implementation, while this file
// selects the southbound transport below the shared cache.
`define OPENRV64_COMPLEX_BUS_AXI       0
`define OPENRV64_COMPLEX_BUS_WISHBONE  1

`endif
