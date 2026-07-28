`timescale 1ns/1ps

module tb_mem_channel;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 128;
    localparam integer ID_WIDTH = 4;
    localparam integer TIMING_TAG_WIDTH = 8;
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
    wire [TIMING_TAG_WIDTH-1:0] timing_cmd_tag;
    wire timing_resp_valid;
    wire [TIMING_TAG_WIDTH-1:0] timing_resp_tag;
    wire timing_resp_ready;
    logic timing_cmd_allow;
    wire timing_backend_cmd_ready;
    wire timing_backend_resp_valid;
    wire [TIMING_TAG_WIDTH-1:0] timing_backend_resp_tag;
    logic manual_timing_mode;
    logic manual_timing_cmd_ready;
    logic manual_timing_resp_valid;
    logic [TIMING_TAG_WIDTH-1:0] manual_timing_resp_tag;

    logic ddr3_cmd_valid;
    logic ddr3_cmd_write;
    logic [ADDR_WIDTH-1:0] ddr3_cmd_addr;
    logic [15:0] ddr3_cmd_bytes;
    logic [TIMING_TAG_WIDTH-1:0] ddr3_cmd_tag;
    wire ddr3_cmd_ready;
    wire ddr3_resp_valid;
    wire [TIMING_TAG_WIDTH-1:0] ddr3_resp_tag;
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

    logic magic_cmd_valid;
    logic magic_cmd_write;
    logic [ADDR_WIDTH-1:0] magic_cmd_addr;
    logic [15:0] magic_cmd_bytes;
    wire magic_cmd_ready;
    wire magic_resp_valid;
    logic magic_resp_ready;

    openrv64_mem_channel #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(4),
        .TIMING_TAG_WIDTH(TIMING_TAG_WIDTH)
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
        .timing_cmd_tag_o(timing_cmd_tag),
        .timing_resp_valid_i(timing_resp_valid),
        .timing_resp_tag_i(timing_resp_tag),
        .timing_resp_ready_o(timing_resp_ready)
    );

    openrv64_timing_ddr4 #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .TAG_WIDTH(TIMING_TAG_WIDTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_ddr4 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(timing_cmd_valid && timing_cmd_allow &&
                     !manual_timing_mode),
        .cmd_ready_o(timing_backend_cmd_ready),
        .cmd_write_i(timing_cmd_write),
        .cmd_addr_i(timing_cmd_addr),
        .cmd_bytes_i(timing_cmd_bytes),
        .cmd_tag_i(timing_cmd_tag),
        .resp_valid_o(timing_backend_resp_valid),
        .resp_tag_o(timing_backend_resp_tag),
        .resp_ready_i(timing_resp_ready)
    );
    assign timing_cmd_ready = manual_timing_mode ?
        manual_timing_cmd_ready :
        (timing_cmd_allow && timing_backend_cmd_ready);
    assign timing_resp_valid = manual_timing_mode ?
        manual_timing_resp_valid : timing_backend_resp_valid;
    assign timing_resp_tag = manual_timing_mode ?
        manual_timing_resp_tag : timing_backend_resp_tag;

    // Standalone instances prove that the alternative profiles implement the
    // exact same timing contract used above.
    openrv64_timing_ddr3 #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(TIMING_TAG_WIDTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_ddr3 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(ddr3_cmd_valid), .cmd_ready_o(ddr3_cmd_ready),
        .cmd_write_i(ddr3_cmd_write), .cmd_addr_i(ddr3_cmd_addr),
        .cmd_bytes_i(ddr3_cmd_bytes), .cmd_tag_i(ddr3_cmd_tag),
        .resp_valid_o(ddr3_resp_valid), .resp_tag_o(ddr3_resp_tag),
        .resp_ready_i(ddr3_resp_ready)
    );

    openrv64_timing_gddr6 #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(TIMING_TAG_WIDTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_gddr6 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(gddr_cmd_valid), .cmd_ready_o(gddr_cmd_ready),
        .cmd_write_i(gddr_cmd_write), .cmd_addr_i(gddr_cmd_addr),
        .cmd_bytes_i(gddr_cmd_bytes), .cmd_tag_i(8'd0),
        .resp_valid_o(gddr_resp_valid), .resp_tag_o(),
        .resp_ready_i(gddr_resp_ready)
    );

    openrv64_timing_hbm2 #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(TIMING_TAG_WIDTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(0)
    ) u_hbm2 (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(hbm_cmd_valid), .cmd_ready_o(hbm_cmd_ready),
        .cmd_write_i(hbm_cmd_write), .cmd_addr_i(hbm_cmd_addr),
        .cmd_bytes_i(hbm_cmd_bytes), .cmd_tag_i(8'd0),
        .resp_valid_o(hbm_resp_valid), .resp_tag_o(),
        .resp_ready_i(hbm_resp_ready)
    );

    openrv64_timing_magic #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(TIMING_TAG_WIDTH)
    ) u_magic (
        .clk_i(clk), .rst_ni(rst_n),
        .cmd_valid_i(magic_cmd_valid), .cmd_ready_o(magic_cmd_ready),
        .cmd_write_i(magic_cmd_write), .cmd_addr_i(magic_cmd_addr),
        .cmd_bytes_i(magic_cmd_bytes), .cmd_tag_i(8'd0),
        .resp_valid_o(magic_resp_valid), .resp_tag_o(),
        .resp_ready_i(magic_resp_ready)
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
            ddr3_cmd_tag = 8'h01;
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

    task automatic issue_ddr3_coalesced_pair(
        output integer elapsed_cycles
    );
        integer guard;
        integer responses;
        reg [63:0] coalesced_before;
        begin
            coalesced_before =
                u_ddr3.u_timing.perf_commands_coalesced_q;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_bytes = 16'd64;
            ddr3_cmd_tag = 8'h41;
            ddr3_cmd_addr = 32'h0000_4000;
            ddr3_cmd_valid = 1'b1;
            guard = 0;
            while (!ddr3_cmd_ready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 first coalescing command timeout");
            tick();

            ddr3_cmd_addr = 32'h0000_4040;
            ddr3_cmd_tag = 8'h42;
            guard = 0;
            while (!ddr3_cmd_ready && guard < 500) begin
                tick();
                guard = guard + 1;
            end
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 second coalescing command timeout");
            tick();
            ddr3_cmd_valid = 1'b0;

            ddr3_resp_ready = 1'b1;
            responses = 0;
            elapsed_cycles = 0;
            while ((responses < 2) && (elapsed_cycles < 500)) begin
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                elapsed_cycles = elapsed_cycles + 1;
            end
            ddr3_resp_ready = 1'b0;
            if (responses != 2)
                $fatal(1, "DDR3 coalesced response pair timeout");
            if ((u_ddr3.u_timing.perf_commands_coalesced_q -
                 coalesced_before) != 1)
                $fatal(1,
                    "DDR3 controller did not coalesce adjacent commands");
        end
    endtask

    task automatic issue_ddr3_ordering_barrier;
        integer responses;
        integer elapsed_cycles;
        reg [63:0] coalesced_before;
        begin
            coalesced_before =
                u_ddr3.u_timing.perf_commands_coalesced_q;
            ddr3_cmd_bytes = 16'd64;
            ddr3_cmd_valid = 1'b1;

            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0000_6000;
            ddr3_cmd_tag = 8'h51;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 ordering command 0 not ready");
            tick();

            ddr3_cmd_write = 1'b1;
            ddr3_cmd_addr = 32'h0000_6040;
            ddr3_cmd_tag = 8'h52;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 ordering command 1 not ready");
            tick();

            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0000_6040;
            ddr3_cmd_tag = 8'h53;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 ordering command 2 not ready");
            tick();
            ddr3_cmd_valid = 1'b0;

            ddr3_resp_ready = 1'b1;
            responses = 0;
            elapsed_cycles = 0;
            while ((responses < 3) && (elapsed_cycles < 500)) begin
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                elapsed_cycles = elapsed_cycles + 1;
            end
            ddr3_resp_ready = 1'b0;
            if (responses != 3)
                $fatal(1, "DDR3 ordering response timeout");
            if (u_ddr3.u_timing.perf_commands_coalesced_q !=
                coalesced_before)
                $fatal(1,
                    "DDR3 coalesced across an older same-bank command");
        end
    endtask

    task automatic issue_ddr3_read_gather;
        integer responses;
        integer elapsed_cycles;
        reg [63:0] coalesced_before;
        reg [7:0] response_tags [0:3];
        begin
            coalesced_before =
                u_ddr3.u_timing.perf_commands_coalesced_q;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_bytes = 16'd64;
            ddr3_cmd_valid = 1'b1;

            ddr3_cmd_addr = 32'h0000_8000;
            ddr3_cmd_tag = 8'h61;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 read gather command 0 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_8800;
            ddr3_cmd_tag = 8'h62;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 read gather command 1 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_8040;
            ddr3_cmd_tag = 8'h63;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 read gather command 2 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_8080;
            ddr3_cmd_tag = 8'h64;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 read gather command 3 not ready");
            tick();
            ddr3_cmd_valid = 1'b0;

            ddr3_resp_ready = 1'b1;
            responses = 0;
            elapsed_cycles = 0;
            while ((responses < 4) && (elapsed_cycles < 500)) begin
                if (ddr3_resp_valid) begin
                    response_tags[responses] = ddr3_resp_tag;
                    responses = responses + 1;
                end
                tick();
                elapsed_cycles = elapsed_cycles + 1;
            end
            ddr3_resp_ready = 1'b0;
            if (responses != 4)
                $fatal(1, "DDR3 read gather response timeout");
            if ((response_tags[0] != 8'h61) ||
                (response_tags[1] != 8'h63) ||
                (response_tags[2] != 8'h64) ||
                (response_tags[3] != 8'h62))
                $fatal(1,
                    "DDR3 read gather tags were not out of order: %h/%h/%h/%h",
                    response_tags[0], response_tags[1],
                    response_tags[2], response_tags[3]);
            if ((u_ddr3.u_timing.perf_commands_coalesced_q -
                 coalesced_before) != 2)
                $fatal(1,
                    "DDR3 did not gather queued read run across unrelated read");
        end
    endtask

    task automatic issue_ddr3_write_gather;
        integer responses;
        integer elapsed_cycles;
        reg [63:0] coalesced_before;
        reg [7:0] response_tags [0:3];
        begin
            coalesced_before =
                u_ddr3.u_timing.perf_commands_coalesced_q;
            ddr3_cmd_write = 1'b1;
            ddr3_cmd_bytes = 16'd64;
            ddr3_cmd_valid = 1'b1;

            ddr3_cmd_addr = 32'h0000_a000;
            ddr3_cmd_tag = 8'h71;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 write gather command 0 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_a800;
            ddr3_cmd_tag = 8'h72;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 write gather command 1 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_a040;
            ddr3_cmd_tag = 8'h73;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 write gather command 2 not ready");
            tick();
            ddr3_cmd_addr = 32'h0000_a080;
            ddr3_cmd_tag = 8'h74;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 write gather command 3 not ready");
            tick();
            ddr3_cmd_valid = 1'b0;

            ddr3_resp_ready = 1'b1;
            responses = 0;
            elapsed_cycles = 0;
            while ((responses < 4) && (elapsed_cycles < 500)) begin
                if (ddr3_resp_valid) begin
                    response_tags[responses] = ddr3_resp_tag;
                    responses = responses + 1;
                end
                tick();
                elapsed_cycles = elapsed_cycles + 1;
            end
            ddr3_resp_ready = 1'b0;
            if (responses != 4)
                $fatal(1, "DDR3 write gather response timeout");
            if ((response_tags[0] != 8'h71) ||
                (response_tags[1] != 8'h73) ||
                (response_tags[2] != 8'h74) ||
                (response_tags[3] != 8'h72))
                $fatal(1,
                    "DDR3 write gather tags were not out of order: %h/%h/%h/%h",
                    response_tags[0], response_tags[1],
                    response_tags[2], response_tags[3]);
            if ((u_ddr3.u_timing.perf_commands_coalesced_q -
                 coalesced_before) != 2)
                $fatal(1,
                    "DDR3 did not gather queued write run across unrelated write");
        end
    endtask

    task automatic issue_ddr3_gem5_timing_checks;
        integer guard;
        integer launches;
        integer responses;
        integer index;
        integer row_limit_hit_latency;
        integer row_limit_reopen_latency;
        integer row_limit_latency;
        reg [63:0] launch_cycle [0:4];
        reg launch_write [0:4];
        reg [63:0] adaptive_conflicts_before;
        reg [63:0] adaptive_empty_before;
        begin
            // Same-rank read-to-write.  With equal CL/CWL, gem5's
            // tBURST+tRTW command gap is also the data-start gap: 8 ns after
            // controller-clock ceiling.
            ddr3_cmd_valid = 1'b1;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0000_4000;
            ddr3_cmd_bytes = 16'd64;
            ddr3_cmd_tag = 8'h81;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 R->W timing read was not accepted");
            tick();
            ddr3_cmd_write = 1'b1;
            ddr3_cmd_addr = 32'h0000_6000;
            ddr3_cmd_tag = 8'h82;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 R->W timing write was not accepted");
            tick();
            ddr3_cmd_valid = 1'b0;
            ddr3_resp_ready = 1'b1;
            guard = 0;
            launches = 0;
            responses = 0;
            while ((responses < 2) && (guard < 500)) begin
                if (u_ddr3.u_timing.bus_launch) begin
                    launch_cycle[launches] =
                        u_ddr3.u_timing.controller_cycle_q;
                    launch_write[launches] =
                        u_ddr3.u_timing.bank_group_write_q[
                            u_ddr3.u_timing.bus_select_bank];
                    launches = launches + 1;
                end
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                guard = guard + 1;
            end
            if ((launches != 2) || launch_write[0] ||
                !launch_write[1] ||
                ((launch_cycle[1] - launch_cycle[0]) < 8))
                $fatal(1,
                    "DDR3 gem5 R->W constraint failed launches=%0d dirs=%0d/%0d gap=%0d",
                    launches, launch_write[0], launch_write[1],
                    launch_cycle[1] - launch_cycle[0]);

            // Same-rank write-to-read includes tBURST+tWTR+tWL at command
            // level and the target read CL at data level: 27 ns here.
            ddr3_cmd_valid = 1'b1;
            ddr3_cmd_write = 1'b1;
            ddr3_cmd_addr = 32'h0000_8000;
            ddr3_cmd_tag = 8'h83;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 W->R timing write was not accepted");
            tick();
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0000_a000;
            ddr3_cmd_tag = 8'h84;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 W->R timing read was not accepted");
            tick();
            ddr3_cmd_valid = 1'b0;
            guard = 0;
            launches = 0;
            responses = 0;
            while ((responses < 2) && (guard < 500)) begin
                if (u_ddr3.u_timing.bus_launch) begin
                    launch_cycle[launches] =
                        u_ddr3.u_timing.controller_cycle_q;
                    launch_write[launches] =
                        u_ddr3.u_timing.bank_group_write_q[
                            u_ddr3.u_timing.bus_select_bank];
                    launches = launches + 1;
                end
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                guard = guard + 1;
            end
            if ((launches != 2) || !launch_write[0] ||
                launch_write[1] ||
                ((launch_cycle[1] - launch_cycle[0]) < 27))
                $fatal(1,
                    "DDR3 gem5 W->R constraint failed launches=%0d dirs=%0d/%0d gap=%0d",
                    launches, launch_write[0], launch_write[1],
                    launch_cycle[1] - launch_cycle[0]);

            // Same-direction rank switch is tBURST+tCS = 7.5 ns, rounded to
            // eight 1 ns controller cycles.  Bit 16 is the rank selector for
            // the DDR3 RoRaBaCo map.
            ddr3_cmd_valid = 1'b1;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0000_c000;
            ddr3_cmd_tag = 8'h85;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 rank-0 timing read was not accepted");
            tick();
            ddr3_cmd_addr = 32'h0001_c000;
            ddr3_cmd_tag = 8'h86;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 rank-1 timing read was not accepted");
            tick();
            ddr3_cmd_valid = 1'b0;
            guard = 0;
            launches = 0;
            responses = 0;
            while ((responses < 2) && (guard < 500)) begin
                if (u_ddr3.u_timing.bus_launch) begin
                    launch_cycle[launches] =
                        u_ddr3.u_timing.controller_cycle_q;
                    launches = launches + 1;
                end
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                guard = guard + 1;
            end
            if ((launches != 2) ||
                ((launch_cycle[1] - launch_cycle[0]) < 8))
                $fatal(1,
                    "DDR3 gem5 rank-switch constraint failed launches=%0d gap=%0d",
                    launches, launch_cycle[1] - launch_cycle[0]);

            // open_adaptive sees the queued second row, finds no remaining
            // hit to the first row, and auto-precharges the first access.
            // The second access therefore reopens an empty bank rather than
            // discovering a still-open conflicting row.
            adaptive_conflicts_before =
                u_ddr3.u_timing.perf_row_conflict_commands_q;
            adaptive_empty_before =
                u_ddr3.u_timing.perf_row_empty_commands_q;
            ddr3_cmd_valid = 1'b1;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_addr = 32'h0003_e000;
            ddr3_cmd_tag = 8'h87;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 adaptive row-0 read was not accepted");
            tick();
            ddr3_cmd_addr = 32'h0005_e000;
            ddr3_cmd_tag = 8'h88;
            if (!ddr3_cmd_ready)
                $fatal(1, "DDR3 adaptive row-1 read was not accepted");
            tick();
            ddr3_cmd_valid = 1'b0;
            guard = 0;
            responses = 0;
            while ((responses < 2) && (guard < 500)) begin
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                guard = guard + 1;
            end
            if (((u_ddr3.u_timing.perf_row_conflict_commands_q -
                  adaptive_conflicts_before) != 0) ||
                ((u_ddr3.u_timing.perf_row_empty_commands_q -
                  adaptive_empty_before) != 2))
                $fatal(1,
                    "DDR3 open-adaptive close failed conflicts=%0d empty=%0d",
                    u_ddr3.u_timing.perf_row_conflict_commands_q -
                        adaptive_conflicts_before,
                    u_ddr3.u_timing.perf_row_empty_commands_q -
                        adaptive_empty_before);

            // Five cold rows in distinct banks of one rank exercise tRRD=6
            // ns and the four-activate tXAW=30 ns window.
            ddr3_cmd_valid = 1'b1;
            ddr3_cmd_write = 1'b0;
            ddr3_cmd_bytes = 16'd64;
            for (index = 0; index < 5; index = index + 1) begin
                ddr3_cmd_addr = 32'h0004_0000 + (index * 32'h2000);
                ddr3_cmd_tag = 8'h90 + index;
                if (!ddr3_cmd_ready)
                    $fatal(1, "DDR3 activation timing read not accepted");
                tick();
            end
            ddr3_cmd_valid = 1'b0;
            guard = 0;
            launches = 0;
            responses = 0;
            while ((responses < 5) && (guard < 800)) begin
                if (u_ddr3.u_timing.bus_launch) begin
                    launch_cycle[launches] =
                        u_ddr3.u_timing.controller_cycle_q;
                    launches = launches + 1;
                end
                if (ddr3_resp_valid)
                    responses = responses + 1;
                tick();
                guard = guard + 1;
            end
            ddr3_resp_ready = 1'b0;
            if (launches != 5)
                $fatal(1,
                    "DDR3 activation timing launch count=%0d expected=5",
                    launches);
            for (index = 1; index < 4; index = index + 1)
                if ((launch_cycle[index] - launch_cycle[index-1]) < 6)
                    $fatal(1,
                        "DDR3 tRRD failed at %0d gap=%0d",
                        index, launch_cycle[index] -
                        launch_cycle[index-1]);
            if ((launch_cycle[4] - launch_cycle[0]) < 30)
                $fatal(1,
                    "DDR3 tXAW failed gap=%0d expected>=30",
                    launch_cycle[4] - launch_cycle[0]);

            // gem5's open-adaptive DDR3 preset caps one open-row episode at
            // 16 column accesses.  The seventeenth access must reopen the
            // row rather than being treated as an unlimited row hit.
            row_limit_hit_latency = 0;
            row_limit_reopen_latency = 0;
            for (index = 0; index < 17; index = index + 1) begin
                issue_ddr3_request(
                    32'h0009_e000 + (index * 32'h40),
                    16'd64, row_limit_latency);
                if (index == 15)
                    row_limit_hit_latency = row_limit_latency;
                if (index == 16)
                    row_limit_reopen_latency = row_limit_latency;
            end
            if (row_limit_reopen_latency <= row_limit_hit_latency)
                $fatal(1,
                    "DDR3 max-access row close failed hit=%0d reopen=%0d",
                    row_limit_hit_latency, row_limit_reopen_latency);
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

    task automatic issue_magic_request(
        output integer latency
    );
        begin
            magic_cmd_addr = 32'h0000_1000;
            magic_cmd_bytes = 16'd64;
            magic_cmd_write = 1'b0;
            magic_cmd_valid = 1'b1;
            if (!magic_cmd_ready)
                $fatal(1, "magic command was not immediately ready");
            tick();
            magic_cmd_valid = 1'b0;

            latency = 1;
            while (!magic_resp_valid && latency < 4) begin
                tick();
                latency = latency + 1;
            end
            if (!magic_resp_valid)
                $fatal(1, "magic response timeout");
            if (magic_cmd_ready)
                $fatal(1,
                    "magic backend accepted a command over a stalled response");
            magic_resp_ready = 1'b1;
            tick();
            magic_resp_ready = 1'b0;
        end
    endtask

    task automatic pulse_manual_timing_response(
        input [TIMING_TAG_WIDTH-1:0] response_tag
    );
        begin
            manual_timing_resp_tag = response_tag;
            manual_timing_resp_valid = 1'b1;
            if (!timing_resp_ready)
                $fatal(1, "manual timing response had no outstanding owner");
            tick();
            manual_timing_resp_valid = 1'b0;
        end
    endtask

    integer ddr3_miss_latency;
    integer ddr3_hit_latency;
    integer ddr3_conflict_latency;
    integer ddr3_two_burst_latency;
    integer ddr3_coalesced_pair_latency;
    integer gddr_miss_latency;
    integer gddr_hit_latency;
    integer gddr_two_burst_latency;
    integer hbm_write_miss_latency;
    integer hbm_write_conflict_latency;
    integer magic_latency;
    reg held_timing_write;
    reg [ADDR_WIDTH-1:0] held_timing_addr;
    reg [15:0] held_timing_bytes;
    reg [TIMING_TAG_WIDTH-1:0] held_timing_tag;
    reg [TIMING_TAG_WIDTH-1:0] manual_read_tag;
    reg [TIMING_TAG_WIDTH-1:0] manual_write_tag;
    reg [TIMING_TAG_WIDTH-1:0] manual_write_tag_older;
    reg [TIMING_TAG_WIDTH-1:0] manual_write_tag_younger;
    integer manual_guard;
    integer manual_slot;
    integer hold_check_cycle;

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
        timing_cmd_allow = 1'b1;
        manual_timing_mode = 1'b0;
        manual_timing_cmd_ready = 1'b0;
        manual_timing_resp_valid = 1'b0;
        manual_timing_resp_tag = 0;
        ddr3_cmd_valid = 1'b0;
        ddr3_cmd_write = 1'b0;
        ddr3_cmd_addr = 0;
        ddr3_cmd_bytes = 0;
        ddr3_cmd_tag = 0;
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
        magic_cmd_valid = 1'b0;
        magic_cmd_write = 1'b0;
        magic_cmd_addr = 0;
        magic_cmd_bytes = 0;
        magic_resp_ready = 1'b0;

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // First make read the preferred direction.  Then block the timing
        // backend with a read selected and make a write newly eligible.  The
        // selected timing payload must not change while VALID is stalled.
        send_ar(4'h0, 32'h0000_8200, 8'd0, 3'd4, 2'b01, 1'b0);
        expect_r(4'h0, 128'd0, 2'b00, 1'b1, 0);
        timing_cmd_allow = 1'b0;
        send_ar(4'h3, 32'h0000_8210, 8'd0, 3'd4, 2'b01, 1'b0);
        if (!timing_cmd_valid)
            $fatal(1, "timing command did not stall as requested");
        held_timing_write = timing_cmd_write;
        held_timing_addr = timing_cmd_addr;
        held_timing_bytes = timing_cmd_bytes;
        held_timing_tag = timing_cmd_tag;
        send_aw(4'h5, 32'h0000_8220, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'h5555_5555_5555_5555_5555_5555_5555_5555,
               16'hffff, 1'b1);
        for (hold_check_cycle = 0; hold_check_cycle < 3;
             hold_check_cycle = hold_check_cycle + 1) begin
            if (!timing_cmd_valid ||
                (timing_cmd_write !== held_timing_write) ||
                (timing_cmd_addr !== held_timing_addr) ||
                (timing_cmd_bytes !== held_timing_bytes) ||
                (timing_cmd_tag !== held_timing_tag))
                $fatal(1,
                    "timing command payload changed under backpressure");
            tick();
        end
        timing_cmd_allow = 1'b1;
        expect_r(4'h3, 128'd0, 2'b00, 1'b1, 0);
        expect_b(4'h5, 2'b00);

        // A read snapshots data when its tagged timing completion arrives,
        // not when AXI eventually drains it.  Complete an older read, then a
        // younger overlapping write, before accepting either AXI response.
        // The read must retain the old value while a later read sees the new
        // committed value.
        send_aw(4'h6, 32'h0000_8180, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'haaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa,
               16'hffff, 1'b1);
        expect_b(4'h6, 2'b00);

        manual_timing_mode = 1'b1;
        manual_timing_cmd_ready = 1'b0;
        send_ar(4'h7, 32'h0000_8180, 8'd0, 3'd4, 2'b01, 1'b0);
        send_aw(4'h8, 32'h0000_8180, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'hbbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb,
               16'hffff, 1'b1);

        manual_read_tag = 0;
        manual_write_tag = 0;
        manual_timing_cmd_ready = 1'b1;
        manual_guard = 0;
        while ((dut.timing_owner_count_q < 2) &&
               (manual_guard < 100)) begin
            tick();
            manual_guard = manual_guard + 1;
        end
        if (dut.timing_owner_count_q != 2)
            $fatal(1,
                "manual timing command timeout valid=%0d write=%0d owners=%0d",
                timing_cmd_valid, timing_cmd_write,
                dut.timing_owner_count_q);
        manual_timing_cmd_ready = 1'b0;
        for (manual_slot = 0; manual_slot < 4;
             manual_slot = manual_slot + 1) begin
            if (dut.read_valid_q[manual_slot] &&
                dut.read_timing_submitted_q[manual_slot])
                manual_read_tag = {1'b0, 5'd0, 2'(manual_slot)};
            if (dut.write_valid_q[manual_slot] &&
                dut.write_timing_submitted_q[manual_slot])
                manual_write_tag = {1'b1, 5'd0, 2'(manual_slot)};
        end
        if (manual_read_tag[TIMING_TAG_WIDTH-1] ||
            !manual_write_tag[TIMING_TAG_WIDTH-1])
            $fatal(1, "manual timing tags did not encode direction");

        pulse_manual_timing_response(manual_read_tag);
        pulse_manual_timing_response(manual_write_tag);
        expect_r(4'h7,
            128'haaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa,
            2'b00, 1'b1, 0);
        expect_b(4'h8, 2'b00);
        manual_timing_mode = 1'b0;
        send_ar(4'h9, 32'h0000_8180, 8'd0, 3'd4, 2'b01, 1'b0);
        expect_r(4'h9,
            128'hbbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb,
            2'b00, 1'b1, 0);

        // AXI writes with one ID are ordered.  The timing backend may finish
        // unrelated commands out of order, but reverse completion of two
        // overlapping writes must not let the older value overwrite the
        // younger value in backing storage.
        manual_timing_mode = 1'b1;
        manual_timing_cmd_ready = 1'b0;
        send_aw(4'ha, 32'h0000_81c0, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'haaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa_aaaa,
               16'hffff, 1'b1);
        send_aw(4'ha, 32'h0000_81c0, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'hbbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb,
               16'hffff, 1'b1);

        manual_slot = dut.write_head_q;
        manual_write_tag_older =
            {1'b1, 5'd0, 2'(manual_slot)};
        manual_slot = (manual_slot == 3) ? 0 : manual_slot + 1;
        manual_write_tag_younger =
            {1'b1, 5'd0, 2'(manual_slot)};

        manual_timing_cmd_ready = 1'b1;
        manual_guard = 0;
        while (!dut.write_timing_submitted_q[
                   manual_write_tag_older[1:0]] &&
               (manual_guard < 100)) begin
            tick();
            manual_guard = manual_guard + 1;
        end
        if (!dut.write_timing_submitted_q[
                manual_write_tag_older[1:0]])
            $fatal(1, "older overlapping write was not submitted");
        repeat (4) begin
            tick();
            if (dut.write_timing_submitted_q[
                    manual_write_tag_younger[1:0]])
                $fatal(1,
                    "younger overlapping write escaped before older completion");
        end

        pulse_manual_timing_response(manual_write_tag_older);
        manual_guard = 0;
        while (!dut.write_timing_submitted_q[
                   manual_write_tag_younger[1:0]] &&
               (manual_guard < 100)) begin
            tick();
            manual_guard = manual_guard + 1;
        end
        manual_timing_cmd_ready = 1'b0;
        if (!dut.write_timing_submitted_q[
                manual_write_tag_younger[1:0]])
            $fatal(1, "younger overlapping write did not unblock");
        pulse_manual_timing_response(manual_write_tag_younger);
        expect_b(4'ha, 2'b00);
        expect_b(4'ha, 2'b00);
        manual_timing_mode = 1'b0;
        send_ar(4'hb, 32'h0000_81c0, 8'd0, 3'd4, 2'b01, 1'b0);
        expect_r(4'hb,
            128'hbbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb_bbbb,
            2'b00, 1'b1, 0);

        // AW is accepted independently.  W follows the oldest AW descriptor,
        // and the complete four-beat burst is buffered before timing issue.
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

        // AW and W are separately ordered in AXI.  Buffer three complete
        // writes before accepting any B response, then prove that responses
        // and committed data retain AW order.
        send_aw(4'h1, 32'h0000_8100, 8'd0, 3'd4, 2'b01, 1'b0);
        send_aw(4'h2, 32'h0000_8120, 8'd0, 3'd4, 2'b01, 1'b0);
        send_aw(4'h4, 32'h0000_8140, 8'd0, 3'd4, 2'b01, 1'b0);
        send_w(128'h1111_1111_1111_1111_1111_1111_1111_1111,
               16'hffff, 1'b1);
        send_w(128'h2222_2222_2222_2222_2222_2222_2222_2222,
               16'hffff, 1'b1);
        send_w(128'h4444_4444_4444_4444_4444_4444_4444_4444,
               16'hffff, 1'b1);
        expect_b(4'h1, 2'b00);
        expect_b(4'h2, 2'b00);
        expect_b(4'h4, 2'b00);
        send_ar(4'h1, 32'h0000_8100, 8'd0, 3'd4, 2'b01, 1'b0);
        send_ar(4'h2, 32'h0000_8120, 8'd0, 3'd4, 2'b01, 1'b0);
        send_ar(4'h4, 32'h0000_8140, 8'd0, 3'd4, 2'b01, 1'b0);
        expect_r(4'h1,
            128'h1111_1111_1111_1111_1111_1111_1111_1111,
            2'b00, 1'b1, 0);
        expect_r(4'h2,
            128'h2222_2222_2222_2222_2222_2222_2222_2222,
            2'b00, 1'b1, 0);
        expect_r(4'h4,
            128'h4444_4444_4444_4444_4444_4444_4444_4444,
            2'b00, 1'b1, 0);

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

        issue_magic_request(magic_latency);
        if (magic_latency != 1)
            $fatal(1,
                "magic response latency was not one cycle: %0d",
                magic_latency);

        // DDR3-1600 x64, BL8: 64-byte native burst.  At a 1 ns controller
        // clock, a closed-row read is ceil((tRCD + tCL + BL/2) * 1.25 ns)
        // = 33 ns after dispatch; command acceptance adds one controller
        // cycle, and the DDR3 preset adds 10 ns frontend plus 10 ns backend
        // controller/PHY latency.  Observed response latencies are therefore
        // 54 ns, 40 ns, and 68 ns.
        // The third access selects another row in the same bank and pays tRP.
        issue_ddr3_request(32'h0000_1000, 8'd64, ddr3_miss_latency);
        issue_ddr3_request(32'h0000_1040, 8'd64, ddr3_hit_latency);
        issue_ddr3_request(32'h0002_1000, 8'd64, ddr3_conflict_latency);
        if ((ddr3_miss_latency != 54) ||
            (ddr3_hit_latency != 40) ||
            (ddr3_conflict_latency != 68))
            $fatal(1,
                "DDR3 latency mismatch: miss=%0d hit=%0d conflict=%0d",
                ddr3_miss_latency, ddr3_hit_latency,
                ddr3_conflict_latency);
        issue_ddr3_request(32'h0002_1040, 16'd128,
                           ddr3_two_burst_latency);
        // A 128-byte row hit consumes two BL8 transfers separated by the
        // shared-bus scheduler handoff; it cannot collapse to one delay.
        if (ddr3_two_burst_latency != 46)
            $fatal(1,
                "DDR3 native-burst scheduling mismatch: got=%0d expected=46",
                ddr3_two_burst_latency);
        issue_ddr3_coalesced_pair(ddr3_coalesced_pair_latency);
        issue_ddr3_ordering_barrier();
        issue_ddr3_read_gather();
        issue_ddr3_write_gather();
        issue_ddr3_gem5_timing_checks();

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

        if ((dut.perf_read_bursts_q == 0) ||
            (dut.perf_write_bursts_q == 0) ||
            (dut.perf_read_beats_requested_q !=
             dut.perf_read_beats_returned_q))
            $fatal(1,
                "memory-channel counters inconsistent: reads=%0d writes=%0d requested_rbeats=%0d returned_rbeats=%0d",
                dut.perf_read_bursts_q,
                dut.perf_write_bursts_q,
                dut.perf_read_beats_requested_q,
                dut.perf_read_beats_returned_q);
        $display(
            "tb_mem_channel_perf: reads=%0d writes=%0d rbeats=%0d/%0d wbeats=%0d/%0d waits=%0d/%0d/%0d timing=%0d/%0d/%0d",
            dut.perf_read_bursts_q,
            dut.perf_write_bursts_q,
            dut.perf_read_beats_requested_q,
            dut.perf_read_beats_returned_q,
            dut.perf_write_beats_requested_q,
            dut.perf_write_beats_received_q,
            dut.perf_read_address_wait_cycles_q,
            dut.perf_write_address_wait_cycles_q,
            dut.perf_write_data_wait_cycles_q,
            dut.perf_read_timing_wait_cycles_q,
            dut.perf_write_timing_wait_cycles_q,
            dut.perf_timing_backend_wait_cycles_q);
        $display("tb_mem_channel: PASS magic_cycles=%0d ddr3_ns=%0d/%0d/%0d/%0d coalesced_pair=%0d gddr6_ns=%0d/%0d/%0d hbm2_ns=%0d/%0d",
            magic_latency,
            ddr3_miss_latency, ddr3_hit_latency, ddr3_conflict_latency,
            ddr3_two_burst_latency, ddr3_coalesced_pair_latency,
            gddr_miss_latency, gddr_hit_latency,
            gddr_two_burst_latency, hbm_write_miss_latency,
            hbm_write_conflict_latency);
        $finish;
    end

endmodule
