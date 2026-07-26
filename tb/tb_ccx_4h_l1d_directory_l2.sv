`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"
`include "core/bus/bus-defs.v"

// Focused four-hart data-coherence integration test.
//
// Each req_* lane below is the LSU-side contract normally driven by the core
// memory channel.  The test deliberately does not instantiate execution,
// translation, or the LSQ: those blocks do not alter the private-cache/CCX
// coherence contract being checked here.
//
//   4 LSU agents -> 4 private L1D -> line crossbar -> directory -> L2 -> RAM
//
// Private caches are currently clean, write-through S/I endpoints.  A probe
// adapter holds an invalidate request at each real L1D until that cache
// accepts it, then returns the directory ACK.  It never fabricates an ACK
// before the cache invalidation handshake.
module tb_ccx_4h_l1d_directory_l2;

    localparam integer NUM_HARTS = 4;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer MEMORY_LINES = 256;
    localparam integer MEMORY_LATENCY = 4;
    localparam [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] LINE_A = MEMORY_BASE;
    localparam [63:0] LINE_B = MEMORY_BASE + 64'h0000_0040;
    localparam [63:0] LINE_C = MEMORY_BASE + 64'h0000_0080;
    localparam [63:0] WRITE_A0 = 64'hc001_cafe_0000_0002;
    localparam [63:0] WRITE_A1 = 64'hc001_cafe_0000_0001;

    logic clk;
    logic rst_n;
    integer cycle_count;
    integer wait_cycles;
    integer commands_before;
    integer reads_before;
    integer hart_index;
    integer memory_line_index;
    integer memory_word_index;
    integer memory_byte_index;

    // Four LSU-side request agents.
    logic [NUM_HARTS-1:0] lsu_req_valid;
    wire [NUM_HARTS-1:0] lsu_req_ready;
    logic [NUM_HARTS*TAG_WIDTH-1:0] lsu_req_tag;
    logic [NUM_HARTS-1:0] lsu_req_write;
    logic [NUM_HARTS*64-1:0] lsu_req_addr;
    logic [NUM_HARTS*64-1:0] lsu_req_wdata;
    logic [NUM_HARTS*8-1:0] lsu_req_wstrb;
    wire [NUM_HARTS*64-1:0] lsu_req_rdata;
    wire [NUM_HARTS-1:0] lsu_req_error;
    wire [NUM_HARTS-1:0] lsu_resp_valid;
    wire [NUM_HARTS*TAG_WIDTH-1:0] lsu_resp_tag;
    wire [NUM_HARTS-1:0] lsu_posted_resp_valid;
    wire [NUM_HARTS*TAG_WIDTH-1:0] lsu_posted_resp_tag;
    wire [NUM_HARTS-1:0] lsu_store_resp_valid;
    wire [NUM_HARTS-1:0] lsu_store_resp_error;
    logic [NUM_HARTS-1:0] speculation_barrier;
    wire [NUM_HARTS-1:0] store_barrier_busy;
    logic [NUM_HARTS*TAG_WIDTH-1:0] next_lsu_tag;

    // Private L1D to CCX line-crossbar channels.
    wire [NUM_HARTS-1:0] hart_req_valid;
    wire [NUM_HARTS-1:0] hart_req_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_req_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_req_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_req_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_OP_WIDTH-1:0] hart_req_op;
    wire [NUM_HARTS-1:0] hart_req_lock;
    wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0] hart_req_order;
    wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0] hart_req_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0] hart_req_attr;
    wire [NUM_HARTS*3-1:0] hart_req_size;
    wire [NUM_HARTS*64-1:0] hart_req_addr;
    wire [NUM_HARTS*`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        hart_req_burst_len;

    wire [NUM_HARTS-1:0] hart_wdata_valid;
    wire [NUM_HARTS-1:0] hart_wdata_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_wdata_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_wdata_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_wdata_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_wdata_beat_index;
    wire [NUM_HARTS-1:0] hart_wdata_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] hart_wdata;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] hart_wstrb;

    wire [NUM_HARTS-1:0] hart_resp_valid;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_resp_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_resp_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_resp_beat_index;
    wire [NUM_HARTS-1:0] hart_resp_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        hart_resp_rdata;
    wire [NUM_HARTS-1:0] hart_resp_error;
    wire [NUM_HARTS-1:0] hart_resp_sc_success;
    wire [NUM_HARTS-1:0] hart_resp_ready;

    // Crossbar to coherent-directory frontend.
    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;

    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;

    wire ccx_resp_valid;
    wire ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    wire ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_error;
    wire ccx_resp_sc_success;

    // Coherence-home probes.
    wire [NUM_HARTS-1:0] probe_valid;
    wire [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    wire [NUM_HARTS-1:0] probe_resp_valid;
    wire [NUM_HARTS-1:0] probe_resp_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
        probe_resp_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    wire [NUM_HARTS-1:0] probe_resp_error;
    wire [NUM_HARTS-1:0] l1d_invalidate_valid;
    wire [NUM_HARTS-1:0] l1d_invalidate_ready;
    wire [NUM_HARTS*64-1:0] l1d_invalidate_addr;
    logic [31:0] probe_accept_count [0:NUM_HARTS-1];
    logic [31:0] invalidate_count [0:NUM_HARTS-1];
    logic [31:0] invalidate_cycle [0:NUM_HARTS-1];

    // Directory to shared L2.
    wire l2_req_valid;
    wire l2_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l2_req_op;
    wire l2_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l2_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l2_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l2_req_attr;
    wire [2:0] l2_req_size;
    wire [63:0] l2_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l2_req_burst_len;

    wire l2_wdata_valid;
    wire l2_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_wdata_beat_index;
    wire l2_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l2_wstrb;

    wire l2_resp_valid;
    wire l2_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_resp_beat_index;
    wire l2_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_resp_rdata;
    wire l2_resp_error;
    wire l2_resp_sc_success;
    wire protocol_error;

    // Shared L2 to bounded-latency line memory.
    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_req_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    logic bus_resp_valid;
    wire bus_resp_ready;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_resp_rdata;
    logic bus_resp_error;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    logic memory_pending;
    logic memory_pending_write;
    logic [63:0] memory_pending_addr;
    integer memory_delay;
    integer memory_read_count;
    integer memory_write_count;
    integer l2_command_count;
    integer l2_write_count;
    integer last_l2_write_cycle;

    function automatic [63:0] initial_memory_word;
        input [63:0] address;
        begin
            initial_memory_word =
                address ^ 64'h4c32_4449_5245_4354;
        end
    endfunction

    function automatic integer line_index;
        input [63:0] address;
        begin
            line_index = address[13:6];
        end
    endfunction

    genvar hart;
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_l1d
            openrv64_l1d_ccx #(
                .ENABLE(1),
                .CACHE_BYTES(1024),
                .LINE_BYTES(64),
                .WAYS(2),
                .FILL_BUFFER_LINES(4),
                .DEMAND_MSHRS(2),
                .STORE_BUFFER_LINES(2),
                .STORE_BUFFER_DRAIN_WATERMARK(2),
                .STORE_BUFFER_TIMEOUT_CYCLES(128),
                .PREFETCH_ENABLE(0),
                .REQ_TAG_WIDTH(TAG_WIDTH),
                .REQ_DEPTH(1 << TAG_WIDTH),
                .HART_ID(`OPENRV64_CCX_HART_ID_WIDTH'(hart))
            ) u_l1d (
                .clk_i(clk),
                .rst_ni(rst_n),
                .req_valid_i(lsu_req_valid[hart]),
                .req_ready_o(lsu_req_ready[hart]),
                .req_tag_i(lsu_req_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .req_lock_i(1'b0),
                .req_posted_i(lsu_req_write[hart]),
                .req_write_i(lsu_req_write[hart]),
                .req_cacheable_i(1'b1),
                .req_addr_i(lsu_req_addr[hart*64 +: 64]),
                .req_size_i(3'd3),
                .req_wdata_i(lsu_req_wdata[hart*64 +: 64]),
                .req_wstrb_i(lsu_req_wstrb[hart*8 +: 8]),
                .req_rdata_o(lsu_req_rdata[hart*64 +: 64]),
                .req_error_o(lsu_req_error[hart]),
                .resp_valid_o(lsu_resp_valid[hart]),
                .resp_ready_i(1'b1),
                .resp_tag_o(lsu_resp_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .posted_resp_valid_o(lsu_posted_resp_valid[hart]),
                .posted_resp_ready_i(1'b1),
                .posted_resp_tag_o(
                    lsu_posted_resp_tag[hart*TAG_WIDTH +: TAG_WIDTH]),
                .store_resp_valid_o(lsu_store_resp_valid[hart]),
                .store_resp_ready_i(1'b1),
                .store_resp_error_o(lsu_store_resp_error[hart]),
                .prefetch_issued_o(),
                .prefetch_useful_o(),
                .prefetch_late_o(),
                .prefetch_dropped_o(),
                .prefetch_useless_o(),
                .prefetch_depth_o(),
                .speculation_barrier_i(speculation_barrier[hart]),
                .store_barrier_busy_o(store_barrier_busy[hart]),
                .invalidate_valid_i(l1d_invalidate_valid[hart]),
                .invalidate_ready_o(l1d_invalidate_ready[hart]),
                .invalidate_all_i(1'b0),
                .invalidate_addr_i(
                    l1d_invalidate_addr[hart*64 +: 64]),
                .ccx_req_valid_o(hart_req_valid[hart]),
                .ccx_req_ready_i(hart_req_ready[hart]),
                .ccx_req_hart_id_o(
                    hart_req_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_req_txn_id_o(
                    hart_req_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_req_source_id_o(
                    hart_req_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_req_op_o(
                    hart_req_op[
                        hart*`OPENRV64_CCX_OP_WIDTH +:
                        `OPENRV64_CCX_OP_WIDTH]),
                .ccx_req_lock_o(hart_req_lock[hart]),
                .ccx_req_order_o(
                    hart_req_order[
                        hart*`OPENRV64_CCX_ORDER_WIDTH +:
                        `OPENRV64_CCX_ORDER_WIDTH]),
                .ccx_req_kind_o(
                    hart_req_kind[
                        hart*`OPENRV64_CCX_KIND_WIDTH +:
                        `OPENRV64_CCX_KIND_WIDTH]),
                .ccx_req_attr_o(
                    hart_req_attr[
                        hart*`OPENRV64_CCX_ATTR_WIDTH +:
                        `OPENRV64_CCX_ATTR_WIDTH]),
                .ccx_req_size_o(hart_req_size[hart*3 +: 3]),
                .ccx_req_addr_o(hart_req_addr[hart*64 +: 64]),
                .ccx_req_burst_len_o(
                    hart_req_burst_len[
                        hart*`OPENRV64_CCX_BURST_LEN_WIDTH +:
                        `OPENRV64_CCX_BURST_LEN_WIDTH]),
                .ccx_wdata_valid_o(hart_wdata_valid[hart]),
                .ccx_wdata_ready_i(hart_wdata_ready[hart]),
                .ccx_wdata_hart_id_o(
                    hart_wdata_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_wdata_txn_id_o(
                    hart_wdata_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_wdata_source_id_o(
                    hart_wdata_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_wdata_beat_index_o(
                    hart_wdata_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_wdata_last_o(hart_wdata_last[hart]),
                .ccx_wdata_o(
                    hart_wdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_wstrb_o(
                    hart_wstrb[
                        hart*`OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH]),
                .ccx_resp_valid_i(hart_resp_valid[hart]),
                .ccx_resp_ready_o(hart_resp_ready[hart]),
                .ccx_resp_hart_id_i(
                    hart_resp_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_resp_txn_id_i(
                    hart_resp_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_resp_source_id_i(
                    hart_resp_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_resp_beat_index_i(
                    hart_resp_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_resp_last_i(hart_resp_last[hart]),
                .ccx_resp_rdata_i(
                    hart_resp_rdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_resp_error_i(hart_resp_error[hart]),
                .ccx_resp_sc_success_i(hart_resp_sc_success[hart])
            );
        end
    endgenerate

    openrv64_ccx_line_crossbar #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0)
    ) u_crossbar (
        .clk_i(clk),
        .rst_ni(rst_n),
        .hart_req_valid_i(hart_req_valid),
        .hart_req_ready_o(hart_req_ready),
        .hart_req_hart_id_i(hart_req_hart_id),
        .hart_req_txn_id_i(hart_req_txn_id),
        .hart_req_source_id_i(hart_req_source_id),
        .hart_req_op_i(hart_req_op),
        .hart_req_lock_i(hart_req_lock),
        .hart_req_order_i(hart_req_order),
        .hart_req_kind_i(hart_req_kind),
        .hart_req_attr_i(hart_req_attr),
        .hart_req_size_i(hart_req_size),
        .hart_req_addr_i(hart_req_addr),
        .hart_req_burst_len_i(hart_req_burst_len),
        .mem_req_valid_o(ccx_req_valid),
        .mem_req_ready_i(ccx_req_ready),
        .mem_req_hart_id_o(ccx_req_hart_id),
        .mem_req_txn_id_o(ccx_req_txn_id),
        .mem_req_source_id_o(ccx_req_source_id),
        .mem_req_op_o(ccx_req_op),
        .mem_req_lock_o(ccx_req_lock),
        .mem_req_order_o(ccx_req_order),
        .mem_req_kind_o(ccx_req_kind),
        .mem_req_attr_o(ccx_req_attr),
        .mem_req_size_o(ccx_req_size),
        .mem_req_addr_o(ccx_req_addr),
        .mem_req_burst_len_o(ccx_req_burst_len),
        .hart_wdata_valid_i(hart_wdata_valid),
        .hart_wdata_ready_o(hart_wdata_ready),
        .hart_wdata_hart_id_i(hart_wdata_hart_id),
        .hart_wdata_txn_id_i(hart_wdata_txn_id),
        .hart_wdata_source_id_i(hart_wdata_source_id),
        .hart_wdata_beat_index_i(hart_wdata_beat_index),
        .hart_wdata_last_i(hart_wdata_last),
        .hart_wdata_i(hart_wdata),
        .hart_wstrb_i(hart_wstrb),
        .mem_wdata_valid_o(ccx_wdata_valid),
        .mem_wdata_ready_i(ccx_wdata_ready),
        .mem_wdata_hart_id_o(ccx_wdata_hart_id),
        .mem_wdata_txn_id_o(ccx_wdata_txn_id),
        .mem_wdata_source_id_o(ccx_wdata_source_id),
        .mem_wdata_beat_index_o(ccx_wdata_beat_index),
        .mem_wdata_last_o(ccx_wdata_last),
        .mem_wdata_o(ccx_wdata),
        .mem_wstrb_o(ccx_wstrb),
        .mem_resp_valid_i(ccx_resp_valid),
        .mem_resp_ready_o(ccx_resp_ready),
        .mem_resp_hart_id_i(ccx_resp_hart_id),
        .mem_resp_txn_id_i(ccx_resp_txn_id),
        .mem_resp_source_id_i(ccx_resp_source_id),
        .mem_resp_beat_index_i(ccx_resp_beat_index),
        .mem_resp_last_i(ccx_resp_last),
        .mem_resp_rdata_i(ccx_resp_rdata),
        .mem_resp_error_i(ccx_resp_error),
        .mem_resp_sc_success_i(ccx_resp_sc_success),
        .hart_resp_valid_o(hart_resp_valid),
        .hart_resp_ready_i(hart_resp_ready),
        .hart_resp_hart_id_o(hart_resp_hart_id),
        .hart_resp_txn_id_o(hart_resp_txn_id),
        .hart_resp_source_id_o(hart_resp_source_id),
        .hart_resp_beat_index_o(hart_resp_beat_index),
        .hart_resp_last_o(hart_resp_last),
        .hart_resp_rdata_o(hart_resp_rdata),
        .hart_resp_error_o(hart_resp_error),
        .hart_resp_sc_success_o(hart_resp_sc_success)
    );

    openrv64_ccx_coherent_protocol #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0),
        .DIRECTORY_ENTRIES(64),
        .DIRECTORY_WAYS(4)
    ) u_directory_frontend (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(ccx_req_valid),
        .req_ready_o(ccx_req_ready),
        .req_hart_id_i(ccx_req_hart_id),
        .req_txn_id_i(ccx_req_txn_id),
        .req_source_id_i(ccx_req_source_id),
        .req_op_i(ccx_req_op),
        .req_lock_i(ccx_req_lock),
        .req_order_i(ccx_req_order),
        .req_kind_i(ccx_req_kind),
        .req_attr_i(ccx_req_attr),
        .req_size_i(ccx_req_size),
        .req_addr_i(ccx_req_addr),
        .req_burst_len_i(ccx_req_burst_len),
        .wdata_valid_i(ccx_wdata_valid),
        .wdata_ready_o(ccx_wdata_ready),
        .wdata_hart_id_i(ccx_wdata_hart_id),
        .wdata_txn_id_i(ccx_wdata_txn_id),
        .wdata_source_id_i(ccx_wdata_source_id),
        .wdata_beat_index_i(ccx_wdata_beat_index),
        .wdata_last_i(ccx_wdata_last),
        .wdata_i(ccx_wdata),
        .wstrb_i(ccx_wstrb),
        .resp_valid_o(ccx_resp_valid),
        .resp_ready_i(ccx_resp_ready),
        .resp_hart_id_o(ccx_resp_hart_id),
        .resp_txn_id_o(ccx_resp_txn_id),
        .resp_source_id_o(ccx_resp_source_id),
        .resp_beat_index_o(ccx_resp_beat_index),
        .resp_last_o(ccx_resp_last),
        .resp_rdata_o(ccx_resp_rdata),
        .resp_error_o(ccx_resp_error),
        .resp_sc_success_o(ccx_resp_sc_success),
        .probe_valid_o(probe_valid),
        .probe_ready_i(probe_ready),
        .probe_id_o(probe_id),
        .probe_command_o(probe_command),
        .probe_cache_mask_o(probe_cache_mask),
        .probe_line_addr_o(probe_line_addr),
        .probe_resp_valid_i(probe_resp_valid),
        .probe_resp_ready_o(probe_resp_ready),
        .probe_resp_id_i(probe_resp_id),
        .probe_resp_kind_i(probe_resp_kind),
        .probe_resp_data_i(probe_resp_data),
        .probe_resp_error_i(probe_resp_error),
        .l2_req_valid_o(l2_req_valid),
        .l2_req_ready_i(l2_req_ready),
        .l2_req_hart_id_o(l2_req_hart_id),
        .l2_req_txn_id_o(l2_req_txn_id),
        .l2_req_source_id_o(l2_req_source_id),
        .l2_req_op_o(l2_req_op),
        .l2_req_lock_o(l2_req_lock),
        .l2_req_order_o(l2_req_order),
        .l2_req_kind_o(l2_req_kind),
        .l2_req_attr_o(l2_req_attr),
        .l2_req_size_o(l2_req_size),
        .l2_req_addr_o(l2_req_addr),
        .l2_req_burst_len_o(l2_req_burst_len),
        .l2_wdata_valid_o(l2_wdata_valid),
        .l2_wdata_ready_i(l2_wdata_ready),
        .l2_wdata_hart_id_o(l2_wdata_hart_id),
        .l2_wdata_txn_id_o(l2_wdata_txn_id),
        .l2_wdata_source_id_o(l2_wdata_source_id),
        .l2_wdata_beat_index_o(l2_wdata_beat_index),
        .l2_wdata_last_o(l2_wdata_last),
        .l2_wdata_o(l2_wdata),
        .l2_wstrb_o(l2_wstrb),
        .l2_resp_valid_i(l2_resp_valid),
        .l2_resp_ready_o(l2_resp_ready),
        .l2_resp_hart_id_i(l2_resp_hart_id),
        .l2_resp_txn_id_i(l2_resp_txn_id),
        .l2_resp_source_id_i(l2_resp_source_id),
        .l2_resp_beat_index_i(l2_resp_beat_index),
        .l2_resp_last_i(l2_resp_last),
        .l2_resp_rdata_i(l2_resp_rdata),
        .l2_resp_error_i(l2_resp_error),
        .l2_resp_sc_success_i(l2_resp_sc_success),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(protocol_error)
    );

    openrv64_ccx_l2_native #(
        .CACHE_BYTES(256 * 1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .MSHR_ENTRIES(2),
        .WAITERS_PER_MSHR(4),
        .COMMAND_ENTRIES(4),
        .RESPONSE_ENTRIES(8),
        .BUS_TRACK_ENTRIES(2)
    ) u_l2 (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l2_req_valid),
        .req_ready_o(l2_req_ready),
        .req_hart_id_i(l2_req_hart_id),
        .req_txn_id_i(l2_req_txn_id),
        .req_source_id_i(l2_req_source_id),
        .req_op_i(l2_req_op),
        .req_lock_i(l2_req_lock),
        .req_order_i(l2_req_order),
        .req_kind_i(l2_req_kind),
        .req_attr_i(l2_req_attr),
        .req_size_i(l2_req_size),
        .req_addr_i(l2_req_addr),
        .req_burst_len_i(l2_req_burst_len),
        .wdata_valid_i(l2_wdata_valid),
        .wdata_ready_o(l2_wdata_ready),
        .wdata_hart_id_i(l2_wdata_hart_id),
        .wdata_txn_id_i(l2_wdata_txn_id),
        .wdata_source_id_i(l2_wdata_source_id),
        .wdata_beat_index_i(l2_wdata_beat_index),
        .wdata_last_i(l2_wdata_last),
        .wdata_i(l2_wdata),
        .wstrb_i(l2_wstrb),
        .resp_valid_o(l2_resp_valid),
        .resp_ready_i(l2_resp_ready),
        .resp_hart_id_o(l2_resp_hart_id),
        .resp_txn_id_o(l2_resp_txn_id),
        .resp_source_id_o(l2_resp_source_id),
        .resp_beat_index_o(l2_resp_beat_index),
        .resp_last_o(l2_resp_last),
        .resp_rdata_o(l2_resp_rdata),
        .resp_error_o(l2_resp_error),
        .resp_sc_success_o(l2_resp_sc_success),
        .bus_req_valid_o(bus_req_valid),
        .bus_req_ready_i(bus_req_ready),
        .bus_req_write_o(bus_req_write),
        .bus_req_addr_o(bus_req_addr),
        .bus_req_size_o(bus_req_size),
        .bus_req_wdata_o(bus_req_wdata),
        .bus_req_wstrb_o(bus_req_wstrb),
        .bus_req_cacheable_o(bus_req_cacheable),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_o(bus_resp_ready),
        .bus_resp_rdata_i(bus_resp_rdata),
        .bus_resp_error_i(bus_resp_error)
    );

    // Per-hart probe endpoint.  The response identity is captured when the
    // probe is accepted, but the ACK remains suppressed until the real L1D
    // invalidation port completes.
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_probe
            logic invalidate_pending_q;
            logic response_valid_q;
            logic [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] response_id_q;
            logic [63:0] invalidate_addr_q;
            wire [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
                incoming_cache_mask =
                    probe_cache_mask[
                        hart*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                        `OPENRV64_CCX_PROBE_CACHE_WIDTH];
            wire incoming_dcache =
                |(incoming_cache_mask & `OPENRV64_CCX_PROBE_CACHE_D);
            wire probe_fire = probe_valid[hart] && probe_ready[hart];
            wire invalidate_fire =
                invalidate_pending_q && l1d_invalidate_ready[hart];

            assign probe_ready[hart] =
                !invalidate_pending_q && !response_valid_q;
            assign l1d_invalidate_valid[hart] = invalidate_pending_q;
            assign l1d_invalidate_addr[hart*64 +: 64] =
                invalidate_addr_q;
            assign probe_resp_valid[hart] = response_valid_q;
            assign probe_resp_id[
                hart*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                `OPENRV64_CCX_PROBE_ID_WIDTH] = response_id_q;
            assign probe_resp_kind[
                hart*`OPENRV64_CCX_PROBE_RESP_WIDTH +:
                `OPENRV64_CCX_PROBE_RESP_WIDTH] =
                `OPENRV64_CCX_PROBE_RESP_ACK;
            assign probe_resp_data[
                hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                `OPENRV64_CCX_LINE_DATA_WIDTH] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            assign probe_resp_error[hart] = 1'b0;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    invalidate_pending_q <= 1'b0;
                    response_valid_q <= 1'b0;
                    response_id_q <=
                        {`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
                    invalidate_addr_q <= 64'd0;
                    probe_accept_count[hart] <= 32'd0;
                    invalidate_count[hart] <= 32'd0;
                    invalidate_cycle[hart] <= 32'd0;
                end else begin
                    if (response_valid_q && probe_resp_ready[hart])
                        response_valid_q <= 1'b0;

                    if (probe_fire) begin
                        if (probe_command[
                                hart*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                                `OPENRV64_CCX_PROBE_CMD_WIDTH] !=
                            `OPENRV64_CCX_PROBE_INV)
                            $fatal(1,
                                "hart %0d received unsupported data probe",
                                hart);
                        response_id_q <=
                            probe_id[
                                hart*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                                `OPENRV64_CCX_PROBE_ID_WIDTH];
                        invalidate_addr_q <=
                            probe_line_addr[hart*64 +: 64];
                        probe_accept_count[hart] <=
                            probe_accept_count[hart] + 1'b1;
                        if (incoming_dcache) begin
                            invalidate_pending_q <= 1'b1;
                        end else begin
                            // This bench has no L1I.  An I-only probe is an
                            // immediate clean miss at this endpoint.
                            response_valid_q <= 1'b1;
                        end
                    end

                    if (invalidate_fire) begin
                        invalidate_pending_q <= 1'b0;
                        response_valid_q <= 1'b1;
                        invalidate_count[hart] <=
                            invalidate_count[hart] + 1'b1;
                        invalidate_cycle[hart] <= cycle_count;
                    end
                end
            end
        end
    endgenerate

    assign bus_req_ready = !memory_pending && !bus_resp_valid;

    // One-outstanding, fixed-latency backing store.  This is intentionally not
    // a DDR timing model; the integration boundary under test ends at L2.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memory_pending <= 1'b0;
            memory_pending_write <= 1'b0;
            memory_pending_addr <= 64'd0;
            memory_delay <= 0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            bus_resp_error <= 1'b0;
            memory_read_count <= 0;
            memory_write_count <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if ((bus_req_size != 3'd6) ||
                    (bus_req_addr[5:0] != 6'd0) ||
                    !bus_req_cacheable)
                    $fatal(1, "malformed L2 memory request");
                memory_pending <= 1'b1;
                memory_pending_write <= bus_req_write;
                memory_pending_addr <= bus_req_addr;
                memory_delay <= MEMORY_LATENCY - 1;
                if (bus_req_write) begin
                    memory_write_count <= memory_write_count + 1;
                    for (memory_byte_index = 0;
                         memory_byte_index <
                             `OPENRV64_CCX_LINE_STRB_WIDTH;
                         memory_byte_index =
                             memory_byte_index + 1)
                        if (bus_req_wstrb[memory_byte_index])
                            memory[line_index(bus_req_addr)][
                                memory_byte_index*8 +: 8] <=
                                bus_req_wdata[
                                    memory_byte_index*8 +: 8];
                end else begin
                    memory_read_count <= memory_read_count + 1;
                end
            end else if (memory_pending) begin
                if (memory_delay == 0) begin
                    memory_pending <= 1'b0;
                    bus_resp_valid <= 1'b1;
                    bus_resp_rdata <= memory_pending_write ?
                        {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}} :
                        memory[line_index(memory_pending_addr)];
                end else begin
                    memory_delay <= memory_delay - 1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_command_count <= 0;
            l2_write_count <= 0;
            last_l2_write_cycle <= -1;
        end else if (l2_req_valid && l2_req_ready) begin
            l2_command_count <= l2_command_count + 1;
            if (l2_req_op == `OPENRV64_CCX_OP_WRITE) begin
                l2_write_count <= l2_write_count + 1;
                last_l2_write_cycle <= cycle_count;
            end
        end
    end

    task automatic issue_load;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] expected;
        logic [TAG_WIDTH-1:0] selected_tag;
        begin
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b1;
            lsu_req_write[selected_hart] = 1'b0;
            lsu_req_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;
            lsu_req_addr[selected_hart*64 +: 64] = address;
            lsu_req_wdata[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'd0;
            wait_cycles = 0;
            while (!lsu_req_ready[selected_hart] &&
                   (wait_cycles < 1000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!lsu_req_ready[selected_hart])
                $fatal(1, "hart %0d load request timeout",
                       selected_hart);
            @(posedge clk);
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b0;
            lsu_req_addr[selected_hart*64 +: 64] = 64'd0;

            wait_cycles = 0;
            while (!lsu_resp_valid[selected_hart] &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!lsu_resp_valid[selected_hart])
                $fatal(1, "hart %0d load response timeout",
                       selected_hart);
            if (lsu_req_error[selected_hart] ||
                (lsu_resp_tag[
                    selected_hart*TAG_WIDTH +: TAG_WIDTH] !=
                 selected_tag) ||
                (lsu_req_rdata[selected_hart*64 +: 64] !== expected))
                $fatal(1,
                    "hart %0d load addr=%016x data=%016x expected=%016x tag=%0d/%0d error=%0b",
                    selected_hart, address,
                    lsu_req_rdata[selected_hart*64 +: 64], expected,
                    lsu_resp_tag[
                        selected_hart*TAG_WIDTH +: TAG_WIDTH],
                    selected_tag, lsu_req_error[selected_hart]);
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_store;
        input integer selected_hart;
        input [63:0] address;
        input [63:0] data;
        logic [TAG_WIDTH-1:0] selected_tag;
        begin
            selected_tag =
                next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH];
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b1;
            lsu_req_write[selected_hart] = 1'b1;
            lsu_req_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag;
            lsu_req_addr[selected_hart*64 +: 64] = address;
            lsu_req_wdata[selected_hart*64 +: 64] = data;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'hff;
            wait_cycles = 0;
            while (!lsu_req_ready[selected_hart] &&
                   (wait_cycles < 1000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!lsu_req_ready[selected_hart])
                $fatal(1, "hart %0d store request timeout",
                       selected_hart);
            @(posedge clk);
            @(negedge clk);
            lsu_req_valid[selected_hart] = 1'b0;
            lsu_req_write[selected_hart] = 1'b0;
            lsu_req_addr[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wdata[selected_hart*64 +: 64] = 64'd0;
            lsu_req_wstrb[selected_hart*8 +: 8] = 8'd0;

            wait_cycles = 0;
            while (!lsu_posted_resp_valid[selected_hart] &&
                   (wait_cycles < 1000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!lsu_posted_resp_valid[selected_hart] ||
                (lsu_posted_resp_tag[
                    selected_hart*TAG_WIDTH +: TAG_WIDTH] !=
                 selected_tag))
                $fatal(1, "hart %0d posted store completion failed",
                       selected_hart);
            next_lsu_tag[selected_hart*TAG_WIDTH +: TAG_WIDTH] =
                selected_tag + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic drain_stores;
        input integer selected_hart;
        begin
            @(negedge clk);
            speculation_barrier[selected_hart] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            speculation_barrier[selected_hart] = 1'b0;
            wait_cycles = 0;
            while (store_barrier_busy[selected_hart] &&
                   (wait_cycles < 3000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (store_barrier_busy[selected_hart])
                $fatal(1, "hart %0d store barrier timeout",
                       selected_hart);
            if (lsu_store_resp_error[selected_hart])
                $fatal(1, "hart %0d downstream store error",
                       selected_hart);
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    initial begin
        for (memory_line_index = 0;
             memory_line_index < MEMORY_LINES;
             memory_line_index = memory_line_index + 1) begin
            memory[memory_line_index] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            for (memory_word_index = 0;
                 memory_word_index < 8;
                 memory_word_index = memory_word_index + 1)
                memory[memory_line_index][memory_word_index*64 +: 64] =
                    initial_memory_word(
                        MEMORY_BASE + memory_line_index*64 +
                        memory_word_index*8);
        end
    end

    initial begin
        rst_n = 1'b0;
        cycle_count = 0;
        lsu_req_valid = {NUM_HARTS{1'b0}};
        lsu_req_write = {NUM_HARTS{1'b0}};
        lsu_req_tag = {NUM_HARTS*TAG_WIDTH{1'b0}};
        lsu_req_addr = {NUM_HARTS*64{1'b0}};
        lsu_req_wdata = {NUM_HARTS*64{1'b0}};
        lsu_req_wstrb = {NUM_HARTS*8{1'b0}};
        speculation_barrier = {NUM_HARTS{1'b0}};
        next_lsu_tag = {NUM_HARTS*TAG_WIDTH{1'b0}};

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Every L1D participates.  Harts 0 and 1 share A; harts 2 and 3
        // independently fill B and C through the same directory and L2.
        issue_load(0, LINE_A, initial_memory_word(LINE_A));
        issue_load(1, LINE_A, initial_memory_word(LINE_A));
        issue_load(2, LINE_B, initial_memory_word(LINE_B));
        issue_load(3, LINE_C, initial_memory_word(LINE_C));
        if (memory_read_count != 3)
            $fatal(1,
                "shared L2 did not merge/hit repeated line reads count=%0d",
                memory_read_count);

        // A resident repeat must hit in private L1D and emit no new L2
        // command.
        commands_before = l2_command_count;
        issue_load(0, LINE_A, initial_memory_word(LINE_A));
        if (l2_command_count != commands_before)
            $fatal(1, "hart 0 resident load escaped L1D");

        // Hart 2 has no cached A copy, avoiding a self-probe limitation in
        // the current idle/drain-coupled L1D invalidation seam.  Its posted
        // write must invalidate the recorded harts 0 and 1 before L2 sees it.
        issue_store(2, LINE_A, WRITE_A0);
        drain_stores(2);
        if ((probe_accept_count[0] != 1) ||
            (probe_accept_count[1] != 1) ||
            (probe_accept_count[2] != 0) ||
            (probe_accept_count[3] != 0) ||
            (invalidate_count[0] != 1) ||
            (invalidate_count[1] != 1))
            $fatal(1,
                "first write probe targets/invalidations incorrect");
        if ((last_l2_write_cycle <= invalidate_cycle[0]) ||
            (last_l2_write_cycle <= invalidate_cycle[1]))
            $fatal(1, "L2 write crossed before private invalidations");

        // Hart 0 must miss after its probe and observe the value installed in
        // the shared L2, not the stale private value.  No backing-memory read
        // is expected because the non-inclusive L2 still owns its own copy.
        reads_before = memory_read_count;
        issue_load(0, LINE_A, WRITE_A0);
        if (memory_read_count != reads_before)
            $fatal(1, "post-invalidate reload missed shared L2");

        // Hart 3 becomes another sharer.  A write from the invalidated hart 1
        // then probes harts 0 and 3, proving that directory ownership changes
        // are not hard-wired to the first pair.
        issue_load(3, LINE_A, WRITE_A0);
        issue_store(1, LINE_A, WRITE_A1);
        drain_stores(1);
        if ((probe_accept_count[0] != 2) ||
            (probe_accept_count[1] != 1) ||
            (probe_accept_count[2] != 0) ||
            (probe_accept_count[3] != 1) ||
            (invalidate_count[0] != 2) ||
            (invalidate_count[3] != 1))
            $fatal(1,
                "second write probe targets/invalidations incorrect");
        issue_load(3, LINE_A, WRITE_A1);

        if (protocol_error)
            $fatal(1, "coherent protocol reported an integration error");
        if (l2_write_count != 2)
            $fatal(1, "L2 write command count=%0d expected=2",
                   l2_write_count);

        $display(
            "PASS: 4 LSU agents -> 4 L1D -> CCX directory -> shared L2");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "four-hart L1D/directory/L2 test timed out");
    end

endmodule
