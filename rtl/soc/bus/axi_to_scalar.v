`timescale 1ns/1ps

// AXI4 slave termination for the platform's existing 64-bit blocking bus.
//
// This is platform glue, not the core-complex external-bus abstraction.  The
// core complex still terminates its neutral L2 request channel in genbus.
// This block lets the AXI selection of genbus reach the existing simulation
// decoder and peripherals without routing the core complex through Wishbone.
//
// One AXI read burst and one AXI write burst may be active.  AXI beats wider
// than the scalar bus are split into 64-bit accesses.  Read and write accesses
// are arbitrated at scalar-access granularity.
module openrv64_soc_axi_to_scalar #(
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
    output wire [63:0]               mem_wdata_o,
    output wire [7:0]                mem_wstrb_o,
    input  wire [63:0]               mem_rdata_i,
    input  wire                      mem_error_i
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer MAX_SCALAR_WORDS = DATA_WIDTH / 64;
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
    reg [7:0] read_subword_q;
    reg [DATA_WIDTH-1:0] read_data_q;
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
    reg [7:0] write_subword_q;
    reg write_error_q;

    reg w_valid_q;
    reg [DATA_WIDTH-1:0] w_data_q;
    reg [DATA_BYTES-1:0] w_strb_q;
    reg w_last_q;

    reg b_valid_q;
    reg [ID_WIDTH-1:0] b_id_q;
    reg [1:0] b_resp_q;
    reg prefer_write_q;

    // The scalar response has no tag.  Hold an explicit owner and request
    // payload from launch through acknowledgment so arbitration cannot
    // reinterpret a write acknowledgment as read data (or vice versa).
    reg scalar_inflight_q;
    reg scalar_owner_write_q;
    reg [ADDR_WIDTH-1:0] scalar_addr_q;
    reg [63:0] scalar_wdata_q;
    reg [7:0] scalar_wstrb_q;
`ifndef SYNTHESIS
    reg trace_enabled;
`endif

    function automatic [7:0] scalar_word_count;
        input [2:0] size;
        begin
            if (size <= 3)
                scalar_word_count = 1;
            else
                scalar_word_count = 8'd1 << (size - 3);
        end
    endfunction

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

    wire [7:0] read_scalar_words = scalar_word_count(read_size_q);
    wire [7:0] write_scalar_words = scalar_word_count(write_size_q);
    wire read_subword_last =
        (read_subword_q + 1'b1) >= read_scalar_words;
    wire write_subword_last =
        (write_subword_q + 1'b1) >= write_scalar_words;
    wire read_beat_last = read_beat_q >= read_len_q;
    wire write_beat_last = write_beat_q >= write_len_q;

    wire [7:0] read_base_lane =
        (read_addr_q & (DATA_BYTES - 1)) >> 3;
    wire [7:0] write_base_lane =
        (write_addr_q & (DATA_BYTES - 1)) >> 3;
    wire [7:0] read_lane = read_base_lane + read_subword_q;
    wire [7:0] write_lane = write_base_lane + write_subword_q;

    wire [ADDR_WIDTH-1:0] read_scalar_addr =
        (read_size_q <= 3) ? read_addr_q :
        read_addr_q + (read_subword_q << 3);
    wire [ADDR_WIDTH-1:0] write_scalar_addr =
        (write_size_q <= 3) ? write_addr_q :
        write_addr_q + (write_subword_q << 3);
    wire [63:0] write_scalar_data =
        w_data_q >> (write_lane * 64);
    wire [7:0] write_scalar_strb =
        w_strb_q >> (write_lane * 8);
    wire write_scalar_has_bytes = |write_scalar_strb;
    wire [DATA_WIDTH-1:0] read_scalar_shifted =
        {{(DATA_WIDTH-64){1'b0}}, mem_rdata_i} << (read_lane * 64);

    wire read_scalar_pending = read_active_q && !r_valid_q;
    wire write_scalar_pending =
        write_active_q && w_valid_q && !b_valid_q;
    wire select_write = write_scalar_pending &&
        (!read_scalar_pending || prefer_write_q);
    wire select_read = read_scalar_pending && !select_write;
    wire read_scalar_issue = !scalar_inflight_q && select_read;
    wire write_scalar_issue = !scalar_inflight_q && select_write &&
                              write_scalar_has_bytes;
    wire write_scalar_skip = !scalar_inflight_q && select_write &&
                             !write_scalar_has_bytes;
    wire read_scalar_fire = scalar_inflight_q &&
                            !scalar_owner_write_q && mem_ready_i;
    wire write_scalar_response_fire = scalar_inflight_q &&
                                      scalar_owner_write_q && mem_ready_i;
    wire write_scalar_fire = write_scalar_response_fire ||
                             write_scalar_skip;

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

    assign mem_valid_o = scalar_inflight_q;
    assign mem_write_o = scalar_owner_write_q;
    assign mem_addr_o = scalar_addr_q;
    assign mem_wdata_o = scalar_wdata_q;
    assign mem_wstrb_o = scalar_wstrb_q;

    initial begin
        if ((DATA_WIDTH < 64) || (DATA_WIDTH > 512) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "AXI-to-scalar DATA_WIDTH must be 64 through 512");
        if ((DATA_WIDTH % 64) != 0)
            $fatal(1, "AXI-to-scalar DATA_WIDTH must contain 64-bit words");
        if (ADDR_WIDTH < 16)
            $fatal(1, "AXI-to-scalar ADDR_WIDTH is too small");
        if (ID_WIDTH < 1)
            $fatal(1, "AXI-to-scalar ID_WIDTH must be positive");
        if (MAX_SCALAR_WORDS > 8)
            $fatal(1, "AXI-to-scalar supports at most eight scalar words");
`ifndef SYNTHESIS
        trace_enabled = $test$plusargs("axi_scalar_trace");
