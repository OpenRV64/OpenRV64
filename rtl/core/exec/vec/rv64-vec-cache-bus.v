`timescale 1ns/1ps
`include "complex/bus/defs.v"

// Bus-facing wrapper for the shared vector SRAM cache. The upper side is the
// packed multi-VLSU interface.  The cache-side beat width is independent of
// the external transport width; genbus_interface performs the shared width
// conversion and AXI4/WISHBONE selection also used below CCX/L2.
module openrv64_vec_sram_cache_bus #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CLIENT_DATA_WIDTH = 256,
    parameter integer CLIENTS = 2,
    parameter integer CLIENT_TAG_WIDTH = 8,
    parameter integer CACHE_BYTES = 256 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 4,
    parameter integer MSHRS = 8,
    parameter integer CACHE_BUS_DATA_WIDTH = LINE_BYTES * 8,
    parameter integer GENBUS_READ_BUFFER_DEPTH = MSHRS,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 4,
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer BUS_DATA_WIDTH = 256,
    parameter integer AXI_ID_WIDTH = 3,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}},
    parameter integer WB_ADDR_SHIFT = $clog2(BUS_DATA_WIDTH / 8),
    parameter integer WB_MAX_RETRIES = 8
) (
    input  wire                                  clk_i,
    input  wire                                  rst_ni,

    input  wire [CLIENTS-1:0]                    client_req_valid_i,
    output wire [CLIENTS-1:0]                    client_req_ready_o,
    input  wire [CLIENTS*CLIENT_TAG_WIDTH-1:0]   client_req_tag_i,
    input  wire [CLIENTS-1:0]                    client_req_write_i,
    input  wire [CLIENTS*ADDR_WIDTH-1:0]         client_req_addr_i,
    input  wire [CLIENTS*CLIENT_DATA_WIDTH-1:0]  client_req_wdata_i,
    input  wire [CLIENTS*(CLIENT_DATA_WIDTH/8)-1:0]
                                                 client_req_wstrb_i,
    output wire [CLIENTS-1:0]                    client_resp_valid_o,
    input  wire [CLIENTS-1:0]                    client_resp_ready_i,
    output wire [CLIENTS*CLIENT_TAG_WIDTH-1:0]   client_resp_tag_o,
    output wire [CLIENTS*CLIENT_DATA_WIDTH-1:0]  client_resp_rdata_o,
    output wire [CLIENTS-1:0]                    client_resp_error_o,
    output wire [CLIENTS-1:0]                    client_resp_retry_o,

    input  wire                                  prefetch_valid_i,
    output wire                                  prefetch_ready_o,
    input  wire [ADDR_WIDTH-1:0]                 prefetch_addr_i,
    input  wire [3:0]                            prefetch_count_i,
    input  wire                                  prefetch_streaming_i,
    output wire                                  prefetch_busy_o,
    output wire                                  replay_o,
    output wire                                  busy_o,

    output wire [AXI_ID_WIDTH-1:0]               m_axi_arid_o,
    output wire [ADDR_WIDTH-1:0]                 m_axi_araddr_o,
    output wire [7:0]                            m_axi_arlen_o,
    output wire [2:0]                            m_axi_arsize_o,
    output wire [1:0]                            m_axi_arburst_o,
    output wire                                  m_axi_arlock_o,
    output wire [3:0]                            m_axi_arcache_o,
    output wire [2:0]                            m_axi_arprot_o,
    output wire [3:0]                            m_axi_arqos_o,
    output wire                                  m_axi_arvalid_o,
    input  wire                                  m_axi_arready_i,
    input  wire [AXI_ID_WIDTH-1:0]               m_axi_rid_i,
    input  wire [BUS_DATA_WIDTH-1:0]             m_axi_rdata_i,
    input  wire [1:0]                            m_axi_rresp_i,
    input  wire                                  m_axi_rlast_i,
    input  wire                                  m_axi_rvalid_i,
    output wire                                  m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]               m_axi_awid_o,
    output wire [ADDR_WIDTH-1:0]                 m_axi_awaddr_o,
    output wire [7:0]                            m_axi_awlen_o,
    output wire [2:0]                            m_axi_awsize_o,
    output wire [1:0]                            m_axi_awburst_o,
    output wire                                  m_axi_awlock_o,
    output wire [3:0]                            m_axi_awcache_o,
    output wire [2:0]                            m_axi_awprot_o,
    output wire [3:0]                            m_axi_awqos_o,
    output wire                                  m_axi_awvalid_o,
    input  wire                                  m_axi_awready_i,
    output wire [BUS_DATA_WIDTH-1:0]             m_axi_wdata_o,
    output wire [BUS_DATA_WIDTH/8-1:0]           m_axi_wstrb_o,
    output wire                                  m_axi_wlast_o,
    output wire                                  m_axi_wvalid_o,
    input  wire                                  m_axi_wready_i,
    input  wire [AXI_ID_WIDTH-1:0]               m_axi_bid_i,
    input  wire [1:0]                            m_axi_bresp_i,
    input  wire                                  m_axi_bvalid_i,
    output wire                                  m_axi_bready_o,

    output wire                                  wb_cyc_o,
    output wire                                  wb_stb_o,
    output wire                                  wb_we_o,
    output wire [ADDR_WIDTH-1:0]                 wb_adr_o,
    output wire [BUS_DATA_WIDTH-1:0]             wb_dat_o,
    output wire [BUS_DATA_WIDTH/8-1:0]           wb_sel_o,
    output wire [2:0]                            wb_cti_o,
    output wire [1:0]                            wb_bte_o,
    output wire                                  wb_lock_o,
    input  wire                                  wb_stall_i,
    input  wire                                  wb_ack_i,
    input  wire                                  wb_err_i,
    input  wire                                  wb_rty_i,
    input  wire [BUS_DATA_WIDTH-1:0]             wb_dat_i
);

    localparam integer CACHE_MEM_TAG_WIDTH =
        (MSHRS <= 1) ? 1 : $clog2(MSHRS);
    localparam integer CACHE_BUS_BYTES = CACHE_BUS_DATA_WIDTH / 8;
    localparam integer CLIENT_BYTES = CLIENT_DATA_WIDTH / 8;
    localparam integer CACHE_BUS_SIZE = $clog2(CACHE_BUS_BYTES);
    localparam integer STORE_SIZE =
        (CACHE_BUS_BYTES <= CLIENT_BYTES) ? $clog2(CACHE_BUS_BYTES) :
                                            $clog2(CLIENT_BYTES);
    localparam integer TAG_FIFO_DEPTH = GENBUS_READ_BUFFER_DEPTH +
                                        GENBUS_WRITE_BUFFER_DEPTH;
    localparam integer TAG_FIFO_INDEX_WIDTH =
        (TAG_FIFO_DEPTH > 1) ? $clog2(TAG_FIFO_DEPTH) : 1;
    localparam integer TAG_FIFO_COUNT_WIDTH =
        $clog2(TAG_FIFO_DEPTH + 1);

    wire cache_mem_req_valid;
    wire cache_mem_req_ready;
    wire [CACHE_MEM_TAG_WIDTH-1:0] cache_mem_req_tag;
    wire cache_mem_req_write;
    wire [7:0] cache_mem_req_burst;
    wire [ADDR_WIDTH-1:0] cache_mem_req_addr;
    wire [CACHE_BUS_DATA_WIDTH-1:0] cache_mem_req_wdata;
    wire [CACHE_BUS_BYTES-1:0] cache_mem_req_wstrb;
    wire cache_mem_resp_valid;
    wire cache_mem_resp_ready;
    wire [CACHE_MEM_TAG_WIDTH-1:0] cache_mem_resp_tag;
    wire [CACHE_BUS_DATA_WIDTH-1:0] cache_mem_resp_rdata;
    wire cache_mem_resp_error;

    wire bus_req_valid;
    wire bus_req_ready;
    wire [2:0] bus_req_size = cache_mem_req_write ?
        STORE_SIZE[2:0] : CACHE_BUS_SIZE[2:0];
    wire bus_resp_valid;
    wire bus_resp_ready;
    wire [CACHE_BUS_DATA_WIDTH-1:0] bus_resp_rdata;
    wire bus_resp_error;

    reg [CACHE_MEM_TAG_WIDTH-1:0] tag_fifo_q [0:TAG_FIFO_DEPTH-1];
    reg [TAG_FIFO_INDEX_WIDTH-1:0] tag_fifo_head_q;
    reg [TAG_FIFO_INDEX_WIDTH-1:0] tag_fifo_tail_q;
    reg [TAG_FIFO_COUNT_WIDTH-1:0] tag_fifo_count_q;
    integer tag_reset_index;
    wire bridge_request_fire = bus_req_valid && bus_req_ready;
    wire bridge_response_fire = bus_resp_valid && bus_resp_ready;

    assign bus_req_valid = cache_mem_req_valid &&
        (tag_fifo_count_q < TAG_FIFO_COUNT_WIDTH'(TAG_FIFO_DEPTH));
    assign cache_mem_req_ready = bus_req_ready &&
        (tag_fifo_count_q < TAG_FIFO_COUNT_WIDTH'(TAG_FIFO_DEPTH));
    assign cache_mem_resp_valid = bus_resp_valid &&
                                  (tag_fifo_count_q != 0);
    assign cache_mem_resp_tag = tag_fifo_q[tag_fifo_head_q];
    assign cache_mem_resp_rdata = bus_resp_rdata;
    assign cache_mem_resp_error = bus_resp_error;
    assign bus_resp_ready = cache_mem_resp_ready &&
                            (tag_fifo_count_q != 0);

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tag_fifo_head_q <= 0;
            tag_fifo_tail_q <= 0;
            tag_fifo_count_q <= 0;
            for (tag_reset_index = 0; tag_reset_index < TAG_FIFO_DEPTH;
                 tag_reset_index = tag_reset_index + 1)
                tag_fifo_q[tag_reset_index] <= 0;
        end else begin
            if (bridge_request_fire) begin
                tag_fifo_q[tag_fifo_tail_q] <= cache_mem_req_tag;
                if (tag_fifo_tail_q ==
                    TAG_FIFO_INDEX_WIDTH'(TAG_FIFO_DEPTH - 1))
                    tag_fifo_tail_q <= 0;
                else
                    tag_fifo_tail_q <= tag_fifo_tail_q + 1'b1;
            end
            if (bridge_response_fire) begin
                if (tag_fifo_head_q ==
                    TAG_FIFO_INDEX_WIDTH'(TAG_FIFO_DEPTH - 1))
                    tag_fifo_head_q <= 0;
                else
                    tag_fifo_head_q <= tag_fifo_head_q + 1'b1;
            end
            case ({bridge_request_fire, bridge_response_fire})
                2'b10: tag_fifo_count_q <= tag_fifo_count_q + 1'b1;
                2'b01: tag_fifo_count_q <= tag_fifo_count_q - 1'b1;
                default: tag_fifo_count_q <= tag_fifo_count_q;
            endcase
        end
    end

    openrv64_vec_sram_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CLIENT_DATA_WIDTH(CLIENT_DATA_WIDTH),
        .MEM_DATA_WIDTH(CACHE_BUS_DATA_WIDTH),
        .CLIENTS(CLIENTS), .CLIENT_TAG_WIDTH(CLIENT_TAG_WIDTH),
        .MEM_TAG_WIDTH(CACHE_MEM_TAG_WIDTH),
        .CACHE_BYTES(CACHE_BYTES), .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS), .MSHRS(MSHRS),
        .MEM_MAX_BURST_REQUESTS(GENBUS_READ_BUFFER_DEPTH)
    ) u_cache (
        .clk(clk_i), .rst_n(rst_ni),
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_tag_i(client_req_tag_i),
        .client_req_write_i(client_req_write_i),
        .client_req_addr_i(client_req_addr_i),
        .client_req_wdata_i(client_req_wdata_i),
        .client_req_wstrb_i(client_req_wstrb_i),
        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_ready_i(client_resp_ready_i),
        .client_resp_tag_o(client_resp_tag_o),
        .client_resp_rdata_o(client_resp_rdata_o),
        .client_resp_error_o(client_resp_error_o),
        .client_resp_retry_o(client_resp_retry_o),
        .prefetch_valid_i(prefetch_valid_i),
        .prefetch_ready_o(prefetch_ready_o),
        .prefetch_addr_i(prefetch_addr_i),
        .prefetch_count_i(prefetch_count_i),
        .prefetch_streaming_i(prefetch_streaming_i),
        .prefetch_busy_o(prefetch_busy_o),
        .mem_req_valid_o(cache_mem_req_valid),
        .mem_req_ready_i(cache_mem_req_ready),
        .mem_req_tag_o(cache_mem_req_tag),
        .mem_req_write_o(cache_mem_req_write),
        .mem_req_burst_o(cache_mem_req_burst),
        .mem_req_addr_o(cache_mem_req_addr),
        .mem_req_wdata_o(cache_mem_req_wdata),
        .mem_req_wstrb_o(cache_mem_req_wstrb),
        .mem_resp_valid_i(cache_mem_resp_valid),
        .mem_resp_ready_o(cache_mem_resp_ready),
        .mem_resp_tag_i(cache_mem_resp_tag),
        .mem_resp_rdata_i(cache_mem_resp_rdata),
        .mem_resp_error_i(cache_mem_resp_error),
        .mem_resp_retry_i(1'b0),
        .replay_o(replay_o), .busy_o(busy_o)
    );

    genbus_interface #(
        .BUS_TYPE(BUS_TYPE), .ADDR_WIDTH(ADDR_WIDTH),
        .UPSTREAM_DATA_WIDTH(CACHE_BUS_DATA_WIDTH),
        .DOWNSTREAM_DATA_WIDTH(BUS_DATA_WIDTH),
        .READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(AXI_ID), .WB_ADDR_SHIFT(WB_ADDR_SHIFT),
        .WB_MAX_RETRIES(WB_MAX_RETRIES)
    ) u_genbus (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .upstream_req_valid_i(bus_req_valid),
        .upstream_req_ready_o(bus_req_ready),
        .upstream_req_write_i(cache_mem_req_write),
        .upstream_req_addr_i(cache_mem_req_addr),
        .upstream_req_size_i(bus_req_size),
        .upstream_req_burst_i(cache_mem_req_burst),
        .upstream_req_wdata_i(cache_mem_req_wdata),
        .upstream_req_wstrb_i(cache_mem_req_wstrb),
        .upstream_req_cacheable_i(1'b1),
        .upstream_resp_valid_o(bus_resp_valid),
        .upstream_resp_ready_i(bus_resp_ready),
        .upstream_resp_rdata_o(bus_resp_rdata),
        .upstream_resp_error_o(bus_resp_error),
        .m_axi_arid_o(m_axi_arid_o), .m_axi_araddr_o(m_axi_araddr_o),
        .m_axi_arlen_o(m_axi_arlen_o), .m_axi_arsize_o(m_axi_arsize_o),
        .m_axi_arburst_o(m_axi_arburst_o),
        .m_axi_arlock_o(m_axi_arlock_o),
        .m_axi_arcache_o(m_axi_arcache_o),
        .m_axi_arprot_o(m_axi_arprot_o), .m_axi_arqos_o(m_axi_arqos_o),
        .m_axi_arvalid_o(m_axi_arvalid_o),
        .m_axi_arready_i(m_axi_arready_i), .m_axi_rid_i(m_axi_rid_i),
        .m_axi_rdata_i(m_axi_rdata_i), .m_axi_rresp_i(m_axi_rresp_i),
        .m_axi_rlast_i(m_axi_rlast_i), .m_axi_rvalid_i(m_axi_rvalid_i),
        .m_axi_rready_o(m_axi_rready_o), .m_axi_awid_o(m_axi_awid_o),
        .m_axi_awaddr_o(m_axi_awaddr_o), .m_axi_awlen_o(m_axi_awlen_o),
        .m_axi_awsize_o(m_axi_awsize_o),
        .m_axi_awburst_o(m_axi_awburst_o),
        .m_axi_awlock_o(m_axi_awlock_o),
        .m_axi_awcache_o(m_axi_awcache_o),
        .m_axi_awprot_o(m_axi_awprot_o), .m_axi_awqos_o(m_axi_awqos_o),
        .m_axi_awvalid_o(m_axi_awvalid_o),
        .m_axi_awready_i(m_axi_awready_i), .m_axi_wdata_o(m_axi_wdata_o),
        .m_axi_wstrb_o(m_axi_wstrb_o), .m_axi_wlast_o(m_axi_wlast_o),
        .m_axi_wvalid_o(m_axi_wvalid_o), .m_axi_wready_i(m_axi_wready_i),
        .m_axi_bid_i(m_axi_bid_i), .m_axi_bresp_i(m_axi_bresp_i),
        .m_axi_bvalid_i(m_axi_bvalid_i), .m_axi_bready_o(m_axi_bready_o),
        .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_we_o(wb_we_o),
        .wb_adr_o(wb_adr_o), .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel_o),
        .wb_cti_o(wb_cti_o), .wb_bte_o(wb_bte_o),
        .wb_lock_o(wb_lock_o), .wb_stall_i(wb_stall_i),
        .wb_ack_i(wb_ack_i), .wb_err_i(wb_err_i), .wb_rty_i(wb_rty_i),
        .wb_dat_i(wb_dat_i)
    );

`ifndef SYNTHESIS
    initial begin
        if ((CACHE_BUS_DATA_WIDTH < 32) ||
            (CACHE_BUS_DATA_WIDTH > 512) ||
            ((CACHE_BUS_DATA_WIDTH & (CACHE_BUS_DATA_WIDTH - 1)) != 0))
            $fatal(1,
                "vector cache-side bus width must be 32 through 512 bits");
        if ((GENBUS_READ_BUFFER_DEPTH < 1) ||
            (GENBUS_WRITE_BUFFER_DEPTH < 1))
            $fatal(1, "vector genbus buffers must be nonzero");
        if ((BUS_DATA_WIDTH < 32) || (BUS_DATA_WIDTH > 512) ||
            ((BUS_DATA_WIDTH & (BUS_DATA_WIDTH - 1)) != 0))
            $fatal(1, "vector AXI bus width must be 32 through 512 bits");
        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
            (BUS_DATA_WIDTH > 64))
            $fatal(1, "WISHBONE B.4 vector bus is limited to 32 or 64 bits");
    end
`endif

endmodule
