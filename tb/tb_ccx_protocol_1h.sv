`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_ccx_protocol_1h;

    logic clk;
    logic rst_n;

    logic core_mem_valid;
    wire core_mem_ready;
    logic core_mem_write;
    logic [63:0] core_mem_addr;
    logic [63:0] core_mem_wdata;
    logic [7:0] core_mem_wstrb;
    wire [63:0] core_mem_rdata;
    wire core_mem_error;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    logic m_axi_arready;
    logic [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_rid;
    logic [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    wire m_axi_rready;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [2:0] m_axi_awprot;
    wire [3:0] m_axi_awqos;
    wire m_axi_awvalid;
    logic m_axi_awready;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    logic m_axi_wready;
    logic [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_bid;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    wire m_axi_bready;

    integer protocol_requests;
    integer cycles;

    openrv64_ccx_protocol_wrapper_1h #(
        .HART_ID(4'd5),
        .DEFAULT_ATTR(`OPENRV64_CCX_ATTR_CACHEABLE)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .core_mem_valid_i(core_mem_valid),
        .core_mem_ready_o(core_mem_ready),
        .core_mem_write_i(core_mem_write),
        .core_mem_addr_i(core_mem_addr),
        .core_mem_wdata_i(core_mem_wdata),
        .core_mem_wstrb_i(core_mem_wstrb),
        .core_mem_rdata_o(core_mem_rdata),
        .core_mem_error_o(core_mem_error),
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
        .m_axi_bready_o(m_axi_bready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (rst_n && dut.ccx_req_valid && dut.ccx_req_ready) begin
            if (dut.ccx_req_hart_id !== 4'd5)
                $fatal(1, "CCX request lost hart identity");
            if (dut.ccx_req_txn_id !== protocol_requests[3:0])
                $fatal(1, "CCX transaction ID mismatch got=%0d expected=%0d",
                       dut.ccx_req_txn_id, protocol_requests);
            if (dut.ccx_req_order !== `OPENRV64_CCX_ORDER_NONE ||
                dut.ccx_req_kind !== `OPENRV64_CCX_KIND_LEGACY ||
                dut.ccx_req_attr !== `OPENRV64_CCX_ATTR_CACHEABLE ||
                dut.ccx_req_size !== 3'd3)
                $fatal(1, "CCX compatibility metadata mismatch");
            if (dut.ccx_req_op !==
                (core_mem_write ? `OPENRV64_CCX_OP_WRITE :
                                  `OPENRV64_CCX_OP_READ))
                $fatal(1, "CCX operation mismatch");
            protocol_requests <= protocol_requests + 1;
        end
    end

    task automatic begin_core_request;
        input logic write;
        input logic [63:0] address;
        input logic [63:0] write_data;
        input logic [7:0] write_strobes;
        begin
            @(negedge clk);
            core_mem_valid = 1'b1;
            core_mem_write = write;
            core_mem_addr = address;
            core_mem_wdata = write_data;
            core_mem_wstrb = write_strobes;
        end
    endtask

    task automatic finish_core_request;
        input logic [63:0] expected_data;
        input logic expected_error;
        input [8*48-1:0] label;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!core_mem_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!core_mem_ready)
                $fatal(1, "%0s timed out waiting for core completion", label);
            if (core_mem_rdata !== expected_data ||
                core_mem_error !== expected_error)
                $fatal(1,
                       "%0s completion mismatch data=%016x/%016x error=%b/%b",
                       label, core_mem_rdata, expected_data,
                       core_mem_error, expected_error);
            @(negedge clk);
            core_mem_valid = 1'b0;
            core_mem_write = 1'b0;
            core_mem_addr = 64'd0;
            core_mem_wdata = 64'd0;
            core_mem_wstrb = 8'd0;
        end
    endtask

    task automatic complete_read;
        input logic [63:0] address;
        input logic [63:0] read_data;
        input logic [1:0] response;
        input logic inject_wrong_id;
        integer lane;
        logic [`OPENRV64_AXI_DATA_WIDTH-1:0] lane_data;
        logic [`OPENRV64_AXI_ADDR_WIDTH-1:0] held_addr;
        begin
            cycles = 0;
            while (!m_axi_arvalid && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!m_axi_arvalid)
                $fatal(1, "read address was not issued");
            held_addr = m_axi_araddr;
            if (m_axi_arid !== {`OPENRV64_AXI_ID_WIDTH{1'b1}} ||
                m_axi_araddr !== {address[63:3], 3'b000} ||
                m_axi_arlen !== 0 || m_axi_arsize !== 3 ||
                m_axi_arburst !== 2'b01 || m_axi_arlock !== 0 ||
                m_axi_arcache !== 4'b0011)
                $fatal(1, "read AXI attributes/address mismatch");

            // Backpressure must not change the exported request.
            repeat (2) begin
                @(negedge clk);
                if (!m_axi_arvalid || m_axi_araddr !== held_addr)
                    $fatal(1, "read address changed under backpressure");
            end
            m_axi_arready = 1'b1;
            @(negedge clk);
            m_axi_arready = 1'b0;

            lane = address[4:3];
            lane_data = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            lane_data[lane*64 +: 64] = read_data;
            m_axi_rdata = lane_data;
            m_axi_rresp = response;
            m_axi_rlast = 1'b1;

            if (inject_wrong_id) begin
                m_axi_rid = {`OPENRV64_AXI_ID_WIDTH{1'b1}} - 1'b1;
                m_axi_rvalid = 1'b1;
                @(negedge clk);
                if (m_axi_rready)
                    $fatal(1, "wrong AXI read ID was accepted");
                m_axi_rvalid = 1'b0;
            end

            m_axi_rid = {`OPENRV64_AXI_ID_WIDTH{1'b1}};
            m_axi_rvalid = 1'b1;
            #1;
            cycles = 0;
            while (!m_axi_rready && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!m_axi_rready)
                $fatal(1, "read data was not accepted");
            @(negedge clk);
            m_axi_rvalid = 1'b0;
            m_axi_rdata = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            m_axi_rresp = 2'b00;
        end
    endtask

    task automatic complete_write;
        input logic [63:0] address;
        input logic [63:0] write_data;
        input logic [7:0] write_strobes;
        input logic [1:0] response;
        input logic inject_wrong_id;
        integer lane;
        logic [`OPENRV64_AXI_DATA_WIDTH-1:0] expected_wdata;
        logic [`OPENRV64_AXI_STRB_WIDTH-1:0] expected_wstrb;
        begin
            cycles = 0;
            while ((!m_axi_awvalid || !m_axi_wvalid) && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!m_axi_awvalid || !m_axi_wvalid)
                $fatal(1, "write address/data were not issued");

            lane = address[4:3];
            expected_wdata = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            expected_wstrb = {`OPENRV64_AXI_STRB_WIDTH{1'b0}};
            expected_wdata[lane*64 +: 64] = write_data;
            expected_wstrb[lane*8 +: 8] = write_strobes;
            if (m_axi_awid !== {`OPENRV64_AXI_ID_WIDTH{1'b1}} ||
                m_axi_awaddr !== {address[63:3], 3'b000} ||
                m_axi_awlen !== 0 || m_axi_awsize !== 3 ||
                m_axi_awburst !== 2'b01 || m_axi_awlock !== 0 ||
                m_axi_awcache !== 4'b0011 ||
                m_axi_wdata !== expected_wdata ||
                m_axi_wstrb !== expected_wstrb || !m_axi_wlast)
                $fatal(1, "write AXI attributes/lane steering mismatch");

            // Accept W before AW to prove the channels are independent.
            m_axi_wready = 1'b1;
            @(negedge clk);
            m_axi_wready = 1'b0;
            repeat (2) begin
                @(negedge clk);
                if (!m_axi_awvalid || m_axi_wvalid)
                    $fatal(1, "write channel completion tracking failed");
            end
            m_axi_awready = 1'b1;
            @(negedge clk);
            m_axi_awready = 1'b0;

            m_axi_bresp = response;
            if (inject_wrong_id) begin
                m_axi_bid = {`OPENRV64_AXI_ID_WIDTH{1'b1}} - 1'b1;
                m_axi_bvalid = 1'b1;
                @(negedge clk);
                if (m_axi_bready)
                    $fatal(1, "wrong AXI write ID was accepted");
                m_axi_bvalid = 1'b0;
            end
            m_axi_bid = {`OPENRV64_AXI_ID_WIDTH{1'b1}};
            m_axi_bvalid = 1'b1;
            #1;
            cycles = 0;
            while (!m_axi_bready && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!m_axi_bready)
                $fatal(1, "write response was not accepted");
            @(negedge clk);
            m_axi_bvalid = 1'b0;
            m_axi_bresp = 2'b00;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        core_mem_valid = 1'b0;
        core_mem_write = 1'b0;
        core_mem_addr = 64'd0;
        core_mem_wdata = 64'd0;
        core_mem_wstrb = 8'd0;
        m_axi_arready = 1'b0;
        m_axi_rid = 0;
        m_axi_rdata = 0;
        m_axi_rresp = 0;
        m_axi_rlast = 1'b1;
        m_axi_rvalid = 1'b0;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bid = 0;
        m_axi_bresp = 0;
        m_axi_bvalid = 1'b0;
        protocol_requests = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        begin_core_request(1'b0, 64'h0000_0000_8000_0010,
                           64'd0, 8'd0);
        complete_read(64'h0000_0000_8000_0010,
                      64'h1122_3344_5566_7788, 2'b00, 1'b1);
        finish_core_request(64'h1122_3344_5566_7788, 1'b0,
                            "successful lane-two read");

        begin_core_request(1'b1, 64'h0000_0000_8000_0018,
                           64'h0123_4567_89ab_cdef, 8'h0f);
        complete_write(64'h0000_0000_8000_0018,
                       64'h0123_4567_89ab_cdef, 8'h0f, 2'b00, 1'b1);
        finish_core_request(64'd0, 1'b0,
                            "successful split-channel write");

        begin_core_request(1'b0, 64'h0000_0000_1000_0008,
                           64'd0, 8'd0);
        complete_read(64'h0000_0000_1000_0008,
                      64'hfeed_face_cafe_f00d, 2'b10, 1'b0);
        finish_core_request(64'hfeed_face_cafe_f00d, 1'b1,
                            "read error propagation");

        begin_core_request(1'b1, 64'h0000_0000_1000_0010,
                           64'hffff_eeee_dddd_cccc, 8'hff);
        complete_write(64'h0000_0000_1000_0010,
                       64'hffff_eeee_dddd_cccc, 8'hff, 2'b11, 1'b0);
        finish_core_request(64'd0, 1'b1,
                            "write error propagation");

        repeat (3) @(posedge clk);
        if (protocol_requests != 4)
            $fatal(1, "expected four protocol requests, observed %0d",
                   protocol_requests);
        $display("PASS: one-hart CCX protocol identity, ordering, AXI lane steering, backpressure, and errors");
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "one-hart CCX protocol test timeout");
    end

endmodule
