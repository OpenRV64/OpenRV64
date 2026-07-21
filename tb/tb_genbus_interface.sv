`timescale 1ns/1ps
`include "complex/bus/defs.v"

module tb_genbus_interface #(
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer DOWN_WIDTH = 64
);

    localparam integer UP_WIDTH = 256;
    localparam integer UP_BYTES = UP_WIDTH / 8;
    localparam integer DOWN_BYTES = DOWN_WIDTH / 8;
    localparam integer WB_ADDR_SHIFT = $clog2(DOWN_BYTES);
    localparam integer WB_BEATS_PER_REQUEST =
        (UP_BYTES > DOWN_BYTES) ? (UP_BYTES / DOWN_BYTES) : 1;
    localparam integer AXI_ID_WIDTH = 3;
    localparam [AXI_ID_WIDTH-1:0] AXI_ID = 3'd6;
    localparam integer ARQ_DEPTH = 16;
    localparam integer AWQ_DEPTH = 16;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg req_write;
    reg [63:0] req_addr;
    reg [2:0] req_size;
    reg [7:0] req_burst;
    reg [UP_WIDTH-1:0] req_wdata;
    reg [UP_WIDTH/8-1:0] req_wstrb;
    reg req_cacheable;
    wire resp_valid;
    reg resp_ready;
    wire [UP_WIDTH-1:0] resp_rdata;
    wire resp_error;

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
    wire arready;
    wire [AXI_ID_WIDTH-1:0] rid;
    wire [DOWN_WIDTH-1:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
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
    wire awready;
    wire [DOWN_WIDTH-1:0] wdata;
    wire [DOWN_WIDTH/8-1:0] wstrb;
    wire wlast;
    wire wvalid;
    wire wready;
    wire [AXI_ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    wire bready;

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [DOWN_WIDTH-1:0] wb_dat_o;
    wire [DOWN_WIDTH/8-1:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;
    wire wb_stall;
    wire wb_ack;
    wire wb_err;
    wire wb_rty;
    wire [DOWN_WIDTH-1:0] wb_dat_i;

    reg [7:0] memory [0:16383];
    reg [63:0] arq_addr [0:ARQ_DEPTH-1];
    reg [7:0] arq_len [0:ARQ_DEPTH-1];
    reg [2:0] arq_size [0:ARQ_DEPTH-1];
    integer arq_head_q;
    integer arq_tail_q;
    integer arq_count_q;
    integer ar_accepted_q;
    integer ar_beat_q;
    reg allow_axi_reads_q;

    reg [63:0] awq_addr [0:AWQ_DEPTH-1];
    reg [7:0] awq_len [0:AWQ_DEPTH-1];
    reg [2:0] awq_size [0:AWQ_DEPTH-1];
    integer awq_head_q;
    integer awq_tail_q;
    integer awq_count_q;
    integer aw_beat_q;
    integer b_pending_q;
    integer aw_accepted_q;

    integer memory_index;
    integer strobe_index;
    integer absolute_byte;
    integer wb_accept_count_q;
    reg wb_retry_pending_q;
    reg wb_retry_used_q;
    reg cutthrough_seen_q;
    reg memory_epoch_q;

    wire axi_ar_fire = arvalid && arready;
    wire axi_r_fire = rvalid && rready;
    wire axi_r_last_fire = axi_r_fire && rlast;
    wire axi_aw_fire = awvalid && awready;
    wire axi_w_fire = wvalid && wready;
    wire axi_w_last_fire = axi_w_fire && wlast;
    wire axi_b_fire = bvalid && bready;

    assign arready = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
                     (arq_count_q < ARQ_DEPTH);
    assign rid = AXI_ID;
    assign rvalid = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
                    allow_axi_reads_q && (arq_count_q != 0);
    assign rdata = memory_beat(arq_addr[arq_head_q] +
                              (ar_beat_q << arq_size[arq_head_q]),
                              memory_epoch_q);
    assign rresp = 2'b00;
    assign rlast = (ar_beat_q == arq_len[arq_head_q]);

    assign awready = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
                     (awq_count_q < AWQ_DEPTH);
    assign wready = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
                    (awq_count_q != 0);
    assign bid = AXI_ID;
    assign bresp = 2'b00;
    assign bvalid = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
                    (b_pending_q != 0);

    assign wb_stall = 1'b0;
    assign wb_ack = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
                    wb_cyc && wb_stb && !wb_retry_pending_q;
    assign wb_err = 1'b0;
    assign wb_rty = (BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
                    wb_cyc && wb_stb && wb_retry_pending_q;
    assign wb_dat_i = memory_beat(wb_adr << WB_ADDR_SHIFT, memory_epoch_q);

    genbus_interface #(
        .BUS_TYPE(BUS_TYPE),
        .ADDR_WIDTH(64),
        .UPSTREAM_DATA_WIDTH(UP_WIDTH),
        .DOWNSTREAM_DATA_WIDTH(DOWN_WIDTH),
        .READ_BUFFER_DEPTH(8),
        .WRITE_BUFFER_DEPTH(4),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(AXI_ID),
        .WB_ADDR_SHIFT(WB_ADDR_SHIFT),
        .WB_MAX_RETRIES(4)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .upstream_req_valid_i(req_valid),
        .upstream_req_ready_o(req_ready),
        .upstream_req_write_i(req_write),
        .upstream_req_addr_i(req_addr),
        .upstream_req_size_i(req_size),
        .upstream_req_burst_i(req_burst),
        .upstream_req_wdata_i(req_wdata),
        .upstream_req_wstrb_i(req_wstrb),
        .upstream_req_cacheable_i(req_cacheable),
        .upstream_resp_valid_o(resp_valid),
        .upstream_resp_ready_i(resp_ready),
        .upstream_resp_rdata_o(resp_rdata),
        .upstream_resp_error_o(resp_error),
        .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
        .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
        .m_axi_arburst_o(arburst), .m_axi_arlock_o(arlock),
        .m_axi_arcache_o(arcache), .m_axi_arprot_o(arprot),
        .m_axi_arqos_o(arqos), .m_axi_arvalid_o(arvalid),
        .m_axi_arready_i(arready), .m_axi_rid_i(rid),
        .m_axi_rdata_i(rdata), .m_axi_rresp_i(rresp),
        .m_axi_rlast_i(rlast), .m_axi_rvalid_i(rvalid),
        .m_axi_rready_o(rready),
        .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr),
        .m_axi_awlen_o(awlen), .m_axi_awsize_o(awsize),
        .m_axi_awburst_o(awburst), .m_axi_awlock_o(awlock),
        .m_axi_awcache_o(awcache), .m_axi_awprot_o(awprot),
        .m_axi_awqos_o(awqos), .m_axi_awvalid_o(awvalid),
        .m_axi_awready_i(awready), .m_axi_wdata_o(wdata),
        .m_axi_wstrb_o(wstrb), .m_axi_wlast_o(wlast),
        .m_axi_wvalid_o(wvalid), .m_axi_wready_i(wready),
        .m_axi_bid_i(bid), .m_axi_bresp_i(bresp),
        .m_axi_bvalid_i(bvalid), .m_axi_bready_o(bready),
        .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we),
        .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti), .wb_bte_o(wb_bte), .wb_lock_o(wb_lock),
        .wb_stall_i(wb_stall), .wb_ack_i(wb_ack), .wb_err_i(wb_err),
        .wb_rty_i(wb_rty), .wb_dat_i(wb_dat_i)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [255:0] expected_line;
        input [63:0] address;
        integer byte_index;
        begin
            expected_line = 0;
            for (byte_index = 0; byte_index < UP_BYTES;
                 byte_index = byte_index + 1)
                expected_line[8*byte_index +: 8] =
                    memory[address + byte_index];
        end
    endfunction

    function automatic [DOWN_WIDTH-1:0] memory_beat;
        input [63:0] address;
        input memory_epoch;
        integer byte_index;
        integer byte_address;
        begin
            // memory_epoch is an explicit simulator sensitivity token. Some
            // simulators do not infer array reads hidden inside a function.
            memory_beat = {DOWN_WIDTH{1'b0}};
            for (byte_index = 0; byte_index < DOWN_BYTES;
                 byte_index = byte_index + 1) begin
                byte_address = address + byte_index;
                memory_beat[8*byte_index +: 8] = memory[byte_address];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arq_head_q <= 0;
            arq_tail_q <= 0;
            arq_count_q <= 0;
            ar_accepted_q <= 0;
            ar_beat_q <= 0;
            awq_head_q <= 0;
            awq_tail_q <= 0;
            awq_count_q <= 0;
            aw_beat_q <= 0;
            b_pending_q <= 0;
            aw_accepted_q <= 0;
            wb_accept_count_q <= 0;
            wb_retry_used_q <= 1'b0;
            cutthrough_seen_q <= 1'b0;
            memory_epoch_q <= 1'b0;
        end else begin
            if (axi_ar_fire) begin
                if ((arid != AXI_ID) || (arburst != 2'b01) || arlock ||
                    (arsize != 3'd3) || (arcache != 4'b0011))
                    $fatal(1, "malformed genbus AXI read address");
                arq_addr[arq_tail_q] <= araddr;
                arq_len[arq_tail_q] <= arlen;
                arq_size[arq_tail_q] <= arsize;
                arq_tail_q <= (arq_tail_q + 1) % ARQ_DEPTH;
                ar_accepted_q <= ar_accepted_q + 1;
            end
            if (axi_r_fire) begin
                if (rlast) begin
                    arq_head_q <= (arq_head_q + 1) % ARQ_DEPTH;
                    ar_beat_q <= 0;
                end else begin
                    ar_beat_q <= ar_beat_q + 1;
                end
            end
            case ({axi_ar_fire, axi_r_last_fire})
                2'b10: arq_count_q <= arq_count_q + 1;
                2'b01: arq_count_q <= arq_count_q - 1;
                default: arq_count_q <= arq_count_q;
            endcase

            if (axi_aw_fire) begin
                if ((awid != AXI_ID) || (awburst != 2'b01) || awlock ||
                    (awsize != 3'd3) || (awcache != 4'b0011))
                    $fatal(1, "malformed genbus AXI write address");
                awq_addr[awq_tail_q] <= awaddr;
                awq_len[awq_tail_q] <= awlen;
                awq_size[awq_tail_q] <= awsize;
                awq_tail_q <= (awq_tail_q + 1) % AWQ_DEPTH;
                aw_accepted_q <= aw_accepted_q + 1;
            end
            if (axi_w_fire) begin
                if (wlast != (aw_beat_q == awq_len[awq_head_q]))
                    $fatal(1, "genbus AXI WLAST is misplaced");
                for (strobe_index = 0; strobe_index < DOWN_BYTES;
                     strobe_index = strobe_index + 1) begin
                    absolute_byte = awq_addr[awq_head_q] +
                        (aw_beat_q << awq_size[awq_head_q]) + strobe_index;
                    if (wstrb[strobe_index]) begin
                        memory[absolute_byte] <=
                            wdata[8*strobe_index +: 8];
                    end
                end
                if (wlast) begin
                    awq_head_q <= (awq_head_q + 1) % AWQ_DEPTH;
                    aw_beat_q <= 0;
                end else begin
                    aw_beat_q <= aw_beat_q + 1;
                end
                memory_epoch_q <= ~memory_epoch_q;
            end
            case ({axi_aw_fire, axi_w_last_fire})
                2'b10: awq_count_q <= awq_count_q + 1;
                2'b01: awq_count_q <= awq_count_q - 1;
                default: awq_count_q <= awq_count_q;
            endcase
            case ({axi_w_last_fire, axi_b_fire})
                2'b10: b_pending_q <= b_pending_q + 1;
                2'b01: b_pending_q <= b_pending_q - 1;
                default: b_pending_q <= b_pending_q;
            endcase

            if (wb_cyc && wb_stb) begin
                if ((wb_cti != 3'b000) || (wb_bte != 2'b00) || wb_lock)
                    $fatal(1, "malformed genbus WISHBONE beat");
                if (wb_rty)
                    wb_retry_used_q <= 1'b1;
                if (wb_ack) begin
                    wb_accept_count_q <= wb_accept_count_q + 1;
                    if (wb_we) begin
                        for (strobe_index = 0; strobe_index < DOWN_BYTES;
                             strobe_index = strobe_index + 1) begin
                            absolute_byte = (wb_adr << WB_ADDR_SHIFT) +
                                            strobe_index;
                            if (wb_sel[strobe_index]) begin
                                memory[absolute_byte] <=
                                    wb_dat_o[8*strobe_index +: 8];
                            end
                        end
                        memory_epoch_q <= ~memory_epoch_q;
                    end
                end
            end

            if (resp_valid && (arq_count_q != 0) &&
                (arq_len[arq_head_q] == 8'd11) && !rlast)
                cutthrough_seen_q <= 1'b1;
        end
    end

    task automatic send_request;
        input write_request;
        input [63:0] address;
        input [2:0] size;
        input [7:0] burst_count;
        input [255:0] data;
        input [31:0] strobe;
        integer timeout;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = write_request;
            req_addr = address;
            req_size = size;
            req_burst = burst_count;
            req_wdata = data;
            req_wstrb = strobe;
            timeout = 0;
            #1;
            while (!req_ready && timeout < 1000) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!req_ready)
                $fatal(1, "genbus request timed out");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic expect_response;
        input [255:0] expected;
        integer timeout;
        begin
            timeout = 0;
            while (!resp_valid && timeout < 4000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!resp_valid || resp_error || (resp_rdata != expected))
                $fatal(1, "bad genbus response data=%x expected=%x error=%0b",
                       resp_rdata, expected, resp_error);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    reg [255:0] write_data0;
    reg [255:0] write_data1;
    integer ar_before;
    integer wb_before;
    initial begin
        for (memory_index = 0; memory_index < 16384;
             memory_index = memory_index + 1)
            memory[memory_index] =
                (64'h9000_0000_0000_0000 | (memory_index >> 3)) >>
                (8 * (memory_index & 7));

        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_size = 0;
        req_burst = 0;
        req_wdata = 0;
        req_wstrb = 0;
        req_cacheable = 1'b1;
        resp_ready = 1'b1;
        allow_axi_reads_q = 1'b0;
        wb_retry_pending_q =
            BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Admission is independent of downstream completion. On AXI these
        // become three same-ID outstanding four-beat bursts.
        send_request(1'b0, 64'h100, 3'd5, 8'd0, 0, 0);
        send_request(1'b0, 64'h120, 3'd5, 8'd0, 0, 0);
        send_request(1'b0, 64'h140, 3'd5, 8'd0, 0, 0);
        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
            wait (ar_accepted_q == 3);
            if ((arq_count_q != 3) || (arq_len[0] != 8'd3) ||
                (arq_len[1] != 8'd3) || (arq_len[2] != 8'd3))
                $fatal(1, "AXI read buffering or width burst is wrong");
            allow_axi_reads_q = 1'b1;
        end else begin
            wb_retry_pending_q = 1'b0;
        end
        expect_response(expected_line(64'h100));
        expect_response(expected_line(64'h120));
        expect_response(expected_line(64'h140));

        // One burst-count leader plus two contiguous followers must issue one
        // 12-beat AXI burst, while preserving three upstream responses.
        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
            wait (arq_count_q == 0);
            allow_axi_reads_q = 1'b0;
            ar_before = ar_accepted_q;
            send_request(1'b0, 64'h200, 3'd5, 8'd2, 0, 0);
            send_request(1'b0, 64'h220, 3'd5, 8'd0, 0, 0);
            send_request(1'b0, 64'h240, 3'd5, 8'd0, 0, 0);
            wait (ar_accepted_q == ar_before + 1);
            if ((arq_count_q != 1) ||
                (arq_len[arq_head_q] != 8'd11))
                $fatal(1, "declared AXI read coalescing did not form ARLEN=11");
            allow_axi_reads_q = 1'b1;
            expect_response(expected_line(64'h200));
            expect_response(expected_line(64'h220));
            expect_response(expected_line(64'h240));
            if (!cutthrough_seen_q)
                $fatal(1, "coalesced read did not cut through per request");

            // A declared group crossing 4 KiB must be split into legal AXI
            // bursts without changing its three upstream responses.
            wait (arq_count_q == 0);
            allow_axi_reads_q = 1'b0;
            ar_before = ar_accepted_q;
            send_request(1'b0, 64'hfc0, 3'd5, 8'd2, 0, 0);
            send_request(1'b0, 64'hfe0, 3'd5, 8'd0, 0, 0);
            send_request(1'b0, 64'h1000, 3'd5, 8'd0, 0, 0);
            wait (ar_accepted_q == ar_before + 2);
            if ((arq_count_q != 2) ||
                (arq_addr[arq_head_q] != 64'hfc0) ||
                (arq_len[arq_head_q] != 8'd7) ||
                (arq_addr[(arq_head_q + 1) % ARQ_DEPTH] != 64'h1000) ||
                (arq_len[(arq_head_q + 1) % ARQ_DEPTH] != 8'd3))
                $fatal(1, "genbus emitted a burst across a 4 KiB boundary");
            allow_axi_reads_q = 1'b1;
            expect_response(expected_line(64'hfc0));
            expect_response(expected_line(64'hfe0));
            expect_response(expected_line(64'h1000));
        end

        write_data0 = {
            64'hdddd_dddd_dddd_dddd, 64'hcccc_cccc_cccc_cccc,
            64'hbbbb_bbbb_bbbb_bbbb, 64'haaaa_aaaa_aaaa_aaaa};
        write_data1 = {
            64'h4444_4444_4444_4444, 64'h3333_3333_3333_3333,
            64'h2222_2222_2222_2222, 64'h1111_1111_1111_1111};
        wb_before = wb_accept_count_q;
        send_request(1'b1, 64'h300, 3'd5, 8'd0, write_data0,
                     {32{1'b1}});
        send_request(1'b1, 64'h320, 3'd5, 8'd0, write_data1,
                     {32{1'b1}});
        expect_response(0);
        expect_response(0);
        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
            if ((aw_accepted_q != 2) || (awq_len[0] != 8'd3) ||
                (awq_len[1] != 8'd3))
                $fatal(1, "AXI write buffering or width burst is wrong");
        end else if ((wb_accept_count_q - wb_before) !=
                     (2 * WB_BEATS_PER_REQUEST)) begin
            $fatal(1,
                "WISHBONE width %0d drained two writes in %0d beats, expected %0d",
                DOWN_WIDTH, wb_accept_count_q - wb_before,
                2 * WB_BEATS_PER_REQUEST);
        end

        send_request(1'b0, 64'h300, 3'd5, 8'd0, 0, 0);
        send_request(1'b0, 64'h320, 3'd5, 8'd0, 0, 0);
        expect_response(write_data0);
        expect_response(write_data1);

        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) &&
            (wb_cyc || wb_stb))
            $fatal(1, "inactive WISHBONE outputs toggled");
        if ((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
            (arvalid || awvalid || wvalid))
            $fatal(1, "inactive AXI outputs toggled");

        $display("PASS: genbus %s buffered reads/writes, width bursts%s",
            (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ? "AXI4" :
                                                     "WISHBONE-wide",
            (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
                ", declared coalescing, and read cut-through" : "");
        $finish;
    end

    initial begin
        repeat (30000) @(posedge clk);
        $fatal(1, "genbus test timed out");
    end

endmodule
