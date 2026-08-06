`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

module tb_core_complex #(
    parameter integer NUM_HARTS = 2,
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI
);

    localparam integer DATA_WIDTH = 64;
    localparam integer ID_WIDTH = 3;
    localparam integer HART_ID_BASE = 5;

    logic clk;
    logic rst_n;

    logic [NUM_HARTS-1:0] icx_req_valid;
    wire [NUM_HARTS-1:0] icx_req_ready;
    logic [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_req_hart_id;
    logic [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_req_txn_id;
    logic [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_req_source_id;
    logic [NUM_HARTS*`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic [NUM_HARTS-1:0] icx_req_lock;
    logic [NUM_HARTS*`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    logic [NUM_HARTS*`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [NUM_HARTS*`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    logic [NUM_HARTS*3-1:0] icx_req_size;
    logic [NUM_HARTS*64-1:0] icx_req_addr;
    logic [NUM_HARTS*`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        icx_req_burst_len;

    logic [NUM_HARTS-1:0] icx_wdata_valid;
    wire [NUM_HARTS-1:0] icx_wdata_ready;
    logic [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_wdata_hart_id;
    logic [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_wdata_txn_id;
    logic [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_wdata_source_id;
    logic [NUM_HARTS*`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        icx_wdata_beat_index;
    logic [NUM_HARTS-1:0] icx_wdata_last;
    logic [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    logic [NUM_HARTS*`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;

    wire [NUM_HARTS-1:0] icx_resp_valid;
    logic [NUM_HARTS-1:0] icx_resp_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_resp_txn_id;
    wire [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_resp_source_id;
    wire [NUM_HARTS*`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        icx_resp_beat_index;
    wire [NUM_HARTS-1:0] icx_resp_last;
    wire [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    wire [NUM_HARTS-1:0] icx_resp_error;
    wire [NUM_HARTS-1:0] icx_resp_sc_success;

    wire [ID_WIDTH-1:0] m_axi_arid;
    wire [63:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    logic m_axi_arready;
    logic [ID_WIDTH-1:0] m_axi_rid;
    logic [DATA_WIDTH-1:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    wire m_axi_rready;
    wire [ID_WIDTH-1:0] m_axi_awid;
    wire [63:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [2:0] m_axi_awprot;
    wire [3:0] m_axi_awqos;
    wire m_axi_awvalid;
    logic m_axi_awready;
    wire [DATA_WIDTH-1:0] m_axi_wdata;
    wire [DATA_WIDTH/8-1:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    logic m_axi_wready;
    logic [ID_WIDTH-1:0] m_axi_bid;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    wire m_axi_bready;

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [DATA_WIDTH-1:0] wb_dat_o;
    wire [DATA_WIDTH/8-1:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;
    logic wb_stall;
    logic wb_ack;
    logic wb_err;
    logic wb_rty;
    logic [DATA_WIDTH-1:0] wb_dat_i;

    logic [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        expected_txn;
    logic [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        expected_source;
    logic [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        expected_data;
    logic burst_check;
    logic [63:0] burst_base;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] burst_txn;
    integer burst_responses;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] burst_first_beat;
    logic nonblocking_check;
    integer nonblocking_responses;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] nonblocking_first_txn;
    integer max_active_mshrs;
    integer external_reads;
    integer protocol_requests;
    integer completions;
    integer hart_index;
    logic [63:0] axi_read_addr;
    logic [7:0] axi_read_len;
    integer axi_read_beat;

    openrv64_core_complex_nh #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(HART_ID_BASE),
        .L2_BYTES(256 * 1024),
        .L2_LINE_BYTES(64),
        .L2_WAYS(8),
        .L2_MERGE_ENTRIES(8),
        .BUS_TYPE(BUS_TYPE),
        .BUS_ADDR_WIDTH(64),
        .BUS_DATA_WIDTH(DATA_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH),
        .AXI_ID(3'd7),
        .WB_ADDR_SHIFT(3)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
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
        .icx_wdata_valid_i(icx_wdata_valid),
        .icx_wdata_ready_o(icx_wdata_ready),
        .icx_wdata_hart_id_i(icx_wdata_hart_id),
        .icx_wdata_txn_id_i(icx_wdata_txn_id),
        .icx_wdata_source_id_i(icx_wdata_source_id),
        .icx_wdata_beat_index_i(icx_wdata_beat_index),
        .icx_wdata_last_i(icx_wdata_last),
        .icx_wdata_i(icx_wdata),
        .icx_wstrb_i(icx_wstrb),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
        .m_axi_arid_o(m_axi_arid),
        .m_axi_araddr_o(m_axi_araddr),
        .m_axi_arlen_o(m_axi_arlen),
        .m_axi_arsize_o(m_axi_arsize),
        .m_axi_arburst_o(m_axi_arburst),
        .m_axi_arlock_o(m_axi_arlock),
        .m_axi_arcache_o(m_axi_arcache),
        .m_axi_arprot_o(m_axi_arprot),
        .m_axi_arqos_o(m_axi_arqos),
        .m_axi_arvalid_o(m_axi_arvalid),
        .m_axi_arready_i(m_axi_arready),
        .m_axi_rid_i(m_axi_rid),
        .m_axi_rdata_i(m_axi_rdata),
        .m_axi_rresp_i(m_axi_rresp),
        .m_axi_rlast_i(m_axi_rlast),
        .m_axi_rvalid_i(m_axi_rvalid),
        .m_axi_rready_o(m_axi_rready),
        .m_axi_awid_o(m_axi_awid),
        .m_axi_awaddr_o(m_axi_awaddr),
        .m_axi_awlen_o(m_axi_awlen),
        .m_axi_awsize_o(m_axi_awsize),
        .m_axi_awburst_o(m_axi_awburst),
        .m_axi_awlock_o(m_axi_awlock),
        .m_axi_awcache_o(m_axi_awcache),
        .m_axi_awprot_o(m_axi_awprot),
        .m_axi_awqos_o(m_axi_awqos),
        .m_axi_awvalid_o(m_axi_awvalid),
        .m_axi_awready_i(m_axi_awready),
        .m_axi_wdata_o(m_axi_wdata),
        .m_axi_wstrb_o(m_axi_wstrb),
        .m_axi_wlast_o(m_axi_wlast),
        .m_axi_wvalid_o(m_axi_wvalid),
        .m_axi_wready_i(m_axi_wready),
        .m_axi_bid_i(m_axi_bid),
        .m_axi_bresp_i(m_axi_bresp),
        .m_axi_bvalid_i(m_axi_bvalid),
        .m_axi_bready_o(m_axi_bready),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_we_o(wb_we),
        .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat_o),
        .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte),
        .wb_lock_o(wb_lock),
        .wb_stall_i(wb_stall),
        .wb_ack_i(wb_ack),
        .wb_err_i(wb_err),
        .wb_rty_i(wb_rty),
        .wb_dat_i(wb_dat_i)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [63:0] memory_data;
        input [63:0] address;
        begin
            memory_data = 64'hc0de_0000_0000_0000 ^
                          {address[60:0], 3'b000};
        end
    endfunction

    function automatic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory_line;
        input [63:0] address;
        integer word_index;
        begin
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory_line[word_index*64 +: 64] =
                    memory_data({address[63:6], 6'b0} + word_index*8);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_rid <= 3'd7;
            m_axi_rdata <= 0;
            m_axi_rresp <= 0;
            m_axi_rlast <= 1'b1;
            m_axi_rvalid <= 1'b0;
            m_axi_arready <= 1'b1;
            m_axi_bid <= 0;
            m_axi_bresp <= 0;
            m_axi_bvalid <= 1'b0;
            axi_read_addr <= 0;
            axi_read_len <= 0;
            axi_read_beat <= 0;
        end else begin
            if (m_axi_rvalid && m_axi_rready) begin
                external_reads <= external_reads + 1;
                if (m_axi_rlast) begin
                    m_axi_rvalid <= 1'b0;
                    m_axi_arready <= 1'b1;
                    axi_read_beat <= 0;
                end else begin
                    axi_read_beat <= axi_read_beat + 1;
                    m_axi_rdata <= memory_data(axi_read_addr +
                        (axi_read_beat + 1) * 8);
                    m_axi_rlast <=
                        (axi_read_beat + 1 == axi_read_len);
                end
            end
            if (m_axi_arvalid && m_axi_arready) begin
                if ((m_axi_arid !== 3'd7) || (m_axi_arlen !== 7) ||
                    (m_axi_arsize !== 3) ||
                    (m_axi_arburst !== 2'b01))
                    $fatal(1, "malformed integrated AXI fill burst");
                m_axi_rid <= m_axi_arid;
                m_axi_rdata <= memory_data(m_axi_araddr);
                m_axi_rresp <= 0;
                m_axi_rlast <= (m_axi_arlen == 0);
                m_axi_rvalid <= 1'b1;
                m_axi_arready <= 1'b0;
                axi_read_addr <= m_axi_araddr;
                axi_read_len <= m_axi_arlen;
                axi_read_beat <= 0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack <= 1'b0;
            wb_err <= 1'b0;
            wb_rty <= 1'b0;
            wb_dat_i <= 0;
        end else begin
            wb_ack <= 1'b0;
            wb_err <= 1'b0;
            wb_rty <= 1'b0;
            if (wb_cyc && wb_stb && !wb_stall) begin
                if (wb_we || (wb_sel !== 8'h00) ||
                    (wb_cti !== 3'b000) || (wb_bte !== 2'b00))
                    $fatal(1, "malformed integrated WISHBONE fill beat");
                wb_dat_i <= memory_data(wb_adr << 3);
                wb_ack <= 1'b1;
                external_reads <= external_reads + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dut.line_req_valid && dut.line_req_ready) begin
            if (dut.line_req_hart_id < HART_ID_BASE ||
                dut.line_req_hart_id >= HART_ID_BASE + NUM_HARTS)
                $fatal(1, "N=%0d core-complex hart strap out of range",
                       NUM_HARTS);
            protocol_requests <= protocol_requests + 1;
        end

        if (rst_n && dut.bus_req_valid && dut.bus_req_ready &&
            (dut.u_genbus.upstream_req_burst_i !== 8'd0))
            $fatal(1, "L2 must issue one neutral bus beat at a time");
        if (rst_n && dut.bus_req_valid && dut.bus_req_ready &&
            dut.bus_req_cacheable &&
            ((dut.bus_req_size != 3'd6) ||
             (dut.bus_req_addr[5:0] != 0)))
            $fatal(1, "L2 cache traffic is not a 512-bit aligned line");
        if (rst_n &&
            (dut.u_l2.active_mshr_count_r > max_active_mshrs))
            max_active_mshrs <= dut.u_l2.active_mshr_count_r;

        if (rst_n) begin
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                if (icx_req_valid[hart_index] &&
                    icx_req_ready[hart_index])
                    icx_req_valid[hart_index] <= 1'b0;
                if (icx_wdata_valid[hart_index] &&
                    icx_wdata_ready[hart_index])
                    icx_wdata_valid[hart_index] <= 1'b0;

                if (icx_resp_valid[hart_index] &&
                    icx_resp_ready[hart_index]) begin
                    if (icx_resp_error[hart_index] ||
                        icx_resp_sc_success[hart_index])
                        $fatal(1, "N=%0d hart %0d received bad status",
                               NUM_HARTS, hart_index);
                    if (icx_resp_hart_id[
                            hart_index*`OPENRV64_ICX_HART_ID_WIDTH +:
                            `OPENRV64_ICX_HART_ID_WIDTH] !==
                        HART_ID_BASE + hart_index)
                        $fatal(1, "N=%0d hart %0d response misrouted",
                               NUM_HARTS, hart_index);
                    if (nonblocking_check) begin
                        if (hart_index != 0)
                            $fatal(1,
                                "nonblocking response routed to wrong hart");
                        if (nonblocking_responses == 0)
                            nonblocking_first_txn <=
                                icx_resp_txn_id[
                                    0 +:
                                    `OPENRV64_ICX_TXN_ID_WIDTH];
                        if (icx_resp_txn_id[
                                0 +: `OPENRV64_ICX_TXN_ID_WIDTH] ==
                            4'd7) begin
                            if (icx_resp_rdata[
                                    0 +:
                                    `OPENRV64_ICX_LINE_DATA_WIDTH] !==
                                memory_line(64'h2000))
                                $fatal(1,
                                    "nonblocking miss data mismatch");
                        end else if (icx_resp_txn_id[
                                0 +: `OPENRV64_ICX_TXN_ID_WIDTH] ==
                                     4'd8) begin
                            if (icx_resp_rdata[
                                    0 +:
                                    `OPENRV64_ICX_LINE_DATA_WIDTH] !==
                                memory_line(64'h1800))
                                $fatal(1,
                                    "hit-under-miss data mismatch");
                        end else begin
                            $fatal(1,
                                "unexpected nonblocking response tag");
                        end
                        nonblocking_responses <=
                            nonblocking_responses + 1;
                    end else if (burst_check) begin
                        if (hart_index != 0)
                            $fatal(1, "burst response routed to wrong hart");
                        if (icx_resp_txn_id[
                                0 +: `OPENRV64_ICX_TXN_ID_WIDTH] !=
                            burst_txn ||
                            icx_resp_source_id[
                                0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] !=
                                `OPENRV64_ICX_SOURCE_ICACHE)
                            $fatal(1, "burst response identity mismatch");
                        if (burst_responses == 0)
                            burst_first_beat <=
                                icx_resp_beat_index[
                                    0 +:
                                    `OPENRV64_ICX_BEAT_INDEX_WIDTH];
                        burst_responses <= burst_responses + 1;
                        if (icx_resp_rdata[
                                0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] !==
                            memory_line(burst_base +
                                icx_resp_beat_index[
                                    0 +:
                                    `OPENRV64_ICX_BEAT_INDEX_WIDTH]*64))
                            $fatal(1, "burst response data mismatch");
                        if (icx_resp_last[0] !==
                            (icx_resp_beat_index[
                                0 +:
                                `OPENRV64_ICX_BEAT_INDEX_WIDTH] == 1))
                            $fatal(1, "burst response last mismatch");
                    end else begin
                        if (icx_resp_txn_id[
                                hart_index*`OPENRV64_ICX_TXN_ID_WIDTH +:
                                `OPENRV64_ICX_TXN_ID_WIDTH] !==
                            expected_txn[
                                hart_index*`OPENRV64_ICX_TXN_ID_WIDTH +:
                                `OPENRV64_ICX_TXN_ID_WIDTH] ||
                            icx_resp_source_id[
                                hart_index*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                                `OPENRV64_ICX_SOURCE_ID_WIDTH] !==
                            expected_source[
                                hart_index*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                                `OPENRV64_ICX_SOURCE_ID_WIDTH])
                            $fatal(1, "N=%0d hart %0d identity mismatch",
                                   NUM_HARTS, hart_index);
                        if ((icx_resp_beat_index[
                                hart_index*
                                `OPENRV64_ICX_BEAT_INDEX_WIDTH +:
                                `OPENRV64_ICX_BEAT_INDEX_WIDTH] != 0) ||
                            !icx_resp_last[hart_index])
                            $fatal(1, "single-line response geometry mismatch");
                        if (icx_resp_rdata[
                                hart_index*
                                `OPENRV64_ICX_LINE_DATA_WIDTH +:
                                `OPENRV64_ICX_LINE_DATA_WIDTH] !==
                            expected_data[
                                hart_index*
                                `OPENRV64_ICX_LINE_DATA_WIDTH +:
                                `OPENRV64_ICX_LINE_DATA_WIDTH]) begin
                            $display("actual   %h",
                                icx_resp_rdata[
                                    hart_index*
                                    `OPENRV64_ICX_LINE_DATA_WIDTH +:
                                    `OPENRV64_ICX_LINE_DATA_WIDTH]);
                            $display("expected %h",
                                expected_data[
                                    hart_index*
                                    `OPENRV64_ICX_LINE_DATA_WIDTH +:
                                    `OPENRV64_ICX_LINE_DATA_WIDTH]);
                            $fatal(1, "N=%0d hart %0d line data mismatch",
                                   NUM_HARTS, hart_index);
                        end
                    end
                    completions <= completions + 1;
                end
            end
        end
    end

    task automatic launch_read_all;
        input [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] source;
        input [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] txn;
        input [63:0] address;
        input [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] data;
        integer index;
        begin
            @(negedge clk);
            for (index = 0; index < NUM_HARTS; index = index + 1) begin
                icx_req_valid[index] = 1'b1;
                icx_req_hart_id[
                    index*`OPENRV64_ICX_HART_ID_WIDTH +:
                    `OPENRV64_ICX_HART_ID_WIDTH] = HART_ID_BASE + index;
                icx_req_txn_id[
                    index*`OPENRV64_ICX_TXN_ID_WIDTH +:
                    `OPENRV64_ICX_TXN_ID_WIDTH] = txn;
                icx_req_source_id[
                    index*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                    `OPENRV64_ICX_SOURCE_ID_WIDTH] = source;
                icx_req_op[
                    index*`OPENRV64_ICX_OP_WIDTH +:
                    `OPENRV64_ICX_OP_WIDTH] = `OPENRV64_ICX_OP_READ;
                icx_req_lock[index] = 1'b0;
                icx_req_kind[
                    index*`OPENRV64_ICX_KIND_WIDTH +:
                    `OPENRV64_ICX_KIND_WIDTH] =
                    (source == `OPENRV64_ICX_SOURCE_ICACHE) ?
                    `OPENRV64_ICX_KIND_FETCH :
                    (source == `OPENRV64_ICX_SOURCE_PTW) ?
                    `OPENRV64_ICX_KIND_PTE : `OPENRV64_ICX_KIND_DATA;
                icx_req_attr[
                    index*`OPENRV64_ICX_ATTR_WIDTH +:
                    `OPENRV64_ICX_ATTR_WIDTH] =
                    `OPENRV64_ICX_ATTR_CACHEABLE |
                    ((source == `OPENRV64_ICX_SOURCE_PTW) ?
                     `OPENRV64_ICX_ATTR_IDEMPOTENT :
                     `OPENRV64_ICX_ATTR_NONE);
                icx_req_size[index*3 +: 3] = 3'd6;
                icx_req_addr[index*64 +: 64] = address;
                icx_req_burst_len[
                    index*`OPENRV64_ICX_BURST_LEN_WIDTH +:
                    `OPENRV64_ICX_BURST_LEN_WIDTH] = 0;
                expected_txn[
                    index*`OPENRV64_ICX_TXN_ID_WIDTH +:
                    `OPENRV64_ICX_TXN_ID_WIDTH] = txn;
                expected_source[
                    index*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                    `OPENRV64_ICX_SOURCE_ID_WIDTH] = source;
                expected_data[
                    index*`OPENRV64_ICX_LINE_DATA_WIDTH +:
                    `OPENRV64_ICX_LINE_DATA_WIDTH] = data;
            end
        end
    endtask

    integer target_completions;
    integer reads_after_fill;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] modified_line;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] scalar_response_line;
    logic [63:0] locked_scalar_data;

    initial begin
        if ((NUM_HARTS != 1) && (NUM_HARTS != 2) && (NUM_HARTS != 4))
            $fatal(1, "core-complex bench supports N=1, N=2, or N=4");

        rst_n = 1'b0;
        icx_req_valid = 0;
        icx_req_hart_id = 0;
        icx_req_txn_id = 0;
        icx_req_source_id = 0;
        icx_req_op = 0;
        icx_req_lock = 0;
        icx_req_order = 0;
        icx_req_kind = 0;
        icx_req_attr = 0;
        icx_req_size = 0;
        icx_req_addr = 0;
        icx_req_burst_len = 0;
        icx_wdata_valid = 0;
        icx_wdata_hart_id = 0;
        icx_wdata_txn_id = 0;
        icx_wdata_source_id = 0;
        icx_wdata_beat_index = 0;
        icx_wdata_last = 0;
        icx_wdata = 0;
        icx_wstrb = 0;
        icx_resp_ready = {NUM_HARTS{1'b1}};
        expected_txn = 0;
        expected_source = 0;
        expected_data = 0;
        burst_check = 1'b0;
        burst_base = 0;
        burst_txn = 0;
        burst_responses = 0;
        burst_first_beat = 0;
        nonblocking_check = 1'b0;
        nonblocking_responses = 0;
        nonblocking_first_txn = 0;
        max_active_mshrs = 0;
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b1;
        wb_stall = 1'b0;
        external_reads = 0;
        protocol_requests = 0;
        completions = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        target_completions = completions + NUM_HARTS;
        launch_read_all(`OPENRV64_ICX_SOURCE_ICACHE, 4'd0,
                        64'h800, memory_line(64'h800));
        wait (completions == target_completions);
        if (external_reads != 8)
            $fatal(1, "N=%0d first line fill used %0d external reads",
                   NUM_HARTS, external_reads);

        reads_after_fill = external_reads;
        target_completions = completions + NUM_HARTS;
        launch_read_all(`OPENRV64_ICX_SOURCE_DCACHE, 4'd1,
                        64'h800, memory_line(64'h800));
        wait (completions == target_completions);
        if (external_reads != reads_after_fill)
            $fatal(1, "N=%0d L2 hits escaped to external bus", NUM_HARTS);

        // PTE traffic bypasses private L1D but remains cacheable at the shared
        // L2.  The first request fills one line and the second must hit it.
        reads_after_fill = external_reads;
        target_completions = completions + NUM_HARTS;
        launch_read_all(`OPENRV64_ICX_SOURCE_PTW, 4'd11,
                        64'hc00, memory_line(64'hc00));
        wait (completions == target_completions);
        if (external_reads != reads_after_fill + 8)
            $fatal(1, "N=%0d PTE fill used %0d external reads",
                   NUM_HARTS, external_reads - reads_after_fill);
        reads_after_fill = external_reads;
        target_completions = completions + NUM_HARTS;
        launch_read_all(`OPENRV64_ICX_SOURCE_PTW, 4'd12,
                        64'hc00, memory_line(64'hc00));
        wait (completions == target_completions);
        if (external_reads != reads_after_fill)
            $fatal(1, "N=%0d cached PTE line escaped L2", NUM_HARTS);

        modified_line = memory_line(64'h800);
        modified_line[15:0] = 16'h5aa5;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd2;
        icx_req_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        icx_req_op[0 +: `OPENRV64_ICX_OP_WIDTH] =
            `OPENRV64_ICX_OP_WRITE;
        icx_req_kind[0 +: `OPENRV64_ICX_KIND_WIDTH] =
            `OPENRV64_ICX_KIND_DATA;
        icx_req_attr[0 +: `OPENRV64_ICX_ATTR_WIDTH] =
            `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_size[0 +: 3] = 3'd6;
        icx_req_addr[0 +: 64] = 64'h800;
        icx_wdata_valid[0] = 1'b1;
        icx_wdata_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_wdata_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd2;
        icx_wdata_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        icx_wdata_last[0] = 1'b1;
        icx_wdata[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] = modified_line;
        icx_wstrb[0 +: `OPENRV64_ICX_LINE_STRB_WIDTH] = 64'h3;
        expected_txn[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd2;
        expected_source[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        expected_data[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] = 0;
        target_completions = completions + 1;
        wait (completions == target_completions);

        // The temporary one-hart lock sequence must survive the native line
        // wrapper even though its payload is a scalar lane.
        scalar_response_line = modified_line;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd5;
        icx_req_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        icx_req_op[0 +: `OPENRV64_ICX_OP_WIDTH] =
            `OPENRV64_ICX_OP_READ;
        icx_req_lock[0] = 1'b1;
        icx_req_kind[0 +: `OPENRV64_ICX_KIND_WIDTH] =
            `OPENRV64_ICX_KIND_DATA;
        icx_req_attr[0 +: `OPENRV64_ICX_ATTR_WIDTH] =
            `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_size[0 +: 3] = 3'd3;
        icx_req_addr[0 +: 64] = 64'h808;
        icx_req_burst_len[
            0 +: `OPENRV64_ICX_BURST_LEN_WIDTH] = 0;
        expected_txn[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd5;
        expected_source[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        expected_data[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] =
            scalar_response_line;
        target_completions = completions + 1;
        wait (completions == target_completions);

        locked_scalar_data = 64'h0123_4567_89ab_cdef;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd6;
        icx_req_op[0 +: `OPENRV64_ICX_OP_WIDTH] =
            `OPENRV64_ICX_OP_WRITE;
        icx_req_lock[0] = 1'b1;
        icx_req_size[0 +: 3] = 3'd3;
        icx_req_addr[0 +: 64] = 64'h808;
        icx_wdata_valid[0] = 1'b1;
        icx_wdata_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_wdata_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd6;
        icx_wdata_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        icx_wdata_beat_index[
            0 +: `OPENRV64_ICX_BEAT_INDEX_WIDTH] = 0;
        icx_wdata_last[0] = 1'b1;
        icx_wdata[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] =
            {{(`OPENRV64_ICX_LINE_DATA_WIDTH-64){1'b0}},
              locked_scalar_data} << 64;
        icx_wstrb[0 +: `OPENRV64_ICX_LINE_STRB_WIDTH] =
            64'hff << 8;
        expected_txn[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd6;
        expected_data[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] = 0;
        target_completions = completions + 1;
        wait (completions == target_completions);
        modified_line[64 +: 64] = locked_scalar_data;

        target_completions = completions + NUM_HARTS;
        launch_read_all(`OPENRV64_ICX_SOURCE_ICACHE, 4'd3,
                        64'h800, modified_line);
        wait (completions == target_completions);
        if (external_reads != reads_after_fill)
            $fatal(1, "resident masked line write escaped to external bus");

        burst_check = 1'b1;
        burst_base = 64'h1000;
        burst_txn = 4'd4;
        burst_responses = 0;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd4;
        icx_req_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_ICACHE;
        icx_req_op[0 +: `OPENRV64_ICX_OP_WIDTH] =
            `OPENRV64_ICX_OP_READ;
        icx_req_lock[0] = 1'b0;
        icx_req_kind[0 +: `OPENRV64_ICX_KIND_WIDTH] =
            `OPENRV64_ICX_KIND_FETCH;
        icx_req_attr[0 +: `OPENRV64_ICX_ATTR_WIDTH] =
            `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_size[0 +: 3] = 3'd6;
        icx_req_addr[0 +: 64] = burst_base;
        icx_req_burst_len[
            0 +: `OPENRV64_ICX_BURST_LEN_WIDTH] = 8'd1;
        target_completions = completions + 2;
        wait (completions == target_completions);
        if (external_reads != reads_after_fill + 16)
            $fatal(1, "two-line burst used %0d new external reads",
                   external_reads - reads_after_fill);

        if (max_active_mshrs < 2)
            $fatal(1, "native L2 never held multiple active MSHRs");

        burst_check = 1'b0;
        target_completions = completions + 1;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_hart_id[0 +: `OPENRV64_ICX_HART_ID_WIDTH] =
            HART_ID_BASE;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd9;
        icx_req_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        icx_req_op[0 +: `OPENRV64_ICX_OP_WIDTH] =
            `OPENRV64_ICX_OP_READ;
        icx_req_lock[0] = 1'b0;
        icx_req_kind[0 +: `OPENRV64_ICX_KIND_WIDTH] =
            `OPENRV64_ICX_KIND_DATA;
        icx_req_attr[0 +: `OPENRV64_ICX_ATTR_WIDTH] =
            `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_size[0 +: 3] = 3'd6;
        icx_req_addr[0 +: 64] = 64'h1800;
        icx_req_burst_len[
            0 +: `OPENRV64_ICX_BURST_LEN_WIDTH] = 0;
        expected_txn[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd9;
        expected_source[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_DCACHE;
        expected_data[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH] =
            memory_line(64'h1800);
        wait (completions == target_completions);

        // Beat 1 is resident and must be allowed to pass beat 0's miss.  The
        // requester uses beat_index, not response arrival order.
        burst_check = 1'b1;
        burst_base = 64'h17c0;
        burst_txn = 4'd10;
        burst_responses = 0;
        reads_after_fill = external_reads;
        target_completions = completions + 2;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = burst_txn;
        icx_req_source_id[0 +: `OPENRV64_ICX_SOURCE_ID_WIDTH] =
            `OPENRV64_ICX_SOURCE_ICACHE;
        icx_req_kind[0 +: `OPENRV64_ICX_KIND_WIDTH] =
            `OPENRV64_ICX_KIND_FETCH;
        icx_req_addr[0 +: 64] = burst_base;
        icx_req_burst_len[
            0 +: `OPENRV64_ICX_BURST_LEN_WIDTH] = 8'd1;
        wait (completions == target_completions);
        if (burst_first_beat != 1)
            $fatal(1,
                "partial-hit burst did not complete resident beat first");
        if (external_reads != reads_after_fill + 8)
            $fatal(1, "partial-hit burst refilled %0d external beats",
                   external_reads - reads_after_fill);
        burst_check = 1'b0;

        nonblocking_check = 1'b1;
        nonblocking_responses = 0;
        target_completions = completions + 2;
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd7;
        icx_req_addr[0 +: 64] = 64'h2000;
        wait (!icx_req_valid[0]);
        @(negedge clk);
        icx_req_valid[0] = 1'b1;
        icx_req_txn_id[0 +: `OPENRV64_ICX_TXN_ID_WIDTH] = 4'd8;
        icx_req_addr[0 +: 64] = 64'h1800;
        wait (completions == target_completions);
        if (nonblocking_first_txn != 4'd8)
            $fatal(1,
                "resident hit did not complete ahead of outstanding miss");
        nonblocking_check = 1'b0;

        if (protocol_requests != (5*NUM_HARTS + 8))
            $fatal(1, "N=%0d native command count=%0d",
                   NUM_HARTS, protocol_requests);

        $display("PASS: %0d-hart native 512-bit pipelined/nonblocking L2, cached PTE, masked write, lock, burst, and %s backend",
                 NUM_HARTS,
                 (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ? "AXI4" :
                                                          "WISHBONE B4");
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1, "N=%0d native core-complex test timeout", NUM_HARTS);
    end

endmodule