`endif
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_active_q <= 1'b0;
            read_id_q <= {ID_WIDTH{1'b0}};
            read_addr_q <= {ADDR_WIDTH{1'b0}};
            read_len_q <= 8'd0;
            read_size_q <= 3'd0;
            read_burst_q <= AXI_BURST_INCR;
            read_beat_q <= 8'd0;
            read_subword_q <= 8'd0;
            read_data_q <= {DATA_WIDTH{1'b0}};
            read_error_q <= 1'b0;
            r_valid_q <= 1'b0;
            r_id_q <= {ID_WIDTH{1'b0}};
            r_data_q <= {DATA_WIDTH{1'b0}};
            r_resp_q <= AXI_RESP_OKAY;
            r_last_q <= 1'b0;

            write_active_q <= 1'b0;
            write_id_q <= {ID_WIDTH{1'b0}};
            write_addr_q <= {ADDR_WIDTH{1'b0}};
            write_len_q <= 8'd0;
            write_size_q <= 3'd0;
            write_burst_q <= AXI_BURST_INCR;
            write_beat_q <= 8'd0;
            write_subword_q <= 8'd0;
            write_error_q <= 1'b0;
            w_valid_q <= 1'b0;
            w_data_q <= {DATA_WIDTH{1'b0}};
            w_strb_q <= {DATA_BYTES{1'b0}};
            w_last_q <= 1'b0;
            b_valid_q <= 1'b0;
            b_id_q <= {ID_WIDTH{1'b0}};
            b_resp_q <= AXI_RESP_OKAY;
            prefer_write_q <= 1'b0;
            scalar_inflight_q <= 1'b0;
            scalar_owner_write_q <= 1'b0;
            scalar_addr_q <= {ADDR_WIDTH{1'b0}};
            scalar_wdata_q <= 64'd0;
            scalar_wstrb_q <= 8'd0;
        end else begin
`ifndef SYNTHESIS
            if (trace_enabled && ar_fire)
                $display("AXI_SCALAR AR id=%0d addr=%016x len=%0d size=%0d",
                         s_axi_arid_i, s_axi_araddr_i,
                         s_axi_arlen_i, s_axi_arsize_i);
            if (trace_enabled && aw_fire)
                $display("AXI_SCALAR AW id=%0d addr=%016x len=%0d size=%0d",
                         s_axi_awid_i, s_axi_awaddr_i,
                         s_axi_awlen_i, s_axi_awsize_i);
            if (trace_enabled && read_scalar_fire)
                $display("AXI_SCALAR R addr=%016x data=%016x error=%0d",
                         scalar_addr_q, mem_rdata_i, mem_error_i);
            if (trace_enabled && write_scalar_response_fire)
                $display("AXI_SCALAR W addr=%016x data=%016x strb=%02x error=%0d",
                         scalar_addr_q, scalar_wdata_q,
                         scalar_wstrb_q, mem_error_i);
