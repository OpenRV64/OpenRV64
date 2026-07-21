`timescale 1ns/1ps
`include "complex/bus/defs.v"

module tb_vec_cache_bus #(
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer BUS_DATA_WIDTH = 512,
    parameter integer CACHE_BUS_DATA_WIDTH = 256
);

    localparam integer CLIENT_DATA_WIDTH = 256;
    localparam integer CLIENT_TAG_WIDTH = 8;
    localparam integer AXI_ID_WIDTH = 3;
    localparam [AXI_ID_WIDTH-1:0] AXI_ID = 3'd5;
    localparam integer BUS_BYTES = BUS_DATA_WIDTH / 8;
    localparam integer WB_ADDR_SHIFT = $clog2(BUS_BYTES);

    reg clk;
    reg rst_n;
    reg client_req_valid;
    wire client_req_ready;
    reg [CLIENT_TAG_WIDTH-1:0] client_req_tag;
    reg client_req_write;
    reg [63:0] client_req_addr;
    reg [CLIENT_DATA_WIDTH-1:0] client_req_wdata;
    reg [CLIENT_DATA_WIDTH/8-1:0] client_req_wstrb;
    wire client_resp_valid;
    reg client_resp_ready;
    wire [CLIENT_TAG_WIDTH-1:0] client_resp_tag;
    wire [CLIENT_DATA_WIDTH-1:0] client_resp_rdata;
    wire client_resp_error;
    wire client_resp_retry;
    reg prefetch_valid;
    wire prefetch_ready;
    reg [63:0] prefetch_addr;
    reg [3:0] prefetch_count;
    reg prefetch_streaming;
    wire prefetch_busy;
    wire replay;
    wire busy;

    wire [AXI_ID_WIDTH-1:0] arid;
    wire [63:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arlock;
    wire [3:0] arcache;
    wire [2:0] arprot;
    wire [3:0] arqos;
    wire arvalid;
    reg arready;
    reg [AXI_ID_WIDTH-1:0] rid;
    reg [BUS_DATA_WIDTH-1:0] rdata;
    reg [1:0] rresp;
    reg rlast;
    reg rvalid;
    wire rready;
    wire [AXI_ID_WIDTH-1:0] awid;
    wire [63:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awlock;
    wire [3:0] awcache;
    wire [2:0] awprot;
    wire [3:0] awqos;
    wire awvalid;
    reg awready;
    wire [BUS_DATA_WIDTH-1:0] wdata;
    wire [BUS_BYTES-1:0] wstrb;
    wire wlast;
    wire wvalid;
    reg wready;
    reg [AXI_ID_WIDTH-1:0] bid;
    reg [1:0] bresp;
    reg bvalid;
    wire bready;

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [BUS_DATA_WIDTH-1:0] wb_dat_o;
    wire [BUS_BYTES-1:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;
    reg wb_stall;
    reg wb_ack;
    reg wb_err;
    reg wb_rty;
    reg [BUS_DATA_WIDTH-1:0] wb_dat_i;

    integer bus_read_count_q;
    integer bus_read_transaction_count_q;
    integer bus_write_count_q;
    reg wb_retry_enable_q;
    reg wb_retry_used_q;
    reg [63:0] wb_retry_addr_q;
    reg aw_seen_q;
    reg w_seen_q;
    reg axi_read_active_q;
    reg [63:0] axi_read_addr_q;
    reg [7:0] axi_read_len_q;
    integer axi_read_beat_q;

    function automatic [63:0] word_pattern;
        input [63:0] address;
        begin
            word_pattern = 64'hcafe_0000_0000_0000 |
                           (address >> 3);
        end
    endfunction

    function automatic [BUS_DATA_WIDTH-1:0] bus_pattern;
        input [63:0] address;
        integer pattern_word;
        reg [63:0] aligned_address;
        begin
            aligned_address = address & ~(BUS_BYTES - 1);
            bus_pattern = {BUS_DATA_WIDTH{1'b0}};
            for (pattern_word = 0; pattern_word < BUS_BYTES / 8;
                 pattern_word = pattern_word + 1)
                bus_pattern[pattern_word*64 +: 64] =
                    word_pattern(aligned_address + pattern_word * 8);
        end
    endfunction

    openrv64_vec_sram_cache_bus #(
        .ADDR_WIDTH(64), .CLIENT_DATA_WIDTH(CLIENT_DATA_WIDTH),
        .CLIENTS(1), .CLIENT_TAG_WIDTH(CLIENT_TAG_WIDTH),
        .CACHE_BYTES(256 * 1024), .LINE_BYTES(64), .WAYS(4),
        .MSHRS(8), .CACHE_BUS_DATA_WIDTH(CACHE_BUS_DATA_WIDTH),
        .BUS_TYPE(BUS_TYPE),
        .BUS_DATA_WIDTH(BUS_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH), .AXI_ID(AXI_ID),
        .WB_ADDR_SHIFT(WB_ADDR_SHIFT), .WB_MAX_RETRIES(4)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .client_req_valid_i(client_req_valid),
        .client_req_ready_o(client_req_ready),
        .client_req_tag_i(client_req_tag),
        .client_req_write_i(client_req_write),
        .client_req_addr_i(client_req_addr),
        .client_req_wdata_i(client_req_wdata),
        .client_req_wstrb_i(client_req_wstrb),
        .client_resp_valid_o(client_resp_valid),
        .client_resp_ready_i(client_resp_ready),
        .client_resp_tag_o(client_resp_tag),
        .client_resp_rdata_o(client_resp_rdata),
        .client_resp_error_o(client_resp_error),
        .client_resp_retry_o(client_resp_retry),
        .prefetch_valid_i(prefetch_valid),
        .prefetch_ready_o(prefetch_ready), .prefetch_addr_i(prefetch_addr),
        .prefetch_count_i(prefetch_count),
        .prefetch_streaming_i(prefetch_streaming),
        .prefetch_busy_o(prefetch_busy), .replay_o(replay), .busy_o(busy),
        .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
        .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
        .m_axi_arburst_o(arburst), .m_axi_arlock_o(arlock),
        .m_axi_arcache_o(arcache), .m_axi_arprot_o(arprot),
        .m_axi_arqos_o(arqos), .m_axi_arvalid_o(arvalid),
        .m_axi_arready_i(arready), .m_axi_rid_i(rid),
        .m_axi_rdata_i(rdata), .m_axi_rresp_i(rresp),
        .m_axi_rlast_i(rlast), .m_axi_rvalid_i(rvalid),
        .m_axi_rready_o(rready), .m_axi_awid_o(awid),
        .m_axi_awaddr_o(awaddr), .m_axi_awlen_o(awlen),
        .m_axi_awsize_o(awsize), .m_axi_awburst_o(awburst),
        .m_axi_awlock_o(awlock), .m_axi_awcache_o(awcache),
        .m_axi_awprot_o(awprot), .m_axi_awqos_o(awqos),
        .m_axi_awvalid_o(awvalid), .m_axi_awready_i(awready),
        .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb),
        .m_axi_wlast_o(wlast), .m_axi_wvalid_o(wvalid),
        .m_axi_wready_i(wready), .m_axi_bid_i(bid),
        .m_axi_bresp_i(bresp), .m_axi_bvalid_i(bvalid),
        .m_axi_bready_o(bready), .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb), .wb_we_o(wb_we), .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel), .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte), .wb_lock_o(wb_lock),
        .wb_stall_i(wb_stall), .wb_ack_i(wb_ack), .wb_err_i(wb_err),
        .wb_rty_i(wb_rty), .wb_dat_i(wb_dat_i)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @* begin
        arready = !axi_read_active_q;
        awready = 1'b1;
        wready = 1'b1;
        wb_stall = 1'b0;
        wb_ack = wb_cyc && wb_stb &&
                 !(wb_retry_enable_q && !wb_retry_used_q &&
                   ((wb_adr << WB_ADDR_SHIFT) == wb_retry_addr_q));
        wb_err = 1'b0;
        wb_rty = wb_cyc && wb_stb && wb_retry_enable_q &&
                 !wb_retry_used_q &&
                 ((wb_adr << WB_ADDR_SHIFT) == wb_retry_addr_q);
        wb_dat_i = bus_pattern(wb_adr << WB_ADDR_SHIFT);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rid <= AXI_ID;
            rdata <= {BUS_DATA_WIDTH{1'b0}};
            rresp <= 2'b00;
            rlast <= 1'b1;
            rvalid <= 1'b0;
            bid <= AXI_ID;
            bresp <= 2'b00;
            bvalid <= 1'b0;
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            bus_read_count_q <= 0;
            bus_read_transaction_count_q <= 0;
            bus_write_count_q <= 0;
            wb_retry_used_q <= 1'b0;
            axi_read_active_q <= 1'b0;
            axi_read_addr_q <= 0;
            axi_read_len_q <= 0;
            axi_read_beat_q <= 0;
        end else begin
            if (rvalid && rready) begin
                bus_read_count_q <= bus_read_count_q + 1;
                if (rlast) begin
                    rvalid <= 1'b0;
                    axi_read_active_q <= 1'b0;
                    axi_read_beat_q <= 0;
                end else begin
                    axi_read_beat_q <= axi_read_beat_q + 1;
                    rdata <= bus_pattern(axi_read_addr_q +
                        (axi_read_beat_q + 1) * BUS_BYTES);
                    rlast <= (axi_read_beat_q + 1 == axi_read_len_q);
                end
            end
            if (bvalid && bready)
                bvalid <= 1'b0;
            if (arvalid && arready) begin
                if ((arid != AXI_ID) ||
                    (arsize != $clog2(CACHE_BUS_DATA_WIDTH/8)) ||
                    (arburst != 2'b01) || arlock ||
                    (arcache != 4'b0011))
                    $fatal(1, "malformed vector-cache AXI read");
                rid <= AXI_ID;
                rdata <= bus_pattern(araddr);
                rresp <= 2'b00;
                rlast <= (arlen == 0);
                rvalid <= 1'b1;
                axi_read_active_q <= 1'b1;
                axi_read_addr_q <= araddr;
                axi_read_len_q <= arlen;
                axi_read_beat_q <= 0;
                bus_read_transaction_count_q <=
                    bus_read_transaction_count_q + 1;
            end
            if (awvalid && awready) begin
                if ((awid != AXI_ID) || (awlen != 0) ||
                    (awsize != $clog2(CLIENT_DATA_WIDTH/8)) ||
                    (awburst != 2'b01) || awlock ||
                    (awcache != 4'b0011) || (awaddr != 64'h120))
                    $fatal(1, "malformed vector-cache AXI write address");
                aw_seen_q <= 1'b1;
            end
            if (wvalid && wready) begin
                if (!wlast)
                    $fatal(1, "vector-cache AXI write lacked WLAST");
                if (BUS_DATA_WIDTH == 512) begin
                    if ((wstrb != {{32{1'b1}}, {32{1'b0}}}) ||
                        (wdata[256 +: 256] != client_req_wdata) ||
                        (wdata[0 +: 256] != 0))
                        $fatal(1, "512-bit AXI store lane placement is wrong");
                end
                w_seen_q <= 1'b1;
            end
            if ((aw_seen_q || (awvalid && awready)) &&
                (w_seen_q || (wvalid && wready)) && !bvalid) begin
                bid <= AXI_ID;
                bresp <= 2'b00;
                bvalid <= 1'b1;
                aw_seen_q <= 1'b0;
                w_seen_q <= 1'b0;
                bus_write_count_q <= bus_write_count_q + 1;
            end
            if (wb_cyc && wb_stb && !wb_stall) begin
                if ((wb_cti != 3'b000) || (wb_bte != 2'b00) || wb_lock)
                    $fatal(1, "malformed vector-cache WISHBONE cycle");
                if (wb_rty)
                    wb_retry_used_q <= 1'b1;
                if (wb_ack) begin
                    if (wb_we) begin
                        if (wb_sel != {BUS_BYTES{1'b1}})
                            $fatal(1, "WISHBONE store did not fill its beat");
                        bus_write_count_q <= bus_write_count_q + 1;
                    end else begin
                        bus_read_count_q <= bus_read_count_q + 1;
                    end
                end
            end
        end
    end

    task automatic issue_read;
        input [63:0] address;
        input [7:0] tag;
        input [255:0] expected;
        integer timeout;
        begin
            @(negedge clk);
            client_req_valid = 1'b1;
            client_req_write = 1'b0;
            client_req_addr = address;
            client_req_tag = tag;
            client_req_wdata = 0;
            client_req_wstrb = 0;
            #1;
            timeout = 0;
            while (!client_req_ready && timeout < 2000) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!client_req_ready)
                $fatal(1, "vector-cache bus read request timed out");
            @(posedge clk);
            @(negedge clk);
            client_req_valid = 1'b0;
            timeout = 0;
            while (!client_resp_valid && timeout < 4000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!client_resp_valid || client_resp_error ||
                client_resp_retry || (client_resp_tag != tag) ||
                (client_resp_rdata != expected))
                $fatal(1,
                    "vector-cache bus bad read tag=%0d error=%0b data=%x expected=%x",
                    client_resp_tag, client_resp_error,
                    client_resp_rdata, expected);
            @(posedge clk);
        end
    endtask

    task automatic issue_store;
        input [63:0] address;
        input [7:0] tag;
        input [255:0] data;
        integer timeout;
        begin
            @(negedge clk);
            client_req_valid = 1'b1;
            client_req_write = 1'b1;
            client_req_addr = address;
            client_req_tag = tag;
            client_req_wdata = data;
            client_req_wstrb = {32{1'b1}};
            #1;
            timeout = 0;
            while (!client_req_ready && timeout < 2000) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!client_req_ready)
                $fatal(1, "vector-cache bus store request timed out");
            @(posedge clk);
            @(negedge clk);
            client_req_valid = 1'b0;
            timeout = 0;
            while (!client_resp_valid && timeout < 4000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!client_resp_valid || client_resp_error ||
                client_resp_retry || (client_resp_tag != tag))
                $fatal(1, "vector-cache bus bad store response");
            @(posedge clk);
        end
    endtask

    task automatic issue_prefetch;
        input [63:0] address;
        input [3:0] count;
        input streaming;
        integer timeout;
        begin
            @(negedge clk);
            prefetch_valid = 1'b1;
            prefetch_addr = address;
            prefetch_count = count;
            prefetch_streaming = streaming;
            timeout = 0;
            #1;
            while (!prefetch_ready && timeout < 1000) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!prefetch_ready)
                $fatal(1, "vector-cache prefetch request timed out");
            @(posedge clk);
            @(negedge clk);
            prefetch_valid = 1'b0;
            timeout = 0;
            while (prefetch_busy && timeout < 8000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (prefetch_busy)
                $fatal(1, "vector-cache prefetch fill timed out");
        end
    endtask

    integer reads_before;
    integer transactions_before;
    reg [255:0] store_data;
    initial begin
        client_req_valid = 1'b0;
        client_req_tag = 0;
        client_req_write = 1'b0;
        client_req_addr = 0;
        client_req_wdata = 0;
        client_req_wstrb = 0;
        client_resp_ready = 1'b1;
        prefetch_valid = 1'b0;
        prefetch_addr = 0;
        prefetch_count = 0;
        prefetch_streaming = 1'b0;
        wb_retry_enable_q =
            BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE;
        wb_retry_addr_q = 64'h108;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        issue_read(64'h100, 8'h31,
            {word_pattern(64'h118), word_pattern(64'h110),
             word_pattern(64'h108), word_pattern(64'h100)});
        reads_before = bus_read_count_q;
        issue_read(64'h120, 8'h72,
            {word_pattern(64'h138), word_pattern(64'h130),
             word_pattern(64'h128), word_pattern(64'h120)});
        if (bus_read_count_q != reads_before)
            $fatal(1, "second 256-bit word missed the resident line");

        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
            if ((BUS_DATA_WIDTH != 512) ||
                (bus_read_count_q != (512 / CACHE_BUS_DATA_WIDTH)))
                $fatal(1,
                    "cache-to-512 genbus line refill beat count is wrong");
            if (wb_cyc || wb_stb)
                $fatal(1, "inactive WISHBONE pins were driven");
        end else begin
            if ((BUS_DATA_WIDTH != 64) || (bus_read_count_q != 8) ||
                !wb_retry_used_q)
                $fatal(1, "64-bit WISHBONE refill/retry count is wrong");
            if (arvalid || awvalid || wvalid)
                $fatal(1, "inactive AXI pins were driven");
        end

        // A line-wide cache producer can turn one four-line VPRFM descriptor
        // into one four-beat AXI INCR transaction. Demand reads then hit.
        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
            (CACHE_BUS_DATA_WIDTH == 512)) begin
            reads_before = bus_read_count_q;
            transactions_before = bus_read_transaction_count_q;
            issue_prefetch(64'h400, 4'd4, 1'b1);
            if ((bus_read_count_q != reads_before + 4) ||
                (bus_read_transaction_count_q !=
                 transactions_before + 1)) begin
                $display("VPRFM beats=%0d transactions=%0d expected=4/1",
                    bus_read_count_q - reads_before,
                    bus_read_transaction_count_q - transactions_before);
                $fatal(1,
                    "four-line VPRFM did not become one four-beat AXI burst");
            end
            reads_before = bus_read_count_q;
            issue_read(64'h400, 8'h40,
                {word_pattern(64'h418), word_pattern(64'h410),
                 word_pattern(64'h408), word_pattern(64'h400)});
            issue_read(64'h440, 8'h41,
                {word_pattern(64'h458), word_pattern(64'h450),
                 word_pattern(64'h448), word_pattern(64'h440)});
            issue_read(64'h480, 8'h42,
                {word_pattern(64'h498), word_pattern(64'h490),
                 word_pattern(64'h488), word_pattern(64'h480)});
            issue_read(64'h4c0, 8'h43,
                {word_pattern(64'h4d8), word_pattern(64'h4d0),
                 word_pattern(64'h4c8), word_pattern(64'h4c0)});
            if (bus_read_count_q != reads_before)
                $fatal(1, "VPRFM-filled lines were not resident");
        end

        store_data = {
            64'h4444_4444_4444_4444, 64'h3333_3333_3333_3333,
            64'h2222_2222_2222_2222, 64'h1111_1111_1111_1111};
        issue_store(64'h120, 8'h53, store_data);
        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
            (bus_write_count_q != 1))
            $fatal(1, "256-to-512 genbus store was not one narrow transfer");
        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
            (bus_write_count_q != 4))
            $fatal(1, "64-bit WISHBONE store was not four beats");
        if (busy || prefetch_busy)
            $fatal(1, "bus-facing vector cache remained busy");

        $display("PASS: vector cache %s bus width=%0d client width=256",
            (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ? "AXI4" :
                                                     "WISHBONE B4",
            BUS_DATA_WIDTH);
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "vector-cache bus test timed out");
    end

endmodule
