`timescale 1ns/1ps

// AXI4 slave termination onto a blocking memory port of the same data width.
//
// One AXI beat produces exactly one memory-port access.  Read and write
// channels may each hold one burst, with arbitration only when both need the
// single memory port in the same cycle.
module openrv64_soc_axi_to_wide #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer ID_WIDTH = 3
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire [ID_WIDTH-1:0]       s_axi_arid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr_i,
    input  wire [7:0]                s_axi_arlen_i,
    input  wire [2:0]                s_axi_arsize_i,
    input  wire [1:0]                s_axi_arburst_i,
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
    input  wire                      s_axi_bready_i,

    output wire                      mem_valid_o,
    input  wire                      mem_ready_i,
    output wire                      mem_write_o,
    output wire [ADDR_WIDTH-1:0]     mem_addr_o,
    output wire [DATA_WIDTH-1:0]     mem_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   mem_wstrb_o,
    input  wire [DATA_WIDTH-1:0]     mem_rdata_i,
    input  wire                      mem_error_i
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR = 2'b01;

    reg read_active_q;
    reg [ID_WIDTH-1:0] read_id_q;
    reg [ADDR_WIDTH-1:0] read_addr_q;
    reg [7:0] read_len_q;
    reg [2:0] read_size_q;
    reg [1:0] read_burst_q;
    reg [7:0] read_beat_q;
    reg read_error_q;

    reg r_valid_q;
    reg [ID_WIDTH-1:0] r_id_q;
    reg [DATA_WIDTH-1:0] r_data_q;
    reg [1:0] r_resp_q;
    reg r_last_q;

    reg write_active_q;
    reg [ID_WIDTH-1:0] write_id_q;
    reg [ADDR_WIDTH-1:0] write_addr_q;
    reg [7:0] write_len_q;
    reg [2:0] write_size_q;
    reg [1:0] write_burst_q;
    reg [7:0] write_beat_q;
    reg write_error_q;

    reg w_valid_q;
    reg [DATA_WIDTH-1:0] w_data_q;
    reg [DATA_BYTES-1:0] w_strb_q;
    reg w_last_q;

    reg b_valid_q;
    reg [ID_WIDTH-1:0] b_id_q;
    reg [1:0] b_resp_q;

    reg prefer_write_q;
    reg mem_inflight_q;
    reg mem_owner_write_q;
    reg [ADDR_WIDTH-1:0] mem_addr_q;
    reg [DATA_WIDTH-1:0] mem_wdata_q;
    reg [DATA_BYTES-1:0] mem_wstrb_q;

    function automatic [ADDR_WIDTH-1:0] next_beat_addr;
        input [ADDR_WIDTH-1:0] addr;
        input [2:0] size;
        input [1:0] burst;
        begin
            if (burst == AXI_BURST_INCR)
                next_beat_addr = addr +
                    ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << size);
            else
                next_beat_addr = addr;
        end
    endfunction

    wire ar_fire = s_axi_arvalid_i && s_axi_arready_o;
    wire r_fire = s_axi_rvalid_o && s_axi_rready_i;
    wire aw_fire = s_axi_awvalid_i && s_axi_awready_o;
    wire w_fire = s_axi_wvalid_i && s_axi_wready_o;
    wire b_fire = s_axi_bvalid_o && s_axi_bready_i;

    wire read_beat_last = read_beat_q >= read_len_q;
    wire write_beat_last = write_beat_q >= write_len_q;
    wire read_pending = read_active_q && !r_valid_q;
    wire write_pending = write_active_q && w_valid_q && !b_valid_q;
    wire select_write = write_pending &&
        (!read_pending || prefer_write_q);
    wire select_read = read_pending && !select_write;
    wire write_has_bytes = |w_strb_q;

    wire read_issue = !mem_inflight_q && select_read;
    wire write_issue = !mem_inflight_q && select_write &&
                       write_has_bytes;
    wire write_skip = !mem_inflight_q && select_write &&
                      !write_has_bytes;
    wire read_complete = mem_inflight_q && !mem_owner_write_q &&
                         mem_ready_i;
    wire write_response_complete =
        mem_inflight_q && mem_owner_write_q && mem_ready_i;
    wire write_complete = write_response_complete || write_skip;

    assign s_axi_arready_o = rst_ni && !read_active_q && !r_valid_q;
    assign s_axi_rid_o = r_id_q;
    assign s_axi_rdata_o = r_data_q;
    assign s_axi_rresp_o = r_resp_q;
    assign s_axi_rlast_o = r_last_q;
    assign s_axi_rvalid_o = r_valid_q;

    assign s_axi_awready_o = rst_ni && !write_active_q && !b_valid_q;
    assign s_axi_wready_o = rst_ni && write_active_q &&
                            !w_valid_q && !b_valid_q;
    assign s_axi_bid_o = b_id_q;
    assign s_axi_bresp_o = b_resp_q;
    assign s_axi_bvalid_o = b_valid_q;

    assign mem_valid_o = mem_inflight_q;
    assign mem_write_o = mem_owner_write_q;
    assign mem_addr_o = mem_addr_q;
    assign mem_wdata_o = mem_wdata_q;
    assign mem_wstrb_o = mem_wstrb_q;

    initial begin
        if ((DATA_WIDTH < 64) || (DATA_WIDTH > 512) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "AXI-to-wide DATA_WIDTH must be 64 through 512");
        if ((DATA_WIDTH % 64) != 0)
            $fatal(1, "AXI-to-wide DATA_WIDTH must contain 64-bit words");
        if (ADDR_WIDTH < 16)
            $fatal(1, "AXI-to-wide ADDR_WIDTH is too small");
        if (ID_WIDTH < 1)
            $fatal(1, "AXI-to-wide ID_WIDTH must be positive");
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_active_q <= 1'b0;
            read_id_q <= 0;
            read_addr_q <= 0;
            read_len_q <= 0;
            read_size_q <= 0;
            read_burst_q <= AXI_BURST_INCR;
            read_beat_q <= 0;
            read_error_q <= 1'b0;
            r_valid_q <= 1'b0;
            r_id_q <= 0;
            r_data_q <= 0;
            r_resp_q <= AXI_RESP_OKAY;
            r_last_q <= 1'b0;

            write_active_q <= 1'b0;
            write_id_q <= 0;
            write_addr_q <= 0;
            write_len_q <= 0;
            write_size_q <= 0;
            write_burst_q <= AXI_BURST_INCR;
            write_beat_q <= 0;
            write_error_q <= 1'b0;
            w_valid_q <= 1'b0;
            w_data_q <= 0;
            w_strb_q <= 0;
            w_last_q <= 1'b0;
            b_valid_q <= 1'b0;
            b_id_q <= 0;
            b_resp_q <= AXI_RESP_OKAY;

            prefer_write_q <= 1'b0;
            mem_inflight_q <= 1'b0;
            mem_owner_write_q <= 1'b0;
            mem_addr_q <= 0;
            mem_wdata_q <= 0;
            mem_wstrb_q <= 0;
        end else begin
            if (read_issue) begin
                mem_inflight_q <= 1'b1;
                mem_owner_write_q <= 1'b0;
                mem_addr_q <= read_addr_q;
                mem_wdata_q <= 0;
                mem_wstrb_q <= 0;
            end else if (write_issue) begin
                mem_inflight_q <= 1'b1;
                mem_owner_write_q <= 1'b1;
                mem_addr_q <= write_addr_q;
                mem_wdata_q <= w_data_q;
                mem_wstrb_q <= w_strb_q;
            end

            if (mem_inflight_q && mem_ready_i)
                mem_inflight_q <= 1'b0;

            if (ar_fire) begin
                read_active_q <= 1'b1;
                read_id_q <= s_axi_arid_i;
                read_addr_q <= s_axi_araddr_i;
                read_len_q <= s_axi_arlen_i;
                read_size_q <= s_axi_arsize_i;
                read_burst_q <= s_axi_arburst_i;
                read_beat_q <= 0;
                read_error_q <=
                    (s_axi_arsize_i > $clog2(DATA_BYTES)) ||
                    ((s_axi_arburst_i != AXI_BURST_FIXED) &&
                     (s_axi_arburst_i != AXI_BURST_INCR));
            end

            if (read_complete) begin
                prefer_write_q <= 1'b1;
                r_valid_q <= 1'b1;
                r_id_q <= read_id_q;
                r_data_q <= mem_rdata_i;
                r_resp_q <= (read_error_q || mem_error_i) ?
                            AXI_RESP_SLVERR : AXI_RESP_OKAY;
                r_last_q <= read_beat_last;
            end

            if (r_fire) begin
                r_valid_q <= 1'b0;
                if (r_last_q) begin
                    read_active_q <= 1'b0;
                end else begin
                    read_addr_q <= next_beat_addr(
                        read_addr_q, read_size_q, read_burst_q);
                    read_beat_q <= read_beat_q + 1'b1;
                end
            end

            if (aw_fire) begin
                write_active_q <= 1'b1;
                write_id_q <= s_axi_awid_i;
                write_addr_q <= s_axi_awaddr_i;
                write_len_q <= s_axi_awlen_i;
                write_size_q <= s_axi_awsize_i;
                write_burst_q <= s_axi_awburst_i;
                write_beat_q <= 0;
                write_error_q <=
                    (s_axi_awsize_i > $clog2(DATA_BYTES)) ||
                    ((s_axi_awburst_i != AXI_BURST_FIXED) &&
                     (s_axi_awburst_i != AXI_BURST_INCR));
            end

            if (w_fire) begin
                w_valid_q <= 1'b1;
                w_data_q <= s_axi_wdata_i;
                w_strb_q <= s_axi_wstrb_i;
                w_last_q <= s_axi_wlast_i;
            end

            if (write_complete) begin
                prefer_write_q <= 1'b0;
                w_valid_q <= 1'b0;
                if (write_beat_last) begin
                    write_active_q <= 1'b0;
                    b_valid_q <= 1'b1;
                    b_id_q <= write_id_q;
                    b_resp_q <=
                        (write_error_q ||
                         (write_has_bytes && mem_error_i) ||
                         !w_last_q) ?
                        AXI_RESP_SLVERR : AXI_RESP_OKAY;
                end else begin
                    write_addr_q <= next_beat_addr(
                        write_addr_q, write_size_q, write_burst_q);
                    write_beat_q <= write_beat_q + 1'b1;
                    write_error_q <= write_error_q ||
                        (write_has_bytes && mem_error_i) ||
                        w_last_q;
                end
            end

            if (b_fire)
                b_valid_q <= 1'b0;
        end
    end

endmodule
