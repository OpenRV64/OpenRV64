`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"
`include "core/isa/rv64-priv.v"
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

// Burst-capable 256-bit AXI SRAM used behind the production CCX/L2 hierarchy.
// The 16 MiB aperture is sparse in Verilator so the generated model does not
// materialize half a million empty 256-bit words.
module tb_axi256_burst_sram #(
    parameter integer RAM_BYTES = 16 * 1024 * 1024
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] arid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] araddr_i,
    input  wire [7:0] arlen_i,
    input  wire [2:0] arsize_i,
    input  wire [1:0] arburst_i,
    input  wire arvalid_i,
    output wire arready_o,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] rid_o,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata_o,
    output wire [1:0] rresp_o,
    output wire rlast_o,
    output wire rvalid_o,
    input  wire rready_i,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] awid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] awaddr_i,
    input  wire [7:0] awlen_i,
    input  wire [2:0] awsize_i,
    input  wire [1:0] awburst_i,
    input  wire awvalid_i,
    output wire awready_o,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] wdata_i,
    input  wire [`OPENRV64_AXI_STRB_WIDTH-1:0] wstrb_i,
    input  wire wlast_i,
    input  wire wvalid_i,
    output wire wready_o,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] bid_o,
    output wire [1:0] bresp_o,
    output wire bvalid_o,
    input  wire bready_i
);
    localparam [63:0] RAM_BASE = `OPENRV64_SOC_MEMORY_BASE;
    localparam integer AXI_BYTES = `OPENRV64_AXI_DATA_WIDTH / 8;

    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_q [longint unsigned];

    reg read_active_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] read_id_q;
    reg [63:0] read_addr_q;
    reg [8:0] read_beats_q;
    reg [2:0] read_size_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] rid_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata_q;
    reg [1:0] rresp_q;
    reg rlast_q;
    reg rvalid_q;

    reg write_active_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] write_id_q;
    reg [63:0] write_addr_q;
    reg [8:0] write_beats_q;
    reg [2:0] write_size_q;
    reg write_error_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] bid_q;
    reg [1:0] bresp_q;
    reg bvalid_q;

    integer read_transactions;
    integer read_beats;
    integer write_transactions;
    integer write_beats;
    integer write_byte;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] merged_write;

    wire ar_fire = arvalid_i && arready_o;
    wire r_fire = rvalid_o && rready_i;
    wire aw_fire = awvalid_i && awready_o;
    wire w_fire = wvalid_i && wready_o;
    wire b_fire = bvalid_o && bready_i;

    function automatic in_range;
        input [63:0] addr;
        begin
            in_range = (addr >= RAM_BASE) &&
                       (addr < (RAM_BASE + RAM_BYTES));
        end
    endfunction

    function automatic longint unsigned word_index;
        input [63:0] addr;
        begin
            word_index = (addr - RAM_BASE) >> $clog2(AXI_BYTES);
        end
    endfunction

    function automatic [`OPENRV64_AXI_DATA_WIDTH-1:0] read_word;
        input [63:0] addr;
        longint unsigned index;
        begin
            index = word_index(addr);
            if (in_range(addr) && ram_q.exists(index))
                read_word = ram_q[index];
            else
                read_word = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
        end
    endfunction

    assign arready_o = rst_ni && !read_active_q;
    assign rid_o = rid_q;
    assign rdata_o = rdata_q;
    assign rresp_o = rresp_q;
    assign rlast_o = rlast_q;
    assign rvalid_o = rvalid_q;
    assign awready_o = rst_ni && !write_active_q && !bvalid_q;
    assign wready_o = rst_ni && write_active_q && !bvalid_q;
    assign bid_o = bid_q;
    assign bresp_o = bresp_q;
    assign bvalid_o = bvalid_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_active_q <= 1'b0;
            read_id_q <= 0;
            read_addr_q <= 0;
            read_beats_q <= 0;
            read_size_q <= 0;
            rid_q <= 0;
            rdata_q <= 0;
            rresp_q <= 2'b00;
            rlast_q <= 1'b0;
            rvalid_q <= 1'b0;
            write_active_q <= 1'b0;
            write_id_q <= 0;
            write_addr_q <= 0;
            write_beats_q <= 0;
            write_size_q <= 0;
            write_error_q <= 1'b0;
            bid_q <= 0;
            bresp_q <= 2'b00;
            bvalid_q <= 1'b0;
            read_transactions <= 0;
            read_beats <= 0;
            write_transactions <= 0;
            write_beats <= 0;
        end else begin
            if (r_fire)
                rvalid_q <= 1'b0;
            if (b_fire)
                bvalid_q <= 1'b0;

            if (ar_fire) begin
                if (arburst_i != 2'b01)
                    $fatal(1, "full-CCX SRAM requires AXI INCR reads");
                if (arsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-CCX SRAM read beat is too wide");
                read_active_q <= 1'b1;
                read_id_q <= arid_i;
                read_addr_q <= araddr_i;
                read_beats_q <= {1'b0, arlen_i} + 1'b1;
                read_size_q <= arsize_i;
                read_transactions <= read_transactions + 1;
            end

            if (read_active_q && (!rvalid_q || rready_i)) begin
                rid_q <= read_id_q;
                rdata_q <= read_word(read_addr_q);
                rresp_q <= in_range(read_addr_q) ? 2'b00 : 2'b10;
                rlast_q <= (read_beats_q == 1);
                rvalid_q <= 1'b1;
                read_beats <= read_beats + 1;
                if (read_beats_q == 1) begin
                    read_active_q <= 1'b0;
                    read_beats_q <= 0;
                end else begin
                    read_addr_q <= read_addr_q +
                        (64'd1 << read_size_q);
                    read_beats_q <= read_beats_q - 1'b1;
                end
            end

            if (aw_fire) begin
                if (awburst_i != 2'b01)
                    $fatal(1, "full-CCX SRAM requires AXI INCR writes");
                if (awsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-CCX SRAM write beat is too wide");
                write_active_q <= 1'b1;
                write_id_q <= awid_i;
                write_addr_q <= awaddr_i;
                write_beats_q <= {1'b0, awlen_i} + 1'b1;
                write_size_q <= awsize_i;
                write_error_q <= 1'b0;
                write_transactions <= write_transactions + 1;
            end

            if (w_fire) begin
                if (wlast_i != (write_beats_q == 1))
                    $fatal(1, "full-CCX SRAM observed malformed WLAST");
                merged_write = read_word(write_addr_q);
                for (write_byte = 0;
                     write_byte < `OPENRV64_AXI_STRB_WIDTH;
                     write_byte = write_byte + 1) begin
                    if (wstrb_i[write_byte])
                        merged_write[write_byte*8 +: 8] =
                            wdata_i[write_byte*8 +: 8];
                end
                if (in_range(write_addr_q))
                    ram_q[word_index(write_addr_q)] = merged_write;
                else
                    write_error_q <= 1'b1;
                write_beats <= write_beats + 1;
                if (write_beats_q == 1) begin
                    write_active_q <= 1'b0;
                    write_beats_q <= 0;
                    bid_q <= write_id_q;
                    bresp_q <= (write_error_q ||
                                !in_range(write_addr_q)) ?
                               2'b10 : 2'b00;
                    bvalid_q <= 1'b1;
                end else begin
                    write_addr_q <= write_addr_q +
                        (64'd1 << write_size_q);
                    write_beats_q <= write_beats_q - 1'b1;
                end
            end
        end
    end
endmodule

// Performance harness:
//   3P core + private L1I/L1D -> native one-hart CCX -> shared L2
//       -> 512-to-256-bit generic bus adapter -> AXI SRAM or banked DDR3.
module tb_top_3p_soc #(
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter integer FETCH_ALT_PAIR_STACK_DEPTH = 2,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_DEFAULT,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter integer ENABLE_FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer RETIRE_DEPTH = 8,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer RAM_BYTES = 16 * 1024 * 1024,
    parameter [63:0] SPEC_LOAD_BASE = `OPENRV64_SOC_MEMORY_BASE,
    parameter [63:0] SPEC_LOAD_SIZE = RAM_BYTES,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L2_TLB_ENTRIES = 256,
    parameter integer L2_TLB_WAYS = 4,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 8,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 4,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 4,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer L1D_PREFETCH_STREAMS = 2,
    parameter integer L1D_PREFETCH_DISTANCE = 1,
    parameter integer L1D_PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter integer L1D_PREFETCH_QUEUE_LINES = 4,
    parameter integer L1D_PREFETCH_OUTSTANDING = 4,
    parameter integer L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter integer DDR3_ENABLE = 0,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer MEMORY_TIMING_MODEL = 0
);
    reg clk;
    reg rst_n;

    wire core_axi_arvalid;
    wire core_axi_awvalid;
    wire core_axi_wvalid;

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire complex_ccx_req_valid;
    wire complex_ccx_req_ready;
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
    wire complex_ccx_resp_valid;
    wire complex_ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] complex_ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] complex_ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        complex_ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        complex_ccx_resp_beat_index;
    wire complex_ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        complex_ccx_resp_rdata;
    wire complex_ccx_resp_error;
    wire complex_ccx_resp_sc_success;

    // Simulation-only, initiator-keyed CCX latency bisection.  Selected
    // private-cache line reads obtain their data directly from the testbench
    // backing store; writes and narrower/uncached requests still traverse L2.
    reg [3:0] magic_ccx_source_mask_q;
    integer magic_ccx_source_mask_arg;
    reg magic_ccx_resp_valid_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        magic_ccx_resp_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        magic_ccx_resp_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        magic_ccx_resp_source_id_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        magic_ccx_resp_rdata_q;
    localparam integer MAGIC_CCX_SHADOW_DEPTH = 32;
    localparam integer MAGIC_CCX_SHADOW_INDEX_WIDTH =
        $clog2(MAGIC_CCX_SHADOW_DEPTH);
    reg magic_ccx_shadow_valid_q [0:MAGIC_CCX_SHADOW_DEPTH-1];
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        magic_ccx_shadow_hart_id_q [0:MAGIC_CCX_SHADOW_DEPTH-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        magic_ccx_shadow_txn_id_q [0:MAGIC_CCX_SHADOW_DEPTH-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        magic_ccx_shadow_source_id_q [0:MAGIC_CCX_SHADOW_DEPTH-1];
    reg magic_ccx_shadow_space_r;
    reg [MAGIC_CCX_SHADOW_INDEX_WIDTH-1:0]
        magic_ccx_shadow_free_index_r;
    reg magic_ccx_shadow_resp_match_r;
    reg [MAGIC_CCX_SHADOW_INDEX_WIDTH-1:0]
        magic_ccx_shadow_resp_index_r;
    integer magic_ccx_shadow_free_scan;
    integer magic_ccx_shadow_resp_scan;
    integer magic_ccx_shadow_reset_scan;
    integer magic_ccx_l1i_reads;
    integer magic_ccx_l1d_reads;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] magic_ccx_read_data;
    localparam integer MAGIC_CCX_RAM_WORDS = RAM_BYTES / 32;
    localparam integer MAGIC_CCX_RAM_INDEX_WIDTH =
        $clog2(MAGIC_CCX_RAM_WORDS);
    wire [63:0] magic_ccx_local_addr =
        ccx_req_addr - `OPENRV64_SOC_MEMORY_BASE;
    wire [MAGIC_CCX_RAM_INDEX_WIDTH-1:0] magic_ccx_word_index =
        magic_ccx_local_addr[
            5 +: MAGIC_CCX_RAM_INDEX_WIDTH];
    wire magic_ccx_ram_line =
        (ccx_req_addr >= `OPENRV64_SOC_MEMORY_BASE) &&
        (ccx_req_addr <=
         (`OPENRV64_SOC_MEMORY_BASE + RAM_BYTES - 64)) &&
        (ccx_req_addr[5:0] == 6'd0);
    wire magic_ccx_source_selected =
        magic_ccx_source_mask_q[ccx_req_source_id];
    wire magic_ccx_req_select =
        magic_ccx_source_selected &&
        (ccx_req_op == `OPENRV64_CCX_OP_READ) &&
        (ccx_req_size == 3'd6) &&
        (ccx_req_burst_len == 0) &&
        |(ccx_req_attr & `OPENRV64_CCX_ATTR_CACHEABLE) &&
        magic_ccx_ram_line;
    wire magic_ccx_resp_fire =
        magic_ccx_resp_valid_q && ccx_resp_ready;
    wire magic_ccx_resp_slot_ready =
        !magic_ccx_resp_valid_q || magic_ccx_resp_fire;
    wire magic_ccx_req_fire =
        ccx_req_valid && ccx_req_ready && magic_ccx_req_select;
    wire magic_ccx_shadow_resp_fire =
        complex_ccx_resp_valid && complex_ccx_resp_ready &&
        magic_ccx_shadow_resp_match_r;

    // Selected requests are still accepted by L2.  Their eventual tagged L2
    // responses are consumed below after L2 has performed its normal fill.
    assign ccx_req_ready = complex_ccx_req_ready &&
        (!magic_ccx_req_select ||
         (magic_ccx_resp_slot_ready && magic_ccx_shadow_space_r));
    assign complex_ccx_req_valid =
        ccx_req_valid &&
        (!magic_ccx_req_select ||
         (magic_ccx_resp_slot_ready && magic_ccx_shadow_space_r));

    assign ccx_resp_valid =
        magic_ccx_resp_valid_q ||
        (complex_ccx_resp_valid && !magic_ccx_shadow_resp_match_r);
    assign ccx_resp_hart_id = magic_ccx_resp_valid_q ?
        magic_ccx_resp_hart_id_q : complex_ccx_resp_hart_id;
    assign ccx_resp_txn_id = magic_ccx_resp_valid_q ?
        magic_ccx_resp_txn_id_q : complex_ccx_resp_txn_id;
    assign ccx_resp_source_id = magic_ccx_resp_valid_q ?
        magic_ccx_resp_source_id_q : complex_ccx_resp_source_id;
    assign ccx_resp_beat_index = magic_ccx_resp_valid_q ?
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}} :
        complex_ccx_resp_beat_index;
    assign ccx_resp_last = magic_ccx_resp_valid_q ?
        1'b1 : complex_ccx_resp_last;
    assign ccx_resp_rdata = magic_ccx_resp_valid_q ?
        magic_ccx_resp_rdata_q : complex_ccx_resp_rdata;
    assign ccx_resp_error = magic_ccx_resp_valid_q ?
        1'b0 : complex_ccx_resp_error;
    assign ccx_resp_sc_success = magic_ccx_resp_valid_q ?
        1'b0 : complex_ccx_resp_sc_success;
    assign complex_ccx_resp_ready =
        magic_ccx_shadow_resp_match_r ||
        (ccx_resp_ready && !magic_ccx_resp_valid_q);

    always @* begin
        magic_ccx_shadow_space_r = 1'b0;
        magic_ccx_shadow_free_index_r =
            {MAGIC_CCX_SHADOW_INDEX_WIDTH{1'b0}};
        for (magic_ccx_shadow_free_scan = 0;
             magic_ccx_shadow_free_scan < MAGIC_CCX_SHADOW_DEPTH;
             magic_ccx_shadow_free_scan = magic_ccx_shadow_free_scan + 1)
            if (!magic_ccx_shadow_space_r &&
                !magic_ccx_shadow_valid_q[magic_ccx_shadow_free_scan]) begin
                magic_ccx_shadow_space_r = 1'b1;
                magic_ccx_shadow_free_index_r =
                    magic_ccx_shadow_free_scan[
                        MAGIC_CCX_SHADOW_INDEX_WIDTH-1:0];
            end
    end

    always @* begin
        magic_ccx_shadow_resp_match_r = 1'b0;
        magic_ccx_shadow_resp_index_r =
            {MAGIC_CCX_SHADOW_INDEX_WIDTH{1'b0}};
        for (magic_ccx_shadow_resp_scan = 0;
             magic_ccx_shadow_resp_scan < MAGIC_CCX_SHADOW_DEPTH;
             magic_ccx_shadow_resp_scan = magic_ccx_shadow_resp_scan + 1)
            if (!magic_ccx_shadow_resp_match_r &&
                magic_ccx_shadow_valid_q[magic_ccx_shadow_resp_scan] &&
                (magic_ccx_shadow_hart_id_q[magic_ccx_shadow_resp_scan] ==
                 complex_ccx_resp_hart_id) &&
                (magic_ccx_shadow_txn_id_q[magic_ccx_shadow_resp_scan] ==
                 complex_ccx_resp_txn_id) &&
                (magic_ccx_shadow_source_id_q[magic_ccx_shadow_resp_scan] ==
                 complex_ccx_resp_source_id)) begin
                magic_ccx_shadow_resp_match_r = 1'b1;
                magic_ccx_shadow_resp_index_r =
                    magic_ccx_shadow_resp_scan[
                        MAGIC_CCX_SHADOW_INDEX_WIDTH-1:0];
            end
    end

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] ram_araddr;
    wire [7:0] ram_arlen;
    wire [2:0] ram_arsize;
    wire [1:0] ram_arburst;
    wire ram_arlock;
    wire [3:0] ram_arcache;
    wire [2:0] ram_arprot;
    wire [3:0] ram_arqos;
    wire ram_arvalid;
    wire ram_arready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_rid;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_rdata;
    wire [1:0] ram_rresp;
    wire ram_rlast;
    wire ram_rvalid;
    wire ram_rready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] ram_awaddr;
    wire [7:0] ram_awlen;
    wire [2:0] ram_awsize;
    wire [1:0] ram_awburst;
    wire ram_awlock;
    wire [3:0] ram_awcache;
    wire [2:0] ram_awprot;
    wire [3:0] ram_awqos;
    wire ram_awvalid;
    wire ram_awready;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] ram_wstrb;
    wire ram_wlast;
    wire ram_wvalid;
    wire ram_wready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_bid;
    wire [1:0] ram_bresp;
    wire ram_bvalid;
    wire ram_bready;

    wire [63:0] memory_read_bursts;
    wire [63:0] memory_write_bursts;
    wire [63:0] memory_read_beats_requested;
    wire [63:0] memory_write_beats_requested;
    wire [63:0] memory_read_beats_returned;
    wire [63:0] memory_write_beats_received;
    wire [63:0] memory_read_address_wait;
    wire [63:0] memory_write_address_wait;
    wire [63:0] memory_write_data_wait;
    wire [63:0] memory_read_response_wait;
    wire [63:0] memory_write_response_wait;
    wire [63:0] memory_timing_backend_wait;
    wire [63:0] memory_timing_owner_full;
    wire [63:0] memory_read_timing_wait;
    wire [63:0] memory_write_timing_wait;
    wire [63:0] memory_timing_read_commands;
    wire [63:0] memory_timing_write_commands;
    wire [63:0] memory_max_read_queue;
    wire [63:0] memory_max_write_queue;
    wire [63:0] memory_max_timing_owners;
    wire [63:0] memory_ddr_commands_coalesced;
    wire [63:0] memory_ddr_reads_coalesced;
    wire [63:0] memory_ddr_writes_coalesced;
    wire [63:0] memory_ddr_coalesced_groups;

    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;

    integer cycles;
    integer max_cycles;
    integer retired;
    integer ccx_requests;
    integer ccx_fetch_reads;
    integer ccx_data_reads;
    integer ccx_data_writes;
    integer ccx_ptw_reads;
    integer dtlb_fast_loads;
    integer dtlb_fast_stores;
    reg require_sv39;
    reg saw_sv39;
    reg saw_supervisor;
    reg saw_sv39_alias_fetch;
    reg saw_sv39_alias_data;
    integer axi_read_transactions;
    integer axi_read_beats;
    integer axi_write_transactions;
    integer axi_write_beats;
    integer max_l2_mshrs;
    integer ddr3_commands;
    integer max_ddr3_queued;
    integer max_timing_owners;
    integer direction_corrections;
    integer target_corrections;
    integer bp_btb_lookups;
    integer bp_btb_hits;
    integer bp_btb_misses;
    integer bp_btb_wrong_targets;
    integer bp_ras_lookups;
    integer bp_ras_hits;
    integer bp_ras_misses;
    integer bp_ras_wrong_targets;
    integer lookaside_restart_hits;
    integer lookaside_eligible_restarts;
    integer lookaside_pair_replacements;
    integer lookaside_pair_stack_overflows;
    integer lookaside_pair_stack_max_saved;
    integer lookaside_store_fills;
    integer lookaside_store_duplicate_fills;
    integer lookaside_store_free_fills;
    integer lookaside_store_evictions;
    integer lookaside_full_branch_allocations;
    integer lookaside_sector_allocations;
    integer lookaside_sector_predicted_free;
    integer lookaside_sector_unpredicted_free;
    integer lookaside_sector_response_taps;
    integer lookaside_sector_predicted_taps;
    integer lookaside_sector_unpredicted_taps;
    integer lookaside_sector_background_requests;
    integer lookaside_sector_background_deferred;
    integer l1d_prefetch_issued;
    integer l1d_prefetch_useful;
    integer l1d_prefetch_late;
    integer l1d_prefetch_dropped;
    integer l1d_prefetch_useless;
    integer l1d_prefetch_max_depth;
    integer issued;
    integer decoded;
    integer issued_this_cycle;
    integer decoded_this_cycle;
    integer issue_width_0;
    integer issue_width_1;
    integer issue_width_2;
    integer issue_width_3;
    integer issue_width_4;
    integer decode_width_0;
    integer decode_width_1;
    integer decode_width_2;
    integer decode_width_3;
    integer retire_width_0;
    integer retire_width_1;
    integer retire_width_2;
    integer retire_width_3;
    integer dispatch_nonempty;
    integer dispatch_nonempty_no_issue;
    integer dispatch_full;
    integer raw_hazard_cycles;
    integer raw_first_block_cycles;
    integer raw_first_pending_cycles;
    integer raw_first_bundle_cycles;
    integer raw_first_completed_cycles;
    integer raw_secondary_only_cycles;
    integer raw_first_rs1_cycles;
    integer raw_first_rs2_cycles;
    integer raw_first_both_sources_cycles;
    integer raw_first_lane0_cycles;
    integer raw_first_lane1_cycles;
    integer raw_first_lane2_cycles;
    integer raw_first_blocked_alu;
    integer raw_first_blocked_branch;
    integer raw_first_blocked_jump;
    integer raw_first_blocked_load;
    integer raw_first_blocked_store;
    integer window_nonempty_cycles;
    integer window_no_eligible_cycles;
    integer window_raw_stall_cycles;
    integer window_hard_stall_cycles;
    integer window_mem_order_stall_cycles;
    integer window_unissued_entry_cycles;
    integer window_operand_ready_entry_cycles;
    integer window_eligible_entry_cycles;
    integer window_raw_block_entry_cycles;
    integer window_hard_block_entry_cycles;
    integer window_mem_order_block_entry_cycles;
    integer waw_hazard_cycles;
    integer read_port_hazard_cycles;
    integer write_busy_cycles;
    integer barrier_cycles;
    integer retire_nonempty;
    integer retire_nonempty_no_retire;
    integer retire_head_incomplete;
    integer retire_completed_behind_head;
    integer frontend_empty;
    integer frontend_held;
    integer frontend_request_wait;
    integer frontend_control_empty;
    integer frontend_refill_wait;
    integer frontend_no_line;
    integer frontend_bp_stall;
    integer frontend_other_empty;
    integer frontend_empty_backend_ready;
    integer frontend_empty_dispatch_empty;
    integer frontend_empty_dispatch_empty_backend_ready;
    integer frontend_empty_dispatch_empty_retire_empty;
    integer frontend_empty_dispatch_nonempty;
    integer frontend_empty_dispatch_full;
    integer frontend_empty_l1i_external_miss;
    integer frontend_empty_pending_no_external_miss;
    integer fetch_demand_trace_enabled;
    integer fetch_demand_trace_cycle_q;
    integer fetch_demand_trace_start_q;
    integer fetch_demand_trace_external_q;
    integer fetch_demand_trace_empty_q;
    reg fetch_demand_trace_active_q;
    reg [63:0] fetch_demand_trace_addr_q;
    reg [63:0] fetch_demand_trace_pc_q;
    integer stash_trace_episodes;
    integer stash_trace_completed;
    integer stash_trace_interrupted;
    integer stash_trace_requested;
    integer stash_trace_stalled;
    integer stash_trace_completed_stalled;
    integer stash_trace_interrupted_stalled;
    integer stash_trace_exposed_stall_cycles;
    integer stash_trace_completed_stall_cycles;
    integer stash_trace_interrupted_stall_cycles;
    integer stash_trace_same_line_stall_cycles;
    integer stash_trace_next_line_stall_cycles;
    integer stash_trace_preview_instructions;
    integer stash_trace_request_delay_sum;
    integer stash_trace_request_delay_max;
    integer stash_trace_response_delay_sum;
    integer stash_trace_response_delay_max;
    integer stash_trace_refill_latency_sum;
    integer stash_trace_refill_latency_max;
    integer stash_trace_printed;
    integer stash_trace_offset_hits [0:3];
    integer stash_trace_offset_stalled [0:3];
    integer stash_trace_offset_stall_cycles [0:3];
    integer stash_trace_sector_hits [0:1];
    integer stash_trace_sector_stalled [0:1];
    integer stash_trace_sector_stall_cycles [0:1];
    reg stash_trace_active;
    reg stash_trace_request_seen;
    reg [63:0] stash_trace_pc;
    reg [63:0] stash_trace_line;
    integer stash_trace_sector;
    integer stash_trace_offset;
    integer stash_trace_start_cycle;
    integer stash_trace_request_cycle;
    integer stash_trace_episode_stall_cycles;
    integer stash_trace_episode_same_line_stalls;
    integer stash_trace_episode_next_line_stalls;
    integer stash_trace_episode_preview_instructions;
    integer stash_trace_cycle;
    integer stash_trace_reset_index;
    integer stash_trace_delay;
    integer lsu_request_wait;
    integer lsu_load_request_wait;
    integer lsu_store_request_wait;
    integer lsu_second_port_opportunities;
    integer l1d_request_wait;
    integer l1d_load_request_wait;
    integer l1d_store_request_wait;
    integer l1d_wait_store_block;
    integer l1d_dirty_snoop_accepts;
    integer l1d_wait_lock_barrier;
    integer l1d_wait_response_tags;
    integer l1d_wait_refill;
    integer l1d_wait_access;
    integer l1d_wait_run_response;
    integer l1d_wait_unknown;
    integer ccx_request_wait;
    integer ccx_read_request_wait;
    integer ccx_write_request_wait;
    integer l2_bus_request_wait;
    integer l2_command_full_cycles;
    integer axi_read_address_wait;
    integer axi_write_address_wait;
    integer axi_write_data_wait;
    integer lsu_outstanding_cycles;
    integer branch_resolutions;
    integer conditional_branch_resolutions;
    integer pipe_conflicts;
    integer pipe_conflicts_ex0;
    integer pipe_conflicts_ex1;
    integer pipe_conflicts_mem;
    integer conflict_blocked_alu;
    integer conflict_blocked_branch;
    integer conflict_blocked_jump;
    integer conflict_blocked_load;
    integer conflict_blocked_store;
    integer conflict_pair_branch_alu;
    integer conflict_pair_alu_branch;
    integer conflict_pair_branch_branch;
    integer conflict_pair_alu_alu;
    integer conflict_pair_load_load;
    integer conflict_pair_store_load;
    integer conflict_pair_store_store;
    integer conflict_pair_other;
    integer memh_words;
    string memh_path;
    reg [63:0] expected_a0;
    reg expected_a0_valid;
    reg [63:0] done_pc;
    reg done_pc_valid;
    real ipc;

    localparam integer RETIRE_RESULT_PC_LSB = 329;
    localparam integer PERF_OP_ALU = 0;
    localparam integer PERF_OP_BRANCH = 1;
    localparam integer PERF_OP_JUMP = 2;
    localparam integer PERF_OP_LOAD = 3;
    localparam integer PERF_OP_STORE = 4;

    function automatic [2:0] perf_op_class;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            if (payload[14])
                perf_op_class = PERF_OP_BRANCH;
            else if (payload[13])
                perf_op_class = PERF_OP_JUMP;
            else if (payload[16] && !payload[15])
                perf_op_class = PERF_OP_LOAD;
            else if (payload[15])
                perf_op_class = PERF_OP_STORE;
            else
                perf_op_class = PERF_OP_ALU;
        end
    endfunction

    wire done_pc_retired =
        (dut.backend_retire_arch[0] &&
         (dut.u_backend.queue_retire_result[
              0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
              RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
        (dut.backend_retire_arch[1] &&
         (dut.u_backend.queue_retire_result[
              1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
              RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
        (dut.backend_retire_arch[2] &&
         (dut.u_backend.queue_retire_result[
              2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
              RETIRE_RESULT_PC_LSB +: 64] == done_pc));
    wire run_done = dbg_halted || (done_pc_valid && done_pc_retired);

    wire [2:0] trace_candidate_valid =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_valid;
    wire [2:0] trace_candidate_fire =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_fire;
    wire [2:0] trace_candidate_hazard_free =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_hazard_free;
    wire [2:0] trace_candidate_free =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_free;
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_candidate_pipe =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_pipe;
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_candidate_payload =
            dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_payload;
    wire [2:0] trace_candidate_uses_rs1 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs1;
    wire [2:0] trace_candidate_uses_rs2 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs1 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs2 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs2_addr;
    wire [2:0] trace_raw_bundle = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle2,
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle1,
        1'b0
    };
    wire [2:0] trace_raw_rs1 = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs12 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        2*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs12) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]] ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs11 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        1*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs11) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs10 &&
            dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        0*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs10
    };
    wire [2:0] trace_raw_rs2 = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs22 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        2*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs22) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]] ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs21 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        1*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs21) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs20 &&
            dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        0*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs20
    };
    wire [31:0] trace_youngest_ready =
        dut.u_backend.youngest_forward_valid_raw;
    wire [2:0] trace_raw_completed = {
        dut.u_backend.raw_hazard[2] && !trace_raw_bundle[2] &&
            (!trace_raw_rs1[2] || trace_youngest_ready[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[2] || trace_youngest_ready[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.raw_hazard[1] && !trace_raw_bundle[1] &&
            (!trace_raw_rs1[1] || trace_youngest_ready[
                trace_candidate_rs1[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[1] || trace_youngest_ready[
                trace_candidate_rs2[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.raw_hazard[0] &&
            (!trace_raw_rs1[0] || trace_youngest_ready[
                trace_candidate_rs1[
                    0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[0] || trace_youngest_ready[
                trace_candidate_rs2[
                    0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]])
    };
    wire raw_first_lane0 = trace_candidate_valid[0] &&
                           !trace_candidate_fire[0];
    wire raw_first_lane1 = !raw_first_lane0 &&
                           trace_candidate_valid[1] &&
                           trace_candidate_fire[0] &&
                           !trace_candidate_fire[1];
    wire raw_first_lane2 = !raw_first_lane0 && !raw_first_lane1 &&
                           trace_candidate_valid[2] &&
                           trace_candidate_fire[1] &&
                           !trace_candidate_fire[2];
    wire [2:0] raw_first_lane =
        {raw_first_lane2, raw_first_lane1, raw_first_lane0};
    wire raw_first_block = |(raw_first_lane & dut.u_backend.raw_hazard);
    wire raw_first_bundle = |(raw_first_lane & trace_raw_bundle);
    wire raw_first_completed = |(raw_first_lane & trace_raw_completed);
    wire raw_first_rs1 = |(raw_first_lane & trace_raw_rs1);
    wire raw_first_rs2 = |(raw_first_lane & trace_raw_rs2);
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        raw_first_payload = raw_first_lane0 ?
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            raw_first_lane1 ?
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [2:0] raw_first_op = perf_op_class(raw_first_payload);
    wire [4:0] trace_window_unissued = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_unissued_count :
        5'd0;
    wire [4:0] trace_window_operand_ready = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_operand_ready_count :
        5'd0;
    wire [4:0] trace_window_eligible = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_eligible_count :
        5'd0;
    wire [4:0] trace_window_raw_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_raw_block_count :
        5'd0;
    wire [4:0] trace_window_hard_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_hard_block_count :
        5'd0;
    wire [4:0] trace_window_mem_order_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_mem_order_block_count :
        5'd0;
    wire [2:0] trace_barrier_allow =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_control.barrier_allow;
    wire trace_allocation_ready = dut.u_backend.allocation_ready;
    wire trace_conflict1 =
        trace_candidate_valid[1] && trace_candidate_fire[0] &&
        !trace_candidate_fire[1] && trace_candidate_hazard_free[1] &&
        trace_barrier_allow[1] && trace_allocation_ready &&
        !trace_candidate_free[0] &&
        (trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                              `OPENRV64_EXEC_PIPE_WIDTH] ==
         trace_candidate_pipe[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                              `OPENRV64_EXEC_PIPE_WIDTH]);
    wire trace_conflict2 =
        trace_candidate_valid[2] && trace_candidate_fire[1] &&
        !trace_candidate_fire[2] && trace_candidate_hazard_free[2] &&
        trace_barrier_allow[2] && trace_allocation_ready &&
        !trace_candidate_free[1] &&
        ((trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH] ==
          trace_candidate_pipe[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH]) ||
         (trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH] ==
          trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH]));
    wire trace_pipe_conflict = trace_conflict1 || trace_conflict2;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_conflict_pipe =
        trace_conflict1 ?
            trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                                 `OPENRV64_EXEC_PIPE_WIDTH] :
            trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                                 `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_conflict_blocked_payload = trace_conflict1 ?
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_conflict_older_payload = trace_conflict1 ?
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            ((trace_candidate_pipe[
                  2*`OPENRV64_EXEC_PIPE_WIDTH +:
                  `OPENRV64_EXEC_PIPE_WIDTH] ==
              trace_candidate_pipe[
                  1*`OPENRV64_EXEC_PIPE_WIDTH +:
                  `OPENRV64_EXEC_PIPE_WIDTH]) ?
                trace_candidate_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
                trace_candidate_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire [2:0] trace_conflict_blocked_op =
        perf_op_class(trace_conflict_blocked_payload);
    wire [2:0] trace_conflict_older_op =
        perf_op_class(trace_conflict_older_payload);

    wire [`OPENRV64_LSU_OUTSTANDING-1:0] trace_lsu_sent;
    genvar trace_lsu_index;
    generate
        for (trace_lsu_index = 0;
             trace_lsu_index < `OPENRV64_LSU_OUTSTANDING;
             trace_lsu_index = trace_lsu_index + 1) begin : g_trace_lsu
            if (trace_lsu_index < 4) begin : g_mem0
                assign trace_lsu_sent[trace_lsu_index] =
                    dut.u_backend.u_exec.g_3p.u_exec.u_mem0.slot_sent_q[
                        trace_lsu_index];
            end else begin : g_mem1
                assign trace_lsu_sent[trace_lsu_index] =
                    dut.u_backend.u_exec.g_3p.u_exec.u_mem1.slot_sent_q[
                        trace_lsu_index - 4];
            end
        end
    endgenerate

    openrv64_rv64_top_3p #(
        .RESET_VECTOR(`OPENRV64_SOC_MEMORY_BASE),
        .BUS_CONFIG(`OPENRV64_BUS_AXI),
        .ENABLE_RV64M(1'b1),
        .COMPLETION_FORWARD_MASK(COMPLETION_FORWARD_MASK),
        .BRANCH_COMPLETION_FORWARD_MASK(
            BRANCH_COMPLETION_FORWARD_MASK),
        .ENABLE_FULL_FORWARDING(ENABLE_FULL_FORWARDING),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .SPEC_LOAD_BASE(SPEC_LOAD_BASE),
        .SPEC_LOAD_SIZE(SPEC_LOAD_SIZE),
        .ENABLE_L1I(1'b1),
        .ENABLE_L1D(1'b1),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
        .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
        .L2_TLB_WAYS(L2_TLB_WAYS),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .L1D_PREFETCH_STREAMS(L1D_PREFETCH_STREAMS),
        .L1D_PREFETCH_DISTANCE(L1D_PREFETCH_DISTANCE),
        .L1D_PREFETCH_ADAPTIVE_ENABLE(
            L1D_PREFETCH_ADAPTIVE_ENABLE),
        .L1D_PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .L1D_PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .L1D_PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .L1D_PREFETCH_DEMAND_RESERVE(
            L1D_PREFETCH_DEMAND_RESERVE),
        .ENABLE_MAGIC_MEMORY(1'b0),
        .ENABLE_TRACE(1'b0),
        .ENABLE_FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
        .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
            FETCH_ALT_CONFIDENCE_GATE),
        .FETCH_ALT_PAIR_STACK_DEPTH(FETCH_ALT_PAIR_STACK_DEPTH),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(1'b1),
        .BP_RAS_DEPTH(8),
        .BP_BIMODAL_ENTRIES(32),
        .BP_BIMODAL_COUNTER_BITS(3),
        .BP_BIMODAL_UPDATE_DEPTH(4),
        .BP_GSHARE_ENTRIES(256),
        .BP_GSHARE_COUNTER_BITS(3),
        .BP_BTB_ENTRIES(256),
        .BP_BTB_TAG_BITS(16),
        .BP_INFLIGHT_DEPTH(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_ready(1'b0),
        .mem_rdata(64'd0),
        .mem_error(1'b0),
        .pair512_req_valid(),
        .pair512_req_ready(1'b0),
        .pair512_req_predicted_addr(),
        .pair512_req_unpredicted_addr(),
        .pair512_resp_valid(1'b0),
        .pair512_resp_predicted_addr(64'd0),
        .pair512_resp_predicted_data(
            {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair512_resp_unpredicted_addr(64'd0),
        .pair512_resp_unpredicted_data(
            {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair1024_req_valid(),
        .pair1024_req_ready(1'b0),
        .pair1024_req_predicted_addr(),
        .pair1024_req_unpredicted_addr(),
        .pair1024_resp_valid(1'b0),
        .pair1024_resp_predicted_addr(64'd0),
        .pair1024_resp_predicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .pair1024_resp_unpredicted_addr(64'd0),
        .pair1024_resp_unpredicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .m_axi_arvalid(core_axi_arvalid),
        .m_axi_arready(1'b0),
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b1),
        .m_axi_rvalid(1'b0),
        .m_axi_awvalid(core_axi_awvalid),
        .m_axi_awready(1'b0),
        .m_axi_wvalid(core_axi_wvalid),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .ccx_req_valid(ccx_req_valid),
        .ccx_req_ready(ccx_req_ready),
        .ccx_req_hart_id(ccx_req_hart_id),
        .ccx_req_txn_id(ccx_req_txn_id),
        .ccx_req_source_id(ccx_req_source_id),
        .ccx_req_op(ccx_req_op),
        .ccx_req_lock(ccx_req_lock),
        .ccx_req_order(ccx_req_order),
        .ccx_req_kind(ccx_req_kind),
        .ccx_req_attr(ccx_req_attr),
        .ccx_req_size(ccx_req_size),
        .ccx_req_addr(ccx_req_addr),
        .ccx_req_burst_len(ccx_req_burst_len),
        .ccx_wdata_valid(ccx_wdata_valid),
        .ccx_wdata_ready(ccx_wdata_ready),
        .ccx_wdata_hart_id(ccx_wdata_hart_id),
        .ccx_wdata_txn_id(ccx_wdata_txn_id),
        .ccx_wdata_source_id(ccx_wdata_source_id),
        .ccx_wdata_beat_index(ccx_wdata_beat_index),
        .ccx_wdata_last(ccx_wdata_last),
        .ccx_wdata(ccx_wdata),
        .ccx_wstrb(ccx_wstrb),
        .ccx_resp_valid(ccx_resp_valid),
        .ccx_resp_ready(ccx_resp_ready),
        .ccx_resp_hart_id(ccx_resp_hart_id),
        .ccx_resp_txn_id(ccx_resp_txn_id),
        .ccx_resp_source_id(ccx_resp_source_id),
        .ccx_resp_beat_index(ccx_resp_beat_index),
        .ccx_resp_last(ccx_resp_last),
        .ccx_resp_rdata(ccx_resp_rdata),
        .ccx_resp_error(ccx_resp_error),
        .ccx_resp_sc_success(ccx_resp_sc_success),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    openrv64_core_complex_nh #(
        .NUM_HARTS(1),
        .HART_ID_BASE(0),
        .L2_BYTES(L2_BYTES),
        .L2_LINE_BYTES(64),
        .L2_WAYS(L2_WAYS),
        .L2_MERGE_ENTRIES(L2_MERGE_ENTRIES),
        .L2_WAITERS_PER_MSHR(8),
        .L2_COMMAND_ENTRIES(16),
        .L2_RESPONSE_ENTRIES(16),
        .L2_BUS_DATA_WIDTH(512),
        .BUS_TYPE(`OPENRV64_COMPLEX_BUS_AXI),
        .BUS_ADDR_WIDTH(`OPENRV64_AXI_ADDR_WIDTH),
        .BUS_DATA_WIDTH(`OPENRV64_AXI_DATA_WIDTH),
        .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .AXI_ID_WIDTH(`OPENRV64_AXI_ID_WIDTH),
        .AXI_ID({`OPENRV64_AXI_ID_WIDTH{1'b1}})
    ) u_complex (
        .clk_i(clk),
        .rst_ni(rst_n),
        .ccx_req_valid_i(complex_ccx_req_valid),
        .ccx_req_ready_o(complex_ccx_req_ready),
        .ccx_req_hart_id_i(ccx_req_hart_id),
        .ccx_req_txn_id_i(ccx_req_txn_id),
        .ccx_req_source_id_i(ccx_req_source_id),
        .ccx_req_op_i(ccx_req_op),
        .ccx_req_lock_i(ccx_req_lock),
        .ccx_req_order_i(ccx_req_order),
        .ccx_req_kind_i(ccx_req_kind),
        .ccx_req_attr_i(ccx_req_attr),
        .ccx_req_size_i(ccx_req_size),
        .ccx_req_addr_i(ccx_req_addr),
        .ccx_req_burst_len_i(ccx_req_burst_len),
        .ccx_wdata_valid_i(ccx_wdata_valid),
        .ccx_wdata_ready_o(ccx_wdata_ready),
        .ccx_wdata_hart_id_i(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_i(ccx_wdata_txn_id),
        .ccx_wdata_source_id_i(ccx_wdata_source_id),
        .ccx_wdata_beat_index_i(ccx_wdata_beat_index),
        .ccx_wdata_last_i(ccx_wdata_last),
        .ccx_wdata_i(ccx_wdata),
        .ccx_wstrb_i(ccx_wstrb),
        .ccx_resp_valid_o(complex_ccx_resp_valid),
        .ccx_resp_ready_i(complex_ccx_resp_ready),
        .ccx_resp_hart_id_o(complex_ccx_resp_hart_id),
        .ccx_resp_txn_id_o(complex_ccx_resp_txn_id),
        .ccx_resp_source_id_o(complex_ccx_resp_source_id),
        .ccx_resp_beat_index_o(complex_ccx_resp_beat_index),
        .ccx_resp_last_o(complex_ccx_resp_last),
        .ccx_resp_rdata_o(complex_ccx_resp_rdata),
        .ccx_resp_error_o(complex_ccx_resp_error),
        .ccx_resp_sc_success_o(complex_ccx_resp_sc_success),
        .m_axi_arid_o(ram_arid),
        .m_axi_araddr_o(ram_araddr),
        .m_axi_arlen_o(ram_arlen),
        .m_axi_arsize_o(ram_arsize),
        .m_axi_arburst_o(ram_arburst),
        .m_axi_arlock_o(ram_arlock),
        .m_axi_arcache_o(ram_arcache),
        .m_axi_arprot_o(ram_arprot),
        .m_axi_arqos_o(ram_arqos),
        .m_axi_arvalid_o(ram_arvalid),
        .m_axi_arready_i(ram_arready),
        .m_axi_rid_i(ram_rid),
        .m_axi_rdata_i(ram_rdata),
        .m_axi_rresp_i(ram_rresp),
        .m_axi_rlast_i(ram_rlast),
        .m_axi_rvalid_i(ram_rvalid),
        .m_axi_rready_o(ram_rready),
        .m_axi_awid_o(ram_awid),
        .m_axi_awaddr_o(ram_awaddr),
        .m_axi_awlen_o(ram_awlen),
        .m_axi_awsize_o(ram_awsize),
        .m_axi_awburst_o(ram_awburst),
        .m_axi_awlock_o(ram_awlock),
        .m_axi_awcache_o(ram_awcache),
        .m_axi_awprot_o(ram_awprot),
        .m_axi_awqos_o(ram_awqos),
        .m_axi_awvalid_o(ram_awvalid),
        .m_axi_awready_i(ram_awready),
        .m_axi_wdata_o(ram_wdata),
        .m_axi_wstrb_o(ram_wstrb),
        .m_axi_wlast_o(ram_wlast),
        .m_axi_wvalid_o(ram_wvalid),
        .m_axi_wready_i(ram_wready),
        .m_axi_bid_i(ram_bid),
        .m_axi_bresp_i(ram_bresp),
        .m_axi_bvalid_i(ram_bvalid),
        .m_axi_bready_o(ram_bready),
        .wb_stall_i(1'b0),
        .wb_ack_i(1'b0),
        .wb_err_i(1'b0),
        .wb_rty_i(1'b0),
        .wb_dat_i({`OPENRV64_AXI_DATA_WIDTH{1'b0}})
    );

    generate
        if (DDR3_ENABLE != 0) begin : g_ddr3
            openrv64_axi_ddr3 #(
                .ADDR_WIDTH(`OPENRV64_AXI_ADDR_WIDTH),
                .DATA_WIDTH(`OPENRV64_AXI_DATA_WIDTH),
                .ID_WIDTH(`OPENRV64_AXI_ID_WIDTH),
                .MEM_BASE(`OPENRV64_SOC_MEMORY_BASE),
                .MEM_BYTES(RAM_BYTES),
                .READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
                .WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
                .ZERO_INIT_WORDS(0),
                .COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
                .TIMING_MODEL(MEMORY_TIMING_MODEL)
            ) u_ddr3 (
                .clk_i(clk),
                .rst_ni(rst_n),
                .s_axi_arid_i(ram_arid),
                .s_axi_araddr_i(ram_araddr),
                .s_axi_arlen_i(ram_arlen),
                .s_axi_arsize_i(ram_arsize),
                .s_axi_arburst_i(ram_arburst),
                .s_axi_arlock_i(ram_arlock),
                .s_axi_arcache_i(ram_arcache),
                .s_axi_arprot_i(ram_arprot),
                .s_axi_arqos_i(ram_arqos),
                .s_axi_arvalid_i(ram_arvalid),
                .s_axi_arready_o(ram_arready),
                .s_axi_rid_o(ram_rid),
                .s_axi_rdata_o(ram_rdata),
                .s_axi_rresp_o(ram_rresp),
                .s_axi_rlast_o(ram_rlast),
                .s_axi_rvalid_o(ram_rvalid),
                .s_axi_rready_i(ram_rready),
                .s_axi_awid_i(ram_awid),
                .s_axi_awaddr_i(ram_awaddr),
                .s_axi_awlen_i(ram_awlen),
                .s_axi_awsize_i(ram_awsize),
                .s_axi_awburst_i(ram_awburst),
                .s_axi_awlock_i(ram_awlock),
                .s_axi_awcache_i(ram_awcache),
                .s_axi_awprot_i(ram_awprot),
                .s_axi_awqos_i(ram_awqos),
                .s_axi_awvalid_i(ram_awvalid),
                .s_axi_awready_o(ram_awready),
                .s_axi_wdata_i(ram_wdata),
                .s_axi_wstrb_i(ram_wstrb),
                .s_axi_wlast_i(ram_wlast),
                .s_axi_wvalid_i(ram_wvalid),
                .s_axi_wready_o(ram_wready),
                .s_axi_bid_o(ram_bid),
                .s_axi_bresp_o(ram_bresp),
                .s_axi_bvalid_o(ram_bvalid),
                .s_axi_bready_i(ram_bready)
            );

            assign magic_ccx_read_data = {
                u_ddr3.u_channel.memory_q[
                    magic_ccx_word_index + 1'b1],
                u_ddr3.u_channel.memory_q[magic_ccx_word_index]
            };

            assign memory_read_bursts =
                u_ddr3.u_channel.perf_read_bursts_q;
            assign memory_write_bursts =
                u_ddr3.u_channel.perf_write_bursts_q;
            assign memory_read_beats_requested =
                u_ddr3.u_channel.perf_read_beats_requested_q;
            assign memory_write_beats_requested =
                u_ddr3.u_channel.perf_write_beats_requested_q;
            assign memory_read_beats_returned =
                u_ddr3.u_channel.perf_read_beats_returned_q;
            assign memory_write_beats_received =
                u_ddr3.u_channel.perf_write_beats_received_q;
            assign memory_read_address_wait =
                u_ddr3.u_channel.perf_read_address_wait_cycles_q;
            assign memory_write_address_wait =
                u_ddr3.u_channel.perf_write_address_wait_cycles_q;
            assign memory_write_data_wait =
                u_ddr3.u_channel.perf_write_data_wait_cycles_q;
            assign memory_read_response_wait =
                u_ddr3.u_channel.perf_read_response_wait_cycles_q;
            assign memory_write_response_wait =
                u_ddr3.u_channel.perf_write_response_wait_cycles_q;
            assign memory_timing_backend_wait =
                u_ddr3.u_channel.perf_timing_backend_wait_cycles_q;
            assign memory_timing_owner_full =
                u_ddr3.u_channel.perf_timing_owner_full_cycles_q;
            assign memory_read_timing_wait =
                u_ddr3.u_channel.perf_read_timing_wait_cycles_q;
            assign memory_write_timing_wait =
                u_ddr3.u_channel.perf_write_timing_wait_cycles_q;
            assign memory_timing_read_commands =
                u_ddr3.u_channel.perf_timing_read_commands_q;
            assign memory_timing_write_commands =
                u_ddr3.u_channel.perf_timing_write_commands_q;
            assign memory_max_read_queue =
                u_ddr3.u_channel.perf_max_read_queue_q;
            assign memory_max_write_queue =
                u_ddr3.u_channel.perf_max_write_queue_q;
            assign memory_max_timing_owners =
                u_ddr3.u_channel.perf_max_timing_owners_q;

            initial begin
                if (!$value$plusargs("memh=%s", memh_path))
                    $fatal(1,
                        "full-CCX timed-memory test requires +memh=<256-bit image>");
                if (!$value$plusargs("memh_words=%d", memh_words))
                    $fatal(1,
                        "full-CCX timed-memory test requires +memh_words=<count>");
                if ((memh_words < 1) ||
                    (memh_words > (RAM_BYTES / 32)))
                    $fatal(1, "timed-memory memh_words=%0d exceeds RAM",
                           memh_words);
                $readmemh(memh_path, u_ddr3.u_channel.memory_q,
                          0, memh_words - 1);
            end

            always @(posedge clk) begin
                if (!rst_n) begin
                    ddr3_commands = 0;
                    max_timing_owners = 0;
                end else begin
                    if (u_ddr3.timing_cmd_valid &&
                        u_ddr3.timing_cmd_ready)
                        ddr3_commands = ddr3_commands + 1;
                    if (u_ddr3.u_channel.timing_owner_count_q >
                        max_timing_owners)
                        max_timing_owners =
                            u_ddr3.u_channel.timing_owner_count_q;
                end
            end

            if (MEMORY_TIMING_MODEL == 0) begin : g_ddr3_stats
                assign memory_ddr_commands_coalesced =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_commands_coalesced_q;
                assign memory_ddr_reads_coalesced =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_read_commands_coalesced_q;
                assign memory_ddr_writes_coalesced =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_write_commands_coalesced_q;
                assign memory_ddr_coalesced_groups =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_coalesced_groups_q;
                always @(posedge clk) begin
                    if (!rst_n) begin
                        max_ddr3_queued = 0;
                    end else if
                        (u_ddr3.g_ddr3.u_timing.u_timing.command_count_q >
                         max_ddr3_queued) begin
                        max_ddr3_queued =
                            u_ddr3.g_ddr3.u_timing.u_timing.command_count_q;
                    end
                end
            end else begin : g_magic_stats
                assign memory_ddr_commands_coalesced = 64'd0;
                assign memory_ddr_reads_coalesced = 64'd0;
                assign memory_ddr_writes_coalesced = 64'd0;
                assign memory_ddr_coalesced_groups = 64'd0;
                always @(posedge clk) begin
                    if (!rst_n)
                        max_ddr3_queued = 0;
                    else if (u_ddr3.g_magic.u_timing.resp_valid_o)
                        max_ddr3_queued = 1;
                end
            end
        end else begin : g_sram
            assign memory_read_bursts = 64'd0;
            assign memory_write_bursts = 64'd0;
            assign memory_read_beats_requested = 64'd0;
            assign memory_write_beats_requested = 64'd0;
            assign memory_read_beats_returned = 64'd0;
            assign memory_write_beats_received = 64'd0;
            assign memory_read_address_wait = 64'd0;
            assign memory_write_address_wait = 64'd0;
            assign memory_write_data_wait = 64'd0;
            assign memory_read_response_wait = 64'd0;
            assign memory_write_response_wait = 64'd0;
            assign memory_timing_backend_wait = 64'd0;
            assign memory_timing_owner_full = 64'd0;
            assign memory_read_timing_wait = 64'd0;
            assign memory_write_timing_wait = 64'd0;
            assign memory_timing_read_commands = 64'd0;
            assign memory_timing_write_commands = 64'd0;
            assign memory_max_read_queue = 64'd0;
            assign memory_max_write_queue = 64'd0;
            assign memory_max_timing_owners = 64'd0;
            assign memory_ddr_commands_coalesced = 64'd0;
            assign memory_ddr_reads_coalesced = 64'd0;
            assign memory_ddr_writes_coalesced = 64'd0;
            assign memory_ddr_coalesced_groups = 64'd0;

            tb_axi256_burst_sram #(
                .RAM_BYTES(RAM_BYTES)
            ) u_ram (
                .clk_i(clk),
                .rst_ni(rst_n),
                .arid_i(ram_arid),
                .araddr_i(ram_araddr),
                .arlen_i(ram_arlen),
                .arsize_i(ram_arsize),
                .arburst_i(ram_arburst),
                .arvalid_i(ram_arvalid),
                .arready_o(ram_arready),
                .rid_o(ram_rid),
                .rdata_o(ram_rdata),
                .rresp_o(ram_rresp),
                .rlast_o(ram_rlast),
                .rvalid_o(ram_rvalid),
                .rready_i(ram_rready),
                .awid_i(ram_awid),
                .awaddr_i(ram_awaddr),
                .awlen_i(ram_awlen),
                .awsize_i(ram_awsize),
                .awburst_i(ram_awburst),
                .awvalid_i(ram_awvalid),
                .awready_o(ram_awready),
                .wdata_i(ram_wdata),
                .wstrb_i(ram_wstrb),
                .wlast_i(ram_wlast),
                .wvalid_i(ram_wvalid),
                .wready_o(ram_wready),
                .bid_o(ram_bid),
                .bresp_o(ram_bresp),
                .bvalid_o(ram_bvalid),
                .bready_i(ram_bready)
            );

            assign magic_ccx_read_data = {
                u_ram.ram_q[magic_ccx_word_index + 1'b1],
                u_ram.ram_q[magic_ccx_word_index]
            };

            initial begin
                ddr3_commands = 0;
                max_ddr3_queued = 0;
                max_timing_owners = 0;
                if (!$value$plusargs("memh=%s", memh_path))
                    $fatal(1,
                        "full-CCX SRAM test requires +memh=<256-bit image>");
                if (!$value$plusargs("memh_words=%d", memh_words))
                    $fatal(1,
                        "full-CCX SRAM test requires +memh_words=<count>");
                if ((memh_words < 1) ||
                    (memh_words > (RAM_BYTES / 32)))
                    $fatal(1, "SRAM memh_words=%0d exceeds RAM",
                           memh_words);
                $readmemh(memh_path, u_ram.ram_q, 0, memh_words - 1);
            end
        end
    endgenerate

    initial begin
        magic_ccx_source_mask_q = 4'b0000;
        magic_ccx_source_mask_arg = 0;
        if ($test$plusargs("magic_l1i"))
            magic_ccx_source_mask_q[`OPENRV64_CCX_SOURCE_ICACHE] = 1'b1;
        if ($test$plusargs("magic_l1d"))
            magic_ccx_source_mask_q[`OPENRV64_CCX_SOURCE_DCACHE] = 1'b1;
        if ($value$plusargs("magic_ccx_sources=%h",
                            magic_ccx_source_mask_arg))
            magic_ccx_source_mask_q = magic_ccx_source_mask_arg[3:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            magic_ccx_resp_valid_q <= 1'b0;
            magic_ccx_resp_hart_id_q <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            magic_ccx_resp_txn_id_q <=
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            magic_ccx_resp_source_id_q <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            magic_ccx_resp_rdata_q <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            magic_ccx_l1i_reads <= 0;
            magic_ccx_l1d_reads <= 0;
            for (magic_ccx_shadow_reset_scan = 0;
                 magic_ccx_shadow_reset_scan < MAGIC_CCX_SHADOW_DEPTH;
                 magic_ccx_shadow_reset_scan =
                    magic_ccx_shadow_reset_scan + 1) begin
                magic_ccx_shadow_valid_q[
                    magic_ccx_shadow_reset_scan] <= 1'b0;
                magic_ccx_shadow_hart_id_q[
                    magic_ccx_shadow_reset_scan] <=
                    {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
                magic_ccx_shadow_txn_id_q[
                    magic_ccx_shadow_reset_scan] <=
                    {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
                magic_ccx_shadow_source_id_q[
                    magic_ccx_shadow_reset_scan] <=
                    {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            end
        end else begin
            if (magic_ccx_resp_fire && !magic_ccx_req_fire)
                magic_ccx_resp_valid_q <= 1'b0;
            if (magic_ccx_shadow_resp_fire)
                magic_ccx_shadow_valid_q[
                    magic_ccx_shadow_resp_index_r] <= 1'b0;
            if (magic_ccx_req_fire) begin
                magic_ccx_resp_valid_q <= 1'b1;
                magic_ccx_resp_hart_id_q <= ccx_req_hart_id;
                magic_ccx_resp_txn_id_q <= ccx_req_txn_id;
                magic_ccx_resp_source_id_q <= ccx_req_source_id;
                magic_ccx_resp_rdata_q <= magic_ccx_read_data;
                magic_ccx_shadow_valid_q[
                    magic_ccx_shadow_free_index_r] <= 1'b1;
                magic_ccx_shadow_hart_id_q[
                    magic_ccx_shadow_free_index_r] <= ccx_req_hart_id;
                magic_ccx_shadow_txn_id_q[
                    magic_ccx_shadow_free_index_r] <= ccx_req_txn_id;
                magic_ccx_shadow_source_id_q[
                    magic_ccx_shadow_free_index_r] <= ccx_req_source_id;
                if (ccx_req_source_id ==
                    `OPENRV64_CCX_SOURCE_ICACHE)
                    magic_ccx_l1i_reads <= magic_ccx_l1i_reads + 1;
                else if (ccx_req_source_id ==
                         `OPENRV64_CCX_SOURCE_DCACHE)
                    magic_ccx_l1d_reads <= magic_ccx_l1d_reads + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_read_transactions = 0;
            axi_read_beats = 0;
            axi_write_transactions = 0;
            axi_write_beats = 0;
            max_l2_mshrs = 0;
        end else begin
            if (ram_arvalid && ram_arready)
                axi_read_transactions = axi_read_transactions + 1;
            if (ram_rvalid && ram_rready)
                axi_read_beats = axi_read_beats + 1;
            if (ram_awvalid && ram_awready)
                axi_write_transactions = axi_write_transactions + 1;
            if (ram_wvalid && ram_wready)
                axi_write_beats = axi_write_beats + 1;
            if (u_complex.u_l2.active_mshr_count_r > max_l2_mshrs)
                max_l2_mshrs = u_complex.u_l2.active_mshr_count_r;
        end
    end

    always #5 clk = ~clk;

    // Optional address-level timing for the single architectural fetch demand
    // retained by fetch_3w.  This distinguishes lower-memory line fills from
    // the much more common L1I-hit request/response turnaround.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_demand_trace_cycle_q = 0;
            fetch_demand_trace_start_q = 0;
            fetch_demand_trace_external_q = 0;
            fetch_demand_trace_empty_q = 0;
            fetch_demand_trace_active_q = 1'b0;
            fetch_demand_trace_addr_q = 64'd0;
            fetch_demand_trace_pc_q = 64'd0;
        end else begin
            fetch_demand_trace_cycle_q = fetch_demand_trace_cycle_q + 1;

            if (fetch_demand_trace_active_q) begin
                if (dut.u_bus.g_ccx.u_bus.u_l1i.backend_state_q != 0)
                    fetch_demand_trace_external_q =
                        fetch_demand_trace_external_q + 1;
                if ((dut.fetch_decode_valid == 0) &&
                    dut.backend_decode_ready[0] &&
                    dut.frontend_decode_enable)
                    fetch_demand_trace_empty_q =
                        fetch_demand_trace_empty_q + 1;

                if (dut.fetch_pipe_resp_valid &&
                    dut.fetch_pipe_resp_ready &&
                    dut.fetch_pipe_resp_demand) begin
                    if (fetch_demand_trace_enabled != 0)
                        $display(
                            "TRACE_FETCH_DEMAND kind=complete start_pc=%016h addr=%016h latency=%0d external=%0d empty=%0d",
                            fetch_demand_trace_pc_q,
                            fetch_demand_trace_addr_q,
                            fetch_demand_trace_cycle_q -
                                fetch_demand_trace_start_q,
                            fetch_demand_trace_external_q,
                            fetch_demand_trace_empty_q);
                    fetch_demand_trace_active_q = 1'b0;
                end else if (dut.fetch3_restart ||
                             dut.fetch3_invalidate) begin
                    if (fetch_demand_trace_enabled != 0)
                        $display(
                            "TRACE_FETCH_DEMAND kind=cancel start_pc=%016h addr=%016h latency=%0d external=%0d empty=%0d",
                            fetch_demand_trace_pc_q,
                            fetch_demand_trace_addr_q,
                            fetch_demand_trace_cycle_q -
                                fetch_demand_trace_start_q,
                            fetch_demand_trace_external_q,
                            fetch_demand_trace_empty_q);
                    fetch_demand_trace_active_q = 1'b0;
                end
            end

            if (dut.fetch_pipe_req_valid &&
                dut.fetch_pipe_req_ready &&
                dut.fetch_pipe_req_demand) begin
                if (fetch_demand_trace_active_q)
                    $fatal(1,
                        "fetch demand trace observed overlapping demand requests");
                fetch_demand_trace_active_q = 1'b1;
                fetch_demand_trace_start_q = fetch_demand_trace_cycle_q;
                fetch_demand_trace_external_q = 0;
                fetch_demand_trace_empty_q = 0;
                fetch_demand_trace_addr_q = dut.fetch_pipe_req_addr;
                fetch_demand_trace_pc_q =
                    dut.g_fetch_axi.u_fetch.consume_pc_q;
            end
        end
    end

    // A sector lookaside hit is only useful until the completing 256-bit
    // demand returns.  Track that interval at the handshake edges so the
    // diagnostic distinguishes an exposed instruction starvation from a
    // frontend-empty cycle caused by backend pressure or branch control.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stash_trace_episodes = 0;
            stash_trace_completed = 0;
            stash_trace_interrupted = 0;
            stash_trace_requested = 0;
            stash_trace_stalled = 0;
            stash_trace_completed_stalled = 0;
            stash_trace_interrupted_stalled = 0;
            stash_trace_exposed_stall_cycles = 0;
            stash_trace_completed_stall_cycles = 0;
            stash_trace_interrupted_stall_cycles = 0;
            stash_trace_same_line_stall_cycles = 0;
            stash_trace_next_line_stall_cycles = 0;
            stash_trace_preview_instructions = 0;
            stash_trace_request_delay_sum = 0;
            stash_trace_request_delay_max = 0;
            stash_trace_response_delay_sum = 0;
            stash_trace_response_delay_max = 0;
            stash_trace_refill_latency_sum = 0;
            stash_trace_refill_latency_max = 0;
            stash_trace_printed = 0;
            stash_trace_active = 1'b0;
            stash_trace_request_seen = 1'b0;
            stash_trace_pc = 64'd0;
            stash_trace_line = 64'd0;
            stash_trace_sector = 0;
            stash_trace_offset = 0;
            stash_trace_start_cycle = 0;
            stash_trace_request_cycle = 0;
            stash_trace_episode_stall_cycles = 0;
            stash_trace_episode_same_line_stalls = 0;
            stash_trace_episode_next_line_stalls = 0;
            stash_trace_episode_preview_instructions = 0;
            stash_trace_cycle = 0;
            stash_trace_delay = 0;
            for (stash_trace_reset_index = 0;
                 stash_trace_reset_index < 4;
                 stash_trace_reset_index =
                     stash_trace_reset_index + 1) begin
                stash_trace_offset_hits[stash_trace_reset_index] = 0;
                stash_trace_offset_stalled[stash_trace_reset_index] = 0;
                stash_trace_offset_stall_cycles[
                    stash_trace_reset_index] = 0;
                if (stash_trace_reset_index < 2) begin
                    stash_trace_sector_hits[stash_trace_reset_index] = 0;
                    stash_trace_sector_stalled[
                        stash_trace_reset_index] = 0;
                    stash_trace_sector_stall_cycles[
                        stash_trace_reset_index] = 0;
                end
            end
        end else begin
            stash_trace_cycle = stash_trace_cycle + 1;

            if (stash_trace_active) begin
                stash_trace_episode_preview_instructions =
                    stash_trace_episode_preview_instructions +
                    dut.frontend_decode_fire[0] +
                    dut.frontend_decode_fire[1] +
                    dut.frontend_decode_fire[2];
                stash_trace_preview_instructions =
                    stash_trace_preview_instructions +
                    dut.frontend_decode_fire[0] +
                    dut.frontend_decode_fire[1] +
                    dut.frontend_decode_fire[2];

                if (!stash_trace_request_seen &&
                    dut.g_fetch_axi.u_fetch.req_fire &&
                    dut.g_fetch_axi.u_fetch.req_demand_o &&
                    (dut.g_fetch_axi.u_fetch.req_addr_o[63:5] ==
                     stash_trace_line[63:5])) begin
                    stash_trace_request_seen = 1'b1;
                    stash_trace_request_cycle = stash_trace_cycle;
                    stash_trace_requested = stash_trace_requested + 1;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_start_cycle;
                    stash_trace_request_delay_sum =
                        stash_trace_request_delay_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_request_delay_max)
                        stash_trace_request_delay_max = stash_trace_delay;
                end

                if ((dut.fetch_decode_valid == 0) &&
                    dut.backend_decode_ready[0] &&
                    dut.frontend_decode_enable &&
                    !dut.control_flush &&
                    !dut.control_redirect &&
                    !dut.bp_fetch_stall &&
                    !dut.g_fetch_axi.u_fetch.consume_line_hit &&
                    dut.g_fetch_axi.u_fetch.pending_valid_q &&
                    (dut.g_fetch_axi.u_fetch.pending_addr_q[63:5] ==
                     stash_trace_line[63:5])) begin
                    if (stash_trace_episode_stall_cycles == 0) begin
                        stash_trace_stalled = stash_trace_stalled + 1;
                        stash_trace_offset_stalled[
                            stash_trace_offset] =
                                stash_trace_offset_stalled[
                                    stash_trace_offset] + 1;
                        stash_trace_sector_stalled[
                            stash_trace_sector] =
                                stash_trace_sector_stalled[
                                    stash_trace_sector] + 1;
                    end
                    stash_trace_episode_stall_cycles =
                        stash_trace_episode_stall_cycles + 1;
                    stash_trace_exposed_stall_cycles =
                        stash_trace_exposed_stall_cycles + 1;
                    stash_trace_offset_stall_cycles[
                        stash_trace_offset] =
                            stash_trace_offset_stall_cycles[
                                stash_trace_offset] + 1;
                    stash_trace_sector_stall_cycles[
                        stash_trace_sector] =
                            stash_trace_sector_stall_cycles[
                                stash_trace_sector] + 1;
                    if (dut.g_fetch_axi.u_fetch.consume_pc_q[63:5] ==
                        stash_trace_line[63:5]) begin
                        stash_trace_episode_same_line_stalls =
                            stash_trace_episode_same_line_stalls + 1;
                        stash_trace_same_line_stall_cycles =
                            stash_trace_same_line_stall_cycles + 1;
                    end else begin
                        stash_trace_episode_next_line_stalls =
                            stash_trace_episode_next_line_stalls + 1;
                        stash_trace_next_line_stall_cycles =
                            stash_trace_next_line_stall_cycles + 1;
                    end
                end

                // Any new frontend restart abandons the old preview episode.
                // A simultaneous response is not useful to that old path.
                if (dut.fetch3_restart || dut.control_flush) begin
                    stash_trace_interrupted =
                        stash_trace_interrupted + 1;
                    if (stash_trace_episode_stall_cycles != 0)
                        stash_trace_interrupted_stalled =
                            stash_trace_interrupted_stalled + 1;
                    stash_trace_interrupted_stall_cycles =
                        stash_trace_interrupted_stall_cycles +
                        stash_trace_episode_stall_cycles;
                    stash_trace_active = 1'b0;
                end else if (stash_trace_request_seen &&
                             dut.fetch_pipe_resp_valid &&
                             dut.fetch_pipe_resp_demand &&
                             (dut.fetch_pipe_resp_addr[63:5] ==
                              stash_trace_line[63:5])) begin
                    stash_trace_completed = stash_trace_completed + 1;
                    if (stash_trace_episode_stall_cycles != 0)
                        stash_trace_completed_stalled =
                            stash_trace_completed_stalled + 1;
                    stash_trace_completed_stall_cycles =
                        stash_trace_completed_stall_cycles +
                        stash_trace_episode_stall_cycles;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_start_cycle;
                    stash_trace_response_delay_sum =
                        stash_trace_response_delay_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_response_delay_max)
                        stash_trace_response_delay_max = stash_trace_delay;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_request_cycle;
                    stash_trace_refill_latency_sum =
                        stash_trace_refill_latency_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_refill_latency_max)
                        stash_trace_refill_latency_max = stash_trace_delay;
                    if (($test$plusargs("trace_stash_stall") ||
                         $test$plusargs("trace_stash_stall_all")) &&
                        (stash_trace_episode_stall_cycles != 0) &&
                        ($test$plusargs("trace_stash_stall_all") ||
                         (stash_trace_printed < 16))) begin
                        $display(
                            "TRACE_STASH_STALL pc=%016h line=%016h sector=%0d offset=%0d request_delay=%0d refill_latency=%0d hit_to_fill=%0d preview_instr=%0d exposed_stall=%0d same_line=%0d next_line=%0d",
                            stash_trace_pc, stash_trace_line,
                            stash_trace_sector, stash_trace_offset,
                            stash_trace_request_cycle -
                                stash_trace_start_cycle,
                            stash_trace_cycle -
                                stash_trace_request_cycle,
                            stash_trace_cycle -
                                stash_trace_start_cycle,
                            stash_trace_episode_preview_instructions,
                            stash_trace_episode_stall_cycles,
                            stash_trace_episode_same_line_stalls,
                            stash_trace_episode_next_line_stalls);
                        stash_trace_printed = stash_trace_printed + 1;
                    end
                    stash_trace_active = 1'b0;
                end
            end

            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.fetch_alt_restart_hit) begin
                stash_trace_active = 1'b1;
                stash_trace_request_seen = 1'b0;
                stash_trace_pc = dut.fetch3_restart_pc;
                stash_trace_line = {dut.fetch3_restart_pc[63:5], 5'b00000};
                stash_trace_sector = dut.fetch3_restart_pc[4];
                stash_trace_offset = dut.fetch3_restart_pc[3:2];
                stash_trace_start_cycle = stash_trace_cycle;
                stash_trace_request_cycle = 0;
                stash_trace_episode_stall_cycles = 0;
                stash_trace_episode_same_line_stalls = 0;
                stash_trace_episode_next_line_stalls = 0;
                stash_trace_episode_preview_instructions = 0;
                stash_trace_episodes = stash_trace_episodes + 1;
                stash_trace_offset_hits[
                    dut.fetch3_restart_pc[3:2]] =
                        stash_trace_offset_hits[
                            dut.fetch3_restart_pc[3:2]] + 1;
                stash_trace_sector_hits[
                    dut.fetch3_restart_pc[4]] =
                        stash_trace_sector_hits[
                            dut.fetch3_restart_pc[4]] + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        max_cycles = 250000;
        expected_a0 = 0;
        expected_a0_valid = 1'b0;
        done_pc = 0;
        done_pc_valid = 1'b0;
        retired = 0;
        ccx_requests = 0;
        ccx_fetch_reads = 0;
        ccx_data_reads = 0;
        ccx_data_writes = 0;
        ccx_ptw_reads = 0;
        dtlb_fast_loads = 0;
        dtlb_fast_stores = 0;
        require_sv39 = $test$plusargs("require_sv39");
        saw_sv39 = 1'b0;
        saw_supervisor = 1'b0;
        saw_sv39_alias_fetch = 1'b0;
        saw_sv39_alias_data = 1'b0;
        direction_corrections = 0;
        target_corrections = 0;
        bp_btb_lookups = 0;
        bp_btb_hits = 0;
        bp_btb_misses = 0;
        bp_btb_wrong_targets = 0;
        bp_ras_lookups = 0;
        bp_ras_hits = 0;
        bp_ras_misses = 0;
        bp_ras_wrong_targets = 0;
        lookaside_restart_hits = 0;
        lookaside_eligible_restarts = 0;
        lookaside_pair_replacements = 0;
        lookaside_pair_stack_overflows = 0;
        lookaside_pair_stack_max_saved = 0;
        lookaside_store_fills = 0;
        lookaside_store_duplicate_fills = 0;
        lookaside_store_free_fills = 0;
        lookaside_store_evictions = 0;
        lookaside_full_branch_allocations = 0;
        lookaside_sector_allocations = 0;
        lookaside_sector_predicted_free = 0;
        lookaside_sector_unpredicted_free = 0;
        lookaside_sector_response_taps = 0;
        lookaside_sector_predicted_taps = 0;
        lookaside_sector_unpredicted_taps = 0;
        lookaside_sector_background_requests = 0;
        lookaside_sector_background_deferred = 0;
        l1d_prefetch_issued = 0;
        l1d_prefetch_useful = 0;
        l1d_prefetch_late = 0;
        l1d_prefetch_dropped = 0;
        l1d_prefetch_useless = 0;
        l1d_prefetch_max_depth = 0;
        issued = 0;
        decoded = 0;
        issued_this_cycle = 0;
        decoded_this_cycle = 0;
        issue_width_0 = 0;
        issue_width_1 = 0;
        issue_width_2 = 0;
        issue_width_3 = 0;
        issue_width_4 = 0;
        decode_width_0 = 0;
        decode_width_1 = 0;
        decode_width_2 = 0;
        decode_width_3 = 0;
        retire_width_0 = 0;
        retire_width_1 = 0;
        retire_width_2 = 0;
        retire_width_3 = 0;
        dispatch_nonempty = 0;
        dispatch_nonempty_no_issue = 0;
        dispatch_full = 0;
        raw_hazard_cycles = 0;
        raw_first_block_cycles = 0;
        raw_first_pending_cycles = 0;
        raw_first_bundle_cycles = 0;
        raw_first_completed_cycles = 0;
        raw_secondary_only_cycles = 0;
        raw_first_rs1_cycles = 0;
        raw_first_rs2_cycles = 0;
        raw_first_both_sources_cycles = 0;
        raw_first_lane0_cycles = 0;
        raw_first_lane1_cycles = 0;
        raw_first_lane2_cycles = 0;
        raw_first_blocked_alu = 0;
        raw_first_blocked_branch = 0;
        raw_first_blocked_jump = 0;
        raw_first_blocked_load = 0;
        raw_first_blocked_store = 0;
        window_nonempty_cycles = 0;
        window_no_eligible_cycles = 0;
        window_raw_stall_cycles = 0;
        window_hard_stall_cycles = 0;
        window_mem_order_stall_cycles = 0;
        window_unissued_entry_cycles = 0;
        window_operand_ready_entry_cycles = 0;
        window_eligible_entry_cycles = 0;
        window_raw_block_entry_cycles = 0;
        window_hard_block_entry_cycles = 0;
        window_mem_order_block_entry_cycles = 0;
        waw_hazard_cycles = 0;
        read_port_hazard_cycles = 0;
        write_busy_cycles = 0;
        barrier_cycles = 0;
        retire_nonempty = 0;
        retire_nonempty_no_retire = 0;
        retire_head_incomplete = 0;
        retire_completed_behind_head = 0;
        frontend_empty = 0;
        frontend_held = 0;
        frontend_request_wait = 0;
        frontend_control_empty = 0;
        frontend_refill_wait = 0;
        frontend_no_line = 0;
        frontend_bp_stall = 0;
        frontend_other_empty = 0;
        frontend_empty_backend_ready = 0;
        frontend_empty_dispatch_empty = 0;
        frontend_empty_dispatch_empty_backend_ready = 0;
        frontend_empty_dispatch_empty_retire_empty = 0;
        frontend_empty_dispatch_nonempty = 0;
        frontend_empty_dispatch_full = 0;
        frontend_empty_l1i_external_miss = 0;
        frontend_empty_pending_no_external_miss = 0;
        fetch_demand_trace_enabled =
            $test$plusargs("fetch_demand_trace");
        lsu_request_wait = 0;
        lsu_load_request_wait = 0;
        lsu_store_request_wait = 0;
        lsu_second_port_opportunities = 0;
        l1d_request_wait = 0;
        l1d_load_request_wait = 0;
        l1d_store_request_wait = 0;
        l1d_wait_store_block = 0;
        l1d_dirty_snoop_accepts = 0;
        l1d_wait_lock_barrier = 0;
        l1d_wait_response_tags = 0;
        l1d_wait_refill = 0;
        l1d_wait_access = 0;
        l1d_wait_run_response = 0;
        l1d_wait_unknown = 0;
        ccx_request_wait = 0;
        ccx_read_request_wait = 0;
        ccx_write_request_wait = 0;
        l2_bus_request_wait = 0;
        l2_command_full_cycles = 0;
        axi_read_address_wait = 0;
        axi_write_address_wait = 0;
        axi_write_data_wait = 0;
        lsu_outstanding_cycles = 0;
        branch_resolutions = 0;
        conditional_branch_resolutions = 0;
        pipe_conflicts = 0;
        pipe_conflicts_ex0 = 0;
        pipe_conflicts_ex1 = 0;
        pipe_conflicts_mem = 0;
        conflict_blocked_alu = 0;
        conflict_blocked_branch = 0;
        conflict_blocked_jump = 0;
        conflict_blocked_load = 0;
        conflict_blocked_store = 0;
        conflict_pair_branch_alu = 0;
        conflict_pair_alu_branch = 0;
        conflict_pair_branch_branch = 0;
        conflict_pair_alu_alu = 0;
        conflict_pair_load_load = 0;
        conflict_pair_store_load = 0;
        conflict_pair_store_store = 0;
        conflict_pair_other = 0;
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 250000;
        if ($value$plusargs("expect_a0=%h", expected_a0))
            expected_a0_valid = 1'b1;
        if ($value$plusargs("done_pc=%h", done_pc))
            done_pc_valid = 1'b1;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (cycles = 0; (cycles < max_cycles) && !run_done;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            retired = retired + dut.backend_retire_count;
            issued_this_cycle =
                dut.backend_issue_valid[0] +
                dut.backend_issue_valid[1] +
                dut.backend_issue_valid[2] +
                dut.backend_issue_valid[3];
            decoded_this_cycle =
                dut.frontend_decode_fire[0] +
                dut.frontend_decode_fire[1] +
                dut.frontend_decode_fire[2];
            issued = issued + issued_this_cycle;
            decoded = decoded + decoded_this_cycle;
            if (dut.backend_mem1_valid && dut.backend_mem_ready)
                lsu_second_port_opportunities =
                    lsu_second_port_opportunities + 1;
            case (issued_this_cycle)
                0: issue_width_0 = issue_width_0 + 1;
                1: issue_width_1 = issue_width_1 + 1;
                2: issue_width_2 = issue_width_2 + 1;
                3: issue_width_3 = issue_width_3 + 1;
                4: issue_width_4 = issue_width_4 + 1;
            endcase
            case (decoded_this_cycle)
                0: decode_width_0 = decode_width_0 + 1;
                1: decode_width_1 = decode_width_1 + 1;
                2: decode_width_2 = decode_width_2 + 1;
                3: decode_width_3 = decode_width_3 + 1;
            endcase
            case (dut.backend_retire_count)
                0: retire_width_0 = retire_width_0 + 1;
                1: retire_width_1 = retire_width_1 + 1;
                2: retire_width_2 = retire_width_2 + 1;
                3: retire_width_3 = retire_width_3 + 1;
            endcase
            if (dut.backend_dispatch_occupancy != 0) begin
                dispatch_nonempty = dispatch_nonempty + 1;
                if (issued_this_cycle == 0)
                    dispatch_nonempty_no_issue =
                        dispatch_nonempty_no_issue + 1;
            end
            if (dut.backend_dispatch_occupancy == 6)
                dispatch_full = dispatch_full + 1;
            if (dut.u_backend.raw_hazard != 0)
                raw_hazard_cycles = raw_hazard_cycles + 1;
            if ((ISSUE_WINDOW == 0) && raw_first_block) begin
                raw_first_block_cycles = raw_first_block_cycles + 1;
                if (raw_first_bundle)
                    raw_first_bundle_cycles =
                        raw_first_bundle_cycles + 1;
                else if (raw_first_completed)
                    raw_first_completed_cycles =
                        raw_first_completed_cycles + 1;
                else
                    raw_first_pending_cycles =
                        raw_first_pending_cycles + 1;
                if (raw_first_rs1 && raw_first_rs2)
                    raw_first_both_sources_cycles =
                        raw_first_both_sources_cycles + 1;
                else if (raw_first_rs1)
                    raw_first_rs1_cycles = raw_first_rs1_cycles + 1;
                else if (raw_first_rs2)
                    raw_first_rs2_cycles = raw_first_rs2_cycles + 1;
                if (raw_first_lane0)
                    raw_first_lane0_cycles =
                        raw_first_lane0_cycles + 1;
                else if (raw_first_lane1)
                    raw_first_lane1_cycles =
                        raw_first_lane1_cycles + 1;
                else
                    raw_first_lane2_cycles =
                        raw_first_lane2_cycles + 1;
                case (raw_first_op)
                    PERF_OP_BRANCH:
                        raw_first_blocked_branch =
                            raw_first_blocked_branch + 1;
                    PERF_OP_JUMP:
                        raw_first_blocked_jump =
                            raw_first_blocked_jump + 1;
                    PERF_OP_LOAD:
                        raw_first_blocked_load =
                            raw_first_blocked_load + 1;
                    PERF_OP_STORE:
                        raw_first_blocked_store =
                            raw_first_blocked_store + 1;
                    default:
                        raw_first_blocked_alu =
                            raw_first_blocked_alu + 1;
                endcase
            end else if ((ISSUE_WINDOW == 0) &&
                         (dut.u_backend.raw_hazard != 0)) begin
                raw_secondary_only_cycles =
                    raw_secondary_only_cycles + 1;
            end
            if (ISSUE_WINDOW != 0) begin
                window_unissued_entry_cycles =
                    window_unissued_entry_cycles +
                    trace_window_unissued;
                window_operand_ready_entry_cycles =
                    window_operand_ready_entry_cycles +
                    trace_window_operand_ready;
                window_eligible_entry_cycles =
                    window_eligible_entry_cycles +
                    trace_window_eligible;
                window_raw_block_entry_cycles =
                    window_raw_block_entry_cycles +
                    trace_window_raw_block;
                window_hard_block_entry_cycles =
                    window_hard_block_entry_cycles +
                    trace_window_hard_block;
                window_mem_order_block_entry_cycles =
                    window_mem_order_block_entry_cycles +
                    trace_window_mem_order_block;
                if (trace_window_unissued != 0) begin
                    window_nonempty_cycles =
                        window_nonempty_cycles + 1;
                    if (trace_window_eligible == 0) begin
                        window_no_eligible_cycles =
                            window_no_eligible_cycles + 1;
                        if (trace_window_raw_block != 0)
                            window_raw_stall_cycles =
                                window_raw_stall_cycles + 1;
                        if (trace_window_hard_block != 0)
                            window_hard_stall_cycles =
                                window_hard_stall_cycles + 1;
                        if (trace_window_mem_order_block != 0)
                            window_mem_order_stall_cycles =
                                window_mem_order_stall_cycles + 1;
                    end
                end
            end
            if (dut.u_backend.waw_hazard != 0)
                waw_hazard_cycles = waw_hazard_cycles + 1;
            if (dut.u_backend.read_port_hazard != 0)
                read_port_hazard_cycles = read_port_hazard_cycles + 1;
            if (dut.backend_write_busy != 0)
                write_busy_cycles = write_busy_cycles + 1;
            if (dut.backend_barrier)
                barrier_cycles = barrier_cycles + 1;
            if (dut.backend_retire_occupancy != 0) begin
                retire_nonempty = retire_nonempty + 1;
                if (dut.backend_retire_count == 0)
                    retire_nonempty_no_retire =
                        retire_nonempty_no_retire + 1;
                if (!dut.u_backend.queue_retire_valid[0]) begin
                    retire_head_incomplete = retire_head_incomplete + 1;
                    if (dut.u_backend.completed_entry_valid != 0)
                        retire_completed_behind_head =
                            retire_completed_behind_head + 1;
                end
            end
            if (dut.fetch_decode_valid == 0)
                frontend_empty = frontend_empty + 1;
            if ((dut.fetch_decode_valid != 0) &&
                (dut.frontend_decode_fire == 0))
                frontend_held = frontend_held + 1;
            if (dut.fetch_pipe_req_valid && !dut.fetch_pipe_req_ready)
                frontend_request_wait = frontend_request_wait + 1;
            if (dut.fetch_decode_valid == 0) begin
                if (dut.backend_decode_ready[0] &&
                    dut.frontend_decode_enable)
                    frontend_empty_backend_ready =
                        frontend_empty_backend_ready + 1;
                if (dut.backend_dispatch_occupancy == 0) begin
                    frontend_empty_dispatch_empty =
                        frontend_empty_dispatch_empty + 1;
                    if (dut.backend_decode_ready[0] &&
                        dut.frontend_decode_enable)
                        frontend_empty_dispatch_empty_backend_ready =
                            frontend_empty_dispatch_empty_backend_ready + 1;
                    if (dut.backend_retire_occupancy == 0)
                        frontend_empty_dispatch_empty_retire_empty =
                            frontend_empty_dispatch_empty_retire_empty + 1;
                end else begin
                    frontend_empty_dispatch_nonempty =
                        frontend_empty_dispatch_nonempty + 1;
                end
                if (dut.backend_dispatch_occupancy == 6)
                    frontend_empty_dispatch_full =
                        frontend_empty_dispatch_full + 1;
                if (dut.u_bus.g_ccx.u_bus.u_l1i.backend_state_q != 0)
                    frontend_empty_l1i_external_miss =
                        frontend_empty_l1i_external_miss + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.pending_valid_q ||
                          (dut.u_bus.g_ccx.u_bus.fetch_count_q != 0)))
                    frontend_empty_pending_no_external_miss =
                        frontend_empty_pending_no_external_miss + 1;
                if (dut.control_flush || dut.control_redirect)
                    frontend_control_empty = frontend_control_empty + 1;
                else if (dut.bp_fetch_stall)
                    frontend_bp_stall = frontend_bp_stall + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.pending_valid_q ||
                          (dut.u_bus.g_ccx.u_bus.fetch_count_q != 0)))
                    frontend_refill_wait = frontend_refill_wait + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit)
                    frontend_no_line = frontend_no_line + 1;
                else
                    frontend_other_empty = frontend_other_empty + 1;
            end
            if (dut.backend_mem_valid && !dut.backend_mem_ready) begin
                lsu_request_wait = lsu_request_wait + 1;
                if (dut.backend_mem_write)
                    lsu_store_request_wait =
                        lsu_store_request_wait + 1;
                else
                    lsu_load_request_wait =
                        lsu_load_request_wait + 1;
            end
            if (dut.u_bus.g_ccx.u_bus.l1d_req_valid &&
                !dut.u_bus.g_ccx.u_bus.l1d_req_ready) begin
                l1d_request_wait = l1d_request_wait + 1;
                if (dut.u_bus.g_ccx.u_bus.l1d_req_write)
                    l1d_store_request_wait =
                        l1d_store_request_wait + 1;
                else
                    l1d_load_request_wait =
                        l1d_load_request_wait + 1;
                if (dut.u_bus.g_ccx.u_bus.u_l1d.
                        demand_load_store_block)
                    l1d_wait_store_block =
                        l1d_wait_store_block + 1;
                else if (!dut.u_bus.g_ccx.u_bus.u_l1d.
                             lock_request_ready)
                    l1d_wait_lock_barrier =
                        l1d_wait_lock_barrier + 1;
                else if (dut.u_bus.g_ccx.u_bus.u_l1d.
                             response_tag_full)
                    l1d_wait_response_tags =
                        l1d_wait_response_tags + 1;
                else if (!dut.u_bus.g_ccx.u_bus.u_l1d.l1_req_ready) begin
                    case (dut.u_bus.g_ccx.u_bus.u_l1d.u_l1d.u_l1.
                              g_cache.u_cache.state_q)
                        2'd1:
                            l1d_wait_refill = l1d_wait_refill + 1;
                        2'd2:
                            l1d_wait_access = l1d_wait_access + 1;
                        default:
                            l1d_wait_run_response =
                                l1d_wait_run_response + 1;
                    endcase
                end else
                    l1d_wait_unknown = l1d_wait_unknown + 1;
            end
            if (dut.u_bus.g_ccx.u_bus.l1d_req_valid &&
                dut.u_bus.g_ccx.u_bus.l1d_req_ready &&
                !dut.u_bus.g_ccx.u_bus.l1d_req_write &&
                dut.u_bus.g_ccx.u_bus.u_l1d.
                    demand_load_store_conflict_r &&
                !dut.u_bus.g_ccx.u_bus.u_l1d.
                    demand_load_store_block)
                l1d_dirty_snoop_accepts =
                    l1d_dirty_snoop_accepts + 1;
            if (ccx_req_valid && !ccx_req_ready) begin
                ccx_request_wait = ccx_request_wait + 1;
                if (ccx_req_op == `OPENRV64_CCX_OP_WRITE)
                    ccx_write_request_wait =
                        ccx_write_request_wait + 1;
                else
                    ccx_read_request_wait =
                        ccx_read_request_wait + 1;
            end
            if (u_complex.u_l2.bus_req_valid_o &&
                !u_complex.u_l2.bus_req_ready_i)
                l2_bus_request_wait = l2_bus_request_wait + 1;
            if (u_complex.u_l2.command_queue_full)
                l2_command_full_cycles = l2_command_full_cycles + 1;
            if (ram_arvalid && !ram_arready)
                axi_read_address_wait = axi_read_address_wait + 1;
            if (ram_awvalid && !ram_awready)
                axi_write_address_wait = axi_write_address_wait + 1;
            if (ram_wvalid && !ram_wready)
                axi_write_data_wait = axi_write_data_wait + 1;
            if (trace_lsu_sent != 0)
                lsu_outstanding_cycles = lsu_outstanding_cycles + 1;
            if (dut.branch_resolved)
                branch_resolutions = branch_resolutions + 1;
            if (dut.branch_resolved && dut.branch_conditional)
                conditional_branch_resolutions =
                    conditional_branch_resolutions + 1;
            if (trace_pipe_conflict) begin
                pipe_conflicts = pipe_conflicts + 1;
                case (trace_conflict_pipe)
                    `OPENRV64_EXEC_PIPE_EX0:
                        pipe_conflicts_ex0 = pipe_conflicts_ex0 + 1;
                    `OPENRV64_EXEC_PIPE_EX1:
                        pipe_conflicts_ex1 = pipe_conflicts_ex1 + 1;
                    `OPENRV64_EXEC_PIPE_MEM:
                        pipe_conflicts_mem = pipe_conflicts_mem + 1;
                    `OPENRV64_EXEC_PIPE_MEM1:
                        pipe_conflicts_mem = pipe_conflicts_mem + 1;
                endcase
                case (trace_conflict_blocked_op)
                    PERF_OP_BRANCH:
                        conflict_blocked_branch =
                            conflict_blocked_branch + 1;
                    PERF_OP_JUMP:
                        conflict_blocked_jump =
                            conflict_blocked_jump + 1;
                    PERF_OP_LOAD:
                        conflict_blocked_load =
                            conflict_blocked_load + 1;
                    PERF_OP_STORE:
                        conflict_blocked_store =
                            conflict_blocked_store + 1;
                    default:
                        conflict_blocked_alu =
                            conflict_blocked_alu + 1;
                endcase
                if (((trace_conflict_older_op == PERF_OP_BRANCH) ||
                     (trace_conflict_older_op == PERF_OP_JUMP)) &&
                    (trace_conflict_blocked_op == PERF_OP_ALU))
                    conflict_pair_branch_alu =
                        conflict_pair_branch_alu + 1;
                else if ((trace_conflict_older_op == PERF_OP_ALU) &&
                         ((trace_conflict_blocked_op == PERF_OP_BRANCH) ||
                          (trace_conflict_blocked_op == PERF_OP_JUMP)))
                    conflict_pair_alu_branch =
                        conflict_pair_alu_branch + 1;
                else if (((trace_conflict_older_op == PERF_OP_BRANCH) ||
                          (trace_conflict_older_op == PERF_OP_JUMP)) &&
                         ((trace_conflict_blocked_op == PERF_OP_BRANCH) ||
                          (trace_conflict_blocked_op == PERF_OP_JUMP)))
                    conflict_pair_branch_branch =
                        conflict_pair_branch_branch + 1;
                else if ((trace_conflict_older_op == PERF_OP_ALU) &&
                         (trace_conflict_blocked_op == PERF_OP_ALU))
                    conflict_pair_alu_alu =
                        conflict_pair_alu_alu + 1;
                else if ((trace_conflict_older_op == PERF_OP_LOAD) &&
                         (trace_conflict_blocked_op == PERF_OP_LOAD))
                    conflict_pair_load_load =
                        conflict_pair_load_load + 1;
                else if ((trace_conflict_older_op == PERF_OP_STORE) &&
                         (trace_conflict_blocked_op == PERF_OP_LOAD))
                    conflict_pair_store_load =
                        conflict_pair_store_load + 1;
                else if ((trace_conflict_older_op == PERF_OP_STORE) &&
                         (trace_conflict_blocked_op == PERF_OP_STORE))
                    conflict_pair_store_store =
                        conflict_pair_store_store + 1;
                else
                    conflict_pair_other = conflict_pair_other + 1;
            end
            if (core_axi_arvalid || core_axi_awvalid || core_axi_wvalid)
                $fatal(1,
                    "physical CoreMark unexpectedly used residual core AXI");
            if (ccx_req_valid && ccx_req_ready) begin
                ccx_requests = ccx_requests + 1;
                if (ccx_req_source_id == `OPENRV64_CCX_SOURCE_ICACHE)
                    ccx_fetch_reads = ccx_fetch_reads + 1;
                else if (ccx_req_source_id ==
                         `OPENRV64_CCX_SOURCE_PTW)
                    ccx_ptw_reads = ccx_ptw_reads + 1;
                else if (ccx_req_op == `OPENRV64_CCX_OP_READ)
                    ccx_data_reads = ccx_data_reads + 1;
                else if (ccx_req_op == `OPENRV64_CCX_OP_WRITE)
                    ccx_data_writes = ccx_data_writes + 1;
                if ((ccx_req_source_id ==
                     `OPENRV64_CCX_SOURCE_ICACHE) &&
                    (dut.csr_priv_mode == `RV64_PRIV_S) &&
                    (ccx_req_addr >= 64'h0000_0000_8000_1000) &&
                    (ccx_req_addr < 64'h0000_0000_8000_2000))
                    saw_sv39_alias_fetch = 1'b1;
                if ((ccx_req_source_id ==
                     `OPENRV64_CCX_SOURCE_DCACHE) &&
                    (dut.csr_priv_mode == `RV64_PRIV_S) &&
                    (ccx_req_addr >= 64'h0000_0000_8000_0000) &&
                    (ccx_req_addr < 64'h0000_0000_8002_0000))
                    saw_sv39_alias_data = 1'b1;
            end
            if (dut.u_bus.g_ccx.u_bus.pipe_fast_request_fire &&
                dut.u_bus.g_ccx.u_bus.pipe_translated_hit) begin
                if (dut.u_bus.g_ccx.u_bus.l1d_req_write)
                    dtlb_fast_stores = dtlb_fast_stores + 1;
                else
                    dtlb_fast_loads = dtlb_fast_loads + 1;
            end
            if (dut.csr_satp_mode == `RV64_SATP_MODE_SV39)
                saw_sv39 = 1'b1;
            if (dut.csr_priv_mode == `RV64_PRIV_S)
                saw_supervisor = 1'b1;
            if (dut.backend_redirect)
                direction_corrections = direction_corrections + 1;
            if (dut.bp_target_mispredict)
                target_corrections = target_corrections + 1;
            if (dut.u_bp.diag_btb_lookup)
                bp_btb_lookups = bp_btb_lookups + 1;
            if (dut.u_bp.diag_btb_hit)
                bp_btb_hits = bp_btb_hits + 1;
            if (dut.u_bp.diag_btb_miss)
                bp_btb_misses = bp_btb_misses + 1;
            if (dut.u_bp.diag_btb_wrong_target)
                bp_btb_wrong_targets = bp_btb_wrong_targets + 1;
            if (dut.u_bp.diag_ras_lookup)
                bp_ras_lookups = bp_ras_lookups + 1;
            if (dut.u_bp.diag_ras_hit)
                bp_ras_hits = bp_ras_hits + 1;
            if (dut.u_bp.diag_ras_miss)
                bp_ras_misses = bp_ras_misses + 1;
            if (dut.u_bp.diag_ras_wrong_target)
                bp_ras_wrong_targets = bp_ras_wrong_targets + 1;
            if (dut.fetch_alt_restart_hit)
                lookaside_restart_hits = lookaside_restart_hits + 1;
            if (dut.fetch3_restart &&
                dut.g_fetch_axi.u_fetch.alt_restart_eligible_i)
                lookaside_eligible_restarts =
                    lookaside_eligible_restarts + 1;
            if (dut.icache_prefetch_valid &&
                (dut.g_fetch_axi.u_fetch.pair_predicted_valid_q ||
                 dut.g_fetch_axi.u_fetch.pair_unpredicted_valid_q))
                lookaside_pair_replacements =
                    lookaside_pair_replacements + 1;
            if (dut.g_fetch_axi.u_fetch.pair_stack_overflow)
                lookaside_pair_stack_overflows =
                    lookaside_pair_stack_overflows + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.icache_prefetch_valid &&
                !dut.g_fetch_axi.u_fetch.branch_sector_context_match_r) begin
                lookaside_sector_allocations =
                    lookaside_sector_allocations + 1;
                if (dut.g_fetch_axi.u_fetch.
                        branch_predicted_sector_source_valid_r)
                    lookaside_sector_predicted_free =
                        lookaside_sector_predicted_free + 1;
                if (dut.g_fetch_axi.u_fetch.
                        branch_unpredicted_sector_source_valid_r)
                    lookaside_sector_unpredicted_free =
                        lookaside_sector_unpredicted_free + 1;
            end
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_response_tap_r)
                lookaside_sector_response_taps =
                    lookaside_sector_response_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_predicted_tap_r)
                lookaside_sector_predicted_taps =
                    lookaside_sector_predicted_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_unpredicted_tap_r)
                lookaside_sector_unpredicted_taps =
                    lookaside_sector_unpredicted_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.pair_req_fire)
                lookaside_sector_background_requests =
                    lookaside_sector_background_requests + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_background_deferred)
                lookaside_sector_background_deferred =
                    lookaside_sector_background_deferred + 1;
            if (dut.g_fetch_axi.u_fetch.pair_saved_count >
                lookaside_pair_stack_max_saved)
                lookaside_pair_stack_max_saved =
                    dut.g_fetch_axi.u_fetch.pair_saved_count;
            if (dut.icache_prefetch_valid &&
                dut.g_fetch_axi.u_fetch.alt_valid_q[0] &&
                dut.g_fetch_axi.u_fetch.alt_valid_q[1] &&
                !dut.g_fetch_axi.u_fetch.branch_predicted_stashed_r &&
                !dut.g_fetch_axi.u_fetch.branch_unpredicted_stashed_r)
                lookaside_full_branch_allocations =
                    lookaside_full_branch_allocations + 1;
            if (dut.fetch_pipe_resp_valid &&
                dut.fetch_pipe_resp_stash &&
                !dut.fetch_pipe_resp_access_fault &&
                !dut.fetch_pipe_resp_page_fault &&
                !dut.g_fetch_axi.u_fetch.alt_prefetch_aged_r) begin
                lookaside_store_fills = lookaside_store_fills + 1;
                if (dut.g_fetch_axi.u_fetch.alt_fill_match_r)
                    lookaside_store_duplicate_fills =
                        lookaside_store_duplicate_fills + 1;
                else if (dut.g_fetch_axi.u_fetch.alt_free_found_r)
                    lookaside_store_free_fills =
                        lookaside_store_free_fills + 1;
                else
                    lookaside_store_evictions =
                        lookaside_store_evictions + 1;
            end
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_issued_o)
                l1d_prefetch_issued = l1d_prefetch_issued + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_useful_o)
                l1d_prefetch_useful = l1d_prefetch_useful + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_late_o)
                l1d_prefetch_late = l1d_prefetch_late + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_dropped_o)
                l1d_prefetch_dropped = l1d_prefetch_dropped + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_useless_o)
                l1d_prefetch_useless = l1d_prefetch_useless + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_depth_o >
                l1d_prefetch_max_depth)
                l1d_prefetch_max_depth =
                    dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_depth_o;
        end

        if (!run_done)
            $fatal(1,
                "full-CCX workload timeout pc=%h instr=%h retired=%0d",
                dbg_pc, dbg_instr, retired);
        if (expected_a0_valid &&
            (dut.u_backend.u_gpr.regs[10] != expected_a0))
            $fatal(1, "full-CCX a0=%h expected=%h",
                dut.u_backend.u_gpr.regs[10], expected_a0);
        if (require_sv39 &&
            (!saw_sv39 || !saw_supervisor || !saw_sv39_alias_fetch ||
             !saw_sv39_alias_data || (ccx_ptw_reads < 3) ||
             (dtlb_fast_loads == 0) || (dtlb_fast_stores == 0)))
            $fatal(1,
                "Sv39 requirement failed: satp=%0b supervisor=%0b alias_fetch=%0b alias_data=%0b ptw_reads=%0d dtlb_fast_loads=%0d dtlb_fast_stores=%0d",
                saw_sv39, saw_supervisor, saw_sv39_alias_fetch,
                saw_sv39_alias_data, ccx_ptw_reads, dtlb_fast_loads,
                dtlb_fast_stores);
        ipc = (cycles != 0) ? $itor(retired) / $itor(cycles) : 0.0;
        $display(
            "PERF_CCX_L2 mode=%0d confidence_gate=%0d bp=%0d completion_forward_mask=%0d branch_forward_mask=%0d full_forwarding=%0d relax_waw=%0d relax_hazards=%0d issue_window=%0d speculation_window=%0d retire_depth=%0d posted_stores=%0d timed_memory=%0d memory_timing_model=%0d cycles=%0d retired=%0d IPC=%0.4f a0=%016h l1i_bytes=%0d l1d_bytes=%0d l2_bytes=%0d l2_ways=%0d ram_bytes=%0d",
            FETCH_ALT_LOOKASIDE, FETCH_ALT_CONFIDENCE_GATE, BP_TYPE,
            COMPLETION_FORWARD_MASK, BRANCH_COMPLETION_FORWARD_MASK,
            ENABLE_FULL_FORWARDING, RELAX_WAW, RELAX_HAZARDS,
            ISSUE_WINDOW, SPECULATION_WINDOW, RETIRE_DEPTH,
            ENABLE_POSTED_STORES, DDR3_ENABLE, MEMORY_TIMING_MODEL,
            cycles, retired, ipc,
            dut.u_backend.u_gpr.regs[10], L1I_CACHE_BYTES,
            L1D_CACHE_BYTES, L2_BYTES, L2_WAYS, RAM_BYTES);
        $display(
            "PERF_CCX_L2_TRAFFIC ccx_requests=%0d fetch_reads=%0d data_reads=%0d data_writes=%0d ptw_reads=%0d l2_axi_reads=%0d l2_axi_read_beats=%0d l2_axi_writes=%0d l2_axi_write_beats=%0d",
            ccx_requests, ccx_fetch_reads, ccx_data_reads,
            ccx_data_writes, ccx_ptw_reads, axi_read_transactions,
            axi_read_beats, axi_write_transactions,
            axi_write_beats);
        $display(
            "PERF_CCX_L2_VM required=%0b satp_sv39=%0b supervisor=%0b alias_fetch=%0b alias_data=%0b ptw_reads=%0d dtlb_fast_loads=%0d dtlb_fast_stores=%0d spec_load_base=%016h spec_load_size=%016h",
            require_sv39, saw_sv39, saw_supervisor,
            saw_sv39_alias_fetch, saw_sv39_alias_data, ccx_ptw_reads,
            dtlb_fast_loads, dtlb_fast_stores,
            SPEC_LOAD_BASE, SPEC_LOAD_SIZE);
        $display(
            "PERF_CCX_MAGIC source_mask=%x l1i_line_reads=%0d l1d_line_reads=%0d",
            magic_ccx_source_mask_q, magic_ccx_l1i_reads,
            magic_ccx_l1d_reads);
        if (DDR3_ENABLE != 0)
            $display(
                "PERF_MEMORY timing_model=%0d commands=%0d max_command_queue=%0d max_timing_owners=%0d max_l2_mshrs=%0d read_queue_depth=%0d write_queue_depth=%0d command_queue_depth=%0d",
                MEMORY_TIMING_MODEL,
                ddr3_commands, max_ddr3_queued, max_timing_owners,
                max_l2_mshrs, DDR3_READ_QUEUE_DEPTH,
                DDR3_WRITE_QUEUE_DEPTH, DDR3_COMMAND_QUEUE_DEPTH);
        if (DDR3_ENABLE != 0) begin
            $display(
                "PERF_MEMORY_CHANNEL read_bursts=%0d write_bursts=%0d read_beats_requested=%0d read_beats_returned=%0d write_beats_requested=%0d write_beats_received=%0d timing_read_commands=%0d timing_write_commands=%0d",
                memory_read_bursts, memory_write_bursts,
                memory_read_beats_requested, memory_read_beats_returned,
                memory_write_beats_requested, memory_write_beats_received,
                memory_timing_read_commands,
                memory_timing_write_commands);
            $display(
                "PERF_MEMORY_CHANNEL_WAIT ar_queue=%0d aw_queue=%0d w_queue=%0d r_backpressure=%0d b_backpressure=%0d read_timing=%0d write_timing=%0d timing_backend=%0d timing_owner_full=%0d max_read_queue=%0d max_write_queue=%0d max_timing_owners=%0d",
                memory_read_address_wait, memory_write_address_wait,
                memory_write_data_wait, memory_read_response_wait,
                memory_write_response_wait, memory_read_timing_wait,
                memory_write_timing_wait, memory_timing_backend_wait,
                memory_timing_owner_full, memory_max_read_queue,
                memory_max_write_queue, memory_max_timing_owners);
            $display(
                "PERF_MEMORY_CHANNEL_MERGE source_read_requests=%0d axi_read_bursts=%0d read_requests_merged=%0d axi_write_bursts=%0d write_requests_merged=%0d ddr_commands_coalesced=%0d ddr_reads_coalesced=%0d ddr_writes_coalesced=%0d ddr_coalesced_groups=%0d",
                u_complex.u_genbus.perf_axi_read_source_requests_q,
                u_complex.u_genbus.perf_axi_read_bursts_q,
                u_complex.u_genbus.perf_axi_read_merged_requests_q,
                u_complex.u_genbus.perf_axi_write_bursts_q,
                u_complex.u_genbus.perf_axi_write_merged_requests_q,
                memory_ddr_commands_coalesced,
                memory_ddr_reads_coalesced,
                memory_ddr_writes_coalesced,
                memory_ddr_coalesced_groups);
        end
        $display(
            "PERF_CCX_L2_FRONTEND direction_corrections=%0d target_corrections=%0d lookaside_restart_hits=%0d",
            direction_corrections, target_corrections,
            lookaside_restart_hits);
        $display(
            "PERF_CCX_L2_BP_TARGET btb_lookups=%0d btb_hits=%0d btb_misses=%0d btb_wrong_targets=%0d ras_lookups=%0d ras_hits=%0d ras_misses=%0d ras_wrong_targets=%0d",
            bp_btb_lookups, bp_btb_hits, bp_btb_misses,
            bp_btb_wrong_targets, bp_ras_lookups, bp_ras_hits,
            bp_ras_misses, bp_ras_wrong_targets);
        $display(
            "PERF_CCX_L2_LOOKASIDE pair_stack_depth=%0d eligible_restarts=%0d hits=%0d pair_overlaps=%0d pair_stack_overflows=%0d pair_stack_max_saved=%0d fills=%0d duplicate_fills=%0d free_fills=%0d evictions=%0d full_branch_allocations=%0d",
            FETCH_ALT_PAIR_STACK_DEPTH,
            lookaside_eligible_restarts, lookaside_restart_hits,
            lookaside_pair_replacements, lookaside_pair_stack_overflows,
            lookaside_pair_stack_max_saved, lookaside_store_fills,
            lookaside_store_duplicate_fills, lookaside_store_free_fills,
            lookaside_store_evictions, lookaside_full_branch_allocations);
        $display(
            "PERF_CCX_L2_SECTOR allocations=%0d predicted_free=%0d unpredicted_free=%0d response_taps=%0d predicted_taps=%0d unpredicted_taps=%0d background_requests=%0d background_deferred_cycles=%0d",
            lookaside_sector_allocations,
            lookaside_sector_predicted_free,
            lookaside_sector_unpredicted_free,
            lookaside_sector_response_taps,
            lookaside_sector_predicted_taps,
            lookaside_sector_unpredicted_taps,
            lookaside_sector_background_requests,
            lookaside_sector_background_deferred);
        $display(
            "PERF_CCX_L2_STASH_STALL episodes=%0d completed=%0d interrupted=%0d active=%0d requested=%0d stalled=%0d completed_stalled=%0d interrupted_stalled=%0d exposed_cycles=%0d completed_stall_cycles=%0d interrupted_stall_cycles=%0d same_line_cycles=%0d next_line_cycles=%0d preview_instr=%0d request_delay_sum=%0d request_delay_max=%0d response_delay_sum=%0d response_delay_max=%0d refill_latency_sum=%0d refill_latency_max=%0d",
            stash_trace_episodes, stash_trace_completed,
            stash_trace_interrupted, stash_trace_active,
            stash_trace_requested, stash_trace_stalled,
            stash_trace_completed_stalled,
            stash_trace_interrupted_stalled,
            stash_trace_exposed_stall_cycles,
            stash_trace_completed_stall_cycles,
            stash_trace_interrupted_stall_cycles,
            stash_trace_same_line_stall_cycles,
            stash_trace_next_line_stall_cycles,
            stash_trace_preview_instructions,
            stash_trace_request_delay_sum,
            stash_trace_request_delay_max,
            stash_trace_response_delay_sum,
            stash_trace_response_delay_max,
            stash_trace_refill_latency_sum,
            stash_trace_refill_latency_max);
        $display(
            "PERF_CCX_L2_STASH_OFFSET hits=%0d,%0d,%0d,%0d stalled=%0d,%0d,%0d,%0d stall_cycles=%0d,%0d,%0d,%0d",
            stash_trace_offset_hits[0], stash_trace_offset_hits[1],
            stash_trace_offset_hits[2], stash_trace_offset_hits[3],
            stash_trace_offset_stalled[0],
            stash_trace_offset_stalled[1],
            stash_trace_offset_stalled[2],
            stash_trace_offset_stalled[3],
            stash_trace_offset_stall_cycles[0],
            stash_trace_offset_stall_cycles[1],
            stash_trace_offset_stall_cycles[2],
            stash_trace_offset_stall_cycles[3]);
        $display(
            "PERF_CCX_L2_STASH_SECTOR hits=%0d,%0d stalled=%0d,%0d stall_cycles=%0d,%0d",
            stash_trace_sector_hits[0], stash_trace_sector_hits[1],
            stash_trace_sector_stalled[0],
            stash_trace_sector_stalled[1],
            stash_trace_sector_stall_cycles[0],
            stash_trace_sector_stall_cycles[1]);
        $display(
            "PERF_CCX_L2_PREFETCH enabled=%0d streams=%0d initial_depth=%0d adaptive=%0d max_depth_cfg=%0d max_depth_seen=%0d outstanding=%0d reserve=%0d issued=%0d useful=%0d late=%0d dropped=%0d useless=%0d",
            L1D_PREFETCH_ENABLE, L1D_PREFETCH_STREAMS,
            L1D_PREFETCH_DISTANCE, L1D_PREFETCH_ADAPTIVE_ENABLE,
            L1D_PREFETCH_MAX_DISTANCE, l1d_prefetch_max_depth,
            L1D_PREFETCH_OUTSTANDING, L1D_PREFETCH_DEMAND_RESERVE,
            l1d_prefetch_issued,
            l1d_prefetch_useful, l1d_prefetch_late,
            l1d_prefetch_dropped, l1d_prefetch_useless);
        $display(
            "PERF_CCX_L2_WIDTH issued=%0d decoded=%0d issue_w0=%0d issue_w1=%0d issue_w2=%0d issue_w3=%0d issue_w4=%0d decode_w0=%0d decode_w1=%0d decode_w2=%0d decode_w3=%0d retire_w0=%0d retire_w1=%0d retire_w2=%0d retire_w3=%0d",
            issued, decoded,
            issue_width_0, issue_width_1, issue_width_2, issue_width_3,
            issue_width_4,
            decode_width_0, decode_width_1, decode_width_2, decode_width_3,
            retire_width_0, retire_width_1, retire_width_2, retire_width_3);
        $display(
            "PERF_CCX_L2_BACKEND dispatch_nonempty=%0d dispatch_nonempty_no_issue=%0d dispatch_full=%0d raw_hazard=%0d waw_hazard=%0d read_port_hazard=%0d write_busy=%0d barrier=%0d",
            dispatch_nonempty, dispatch_nonempty_no_issue, dispatch_full,
            raw_hazard_cycles, waw_hazard_cycles, read_port_hazard_cycles,
            write_busy_cycles, barrier_cycles);
        $display(
            "PERF_CCX_L2_RAW first_block=%0d pending=%0d bundle=%0d completed=%0d secondary_only=%0d rs1=%0d rs2=%0d both=%0d lane0=%0d lane1=%0d lane2=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            raw_first_block_cycles, raw_first_pending_cycles,
            raw_first_bundle_cycles, raw_first_completed_cycles,
            raw_secondary_only_cycles, raw_first_rs1_cycles,
            raw_first_rs2_cycles, raw_first_both_sources_cycles,
            raw_first_lane0_cycles, raw_first_lane1_cycles,
            raw_first_lane2_cycles, raw_first_blocked_alu,
            raw_first_blocked_branch, raw_first_blocked_jump,
            raw_first_blocked_load, raw_first_blocked_store);
        $display(
            "PERF_CCX_L2_WINDOW enabled=%0d speculation=%0d nonempty_cycles=%0d no_eligible_cycles=%0d raw_stall_cycles=%0d hard_stall_cycles=%0d mem_order_stall_cycles=%0d unissued_entry_cycles=%0d operand_ready_entry_cycles=%0d eligible_entry_cycles=%0d raw_block_entry_cycles=%0d hard_block_entry_cycles=%0d mem_order_block_entry_cycles=%0d",
            ISSUE_WINDOW, SPECULATION_WINDOW, window_nonempty_cycles,
            window_no_eligible_cycles, window_raw_stall_cycles,
            window_hard_stall_cycles, window_mem_order_stall_cycles,
            window_unissued_entry_cycles,
            window_operand_ready_entry_cycles,
            window_eligible_entry_cycles,
            window_raw_block_entry_cycles,
            window_hard_block_entry_cycles,
            window_mem_order_block_entry_cycles);
        $display(
            "PERF_CCX_L2_RETIRE nonempty=%0d nonempty_no_retire=%0d head_incomplete=%0d completed_behind_head=%0d",
            retire_nonempty, retire_nonempty_no_retire,
            retire_head_incomplete, retire_completed_behind_head);
        $display(
            "PERF_CCX_L2_FETCH empty=%0d held=%0d request_wait=%0d control_empty=%0d refill_wait=%0d no_line=%0d bp_stall=%0d other_empty=%0d",
            frontend_empty, frontend_held, frontend_request_wait,
            frontend_control_empty, frontend_refill_wait, frontend_no_line,
            frontend_bp_stall, frontend_other_empty);
        $display(
            "PERF_CCX_L2_FETCH_CAUSAL empty_backend_ready=%0d empty_dispatch_empty=%0d empty_dispatch_empty_backend_ready=%0d empty_dispatch_empty_retire_empty=%0d empty_dispatch_nonempty=%0d empty_dispatch_full=%0d empty_l1i_external_miss=%0d empty_pending_no_external_miss=%0d",
            frontend_empty_backend_ready, frontend_empty_dispatch_empty,
            frontend_empty_dispatch_empty_backend_ready,
            frontend_empty_dispatch_empty_retire_empty,
            frontend_empty_dispatch_nonempty, frontend_empty_dispatch_full,
            frontend_empty_l1i_external_miss,
            frontend_empty_pending_no_external_miss);
        $display(
            "PERF_CCX_L2_LSU request_wait=%0d load_wait=%0d store_wait=%0d outstanding=%0d branch_resolutions=%0d conditional_branch_resolutions=%0d",
            lsu_request_wait, lsu_load_request_wait,
            lsu_store_request_wait, lsu_outstanding_cycles,
            branch_resolutions, conditional_branch_resolutions);
        $display(
            "PERF_CCX_L2_MEM_PORTS second_port_opportunities=%0d",
            lsu_second_port_opportunities);
        $display(
            "PERF_CCX_L2_BACKPRESSURE l1d_wait=%0d l1d_load_wait=%0d l1d_store_wait=%0d ccx_wait=%0d ccx_read_wait=%0d ccx_write_wait=%0d l2_bus_wait=%0d l2_command_full=%0d axi_ar_wait=%0d axi_aw_wait=%0d axi_w_wait=%0d",
            l1d_request_wait, l1d_load_request_wait,
            l1d_store_request_wait, ccx_request_wait,
            ccx_read_request_wait, ccx_write_request_wait,
            l2_bus_request_wait, l2_command_full_cycles,
            axi_read_address_wait, axi_write_address_wait,
            axi_write_data_wait);
        $display(
            "PERF_CCX_L2_L1D_WAIT store_block=%0d dirty_snoops=%0d lock_barrier=%0d response_tags=%0d refill=%0d access=%0d run_response=%0d unknown=%0d",
            l1d_wait_store_block, l1d_dirty_snoop_accepts,
            l1d_wait_lock_barrier,
            l1d_wait_response_tags, l1d_wait_refill,
            l1d_wait_access, l1d_wait_run_response,
            l1d_wait_unknown);
        $display(
            "PERF_CCX_L2_CONFLICT total=%0d ex0=%0d ex1=%0d mem=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            pipe_conflicts, pipe_conflicts_ex0, pipe_conflicts_ex1,
            pipe_conflicts_mem, conflict_blocked_alu,
            conflict_blocked_branch, conflict_blocked_jump,
            conflict_blocked_load, conflict_blocked_store);
        $display(
            "PERF_CCX_L2_CONFLICT_PAIR branch_alu=%0d alu_branch=%0d branch_branch=%0d alu_alu=%0d load_load=%0d store_load=%0d store_store=%0d other=%0d",
            conflict_pair_branch_alu, conflict_pair_alu_branch,
            conflict_pair_branch_branch, conflict_pair_alu_alu,
            conflict_pair_load_load, conflict_pair_store_load,
            conflict_pair_store_store, conflict_pair_other);
        if ((DDR3_ENABLE != 0) && (MEMORY_TIMING_MODEL == 0) &&
            $test$plusargs("require_ddr3_overlap") &&
            ((max_ddr3_queued < 2) || (max_timing_owners < 2)))
            $fatal(1,
                "DDR3 path did not overlap requests: queued=%0d owners=%0d",
                max_ddr3_queued, max_timing_owners);
        if ((DDR3_ENABLE != 0) &&
            $test$plusargs("require_timed_memory") &&
            (ddr3_commands == 0))
            $fatal(1, "timed-memory path accepted no commands");
        if (DDR3_ENABLE != 0)
            if (MEMORY_TIMING_MODEL == 1)
                $display(
                    "PASS: 3P L1I/L1D -> CCX -> L2 -> AXI -> magic memory");
            else
                $display(
                    "PASS: 3P L1I/L1D -> CCX -> L2 -> AXI -> banked DDR3");
        else
            $display(
                "PASS: 3P L1I/L1D -> CCX -> L2 -> 16 MiB AXI SRAM");
        $finish;
    end
endmodule
