`timescale 1ns/1ps

module tb_mem_channel;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 128;
    localparam integer ID_WIDTH = 4;
    localparam [ADDR_WIDTH-1:0] MEM_BASE = 32'h0000_8000;
    localparam integer MEM_BYTES = 4096;

    logic clk;
    logic rst_n;

    logic [ID_WIDTH-1:0] arid;
    logic [ADDR_WIDTH-1:0] araddr;
    logic [7:0] arlen;
    logic [2:0] arsize;
    logic [1:0] arburst;
    logic arlock;
    logic arvalid;
    wire arready;
    wire [ID_WIDTH-1:0] rid;
    wire [DATA_WIDTH-1:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    logic rready;

    logic [ID_WIDTH-1:0] awid;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic awlock;
    logic awvalid;
    wire awready;
    logic [DATA_WIDTH-1:0] wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic wlast;
    logic wvalid;
    wire wready;
    wire [ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    logic bready;

    wire timing_cmd_valid;
    wire timing_cmd_ready;
    wire timing_cmd_write;
    wire [ADDR_WIDTH-1:0] timing_cmd_addr;
    wire [15:0] timing_cmd_bytes;
    wire timing_resp_valid;
    wire timing_resp_ready;

    logic ddr3_cmd_valid;
    logic ddr3_cmd_write;
    logic [ADDR_WIDTH-1:0] ddr3_cmd_addr;
    logic [15:0] ddr3_cmd_bytes;
    wire ddr3_cmd_ready;
    wire ddr3_resp_valid;
    logic ddr3_resp_ready;

    logic gddr_cmd_valid;
    logic gddr_cmd_write;
    logic [ADDR_WIDTH-1:0] gddr_cmd_addr;
    logic [15:0] gddr_cmd_bytes;
    wire gddr_cmd_ready;
    wire gddr_resp_valid;
    logic gddr_resp_ready;

    logic hbm_cmd_valid;
    logic hbm_cmd_write;
    logic [ADDR_WIDTH-1:0] hbm_cmd_addr;
    logic [15:0] hbm_cmd_bytes;
    wire hbm_cmd_ready;
    wire hbm_resp_valid;
    logic hbm_resp_ready;

    openrv64_mem_channel #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(4)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axi_arid_i(arid), .s_axi_araddr_i(araddr),
        .s_axi_arlen_i(arlen), .s_axi_arsize_i(arsize),
        .s_axi_arburst_i(arburst), .s_axi_arlock_i(arlock),
        .s_axi_arcache_i(4'b0011), .s_axi_arprot_i(3'b000),
        .s_axi_arqos_i(4'b0000), .s_axi_arvalid_i(arvalid),
        .s_axi_arready_o(arready),
        .s_axi_rid_o(rid), .s_axi_rdata_o(rdata),
        .s_axi_rresp_o(rresp), .s_axi_rlast_o(rlast),
        .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
        .s_axi_awid_i(awid), .s_axi_awaddr_i(awaddr),
        .s_axi_awlen_i(awlen), .s_axi_awsize_i(awsize),
        .s_axi_awburst_i(awburst), .s_axi_awlock_i(awlock),
        .s_axi_awcache_i(4'b0011), .s_axi_awprot_i(3'b000),
        .s_axi_awqos_i(4'b0000), .s_axi_awvalid_i(awvalid),
        .s_axi_awready_o(awready),
        .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb),
        .s_axi_wlast_i(wlast), .s_axi_wvalid_i(wvalid),
        .s_axi_wready_o(wready),
        .s_axi_bid_o(bid), .s_axi_bresp_o(bresp),
        .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
        .timing_cmd_valid_o(timing_cmd_valid),
        .timing_cmd_ready_i(timing_cmd_ready),
        .timing_cmd_write_o(timing_cmd_write),
        .timing_cmd_addr_o(timing_cmd_addr),
        .timing_cmd_bytes_o(timing_cmd_bytes),
        .timing_resp_valid_i(timing_resp_valid),
        .timing_resp_ready_o(timing_resp_ready)
    );

    openrv64_timing_ddr4 #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_ddr4 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(timing_cmd_valid),
        .cmd_ready_o(timing_cmd_ready),
        .cmd_write_i(timing_cmd_write),
        .cmd_addr_i(timing_cmd_addr),
        .cmd_bytes_i(timing_cmd_bytes),
        .resp_valid_o(timing_resp_valid),
        .resp_ready_i(timing_resp_ready)
    );

    // Standalone instances prove that the alternative profiles implement the
    // exact same timing contract used above.
    openrv64_timing_ddr3 #(
        .ADDR_WIDTH(ADDR_WIDTH), .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_ddr3 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(ddr3_cmd_valid), .cmd_ready_o(ddr3_cmd_ready),
        .cmd_write_i(ddr3_cmd_write), .cmd_addr_i(ddr3_cmd_addr),
        .cmd_bytes_i(ddr3_cmd_bytes),
        .resp_valid_o(ddr3_resp_valid), .resp_ready_i(ddr3_resp_ready)
    );

    openrv64_timing_gddr6 #(
        .ADDR_WIDTH(ADDR_WIDTH), .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_gddr6 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(gddr_cmd_valid), .cmd_ready_o(gddr_cmd_ready),
        .cmd_write_i(gddr_cmd_write), .cmd_addr_i(gddr_cmd_addr),
        .cmd_bytes_i(gddr_cmd_bytes),
        .resp_valid_o(gddr_resp_valid), .resp_ready_i(gddr_resp_ready)
    );

    openrv64_timing_hbm2 #(
        .ADDR_WIDTH(ADDR_WIDTH), .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_hbm2 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(hbm_cmd_valid), .cmd_ready_o(hbm_cmd_ready),
        .cmd_write_i(hbm_cmd_write), .cmd_addr_i(hbm_cmd_addr),
        .cmd_bytes_i(hbm_cmd_bytes),
        .resp_valid_o(hbm_resp_valid), .resp_ready_i(hbm_resp_ready)
    );

    // The timing presets convert their DRAM clocks into this 1 GHz controller
    // clock, so one measured testbench cycle is one nanosecond.
    always #0.5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #0.01;
        end
    endtask

    task automatic send_aw(
        input [ID_WIDTH-1:0] id,
        input [ADDR_WIDTH-1:0] address,
        input [7:0] length,
        input [2:0] size,
        input [1:0] burst,
        input lock
    );
        integer guard;
        begin
            awid = id;
            awaddr = address;
            awlen = length;
            awsize = size;
            awburst = burst;
            awlock = lock;
            awvalid = 1'b1;
            guard = 0;
            while (!awready && guard < 100) begin
                tick();
                guard = guard + 1;
            end
            if (!awready)
                $fatal(1, "AW timeout id=%0d address=%08x", id, address);
            tick();
            awvalid = 1'b0;
        end
    endtask

    task automatic send_w(
        input [DATA_WIDTH-1:0] data,
        input [DATA_WIDTH/8-1:0] strobe,
        input last
    );
        integer guard;
        begin
            wdata = data;
            wstrb = strobe;
            wlast = last;
            wvalid = 1'b1;
            guard = 0;
            while (!wready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!wready)
                $fatal(1, "W timeout last=%b", last);
            tick();
            wvalid = 1'b0;
        end
    endtask

    task automatic expect_b(
        input [ID_WIDTH-1:0] expected_id,
        input [1:0] expected_resp
    );
        integer guard;
        begin
            guard = 0;
            while (!bvalid && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!bvalid)
                $fatal(1, "B timeout id=%0d", expected_id);
            if ((bid !== expected_id) || (bresp !== expected_resp))
                $fatal(1,
                    "B mismatch got id=%0d resp=%b expected id=%0d resp=%b",
                    bid, bresp, expected_id, expected_resp);
            bready = 1'b1;
            tick();
            bready = 1'b0;
        end
    endtask

    task automatic send_ar(
        input [ID_WIDTH-1:0] id,
        input [ADDR_WIDTH-1:0] address,
        input [7:0] length,
        input [2:0] size,
        input [1:0] burst,
        input lock
    );
        integer guard;
        begin
            arid = id;
            araddr = address;
            arlen = length;
            arsize = size;
            arburst = burst;
            arlock = lock;
            arvalid = 1'b1;
            guard = 0;
            while (!arready && guard < 100) begin
                tick();
                guard = guard + 1;
            end
            if (!arready)
                $fatal(1, "AR timeout id=%0d address=%08x", id, address);
            tick();
            arvalid = 1'b0;
        end
    endtask

    task automatic expect_r(
        input [ID_WIDTH-1:0] expected_id,
        input [DATA_WIDTH-1:0] expected_data,
        input [1:0] expected_resp,
        input expected_last,
        input integer stall_cycles
    );
        integer guard;
        integer stall;
        reg [DATA_WIDTH-1:0] held_data;
        begin
            guard = 0;
            while (!rvalid && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!rvalid)
                $fatal(1, "R timeout id=%0d", expected_id);
            if ((rid !== expected_id) || (rdata !== expected_data) ||
                (rresp !== expected_resp) || (rlast !== expected_last))
                $fatal(1,
                    "R mismatch id=%0d/%0d data=%032x/%032x resp=%b/%b last=%b/%b",
                    rid, expected_id, rdata, expected_data,
                    rresp, expected_resp, rlast, expected_last);

            held_data = rdata;
            for (stall = 0; stall < stall_cycles; stall = stall + 1) begin
                tick();
                if (!rvalid || (rid !== expected_id) ||
                    (rdata !== held_data) || (rresp !== expected_resp) ||
                    (rlast !== expected_last))
                    $fatal(1, "R payload changed under backpressure");
            end

            rready = 1'b1;
            tick();
            rready = 1'b0;
        end
    endtask

    task automatic issue_ddr3_request(
        input [ADDR_WIDTH-1:0] address,
        input [15:0] byte_count,
        output integer latency
    );
        integer guard;
        begin
            ddr3_cmd_addr = address;
            ddr3_cmd_bytes = byte_count;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_valid = 1'b1;
            guard = 0;
            while (!ddr3_cmd_ready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 command timeout");
            tick();
            ddr3_cmd_valid = 1'b0;

            latency = 0;
            while (!ddr3_resp_valid && latency < 500) begin
                tick();
                latency = latency + 1;
            end
            if (!ddr3_resp_valid)
                $fatal(1, "DDR3 response timeout");
            ddr3_resp_ready = 1'b1;
            tick();
            ddr3_resp_ready = 1'b0;
        end
    endtask

    task automatic issue_gddr_request(
        input [ADDR_WIDTH-1:0] address,
        input [15:0] byte_count,
        output integer latency
    );
        integer guard;
        begin
            gddr_cmd_addr = address;
            gddr_cmd_bytes = byte_count;
            gddr_cmd_write = 1'b0;
            gddr_cmd_valid = 1'b1;
            guard = 0;
            while (!gddr_cmd_ready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!gddr_cmd_ready)
                $fatal(1, "GDDR6 command timeout");
            tick();
            gddr_cmd_valid = 1'b0;

            latency = 0;
            while (!gddr_resp_valid && latency < 500) begin
                tick();
                latency = latency + 1;
            end
            if (!gddr_resp_valid)
                $fatal(1, "GDDR6 response timeout");
            gddr_resp_ready = 1'b1;
            tick();
            gddr_resp_ready = 1'b0;
        end
    endtask

    task automatic issue_hbm_request(
        input [ADDR_WIDTH-1:0] address,
        output integer latency
    );
        integer guard;
        begin
            hbm_cmd_addr = address;
            hbm_cmd_bytes = 8'd32;
            hbm_cmd_write = 1'b1;
            hbm_cmd_valid = 1'b1;
            guard = 0;
            while (!hbm_cmd_ready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!hbm_cmd_ready)
                $fatal(1, "HBM2 command timeout");
            tick();
            hbm_cmd_valid = 1'b0;
            latency = 0;
            while (!hbm_resp_valid && latency < 500) begin
                tick();
                latency = latency + 1;
            end
            if (!hbm_resp_valid)
                $fatal(1, "HBM2 response timeout");
            hbm_resp_ready = 1'b1;
            tick();
            hbm_resp_ready = 1'b0;
        end
    endtask

    integer ddr3_miss_latency;
    integer ddr3_hit_latency;
    integer ddr3_conflict_latency;
    integer ddr3_two_burst_latency;
    integer gddr_miss_latency;
    integer gddr_hit_latency;
    integer gddr_two_burst_latency;
    integer hbm_write_miss_latency;
    integer hbm_write_conflict_latency;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        arid = 0;
        araddr = 0;
        arlen = 0;
        arsize = 3'd4;
        arburst = 2'b01;
        arlock = 1'b0;
        arvalid = 1'b0;
        rready = 1'b0;
        awid = 0;
        awaddr = 0;
        awlen = 0;
        awsize = 3'd4;
        awburst = 2'b01;
        awlock = 1'b0;
        awvalid = 1'b0;
        wdata = 0;
        wstrb = 0;
        wlast = 1'b0;
        wvalid = 1'b0;
        bready = 1'b0;
        ddr3_cmd_valid = 1'b0;
        ddr3_cmd_write = 1'b0;
        ddr3_cmd_addr = 0;
        ddr3_cmd_bytes = 0;
        ddr3_resp_ready = 1'b0;
        gddr_cmd_valid = 1'b0;
        gddr_cmd_write = 1'b0;
        gddr_cmd_addr = 0;
        gddr_cmd_bytes = 0;
        gddr_resp_ready = 1'b0;
        hbm_cmd_valid = 1'b0;
        hbm_cmd_write = 1'b0;
        hbm_cmd_addr = 0;
        hbm_cmd_bytes = 0;
        hbm_resp_ready = 1'b0;

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // AW is accepted independently.  W begins only after the descriptor
        // reaches the active write slot, then proceeds as a four-beat burst.
        send_aw(4'h9, 32'h0000_8000, 8'd3, 3'd4, 2'b01, 1'b0);
        send_w(128'h0011_2233_4455_6677_8899_aabb_ccdd_eeff,
               16'hffff, 1'b0);
        send_w(128'hffff_ffff_ffff_ffff_0123_4567_89ab_cdef,
               16'h00ff, 1'b0);
        send_w(128'h1020_3040_5060_7080_90a0_b0c0_d0e0_f000,
               16'hffff, 1'b0);
        send_w(128'hdead_beef_cafe_f00d_0bad_f00d_1234_5678,
               16'hffff, 1'b1);
        expect_b(4'h9, 2'b00);

        // Two AR descriptors queue while the first burst is still active.
        send_ar(4'h3, 32'h0000_8000, 8'd1, 3'd4, 2'b01, 1'b0);
        send_ar(4'h5, 32'h0000_8020, 8'd1, 3'd4, 2'b01, 1'b0);
        expect_r(4'h3,
            128'h0011_2233_4455_6677_8899_aabb_ccdd_eeff,
            2'b00, 1'b0, 3);
        expect_r(4'h3,
            128'h0000_0000_0000_0000_0123_4567_89ab_cdef,
            2'b00, 1'b1, 0);
        expect_r(4'h5,
            128'h1020_3040_5060_7080_90a0_b0c0_d0e0_f000,
            2'b00, 1'b0, 0);
        expect_r(4'h5,
            128'hdead_beef_cafe_f00d_0bad_f00d_1234_5678,
            2'b00, 1'b1, 0);

        // A burst crossing the aperture and 4 KiB boundary returns DECERR on
        // every requested beat while preserving ID and RLAST.
        send_ar(4'ha, 32'h0000_8ff0, 8'd1, 3'd4, 2'b01, 1'b0);
        expect_r(4'ha, 128'd0, 2'b11, 1'b0, 0);
        expect_r(4'ha, 128'd0, 2'b11, 1'b1, 0);

        // Early WLAST is a write-channel protocol failure, not a silent
        // truncated OKAY burst.
        send_aw(4'hc, 32'h0000_8080, 8'd1, 3'd4, 2'b01, 1'b0);
        send_w(128'h55, 16'hffff, 1'b1);
        expect_b(4'hc, 2'b10);

        // DDR3-1600 x64, BL8: 64-byte native burst.  At a 1 ns controller
        // clock, a closed-row read is ceil((tRCD + tCL + BL/2) * 1.25 ns)
        // = 33 ns after dispatch; command acceptance adds one controller
        // cycle, so observed response latencies are 34 ns, 20 ns, and 48 ns.
        // The third access selects another row in the same bank and pays tRP.
        issue_ddr3_request(32'h0000_1000, 8'd64, ddr3_miss_latency);
        issue_ddr3_request(32'h0000_1040, 8'd64, ddr3_hit_latency);
        issue_ddr3_request(32'h0001_1000, 8'd64, ddr3_conflict_latency);
        if ((ddr3_miss_latency != 34) ||
            (ddr3_hit_latency != 20) ||
            (ddr3_conflict_latency != 48))
            $fatal(1,
                "DDR3 latency mismatch: miss=%0d hit=%0d conflict=%0d",
                ddr3_miss_latency, ddr3_hit_latency,
                ddr3_conflict_latency);
        issue_ddr3_request(32'h0001_1040, 16'd128,
                           ddr3_two_burst_latency);
        // A 128-byte row hit consumes two BL8 transfers separated by the
        // shared-bus scheduler handoff; it cannot collapse to one delay.
        if (ddr3_two_burst_latency != 26)
            $fatal(1,
                "DDR3 native-burst scheduling mismatch: got=%0d expected=26",
                ddr3_two_burst_latency);

        // GDDR6 x16, BL16: 32-byte native burst.  At a 1 ns controller
        // clock, these are exact ceil() conversions from the 0.66 ns DRAM
        // clock: closed-row read 33 ns, row-hit read 18 ns, and a 64-byte
        // row-hit read 20 ns after the extra tCCD.
        issue_gddr_request(32'h0000_1000, 8'd32,
                           gddr_miss_latency);
        issue_gddr_request(32'h0000_1020, 8'd32,
                           gddr_hit_latency);
        issue_gddr_request(32'h0000_1040, 8'd64,
                           gddr_two_burst_latency);
        if ((gddr_miss_latency != 33) ||
            (gddr_hit_latency != 18) ||
            (gddr_two_burst_latency != 20))
            $fatal(1,
                "GDDR6 latency mismatch: miss=%0d hit=%0d two-burst=%0d",
                gddr_miss_latency, gddr_hit_latency,
                gddr_two_burst_latency);

        // HBM2 pseudo-channel x64, BL4: a closed-row 32-byte write is
        // tRCDWR(14) + tCWL(4) + two burst clocks = 20 ns.
        issue_hbm_request(32'h0000_4000, hbm_write_miss_latency);
        if (hbm_write_miss_latency != 20)
            $fatal(1, "HBM2 write latency mismatch: got=%0d expected=20",
                   hbm_write_miss_latency);
        issue_hbm_request(32'h0000_8000, hbm_write_conflict_latency);
        if (hbm_write_conflict_latency <= hbm_write_miss_latency)
            $fatal(1,
                "HBM2 write recovery/row conflict was not charged: miss=%0d conflict=%0d",
                hbm_write_miss_latency, hbm_write_conflict_latency);

        $display("tb_mem_channel: PASS ddr3_ns=%0d/%0d/%0d/%0d gddr6_ns=%0d/%0d/%0d hbm2_ns=%0d/%0d",
            ddr3_miss_latency, ddr3_hit_latency, ddr3_conflict_latency,
            ddr3_two_burst_latency,
            gddr_miss_latency, gddr_hit_latency,
            gddr_two_burst_latency, hbm_write_miss_latency,
            hbm_write_conflict_latency);
        $finish;
    end

endmodule
