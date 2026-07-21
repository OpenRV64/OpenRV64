`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_ccx_protocol_nh #(
    parameter integer NUM_HARTS = 2
);

    localparam [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID_BASE = 4'd4;

    logic clk;
    logic rst_n;
    logic [NUM_HARTS-1:0] core_mem_valid;
    wire [NUM_HARTS-1:0] core_mem_ready;
    logic [NUM_HARTS-1:0] core_mem_write;
    logic [NUM_HARTS*64-1:0] core_mem_addr;
    logic [NUM_HARTS*64-1:0] core_mem_wdata;
    logic [NUM_HARTS*8-1:0] core_mem_wstrb;
    wire [NUM_HARTS*64-1:0] core_mem_rdata;
    wire [NUM_HARTS-1:0] core_mem_error;

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

    integer protocol_issues;
    integer completions;
    integer axi_reads;
    integer axi_writes;
    integer hart_index;
    integer expected_hart;
    integer expected_phase;
    integer response_lane;
    logic aw_seen;
    logic w_seen;

    openrv64_ccx_protocol_wrapper_nh #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(HART_ID_BASE),
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

    function automatic [63:0] request_address;
        input integer phase;
        input integer hart;
        begin
            request_address = 64'h0000_0000_8000_0000 +
                              (hart * 64'h100) +
                              (hart * 64'h8) +
                              (phase * 64'h40);
        end
    endfunction

    function automatic [63:0] request_write_data;
        input integer hart;
        begin
            request_write_data = 64'hc001_cafe_0000_0000 | hart;
        end
    endfunction

    function automatic [63:0] response_data;
        input [63:0] address;
        begin
            response_data = 64'h5a5a_1234_0000_0000 ^ address;
        end
    endfunction

    task automatic launch_round;
        input logic write;
        input integer phase;
        begin
            @(negedge clk);
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                core_mem_valid[hart_index] = 1'b1;
                core_mem_write[hart_index] = write;
                core_mem_addr[hart_index*64 +: 64] =
                    request_address(phase, hart_index);
                core_mem_wdata[hart_index*64 +: 64] =
                    request_write_data(hart_index);
                core_mem_wstrb[hart_index*8 +: 8] =
                    write ? 8'hf3 : 8'h00;
            end
        end
    endtask

    // Check round-robin selection at the actual internal protocol boundary.
    always @(posedge clk) begin
        if (rst_n && dut.shared_req_valid && dut.shared_req_ready) begin
            expected_hart = protocol_issues % NUM_HARTS;
            expected_phase = protocol_issues / NUM_HARTS;
            if (dut.shared_req_hart_id !== HART_ID_BASE + expected_hart)
                $fatal(1,
                       "N=%0d protocol hart ID/order mismatch got=%0d expected=%0d",
                       NUM_HARTS, dut.shared_req_hart_id,
                       HART_ID_BASE + expected_hart);
            if (dut.shared_req_txn_id !== expected_phase[3:0])
                $fatal(1,
                       "N=%0d hart %0d transaction ID mismatch got=%0d expected=%0d",
                       NUM_HARTS, expected_hart, dut.shared_req_txn_id,
                       expected_phase);
            if (dut.shared_req_addr !==
                request_address(expected_phase, expected_hart))
                $fatal(1, "N=%0d round-robin address order mismatch",
                       NUM_HARTS);
            if (dut.shared_req_op !==
                ((expected_phase == 0) ? `OPENRV64_CCX_OP_READ :
                                         `OPENRV64_CCX_OP_WRITE))
                $fatal(1, "N=%0d operation routing mismatch", NUM_HARTS);
            protocol_issues <= protocol_issues + 1;
        end
    end

    // Minimal single-outstanding AXI memory target.  Its response value is a
    // function of the accepted address, making a misrouted CCX response fail
    // at the receiving hart.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_rid <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            m_axi_rdata <= {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b1;
            m_axi_rvalid <= 1'b0;
            m_axi_bid <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            m_axi_bresp <= 2'b00;
            m_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
            axi_reads <= 0;
            axi_writes <= 0;
        end else begin
            if (m_axi_rvalid && m_axi_rready)
                m_axi_rvalid <= 1'b0;
            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;

            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_arid !== {`OPENRV64_AXI_ID_WIDTH{1'b1}} ||
                    m_axi_arlen !== 0 || m_axi_arsize !== 3 ||
                    m_axi_arburst !== 2'b01 || m_axi_arcache !== 4'b0011)
                    $fatal(1, "N=%0d malformed AXI read", NUM_HARTS);
                if (m_axi_araddr !== request_address(0, axi_reads))
                    $fatal(1, "N=%0d AXI read arbitration order mismatch",
                           NUM_HARTS);
                response_lane = m_axi_araddr[4:3];
                m_axi_rid <= m_axi_arid;
                m_axi_rdata <= {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
                m_axi_rdata[response_lane*64 +: 64] <=
                    response_data(m_axi_araddr);
                m_axi_rresp <= 2'b00;
                m_axi_rlast <= 1'b1;
                m_axi_rvalid <= 1'b1;
                axi_reads <= axi_reads + 1;
            end

            if (m_axi_awvalid && m_axi_awready) begin
                if (m_axi_awaddr !== request_address(1, axi_writes) ||
                    m_axi_awid !== {`OPENRV64_AXI_ID_WIDTH{1'b1}} ||
                    m_axi_awlen !== 0 || m_axi_awsize !== 3 ||
                    m_axi_awburst !== 2'b01 || m_axi_awcache !== 4'b0011)
                    $fatal(1, "N=%0d malformed or misordered AXI write",
                           NUM_HARTS);
                aw_seen <= 1'b1;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                response_lane = (request_address(1, axi_writes) >> 3) & 3;
                if (m_axi_wdata[response_lane*64 +: 64] !==
                    request_write_data(axi_writes) ||
                    m_axi_wstrb[response_lane*8 +: 8] !== 8'hf3 ||
                    !m_axi_wlast)
                    $fatal(1, "N=%0d AXI write payload routing mismatch",
                           NUM_HARTS);
                w_seen <= 1'b1;
            end

            if ((aw_seen || (m_axi_awvalid && m_axi_awready)) &&
                (w_seen || (m_axi_wvalid && m_axi_wready))) begin
                m_axi_bid <= m_axi_awid;
                m_axi_bresp <= 2'b00;
                m_axi_bvalid <= 1'b1;
                aw_seen <= 1'b0;
                w_seen <= 1'b0;
                axi_writes <= axi_writes + 1;
            end
        end
    end

    // Every completion must return only to the hart that owns the request.
    always @(posedge clk) begin
        if (rst_n) begin
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                if (core_mem_valid[hart_index] &&
                    core_mem_ready[hart_index]) begin
                    if (core_mem_error[hart_index])
                        $fatal(1, "N=%0d hart %0d received an error",
                               NUM_HARTS, hart_index);
                    if (!core_mem_write[hart_index] &&
                        core_mem_rdata[hart_index*64 +: 64] !==
                        response_data(core_mem_addr[hart_index*64 +: 64]))
                        $fatal(1, "N=%0d read response routed to wrong hart",
                               NUM_HARTS);
                    core_mem_valid[hart_index] <= 1'b0;
                    completions <= completions + 1;
                end
            end
        end
    end

    initial begin
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4))
            $fatal(1, "multi-hart protocol bench supports N=2 or N=4");

        rst_n = 1'b0;
        core_mem_valid = {NUM_HARTS{1'b0}};
        core_mem_write = {NUM_HARTS{1'b0}};
        core_mem_addr = {NUM_HARTS*64{1'b0}};
        core_mem_wdata = {NUM_HARTS*64{1'b0}};
        core_mem_wstrb = {NUM_HARTS*8{1'b0}};
        m_axi_arready = 1'b1;
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b1;
        protocol_issues = 0;
        completions = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        launch_round(1'b0, 0);
        wait (completions == NUM_HARTS);
        repeat (2) @(posedge clk);

        launch_round(1'b1, 1);
        wait (completions == 2 * NUM_HARTS);
        repeat (3) @(posedge clk);

        if (protocol_issues != 2 * NUM_HARTS ||
            axi_reads != NUM_HARTS || axi_writes != NUM_HARTS)
            $fatal(1,
                   "N=%0d traffic count mismatch protocol=%0d read=%0d write=%0d",
                   NUM_HARTS, protocol_issues, axi_reads, axi_writes);

        $display("PASS: %0d-hart CCX IDs, round-robin arbitration, response routing, and external AXI", NUM_HARTS);
        $finish;
    end

    initial begin
        repeat (4000) @(posedge clk);
        $fatal(1, "N=%0d multi-hart CCX test timeout", NUM_HARTS);
    end

endmodule
