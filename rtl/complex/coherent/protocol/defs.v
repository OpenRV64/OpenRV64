`ifndef OPENRV64_CCX_COHERENT_PROTOCOL_DEFS_V
`define OPENRV64_CCX_COHERENT_PROTOCOL_DEFS_V

// Coherent private-cache probe protocol.  This is separate from the ordinary
// CCX request protocol because probes flow from the coherence home back toward
// private caches and must make progress independently of demand traffic.
`define OPENRV64_CCX_PROBE_ID_WIDTH     4
`define OPENRV64_CCX_PROBE_CMD_WIDTH    2
`define OPENRV64_CCX_PROBE_CACHE_WIDTH  2

`define OPENRV64_CCX_PROBE_INV          2'd0
// Reserved for a future write-back private-cache protocol.  READ_SHARED asks
// a dirty owner to supply data and retain a clean shared copy; READ_INVALIDATE
// asks it to supply data and invalidate its copy.
`define OPENRV64_CCX_PROBE_READ_SHARED  2'd1
`define OPENRV64_CCX_PROBE_READ_INVALIDATE 2'd2

`define OPENRV64_CCX_PROBE_CACHE_NONE   2'b00
`define OPENRV64_CCX_PROBE_CACHE_I      2'b01
`define OPENRV64_CCX_PROBE_CACHE_D      2'b10
`define OPENRV64_CCX_PROBE_CACHE_BOTH   2'b11

`define OPENRV64_CCX_PROBE_RESP_WIDTH   2
`define OPENRV64_CCX_PROBE_RESP_ACK     2'd0
`define OPENRV64_CCX_PROBE_RESP_DATA    2'd1
`define OPENRV64_CCX_PROBE_RESP_ERROR   2'd2

`endif