`endif
            if (read_scalar_issue) begin
                scalar_inflight_q <= 1'b1;
                scalar_owner_write_q <= 1'b0;
                scalar_addr_q <= read_scalar_addr;
                scalar_wdata_q <= 64'd0;
                scalar_wstrb_q <= 8'd0;
            end else if (write_scalar_issue) begin
                scalar_inflight_q <= 1'b1;
                scalar_owner_write_q <= 1'b1;
                scalar_addr_q <= write_scalar_addr;
                scalar_wdata_q <= write_scalar_data;
                scalar_wstrb_q <= write_scalar_strb;
            end

            if (scalar_inflight_q && mem_ready_i)
                scalar_inflight_q <= 1'b0;

            if (ar_fire) begin
                read_active_q <= 1'b1;
                read_id_q <= s_axi_arid_i;
                read_addr_q <= s_axi_araddr_i;
                read_len_q <= s_axi_arlen_i;
                read_size_q <= s_axi_arsize_i;
                read_burst_q <= s_axi_arburst_i;
                read_beat_q <= 8'd0;
                read_subword_q <= 8'd0;
                read_data_q <= {DATA_WIDTH{1'b0}};
                read_error_q <=
                    (s_axi_arsize_i > $clog2(DATA_BYTES)) ||
                    ((s_axi_arburst_i != AXI_BURST_FIXED) &&
                     (s_axi_arburst_i != AXI_BURST_INCR));
            end

            if (read_scalar_fire) begin
                prefer_write_q <= 1'b1;
                if (read_subword_last) begin
                    r_valid_q <= 1'b1;
                    r_id_q <= read_id_q;
                    r_data_q <= read_data_q | read_scalar_shifted;
                    r_resp_q <= (read_error_q || mem_error_i) ?
                                AXI_RESP_SLVERR : AXI_RESP_OKAY;
                    r_last_q <= read_beat_last;
                    read_error_q <= read_error_q || mem_error_i;
                end else begin
                    read_data_q <= read_data_q | read_scalar_shifted;
                    read_error_q <= read_error_q || mem_error_i;
                    read_subword_q <= read_subword_q + 1'b1;
                end
            end

            if (r_fire) begin
                r_valid_q <= 1'b0;
                if (r_last_q) begin
                    read_active_q <= 1'b0;
                end else begin
                    read_addr_q <= next_beat_addr(
                        read_addr_q, read_size_q, read_burst_q);
                    read_beat_q <= read_beat_q + 1'b1;
                    read_subword_q <= 8'd0;
                    read_data_q <= {DATA_WIDTH{1'b0}};
                    read_error_q <= 1'b0;
                end
            end

            if (aw_fire) begin
                write_active_q <= 1'b1;
                write_id_q <= s_axi_awid_i;
                write_addr_q <= s_axi_awaddr_i;
                write_len_q <= s_axi_awlen_i;
                write_size_q <= s_axi_awsize_i;
                write_burst_q <= s_axi_awburst_i;
                write_beat_q <= 8'd0;
                write_subword_q <= 8'd0;
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

            if (write_scalar_fire) begin
                prefer_write_q <= 1'b0;
                if (write_subword_last) begin
                    w_valid_q <= 1'b0;
                    write_subword_q <= 8'd0;
                    if (write_beat_last) begin
                        write_active_q <= 1'b0;
                        b_valid_q <= 1'b1;
                        b_id_q <= write_id_q;
                        b_resp_q <=
                            (write_error_q ||
                             (write_scalar_has_bytes && mem_error_i) ||
                             !w_last_q) ?
                            AXI_RESP_SLVERR : AXI_RESP_OKAY;
                    end else begin
                        write_addr_q <= next_beat_addr(
                            write_addr_q, write_size_q, write_burst_q);
                        write_beat_q <= write_beat_q + 1'b1;
                        write_error_q <= write_error_q ||
                            (write_scalar_has_bytes && mem_error_i) ||
                            w_last_q;
                    end
                end else begin
                    write_subword_q <= write_subword_q + 1'b1;
                    write_error_q <= write_error_q ||
                        (write_scalar_has_bytes && mem_error_i);
                end
            end

            if (b_fire)
                b_valid_q <= 1'b0;
        end
    end

endmodule
