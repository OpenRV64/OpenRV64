`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

module tb_l2_axi_ddr3;

    localparam integer AXI_DATA_WIDTH = 256;
    localparam integer AXI_ID_WIDTH = 3;
    localparam [63:0] MEM_BASE = 64'h0000_0000_8000_0000;
    localparam integer MEM_BYTES = 64 * 1024;

    logic clk;
    logic rst_n;

    logic ccx_req_valid;
    wire ccx_req_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    logic ccx_req_lock;
    logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    logic [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    logic [2:0] ccx_req_size;
    logic [63:0] ccx_req_addr;
    logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;

    logic ccx_wdata_valid;
    wire ccx_wdata_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    logic ccx_wdata_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;

    wire ccx_resp_valid;
    logic ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    wire ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_error;
    wire ccx_resp_sc_success;

    wire [AXI_ID_WIDTH-1:0] axi_arid;
    wire [63:0] axi_araddr;
    wire [7:0] axi_arlen;
    wire [2:0] axi_arsize;
    wire [1:0] axi_arburst;
    wire axi_arlock;
    wire [3:0] axi_arcache;
    wire [2:0] axi_arprot;
    wire [3:0] axi_arqos;
    wire axi_arvalid;
    wire axi_arready;
    wire [AXI_ID_WIDTH-1:0] axi_rid;
    wire [AXI_DATA_WIDTH-1:0] axi_rdata;
    wire [1:0] axi_rresp;
    wire axi_rlast;
    wire axi_rvalid;
    wire axi_rready;

    wire [AXI_ID_WIDTH-1:0] axi_awid;
    wire [63:0] axi_awaddr;
    wire [7:0] axi_awlen;
    wire [2:0] axi_awsize;
    wire [1:0] axi_awburst;
    wire axi_awlock;
    wire [3:0] axi_awcache;
    wire [2:0] axi_awprot;
    wire [3:0] axi_awqos;
    wire axi_awvalid;
    wire axi_awready;
    wire [AXI_DATA_WIDTH-1:0] axi_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] axi_wstrb;
    wire axi_wlast;
    wire axi_wvalid;
    wire axi_wready;
    wire [AXI_ID_WIDTH-1:0] axi_bid;
    wire [1:0] axi_bresp;
    wire axi_bvalid;
    wire axi_bready;

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [AXI_DATA_WIDTH-1:0] wb_dat;
    wire [AXI_DATA_WIDTH/8-1:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;

    integer axi_read_transactions;
    integer axi_write_transactions;
    integer axi_read_beats;
    integer axi_write_beats;
    integer ddr3_commands;
    integer max_active_mshrs;
    integer max_ddr3_queued;
    integer max_timing_owners;

    openrv64_core_complex_nh #(
        .NUM_HARTS(1),
        .HART_ID_BASE(0),
        .L2_BYTES(256 * 1024),
        .L2_LINE_BYTES(64),
        .L2_WAYS(2),
        .L2_MERGE_ENTRIES(4),
        .L2_WAITERS_PER_MSHR(4),
        .L2_COMMAND_ENTRIES(8),
        .L2_RESPONSE_ENTRIES(8),
        .L2_BUS_DATA_WIDTH(512),
        .BUS_TYPE(`OPENRV64_COMPLEX_BUS_AXI),
        .BUS_ADDR_WIDTH(64),
        .BUS_DATA_WIDTH(AXI_DATA_WIDTH),
        .GENBUS_READ_BUFFER_DEPTH(4),
        .GENBUS_WRITE_BUFFER_DEPTH(4),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(3'd7)
    ) u_complex (
        .clk_i(clk),
        .rst_ni(rst_n),
        .ccx_req_valid_i(ccx_req_valid),
        .ccx_req_ready_o(ccx_req_ready),
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
        .ccx_resp_valid_o(ccx_resp_valid),
        .ccx_resp_ready_i(ccx_resp_ready),
        .ccx_resp_hart_id_o(ccx_resp_hart_id),
        .ccx_resp_txn_id_o(ccx_resp_txn_id),
        .ccx_resp_source_id_o(ccx_resp_source_id),
        .ccx_resp_beat_index_o(ccx_resp_beat_index),
        .ccx_resp_last_o(ccx_resp_last),
        .ccx_resp_rdata_o(ccx_resp_rdata),
        .ccx_resp_error_o(ccx_resp_error),
        .ccx_resp_sc_success_o(ccx_resp_sc_success),
        .m_axi_arid_o(axi_arid),
        .m_axi_araddr_o(axi_araddr),
        .m_axi_arlen_o(axi_arlen),
        .m_axi_arsize_o(axi_arsize),
        .m_axi_arburst_o(axi_arburst),
        .m_axi_arlock_o(axi_arlock),
        .m_axi_arcache_o(axi_arcache),
        .m_axi_arprot_o(axi_arprot),
        .m_axi_arqos_o(axi_arqos),
        .m_axi_arvalid_o(axi_arvalid),
        .m_axi_arready_i(axi_arready),
        .m_axi_rid_i(axi_rid),
        .m_axi_rdata_i(axi_rdata),
        .m_axi_rresp_i(axi_rresp),
        .m_axi_rlast_i(axi_rlast),
        .m_axi_rvalid_i(axi_rvalid),
        .m_axi_rready_o(axi_rready),
        .m_axi_awid_o(axi_awid),
        .m_axi_awaddr_o(axi_awaddr),
        .m_axi_awlen_o(axi_awlen),
        .m_axi_awsize_o(axi_awsize),
        .m_axi_awburst_o(axi_awburst),
        .m_axi_awlock_o(axi_awlock),
        .m_axi_awcache_o(axi_awcache),
        .m_axi_awprot_o(axi_awprot),
        .m_axi_awqos_o(axi_awqos),
        .m_axi_awvalid_o(axi_awvalid),
        .m_axi_awready_i(axi_awready),
        .m_axi_wdata_o(axi_wdata),
        .m_axi_wstrb_o(axi_wstrb),
        .m_axi_wlast_o(axi_wlast),
        .m_axi_wvalid_o(axi_wvalid),
        .m_axi_wready_i(axi_wready),
        .m_axi_bid_i(axi_bid),
        .m_axi_bresp_i(axi_bresp),
        .m_axi_bvalid_i(axi_bvalid),
        .m_axi_bready_o(axi_bready),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_we_o(wb_we),
        .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat),
        .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte),
        .wb_lock_o(wb_lock),
        .wb_stall_i(1'b0),
        .wb_ack_i(1'b0),
        .wb_err_i(1'b0),
        .wb_rty_i(1'b0),
        .wb_dat_i({AXI_DATA_WIDTH{1'b0}})
    );

    openrv64_axi_ddr3 #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH),
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(4),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0),
        .COMMAND_QUEUE_DEPTH(8)
    ) u_ddr3 (
        .clk_i(clk),
        .rst_ni(rst_n),
        .s_axi_arid_i(axi_arid),
        .s_axi_araddr_i(axi_araddr),
        .s_axi_arlen_i(axi_arlen),
        .s_axi_arsize_i(axi_arsize),
        .s_axi_arburst_i(axi_arburst),
        .s_axi_arlock_i(axi_arlock),
        .s_axi_arcache_i(axi_arcache),
        .s_axi_arprot_i(axi_arprot),
        .s_axi_arqos_i(axi_arqos),
        .s_axi_arvalid_i(axi_arvalid),
        .s_axi_arready_o(axi_arready),
        .s_axi_rid_o(axi_rid),
        .s_axi_rdata_o(axi_rdata),
        .s_axi_rresp_o(axi_rresp),
        .s_axi_rlast_o(axi_rlast),
        .s_axi_rvalid_o(axi_rvalid),
        .s_axi_rready_i(axi_rready),
        .s_axi_awid_i(axi_awid),
        .s_axi_awaddr_i(axi_awaddr),
        .s_axi_awlen_i(axi_awlen),
        .s_axi_awsize_i(axi_awsize),
        .s_axi_awburst_i(axi_awburst),
        .s_axi_awlock_i(axi_awlock),
        .s_axi_awcache_i(axi_awcache),
        .s_axi_awprot_i(axi_awprot),
        .s_axi_awqos_i(axi_awqos),
        .s_axi_awvalid_i(axi_awvalid),
        .s_axi_awready_o(axi_awready),
        .s_axi_wdata_i(axi_wdata),
        .s_axi_wstrb_i(axi_wstrb),
        .s_axi_wlast_i(axi_wlast),
        .s_axi_wvalid_i(axi_wvalid),
        .s_axi_wready_o(axi_wready),
        .s_axi_bid_o(axi_bid),
        .s_axi_bresp_o(axi_bresp),
        .s_axi_bvalid_o(axi_bvalid),
        .s_axi_bready_i(axi_bready)
    );

    always #0.5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n) begin
            if (axi_arvalid && axi_arready) begin
                axi_read_transactions = axi_read_transactions + 1;
                if ((axi_arid !== 3'd7) || (axi_arlen !== 8'd1) ||
                    (axi_arsize !== 3'd5) ||
                    (axi_arburst !== 2'b01) || axi_arlock ||
                    (axi_araddr[5:0] != 0))
                    $fatal(1, "malformed L2 AXI read burst");
            end
            if (axi_rvalid && axi_rready)
                axi_read_beats = axi_read_beats + 1;
            if (axi_awvalid && axi_awready) begin
                axi_write_transactions = axi_write_transactions + 1;
                if ((axi_awid !== 3'd7) || (axi_awlen !== 8'd1) ||
                    (axi_awsize !== 3'd5) ||
                    (axi_awburst !== 2'b01) || axi_awlock ||
                    (axi_awaddr[5:0] != 0))
                    $fatal(1, "malformed L2 AXI write burst");
            end
            if (axi_wvalid && axi_wready)
                axi_write_beats = axi_write_beats + 1;
            if (u_ddr3.timing_cmd_valid &&
                u_ddr3.timing_cmd_ready) begin
                ddr3_commands = ddr3_commands + 1;
                if (u_ddr3.timing_cmd_bytes !== 16'd64)
                    $fatal(1,
                        "L2 line was not scheduled as one 64-byte DDR3 command");
            end
            if (u_complex.u_l2.active_mshr_count_r >
                max_active_mshrs)
                max_active_mshrs =
                    u_complex.u_l2.active_mshr_count_r;
            if (u_ddr3.u_timing.u_timing.command_count_q >
                max_ddr3_queued)
                max_ddr3_queued =
                    u_ddr3.u_timing.u_timing.command_count_q;
            if (u_ddr3.u_channel.timing_owner_count_q >
                max_timing_owners)
                max_timing_owners =
                    u_ddr3.u_channel.timing_owner_count_q;
            if (wb_cyc || wb_stb || wb_we)
                $fatal(1, "AXI configuration drove WISHBONE");
        end
    end

    task automatic launch_request(
        input [`OPENRV64_CCX_OP_WIDTH-1:0] op,
        input [`OPENRV64_CCX_ATTR_WIDTH-1:0] attr,
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] txn,
        input [63:0] address,
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data
    );
        integer guard;
        begin
            @(negedge clk);
            ccx_req_op = op;
            ccx_req_attr = attr;
            ccx_req_txn_id = txn;
            ccx_req_addr = address;
            ccx_req_valid = 1'b1;
            if (op == `OPENRV64_CCX_OP_WRITE) begin
                ccx_wdata_txn_id = txn;
                ccx_wdata = data;
                ccx_wstrb = {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}};
                ccx_wdata_valid = 1'b1;
            end
            guard = 0;
            while ((ccx_req_valid || ccx_wdata_valid) &&
                   (guard < 2000)) begin
                @(posedge clk);
                if (ccx_req_valid && ccx_req_ready)
                    ccx_req_valid = 1'b0;
                if (ccx_wdata_valid && ccx_wdata_ready)
                    ccx_wdata_valid = 1'b0;
                guard = guard + 1;
            end
            if (ccx_req_valid || ccx_wdata_valid)
                $fatal(1, "CCX request admission timeout txn=%0d", txn);
        end
    endtask

    task automatic expect_response(
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] txn,
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data
    );
        integer guard;
        begin
            guard = 0;
            while (!ccx_resp_valid && (guard < 10000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!ccx_resp_valid)
                $fatal(1, "CCX response timeout txn=%0d", txn);
            if ((ccx_resp_hart_id !== 0) ||
                (ccx_resp_txn_id !== txn) ||
                (ccx_resp_source_id !==
                 `OPENRV64_CCX_SOURCE_DCACHE) ||
                (ccx_resp_beat_index !== 0) || !ccx_resp_last ||
                ccx_resp_error || ccx_resp_sc_success ||
                (ccx_resp_rdata !== data))
                $fatal(1, "CCX response mismatch txn=%0d", txn);
            @(posedge clk);
        end
    endtask

    task automatic transact(
        input [`OPENRV64_CCX_OP_WIDTH-1:0] op,
        input [`OPENRV64_CCX_ATTR_WIDTH-1:0] attr,
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] txn,
        input [63:0] address,
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] write_data,
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] response_data
    );
        begin
            launch_request(op, attr, txn, address, write_data);
            expect_response(txn, response_data);
        end
    endtask

    localparam [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] LINE_A = {
        64'h0707_0707_0707_0707, 64'h0606_0606_0606_0606,
        64'h0505_0505_0505_0505, 64'h0404_0404_0404_0404,
        64'h0303_0303_0303_0303, 64'h0202_0202_0202_0202,
        64'h0101_0101_0101_0101, 64'h0000_0000_0000_0000
    };
    localparam [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] LINE_B = {
        64'h1717_1717_1717_1717, 64'h1616_1616_1616_1616,
        64'h1515_1515_1515_1515, 64'h1414_1414_1414_1414,
        64'h1313_1313_1313_1313, 64'h1212_1212_1212_1212,
        64'h1111_1111_1111_1111, 64'h1010_1010_1010_1010
    };
    localparam [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] LINE_C = {
        8{64'hc3c3_c3c3_c3c3_c3c3}
    };
    integer reads_before_hit;
    integer commands_before_hit;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        ccx_req_valid = 1'b0;
        ccx_req_hart_id = 0;
        ccx_req_txn_id = 0;
        ccx_req_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
        ccx_req_op = `OPENRV64_CCX_OP_READ;
        ccx_req_lock = 1'b0;
        ccx_req_order = `OPENRV64_CCX_ORDER_NONE;
        ccx_req_kind = `OPENRV64_CCX_KIND_DATA;
        ccx_req_attr = `OPENRV64_CCX_ATTR_NONE;
        ccx_req_size = 3'd6;
        ccx_req_addr = 0;
        ccx_req_burst_len = 0;
        ccx_wdata_valid = 1'b0;
        ccx_wdata_hart_id = 0;
        ccx_wdata_txn_id = 0;
        ccx_wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
        ccx_wdata_beat_index = 0;
        ccx_wdata_last = 1'b1;
        ccx_wdata = 0;
        ccx_wstrb = 0;
        ccx_resp_ready = 1'b1;
        axi_read_transactions = 0;
        axi_write_transactions = 0;
        axi_read_beats = 0;
        axi_write_beats = 0;
        ddr3_commands = 0;
        max_active_mshrs = 0;
        max_ddr3_queued = 0;
        max_timing_owners = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Uncached traffic proves the complete write and read paths through
        // L2 bypass, AXI burst conversion, storage, and DDR3 timing.
        transact(`OPENRV64_CCX_OP_WRITE, `OPENRV64_CCX_ATTR_NONE,
                 4'd1, MEM_BASE, LINE_A, 512'd0);
        transact(`OPENRV64_CCX_OP_READ, `OPENRV64_CCX_ATTR_NONE,
                 4'd2, MEM_BASE, 512'd0, LINE_A);

        // The first cacheable read fills L2; the second must hit without
        // another AXI transaction or DDR3 command.
        transact(`OPENRV64_CCX_OP_READ,
                 `OPENRV64_CCX_ATTR_CACHEABLE,
                 4'd3, MEM_BASE, 512'd0, LINE_A);
        reads_before_hit = axi_read_transactions;
        commands_before_hit = ddr3_commands;
        transact(`OPENRV64_CCX_OP_READ,
                 `OPENRV64_CCX_ATTR_CACHEABLE,
                 4'd4, MEM_BASE, 512'd0, LINE_A);
        if ((axi_read_transactions != reads_before_hit) ||
            (ddr3_commands != commands_before_hit))
            $fatal(1, "L2 hit escaped to AXI/DDR3");

        // A read and write to independent banks may both enter the DDR3
        // scheduler.  Responses remain in acceptance order.
        transact(`OPENRV64_CCX_OP_WRITE, `OPENRV64_CCX_ATTR_NONE,
                 4'd5, MEM_BASE + 64'h4000, LINE_C, 512'd0);
        launch_request(`OPENRV64_CCX_OP_READ,
                       `OPENRV64_CCX_ATTR_NONE,
                       4'd6, MEM_BASE + 64'h4000, 512'd0);
        launch_request(`OPENRV64_CCX_OP_WRITE,
                       `OPENRV64_CCX_ATTR_NONE,
                       4'd7, MEM_BASE + 64'h2000, LINE_B);
        expect_response(4'd6, LINE_C);
        expect_response(4'd7, 512'd0);

        // Launch cacheable misses to those different-bank lines without
        // waiting between requests.  L2 must retain both misses even though
        // the AXI and DDR3 response streams remain ordered.
        launch_request(`OPENRV64_CCX_OP_READ,
                       `OPENRV64_CCX_ATTR_CACHEABLE,
                       4'd8, MEM_BASE + 64'h4000, 512'd0);
        launch_request(`OPENRV64_CCX_OP_READ,
                       `OPENRV64_CCX_ATTR_CACHEABLE,
                       4'd9, MEM_BASE + 64'h2000, 512'd0);
        expect_response(4'd8, LINE_C);
        expect_response(4'd9, LINE_B);

        if (max_active_mshrs < 2)
            $fatal(1, "L2 never retained two outstanding misses");
        if ((max_ddr3_queued < 2) || (max_timing_owners < 2))
            $fatal(1,
                "independent AXI bursts never overlapped in DDR3 scheduler");
        if (axi_read_beats != 2 * axi_read_transactions)
            $fatal(1, "AXI read burst beat count mismatch");
        if (axi_write_beats != 2 * axi_write_transactions)
            $fatal(1, "AXI write burst beat count mismatch");
        if (ddr3_commands !=
            (axi_read_transactions + axi_write_transactions))
            $fatal(1,
                "DDR3 command count does not match complete AXI bursts");

        $display(
            "tb_l2_axi_ddr3: PASS reads=%0d writes=%0d rbeats=%0d wbeats=%0d ddr3_cmds=%0d max_mshrs=%0d max_ddr3_queued=%0d",
            axi_read_transactions, axi_write_transactions,
            axi_read_beats, axi_write_beats, ddr3_commands,
            max_active_mshrs, max_ddr3_queued);
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "L2 -> AXI -> DDR3 test timeout");
    end

endmodule
