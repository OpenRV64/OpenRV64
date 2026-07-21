`ifndef OPENRV64_CCX_PROTOCOL_DEFS_V
`define OPENRV64_CCX_PROTOCOL_DEFS_V

// OpenRV64 core-complex protocol geometry.  Hart identity and local
// transaction identity remain separate so a future fabric can route by hart
// without consuming or rewriting the requester's tag.
`define OPENRV64_CCX_HART_ID_WIDTH 4
`define OPENRV64_CCX_TXN_ID_WIDTH  4
`define OPENRV64_CCX_OP_WIDTH      4
`define OPENRV64_CCX_ORDER_WIDTH   2
`define OPENRV64_CCX_KIND_WIDTH    2
`define OPENRV64_CCX_ATTR_WIDTH    4

// Stable request operations.  The one-hart compatibility adapter currently
// emits READ and WRITE.  The remaining encodings are reserved now so later
// coherent logic receives atomic intent explicitly rather than attempting to
// infer an AMO or LR/SC sequence from ordinary memory traffic.
`define OPENRV64_CCX_OP_READ       4'd0
`define OPENRV64_CCX_OP_WRITE      4'd1
`define OPENRV64_CCX_OP_LR         4'd2
`define OPENRV64_CCX_OP_SC         4'd3
`define OPENRV64_CCX_OP_AMOSWAP    4'd4
`define OPENRV64_CCX_OP_AMOADD     4'd5
`define OPENRV64_CCX_OP_AMOXOR     4'd6
`define OPENRV64_CCX_OP_AMOAND     4'd7
`define OPENRV64_CCX_OP_AMOOR      4'd8
`define OPENRV64_CCX_OP_AMOMIN     4'd9
`define OPENRV64_CCX_OP_AMOMAX     4'd10
`define OPENRV64_CCX_OP_AMOMINU    4'd11
`define OPENRV64_CCX_OP_AMOMAXU    4'd12
`define OPENRV64_CCX_OP_FENCE      4'd13

`define OPENRV64_CCX_ORDER_NONE    2'd0
`define OPENRV64_CCX_ORDER_ACQUIRE 2'd1
`define OPENRV64_CCX_ORDER_RELEASE 2'd2
`define OPENRV64_CCX_ORDER_ACQ_REL 2'd3

// LEGACY means the current merged instruction/data physical port did not
// preserve requester class.  New native protocol endpoints must use the more
// specific encodings.
`define OPENRV64_CCX_KIND_LEGACY    2'd0
`define OPENRV64_CCX_KIND_FETCH     2'd1
`define OPENRV64_CCX_KIND_DATA      2'd2
`define OPENRV64_CCX_KIND_PTW       2'd3

`define OPENRV64_CCX_ATTR_NONE       4'b0000
`define OPENRV64_CCX_ATTR_CACHEABLE  4'b0001
`define OPENRV64_CCX_ATTR_DEVICE     4'b0010
`define OPENRV64_CCX_ATTR_IDEMPOTENT 4'b0100
`define OPENRV64_CCX_ATTR_EXECUTABLE 4'b1000

`endif
