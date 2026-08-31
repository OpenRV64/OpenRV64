`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"
`include "core/isa/rv64-priv.v"
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

// Burst-capable 256-bit AXI SRAM used behind the production ICX/L2 hierarchy.
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
                    $fatal(1, "full-ICX SRAM requires AXI INCR reads");
                if (arsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-ICX SRAM read beat is too wide");
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
                    $fatal(1, "full-ICX SRAM requires AXI INCR writes");
                if (awsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-ICX SRAM write beat is too wide");
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
                    $fatal(1, "full-ICX SRAM observed malformed WLAST");
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
//   3P core + private L1I/L1D -> native one-hart ICX -> shared L2
//       -> 512-to-256-bit generic bus adapter -> AXI SRAM or banked DDR3.
module tb_top_3p_soc #(
    parameter integer FETCH_CAROUSEL = 1,
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 1,
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
    parameter integer BANKED_GPR = 0,
    parameter integer FPGA_GPR_LUTRAM = 0,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer ENABLE_FENCE_L2_ACK = 1,
    parameter integer M_MODE_PREFETCH_ENABLE = 0,
    parameter integer ENABLE_RV64ZBB = 1,
    parameter integer RAM_BYTES = 16 * 1024 * 1024,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1I_FETCH_DATA_WIDTH =
        `OPENRV64_ICX_LINE_DATA_WIDTH,
    parameter integer L1I_DEMAND_MSHRS = 4,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_SYNC_TAG_LOOKUP = 1,
    parameter integer L1D_SYNC_STORE_EXTENSION = 1,
    parameter integer ENABLE_LSU_PAGE_SCREEN = 1,
    parameter integer L2_TLB_ENTRIES = 256,
    parameter integer L2_TLB_WAYS = 4,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 8,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer L1D_PREFETCH_STREAMS = 2,
    parameter integer L1D_PREFETCH_DISTANCE = 1,
    parameter integer L1D_PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter integer L1D_PREFETCH_QUEUE_LINES = 4,
    parameter integer L1D_PREFETCH_OUTSTANDING = 4,
    parameter integer L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter integer L1D_PREFETCH_PAGE_GATING = 1,
    parameter integer DDR3_ENABLE = 0,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer DDR3_MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer DDR3_BANK_ROW_SWIZZLE = 1,
    parameter integer MEMORY_TIMING_MODEL = 0
);
    reg clk;
    reg rst_n;

    wire core_axi_arvalid;
    wire core_axi_awvalid;
    wire core_axi_wvalid;

    wire icx_req_valid;
    wire icx_req_ready;
    wire complex_icx_req_valid;
    wire complex_icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    wire icx_wdata_valid;
    wire icx_wdata_ready;
    wire complex_icx_wdata_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    wire icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    wire icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    wire icx_resp_error;
    wire icx_resp_sc_success;
    wire complex_icx_resp_valid;
    wire complex_icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] complex_icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] complex_icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        complex_icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        complex_icx_resp_beat_index;
    wire complex_icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        complex_icx_resp_rdata;
    wire complex_icx_resp_error;
    wire complex_icx_resp_sc_success;

    /*
     * Directed Sv39 fence checker.
     *
     * In +fence_check mode, selected cacheable lines and the mapped device
     * page terminate here instead of at L2.  Completion is intentionally
     * delayed.  Ordering is checked when a successor request reaches this
     * external ICX/home boundary; dispatch or retirement state is not used as
     * the ordering oracle.
     */
    localparam [63:0] FENCE_TEST_BASE = 64'h0000_0000_8001_0000;
    localparam [63:0] FENCE_TEST_LIMIT = 64'h0000_0000_8001_2000;
    localparam [63:0] FENCE_SMC_LINE = 64'h0000_0000_8001_8000;
    localparam [63:0] FENCE_DEVICE_BASE = 64'h0000_0000_1000_0000;
    localparam [63:0] FENCE_DEVICE_LIMIT = 64'h0000_0000_1000_1000;
    localparam integer FENCE_QUEUE_DEPTH = 32;
    localparam integer FENCE_QUEUE_INDEX_WIDTH =
        $clog2(FENCE_QUEUE_DEPTH);
    localparam integer FENCE_SHADOW_DEPTH = 64;
    localparam integer FENCE_SHADOW_INDEX_WIDTH =
        $clog2(FENCE_SHADOW_DEPTH);
    localparam integer FENCE_RESPONSE_DELAY = 24;

    reg fence_check_enabled_q;
    reg fence_trace_enabled_q;
    integer fence_case_q;
    wire fence_test_dcache_request =
        icx_req_source_id == `OPENRV64_ICX_SOURCE_DCACHE &&
        (((icx_req_addr >= FENCE_TEST_BASE) &&
          (icx_req_addr < FENCE_TEST_LIMIT)) ||
         (icx_req_addr == FENCE_SMC_LINE) ||
         ((icx_req_addr >= FENCE_DEVICE_BASE) &&
          (icx_req_addr < FENCE_DEVICE_LIMIT)));
    wire fence_test_icache_request =
        (icx_req_source_id == `OPENRV64_ICX_SOURCE_ICACHE) &&
        (icx_req_addr == FENCE_SMC_LINE);
    wire fence_icx_select = fence_check_enabled_q &&
        (fence_test_dcache_request || fence_test_icache_request);

    reg fence_queue_valid_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        fence_queue_hart_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        fence_queue_txn_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        fence_queue_source_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_OP_WIDTH-1:0]
        fence_queue_op_q [0:FENCE_QUEUE_DEPTH-1];
    reg [63:0] fence_queue_addr_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fence_queue_wdata_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        fence_queue_wstrb_q [0:FENCE_QUEUE_DEPTH-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fence_queue_rdata_q [0:FENCE_QUEUE_DEPTH-1];
    reg [FENCE_SHADOW_INDEX_WIDTH-1:0]
        fence_queue_shadow_q [0:FENCE_QUEUE_DEPTH-1];
    integer fence_queue_delay_q [0:FENCE_QUEUE_DEPTH-1];
    reg fence_queue_space_r;
    reg [FENCE_QUEUE_INDEX_WIDTH-1:0] fence_queue_free_index_r;
    reg fence_queue_response_found_r;
    reg [FENCE_QUEUE_INDEX_WIDTH-1:0] fence_queue_response_index_r;
    integer fence_queue_scan;
    integer fence_queue_reset_scan;

    reg fence_shadow_valid_q [0:FENCE_SHADOW_DEPTH-1];
    reg [63:0] fence_shadow_addr_q [0:FENCE_SHADOW_DEPTH-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fence_shadow_data_q [0:FENCE_SHADOW_DEPTH-1];
    reg fence_shadow_match_r;
    reg [FENCE_SHADOW_INDEX_WIDTH-1:0] fence_shadow_match_index_r;
    reg fence_shadow_space_r;
    reg [FENCE_SHADOW_INDEX_WIDTH-1:0] fence_shadow_free_index_r;
    integer fence_shadow_scan;
    integer fence_shadow_reset_scan;
    integer fence_shadow_write_byte;

    reg fence_resp_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] fence_resp_hart_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] fence_resp_txn_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] fence_resp_source_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] fence_resp_rdata_q;
    wire fence_resp_fire = fence_resp_valid_q && icx_resp_ready;
    wire fence_icx_req_fire =
        icx_req_valid && icx_req_ready && fence_icx_select;

    reg fence_ww_pred_done_q;
    reg fence_wr_pred_done_q;
    reg fence_rr_pred_done_q;
    reg fence_rw_pred_done_q;
    reg fence_oo_pred_done_q;
    reg fence_oi_pred_done_q;
    reg fence_ii_pred_done_q;
    reg fence_io_pred_done_q;
    reg fence_partial_done_q;
    reg [11:0] fence_pressure_done_q;
    reg fence_smc_store_seen_q;
    reg fence_smc_store_done_q;
    integer fence_smc_fetches_q;
    reg fence_ww_succ_seen_q;
    reg fence_wr_succ_seen_q;
    reg fence_rr_succ_seen_q;
    reg fence_rw_succ_seen_q;
    reg fence_oo_succ_seen_q;
    reg fence_oi_succ_seen_q;
    reg fence_ii_succ_seen_q;
    reg fence_io_succ_seen_q;
    reg fence_partial_succ_seen_q;
    reg fence_pressure_succ_seen_q;
    reg fence_final_store_done_q;
    reg [10:0] fence_order_violation_q;
    reg fence_smc_pending_valid_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fence_smc_forward_data_q;
    integer fence_external_requests_q;
    integer fence_external_completions_q;
    integer fence_retired_q;
    integer fence_i_retired_q;
    integer sfence_vma_retired_q;

    // Simulation-only, initiator-keyed ICX latency bisection.  Selected
    // private-cache line reads obtain their data directly from the testbench
    // backing store; writes and narrower/uncached requests still traverse L2.
    reg [3:0] magic_icx_source_mask_q;
    integer magic_icx_source_mask_arg;
    reg magic_icx_resp_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        magic_icx_resp_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        magic_icx_resp_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        magic_icx_resp_source_id_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        magic_icx_resp_rdata_q;
    localparam integer MAGIC_ICX_SHADOW_DEPTH = 32;
    localparam integer MAGIC_ICX_SHADOW_INDEX_WIDTH =
        $clog2(MAGIC_ICX_SHADOW_DEPTH);
    reg magic_icx_shadow_valid_q [0:MAGIC_ICX_SHADOW_DEPTH-1];
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        magic_icx_shadow_hart_id_q [0:MAGIC_ICX_SHADOW_DEPTH-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        magic_icx_shadow_txn_id_q [0:MAGIC_ICX_SHADOW_DEPTH-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        magic_icx_shadow_source_id_q [0:MAGIC_ICX_SHADOW_DEPTH-1];
    reg magic_icx_shadow_space_r;
    reg [MAGIC_ICX_SHADOW_INDEX_WIDTH-1:0]
        magic_icx_shadow_free_index_r;
    reg magic_icx_shadow_resp_match_r;
    reg [MAGIC_ICX_SHADOW_INDEX_WIDTH-1:0]
        magic_icx_shadow_resp_index_r;
    integer magic_icx_shadow_free_scan;
    integer magic_icx_shadow_resp_scan;
    integer magic_icx_shadow_reset_scan;
    integer magic_icx_l1i_reads;
    integer magic_icx_l1d_reads;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] magic_icx_read_data;
    localparam integer MAGIC_ICX_RAM_WORDS = RAM_BYTES / 32;
    localparam integer MAGIC_ICX_RAM_INDEX_WIDTH =
        $clog2(MAGIC_ICX_RAM_WORDS);
    wire [63:0] magic_icx_local_addr =
        icx_req_addr - `OPENRV64_SOC_MEMORY_BASE;
    wire [MAGIC_ICX_RAM_INDEX_WIDTH-1:0] magic_icx_word_index =
        magic_icx_local_addr[
            5 +: MAGIC_ICX_RAM_INDEX_WIDTH];
    wire magic_icx_ram_line =
        (icx_req_addr >= `OPENRV64_SOC_MEMORY_BASE) &&
        (icx_req_addr <=
         (`OPENRV64_SOC_MEMORY_BASE + RAM_BYTES - 64)) &&
        (icx_req_addr[5:0] == 6'd0);
    wire magic_icx_source_selected =
        magic_icx_source_mask_q[icx_req_source_id];
    wire magic_icx_req_select =
        magic_icx_source_selected &&
        (icx_req_op == `OPENRV64_ICX_OP_READ) &&
        (icx_req_size == 3'd6) &&
        (icx_req_burst_len == 0) &&
        |(icx_req_attr & `OPENRV64_ICX_ATTR_CACHEABLE) &&
        magic_icx_ram_line;
    wire magic_icx_resp_fire =
        magic_icx_resp_valid_q && icx_resp_ready;
    wire magic_icx_resp_slot_ready =
        !magic_icx_resp_valid_q || magic_icx_resp_fire;
    wire magic_icx_req_fire =
        icx_req_valid && icx_req_ready && magic_icx_req_select;
    wire magic_icx_shadow_resp_fire =
        complex_icx_resp_valid && complex_icx_resp_ready &&
        magic_icx_shadow_resp_match_r;

    always @* begin
        fence_queue_space_r = 1'b0;
        fence_queue_free_index_r =
            {FENCE_QUEUE_INDEX_WIDTH{1'b0}};
        fence_queue_response_found_r = 1'b0;
        fence_queue_response_index_r =
            {FENCE_QUEUE_INDEX_WIDTH{1'b0}};
        for (fence_queue_scan = 0;
             fence_queue_scan < FENCE_QUEUE_DEPTH;
             fence_queue_scan = fence_queue_scan + 1) begin
            if (!fence_queue_space_r &&
                !fence_queue_valid_q[fence_queue_scan]) begin
                fence_queue_space_r = 1'b1;
                fence_queue_free_index_r =
                    fence_queue_scan[FENCE_QUEUE_INDEX_WIDTH-1:0];
            end
            if (!fence_queue_response_found_r &&
                fence_queue_valid_q[fence_queue_scan] &&
                (fence_queue_delay_q[fence_queue_scan] == 0)) begin
                fence_queue_response_found_r = 1'b1;
                fence_queue_response_index_r =
                    fence_queue_scan[FENCE_QUEUE_INDEX_WIDTH-1:0];
            end
        end
    end

    always @* begin
        fence_shadow_match_r = 1'b0;
        fence_shadow_match_index_r =
            {FENCE_SHADOW_INDEX_WIDTH{1'b0}};
        fence_shadow_space_r = 1'b0;
        fence_shadow_free_index_r =
            {FENCE_SHADOW_INDEX_WIDTH{1'b0}};
        for (fence_shadow_scan = 0;
             fence_shadow_scan < FENCE_SHADOW_DEPTH;
             fence_shadow_scan = fence_shadow_scan + 1) begin
            if (!fence_shadow_match_r &&
                fence_shadow_valid_q[fence_shadow_scan] &&
                (fence_shadow_addr_q[fence_shadow_scan] ==
                 {icx_req_addr[63:6], 6'b0})) begin
                fence_shadow_match_r = 1'b1;
                fence_shadow_match_index_r =
                    fence_shadow_scan[FENCE_SHADOW_INDEX_WIDTH-1:0];
            end
            if (!fence_shadow_space_r &&
                !fence_shadow_valid_q[fence_shadow_scan]) begin
                fence_shadow_space_r = 1'b1;
                fence_shadow_free_index_r =
                    fence_shadow_scan[FENCE_SHADOW_INDEX_WIDTH-1:0];
            end
        end
    end

    wire fence_icx_write =
        icx_req_op == `OPENRV64_ICX_OP_WRITE;
    wire fence_icx_read =
        icx_req_op == `OPENRV64_ICX_OP_READ;
    wire fence_icx_can_accept = fence_queue_space_r &&
        (fence_shadow_match_r || fence_shadow_space_r) &&
        (fence_icx_read || fence_icx_write) &&
        (!fence_icx_write || icx_wdata_valid);

    // Fence-check requests terminate in the delayed external model.  Existing
    // magic-read requests are still accepted by L2 for normal fill behavior.
    assign icx_req_ready = fence_icx_select ?
        fence_icx_can_accept :
        (complex_icx_req_ready &&
         (!magic_icx_req_select ||
          (magic_icx_resp_slot_ready && magic_icx_shadow_space_r)));
    assign complex_icx_req_valid =
        icx_req_valid && !fence_icx_select &&
        (!magic_icx_req_select ||
         (magic_icx_resp_slot_ready && magic_icx_shadow_space_r));
    assign icx_wdata_ready = fence_icx_select ?
        (icx_req_valid && fence_icx_can_accept) :
        complex_icx_wdata_ready;

    assign icx_resp_valid =
        fence_resp_valid_q || magic_icx_resp_valid_q ||
        (complex_icx_resp_valid && !magic_icx_shadow_resp_match_r);
    assign icx_resp_hart_id = fence_resp_valid_q ?
        fence_resp_hart_q : magic_icx_resp_valid_q ?
        magic_icx_resp_hart_id_q : complex_icx_resp_hart_id;
    assign icx_resp_txn_id = fence_resp_valid_q ?
        fence_resp_txn_q : magic_icx_resp_valid_q ?
        magic_icx_resp_txn_id_q : complex_icx_resp_txn_id;
    assign icx_resp_source_id = fence_resp_valid_q ?
        fence_resp_source_q : magic_icx_resp_valid_q ?
        magic_icx_resp_source_id_q : complex_icx_resp_source_id;
    assign icx_resp_beat_index =
        (fence_resp_valid_q || magic_icx_resp_valid_q) ?
        {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}} :
        complex_icx_resp_beat_index;
    assign icx_resp_last =
        (fence_resp_valid_q || magic_icx_resp_valid_q) ?
        1'b1 : complex_icx_resp_last;
    assign icx_resp_rdata = fence_resp_valid_q ?
        fence_resp_rdata_q : magic_icx_resp_valid_q ?
        magic_icx_resp_rdata_q : complex_icx_resp_rdata;
    assign icx_resp_error =
        (fence_resp_valid_q || magic_icx_resp_valid_q) ?
        1'b0 : complex_icx_resp_error;
    assign icx_resp_sc_success =
        (fence_resp_valid_q || magic_icx_resp_valid_q) ?
        1'b0 : complex_icx_resp_sc_success;
    assign complex_icx_resp_ready =
        magic_icx_shadow_resp_match_r ||
        (icx_resp_ready && !fence_resp_valid_q &&
         !magic_icx_resp_valid_q);

    always @* begin
        magic_icx_shadow_space_r = 1'b0;
        magic_icx_shadow_free_index_r =
            {MAGIC_ICX_SHADOW_INDEX_WIDTH{1'b0}};
        for (magic_icx_shadow_free_scan = 0;
             magic_icx_shadow_free_scan < MAGIC_ICX_SHADOW_DEPTH;
             magic_icx_shadow_free_scan = magic_icx_shadow_free_scan + 1)
            if (!magic_icx_shadow_space_r &&
                !magic_icx_shadow_valid_q[magic_icx_shadow_free_scan]) begin
                magic_icx_shadow_space_r = 1'b1;
                magic_icx_shadow_free_index_r =
                    magic_icx_shadow_free_scan[
                        MAGIC_ICX_SHADOW_INDEX_WIDTH-1:0];
            end
    end

    always @* begin
        magic_icx_shadow_resp_match_r = 1'b0;
        magic_icx_shadow_resp_index_r =
            {MAGIC_ICX_SHADOW_INDEX_WIDTH{1'b0}};
        for (magic_icx_shadow_resp_scan = 0;
             magic_icx_shadow_resp_scan < MAGIC_ICX_SHADOW_DEPTH;
             magic_icx_shadow_resp_scan = magic_icx_shadow_resp_scan + 1)
            if (!magic_icx_shadow_resp_match_r &&
                magic_icx_shadow_valid_q[magic_icx_shadow_resp_scan] &&
                (magic_icx_shadow_hart_id_q[magic_icx_shadow_resp_scan] ==
                 complex_icx_resp_hart_id) &&
                (magic_icx_shadow_txn_id_q[magic_icx_shadow_resp_scan] ==
                 complex_icx_resp_txn_id) &&
                (magic_icx_shadow_source_id_q[magic_icx_shadow_resp_scan] ==
                 complex_icx_resp_source_id)) begin
                magic_icx_shadow_resp_match_r = 1'b1;
                magic_icx_shadow_resp_index_r =
                    magic_icx_shadow_resp_scan[
                        MAGIC_ICX_SHADOW_INDEX_WIDTH-1:0];
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
    wire [63:0] memory_read_single_beat_bursts;
    wire [63:0] memory_read_two_beat_bursts;
    wire [63:0] memory_read_other_bursts;
    wire [63:0] memory_write_single_beat_bursts;
    wire [63:0] memory_write_two_beat_bursts;
    wire [63:0] memory_write_other_bursts;
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
    wire [63:0] memory_ddr_active_cycles;
    wire [63:0] memory_ddr_command_queue_entry_cycles;
    wire [63:0] memory_ddr_command_queue_full_cycles;
    wire [63:0] memory_ddr_command_input_wait_cycles;
    wire [63:0] memory_ddr_command_refresh_wait_cycles;
    wire [63:0] memory_ddr_bus_busy_cycles;
    wire [63:0] memory_ddr_bus_read_cycles;
    wire [63:0] memory_ddr_bus_write_cycles;
    wire [63:0] memory_ddr_bus_launches;
    wire [63:0] memory_ddr_bus_read_launches;
    wire [63:0] memory_ddr_bus_write_launches;
    wire [63:0] memory_ddr_bus_bank_wait_cycles;
    wire [63:0] memory_ddr_bus_queue_wait_cycles;
    wire [63:0] memory_ddr_bank_busy_entry_cycles;
    wire [63:0] memory_ddr_max_busy_banks;
    wire [63:0] memory_ddr_row_hit_commands;
    wire [63:0] memory_ddr_row_miss_commands;
    wire [63:0] memory_ddr_row_conflict_commands;
    wire [63:0] memory_ddr_row_empty_commands;
    wire [63:0] memory_ddr_native_bursts;
    wire [63:0] memory_ddr_full_native_commands;
    wire [63:0] memory_ddr_partial_native_commands;
    wire [63:0] memory_ddr_multi_native_commands;
    wire [63:0] memory_ddr_burst_trains;
    wire [63:0] memory_ddr_single_burst_trains;
    wire [63:0] memory_ddr_two_burst_trains;
    wire [63:0] memory_ddr_three_burst_trains;
    wire [63:0] memory_ddr_four_burst_trains;
    wire [63:0] memory_ddr_five_burst_trains;
    wire [63:0] memory_ddr_six_burst_trains;
    wire [63:0] memory_ddr_seven_burst_trains;
    wire [63:0] memory_ddr_eight_burst_trains;
    wire [63:0] memory_ddr_long_burst_trains;
    wire [63:0] memory_ddr_direction_switches;
    wire [63:0] memory_ddr_refresh_cycles;
    wire [63:0] memory_ddr_refresh_events;
    wire [63:0] memory_ddr_refresh_deferred_cycles;

    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;

    integer cycles;
    integer max_cycles;
    integer retired;
    integer progress_interval_cycles;
    integer progress_next_cycle;
    integer icx_requests;
    integer icx_fetch_reads;
    integer icx_data_reads;
    integer icx_data_writes;
    integer icx_ptw_reads;
    integer dtlb_fast_loads;
    integer dtlb_fast_stores;
    integer dtlb_access_overlap_loads;
    integer dtlb_serial_loads;
    integer dtlb_serial_stores;
    integer l1d_store_extensions;
    reg require_sv39;
    reg require_sv39_active;
    reg require_zero_scatter;
    reg saw_sv39;
    reg saw_supervisor;
    reg saw_sv39_alias_fetch;
    reg saw_sv39_alias_data;
    integer zero_scatter_xlates;
    integer zero_scatter_accesses;
    integer zero_scatter_mapping_errors;
    reg [63:0] zero_scatter_expected_paddr;
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
    integer l1i_next_line_hints;
    integer l1i_next_line_enqueues;
    integer l1i_prefetch_probes;
    integer l1i_prefetch_miss_completions;
    integer l1d_prefetch_issued;
    integer l1d_prefetch_useful;
    integer l1d_prefetch_on_time_useful;
    integer l1d_prefetch_late_useful;
    integer l1d_prefetch_late;
    integer l1d_prefetch_late_queued;
    integer l1d_prefetch_late_command;
    integer l1d_prefetch_late_mshr;
    integer l1d_prefetch_dropped;
    integer l1d_prefetch_useless;
    integer l1d_prefetch_max_depth;
    integer l1d_prefetch_trace_fd;
    reg [1023:0] l1d_prefetch_trace_path;
    integer l1d_prefetch_trace_scan;
    integer l1d_prefetch_trace_queue_occupancy;
    integer l1d_prefetch_trace_mshr_occupancy;
    integer l1d_prefetch_trace_long_mask;
    integer l1d_store_poison_any_events;
    integer l1d_store_poison_prefetch_events;
    integer l1d_store_poison_prefetch_queue;
    integer l1d_store_poison_prefetch_command;
    integer l1d_store_poison_prefetch_mshr;
    integer l1d_store_poison_prefetch_fill;
    integer l1d_store_poison_demand_events;
    integer l1d_store_poison_demand_wait_prefetch;
    integer l1d_store_poison_demand_fill;
    integer l1d_store_overlay_demand_mshr;
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
    integer completed_control_load_candidate_cycles;
    integer completed_control_load_gate_cycles;
    integer completed_control_load_candidate_entry_cycles;
    integer completed_control_load_gate_entry_cycles;
    integer waw_hazard_cycles;
    integer read_port_hazard_cycles;
    integer write_busy_cycles;
    integer barrier_cycles;
    integer retire_nonempty;
    integer retire_nonempty_no_retire;
    integer retire_head_incomplete;
    integer retire_completed_behind_head;
    integer retire_head_wait_alu;
    integer retire_head_wait_branch;
    integer retire_head_wait_jump;
    integer retire_head_wait_load;
    integer retire_head_wait_store;
    integer retire_head_mem_lsq_absent;
    integer retire_head_mem_absent_unissued;
    integer retire_head_mem_absent_issued;
    integer retire_head_mem_absent_result;
    integer retire_head_mem_absent_complete;
    integer retire_head_mem_wait_xlate;
    integer retire_head_mem_wait_access;
    integer retire_head_mem_access_inflight;
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
    integer fetch_page_screen_requests;
    integer fetch_page_screen_hits;
    integer fetch_page_screen_redirect_hits;
    integer fetch_page_screen_predicted_hits;
    integer fetch_page_screen_correction_hits;
    integer fetch_page_screen_fills;
    integer fetch_page_screen_launches;
    integer fetch_page_screen_bypasses;
    integer fetch_page_screen_invalidates;
    integer lsu_page_screen_requests;
    integer lsu_page_screen_store_requests;
    integer lsu_page_screen_hits;
    integer lsu_page_screen_store_hits;
    integer lsu_page_screen_fills;
    integer lsu_page_screen_invalidates;
    integer fetch_redirect_events;
    integer fetch_predicted_redirect_events;
    integer fetch_correction_redirect_events;
    integer fetch_target_correction_events;
    integer fetch_control_restart_events;
    integer fetch_exception_redirect_events;
    integer fetch_other_redirect_events;
    integer fetch_redirect_lookaside_hits;
    integer fetch_predicted_redirect_lookaside_hits;
    integer fetch_correction_redirect_lookaside_hits;
    integer fetch_correction_lookaside_no_context;
    integer fetch_correction_lookaside_context_pending;
    integer fetch_correction_lookaside_context_not_pending;
    integer post_redirect_completed_events;
    integer post_redirect_superseded_events;
    integer post_redirect_stalled_events;
    integer post_redirect_zero_stall_events;
    integer post_redirect_empty_cycles;
    integer post_redirect_critical_empty_cycles;
    integer post_redirect_current_pending_cycles;
    integer post_redirect_other_pending_cycles;
    integer post_redirect_no_pending_cycles;
    integer post_redirect_external_miss_cycles;
    integer post_redirect_request_wait_cycles;
    integer post_redirect_predicted_empty_cycles;
    integer post_redirect_correction_empty_cycles;
    integer post_redirect_restart_empty_cycles;
    integer post_redirect_other_empty_cycles;
    integer post_redirect_lookaside_hit_empty_cycles;
    integer post_redirect_lookaside_miss_empty_cycles;
    integer post_redirect_lookaside_hit_stalled_events;
    integer post_redirect_lookaside_hit_zero_stall_events;
    integer post_redirect_lookaside_miss_stalled_events;
    integer post_redirect_lookaside_miss_zero_stall_events;
    integer post_redirect_correction_lookaside_hit_empty_cycles;
    integer post_redirect_correction_no_context_empty_cycles;
    integer post_redirect_correction_context_pending_empty_cycles;
    integer post_redirect_correction_context_not_pending_empty_cycles;
    integer post_redirect_episode_cycles;
    integer post_redirect_max_empty_cycles;
    integer post_redirect_completed_empty_cycles;
    integer post_redirect_superseded_empty_cycles;
    integer post_redirect_hist [0:13];
    integer post_redirect_predicted_hist [0:13];
    integer post_redirect_correction_hist [0:13];
    integer post_redirect_hist_bucket;
    integer post_redirect_hist_init;
    reg post_redirect_active;
    reg post_redirect_lookaside_hit;
    reg [1:0] post_redirect_correction_miss_reason;
    reg [1:0] post_redirect_kind;
    localparam integer REDIRECT_CYCLE_TRACE_DEPTH = 512;
    integer redirect_cycle_trace_enabled;
    integer redirect_cycle_trace_skip;
    integer redirect_cycle_trace_limit;
    integer redirect_cycle_trace_seen;
    integer redirect_cycle_trace_captured;
    integer redirect_cycle_trace_superseded;
    integer redirect_cycle_trace_length;
    integer redirect_cycle_trace_empty;
    integer redirect_cycle_trace_start;
    integer redirect_cycle_trace_kind;
    integer redirect_cycle_trace_index;
    integer redirect_cycle_trace_scan;
    reg redirect_cycle_trace_active;
    reg redirect_cycle_trace_truncated;
    reg [63:0] redirect_cycle_trace_target;
    integer redirect_cycle_trace_cycle [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg [2:0] redirect_cycle_trace_decode [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_req_valid [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_req_ready [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_req_target [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_req_stash [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_req_demand [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_mtl_match [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg [1:0] redirect_cycle_trace_mtl_slot [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg [2:0] redirect_cycle_trace_mtl_state [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg [11:0] redirect_cycle_trace_mtl_states [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_xlate [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg [1:0] redirect_cycle_trace_xlate_slot [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_pmp_fetch [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_l1_launch [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_screen_hit [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_screen_launch
        [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_screen_bypass
        [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_l1_req_valid [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_l1_req_fire [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_l1_resp [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_pipe_resp [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_pipe_resp_target [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_ingress_hit [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_line_hit [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_redirect_pending [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    reg redirect_cycle_trace_external_miss [0:REDIRECT_CYCLE_TRACE_DEPTH-1];
    integer fetch_demand_trace_enabled;
    integer fetch_demand_trace_cycle_q;
    integer fetch_demand_trace_start_q [0:3];
    integer fetch_demand_trace_external_q [0:3];
    integer fetch_demand_trace_empty_q [0:3];
    reg fetch_demand_trace_valid_q [0:3];
    reg [63:0] fetch_demand_trace_addr_q [0:3];
    reg [63:0] fetch_demand_trace_pc_q [0:3];
    integer fetch_demand_trace_scan;
    integer fetch_demand_trace_match;
    integer fetch_demand_trace_free;
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
    integer icx_request_wait;
    integer icx_read_request_wait;
    integer icx_write_request_wait;
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
        input [`OPENRV64_RETIRE_ALLOC_WIDTH-1:0] payload;
        begin
            if (payload[`OPENRV64_RETIRE_ALLOC_BRANCH_BIT])
                perf_op_class = PERF_OP_BRANCH;
            else if (payload[`OPENRV64_RETIRE_ALLOC_JUMP_BIT])
                perf_op_class = PERF_OP_JUMP;
            else if (payload[`OPENRV64_RETIRE_ALLOC_MEM_READ_BIT] &&
                     !payload[`OPENRV64_RETIRE_ALLOC_MEM_WRITE_BIT])
                perf_op_class = PERF_OP_LOAD;
            else if (payload[`OPENRV64_RETIRE_ALLOC_MEM_WRITE_BIT])
                perf_op_class = PERF_OP_STORE;
            else
                perf_op_class = PERF_OP_ALU;
        end
    endfunction

    wire [`OPENRV64_RETIRE_ALLOC_WIDTH-1:0]
        trace_retire_head_payload =
            dut.u_backend.queue_retire_record[
                0 +: `OPENRV64_RETIRE_ALLOC_WIDTH];
    wire [2:0] trace_retire_head_op =
        perf_op_class(trace_retire_head_payload);
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] trace_retire_head_id =
        dut.u_backend.u_retire_queue.id_q[
            dut.u_backend.u_retire_queue.head_q];
    reg trace_retire_head_lsq_valid;
    reg trace_retire_head_lsq_xlate_done;
    reg trace_retire_head_lsq_access_sent;
    reg trace_retire_head_window_valid;
    reg trace_retire_head_window_issued;
    integer trace_retire_head_lsq_index;
    integer trace_retire_head_window_index;
    always @* begin
        trace_retire_head_lsq_valid = 1'b0;
        trace_retire_head_lsq_xlate_done = 1'b0;
        trace_retire_head_lsq_access_sent = 1'b0;
        trace_retire_head_window_valid = 1'b0;
        trace_retire_head_window_issued = 1'b0;
        for (trace_retire_head_lsq_index = 0;
             trace_retire_head_lsq_index < `OPENRV64_LSU_OUTSTANDING;
             trace_retire_head_lsq_index =
                 trace_retire_head_lsq_index + 1) begin
            if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                    .slot_valid_q[trace_retire_head_lsq_index] &&
                (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                    .slot_id_q[trace_retire_head_lsq_index] ==
                 trace_retire_head_id)) begin
                trace_retire_head_lsq_valid = 1'b1;
                trace_retire_head_lsq_xlate_done =
                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                        .slot_xlate_done_q[trace_retire_head_lsq_index];
                trace_retire_head_lsq_access_sent =
                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                        .slot_access_sent_q[trace_retire_head_lsq_index];
            end
        end
        for (trace_retire_head_window_index = 0;
             trace_retire_head_window_index < 16;
             trace_retire_head_window_index =
                 trace_retire_head_window_index + 1) begin
            if (dut.u_backend.u_dispatch.g_3p.u_window
                    .valid_q[trace_retire_head_window_index] &&
                (dut.u_backend.u_dispatch.g_3p.u_window
                    .id_q[trace_retire_head_window_index] ==
                 trace_retire_head_id)) begin
                trace_retire_head_window_valid = 1'b1;
                trace_retire_head_window_issued =
                    dut.u_backend.u_dispatch.g_3p.u_window.issued_q[
                        trace_retire_head_window_index];
            end
        end
    end
    wire trace_retire_head_lsq_result =
        dut.u_backend.u_exec.g_3p.u_exec.u_lsu.lsq_result_valid &&
        (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.lsq_result_id ==
         trace_retire_head_id);
    wire trace_retire_head_lsu_complete =
        dut.u_backend.u_exec.g_3p.u_exec.u_lsu.complete_valid_q &&
        (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.complete_id_q ==
         trace_retire_head_id);

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
    reg run_completed_q;

    always @(posedge clk) begin
        if (!rst_n)
            l1d_store_extensions <= 0;
        else if (dut.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.g_cache
                     .u_cache.sync_store_extension_fire)
            l1d_store_extensions <= l1d_store_extensions + 1;
    end

    localparam integer RETIRE_RESULT_INSTR_LSB = 233;
    wire [31:0] fence_retire_instr0 =
        dut.u_backend.queue_retire_result[
            0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
            RETIRE_RESULT_INSTR_LSB +: 32];
    wire [31:0] fence_retire_instr1 =
        dut.u_backend.queue_retire_result[
            1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
            RETIRE_RESULT_INSTR_LSB +: 32];
    wire [31:0] fence_retire_instr2 =
        dut.u_backend.queue_retire_result[
            2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
            RETIRE_RESULT_INSTR_LSB +: 32];
    wire fence_retire0 = dut.backend_retire_arch[0] &&
        (`RV64_OPCODE(fence_retire_instr0) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr0) == 3'b000);
    wire fence_retire1 = dut.backend_retire_arch[1] &&
        (`RV64_OPCODE(fence_retire_instr1) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr1) == 3'b000);
    wire fence_retire2 = dut.backend_retire_arch[2] &&
        (`RV64_OPCODE(fence_retire_instr2) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr2) == 3'b000);
    wire fence_i_retire0 = dut.backend_retire_arch[0] &&
        (`RV64_OPCODE(fence_retire_instr0) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr0) == 3'b001);
    wire fence_i_retire1 = dut.backend_retire_arch[1] &&
        (`RV64_OPCODE(fence_retire_instr1) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr1) == 3'b001);
    wire fence_i_retire2 = dut.backend_retire_arch[2] &&
        (`RV64_OPCODE(fence_retire_instr2) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(fence_retire_instr2) == 3'b001);
    wire sfence_vma_retire0 = dut.backend_retire_arch[0] &&
        `RV64_IS_SFENCE_VMA(fence_retire_instr0);
    wire sfence_vma_retire1 = dut.backend_retire_arch[1] &&
        `RV64_IS_SFENCE_VMA(fence_retire_instr1);
    wire sfence_vma_retire2 = dut.backend_retire_arch[2] &&
        `RV64_IS_SFENCE_VMA(fence_retire_instr2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fence_retired_q <= 0;
            fence_i_retired_q <= 0;
            sfence_vma_retired_q <= 0;
        end else begin
            fence_retired_q <= fence_retired_q +
                fence_retire0 + fence_retire1 + fence_retire2;
            fence_i_retired_q <= fence_i_retired_q +
                fence_i_retire0 + fence_i_retire1 + fence_i_retire2;
            sfence_vma_retired_q <= sfence_vma_retired_q +
                sfence_vma_retire0 + sfence_vma_retire1 +
                sfence_vma_retire2;
        end
    end

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
    wire [5:0] trace_completed_control_load_candidate =
        (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window
            .trace_completed_control_load_candidate_count : 6'd0;
    wire [5:0] trace_completed_control_load_gate =
        (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window
            .trace_completed_control_load_gate_count : 6'd0;
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
            assign trace_lsu_sent[trace_lsu_index] =
                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                    .slot_xlate_sent_q[trace_lsu_index] ||
                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                    .slot_access_sent_q[trace_lsu_index];
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
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .BANKED_GPR(BANKED_GPR),
        .FPGA_GPR_LUTRAM(FPGA_GPR_LUTRAM),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .ENABLE_FENCE_L2_ACK(ENABLE_FENCE_L2_ACK),
        .ENABLE_RV64ZBB(ENABLE_RV64ZBB),
        .ENABLE_L1I(1'b1),
        .ENABLE_M_MODE_PREFETCH(M_MODE_PREFETCH_ENABLE),
        .ENABLE_L1D(1'b1),
        .ENABLE_L1D_COHERENCE_PROBES(1'b0),
        .ENABLE_COHERENT_ATOMICS(1'b0),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1I_FETCH_DATA_WIDTH(L1I_FETCH_DATA_WIDTH),
        .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
        .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
        .L1D_SYNC_TAG_LOOKUP(L1D_SYNC_TAG_LOOKUP),
        .L1D_SYNC_STORE_EXTENSION(L1D_SYNC_STORE_EXTENSION),
        .ENABLE_LSU_PAGE_SCREEN(ENABLE_LSU_PAGE_SCREEN),
        .L1D_CACHEABLE_BASE(`OPENRV64_SOC_MEMORY_BASE),
        .L1D_CACHEABLE_SIZE(`OPENRV64_SOC_DRAM_PMA_SIZE),
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
        .L1D_PREFETCH_PAGE_GATING(L1D_PREFETCH_PAGE_GATING),
        .ENABLE_MAGIC_MEMORY(1'b0),
        .ENABLE_TRACE(1'b0),
        .ENABLE_FETCH_CAROUSEL(FETCH_CAROUSEL),
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
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
        .pair1024_resp_unpredicted_addr(64'd0),
        .pair1024_resp_unpredicted_data(
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
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
        .icx_req_valid(icx_req_valid),
        .icx_req_ready(icx_req_ready),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id),
        .icx_req_op(icx_req_op),
        .icx_req_lock(icx_req_lock),
        .icx_req_order(icx_req_order),
        .icx_req_kind(icx_req_kind),
        .icx_req_attr(icx_req_attr),
        .icx_req_size(icx_req_size),
        .icx_req_addr(icx_req_addr),
        .icx_req_burst_len(icx_req_burst_len),
        .icx_wdata_valid(icx_wdata_valid),
        .icx_wdata_ready(icx_wdata_ready),
        .icx_wdata_hart_id(icx_wdata_hart_id),
        .icx_wdata_txn_id(icx_wdata_txn_id),
        .icx_wdata_source_id(icx_wdata_source_id),
        .icx_wdata_beat_index(icx_wdata_beat_index),
        .icx_wdata_last(icx_wdata_last),
        .icx_wdata(icx_wdata),
        .icx_wstrb(icx_wstrb),
        .icx_resp_valid(icx_resp_valid),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id),
        .icx_resp_txn_id(icx_resp_txn_id),
        .icx_resp_source_id(icx_resp_source_id),
        .icx_resp_beat_index(icx_resp_beat_index),
        .icx_resp_last(icx_resp_last),
        .icx_resp_rdata(icx_resp_rdata),
        .icx_resp_error(icx_resp_error),
        .icx_resp_sc_success(icx_resp_sc_success),
        .l1d_probe_valid_i(1'b0),
        .l1d_probe_ready_o(),
        .l1d_probe_addr_i(64'd0),
        .coherent_reservation_clear_i(1'b0),
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
        .icx_req_valid_i(complex_icx_req_valid),
        .icx_req_ready_o(complex_icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_order_i(icx_req_order),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_attr_i(icx_req_attr),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_wdata_valid_i(icx_wdata_valid && !fence_icx_select),
        .icx_wdata_ready_o(complex_icx_wdata_ready),
        .icx_wdata_hart_id_i(icx_wdata_hart_id),
        .icx_wdata_txn_id_i(icx_wdata_txn_id),
        .icx_wdata_source_id_i(icx_wdata_source_id),
        .icx_wdata_beat_index_i(icx_wdata_beat_index),
        .icx_wdata_last_i(icx_wdata_last),
        .icx_wdata_i(icx_wdata),
        .icx_wstrb_i(icx_wstrb),
        .icx_resp_valid_o(complex_icx_resp_valid),
        .icx_resp_ready_i(complex_icx_resp_ready),
        .icx_resp_hart_id_o(complex_icx_resp_hart_id),
        .icx_resp_txn_id_o(complex_icx_resp_txn_id),
        .icx_resp_source_id_o(complex_icx_resp_source_id),
        .icx_resp_beat_index_o(complex_icx_resp_beat_index),
        .icx_resp_last_o(complex_icx_resp_last),
        .icx_resp_rdata_o(complex_icx_resp_rdata),
        .icx_resp_error_o(complex_icx_resp_error),
        .icx_resp_sc_success_o(complex_icx_resp_sc_success),
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
                .MAX_BURST_TRAIN_BURSTS(
                    DDR3_MAX_BURST_TRAIN_BURSTS),
                .BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE),
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

            assign magic_icx_read_data = {
                u_ddr3.u_channel.memory_q[
                    magic_icx_word_index + 1'b1],
                u_ddr3.u_channel.memory_q[magic_icx_word_index]
            };

            assign memory_read_bursts =
                u_ddr3.u_channel.perf_read_bursts_q;
            assign memory_write_bursts =
                u_ddr3.u_channel.perf_write_bursts_q;
            assign memory_read_single_beat_bursts =
                u_ddr3.u_channel.perf_read_single_beat_bursts_q;
            assign memory_read_two_beat_bursts =
                u_ddr3.u_channel.perf_read_two_beat_bursts_q;
            assign memory_read_other_bursts =
                u_ddr3.u_channel.perf_read_other_bursts_q;
            assign memory_write_single_beat_bursts =
                u_ddr3.u_channel.perf_write_single_beat_bursts_q;
            assign memory_write_two_beat_bursts =
                u_ddr3.u_channel.perf_write_two_beat_bursts_q;
            assign memory_write_other_bursts =
                u_ddr3.u_channel.perf_write_other_bursts_q;
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
                        "full-ICX timed-memory test requires +memh=<256-bit image>");
                if (!$value$plusargs("memh_words=%d", memh_words))
                    $fatal(1,
                        "full-ICX timed-memory test requires +memh_words=<count>");
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
                assign memory_ddr_active_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_active_cycles_q;
                assign memory_ddr_command_queue_entry_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_command_queue_entry_cycles_q;
                assign memory_ddr_command_queue_full_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_command_queue_full_cycles_q;
                assign memory_ddr_command_input_wait_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_command_input_wait_cycles_q;
                assign memory_ddr_command_refresh_wait_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_command_refresh_wait_cycles_q;
                assign memory_ddr_bus_busy_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_busy_cycles_q;
                assign memory_ddr_bus_read_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_read_cycles_q;
                assign memory_ddr_bus_write_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_write_cycles_q;
                assign memory_ddr_bus_launches =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_launches_q;
                assign memory_ddr_bus_read_launches =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_read_launches_q;
                assign memory_ddr_bus_write_launches =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_write_launches_q;
                assign memory_ddr_bus_bank_wait_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_bank_wait_cycles_q;
                assign memory_ddr_bus_queue_wait_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bus_queue_wait_cycles_q;
                assign memory_ddr_bank_busy_entry_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_bank_busy_entry_cycles_q;
                assign memory_ddr_max_busy_banks =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_max_busy_banks_q;
                assign memory_ddr_row_hit_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_row_hit_commands_q;
                assign memory_ddr_row_miss_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_row_miss_commands_q;
                assign memory_ddr_row_conflict_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_row_conflict_commands_q;
                assign memory_ddr_row_empty_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_row_empty_commands_q;
                assign memory_ddr_native_bursts =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_native_bursts_q;
                assign memory_ddr_full_native_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_full_native_commands_q;
                assign memory_ddr_partial_native_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_partial_native_commands_q;
                assign memory_ddr_multi_native_commands =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_multi_native_commands_q;
                assign memory_ddr_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_burst_trains_q;
                assign memory_ddr_single_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_single_burst_trains_q;
                assign memory_ddr_two_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_two_burst_trains_q;
                assign memory_ddr_three_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_three_burst_trains_q;
                assign memory_ddr_four_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_four_burst_trains_q;
                assign memory_ddr_five_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_five_burst_trains_q;
                assign memory_ddr_six_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_six_burst_trains_q;
                assign memory_ddr_seven_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_seven_burst_trains_q;
                assign memory_ddr_eight_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_eight_burst_trains_q;
                assign memory_ddr_long_burst_trains =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_long_burst_trains_q;
                assign memory_ddr_direction_switches =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_direction_switches_q;
                assign memory_ddr_refresh_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_refresh_cycles_q;
                assign memory_ddr_refresh_events =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_refresh_events_q;
                assign memory_ddr_refresh_deferred_cycles =
                    u_ddr3.g_ddr3.u_timing.u_timing
                        .perf_refresh_deferred_cycles_q;
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
                assign memory_ddr_active_cycles = 64'd0;
                assign memory_ddr_command_queue_entry_cycles = 64'd0;
                assign memory_ddr_command_queue_full_cycles = 64'd0;
                assign memory_ddr_command_input_wait_cycles = 64'd0;
                assign memory_ddr_command_refresh_wait_cycles = 64'd0;
                assign memory_ddr_bus_busy_cycles = 64'd0;
                assign memory_ddr_bus_read_cycles = 64'd0;
                assign memory_ddr_bus_write_cycles = 64'd0;
                assign memory_ddr_bus_launches = 64'd0;
                assign memory_ddr_bus_read_launches = 64'd0;
                assign memory_ddr_bus_write_launches = 64'd0;
                assign memory_ddr_bus_bank_wait_cycles = 64'd0;
                assign memory_ddr_bus_queue_wait_cycles = 64'd0;
                assign memory_ddr_bank_busy_entry_cycles = 64'd0;
                assign memory_ddr_max_busy_banks = 64'd0;
                assign memory_ddr_row_hit_commands = 64'd0;
                assign memory_ddr_row_miss_commands = 64'd0;
                assign memory_ddr_row_conflict_commands = 64'd0;
                assign memory_ddr_row_empty_commands = 64'd0;
                assign memory_ddr_native_bursts = 64'd0;
                assign memory_ddr_full_native_commands = 64'd0;
                assign memory_ddr_partial_native_commands = 64'd0;
                assign memory_ddr_multi_native_commands = 64'd0;
                assign memory_ddr_burst_trains = 64'd0;
                assign memory_ddr_single_burst_trains = 64'd0;
                assign memory_ddr_two_burst_trains = 64'd0;
                assign memory_ddr_three_burst_trains = 64'd0;
                assign memory_ddr_four_burst_trains = 64'd0;
                assign memory_ddr_five_burst_trains = 64'd0;
                assign memory_ddr_six_burst_trains = 64'd0;
                assign memory_ddr_seven_burst_trains = 64'd0;
                assign memory_ddr_eight_burst_trains = 64'd0;
                assign memory_ddr_long_burst_trains = 64'd0;
                assign memory_ddr_direction_switches = 64'd0;
                assign memory_ddr_refresh_cycles = 64'd0;
                assign memory_ddr_refresh_events = 64'd0;
                assign memory_ddr_refresh_deferred_cycles = 64'd0;
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
            assign memory_read_single_beat_bursts = 64'd0;
            assign memory_read_two_beat_bursts = 64'd0;
            assign memory_read_other_bursts = 64'd0;
            assign memory_write_single_beat_bursts = 64'd0;
            assign memory_write_two_beat_bursts = 64'd0;
            assign memory_write_other_bursts = 64'd0;
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
            assign memory_ddr_active_cycles = 64'd0;
            assign memory_ddr_command_queue_entry_cycles = 64'd0;
            assign memory_ddr_command_queue_full_cycles = 64'd0;
            assign memory_ddr_command_input_wait_cycles = 64'd0;
            assign memory_ddr_command_refresh_wait_cycles = 64'd0;
            assign memory_ddr_bus_busy_cycles = 64'd0;
            assign memory_ddr_bus_read_cycles = 64'd0;
            assign memory_ddr_bus_write_cycles = 64'd0;
            assign memory_ddr_bus_launches = 64'd0;
            assign memory_ddr_bus_read_launches = 64'd0;
            assign memory_ddr_bus_write_launches = 64'd0;
            assign memory_ddr_bus_bank_wait_cycles = 64'd0;
            assign memory_ddr_bus_queue_wait_cycles = 64'd0;
            assign memory_ddr_bank_busy_entry_cycles = 64'd0;
            assign memory_ddr_max_busy_banks = 64'd0;
            assign memory_ddr_row_hit_commands = 64'd0;
            assign memory_ddr_row_miss_commands = 64'd0;
            assign memory_ddr_row_conflict_commands = 64'd0;
            assign memory_ddr_row_empty_commands = 64'd0;
            assign memory_ddr_native_bursts = 64'd0;
            assign memory_ddr_full_native_commands = 64'd0;
            assign memory_ddr_partial_native_commands = 64'd0;
            assign memory_ddr_multi_native_commands = 64'd0;
            assign memory_ddr_burst_trains = 64'd0;
            assign memory_ddr_single_burst_trains = 64'd0;
            assign memory_ddr_two_burst_trains = 64'd0;
            assign memory_ddr_three_burst_trains = 64'd0;
            assign memory_ddr_four_burst_trains = 64'd0;
            assign memory_ddr_five_burst_trains = 64'd0;
            assign memory_ddr_six_burst_trains = 64'd0;
            assign memory_ddr_seven_burst_trains = 64'd0;
            assign memory_ddr_eight_burst_trains = 64'd0;
            assign memory_ddr_long_burst_trains = 64'd0;
            assign memory_ddr_direction_switches = 64'd0;
            assign memory_ddr_refresh_cycles = 64'd0;
            assign memory_ddr_refresh_events = 64'd0;
            assign memory_ddr_refresh_deferred_cycles = 64'd0;

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

            assign magic_icx_read_data = {
                u_ram.ram_q[magic_icx_word_index + 1'b1],
                u_ram.ram_q[magic_icx_word_index]
            };

            initial begin
                ddr3_commands = 0;
                max_ddr3_queued = 0;
                max_timing_owners = 0;
                if (!$value$plusargs("memh=%s", memh_path))
                    $fatal(1,
                        "full-ICX SRAM test requires +memh=<256-bit image>");
                if (!$value$plusargs("memh_words=%d", memh_words))
                    $fatal(1,
                        "full-ICX SRAM test requires +memh_words=<count>");
                if ((memh_words < 1) ||
                    (memh_words > (RAM_BYTES / 32)))
                    $fatal(1, "SRAM memh_words=%0d exceeds RAM",
                           memh_words);
                $readmemh(memh_path, u_ram.ram_q, 0, memh_words - 1);
            end
        end
    endgenerate

    initial begin
        magic_icx_source_mask_q = 4'b0000;
        magic_icx_source_mask_arg = 0;
        fence_case_q = 0;
        if (!$value$plusargs("fence_case=%d", fence_case_q))
            fence_case_q = 0;
        fence_check_enabled_q = $test$plusargs("fence_check");
        fence_trace_enabled_q = $test$plusargs("fence_trace");
        if ($test$plusargs("magic_l1i"))
            magic_icx_source_mask_q[`OPENRV64_ICX_SOURCE_ICACHE] = 1'b1;
        if ($test$plusargs("magic_l1d"))
            magic_icx_source_mask_q[`OPENRV64_ICX_SOURCE_DCACHE] = 1'b1;
        if ($value$plusargs("magic_icx_sources=%h",
                            magic_icx_source_mask_arg))
            magic_icx_source_mask_q = magic_icx_source_mask_arg[3:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            magic_icx_resp_valid_q <= 1'b0;
            magic_icx_resp_hart_id_q <=
                {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            magic_icx_resp_txn_id_q <=
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            magic_icx_resp_source_id_q <=
                {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
            magic_icx_resp_rdata_q <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            magic_icx_l1i_reads <= 0;
            magic_icx_l1d_reads <= 0;
            for (magic_icx_shadow_reset_scan = 0;
                 magic_icx_shadow_reset_scan < MAGIC_ICX_SHADOW_DEPTH;
                 magic_icx_shadow_reset_scan =
                    magic_icx_shadow_reset_scan + 1) begin
                magic_icx_shadow_valid_q[
                    magic_icx_shadow_reset_scan] <= 1'b0;
                magic_icx_shadow_hart_id_q[
                    magic_icx_shadow_reset_scan] <=
                    {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
                magic_icx_shadow_txn_id_q[
                    magic_icx_shadow_reset_scan] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                magic_icx_shadow_source_id_q[
                    magic_icx_shadow_reset_scan] <=
                    {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
            end
        end else begin
            if (magic_icx_resp_fire && !magic_icx_req_fire)
                magic_icx_resp_valid_q <= 1'b0;
            if (magic_icx_shadow_resp_fire)
                magic_icx_shadow_valid_q[
                    magic_icx_shadow_resp_index_r] <= 1'b0;
            if (magic_icx_req_fire) begin
                magic_icx_resp_valid_q <= 1'b1;
                magic_icx_resp_hart_id_q <= icx_req_hart_id;
                magic_icx_resp_txn_id_q <= icx_req_txn_id;
                magic_icx_resp_source_id_q <= icx_req_source_id;
                magic_icx_resp_rdata_q <= magic_icx_read_data;
                magic_icx_shadow_valid_q[
                    magic_icx_shadow_free_index_r] <= 1'b1;
                magic_icx_shadow_hart_id_q[
                    magic_icx_shadow_free_index_r] <= icx_req_hart_id;
                magic_icx_shadow_txn_id_q[
                    magic_icx_shadow_free_index_r] <= icx_req_txn_id;
                magic_icx_shadow_source_id_q[
                    magic_icx_shadow_free_index_r] <= icx_req_source_id;
                if (icx_req_source_id ==
                    `OPENRV64_ICX_SOURCE_ICACHE)
                    magic_icx_l1i_reads <= magic_icx_l1i_reads + 1;
                else if (icx_req_source_id ==
                         `OPENRV64_ICX_SOURCE_DCACHE)
                    magic_icx_l1d_reads <= magic_icx_l1d_reads + 1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fence_resp_valid_q <= 1'b0;
            fence_resp_hart_q <=
                {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            fence_resp_txn_q <=
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            fence_resp_source_q <=
                {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
            fence_resp_rdata_q <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            fence_ww_pred_done_q <= 1'b0;
            fence_wr_pred_done_q <= 1'b0;
            fence_rr_pred_done_q <= 1'b0;
            fence_rw_pred_done_q <= 1'b0;
            fence_oo_pred_done_q <= 1'b0;
            fence_oi_pred_done_q <= 1'b0;
            fence_ii_pred_done_q <= 1'b0;
            fence_io_pred_done_q <= 1'b0;
            fence_partial_done_q <= 1'b0;
            fence_pressure_done_q <= 12'd0;
            fence_smc_store_seen_q <= 1'b0;
            fence_smc_store_done_q <= 1'b0;
            fence_smc_fetches_q <= 0;
            fence_ww_succ_seen_q <= 1'b0;
            fence_wr_succ_seen_q <= 1'b0;
            fence_rr_succ_seen_q <= 1'b0;
            fence_rw_succ_seen_q <= 1'b0;
            fence_oo_succ_seen_q <= 1'b0;
            fence_oi_succ_seen_q <= 1'b0;
            fence_ii_succ_seen_q <= 1'b0;
            fence_io_succ_seen_q <= 1'b0;
            fence_partial_succ_seen_q <= 1'b0;
            fence_pressure_succ_seen_q <= 1'b0;
            fence_final_store_done_q <= 1'b0;
            fence_order_violation_q <= 11'd0;
            fence_smc_pending_valid_q <= 1'b0;
            fence_smc_forward_data_q <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            fence_external_requests_q <= 0;
            fence_external_completions_q <= 0;
            for (fence_queue_reset_scan = 0;
                 fence_queue_reset_scan < FENCE_QUEUE_DEPTH;
                 fence_queue_reset_scan =
                     fence_queue_reset_scan + 1) begin
                fence_queue_valid_q[fence_queue_reset_scan] <= 1'b0;
                fence_queue_hart_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
                fence_queue_txn_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                fence_queue_source_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
                fence_queue_op_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_OP_WIDTH{1'b0}};
                fence_queue_addr_q[fence_queue_reset_scan] <= 64'd0;
                fence_queue_wdata_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                fence_queue_wstrb_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                fence_queue_rdata_q[fence_queue_reset_scan] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                fence_queue_shadow_q[fence_queue_reset_scan] <=
                    {FENCE_SHADOW_INDEX_WIDTH{1'b0}};
                fence_queue_delay_q[fence_queue_reset_scan] <= 0;
            end
            for (fence_shadow_reset_scan = 0;
                 fence_shadow_reset_scan < FENCE_SHADOW_DEPTH;
                 fence_shadow_reset_scan =
                     fence_shadow_reset_scan + 1) begin
                fence_shadow_valid_q[fence_shadow_reset_scan] <= 1'b0;
                fence_shadow_addr_q[fence_shadow_reset_scan] <= 64'd0;
                fence_shadow_data_q[fence_shadow_reset_scan] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            end
        end else begin
            if (fence_resp_fire)
                fence_resp_valid_q <= 1'b0;

            for (fence_queue_reset_scan = 0;
                 fence_queue_reset_scan < FENCE_QUEUE_DEPTH;
                 fence_queue_reset_scan =
                     fence_queue_reset_scan + 1)
                if (fence_queue_valid_q[fence_queue_reset_scan] &&
                    (fence_queue_delay_q[fence_queue_reset_scan] != 0))
                    fence_queue_delay_q[fence_queue_reset_scan] <=
                        fence_queue_delay_q[fence_queue_reset_scan] - 1;

            if (fence_queue_response_found_r &&
                (!fence_resp_valid_q || fence_resp_fire)) begin
                if (fence_trace_enabled_q)
                    $display(
                        "FENCE_BOUNDARY response source=%0d txn=%0d op=%0d addr=%016h",
                        fence_queue_source_q[
                            fence_queue_response_index_r],
                        fence_queue_txn_q[
                            fence_queue_response_index_r],
                        fence_queue_op_q[
                            fence_queue_response_index_r],
                        fence_queue_addr_q[
                            fence_queue_response_index_r]);
                fence_resp_valid_q <= 1'b1;
                fence_resp_hart_q <= fence_queue_hart_q[
                    fence_queue_response_index_r];
                fence_resp_txn_q <= fence_queue_txn_q[
                    fence_queue_response_index_r];
                fence_resp_source_q <= fence_queue_source_q[
                    fence_queue_response_index_r];
                fence_resp_rdata_q <= fence_queue_rdata_q[
                    fence_queue_response_index_r];
                fence_queue_valid_q[
                    fence_queue_response_index_r] <= 1'b0;
                fence_external_completions_q <=
                    fence_external_completions_q + 1;

                if (fence_queue_op_q[fence_queue_response_index_r] ==
                    `OPENRV64_ICX_OP_WRITE) begin
                    for (fence_shadow_write_byte = 0;
                         fence_shadow_write_byte <
                             `OPENRV64_ICX_LINE_STRB_WIDTH;
                         fence_shadow_write_byte =
                             fence_shadow_write_byte + 1)
                        if (fence_queue_wstrb_q[
                                fence_queue_response_index_r][
                                fence_shadow_write_byte])
                            fence_shadow_data_q[
                                fence_queue_shadow_q[
                                    fence_queue_response_index_r]][
                                fence_shadow_write_byte*8 +: 8] <=
                                fence_queue_wdata_q[
                                    fence_queue_response_index_r][
                                    fence_shadow_write_byte*8 +: 8];
                end

                case (fence_queue_addr_q[
                          fence_queue_response_index_r])
                    FENCE_TEST_BASE + 64'h000:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_ww_pred_done_q <= 1'b1;
                    FENCE_TEST_BASE + 64'h100:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_wr_pred_done_q <= 1'b1;
                    FENCE_TEST_BASE + 64'h200:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_READ)
                            fence_rr_pred_done_q <= 1'b1;
                    FENCE_TEST_BASE + 64'h300:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_READ)
                            fence_rw_pred_done_q <= 1'b1;
                    FENCE_TEST_BASE + 64'h400:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_partial_done_q <= 1'b1;
                    FENCE_TEST_BASE + 64'hd00:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_final_store_done_q <= 1'b1;
                    FENCE_SMC_LINE:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE) begin
                            fence_smc_store_done_q <= 1'b1;
                            fence_smc_pending_valid_q <= 1'b0;
                        end
                    FENCE_DEVICE_BASE + 64'h000:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_oo_pred_done_q <= 1'b1;
                    FENCE_DEVICE_BASE + 64'h100:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_WRITE)
                            fence_oi_pred_done_q <= 1'b1;
                    FENCE_DEVICE_BASE + 64'h200:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_READ)
                            fence_ii_pred_done_q <= 1'b1;
                    FENCE_DEVICE_BASE + 64'h300:
                        if (fence_queue_op_q[
                                fence_queue_response_index_r] ==
                            `OPENRV64_ICX_OP_READ)
                            fence_io_pred_done_q <= 1'b1;
                    default: begin
                        if ((fence_queue_addr_q[
                                 fence_queue_response_index_r] >=
                             FENCE_TEST_BASE + 64'h800) &&
                            (fence_queue_addr_q[
                                 fence_queue_response_index_r] <
                             FENCE_TEST_BASE + 64'hb00) &&
                            (fence_queue_op_q[
                                 fence_queue_response_index_r] ==
                             `OPENRV64_ICX_OP_WRITE))
                            fence_pressure_done_q[
                                (fence_queue_addr_q[
                                     fence_queue_response_index_r] -
                                 (FENCE_TEST_BASE + 64'h800)) >> 6] <=
                                1'b1;
                    end
                endcase
            end

            if (fence_icx_req_fire) begin
                if (fence_trace_enabled_q)
                    $display(
                        "FENCE_BOUNDARY request source=%0d txn=%0d op=%0d addr=%016h",
                        icx_req_source_id, icx_req_txn_id,
                        icx_req_op, icx_req_addr);
                fence_external_requests_q <=
                    fence_external_requests_q + 1;
                fence_queue_valid_q[fence_queue_free_index_r] <= 1'b1;
                fence_queue_hart_q[fence_queue_free_index_r] <=
                    icx_req_hart_id;
                fence_queue_txn_q[fence_queue_free_index_r] <=
                    icx_req_txn_id;
                fence_queue_source_q[fence_queue_free_index_r] <=
                    icx_req_source_id;
                fence_queue_op_q[fence_queue_free_index_r] <= icx_req_op;
                fence_queue_addr_q[fence_queue_free_index_r] <=
                    icx_req_addr;
                fence_queue_wdata_q[fence_queue_free_index_r] <=
                    icx_wdata;
                fence_queue_wstrb_q[fence_queue_free_index_r] <=
                    icx_wstrb;
                fence_queue_rdata_q[fence_queue_free_index_r] <=
                    ((icx_req_addr == FENCE_SMC_LINE) &&
                     (icx_req_source_id ==
                      `OPENRV64_ICX_SOURCE_ICACHE) &&
                     fence_smc_pending_valid_q) ?
                        fence_smc_forward_data_q :
                    fence_shadow_match_r ?
                        fence_shadow_data_q[
                            fence_shadow_match_index_r] :
                        ((icx_req_addr >= FENCE_DEVICE_BASE) &&
                         (icx_req_addr < FENCE_DEVICE_LIMIT)) ?
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}} :
                            magic_icx_read_data;
                fence_queue_shadow_q[fence_queue_free_index_r] <=
                    fence_shadow_match_r ?
                        fence_shadow_match_index_r :
                        fence_shadow_free_index_r;
                fence_queue_delay_q[fence_queue_free_index_r] <=
                    FENCE_RESPONSE_DELAY;

                if (!fence_shadow_match_r) begin
                    fence_shadow_valid_q[
                        fence_shadow_free_index_r] <= 1'b1;
                    fence_shadow_addr_q[
                        fence_shadow_free_index_r] <=
                        {icx_req_addr[63:6], 6'b0};
                    fence_shadow_data_q[
                        fence_shadow_free_index_r] <=
                        ((icx_req_addr >= FENCE_DEVICE_BASE) &&
                         (icx_req_addr < FENCE_DEVICE_LIMIT)) ?
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}} :
                            magic_icx_read_data;
                end

                if (icx_req_addr == FENCE_TEST_BASE + 64'h040) begin
                    if (!fence_ww_pred_done_q) begin
                        fence_order_violation_q[0] <= 1'b1;
                        $display(
                            "FENCE w,w exposed successor store before predecessor completion");
                    end
                    fence_ww_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'h140) begin
                    if (!fence_wr_pred_done_q) begin
                        fence_order_violation_q[1] <= 1'b1;
                        $display(
                            "FENCE w,r exposed successor load before predecessor completion");
                    end
                    fence_wr_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'h240) begin
                    if (!fence_rr_pred_done_q) begin
                        fence_order_violation_q[2] <= 1'b1;
                        $display(
                            "FENCE r,r exposed successor load before predecessor completion");
                    end
                    fence_rr_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'h340) begin
                    if (!fence_rw_pred_done_q) begin
                        fence_order_violation_q[3] <= 1'b1;
                        $display(
                            "FENCE r,w exposed successor store before predecessor completion");
                    end
                    fence_rw_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_DEVICE_BASE + 64'h040) begin
                    if (!fence_oo_pred_done_q) begin
                        fence_order_violation_q[4] <= 1'b1;
                        $display(
                            "FENCE o,o exposed successor output before predecessor completion");
                    end
                    fence_oo_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_DEVICE_BASE + 64'h140) begin
                    if (!fence_oi_pred_done_q) begin
                        fence_order_violation_q[5] <= 1'b1;
                        $display(
                            "FENCE o,i exposed successor input before predecessor completion");
                    end
                    fence_oi_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_DEVICE_BASE + 64'h240) begin
                    if (!fence_ii_pred_done_q) begin
                        fence_order_violation_q[6] <= 1'b1;
                        $display(
                            "FENCE i,i exposed successor input before predecessor completion");
                    end
                    fence_ii_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_DEVICE_BASE + 64'h340) begin
                    if (!fence_io_pred_done_q) begin
                        fence_order_violation_q[7] <= 1'b1;
                        $display(
                            "FENCE i,o exposed successor output before predecessor completion");
                    end
                    fence_io_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'h400) begin
                    if ((icx_wstrb[15:0] != 16'hfffe) ||
                        (|icx_wstrb[
                            `OPENRV64_ICX_LINE_STRB_WIDTH-1:16]) ||
                        (icx_wdata[127:0] !=
                         128'hffeeddccbbaa99887766554433221100))
                        $fatal(1,
                            "partial stores did not merge at external boundary strb=%h data=%032h",
                            icx_wstrb, icx_wdata[127:0]);
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'h440) begin
                    if (!fence_partial_done_q) begin
                        fence_order_violation_q[8] <= 1'b1;
                        $display(
                            "partial-line stores were not complete before successor load");
                    end
                    fence_partial_succ_seen_q <= 1'b1;
                end
                if (icx_req_addr == FENCE_TEST_BASE + 64'hc00) begin
                    if (fence_pressure_done_q != 12'hfff) begin
                        fence_order_violation_q[9] <= 1'b1;
                        $display(
                            "buffer-pressure successor escaped with completions=%03h",
                            fence_pressure_done_q);
                    end
                    fence_pressure_succ_seen_q <= 1'b1;
                end
                if ((icx_req_addr == FENCE_SMC_LINE) &&
                    (icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_DCACHE) &&
                    (icx_req_op == `OPENRV64_ICX_OP_WRITE)) begin
                    fence_smc_store_seen_q <= 1'b1;
                    fence_smc_pending_valid_q <= 1'b1;
                    fence_smc_forward_data_q <=
                        fence_shadow_match_r ?
                            fence_shadow_data_q[
                                fence_shadow_match_index_r] :
                            magic_icx_read_data;
                    for (fence_shadow_write_byte = 0;
                         fence_shadow_write_byte <
                             `OPENRV64_ICX_LINE_STRB_WIDTH;
                         fence_shadow_write_byte =
                             fence_shadow_write_byte + 1)
                        if (icx_wstrb[fence_shadow_write_byte])
                            fence_smc_forward_data_q[
                                fence_shadow_write_byte*8 +: 8] <=
                                icx_wdata[
                                    fence_shadow_write_byte*8 +: 8];
                end
                if ((icx_req_addr == FENCE_SMC_LINE) &&
                    (icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_ICACHE)) begin
                    if ((fence_smc_fetches_q != 0) &&
                        !fence_smc_store_done_q) begin
                        fence_order_violation_q[10] <= 1'b1;
                        $display(
                            "FENCE.I refetch crossed external boundary before code store completion");
                    end
                    fence_smc_fetches_q <= fence_smc_fetches_q + 1;
                end
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

    // Optional address-level timing for up to four architectural fetch
    // demands. This supports both the single-request bridge and the
    // experimental four-slot carousel.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_demand_trace_cycle_q = 0;
            for (fetch_demand_trace_scan = 0;
                 fetch_demand_trace_scan < 4;
                 fetch_demand_trace_scan =
                    fetch_demand_trace_scan + 1) begin
                fetch_demand_trace_start_q[
                    fetch_demand_trace_scan] = 0;
                fetch_demand_trace_external_q[
                    fetch_demand_trace_scan] = 0;
                fetch_demand_trace_empty_q[
                    fetch_demand_trace_scan] = 0;
                fetch_demand_trace_valid_q[
                    fetch_demand_trace_scan] = 1'b0;
                fetch_demand_trace_addr_q[
                    fetch_demand_trace_scan] = 64'd0;
                fetch_demand_trace_pc_q[
                    fetch_demand_trace_scan] = 64'd0;
            end
        end else begin
            fetch_demand_trace_cycle_q = fetch_demand_trace_cycle_q + 1;

            for (fetch_demand_trace_scan = 0;
                 fetch_demand_trace_scan < 4;
                 fetch_demand_trace_scan =
                    fetch_demand_trace_scan + 1) begin
                if (fetch_demand_trace_valid_q[
                        fetch_demand_trace_scan]) begin
                    if (dut.u_bus.g_icx.u_bus.u_l1i
                            .demand_mshr_any_valid_r)
                        fetch_demand_trace_external_q[
                            fetch_demand_trace_scan] =
                            fetch_demand_trace_external_q[
                                fetch_demand_trace_scan] + 1;
                    if ((dut.fetch_decode_valid == 0) &&
                        dut.backend_decode_ready[0] &&
                        dut.frontend_decode_enable)
                        fetch_demand_trace_empty_q[
                            fetch_demand_trace_scan] =
                            fetch_demand_trace_empty_q[
                                fetch_demand_trace_scan] + 1;
                end
            end

            if (dut.fetch_pipe_resp_valid &&
                dut.fetch_pipe_resp_ready &&
                dut.fetch_pipe_resp_demand) begin
                fetch_demand_trace_match = -1;
                for (fetch_demand_trace_scan = 0;
                     fetch_demand_trace_scan < 4;
                     fetch_demand_trace_scan =
                        fetch_demand_trace_scan + 1)
                    if ((fetch_demand_trace_match < 0) &&
                        fetch_demand_trace_valid_q[
                            fetch_demand_trace_scan] &&
                        (fetch_demand_trace_addr_q[
                            fetch_demand_trace_scan][63:5] ==
                         dut.fetch_pipe_resp_addr[63:5]))
                        fetch_demand_trace_match =
                            fetch_demand_trace_scan;
                if (fetch_demand_trace_match < 0)
                    $fatal(1,
                        "fetch demand trace response had no matching request");
                if (fetch_demand_trace_enabled != 0)
                    $display(
                        "TRACE_FETCH_DEMAND kind=complete start_pc=%016h addr=%016h latency=%0d external=%0d empty=%0d",
                        fetch_demand_trace_pc_q[
                            fetch_demand_trace_match],
                        fetch_demand_trace_addr_q[
                            fetch_demand_trace_match],
                        fetch_demand_trace_cycle_q -
                            fetch_demand_trace_start_q[
                                fetch_demand_trace_match],
                        fetch_demand_trace_external_q[
                            fetch_demand_trace_match],
                        fetch_demand_trace_empty_q[
                            fetch_demand_trace_match]);
                fetch_demand_trace_valid_q[
                    fetch_demand_trace_match] = 1'b0;
            end

            if (dut.fetch3_restart || dut.fetch3_invalidate) begin
                for (fetch_demand_trace_scan = 0;
                     fetch_demand_trace_scan < 4;
                     fetch_demand_trace_scan =
                        fetch_demand_trace_scan + 1) begin
                    if (fetch_demand_trace_valid_q[
                            fetch_demand_trace_scan] &&
                        (fetch_demand_trace_enabled != 0))
                        $display(
                            "TRACE_FETCH_DEMAND kind=cancel start_pc=%016h addr=%016h latency=%0d external=%0d empty=%0d",
                            fetch_demand_trace_pc_q[
                                fetch_demand_trace_scan],
                            fetch_demand_trace_addr_q[
                                fetch_demand_trace_scan],
                            fetch_demand_trace_cycle_q -
                                fetch_demand_trace_start_q[
                                    fetch_demand_trace_scan],
                            fetch_demand_trace_external_q[
                                fetch_demand_trace_scan],
                            fetch_demand_trace_empty_q[
                                fetch_demand_trace_scan]);
                    fetch_demand_trace_valid_q[
                        fetch_demand_trace_scan] = 1'b0;
                end
            end

            if (dut.fetch_pipe_req_valid &&
                dut.fetch_pipe_req_ready &&
                dut.fetch_pipe_req_demand) begin
                fetch_demand_trace_free = -1;
                for (fetch_demand_trace_scan = 0;
                     fetch_demand_trace_scan < 4;
                     fetch_demand_trace_scan =
                        fetch_demand_trace_scan + 1)
                    if ((fetch_demand_trace_free < 0) &&
                        !fetch_demand_trace_valid_q[
                            fetch_demand_trace_scan])
                        fetch_demand_trace_free =
                            fetch_demand_trace_scan;
                if (fetch_demand_trace_free < 0)
                    $fatal(1,
                        "fetch demand trace exceeded four outstanding requests");
                fetch_demand_trace_valid_q[
                    fetch_demand_trace_free] = 1'b1;
                fetch_demand_trace_start_q[
                    fetch_demand_trace_free] =
                    fetch_demand_trace_cycle_q;
                fetch_demand_trace_external_q[
                    fetch_demand_trace_free] = 0;
                fetch_demand_trace_empty_q[
                    fetch_demand_trace_free] = 0;
                fetch_demand_trace_addr_q[
                    fetch_demand_trace_free] =
                    dut.fetch_pipe_req_addr;
                fetch_demand_trace_pc_q[
                    fetch_demand_trace_free] =
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
                    dut.g_fetch_axi.u_fetch.consume_line_pending) begin
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

    task automatic sample_redirect_cycle_trace;
        integer sample_index;
        integer slot_index;
        begin
            if (redirect_cycle_trace_active &&
                (redirect_cycle_trace_length <
                 REDIRECT_CYCLE_TRACE_DEPTH)) begin
                sample_index = redirect_cycle_trace_length;
                redirect_cycle_trace_cycle[sample_index] = cycles;
                redirect_cycle_trace_decode[sample_index] =
                    dut.fetch_decode_valid;
                redirect_cycle_trace_req_valid[sample_index] =
                    dut.fetch_pipe_req_valid;
                redirect_cycle_trace_req_ready[sample_index] =
                    dut.fetch_pipe_req_ready;
                redirect_cycle_trace_req_target[sample_index] =
                    dut.fetch_pipe_req_valid &&
                    (dut.fetch_pipe_req_addr[63:6] ==
                     redirect_cycle_trace_target[63:6]);
                redirect_cycle_trace_req_stash[sample_index] =
                    dut.fetch_pipe_req_stash;
                redirect_cycle_trace_req_demand[sample_index] =
                    dut.fetch_pipe_req_demand;
                redirect_cycle_trace_mtl_match[sample_index] = 1'b0;
                redirect_cycle_trace_mtl_slot[sample_index] = 2'd0;
                redirect_cycle_trace_mtl_state[sample_index] = 3'd0;
                for (slot_index = 0; slot_index < 4;
                     slot_index = slot_index + 1) begin
                    if (!redirect_cycle_trace_mtl_match[sample_index] &&
                        (dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[
                            slot_index] != 3'd0) &&
                        (dut.u_bus.g_icx.u_bus.u_debug.fetch_vaddr_q[
                            slot_index][63:6] ==
                         redirect_cycle_trace_target[63:6])) begin
                        redirect_cycle_trace_mtl_match[sample_index] = 1'b1;
                        redirect_cycle_trace_mtl_slot[sample_index] =
                            slot_index[1:0];
                        redirect_cycle_trace_mtl_state[sample_index] =
                            dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[
                                slot_index];
                    end
                end
                redirect_cycle_trace_mtl_states[sample_index] = {
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[3],
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[2],
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[1],
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_state_q[0]
                };
                redirect_cycle_trace_xlate[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_xlate_found_r;
                redirect_cycle_trace_xlate_slot[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_xlate_slot_r;
                redirect_cycle_trace_pmp_fetch[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_pmp_resp_valid;
                redirect_cycle_trace_l1_launch[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.fetch_l1i_launch;
                redirect_cycle_trace_screen_hit[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug
                        .fetch_page_screen_accept;
                redirect_cycle_trace_screen_launch[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug
                        .fetch_page_screen_launch;
                redirect_cycle_trace_screen_bypass[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug
                        .fetch_page_screen_resp_bypass;
                redirect_cycle_trace_l1_req_valid[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.l1i_req_valid;
                redirect_cycle_trace_l1_req_fire[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.l1i_req_fire;
                redirect_cycle_trace_l1_resp[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_debug.l1i_resp_valid;
                redirect_cycle_trace_pipe_resp[sample_index] =
                    dut.fetch_pipe_resp_valid;
                redirect_cycle_trace_pipe_resp_target[sample_index] =
                    dut.fetch_pipe_resp_valid &&
                    (dut.fetch_pipe_resp_addr[63:6] ==
                     redirect_cycle_trace_target[63:6]);
                redirect_cycle_trace_ingress_hit[sample_index] =
                    dut.g_fetch_axi.u_fetch.consume_ingress_hit_r;
                redirect_cycle_trace_line_hit[sample_index] =
                    dut.g_fetch_axi.u_fetch.consume_line_hit;
                redirect_cycle_trace_redirect_pending[sample_index] =
                    dut.g_fetch_axi.u_fetch.redirect_line_pending_q;
                redirect_cycle_trace_external_miss[sample_index] =
                    dut.u_bus.g_icx.u_bus.u_l1i.demand_mshr_any_valid_r;
                redirect_cycle_trace_length =
                    redirect_cycle_trace_length + 1;
            end else if (redirect_cycle_trace_active) begin
                redirect_cycle_trace_truncated = 1'b1;
            end
        end
    endtask

    task automatic emit_redirect_cycle_trace;
        integer sample_index;
        begin
            $display(
                "TRACE_REDIRECT_EVENT capture=%0d redirect_index=%0d kind=%0d start_cycle=%0d target=%016h empty_cycles=%0d samples=%0d truncated=%0d",
                redirect_cycle_trace_captured,
                redirect_cycle_trace_seen,
                redirect_cycle_trace_kind,
                redirect_cycle_trace_start,
                redirect_cycle_trace_target,
                redirect_cycle_trace_empty,
                redirect_cycle_trace_length,
                redirect_cycle_trace_truncated);
            for (sample_index = 0;
                 sample_index < redirect_cycle_trace_length;
                 sample_index = sample_index + 1) begin
                $display(
                    "TRACE_REDIRECT_CYCLE capture=%0d rel=%0d cycle=%0d decode=%01h req=%0d/%0d req_target=%0d stash=%0d demand=%0d mtl_match=%0d mtl_slot=%0d mtl_state=%0d mtl_states=%03h xlate=%0d/%0d pmp_fetch=%0d l1_launch=%0d screen=%0d/%0d/%0d l1_req=%0d/%0d l1_resp=%0d pipe_resp=%0d/%0d ingress_hit=%0d line_hit=%0d redirect_pending=%0d external_miss=%0d",
                    redirect_cycle_trace_captured,
                    sample_index,
                    redirect_cycle_trace_cycle[sample_index],
                    redirect_cycle_trace_decode[sample_index],
                    redirect_cycle_trace_req_valid[sample_index],
                    redirect_cycle_trace_req_ready[sample_index],
                    redirect_cycle_trace_req_target[sample_index],
                    redirect_cycle_trace_req_stash[sample_index],
                    redirect_cycle_trace_req_demand[sample_index],
                    redirect_cycle_trace_mtl_match[sample_index],
                    redirect_cycle_trace_mtl_slot[sample_index],
                    redirect_cycle_trace_mtl_state[sample_index],
                    redirect_cycle_trace_mtl_states[sample_index],
                    redirect_cycle_trace_xlate[sample_index],
                    redirect_cycle_trace_xlate_slot[sample_index],
                    redirect_cycle_trace_pmp_fetch[sample_index],
                    redirect_cycle_trace_l1_launch[sample_index],
                    redirect_cycle_trace_screen_hit[sample_index],
                    redirect_cycle_trace_screen_launch[sample_index],
                    redirect_cycle_trace_screen_bypass[sample_index],
                    redirect_cycle_trace_l1_req_valid[sample_index],
                    redirect_cycle_trace_l1_req_fire[sample_index],
                    redirect_cycle_trace_l1_resp[sample_index],
                    redirect_cycle_trace_pipe_resp[sample_index],
                    redirect_cycle_trace_pipe_resp_target[sample_index],
                    redirect_cycle_trace_ingress_hit[sample_index],
                    redirect_cycle_trace_line_hit[sample_index],
                    redirect_cycle_trace_redirect_pending[sample_index],
                    redirect_cycle_trace_external_miss[sample_index]);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        max_cycles = 250000;
        expected_a0 = 0;
        expected_a0_valid = 1'b0;
        done_pc = 0;
        done_pc_valid = 1'b0;
        retired = 0;
        progress_interval_cycles = 0;
        progress_next_cycle = 0;
        icx_requests = 0;
        icx_fetch_reads = 0;
        icx_data_reads = 0;
        icx_data_writes = 0;
        icx_ptw_reads = 0;
        dtlb_fast_loads = 0;
        dtlb_fast_stores = 0;
        dtlb_access_overlap_loads = 0;
        dtlb_serial_loads = 0;
        dtlb_serial_stores = 0;
        require_sv39 = $test$plusargs("require_sv39");
        require_sv39_active =
            $test$plusargs("fence_sv39_active");
        require_zero_scatter =
            $test$plusargs("require_zero_scatter");
        saw_sv39 = 1'b0;
        saw_supervisor = 1'b0;
        saw_sv39_alias_fetch = 1'b0;
        saw_sv39_alias_data = 1'b0;
        zero_scatter_xlates = 0;
        zero_scatter_accesses = 0;
        zero_scatter_mapping_errors = 0;
        zero_scatter_expected_paddr = 64'd0;
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
        l1i_next_line_hints = 0;
        l1i_next_line_enqueues = 0;
        l1i_prefetch_probes = 0;
        l1i_prefetch_miss_completions = 0;
        l1d_prefetch_issued = 0;
        l1d_prefetch_useful = 0;
        l1d_prefetch_on_time_useful = 0;
        l1d_prefetch_late_useful = 0;
        l1d_prefetch_late = 0;
        l1d_prefetch_late_queued = 0;
        l1d_prefetch_late_command = 0;
        l1d_prefetch_late_mshr = 0;
        l1d_prefetch_dropped = 0;
        l1d_prefetch_useless = 0;
        l1d_prefetch_max_depth = 0;
        l1d_prefetch_trace_fd = 0;
        l1d_prefetch_trace_path = "l1d-prefetch.trace";
        if ($value$plusargs("l1d_prefetch_trace=%s",
                            l1d_prefetch_trace_path)) begin
            l1d_prefetch_trace_fd =
                $fopen(l1d_prefetch_trace_path, "w");
            if (l1d_prefetch_trace_fd == 0)
                $fatal(1, "cannot open L1D prefetch trace %0s",
                       l1d_prefetch_trace_path);
            $fdisplay(
                l1d_prefetch_trace_fd,
                "cycle,event,address,stream,distance,depth,queue_occupancy,mshr_occupancy,long_mask,slot,txn");
        end
        l1d_store_poison_any_events = 0;
        l1d_store_poison_prefetch_events = 0;
        l1d_store_poison_prefetch_queue = 0;
        l1d_store_poison_prefetch_command = 0;
        l1d_store_poison_prefetch_mshr = 0;
        l1d_store_poison_prefetch_fill = 0;
        l1d_store_poison_demand_events = 0;
        l1d_store_poison_demand_wait_prefetch = 0;
        l1d_store_poison_demand_fill = 0;
        l1d_store_overlay_demand_mshr = 0;
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
        completed_control_load_candidate_cycles = 0;
        completed_control_load_gate_cycles = 0;
        completed_control_load_candidate_entry_cycles = 0;
        completed_control_load_gate_entry_cycles = 0;
        waw_hazard_cycles = 0;
        read_port_hazard_cycles = 0;
        write_busy_cycles = 0;
        barrier_cycles = 0;
        retire_nonempty = 0;
        retire_nonempty_no_retire = 0;
        retire_head_incomplete = 0;
        retire_completed_behind_head = 0;
        retire_head_wait_alu = 0;
        retire_head_wait_branch = 0;
        retire_head_wait_jump = 0;
        retire_head_wait_load = 0;
        retire_head_wait_store = 0;
        retire_head_mem_lsq_absent = 0;
        retire_head_mem_absent_unissued = 0;
        retire_head_mem_absent_issued = 0;
        retire_head_mem_absent_result = 0;
        retire_head_mem_absent_complete = 0;
        retire_head_mem_wait_xlate = 0;
        retire_head_mem_wait_access = 0;
        retire_head_mem_access_inflight = 0;
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
        fetch_page_screen_requests = 0;
        fetch_page_screen_hits = 0;
        fetch_page_screen_redirect_hits = 0;
        fetch_page_screen_predicted_hits = 0;
        fetch_page_screen_correction_hits = 0;
        fetch_page_screen_fills = 0;
        fetch_page_screen_launches = 0;
        fetch_page_screen_bypasses = 0;
        fetch_page_screen_invalidates = 0;
        lsu_page_screen_requests = 0;
        lsu_page_screen_store_requests = 0;
        lsu_page_screen_hits = 0;
        lsu_page_screen_store_hits = 0;
        lsu_page_screen_fills = 0;
        lsu_page_screen_invalidates = 0;
        fetch_redirect_events = 0;
        fetch_predicted_redirect_events = 0;
        fetch_correction_redirect_events = 0;
        fetch_target_correction_events = 0;
        fetch_control_restart_events = 0;
        fetch_exception_redirect_events = 0;
        fetch_other_redirect_events = 0;
        fetch_redirect_lookaside_hits = 0;
        fetch_predicted_redirect_lookaside_hits = 0;
        fetch_correction_redirect_lookaside_hits = 0;
        fetch_correction_lookaside_no_context = 0;
        fetch_correction_lookaside_context_pending = 0;
        fetch_correction_lookaside_context_not_pending = 0;
        post_redirect_completed_events = 0;
        post_redirect_superseded_events = 0;
        post_redirect_stalled_events = 0;
        post_redirect_zero_stall_events = 0;
        post_redirect_empty_cycles = 0;
        post_redirect_critical_empty_cycles = 0;
        post_redirect_current_pending_cycles = 0;
        post_redirect_other_pending_cycles = 0;
        post_redirect_no_pending_cycles = 0;
        post_redirect_external_miss_cycles = 0;
        post_redirect_request_wait_cycles = 0;
        post_redirect_predicted_empty_cycles = 0;
        post_redirect_correction_empty_cycles = 0;
        post_redirect_restart_empty_cycles = 0;
        post_redirect_other_empty_cycles = 0;
        post_redirect_lookaside_hit_empty_cycles = 0;
        post_redirect_lookaside_miss_empty_cycles = 0;
        post_redirect_lookaside_hit_stalled_events = 0;
        post_redirect_lookaside_hit_zero_stall_events = 0;
        post_redirect_lookaside_miss_stalled_events = 0;
        post_redirect_lookaside_miss_zero_stall_events = 0;
        post_redirect_correction_lookaside_hit_empty_cycles = 0;
        post_redirect_correction_no_context_empty_cycles = 0;
        post_redirect_correction_context_pending_empty_cycles = 0;
        post_redirect_correction_context_not_pending_empty_cycles = 0;
        post_redirect_episode_cycles = 0;
        post_redirect_max_empty_cycles = 0;
        post_redirect_completed_empty_cycles = 0;
        post_redirect_superseded_empty_cycles = 0;
        for (post_redirect_hist_init = 0;
             post_redirect_hist_init < 14;
             post_redirect_hist_init = post_redirect_hist_init + 1) begin
            post_redirect_hist[post_redirect_hist_init] = 0;
            post_redirect_predicted_hist[post_redirect_hist_init] = 0;
            post_redirect_correction_hist[post_redirect_hist_init] = 0;
        end
        post_redirect_hist_bucket = 0;
        post_redirect_active = 1'b0;
        post_redirect_lookaside_hit = 1'b0;
        post_redirect_correction_miss_reason = 2'd0;
        post_redirect_kind = 2'd0;
        redirect_cycle_trace_enabled =
            $test$plusargs("redirect_cycle_trace");
        redirect_cycle_trace_skip = 2000;
        redirect_cycle_trace_limit = 50;
        if (!$value$plusargs("redirect_cycle_trace_skip=%d",
                            redirect_cycle_trace_skip)) begin
        end
        if (!$value$plusargs("redirect_cycle_trace_limit=%d",
                            redirect_cycle_trace_limit)) begin
        end
        redirect_cycle_trace_seen = 0;
        redirect_cycle_trace_captured = 0;
        redirect_cycle_trace_superseded = 0;
        redirect_cycle_trace_length = 0;
        redirect_cycle_trace_empty = 0;
        redirect_cycle_trace_start = 0;
        redirect_cycle_trace_kind = 0;
        redirect_cycle_trace_active = 1'b0;
        redirect_cycle_trace_truncated = 1'b0;
        redirect_cycle_trace_target = 64'd0;
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
        icx_request_wait = 0;
        icx_read_request_wait = 0;
        icx_write_request_wait = 0;
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
        if ($value$plusargs("progress_cycles=%d",
                            progress_interval_cycles) &&
            (progress_interval_cycles > 0))
            progress_next_cycle = progress_interval_cycles;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (cycles = 0; (cycles < max_cycles) && !run_done;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            retired = retired + dut.backend_retire_count;
            if ((progress_interval_cycles > 0) &&
                ((cycles + 1) >= progress_next_cycle)) begin
                $display(
                    "SIM_PROGRESS cycles=%0d retired=%0d IPC=%0.4f pc=%016h",
                    cycles + 1, retired,
                    $itor(retired) / $itor(cycles + 1), dbg_pc);
                progress_next_cycle =
                    progress_next_cycle + progress_interval_cycles;
            end
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
                completed_control_load_candidate_entry_cycles =
                    completed_control_load_candidate_entry_cycles +
                    trace_completed_control_load_candidate;
                completed_control_load_gate_entry_cycles =
                    completed_control_load_gate_entry_cycles +
                    trace_completed_control_load_gate;
                if (trace_completed_control_load_candidate != 0)
                    completed_control_load_candidate_cycles =
                        completed_control_load_candidate_cycles + 1;
                if (trace_completed_control_load_gate != 0)
                    completed_control_load_gate_cycles =
                        completed_control_load_gate_cycles + 1;
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
                    case (trace_retire_head_op)
                        PERF_OP_BRANCH:
                            retire_head_wait_branch =
                                retire_head_wait_branch + 1;
                        PERF_OP_JUMP:
                            retire_head_wait_jump =
                                retire_head_wait_jump + 1;
                        PERF_OP_LOAD:
                            retire_head_wait_load =
                                retire_head_wait_load + 1;
                        PERF_OP_STORE:
                            retire_head_wait_store =
                                retire_head_wait_store + 1;
                        default:
                            retire_head_wait_alu =
                                retire_head_wait_alu + 1;
                    endcase
                    if ((trace_retire_head_op == PERF_OP_LOAD) ||
                        (trace_retire_head_op == PERF_OP_STORE)) begin
                        if (!trace_retire_head_lsq_valid) begin
                            retire_head_mem_lsq_absent =
                                retire_head_mem_lsq_absent + 1;
                            if (trace_retire_head_lsq_result)
                                retire_head_mem_absent_result =
                                    retire_head_mem_absent_result + 1;
                            else if (trace_retire_head_lsu_complete)
                                retire_head_mem_absent_complete =
                                    retire_head_mem_absent_complete + 1;
                            else if (trace_retire_head_window_valid &&
                                     trace_retire_head_window_issued)
                                retire_head_mem_absent_issued =
                                    retire_head_mem_absent_issued + 1;
                            else
                                retire_head_mem_absent_unissued =
                                    retire_head_mem_absent_unissued + 1;
                        end else if (!trace_retire_head_lsq_xlate_done)
                            retire_head_mem_wait_xlate =
                                retire_head_mem_wait_xlate + 1;
                        else if (!trace_retire_head_lsq_access_sent)
                            retire_head_mem_wait_access =
                                retire_head_mem_wait_access + 1;
                        else
                            retire_head_mem_access_inflight =
                                retire_head_mem_access_inflight + 1;
                    end
                end
            end
            if (dut.fetch_decode_valid == 0)
                frontend_empty = frontend_empty + 1;
            if ((dut.fetch_decode_valid != 0) &&
                (dut.frontend_decode_fire == 0))
                frontend_held = frontend_held + 1;
            if (dut.fetch_pipe_req_valid && !dut.fetch_pipe_req_ready)
                frontend_request_wait = frontend_request_wait + 1;
            if (dut.fetch_pipe_req_valid && dut.fetch_pipe_req_ready)
                fetch_page_screen_requests =
                    fetch_page_screen_requests + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug
                    .fetch_page_screen_accept) begin
                fetch_page_screen_hits = fetch_page_screen_hits + 1;
                if (dut.fetch3_restart) begin
                    fetch_page_screen_redirect_hits =
                        fetch_page_screen_redirect_hits + 1;
                    if (dut.bp_predict_redirect)
                        fetch_page_screen_predicted_hits =
                            fetch_page_screen_predicted_hits + 1;
                    else if (dut.control_redirect)
                        fetch_page_screen_correction_hits =
                            fetch_page_screen_correction_hits + 1;
                end
            end
            if (dut.u_bus.g_icx.u_bus.u_debug.fetch_page_screen_fill)
                fetch_page_screen_fills = fetch_page_screen_fills + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug.fetch_page_screen_launch)
                fetch_page_screen_launches =
                    fetch_page_screen_launches + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug
                    .fetch_page_screen_resp_bypass &&
                dut.fetch_pipe_resp_ready)
                fetch_page_screen_bypasses =
                    fetch_page_screen_bypasses + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug
                    .fetch_page_screen_invalidate)
                fetch_page_screen_invalidates =
                    fetch_page_screen_invalidates + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug.lsu_xlate_accept)
                lsu_page_screen_requests = lsu_page_screen_requests + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug.lsu_xlate_write_accept)
                lsu_page_screen_store_requests =
                    lsu_page_screen_store_requests + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug.lsu_page_screen_accept)
                lsu_page_screen_hits = lsu_page_screen_hits + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug
                    .lsu_page_screen_write_accept)
                lsu_page_screen_store_hits =
                    lsu_page_screen_store_hits + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug.lsu_page_screen_fill)
                lsu_page_screen_fills = lsu_page_screen_fills + 1;
            if (dut.u_bus.g_icx.u_bus.u_debug
                    .lsu_page_screen_invalidate)
                lsu_page_screen_invalidates =
                    lsu_page_screen_invalidates + 1;
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
                if (dut.u_bus.g_icx.u_bus.u_l1i
                        .demand_mshr_any_valid_r)
                    frontend_empty_l1i_external_miss =
                        frontend_empty_l1i_external_miss + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.demand_pending_any ||
                          (dut.u_bus.g_icx.u_bus.fetch_count_q != 0)))
                    frontend_empty_pending_no_external_miss =
                        frontend_empty_pending_no_external_miss + 1;
                if (dut.control_flush || dut.control_redirect)
                    frontend_control_empty = frontend_control_empty + 1;
                else if (dut.bp_fetch_stall)
                    frontend_bp_stall = frontend_bp_stall + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.demand_pending_any ||
                          (dut.u_bus.g_icx.u_bus.fetch_count_q != 0)))
                    frontend_refill_wait = frontend_refill_wait + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit)
                    frontend_no_line = frontend_no_line + 1;
                else
                    frontend_other_empty = frontend_other_empty + 1;
            end
            // A redirect episode begins on the fetch restart edge and ends
            // when the redirected stream exposes its first decode bundle.
            // A newer redirect may supersede an episode before that happens;
            // report those separately rather than pretending they completed.
            if (dut.fetch3_restart && !dut.reset_pending_q) begin
                fetch_redirect_events = fetch_redirect_events + 1;
                if (post_redirect_active) begin
                    post_redirect_superseded_events =
                        post_redirect_superseded_events + 1;
                    post_redirect_superseded_empty_cycles =
                        post_redirect_superseded_empty_cycles +
                        post_redirect_episode_cycles;
                end
                post_redirect_active = 1'b1;
                post_redirect_episode_cycles = 0;
                post_redirect_lookaside_hit = dut.fetch_alt_restart_hit;
                post_redirect_correction_miss_reason = 2'd0;
                if (dut.control_redirect) begin
                    fetch_correction_redirect_events =
                        fetch_correction_redirect_events + 1;
                    post_redirect_kind = 2'd1;
                    if (dut.fetch_alt_restart_hit)
                        fetch_correction_redirect_lookaside_hits =
                            fetch_correction_redirect_lookaside_hits + 1;
                    else if (!dut.g_fetch_axi.u_fetch.u_debug
                                     .alt_restart_context_match_r) begin
                        fetch_correction_lookaside_no_context =
                            fetch_correction_lookaside_no_context + 1;
                        post_redirect_correction_miss_reason = 2'd1;
                    end else if (dut.g_fetch_axi.u_fetch.u_debug
                                      .alt_restart_target_pending_r) begin
                        fetch_correction_lookaside_context_pending =
                            fetch_correction_lookaside_context_pending + 1;
                        post_redirect_correction_miss_reason = 2'd2;
                    end else begin
                        fetch_correction_lookaside_context_not_pending =
                            fetch_correction_lookaside_context_not_pending + 1;
                        post_redirect_correction_miss_reason = 2'd3;
                    end
                    if (dut.bp_target_mispredict_effective)
                        fetch_target_correction_events =
                            fetch_target_correction_events + 1;
                end else if (dut.bp_predict_redirect) begin
                    fetch_predicted_redirect_events =
                        fetch_predicted_redirect_events + 1;
                    post_redirect_kind = 2'd0;
                    if (dut.fetch_alt_restart_hit)
                        fetch_predicted_redirect_lookaside_hits =
                            fetch_predicted_redirect_lookaside_hits + 1;
                end else if (dut.control_restart) begin
                    fetch_control_restart_events =
                        fetch_control_restart_events + 1;
                    post_redirect_kind = 2'd2;
                end else if (dut.except_vector_valid) begin
                    fetch_exception_redirect_events =
                        fetch_exception_redirect_events + 1;
                    post_redirect_kind = 2'd2;
                end else begin
                    fetch_other_redirect_events =
                        fetch_other_redirect_events + 1;
                    post_redirect_kind = 2'd3;
                end
                if (dut.fetch_alt_restart_hit)
                    fetch_redirect_lookaside_hits =
                        fetch_redirect_lookaside_hits + 1;
            end else if (post_redirect_active) begin
                // restart_i updates consume_pc_q on the restart edge.  Begin
                // sampling here, on the following cycle, so raw decode-valid
                // belongs to the redirected PC rather than the abandoned
                // stream which happened to be visible during correction.
                if (dut.fetch_decode_valid == 0) begin
                    post_redirect_empty_cycles =
                        post_redirect_empty_cycles + 1;
                    post_redirect_episode_cycles =
                        post_redirect_episode_cycles + 1;
                    if (post_redirect_episode_cycles >
                        post_redirect_max_empty_cycles)
                        post_redirect_max_empty_cycles =
                            post_redirect_episode_cycles;
                    if (dut.backend_dispatch_occupancy == 0 &&
                        dut.backend_decode_ready[0] &&
                        dut.frontend_decode_enable)
                        post_redirect_critical_empty_cycles =
                            post_redirect_critical_empty_cycles + 1;
                    if (dut.g_fetch_axi.u_fetch.consume_line_pending)
                        post_redirect_current_pending_cycles =
                            post_redirect_current_pending_cycles + 1;
                    else if (dut.g_fetch_axi.u_fetch.demand_pending_any ||
                             (dut.u_bus.g_icx.u_bus.fetch_count_q != 0))
                        post_redirect_other_pending_cycles =
                            post_redirect_other_pending_cycles + 1;
                    else
                        post_redirect_no_pending_cycles =
                            post_redirect_no_pending_cycles + 1;
                    if (dut.u_bus.g_icx.u_bus.u_l1i
                            .demand_mshr_any_valid_r)
                        post_redirect_external_miss_cycles =
                            post_redirect_external_miss_cycles + 1;
                    if (dut.fetch_pipe_req_valid &&
                        !dut.fetch_pipe_req_ready)
                        post_redirect_request_wait_cycles =
                            post_redirect_request_wait_cycles + 1;
                    if (post_redirect_lookaside_hit)
                        post_redirect_lookaside_hit_empty_cycles =
                            post_redirect_lookaside_hit_empty_cycles + 1;
                    else
                        post_redirect_lookaside_miss_empty_cycles =
                            post_redirect_lookaside_miss_empty_cycles + 1;
                    case (post_redirect_kind)
                        2'd0: post_redirect_predicted_empty_cycles =
                            post_redirect_predicted_empty_cycles + 1;
                        2'd1: post_redirect_correction_empty_cycles =
                            post_redirect_correction_empty_cycles + 1;
                        2'd2: post_redirect_restart_empty_cycles =
                            post_redirect_restart_empty_cycles + 1;
                        default: post_redirect_other_empty_cycles =
                            post_redirect_other_empty_cycles + 1;
                    endcase
                    if (post_redirect_kind == 2'd1) begin
                        if (post_redirect_lookaside_hit)
                            post_redirect_correction_lookaside_hit_empty_cycles =
                                post_redirect_correction_lookaside_hit_empty_cycles +
                                1;
                        case (post_redirect_correction_miss_reason)
                            2'd1:
                                post_redirect_correction_no_context_empty_cycles =
                                    post_redirect_correction_no_context_empty_cycles +
                                    1;
                            2'd2:
                                post_redirect_correction_context_pending_empty_cycles =
                                    post_redirect_correction_context_pending_empty_cycles +
                                    1;
                            2'd3:
                                post_redirect_correction_context_not_pending_empty_cycles =
                                    post_redirect_correction_context_not_pending_empty_cycles +
                                    1;
                            default: begin
                            end
                        endcase
                    end
                end else begin
                    post_redirect_completed_events =
                        post_redirect_completed_events + 1;
                    post_redirect_completed_empty_cycles =
                        post_redirect_completed_empty_cycles +
                        post_redirect_episode_cycles;
                    if (post_redirect_episode_cycles < 8)
                        post_redirect_hist_bucket =
                            post_redirect_episode_cycles;
                    else if (post_redirect_episode_cycles < 16)
                        post_redirect_hist_bucket = 8;
                    else if (post_redirect_episode_cycles < 32)
                        post_redirect_hist_bucket = 9;
                    else if (post_redirect_episode_cycles < 64)
                        post_redirect_hist_bucket = 10;
                    else if (post_redirect_episode_cycles < 128)
                        post_redirect_hist_bucket = 11;
                    else if (post_redirect_episode_cycles < 256)
                        post_redirect_hist_bucket = 12;
                    else
                        post_redirect_hist_bucket = 13;
                    post_redirect_hist[post_redirect_hist_bucket] =
                        post_redirect_hist[post_redirect_hist_bucket] + 1;
                    if (post_redirect_kind == 2'd0)
                        post_redirect_predicted_hist[
                            post_redirect_hist_bucket] =
                            post_redirect_predicted_hist[
                                post_redirect_hist_bucket] + 1;
                    else if (post_redirect_kind == 2'd1)
                        post_redirect_correction_hist[
                            post_redirect_hist_bucket] =
                            post_redirect_correction_hist[
                                post_redirect_hist_bucket] + 1;
                    if (post_redirect_episode_cycles == 0)
                        post_redirect_zero_stall_events =
                            post_redirect_zero_stall_events + 1;
                    else
                        post_redirect_stalled_events =
                            post_redirect_stalled_events + 1;
                    if (post_redirect_lookaside_hit) begin
                        if (post_redirect_episode_cycles == 0)
                            post_redirect_lookaside_hit_zero_stall_events =
                                post_redirect_lookaside_hit_zero_stall_events +
                                1;
                        else
                            post_redirect_lookaside_hit_stalled_events =
                                post_redirect_lookaside_hit_stalled_events + 1;
                    end else begin
                        if (post_redirect_episode_cycles == 0)
                            post_redirect_lookaside_miss_zero_stall_events =
                                post_redirect_lookaside_miss_zero_stall_events +
                                1;
                        else
                            post_redirect_lookaside_miss_stalled_events =
                                post_redirect_lookaside_miss_stalled_events +
                                1;
                    end
                    post_redirect_active = 1'b0;
                end
            end
            if ((redirect_cycle_trace_enabled != 0) &&
                dut.fetch3_restart && !dut.reset_pending_q) begin
                if (redirect_cycle_trace_active)
                    redirect_cycle_trace_superseded =
                        redirect_cycle_trace_superseded + 1;
                redirect_cycle_trace_seen =
                    redirect_cycle_trace_seen + 1;
                redirect_cycle_trace_active =
                    (redirect_cycle_trace_seen >
                     redirect_cycle_trace_skip) &&
                    (redirect_cycle_trace_captured <
                     redirect_cycle_trace_limit);
                if (redirect_cycle_trace_active) begin
                    redirect_cycle_trace_length = 0;
                    redirect_cycle_trace_empty = 0;
                    redirect_cycle_trace_start = cycles;
                    redirect_cycle_trace_kind =
                        dut.control_redirect ? 1 :
                        (dut.bp_predict_redirect ? 0 : 2);
                    redirect_cycle_trace_target = dut.fetch3_restart_pc;
                    redirect_cycle_trace_truncated = 1'b0;
                    sample_redirect_cycle_trace();
                end
            end else if (redirect_cycle_trace_active) begin
                if (dut.fetch_decode_valid == 0)
                    redirect_cycle_trace_empty =
                        redirect_cycle_trace_empty + 1;
                sample_redirect_cycle_trace();
                if (dut.fetch_decode_valid != 0) begin
                    if (redirect_cycle_trace_empty != 0) begin
                        redirect_cycle_trace_captured =
                            redirect_cycle_trace_captured + 1;
                        emit_redirect_cycle_trace();
                    end
                    redirect_cycle_trace_active = 1'b0;
                end
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
            if (dut.u_bus.g_icx.u_bus.l1d_req_valid &&
                !dut.u_bus.g_icx.u_bus.l1d_req_ready) begin
                l1d_request_wait = l1d_request_wait + 1;
                if (dut.u_bus.g_icx.u_bus.l1d_req_write)
                    l1d_store_request_wait =
                        l1d_store_request_wait + 1;
                else
                    l1d_load_request_wait =
                        l1d_load_request_wait + 1;
                if (dut.u_bus.g_icx.u_bus.u_l1d.
                        demand_load_store_block)
                    l1d_wait_store_block =
                        l1d_wait_store_block + 1;
                else if (!dut.u_bus.g_icx.u_bus.u_l1d.
                             lock_request_ready)
                    l1d_wait_lock_barrier =
                        l1d_wait_lock_barrier + 1;
                else if (dut.u_bus.g_icx.u_bus.u_l1d.
                             response_tag_full)
                    l1d_wait_response_tags =
                        l1d_wait_response_tags + 1;
                else if (!dut.u_bus.g_icx.u_bus.u_l1d.l1_req_ready) begin
                    case (dut.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
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
            if (dut.u_bus.g_icx.u_bus.l1d_req_valid &&
                dut.u_bus.g_icx.u_bus.l1d_req_ready &&
                !dut.u_bus.g_icx.u_bus.l1d_req_write &&
                dut.u_bus.g_icx.u_bus.u_l1d.
                    demand_load_store_conflict_r &&
                !dut.u_bus.g_icx.u_bus.u_l1d.
                    demand_load_store_block)
                l1d_dirty_snoop_accepts =
                    l1d_dirty_snoop_accepts + 1;
            if (icx_req_valid && !icx_req_ready) begin
                icx_request_wait = icx_request_wait + 1;
                if (icx_req_op == `OPENRV64_ICX_OP_WRITE)
                    icx_write_request_wait =
                        icx_write_request_wait + 1;
                else
                    icx_read_request_wait =
                        icx_read_request_wait + 1;
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
            if (icx_req_valid && icx_req_ready) begin
                icx_requests = icx_requests + 1;
                if (icx_req_source_id == `OPENRV64_ICX_SOURCE_ICACHE)
                    icx_fetch_reads = icx_fetch_reads + 1;
                else if (icx_req_source_id ==
                         `OPENRV64_ICX_SOURCE_PTW)
                    icx_ptw_reads = icx_ptw_reads + 1;
                else if (icx_req_op == `OPENRV64_ICX_OP_READ)
                    icx_data_reads = icx_data_reads + 1;
                else if (icx_req_op == `OPENRV64_ICX_OP_WRITE)
                    icx_data_writes = icx_data_writes + 1;
                if ((icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_ICACHE) &&
                    (dut.csr_priv_mode == `RV64_PRIV_S) &&
                    (icx_req_addr >= 64'h0000_0000_8000_1000) &&
                    (icx_req_addr < 64'h0000_0000_8000_2000))
                    saw_sv39_alias_fetch = 1'b1;
                if ((icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_DCACHE) &&
                    (dut.csr_priv_mode == `RV64_PRIV_S) &&
                    (icx_req_addr >= 64'h0000_0000_8000_0000) &&
                    (icx_req_addr <
                     (64'h0000_0000_8000_0000 + RAM_BYTES)))
                    saw_sv39_alias_data = 1'b1;
            end
            if (dut.u_bus.g_icx.u_bus.xlate_request_fire &&
                dut.u_bus.g_icx.u_bus.lsu_xlate_req_write_i &&
                (dut.u_bus.g_icx.u_bus.lsu_xlate_req_vaddr_i >=
                 64'h0000_0000_4004_0000) &&
                (dut.u_bus.g_icx.u_bus.lsu_xlate_req_vaddr_i <
                 64'h0000_0000_4008_0000))
                zero_scatter_xlates = zero_scatter_xlates + 1;
            if (dut.u_bus.g_icx.u_bus.pipe_fast_request_fire &&
                dut.u_bus.g_icx.u_bus.lsu_pipe_req_write_i &&
                (dut.backend_mem_effective_addr >=
                 64'h0000_0000_4004_0000) &&
                (dut.backend_mem_effective_addr <
                 64'h0000_0000_4008_0000)) begin
                zero_scatter_accesses = zero_scatter_accesses + 1;
                zero_scatter_expected_paddr =
                    64'h0000_0000_8020_0000 +
                    ((((dut.backend_mem_effective_addr -
                        64'h0000_0000_4004_0000) >> 12) << 13)) +
                    (dut.backend_mem_effective_addr &
                     64'h0000_0000_0000_0fff);
                if (dut.backend_mem_addr !=
                    zero_scatter_expected_paddr)
                    zero_scatter_mapping_errors =
                        zero_scatter_mapping_errors + 1;
            end
            // The LSQ translates at admission. Count micro/main-TLB fast
            // accepts independently from later physical L1D accesses.
            if (dut.u_bus.g_icx.u_bus.xlate_request_fire &&
                (dut.u_bus.g_icx.u_bus.xlate_l1_hit ||
                 dut.u_bus.g_icx.u_bus.xlate_l2_hit)) begin
                if (dut.u_bus.g_icx.u_bus.lsu_xlate_req_write_i)
                    dtlb_fast_stores = dtlb_fast_stores + 1;
                else
                    dtlb_fast_loads = dtlb_fast_loads + 1;
            end
            // This is actual channel overlap, not a fused translation/cache
            // lookup: a younger load translation and an older physical L1D
            // request were both accepted on this cycle.
            if (dut.u_bus.g_icx.u_bus.xlate_request_fire &&
                !dut.u_bus.g_icx.u_bus.lsu_xlate_req_write_i &&
                dut.u_bus.g_icx.u_bus.pipe_fast_request_fire)
                dtlb_access_overlap_loads =
                    dtlb_access_overlap_loads + 1;
            if (dut.u_bus.g_icx.u_bus.serial_dtlb_lookup &&
                dut.u_bus.g_icx.u_bus.dtlb_lookup_hit &&
                !dut.u_bus.g_icx.u_bus.dtlb_lookup_page_fault &&
                dut.u_bus.g_icx.u_bus.lsu_xlate_only_q) begin
                if (dut.u_bus.g_icx.u_bus.lsu_write_q)
                    dtlb_serial_stores = dtlb_serial_stores + 1;
                else
                    dtlb_serial_loads = dtlb_serial_loads + 1;
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
            if (dut.l1i_next_line_prefetch)
                l1i_next_line_hints = l1i_next_line_hints + 1;
            if (dut.l1i_next_line_prefetch &&
                dut.u_bus.g_icx.u_bus.u_l1i.enqueue_taken_r)
                l1i_next_line_enqueues = l1i_next_line_enqueues + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1i.l1_request_fire &&
                dut.u_bus.g_icx.u_bus.u_l1i.select_prefetch)
                l1i_prefetch_probes = l1i_prefetch_probes + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1i.l1_mem_valid &&
                dut.u_bus.g_icx.u_bus.u_l1i.l1_mem_ready &&
                dut.u_bus.g_icx.u_bus.u_l1i.cache_prefetch_q)
                l1i_prefetch_miss_completions =
                    l1i_prefetch_miss_completions + 1;
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
            if (l1d_prefetch_trace_fd != 0) begin
                l1d_prefetch_trace_queue_occupancy = 0;
                for (l1d_prefetch_trace_scan = 0;
                     l1d_prefetch_trace_scan <
                         L1D_PREFETCH_QUEUE_LINES;
                     l1d_prefetch_trace_scan =
                         l1d_prefetch_trace_scan + 1)
                    if (dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_candidate_valid_q[
                                l1d_prefetch_trace_scan])
                        l1d_prefetch_trace_queue_occupancy =
                            l1d_prefetch_trace_queue_occupancy + 1;
                l1d_prefetch_trace_mshr_occupancy = 0;
                for (l1d_prefetch_trace_scan = 0;
                     l1d_prefetch_trace_scan <
                         L1D_PREFETCH_OUTSTANDING;
                     l1d_prefetch_trace_scan =
                         l1d_prefetch_trace_scan + 1)
                    if (dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_mshr_valid_q[
                                l1d_prefetch_trace_scan])
                        l1d_prefetch_trace_mshr_occupancy =
                            l1d_prefetch_trace_mshr_occupancy + 1;
                l1d_prefetch_trace_long_mask = 0;
                for (l1d_prefetch_trace_scan = 0;
                     l1d_prefetch_trace_scan <
                         L1D_PREFETCH_STREAMS;
                     l1d_prefetch_trace_scan =
                         l1d_prefetch_trace_scan + 1)
                    if (dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_stream_long_q[
                                l1d_prefetch_trace_scan])
                        l1d_prefetch_trace_long_mask =
                            l1d_prefetch_trace_long_mask |
                            (1 << l1d_prefetch_trace_scan);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .demand_request_fire &&
                    !dut.u_bus.g_icx.u_bus.u_l1d.req_write_i &&
                    dut.u_bus.g_icx.u_bus.u_l1d.l1_req_cacheable)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,DEMAND,%016h,-1,0,%0d,%0d,%0d,%0h,-1,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d.demand_line_addr,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask);
                if (dut.u_bus.g_icx.u_bus.u_l1d.l1_miss_fire)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,MISS,%016h,-1,0,%0d,%0d,%0d,%0h,-1,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d.l1_miss_addr,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .prefetch_candidate_queue)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,CANDIDATE,%016h,%0d,%0d,%0d,%0d,%0d,%0h,%0d,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_addr_r,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_stream_r,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_index_r + 1,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_candidate_free_index_r);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .prefetch_candidate_drop)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,DROP,%016h,%0d,%0d,%0d,%0d,%0d,%0h,-1,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_addr_r,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_stream_r,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_generate_index_r + 1,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask);
                if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_launch)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,LAUNCH,%016h,%0d,-1,%0d,%0d,%0d,%0h,%0d,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_launch_addr_r,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_candidate_stream_q[
                                dut.u_bus.g_icx.u_bus.u_l1d
                                    .prefetch_launch_index_r],
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_launch_index_r);
                if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_issued_o)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,ISSUE,%016h,-1,-1,%0d,%0d,%0d,%0h,-1,%0d",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d.request_addr_q,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask,
                        dut.u_bus.g_icx.u_bus.u_l1d.request_txn_id_q);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .prefetch_response_fire)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,RESPONSE,%016h,-1,-1,%0d,%0d,%0d,%0h,%0d,%0d",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_mshr_addr_q[
                                dut.u_bus.g_icx.u_bus.u_l1d
                                    .prefetch_mshr_response_index_r],
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_mshr_response_index_r,
                        dut.u_bus.g_icx.u_bus.u_l1d.icx_resp_txn_id_i);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .prefetch_on_time_useful)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,USE_ON_TIME,%016h,-1,-1,%0d,%0d,%0d,%0h,-1,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_useful_line_addr,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask);
                if (dut.u_bus.g_icx.u_bus.u_l1d
                        .prefetch_late_useful)
                    $fdisplay(
                        l1d_prefetch_trace_fd,
                        "%0d,USE_LATE,%016h,-1,-1,%0d,%0d,%0d,%0h,-1,-1",
                        cycles,
                        dut.u_bus.g_icx.u_bus.u_l1d
                            .prefetch_useful_line_addr,
                        dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_q,
                        l1d_prefetch_trace_queue_occupancy,
                        l1d_prefetch_trace_mshr_occupancy,
                        l1d_prefetch_trace_long_mask);
            end
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_issued_o)
                l1d_prefetch_issued = l1d_prefetch_issued + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_useful_o)
                l1d_prefetch_useful = l1d_prefetch_useful + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_on_time_useful)
                l1d_prefetch_on_time_useful =
                    l1d_prefetch_on_time_useful + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_late_useful)
                l1d_prefetch_late_useful =
                    l1d_prefetch_late_useful + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_late_o)
                l1d_prefetch_late = l1d_prefetch_late + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d
                    .prefetch_queued_demand_match_r)
                l1d_prefetch_late_queued =
                    l1d_prefetch_late_queued + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d
                    .prefetch_inflight_late_match)
                l1d_prefetch_late_command =
                    l1d_prefetch_late_command + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d
                    .prefetch_mshr_late_match_r)
                l1d_prefetch_late_mshr =
                    l1d_prefetch_late_mshr + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_dropped_o)
                l1d_prefetch_dropped = l1d_prefetch_dropped + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_useless_o)
                l1d_prefetch_useless = l1d_prefetch_useless + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_o >
                l1d_prefetch_max_depth)
                l1d_prefetch_max_depth =
                    dut.u_bus.g_icx.u_bus.u_l1d.prefetch_depth_o;
            if (dut.u_bus.g_icx.u_bus.u_l1d.store_poison_any_event_r)
                l1d_store_poison_any_events =
                    l1d_store_poison_any_events + 1;
            if (dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_prefetch_event_r)
                l1d_store_poison_prefetch_events =
                    l1d_store_poison_prefetch_events + 1;
            l1d_store_poison_prefetch_queue =
                l1d_store_poison_prefetch_queue +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_prefetch_queue_count_r;
            l1d_store_poison_prefetch_command =
                l1d_store_poison_prefetch_command +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_prefetch_command_count_r;
            l1d_store_poison_prefetch_mshr =
                l1d_store_poison_prefetch_mshr +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_prefetch_mshr_count_r;
            l1d_store_poison_prefetch_fill =
                l1d_store_poison_prefetch_fill +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_prefetch_fill_count_r;
            if (dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_demand_event_r)
                l1d_store_poison_demand_events =
                    l1d_store_poison_demand_events + 1;
            l1d_store_poison_demand_wait_prefetch =
                l1d_store_poison_demand_wait_prefetch +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_demand_wait_prefetch_count_r;
            l1d_store_poison_demand_fill =
                l1d_store_poison_demand_fill +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_poison_demand_fill_count_r;
            l1d_store_overlay_demand_mshr =
                l1d_store_overlay_demand_mshr +
                dut.u_bus.g_icx.u_bus.u_l1d
                    .store_overlay_demand_mshr_count_r;
        end

        run_completed_q = run_done;
        /*
         * A posted successor is allowed to retire after the ordering point
         * has been observed.  Keep the external model alive long enough to
         * consume its response before checking queue completeness.
         */
        if (run_completed_q && fence_check_enabled_q)
            repeat (FENCE_RESPONSE_DELAY + 4096) @(posedge clk);

        if (!run_completed_q)
            $fatal(1,
                "full-ICX workload timeout pc=%h instr=%h retired=%0d",
                dbg_pc, dbg_instr, retired);
        if (fence_check_enabled_q)
            $display(
                "PERF_FENCE_SV39_CHECK case=%0d requests=%0d completions=%0d ordinary=%0d fence_i=%0d bootstrap_sfence_vma=%0d delayed_cycles=%0d smc_fetches=%0d pressure_lines=%0d violation_mask=%03h",
                fence_case_q,
                fence_external_requests_q,
                fence_external_completions_q,
                fence_retired_q, fence_i_retired_q,
                sfence_vma_retired_q, FENCE_RESPONSE_DELAY,
                fence_smc_fetches_q, 12,
                fence_order_violation_q);
        if (expected_a0_valid &&
            (dut.u_backend.u_gpr.regs[10] != expected_a0))
            $fatal(1, "full-ICX a0=%h expected=%h",
                dut.u_backend.u_gpr.regs[10], expected_a0);
        /*
         * This is an architectural VM requirement. Translation/access
         * overlap is a timing optimization and remains reported separately;
         * an atomic-heavy workload is allowed to serialize every DTLB hit.
         */
        if (require_sv39 &&
            (!saw_sv39 || !saw_supervisor || !saw_sv39_alias_fetch ||
             !saw_sv39_alias_data || (icx_ptw_reads < 3) ||
             (dtlb_fast_loads == 0) || (dtlb_fast_stores == 0)))
            $fatal(1,
                "Sv39 requirement failed: satp=%0b supervisor=%0b alias_fetch=%0b alias_data=%0b ptw_reads=%0d dtlb_fast_loads=%0d dtlb_fast_stores=%0d dtlb_access_overlap_loads=%0d",
                saw_sv39, saw_supervisor, saw_sv39_alias_fetch,
                saw_sv39_alias_data, icx_ptw_reads, dtlb_fast_loads,
                dtlb_fast_stores, dtlb_access_overlap_loads);
        if (require_sv39_active &&
            (!saw_sv39 || !saw_supervisor ||
             !saw_sv39_alias_fetch || (icx_ptw_reads < 3)))
            $fatal(1,
                "active Sv39 requirement failed: satp=%0b supervisor=%0b alias_fetch=%0b ptw_reads=%0d",
                saw_sv39, saw_supervisor, saw_sv39_alias_fetch,
                icx_ptw_reads);
        if (require_zero_scatter &&
            (!saw_sv39 || !saw_supervisor || !saw_sv39_alias_fetch ||
             (icx_ptw_reads < 3) ||
             (zero_scatter_xlates != 32768) ||
             (zero_scatter_accesses != 32768) ||
             (zero_scatter_mapping_errors != 0)))
            $fatal(1,
                "zero scatter requirement failed: satp=%0b supervisor=%0b alias_fetch=%0b ptw_reads=%0d xlates=%0d accesses=%0d mapping_errors=%0d",
                saw_sv39, saw_supervisor, saw_sv39_alias_fetch,
                icx_ptw_reads, zero_scatter_xlates,
                zero_scatter_accesses, zero_scatter_mapping_errors);
        if (fence_check_enabled_q) begin
            case (fence_case_q)
                0: begin
                    if (!fence_ww_pred_done_q ||
                        !fence_wr_pred_done_q ||
                        !fence_rr_pred_done_q ||
                        !fence_rw_pred_done_q ||
                        !fence_partial_done_q ||
                        (fence_pressure_done_q != 12'hfff) ||
                        !fence_smc_store_done_q ||
                        !fence_final_store_done_q ||
                        !fence_ww_succ_seen_q ||
                        !fence_wr_succ_seen_q ||
                        !fence_rr_succ_seen_q ||
                        !fence_rw_succ_seen_q ||
                        !fence_partial_succ_seen_q ||
                        !fence_pressure_succ_seen_q ||
                        (fence_smc_fetches_q < 2))
                        $fatal(1,
                            "combined fence coverage incomplete");
                    if ((fence_retired_q != 11) ||
                        (fence_i_retired_q != 1) ||
                        (sfence_vma_retired_q != 1))
                        $fatal(1,
                            "combined fence retirement coverage ordinary=%0d fence_i=%0d sfence_vma=%0d expected=11/1/1",
                            fence_retired_q, fence_i_retired_q,
                            sfence_vma_retired_q);
                end
                1: begin
                    if (!fence_ww_pred_done_q ||
                        !fence_ww_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1, "FENCE w,w coverage incomplete");
                end
                2: begin
                    if (!fence_wr_pred_done_q ||
                        !fence_wr_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1, "FENCE w,r coverage incomplete");
                end
                3: begin
                    if (!fence_rr_pred_done_q ||
                        !fence_rr_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1, "FENCE r,r coverage incomplete");
                end
                4: begin
                    if (!fence_rw_pred_done_q ||
                        !fence_rw_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1, "FENCE r,w coverage incomplete");
                end
                5: begin
                    if (!fence_oo_pred_done_q ||
                        !fence_oi_pred_done_q ||
                        !fence_ii_pred_done_q ||
                        !fence_io_pred_done_q ||
                        !fence_oo_succ_seen_q ||
                        !fence_oi_succ_seen_q ||
                        !fence_ii_succ_seen_q ||
                        !fence_io_succ_seen_q ||
                        (fence_retired_q != 4))
                        $fatal(1,
                            "fence I/O coverage incomplete pred=%b%b%b%b succ=%b%b%b%b ordinary=%0d",
                            fence_oo_pred_done_q,
                            fence_oi_pred_done_q,
                            fence_ii_pred_done_q,
                            fence_io_pred_done_q,
                            fence_oo_succ_seen_q,
                            fence_oi_succ_seen_q,
                            fence_ii_succ_seen_q,
                            fence_io_succ_seen_q,
                            fence_retired_q);
                end
                6: begin
                    if (!fence_partial_done_q ||
                        !fence_partial_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1,
                            "partial-line fence coverage incomplete");
                end
                7: begin
                    if ((fence_pressure_done_q != 12'hfff) ||
                        !fence_pressure_succ_seen_q ||
                        (fence_retired_q != 1))
                        $fatal(1,
                            "pressure fence coverage incomplete completions=%03h",
                            fence_pressure_done_q);
                end
                8: begin
                    if (!fence_final_store_done_q ||
                        (fence_retired_q != 4))
                        $fatal(1,
                            "empty/back-to-back fence coverage incomplete");
                end
                9: begin
                    if (!fence_smc_store_done_q ||
                        (fence_smc_fetches_q < 2) ||
                        (fence_retired_q != 0) ||
                        (fence_i_retired_q != 1))
                        $fatal(1,
                            "FENCE.I coverage incomplete store=%b fetches=%0d ordinary=%0d fence_i=%0d",
                            fence_smc_store_done_q,
                            fence_smc_fetches_q,
                            fence_retired_q, fence_i_retired_q);
                end
                default:
                    $fatal(1, "unknown fence case %0d", fence_case_q);
            endcase
            if ((fence_case_q != 0) &&
                (sfence_vma_retired_q != 1))
                $fatal(1,
                    "Sv39 bootstrap SFENCE.VMA count=%0d expected=1",
                    sfence_vma_retired_q);
            if ((fence_case_q != 0) && (fence_case_q != 9) &&
                (fence_i_retired_q != 0))
                $fatal(1,
                    "unexpected FENCE.I count=%0d case=%0d",
                    fence_i_retired_q, fence_case_q);
            if (fence_external_requests_q !=
                fence_external_completions_q)
                $fatal(1,
                    "fence external requests remain incomplete requests=%0d completions=%0d",
                    fence_external_requests_q,
                    fence_external_completions_q);
        end
        ipc = (cycles != 0) ? $itor(retired) / $itor(cycles) : 0.0;
        $display(
            "PERF_ICX_L2 mode=%0d carousel=%0d confidence_gate=%0d bp=%0d completion_forward_mask=%0d branch_forward_mask=%0d full_forwarding=%0d relax_waw=%0d relax_hazards=%0d issue_window=%0d speculation_window=%0d result_ready_control_release=%0d retire_depth=%0d posted_stores=%0d timed_memory=%0d memory_timing_model=%0d cycles=%0d retired=%0d IPC=%0.4f a0=%016h l1i_bytes=%0d l1i_fetch_width=%0d l1d_bytes=%0d l2_bytes=%0d l2_ways=%0d ram_bytes=%0d",
            FETCH_ALT_LOOKASIDE, FETCH_CAROUSEL,
            FETCH_ALT_CONFIDENCE_GATE, BP_TYPE,
            COMPLETION_FORWARD_MASK, BRANCH_COMPLETION_FORWARD_MASK,
            ENABLE_FULL_FORWARDING, RELAX_WAW, RELAX_HAZARDS,
            ISSUE_WINDOW, SPECULATION_WINDOW,
            `OPENRV64_3P_RESULT_READY_CONTROL_RELEASE, RETIRE_DEPTH,
            ENABLE_POSTED_STORES, DDR3_ENABLE, MEMORY_TIMING_MODEL,
            cycles, retired, ipc,
            dut.u_backend.u_gpr.regs[10], L1I_CACHE_BYTES,
            L1I_FETCH_DATA_WIDTH, L1D_CACHE_BYTES, L2_BYTES, L2_WAYS,
            RAM_BYTES);
        if ($test$plusargs("report_a_regs"))
            $display(
                "PERF_FENCE_SV39_RESULTS iters=1024 rr_none=%0d rr=%0d rw_none=%0d rw=%0d wr_none=%0d wr=%0d ww_none=%0d ww=%0d",
                dut.u_backend.u_gpr.regs[10],
                dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[14],
                dut.u_backend.u_gpr.regs[15],
                dut.u_backend.u_gpr.regs[16],
                dut.u_backend.u_gpr.regs[17]);
        if ($test$plusargs("report_pagefree"))
            $display(
                "PERF_PAGEFREE kernel=%0d loop_cycles=%0d loop_instructions=%0d records=%0d drain_cycles=%0d",
                dut.u_backend.u_gpr.regs[10],
                dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[14]);
        if ($test$plusargs("report_blake2s"))
            $display(
                "PERF_BLAKE2S cycles=%0d instructions=%0d calls=%0d blocks_per_call=%0d total_blocks=%0d checksum=%08h input_offset=%0d kernel_zbb=%0d",
                dut.u_backend.u_gpr.regs[10],
                dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[14],
                dut.u_backend.u_gpr.regs[15][31:0],
                dut.u_backend.u_gpr.regs[16],
                dut.u_backend.u_gpr.regs[17]);
        if ($test$plusargs("report_sv39_smoke"))
            $display(
                "PERF_SV39_SMOKE coremark_cycles=%0d blake2s_cycles=%0d stream_cycles=%0d atomic_cycles=%0d fence_cycles=%0d store_extension_cycles=%0d selected_mask=%02h",
                dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[14],
                dut.u_backend.u_gpr.regs[15],
                dut.u_backend.u_gpr.regs[16],
                dut.u_backend.u_gpr.regs[17][7:0]);
        if ($test$plusargs("report_linux_spinlock_sv39"))
            $display(
                "PERF_LINUX_SPINLOCK_SV39 iters=%0d baseline_cycles=%0d ticket_cycles=%0d raw_cycles=%0d irqsave_cycles=%0d baseline_instructions=%0d ticket_instructions=%0d raw_instructions=%0d irqsave_instructions=%0d",
                dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[14],
                dut.u_backend.u_gpr.regs[15],
                dut.u_backend.u_gpr.regs[16],
                dut.u_backend.u_gpr.regs[17],
                dut.u_backend.u_gpr.regs[8],
                dut.u_backend.u_gpr.regs[9]);
        if ($test$plusargs("report_store_extension_sv39")) begin
            if ((dut.u_backend.u_gpr.regs[10] == 0) ||
                (dtlb_fast_stores == 0))
                $fatal(1,
                    "Sv39 store-extension result incomplete cycles=%0d fast_stores=%0d",
                    dut.u_backend.u_gpr.regs[10], dtlb_fast_stores);
            if ((L1D_SYNC_TAG_LOOKUP != 0) &&
                (L1D_SYNC_STORE_EXTENSION != 0) &&
                (l1d_store_extensions != 3584))
                $fatal(1,
                    "Sv39 store-extension hits=%0d expected=3584",
                    l1d_store_extensions);
            if (((L1D_SYNC_TAG_LOOKUP == 0) ||
                 (L1D_SYNC_STORE_EXTENSION == 0)) &&
                (l1d_store_extensions != 0))
                $fatal(1,
                    "disabled Sv39 store extension fired hits=%0d",
                    l1d_store_extensions);
            $display(
                "PERF_L1D_STORE_EXTENSION_SV39 sync_tags=%0d extension=%0d iterations=4096 cycles=%0d extension_hits=%0d dtlb_fast_stores=%0d",
                L1D_SYNC_TAG_LOOKUP, L1D_SYNC_STORE_EXTENSION,
                dut.u_backend.u_gpr.regs[10], l1d_store_extensions,
                dtlb_fast_stores);
        end
        if ($test$plusargs("report_coherence_1h")) begin
            if ((dut.u_backend.u_gpr.regs[11] == 0) ||
                (dut.u_backend.u_gpr.regs[13] == 0) ||
                (dut.u_backend.u_gpr.regs[14] != 0))
                $fatal(1,
                    "one-hart coherence result cycles=%0d operations=%0d status=%0d",
                    dut.u_backend.u_gpr.regs[11],
                    dut.u_backend.u_gpr.regs[13],
                    dut.u_backend.u_gpr.regs[14]);
            $display(
                "COHERENCE_1H case=%0d signature=%h operations=%0d cycles=%0d operations_per_kcycle=%0d instret=%0d ipc_x1000=%0d",
                dut.u_backend.u_gpr.regs[15],
                dut.u_backend.u_gpr.regs[10],
                dut.u_backend.u_gpr.regs[13],
                dut.u_backend.u_gpr.regs[11],
                (dut.u_backend.u_gpr.regs[13] * 1000) /
                    dut.u_backend.u_gpr.regs[11],
                dut.u_backend.u_gpr.regs[12],
                (dut.u_backend.u_gpr.regs[12] * 1000) /
                    dut.u_backend.u_gpr.regs[11]);
        end
        $display(
            "PERF_ICX_L2_TRAFFIC icx_requests=%0d fetch_reads=%0d data_reads=%0d data_writes=%0d ptw_reads=%0d l2_axi_reads=%0d l2_axi_read_beats=%0d l2_axi_writes=%0d l2_axi_write_beats=%0d",
            icx_requests, icx_fetch_reads, icx_data_reads,
            icx_data_writes, icx_ptw_reads, axi_read_transactions,
            axi_read_beats, axi_write_transactions,
            axi_write_beats);
        $display(
            "PERF_ICX_L2_L1I_PREFETCH next_line_hints=%0d next_line_enqueues=%0d probes=%0d miss_completions=%0d",
            l1i_next_line_hints, l1i_next_line_enqueues,
            l1i_prefetch_probes, l1i_prefetch_miss_completions);
        $display(
            "PERF_ICX_L2_VM required=%0b satp_sv39=%0b supervisor=%0b alias_fetch=%0b alias_data=%0b ptw_reads=%0d dtlb_fast_loads=%0d dtlb_fast_stores=%0d dtlb_access_overlap_loads=%0d dtlb_serial_loads=%0d dtlb_serial_stores=%0d cacheable_pa_base=%016h cacheable_pa_size=%016h",
            require_sv39, saw_sv39, saw_supervisor,
            saw_sv39_alias_fetch, saw_sv39_alias_data, icx_ptw_reads,
            dtlb_fast_loads, dtlb_fast_stores,
            dtlb_access_overlap_loads,
            dtlb_serial_loads, dtlb_serial_stores,
            `OPENRV64_SOC_MEMORY_BASE,
            `OPENRV64_SOC_DRAM_PMA_SIZE);
        $display(
            "PERF_ZERO_SV39 required=%0b xlates=%0d accesses=%0d mapping_errors=%0d",
            require_zero_scatter, zero_scatter_xlates,
            zero_scatter_accesses, zero_scatter_mapping_errors);
        $display(
            "PERF_ICX_MAGIC source_mask=%x l1i_line_reads=%0d l1d_line_reads=%0d",
            magic_icx_source_mask_q, magic_icx_l1i_reads,
            magic_icx_l1d_reads);
        if (DDR3_ENABLE != 0)
            $display(
                "PERF_MEMORY timing_model=%0d commands=%0d max_command_queue=%0d max_timing_owners=%0d max_l2_mshrs=%0d read_queue_depth=%0d write_queue_depth=%0d command_queue_depth=%0d max_burst_train_bursts=%0d bank_row_swizzle=%0d",
                MEMORY_TIMING_MODEL,
                ddr3_commands, max_ddr3_queued, max_timing_owners,
                max_l2_mshrs, DDR3_READ_QUEUE_DEPTH,
                DDR3_WRITE_QUEUE_DEPTH, DDR3_COMMAND_QUEUE_DEPTH,
                DDR3_MAX_BURST_TRAIN_BURSTS,
                DDR3_BANK_ROW_SWIZZLE);
        if (DDR3_ENABLE != 0) begin
            $display(
                "PERF_MEMORY_CHANNEL read_bursts=%0d write_bursts=%0d read_beats_requested=%0d read_beats_returned=%0d write_beats_requested=%0d write_beats_received=%0d timing_read_commands=%0d timing_write_commands=%0d",
                memory_read_bursts, memory_write_bursts,
                memory_read_beats_requested, memory_read_beats_returned,
                memory_write_beats_requested, memory_write_beats_received,
                memory_timing_read_commands,
                memory_timing_write_commands);
            $display(
                "PERF_MEMORY_AXI_BURSTS read_1beat=%0d read_2beat=%0d read_other=%0d write_1beat=%0d write_2beat=%0d write_other=%0d",
                memory_read_single_beat_bursts,
                memory_read_two_beat_bursts,
                memory_read_other_bursts,
                memory_write_single_beat_bursts,
                memory_write_two_beat_bursts,
                memory_write_other_bursts);
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
            $display(
                "PERF_MEMORY_DDR_UTIL active_cycles=%0d total_cycles=%0d bus_busy=%0d bus_read=%0d bus_write=%0d bus_launches=%0d read_launches=%0d write_launches=%0d bank_wait=%0d queue_wait=%0d bank_entry_cycles=%0d max_busy_banks=%0d",
                memory_ddr_active_cycles, cycles,
                memory_ddr_bus_busy_cycles,
                memory_ddr_bus_read_cycles,
                memory_ddr_bus_write_cycles,
                memory_ddr_bus_launches,
                memory_ddr_bus_read_launches,
                memory_ddr_bus_write_launches,
                memory_ddr_bus_bank_wait_cycles,
                memory_ddr_bus_queue_wait_cycles,
                memory_ddr_bank_busy_entry_cycles,
                memory_ddr_max_busy_banks);
            $display(
                "PERF_MEMORY_DDR_QUEUE entry_cycles=%0d full_cycles=%0d input_wait=%0d refresh_wait=%0d",
                memory_ddr_command_queue_entry_cycles,
                memory_ddr_command_queue_full_cycles,
                memory_ddr_command_input_wait_cycles,
                memory_ddr_command_refresh_wait_cycles);
            $display(
                "PERF_MEMORY_DDR_ROWS hits=%0d misses=%0d conflicts=%0d empty=%0d direction_switches=%0d",
                memory_ddr_row_hit_commands,
                memory_ddr_row_miss_commands,
                memory_ddr_row_conflict_commands,
                memory_ddr_row_empty_commands,
                memory_ddr_direction_switches);
            $display(
                "PERF_MEMORY_DDR_BURSTS native=%0d full_commands=%0d partial_commands=%0d multi_commands=%0d",
                memory_ddr_native_bursts,
                memory_ddr_full_native_commands,
                memory_ddr_partial_native_commands,
                memory_ddr_multi_native_commands);
            $display(
                "PERF_MEMORY_DDR_TRAINS total=%0d burst1=%0d burst2=%0d burst3=%0d burst4=%0d burst5=%0d burst6=%0d burst7=%0d burst8=%0d burst_long=%0d",
                memory_ddr_burst_trains,
                memory_ddr_single_burst_trains,
                memory_ddr_two_burst_trains,
                memory_ddr_three_burst_trains,
                memory_ddr_four_burst_trains,
                memory_ddr_five_burst_trains,
                memory_ddr_six_burst_trains,
                memory_ddr_seven_burst_trains,
                memory_ddr_eight_burst_trains,
                memory_ddr_long_burst_trains);
            $display(
                "PERF_MEMORY_DDR_REFRESH cycles=%0d events=%0d deferred_cycles=%0d",
                memory_ddr_refresh_cycles,
                memory_ddr_refresh_events,
                memory_ddr_refresh_deferred_cycles);
        end
        $display(
            "PERF_ICX_L2_FRONTEND direction_corrections=%0d target_corrections=%0d lookaside_restart_hits=%0d",
            direction_corrections, target_corrections,
            lookaside_restart_hits);
        $display(
            "PERF_ICX_L2_BP_TARGET btb_lookups=%0d btb_hits=%0d btb_misses=%0d btb_wrong_targets=%0d ras_lookups=%0d ras_hits=%0d ras_misses=%0d ras_wrong_targets=%0d",
            bp_btb_lookups, bp_btb_hits, bp_btb_misses,
            bp_btb_wrong_targets, bp_ras_lookups, bp_ras_hits,
            bp_ras_misses, bp_ras_wrong_targets);
        $display(
            "PERF_ICX_L2_LOOKASIDE pair_stack_depth=%0d eligible_restarts=%0d hits=%0d pair_overlaps=%0d pair_stack_overflows=%0d pair_stack_max_saved=%0d fills=%0d duplicate_fills=%0d free_fills=%0d evictions=%0d full_branch_allocations=%0d",
            FETCH_ALT_PAIR_STACK_DEPTH,
            lookaside_eligible_restarts, lookaside_restart_hits,
            lookaside_pair_replacements, lookaside_pair_stack_overflows,
            lookaside_pair_stack_max_saved, lookaside_store_fills,
            lookaside_store_duplicate_fills, lookaside_store_free_fills,
            lookaside_store_evictions, lookaside_full_branch_allocations);
        $display(
            "PERF_ICX_L2_SECTOR allocations=%0d predicted_free=%0d unpredicted_free=%0d response_taps=%0d predicted_taps=%0d unpredicted_taps=%0d background_requests=%0d background_deferred_cycles=%0d",
            lookaside_sector_allocations,
            lookaside_sector_predicted_free,
            lookaside_sector_unpredicted_free,
            lookaside_sector_response_taps,
            lookaside_sector_predicted_taps,
            lookaside_sector_unpredicted_taps,
            lookaside_sector_background_requests,
            lookaside_sector_background_deferred);
        $display(
            "PERF_ICX_L2_STASH_STALL episodes=%0d completed=%0d interrupted=%0d active=%0d requested=%0d stalled=%0d completed_stalled=%0d interrupted_stalled=%0d exposed_cycles=%0d completed_stall_cycles=%0d interrupted_stall_cycles=%0d same_line_cycles=%0d next_line_cycles=%0d preview_instr=%0d request_delay_sum=%0d request_delay_max=%0d response_delay_sum=%0d response_delay_max=%0d refill_latency_sum=%0d refill_latency_max=%0d",
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
            "PERF_ICX_L2_STASH_OFFSET hits=%0d,%0d,%0d,%0d stalled=%0d,%0d,%0d,%0d stall_cycles=%0d,%0d,%0d,%0d",
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
            "PERF_ICX_L2_STASH_SECTOR hits=%0d,%0d stalled=%0d,%0d stall_cycles=%0d,%0d",
            stash_trace_sector_hits[0], stash_trace_sector_hits[1],
            stash_trace_sector_stalled[0],
            stash_trace_sector_stalled[1],
            stash_trace_sector_stall_cycles[0],
            stash_trace_sector_stall_cycles[1]);
        $display(
            "PERF_ICX_L2_PREFETCH enabled=%0d streams=%0d initial_depth=%0d adaptive=%0d max_depth_cfg=%0d max_depth_seen=%0d outstanding=%0d reserve=%0d issued=%0d useful=%0d useful_pct=%0.2f on_time_useful=%0d on_time_pct=%0.2f late_useful=%0d late_useful_pct=%0.2f late=%0d late_queued=%0d late_command=%0d late_mshr=%0d dropped=%0d useless=%0d",
            L1D_PREFETCH_ENABLE, L1D_PREFETCH_STREAMS,
            L1D_PREFETCH_DISTANCE, L1D_PREFETCH_ADAPTIVE_ENABLE,
            L1D_PREFETCH_MAX_DISTANCE, l1d_prefetch_max_depth,
            L1D_PREFETCH_OUTSTANDING, L1D_PREFETCH_DEMAND_RESERVE,
            l1d_prefetch_issued,
            l1d_prefetch_useful,
            (l1d_prefetch_issued == 0) ? 0.0 :
                (100.0 * l1d_prefetch_useful / l1d_prefetch_issued),
            l1d_prefetch_on_time_useful,
            (l1d_prefetch_issued == 0) ? 0.0 :
                (100.0 * l1d_prefetch_on_time_useful /
                 l1d_prefetch_issued),
            l1d_prefetch_late_useful,
            (l1d_prefetch_issued == 0) ? 0.0 :
                (100.0 * l1d_prefetch_late_useful /
                 l1d_prefetch_issued),
            l1d_prefetch_late,
            l1d_prefetch_late_queued,
            l1d_prefetch_late_command,
            l1d_prefetch_late_mshr,
            l1d_prefetch_dropped, l1d_prefetch_useless);
        $display(
            "PERF_ICX_L2_STORE_POISON any_events=%0d prefetch_events=%0d prefetch_queue=%0d prefetch_command=%0d prefetch_mshr=%0d prefetch_fill=%0d demand_events=%0d demand_wait_prefetch=%0d demand_fill=%0d demand_mshr_overlays=%0d",
            l1d_store_poison_any_events,
            l1d_store_poison_prefetch_events,
            l1d_store_poison_prefetch_queue,
            l1d_store_poison_prefetch_command,
            l1d_store_poison_prefetch_mshr,
            l1d_store_poison_prefetch_fill,
            l1d_store_poison_demand_events,
            l1d_store_poison_demand_wait_prefetch,
            l1d_store_poison_demand_fill,
            l1d_store_overlay_demand_mshr);
        $display(
            "PERF_ICX_L2_WIDTH issued=%0d decoded=%0d issue_w0=%0d issue_w1=%0d issue_w2=%0d issue_w3=%0d issue_w4=%0d decode_w0=%0d decode_w1=%0d decode_w2=%0d decode_w3=%0d retire_w0=%0d retire_w1=%0d retire_w2=%0d retire_w3=%0d",
            issued, decoded,
            issue_width_0, issue_width_1, issue_width_2, issue_width_3,
            issue_width_4,
            decode_width_0, decode_width_1, decode_width_2, decode_width_3,
            retire_width_0, retire_width_1, retire_width_2, retire_width_3);
        $display(
            "PERF_ICX_L2_BACKEND dispatch_nonempty=%0d dispatch_nonempty_no_issue=%0d dispatch_full=%0d raw_hazard=%0d waw_hazard=%0d read_port_hazard=%0d write_busy=%0d barrier=%0d",
            dispatch_nonempty, dispatch_nonempty_no_issue, dispatch_full,
            raw_hazard_cycles, waw_hazard_cycles, read_port_hazard_cycles,
            write_busy_cycles, barrier_cycles);
        $display(
            "PERF_ICX_L2_RAW first_block=%0d pending=%0d bundle=%0d completed=%0d secondary_only=%0d rs1=%0d rs2=%0d both=%0d lane0=%0d lane1=%0d lane2=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            raw_first_block_cycles, raw_first_pending_cycles,
            raw_first_bundle_cycles, raw_first_completed_cycles,
            raw_secondary_only_cycles, raw_first_rs1_cycles,
            raw_first_rs2_cycles, raw_first_both_sources_cycles,
            raw_first_lane0_cycles, raw_first_lane1_cycles,
            raw_first_lane2_cycles, raw_first_blocked_alu,
            raw_first_blocked_branch, raw_first_blocked_jump,
            raw_first_blocked_load, raw_first_blocked_store);
        $display(
            "PERF_ICX_L2_WINDOW enabled=%0d speculation=%0d nonempty_cycles=%0d no_eligible_cycles=%0d raw_stall_cycles=%0d hard_stall_cycles=%0d mem_order_stall_cycles=%0d unissued_entry_cycles=%0d operand_ready_entry_cycles=%0d eligible_entry_cycles=%0d raw_block_entry_cycles=%0d hard_block_entry_cycles=%0d mem_order_block_entry_cycles=%0d",
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
            "PERF_ICX_L2_BRANCH_GATED_LOAD candidate_cycles=%0d gated_cycles=%0d candidate_entry_cycles=%0d gated_entry_cycles=%0d",
            completed_control_load_candidate_cycles,
            completed_control_load_gate_cycles,
            completed_control_load_candidate_entry_cycles,
            completed_control_load_gate_entry_cycles);
        $display(
            "PERF_ICX_L2_RETIRE nonempty=%0d nonempty_no_retire=%0d head_incomplete=%0d completed_behind_head=%0d",
            retire_nonempty, retire_nonempty_no_retire,
            retire_head_incomplete, retire_completed_behind_head);
        $display(
            "PERF_ICX_L2_RETIRE_HEAD alu=%0d branch=%0d jump=%0d load=%0d store=%0d mem_lsq_absent=%0d mem_wait_xlate=%0d mem_wait_access=%0d mem_access_inflight=%0d",
            retire_head_wait_alu, retire_head_wait_branch,
            retire_head_wait_jump, retire_head_wait_load,
            retire_head_wait_store, retire_head_mem_lsq_absent,
            retire_head_mem_wait_xlate, retire_head_mem_wait_access,
            retire_head_mem_access_inflight);
        $display(
            "PERF_ICX_L2_RETIRE_HEAD_ABSENT unissued=%0d issued=%0d result=%0d complete=%0d",
            retire_head_mem_absent_unissued,
            retire_head_mem_absent_issued,
            retire_head_mem_absent_result,
            retire_head_mem_absent_complete);
        $display(
            "PERF_ICX_L2_FETCH empty=%0d held=%0d request_wait=%0d control_empty=%0d refill_wait=%0d no_line=%0d bp_stall=%0d other_empty=%0d",
            frontend_empty, frontend_held, frontend_request_wait,
            frontend_control_empty, frontend_refill_wait, frontend_no_line,
            frontend_bp_stall, frontend_other_empty);
        $display(
            "PERF_ICX_L2_FETCH_CAUSAL empty_backend_ready=%0d empty_dispatch_empty=%0d empty_dispatch_empty_backend_ready=%0d empty_dispatch_empty_retire_empty=%0d empty_dispatch_nonempty=%0d empty_dispatch_full=%0d empty_l1i_external_miss=%0d empty_pending_no_external_miss=%0d",
            frontend_empty_backend_ready, frontend_empty_dispatch_empty,
            frontend_empty_dispatch_empty_backend_ready,
            frontend_empty_dispatch_empty_retire_empty,
            frontend_empty_dispatch_nonempty, frontend_empty_dispatch_full,
            frontend_empty_l1i_external_miss,
            frontend_empty_pending_no_external_miss);
        $display(
            "PERF_ICX_L2_FETCH_PAGE_SCREEN entries=4 requests=%0d hits=%0d hit_pct_x100=%0d redirect_hits=%0d predicted_hits=%0d correction_hits=%0d fills=%0d launches=%0d response_bypasses=%0d invalidates=%0d",
            fetch_page_screen_requests,
            fetch_page_screen_hits,
            (fetch_page_screen_requests != 0) ?
                ((fetch_page_screen_hits * 10000) /
                 fetch_page_screen_requests) : 0,
            fetch_page_screen_redirect_hits,
            fetch_page_screen_predicted_hits,
            fetch_page_screen_correction_hits,
            fetch_page_screen_fills,
            fetch_page_screen_launches,
            fetch_page_screen_bypasses,
            fetch_page_screen_invalidates);
        $display(
            "PERF_ICX_L2_LSU_PAGE_SCREEN enabled=%0d entries=4 requests=%0d store_requests=%0d hits=%0d store_hits=%0d hit_pct_x100=%0d fills=%0d invalidates=%0d",
            ENABLE_LSU_PAGE_SCREEN,
            lsu_page_screen_requests,
            lsu_page_screen_store_requests,
            lsu_page_screen_hits,
            lsu_page_screen_store_hits,
            (lsu_page_screen_requests != 0) ?
                ((lsu_page_screen_hits * 10000) /
                 lsu_page_screen_requests) : 0,
            lsu_page_screen_fills,
            lsu_page_screen_invalidates);
        $display(
            "PERF_ICX_L2_REDIRECT total=%0d predicted=%0d correction=%0d target_correction=%0d control_restart=%0d exception=%0d other=%0d lookaside_hits=%0d predicted_lookaside_hits=%0d correction_lookaside_hits=%0d completed=%0d superseded=%0d active=%0d",
            fetch_redirect_events, fetch_predicted_redirect_events,
            fetch_correction_redirect_events,
            fetch_target_correction_events,
            fetch_control_restart_events,
            fetch_exception_redirect_events, fetch_other_redirect_events,
            fetch_redirect_lookaside_hits,
            fetch_predicted_redirect_lookaside_hits,
            fetch_correction_redirect_lookaside_hits,
            post_redirect_completed_events,
            post_redirect_superseded_events, post_redirect_active);
        $display(
            "PERF_ICX_L2_POST_REDIRECT empty_cycles=%0d empty_cycles_x1000_per_redirect=%0d stalled_events=%0d zero_stall_events=%0d max_empty_cycles=%0d critical_empty_cycles=%0d predicted_empty_cycles=%0d correction_empty_cycles=%0d restart_empty_cycles=%0d other_empty_cycles=%0d",
            post_redirect_empty_cycles,
            (fetch_redirect_events != 0) ?
                ((post_redirect_empty_cycles * 1000) /
                 fetch_redirect_events) : 0,
            post_redirect_stalled_events,
            post_redirect_zero_stall_events,
            post_redirect_max_empty_cycles,
            post_redirect_critical_empty_cycles,
            post_redirect_predicted_empty_cycles,
            post_redirect_correction_empty_cycles,
            post_redirect_restart_empty_cycles,
            post_redirect_other_empty_cycles);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_ACCOUNT completed_empty_cycles=%0d superseded_empty_cycles=%0d completed_x1000_per_event=%0d stalled_x1000_per_event=%0d superseded_x1000_per_event=%0d",
            post_redirect_completed_empty_cycles,
            post_redirect_superseded_empty_cycles,
            (post_redirect_completed_events != 0) ?
                ((post_redirect_completed_empty_cycles * 1000) /
                 post_redirect_completed_events) : 0,
            (post_redirect_stalled_events != 0) ?
                ((post_redirect_completed_empty_cycles * 1000) /
                 post_redirect_stalled_events) : 0,
            (post_redirect_superseded_events != 0) ?
                ((post_redirect_superseded_empty_cycles * 1000) /
                 post_redirect_superseded_events) : 0);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_HIST zero=%0d one=%0d two=%0d three=%0d four=%0d five=%0d six=%0d seven=%0d eight_to_fifteen=%0d sixteen_to_thirtyone=%0d thirtytwo_to_sixtythree=%0d sixtyfour_to_127=%0d one28_to_255=%0d two56_plus=%0d",
            post_redirect_hist[0], post_redirect_hist[1],
            post_redirect_hist[2], post_redirect_hist[3],
            post_redirect_hist[4], post_redirect_hist[5],
            post_redirect_hist[6], post_redirect_hist[7],
            post_redirect_hist[8], post_redirect_hist[9],
            post_redirect_hist[10], post_redirect_hist[11],
            post_redirect_hist[12], post_redirect_hist[13]);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_PREDICTED_HIST zero=%0d one=%0d two=%0d three=%0d four=%0d five=%0d six=%0d seven=%0d eight_to_fifteen=%0d sixteen_to_thirtyone=%0d thirtytwo_to_sixtythree=%0d sixtyfour_to_127=%0d one28_to_255=%0d two56_plus=%0d",
            post_redirect_predicted_hist[0],
            post_redirect_predicted_hist[1],
            post_redirect_predicted_hist[2],
            post_redirect_predicted_hist[3],
            post_redirect_predicted_hist[4],
            post_redirect_predicted_hist[5],
            post_redirect_predicted_hist[6],
            post_redirect_predicted_hist[7],
            post_redirect_predicted_hist[8],
            post_redirect_predicted_hist[9],
            post_redirect_predicted_hist[10],
            post_redirect_predicted_hist[11],
            post_redirect_predicted_hist[12],
            post_redirect_predicted_hist[13]);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_CORRECTION_HIST zero=%0d one=%0d two=%0d three=%0d four=%0d five=%0d six=%0d seven=%0d eight_to_fifteen=%0d sixteen_to_thirtyone=%0d thirtytwo_to_sixtythree=%0d sixtyfour_to_127=%0d one28_to_255=%0d two56_plus=%0d",
            post_redirect_correction_hist[0],
            post_redirect_correction_hist[1],
            post_redirect_correction_hist[2],
            post_redirect_correction_hist[3],
            post_redirect_correction_hist[4],
            post_redirect_correction_hist[5],
            post_redirect_correction_hist[6],
            post_redirect_correction_hist[7],
            post_redirect_correction_hist[8],
            post_redirect_correction_hist[9],
            post_redirect_correction_hist[10],
            post_redirect_correction_hist[11],
            post_redirect_correction_hist[12],
            post_redirect_correction_hist[13]);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_CAUSE current_pending=%0d other_pending=%0d no_pending=%0d external_miss=%0d request_wait=%0d",
            post_redirect_current_pending_cycles,
            post_redirect_other_pending_cycles,
            post_redirect_no_pending_cycles,
            post_redirect_external_miss_cycles,
            post_redirect_request_wait_cycles);
        $display(
            "PERF_ICX_L2_POST_REDIRECT_LOOKASIDE hit_empty_cycles=%0d miss_empty_cycles=%0d hit_stalled_events=%0d hit_zero_stall_events=%0d miss_stalled_events=%0d miss_zero_stall_events=%0d",
            post_redirect_lookaside_hit_empty_cycles,
            post_redirect_lookaside_miss_empty_cycles,
            post_redirect_lookaside_hit_stalled_events,
            post_redirect_lookaside_hit_zero_stall_events,
            post_redirect_lookaside_miss_stalled_events,
            post_redirect_lookaside_miss_zero_stall_events);
        $display(
            "PERF_ICX_L2_CORRECTION_FAL no_context=%0d context_pending=%0d context_not_pending=%0d lookaside_hit_empty_cycles=%0d no_context_empty_cycles=%0d context_pending_empty_cycles=%0d context_not_pending_empty_cycles=%0d",
            fetch_correction_lookaside_no_context,
            fetch_correction_lookaside_context_pending,
            fetch_correction_lookaside_context_not_pending,
            post_redirect_correction_lookaside_hit_empty_cycles,
            post_redirect_correction_no_context_empty_cycles,
            post_redirect_correction_context_pending_empty_cycles,
            post_redirect_correction_context_not_pending_empty_cycles);
        if (redirect_cycle_trace_enabled != 0)
            $display(
                "TRACE_REDIRECT_SUMMARY skipped=%0d redirects_seen=%0d stalled_captured=%0d limit=%0d superseded_candidates=%0d active=%0d",
                redirect_cycle_trace_skip,
                redirect_cycle_trace_seen,
                redirect_cycle_trace_captured,
                redirect_cycle_trace_limit,
                redirect_cycle_trace_superseded,
                redirect_cycle_trace_active);
        if ((post_redirect_current_pending_cycles +
             post_redirect_other_pending_cycles +
             post_redirect_no_pending_cycles) !=
            post_redirect_empty_cycles)
            $fatal(1, "post-redirect empty classification mismatch");
        if ((post_redirect_predicted_empty_cycles +
             post_redirect_correction_empty_cycles +
             post_redirect_restart_empty_cycles +
             post_redirect_other_empty_cycles) !=
            post_redirect_empty_cycles)
            $fatal(1, "post-redirect kind classification mismatch");
        if ((post_redirect_lookaside_hit_empty_cycles +
             post_redirect_lookaside_miss_empty_cycles) !=
            post_redirect_empty_cycles)
            $fatal(1, "post-redirect lookaside classification mismatch");
        if ((post_redirect_correction_lookaside_hit_empty_cycles +
             post_redirect_correction_no_context_empty_cycles +
             post_redirect_correction_context_pending_empty_cycles +
             post_redirect_correction_context_not_pending_empty_cycles) !=
            post_redirect_correction_empty_cycles)
            $fatal(1, "post-redirect correction FAL classification mismatch");
        $display(
            "PERF_ICX_L2_LSU request_wait=%0d load_wait=%0d store_wait=%0d outstanding=%0d branch_resolutions=%0d conditional_branch_resolutions=%0d",
            lsu_request_wait, lsu_load_request_wait,
            lsu_store_request_wait, lsu_outstanding_cycles,
            branch_resolutions, conditional_branch_resolutions);
        $display(
            "PERF_ICX_L2_SPEC_LOAD alloc=%0d spec_alloc=%0d ordered_alloc=%0d xlate=%0d spec_xlate=%0d access=%0d spec_access=%0d ordered_access=%0d responses=%0d completions=%0d forwarded=%0d faults=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_spec_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_ordered_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_xlate_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_spec_xlate_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_access_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_spec_access_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_ordered_access_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_responses_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_completions_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_forwarded_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_faults_q);
        $display(
            "PERF_ICX_L2_SPEC_LOAD_WAIT alloc_wait=%0d queue_full=%0d xlate_wait=%0d access_wait=%0d dependency_cycles=%0d dependency_entry_cycles=%0d forward_cycles=%0d forward_entry_cycles=%0d occupancy_entry_cycles=%0d spec_occupancy_entry_cycles=%0d max_occupancy=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_alloc_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_queue_full_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_xlate_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_access_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_dependency_block_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_dependency_block_entry_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_forward_ready_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_forward_ready_entry_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_occupancy_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_spec_occupancy_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_max_occupancy_q);
        $display(
            "PERF_ICX_L2_SPEC_LOAD_SQUASH branch_total=%0d before_xlate=%0d xlate_inflight=%0d xlate_done=%0d access_inflight=%0d killed_responses=%0d flushed=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_before_xlate_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_xlate_inflight_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_xlate_done_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_access_inflight_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_killed_responses_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_flushed_q);
        $display(
            "PERF_ICX_L2_SPEC_LOAD_OUTCOME retired=%0d spec_retired=%0d ordered_retired=%0d cache_reissues=%0d branch_aborted=%0d flush_aborted=%0d",
            dut.u_backend.perf_lsq_load_retired_q,
            dut.u_backend.perf_lsq_load_spec_retired_q,
            dut.u_backend.perf_lsq_load_ordered_retired_q,
            dut.u_bus.g_icx.u_bus.u_l1d.perf_demand_reissues_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_squashed_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_load_flushed_q);
        $display(
            "PERF_ICX_L2_SPEC_STORE alloc=%0d spec_alloc=%0d ordered_alloc=%0d atomic_alloc=%0d xlate=%0d spec_xlate=%0d ordered_access=%0d posted_results=%0d done=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_spec_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_ordered_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_atomic_allocations_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_xlate_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_spec_xlate_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_access_requests_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_posted_results_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_done_q);
        $display(
            "PERF_ICX_L2_SPEC_STORE_WAIT alloc_wait=%0d queue_full=%0d xlate_wait=%0d access_wait=%0d order_wait_cycles=%0d order_wait_entry_cycles=%0d occupancy_entry_cycles=%0d spec_occupancy_entry_cycles=%0d max_occupancy=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_alloc_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_queue_full_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_xlate_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_access_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_order_wait_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_order_wait_entry_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_occupancy_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_spec_occupancy_cycles_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_max_occupancy_q);
        $display(
            "PERF_ICX_L2_SPEC_STORE_SQUASH branch_total=%0d before_xlate=%0d xlate_inflight=%0d xlate_done=%0d access_inflight=%0d killed_responses=%0d flushed=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_before_xlate_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_xlate_inflight_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_xlate_done_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_access_inflight_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_killed_responses_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_flushed_q);
        $display(
            "PERF_ICX_L2_SPEC_STORE_OUTCOME retired=%0d spec_retired=%0d ordered_retired=%0d cache_reissues=0 branch_aborted=%0d flush_aborted=%0d untracked_retired=%0d",
            dut.u_backend.perf_lsq_store_retired_q,
            dut.u_backend.perf_lsq_store_spec_retired_q,
            dut.u_backend.perf_lsq_store_ordered_retired_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_squashed_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_store_flushed_q,
            dut.u_backend.perf_lsq_retired_untracked_q);
        $display(
            "PERF_ICX_L2_ATOMIC starts=%0d done=%0d active_cycles=%0d store_success=%0d store_failed=%0d home_sc_success=%0d home_sc_failed=%0d",
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_atomic_starts_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_atomic_done_q,
            dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                .perf_atomic_active_cycles_q,
            dut.u_debug.perf_atomic_store_success_q,
            dut.u_debug.perf_atomic_store_failed_q,
            u_complex.u_l2.u_debug.perf_atomic_store_success_q,
            u_complex.u_l2.u_debug.perf_atomic_store_failed_q);
        $display(
            "PERF_ICX_L2_PREFETCH_PAGE_END boundaries_seen=%0d",
            dut.u_bus.g_icx.u_bus.u_l1d.perf_prefetch_page_ends_q);
        $display(
            "PERF_ICX_L2_MEM_PORTS second_port_opportunities=%0d",
            lsu_second_port_opportunities);
        $display(
            "PERF_ICX_L2_BACKPRESSURE l1d_wait=%0d l1d_load_wait=%0d l1d_store_wait=%0d icx_wait=%0d icx_read_wait=%0d icx_write_wait=%0d l2_bus_wait=%0d l2_command_full=%0d axi_ar_wait=%0d axi_aw_wait=%0d axi_w_wait=%0d",
            l1d_request_wait, l1d_load_request_wait,
            l1d_store_request_wait, icx_request_wait,
            icx_read_request_wait, icx_write_request_wait,
            l2_bus_request_wait, l2_command_full_cycles,
            axi_read_address_wait, axi_write_address_wait,
            axi_write_data_wait);
        $display(
            "PERF_ICX_L2_L1D_WAIT store_block=%0d dirty_snoops=%0d lock_barrier=%0d response_tags=%0d refill=%0d access=%0d run_response=%0d unknown=%0d",
            l1d_wait_store_block, l1d_dirty_snoop_accepts,
            l1d_wait_lock_barrier,
            l1d_wait_response_tags, l1d_wait_refill,
            l1d_wait_access, l1d_wait_run_response,
            l1d_wait_unknown);
        $display(
            "PERF_ICX_L2_CONFLICT total=%0d ex0=%0d ex1=%0d mem=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            pipe_conflicts, pipe_conflicts_ex0, pipe_conflicts_ex1,
            pipe_conflicts_mem, conflict_blocked_alu,
            conflict_blocked_branch, conflict_blocked_jump,
            conflict_blocked_load, conflict_blocked_store);
        $display(
            "PERF_ICX_L2_CONFLICT_PAIR branch_alu=%0d alu_branch=%0d branch_branch=%0d alu_alu=%0d load_load=%0d store_load=%0d store_store=%0d other=%0d",
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
        if (fence_check_enabled_q &&
            (fence_order_violation_q != 11'd0))
            $fatal(1,
                "external-boundary fence ordering violations mask=%03h",
                fence_order_violation_q);
        if (DDR3_ENABLE != 0)
            if (MEMORY_TIMING_MODEL == 1)
                $display(
                    "PASS: 3P L1I/L1D -> ICX -> L2 -> AXI -> magic memory");
            else
                $display(
                    "PASS: 3P L1I/L1D -> ICX -> L2 -> AXI -> banked DDR3");
        else
            $display(
                "PASS: 3P L1I/L1D -> ICX -> L2 -> 16 MiB AXI SRAM");
        if (l1d_prefetch_trace_fd != 0)
            $fclose(l1d_prefetch_trace_fd);
        $finish;
    end
endmodule
