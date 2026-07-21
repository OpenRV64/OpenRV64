`timescale 1ns/1ps
`include "complex/bus/defs.v"

module tb_complex_bus #(
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI
);

    localparam integer DATA_WIDTH = 64;
    localparam integer ID_WIDTH = 3;
    localparam [ID_WIDTH-1:0] AXI_ID = 3'd6;

    logic clk;
    logic rst_n;
    logic req_valid;
    wire req_ready;
    logic req_write;
    logic [63:0] req_addr;
    logic [2:0] req_size;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic [DATA_WIDTH/8-1:0] req_wstrb;
    logic req_cacheable;
    wire resp_valid;
    logic resp_ready;
    wire [DATA_WIDTH-1:0] resp_rdata;
    wire resp_error;

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

    logic aw_seen;
    logic w_seen;
    logic [63:0] accepted_awaddr;
    integer cycle_count;
    integer wb_attempts;
    integer wb_retries_remaining;
    logic wb_error_next;

    openrv64_complex_external_bus #(
        .BUS_TYPE(BUS_TYPE),
        .ADDR_WIDTH(64),
        .DATA_WIDTH(DATA_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH),
        .AXI_ID(AXI_ID),
        .WB_ADDR_SHIFT(3),
        .WB_MAX_RETRIES(3)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_write_i(req_write),
        .req_addr_i(req_addr),
        .req_size_i(req_size),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .req_cacheable_i(req_cacheable),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_rdata_o(resp_rdata),
        .resp_error_o(resp_error),
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

    function automatic [63:0] read_pattern;
        input [63:0] address;
        begin
            read_pattern = 64'h5a5a_cafe_0000_0000 ^ address;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            m_axi_rid <= AXI_ID;
            m_axi_rdata <= 0;
            m_axi_rresp <= 0;
            m_axi_rlast <= 1'b1;
            m_axi_rvalid <= 1'b0;
            m_axi_bid <= AXI_ID;
            m_axi_bresp <= 0;
            m_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
            accepted_awaddr <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (m_axi_rvalid && m_axi_rready)
                m_axi_rvalid <= 1'b0;
            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;

            if (m_axi_arvalid && m_axi_arready) begin
                if ((m_axi_arid !== AXI_ID) || (m_axi_arlen !== 0) ||
                    (m_axi_arsize !== 3) ||
                    (m_axi_arburst !== 2'b01) || m_axi_arlock)
                    $fatal(1, "malformed AXI read request");
                m_axi_rid <= AXI_ID;
                m_axi_rdata <= read_pattern(m_axi_araddr);
                m_axi_rresp <= 2'b00;
                m_axi_rlast <= 1'b1;
                m_axi_rvalid <= 1'b1;
            end

            if (m_axi_awvalid && m_axi_awready) begin
                if ((m_axi_awid !== AXI_ID) || (m_axi_awlen !== 0) ||
                    (m_axi_awsize !== 3) ||
                    (m_axi_awburst !== 2'b01) || m_axi_awlock)
                    $fatal(1, "malformed AXI write address");
                accepted_awaddr <= m_axi_awaddr;
                aw_seen <= 1'b1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if ((m_axi_wdata !== 64'h0123_4567_89ab_cdef) ||
                    (m_axi_wstrb !== 8'h3c) || !m_axi_wlast)
                    $fatal(1, "malformed AXI write data");
                w_seen <= 1'b1;
            end
            if ((aw_seen || (m_axi_awvalid && m_axi_awready)) &&
                (w_seen || (m_axi_wvalid && m_axi_wready)) &&
                !m_axi_bvalid) begin
                m_axi_bid <= AXI_ID;
                m_axi_bresp <= 2'b00;
                m_axi_bvalid <= 1'b1;
                aw_seen <= 1'b0;
                w_seen <= 1'b0;
            end
        end
    end

    // Independent ready patterns prove that AW and W are not assumed to
    // handshake together.
    always @* begin
        m_axi_arready = 1'b1;
        m_axi_awready = cycle_count[0];
        m_axi_wready = !cycle_count[0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack <= 1'b0;
            wb_err <= 1'b0;
            wb_rty <= 1'b0;
            wb_dat_i <= 0;
            wb_attempts <= 0;
        end else begin
            wb_ack <= 1'b0;
            wb_err <= 1'b0;
            wb_rty <= 1'b0;
            if (wb_cyc && wb_stb && !wb_stall) begin
                if ((wb_cti !== 3'b000) || (wb_bte !== 2'b00) || wb_lock)
                    $fatal(1, "malformed WISHBONE B4 cycle tags");
                wb_attempts <= wb_attempts + 1;
                if (wb_retries_remaining > 0) begin
                    wb_rty <= 1'b1;
                    wb_retries_remaining <= wb_retries_remaining - 1;
                end else if (wb_error_next) begin
                    wb_err <= 1'b1;
                    wb_error_next <= 1'b0;
                end else begin
                    wb_ack <= 1'b1;
                    wb_dat_i <= read_pattern(wb_adr << 3);
                end
            end
        end
    end

    task automatic issue_request;
        input write;
        input [63:0] address;
        input [63:0] write_data;
        input [7:0] write_strobes;
        input [63:0] expected_data;
        input expected_error;
        integer cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = write;
            req_addr = address;
            req_wdata = write_data;
            req_wstrb = write_strobes;
            cycles = 0;
            while (!req_ready && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "external bus request timed out");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            cycles = 0;
            while (!resp_valid && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!resp_valid)
                $fatal(1, "external bus response timed out");
            if (resp_error !== expected_error)
                $fatal(1, "external bus error=%b expected=%b",
                       resp_error, expected_error);
            if (!write && !expected_error && resp_rdata !== expected_data)
                $fatal(1, "external bus data=%016x expected=%016x",
                       resp_rdata, expected_data);
            @(posedge clk);
        end
    endtask

    integer attempts_before;

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_size = 3'd3;
        req_wdata = 0;
        req_wstrb = 0;
        req_cacheable = 1'b1;
        resp_ready = 1'b1;
        wb_stall = 1'b0;
        wb_retries_remaining = 0;
        wb_error_next = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
            issue_request(1'b0, 64'h108, 0, 0,
                          read_pattern(64'h108), 1'b0);
            issue_request(1'b1, 64'h210,
                          64'h0123_4567_89ab_cdef, 8'h3c,
                          0, 1'b0);
            if (accepted_awaddr !== 64'h210)
                $fatal(1, "AXI write address was not retained");
            if (wb_cyc || wb_stb)
                $fatal(1, "inactive WISHBONE interface was driven");
        end else begin
            wb_stall = 1'b1;
            fork
                begin
                    repeat (3) @(posedge clk);
                    @(negedge clk);
                    wb_stall = 1'b0;
                end
                issue_request(1'b0, 64'h108, 0, 0,
                              read_pattern(64'h108), 1'b0);
            join
            if (wb_adr !== (64'h108 >> 3))
                $fatal(1, "WISHBONE address-unit shift is wrong");

            wb_retries_remaining = 1;
            attempts_before = wb_attempts;
            issue_request(1'b1, 64'h210,
                          64'h0123_4567_89ab_cdef, 8'h3c,
                          0, 1'b0);
            if ((wb_attempts - attempts_before) != 2)
                $fatal(1, "WISHBONE RTY did not reissue exactly once");

            wb_retries_remaining = 4;
            attempts_before = wb_attempts;
            issue_request(1'b0, 64'h2a0, 0, 0, 0, 1'b1);
            if ((wb_attempts - attempts_before) != 4)
                $fatal(1, "WISHBONE retry limit attempt count is wrong");

            wb_error_next = 1'b1;
            issue_request(1'b0, 64'h318, 0, 0, 0, 1'b1);
            if (m_axi_arvalid || m_axi_awvalid || m_axi_wvalid)
                $fatal(1, "inactive AXI interface was driven");
        end

        $display("PASS: selectable %s external backend handshake, errors, and backpressure",
                 (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ? "AXI4" :
                                                          "WISHBONE B4");
        $finish;
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1, "external bus test timeout");
    end

endmodule
