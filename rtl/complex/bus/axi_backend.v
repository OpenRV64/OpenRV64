`timescale 1ns/1ps

// Single-outstanding adapter from the core-complex beat interface to AXI4.
// The neutral request already contains AXI-lane-positioned data and strobes.
// A cache-line transaction is decomposed into beats above this module.
module openrv64_complex_axi_backend #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer ID_WIDTH = 3,
    parameter [ID_WIDTH-1:0] AXI_ID = {ID_WIDTH{1'b1}}
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire                      req_write_i,
    input  wire [63:0]               req_addr_i,
    input  wire [2:0]                req_size_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    input  wire                      req_cacheable_i,

    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [DATA_WIDTH-1:0]     resp_rdata_o,
    output wire                      resp_error_o,

    output wire [ID_WIDTH-1:0]       m_axi_arid_o,
    output wire [ADDR_WIDTH-1:0]     m_axi_araddr_o,
    output wire [7:0]                m_axi_arlen_o,
    output wire [2:0]                m_axi_arsize_o,
    output wire [1:0]                m_axi_arburst_o,
    output wire                      m_axi_arlock_o,
    output wire [3:0]                m_axi_arcache_o,
    output wire [2:0]                m_axi_arprot_o,
    output wire [3:0]                m_axi_arqos_o,
    output wire                      m_axi_arvalid_o,
    input  wire                      m_axi_arready_i,
    input  wire [ID_WIDTH-1:0]       m_axi_rid_i,
    input  wire [DATA_WIDTH-1:0]     m_axi_rdata_i,
    input  wire [1:0]                m_axi_rresp_i,
    input  wire                      m_axi_rlast_i,
    input  wire                      m_axi_rvalid_i,
    output wire                      m_axi_rready_o,

    output wire [ID_WIDTH-1:0]       m_axi_awid_o,
    output wire [ADDR_WIDTH-1:0]     m_axi_awaddr_o,
    output wire [7:0]                m_axi_awlen_o,
    output wire [2:0]                m_axi_awsize_o,
    output wire [1:0]                m_axi_awburst_o,
    output wire                      m_axi_awlock_o,
    output wire [3:0]                m_axi_awcache_o,
    output wire [2:0]                m_axi_awprot_o,
    output wire [3:0]                m_axi_awqos_o,
    output wire                      m_axi_awvalid_o,
    input  wire                      m_axi_awready_i,
    output wire [DATA_WIDTH-1:0]     m_axi_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   m_axi_wstrb_o,
    output wire                      m_axi_wlast_o,
    output wire                      m_axi_wvalid_o,
    input  wire                      m_axi_wready_i,
    input  wire [ID_WIDTH-1:0]       m_axi_bid_i,
    input  wire [1:0]                m_axi_bresp_i,
    input  wire                      m_axi_bvalid_i,
    output wire                      m_axi_bready_o
);

    localparam [2:0] STATE_IDLE       = 3'd0;
    localparam [2:0] STATE_READ_ADDR  = 3'd1;
    localparam [2:0] STATE_READ_DATA  = 3'd2;
    localparam [2:0] STATE_WRITE      = 3'd3;
    localparam [2:0] STATE_WRITE_RESP = 3'd4;
    localparam [2:0] STATE_RESPONSE   = 3'd5;

    reg [2:0] state_q;
    reg [63:0] request_addr_q;
    reg [2:0] request_size_q;
    reg [DATA_WIDTH-1:0] request_wdata_q;
    reg [DATA_WIDTH/8-1:0] request_wstrb_q;
    reg request_cacheable_q;
    reg aw_done_q;
    reg w_done_q;
    reg [DATA_WIDTH-1:0] response_data_q;
    reg response_error_q;

    wire request_fire = req_valid_i && req_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;
    wire aw_fire = m_axi_awvalid_o && m_axi_awready_i;
    wire w_fire = m_axi_wvalid_o && m_axi_wready_i;

    assign req_ready_o = (state_q == STATE_IDLE);
    assign resp_valid_o = (state_q == STATE_RESPONSE);
    assign resp_rdata_o = response_data_q;
    assign resp_error_o = response_error_q;

    assign m_axi_arid_o = AXI_ID;
    assign m_axi_araddr_o = request_addr_q[ADDR_WIDTH-1:0];
    assign m_axi_arlen_o = 8'd0;
    assign m_axi_arsize_o = request_size_q;
    assign m_axi_arburst_o = 2'b01;
    assign m_axi_arlock_o = 1'b0;
    assign m_axi_arcache_o = request_cacheable_q ? 4'b0011 : 4'b0000;
    assign m_axi_arprot_o = 3'b000;
    assign m_axi_arqos_o = 4'b0000;
    assign m_axi_arvalid_o = (state_q == STATE_READ_ADDR);
    assign m_axi_rready_o = (state_q == STATE_READ_DATA);

    assign m_axi_awid_o = AXI_ID;
    assign m_axi_awaddr_o = request_addr_q[ADDR_WIDTH-1:0];
    assign m_axi_awlen_o = 8'd0;
    assign m_axi_awsize_o = request_size_q;
    assign m_axi_awburst_o = 2'b01;
    assign m_axi_awlock_o = 1'b0;
    assign m_axi_awcache_o = request_cacheable_q ? 4'b0011 : 4'b0000;
    assign m_axi_awprot_o = 3'b000;
    assign m_axi_awqos_o = 4'b0000;
    assign m_axi_awvalid_o = (state_q == STATE_WRITE) && !aw_done_q;
    assign m_axi_wdata_o = request_wdata_q;
    assign m_axi_wstrb_o = request_wstrb_q;
    assign m_axi_wlast_o = 1'b1;
    assign m_axi_wvalid_o = (state_q == STATE_WRITE) && !w_done_q;
    assign m_axi_bready_o = (state_q == STATE_WRITE_RESP);

    initial begin
        if ((ADDR_WIDTH < 1) || (ADDR_WIDTH > 64))
            $fatal(1, "complex AXI address width must be from 1 through 64");
        if ((DATA_WIDTH < 32) || (DATA_WIDTH > 512) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1,
                "complex AXI data width must be 32, 64, 128, 256, or 512");
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            request_addr_q <= 64'd0;
            request_size_q <= 3'd0;
            request_wdata_q <= {DATA_WIDTH{1'b0}};
            request_wstrb_q <= {DATA_WIDTH/8{1'b0}};
            request_cacheable_q <= 1'b0;
            aw_done_q <= 1'b0;
            w_done_q <= 1'b0;
            response_data_q <= {DATA_WIDTH{1'b0}};
            response_error_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    response_error_q <= 1'b0;
                    if (request_fire) begin
                        request_addr_q <= req_addr_i;
                        request_size_q <= req_size_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        request_cacheable_q <= req_cacheable_i;
                        aw_done_q <= 1'b0;
                        w_done_q <= 1'b0;
                        state_q <= req_write_i ? STATE_WRITE :
                                                 STATE_READ_ADDR;
                    end
                end

                STATE_READ_ADDR: begin
                    if (m_axi_arvalid_o && m_axi_arready_i)
                        state_q <= STATE_READ_DATA;
                end

                STATE_READ_DATA: begin
                    if (m_axi_rvalid_i && m_axi_rready_o) begin
                        response_data_q <= m_axi_rdata_i;
                        response_error_q <= (m_axi_rid_i != AXI_ID) ||
                                            (m_axi_rresp_i != 2'b00) ||
                                            !m_axi_rlast_i;
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_WRITE: begin
                    if (aw_fire)
                        aw_done_q <= 1'b1;
                    if (w_fire)
                        w_done_q <= 1'b1;
                    if ((aw_done_q || aw_fire) &&
                        (w_done_q || w_fire))
                        state_q <= STATE_WRITE_RESP;
                end

                STATE_WRITE_RESP: begin
                    if (m_axi_bvalid_i && m_axi_bready_o) begin
                        response_data_q <= {DATA_WIDTH{1'b0}};
                        response_error_q <= (m_axi_bid_i != AXI_ID) ||
                                            (m_axi_bresp_i != 2'b00);
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (response_fire)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule
