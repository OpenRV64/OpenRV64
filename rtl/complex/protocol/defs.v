`ifndef OPENRV64_ICX_PROTOCOL_DEFS_V
`define OPENRV64_ICX_PROTOCOL_DEFS_V

// OpenRV64 core-complex protocol geometry.  Hart identity and local
// transaction identity remain separate so a future fabric can route by hart
// without consuming or rewriting the requester's tag.
`define OPENRV64_ICX_HART_ID_WIDTH 4
`define OPENRV64_ICX_TXN_ID_WIDTH  4
`define OPENRV64_ICX_OP_WIDTH      4
`define OPENRV64_ICX_ORDER_WIDTH   2
`define OPENRV64_ICX_KIND_WIDTH    2
`define OPENRV64_ICX_ATTR_WIDTH    4

// Native cache-facing geometry.  The compatibility modules below this file
// still use their explicit 64-bit payloads; these constants define the
// separate northbound line protocol used by private cache endpoints.
`define OPENRV64_ICX_SOURCE_ID_WIDTH 2
`define OPENRV64_ICX_BURST_LEN_WIDTH 8
`define OPENRV64_ICX_BEAT_INDEX_WIDTH 8
`define OPENRV64_ICX_LINE_BYTES      64
`define OPENRV64_ICX_LINE_DATA_WIDTH 512
`define OPENRV64_ICX_LINE_STRB_WIDTH 64

`define OPENRV64_ICX_SOURCE_ICACHE 2'd0
`define OPENRV64_ICX_SOURCE_DCACHE 2'd1
`define OPENRV64_ICX_SOURCE_PTW    2'd2
`define OPENRV64_ICX_SOURCE_LEGACY 2'd3

// Stable request operations.  The one-hart compatibility adapter currently
// emits READ and WRITE.  The remaining encodings are reserved now so later
// coherent logic receives atomic intent explicitly rather than attempting to
// infer an AMO or LR/SC sequence from ordinary memory traffic.
// `icx_req_lock` is a separate transitional signal used by the one-hart AMO
// bring-up path.  It is deliberately not encoded as another operation and is
// not the eventual coherent atomic contract.
`define OPENRV64_ICX_OP_READ       4'd0
`define OPENRV64_ICX_OP_WRITE      4'd1
`define OPENRV64_ICX_OP_LR         4'd2
`define OPENRV64_ICX_OP_SC         4'd3
`define OPENRV64_ICX_OP_AMOSWAP    4'd4
`define OPENRV64_ICX_OP_AMOADD     4'd5
`define OPENRV64_ICX_OP_AMOXOR     4'd6
`define OPENRV64_ICX_OP_AMOAND     4'd7
`define OPENRV64_ICX_OP_AMOOR      4'd8
`define OPENRV64_ICX_OP_AMOMIN     4'd9
`define OPENRV64_ICX_OP_AMOMAX     4'd10
`define OPENRV64_ICX_OP_AMOMINU    4'd11
`define OPENRV64_ICX_OP_AMOMAXU    4'd12
`define OPENRV64_ICX_OP_FENCE      4'd13

// SC responses carry an internal coherence disposition in resp_rdata[1:0].
// The architectural success bit remains on resp_sc_success for compatibility;
// SUCCESS_EXCLUSIVE additionally tells the requesting private D-cache that
// the home proved it was the sole D-side holder and retained its directory
// bit, so the resident line may be updated without a local invalidate.
`define OPENRV64_ICX_SC_RESULT_WIDTH             2
`define OPENRV64_ICX_SC_FAIL                     2'b00
`define OPENRV64_ICX_SC_SUCCESS_DROP             2'b01
`define OPENRV64_ICX_SC_SUCCESS_EXCLUSIVE        2'b10

`define OPENRV64_ICX_ORDER_NONE    2'd0
`define OPENRV64_ICX_ORDER_ACQUIRE 2'd1
`define OPENRV64_ICX_ORDER_RELEASE 2'd2
`define OPENRV64_ICX_ORDER_ACQ_REL 2'd3

// LEGACY means the current merged instruction/data physical port did not
// preserve requester class.  New native protocol endpoints must use the more
// specific encodings.
`define OPENRV64_ICX_KIND_LEGACY    2'd0
`define OPENRV64_ICX_KIND_FETCH     2'd1
`define OPENRV64_ICX_KIND_DATA      2'd2
`define OPENRV64_ICX_KIND_PTE       2'd3
// Compatibility spelling for users which identify the requester rather than
// the memory object.  New requests use KIND_PTE.
`define OPENRV64_ICX_KIND_PTW       `OPENRV64_ICX_KIND_PTE

`define OPENRV64_ICX_ATTR_NONE       4'b0000
`define OPENRV64_ICX_ATTR_CACHEABLE  4'b0001
`define OPENRV64_ICX_ATTR_DEVICE     4'b0010
`define OPENRV64_ICX_ATTR_IDEMPOTENT 4'b0100
`define OPENRV64_ICX_ATTR_EXECUTABLE 4'b1000

`endif
