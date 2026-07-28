`timescale 1ns/1ps

// AXI4-attached timed-memory simulation endpoint.
//
// This is the intended placement of the transaction-level DDR timing model:
// downstream of the shared L2 and its generic-bus AXI adapter.  Storage and
// AXI ordering live in openrv64_mem_channel.  TIMING_MODEL selects DDR3
// scheduling (0) or the idealized one-cycle magic backend (1).
module openrv64_axi_ddr3 #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer ID_WIDTH = 3,
    parameter [ADDR_WIDTH-1:0] MEM_BASE = {ADDR_WIDTH{1'b0}},
    parameter integer MEM_BYTES = 16 * 1024 * 1024,
    parameter integer READ_QUEUE_DEPTH = 8,
    parameter integer WRITE_QUEUE_DEPTH = 8,
    parameter integer TIMING_TAG_WIDTH = 8,
    parameter integer ZERO_INIT_WORDS =
        MEM_BYTES / (DATA_WIDTH / 8),
    parameter INIT_FILE = "",
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer REFRESH_INTERVAL = 6240,
    parameter integer FRONTEND_LATENCY_PS = 10000,
    parameter integer BACKEND_LATENCY_PS = 10000,
    parameter integer COMMAND_QUEUE_DEPTH = 16,
    parameter integer MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer TIMING_MODEL = 0
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire [ID_WIDTH-1:0]       s_axi_arid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr_i,
    input  wire [7:0]                s_axi_arlen_i,
    input  wire [2:0]                s_axi_arsize_i,
    input  wire [1:0]                s_axi_arburst_i,
    input  wire                      s_axi_arlock_i,
    input  wire [3:0]                s_axi_arcache_i,
    input  wire [2:0]                s_axi_arprot_i,
    input  wire [3:0]                s_axi_arqos_i,
    input  wire                      s_axi_arvalid_i,
    output wire                      s_axi_arready_o,

    output wire [ID_WIDTH-1:0]       s_axi_rid_o,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata_o,
    output wire [1:0]                s_axi_rresp_o,
    output wire                      s_axi_rlast_o,
    output wire                      s_axi_rvalid_o,
    input  wire                      s_axi_rready_i,

    input  wire [ID_WIDTH-1:0]       s_axi_awid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr_i,
    input  wire [7:0]                s_axi_awlen_i,
    input  wire [2:0]                s_axi_awsize_i,
    input  wire [1:0]                s_axi_awburst_i,
    input  wire                      s_axi_awlock_i,
    input  wire [3:0]                s_axi_awcache_i,
    input  wire [2:0]                s_axi_awprot_i,
    input  wire [3:0]                s_axi_awqos_i,
    input  wire                      s_axi_awvalid_i,
    output wire                      s_axi_awready_o,

    input  wire [DATA_WIDTH-1:0]     s_axi_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb_i,
    input  wire                      s_axi_wlast_i,
    input  wire                      s_axi_wvalid_i,
    output wire                      s_axi_wready_o,

    output wire [ID_WIDTH-1:0]       s_axi_bid_o,
    output wire [1:0]                s_axi_bresp_o,
    output wire                      s_axi_bvalid_o,
    input  wire                      s_axi_bready_i
);

    wire timing_cmd_valid;
    wire timing_cmd_ready;
    wire timing_cmd_write;
    wire [ADDR_WIDTH-1:0] timing_cmd_addr;
    wire [15:0] timing_cmd_bytes;
    wire [TIMING_TAG_WIDTH-1:0] timing_cmd_tag;
    wire timing_resp_valid;
    wire [TIMING_TAG_WIDTH-1:0] timing_resp_tag;
    wire timing_resp_ready;

    openrv64_mem_channel #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES),
        .READ_QUEUE_DEPTH(READ_QUEUE_DEPTH),
        .WRITE_QUEUE_DEPTH(WRITE_QUEUE_DEPTH),
        .TIMING_TAG_WIDTH(TIMING_TAG_WIDTH),
        .ZERO_INIT_WORDS(ZERO_INIT_WORDS),
        .INIT_FILE(INIT_FILE)
    ) u_channel (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .s_axi_arid_i(s_axi_arid_i),
        .s_axi_araddr_i(s_axi_araddr_i),
        .s_axi_arlen_i(s_axi_arlen_i),
        .s_axi_arsize_i(s_axi_arsize_i),
        .s_axi_arburst_i(s_axi_arburst_i),
        .s_axi_arlock_i(s_axi_arlock_i),
        .s_axi_arcache_i(s_axi_arcache_i),
        .s_axi_arprot_i(s_axi_arprot_i),
        .s_axi_arqos_i(s_axi_arqos_i),
        .s_axi_arvalid_i(s_axi_arvalid_i),
        .s_axi_arready_o(s_axi_arready_o),
        .s_axi_rid_o(s_axi_rid_o),
        .s_axi_rdata_o(s_axi_rdata_o),
        .s_axi_rresp_o(s_axi_rresp_o),
        .s_axi_rlast_o(s_axi_rlast_o),
        .s_axi_rvalid_o(s_axi_rvalid_o),
        .s_axi_rready_i(s_axi_rready_i),
        .s_axi_awid_i(s_axi_awid_i),
        .s_axi_awaddr_i(s_axi_awaddr_i),
        .s_axi_awlen_i(s_axi_awlen_i),
        .s_axi_awsize_i(s_axi_awsize_i),
        .s_axi_awburst_i(s_axi_awburst_i),
        .s_axi_awlock_i(s_axi_awlock_i),
        .s_axi_awcache_i(s_axi_awcache_i),
        .s_axi_awprot_i(s_axi_awprot_i),
        .s_axi_awqos_i(s_axi_awqos_i),
        .s_axi_awvalid_i(s_axi_awvalid_i),
        .s_axi_awready_o(s_axi_awready_o),
        .s_axi_wdata_i(s_axi_wdata_i),
        .s_axi_wstrb_i(s_axi_wstrb_i),
        .s_axi_wlast_i(s_axi_wlast_i),
        .s_axi_wvalid_i(s_axi_wvalid_i),
        .s_axi_wready_o(s_axi_wready_o),
        .s_axi_bid_o(s_axi_bid_o),
        .s_axi_bresp_o(s_axi_bresp_o),
        .s_axi_bvalid_o(s_axi_bvalid_o),
        .s_axi_bready_i(s_axi_bready_i),
        .timing_cmd_valid_o(timing_cmd_valid),
        .timing_cmd_ready_i(timing_cmd_ready),
        .timing_cmd_write_o(timing_cmd_write),
        .timing_cmd_addr_o(timing_cmd_addr),
        .timing_cmd_bytes_o(timing_cmd_bytes),
        .timing_cmd_tag_o(timing_cmd_tag),
        .timing_resp_valid_i(timing_resp_valid),
        .timing_resp_tag_i(timing_resp_tag),
        .timing_resp_ready_o(timing_resp_ready)
    );

    generate
        if (TIMING_MODEL == 1) begin : g_magic
            openrv64_timing_magic #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .TAG_WIDTH(TIMING_TAG_WIDTH)
            ) u_timing (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .cmd_valid_i(timing_cmd_valid),
                .cmd_ready_o(timing_cmd_ready),
                .cmd_write_i(timing_cmd_write),
                .cmd_addr_i(timing_cmd_addr),
                .cmd_bytes_i(timing_cmd_bytes),
                .cmd_tag_i(timing_cmd_tag),
                .resp_valid_o(timing_resp_valid),
                .resp_tag_o(timing_resp_tag),
                .resp_ready_i(timing_resp_ready)
            );
        end else begin : g_ddr3
            openrv64_timing_ddr3 #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .TAG_WIDTH(TIMING_TAG_WIDTH),
                .CONTROLLER_TCK_PS(CONTROLLER_TCK_PS),
                .REFRESH_INTERVAL(REFRESH_INTERVAL),
                .FRONTEND_LATENCY_PS(FRONTEND_LATENCY_PS),
                .BACKEND_LATENCY_PS(BACKEND_LATENCY_PS),
                .COMMAND_QUEUE_DEPTH(COMMAND_QUEUE_DEPTH),
                .MAX_BURST_TRAIN_BURSTS(MAX_BURST_TRAIN_BURSTS)
            ) u_timing (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .cmd_valid_i(timing_cmd_valid),
                .cmd_ready_o(timing_cmd_ready),
                .cmd_write_i(timing_cmd_write),
                .cmd_addr_i(timing_cmd_addr),
                .cmd_bytes_i(timing_cmd_bytes),
                .cmd_tag_i(timing_cmd_tag),
                .resp_valid_o(timing_resp_valid),
                .resp_tag_o(timing_resp_tag),
                .resp_ready_i(timing_resp_ready)
            );
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if ((TIMING_MODEL != 0) && (TIMING_MODEL != 1))
            $fatal(1, "AXI timed-memory model must be DDR3 (0) or magic (1)");
    end
`endif

endmodule
