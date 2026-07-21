`timescale 1ns/1ps
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
    logic [NUM_HARTS-1:0] core_valid;
    wire [NUM_HARTS-1:0] core_ready;
    logic [NUM_HARTS-1:0] core_write;
    logic [NUM_HARTS*64-1:0] core_addr;
    logic [NUM_HARTS*64-1:0] core_wdata;
    logic [NUM_HARTS*8-1:0] core_wstrb;
    wire [NUM_HARTS*64-1:0] core_rdata;
    wire [NUM_HARTS-1:0] core_error;

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

    integer external_reads;
    integer protocol_requests;
    integer completions;
    integer hart_index;
    integer expected_hart;
    logic axi_read_active;
    logic [63:0] axi_read_addr;
    logic [7:0] axi_read_len;
    integer axi_read_beat;

    openrv64_core_complex_nh #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(HART_ID_BASE),
        .L2_BYTES(256 * 1024),
        .L2_LINE_BYTES(64),
        .L2_WAYS(8),
        .L2_MERGE_ENTRIES(NUM_HARTS),
        .BUS_TYPE(BUS_TYPE),
        .BUS_ADDR_WIDTH(64),
        .BUS_DATA_WIDTH(DATA_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH),
        .AXI_ID(3'd7),
        .WB_ADDR_SHIFT(3)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .core_mem_valid_i(core_valid),
        .core_mem_ready_o(core_ready),
        .core_mem_write_i(core_write),
        .core_mem_addr_i(core_addr),
        .core_mem_wdata_i(core_wdata),
        .core_mem_wstrb_i(core_wstrb),
        .core_mem_rdata_o(core_rdata),
        .core_mem_error_o(core_error),
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
            axi_read_active <= 1'b0;
            axi_read_addr <= 0;
            axi_read_len <= 0;
            axi_read_beat <= 0;
        end else begin
            if (m_axi_rvalid && m_axi_rready) begin
                external_reads <= external_reads + 1;
                if (m_axi_rlast) begin
                    m_axi_rvalid <= 1'b0;
                    m_axi_arready <= 1'b1;
                    axi_read_active <= 1'b0;
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
                if ((m_axi_arid !== 3'd7) || (m_axi_arlen !== 3) ||
                    (m_axi_arsize !== 3) ||
                    (m_axi_arburst !== 2'b01))
                    $fatal(1, "malformed integrated AXI fill burst");
                m_axi_rid <= m_axi_arid;
                m_axi_rdata <= memory_data(m_axi_araddr);
                m_axi_rresp <= 0;
                m_axi_rlast <= (m_axi_arlen == 0);
                m_axi_rvalid <= 1'b1;
                m_axi_arready <= 1'b0;
                axi_read_active <= 1'b1;
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
        if (rst_n && dut.shared_req_valid && dut.shared_req_ready) begin
            expected_hart = protocol_requests % NUM_HARTS;
            if (dut.shared_req_hart_id !== HART_ID_BASE + expected_hart)
                $fatal(1, "N=%0d core-complex hart strap/order mismatch",
                       NUM_HARTS);
            protocol_requests <= protocol_requests + 1;
        end

        if (rst_n && dut.bus_req_valid && dut.bus_req_ready &&
            (dut.u_genbus.upstream_req_burst_i !== 8'd0))
            $fatal(1, "CCX must tie the genbus burst counter to zero");

        if (rst_n) begin
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                if (core_valid[hart_index] && core_ready[hart_index]) begin
                    if (core_error[hart_index])
                        $fatal(1, "N=%0d hart %0d received error",
                               NUM_HARTS, hart_index);
                    if (core_rdata[hart_index*64 +: 64] !==
                        memory_data(core_addr[hart_index*64 +: 64]))
                        $fatal(1, "N=%0d hart %0d response misrouted",
                               NUM_HARTS, hart_index);
                    core_valid[hart_index] <= 1'b0;
                    completions <= completions + 1;
                end
            end
        end
    end

    task automatic launch_round;
        input integer round;
        begin
            @(negedge clk);
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                core_valid[hart_index] = 1'b1;
                core_addr[hart_index*64 +: 64] =
                    64'h800 + hart_index*8;
            end
        end
    endtask

    integer reads_after_fill;

    initial begin
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4))
            $fatal(1, "core-complex bench supports N=2 or N=4");

        rst_n = 1'b0;
        core_valid = 0;
        core_write = 0;
        core_addr = 0;
        core_wdata = 0;
        core_wstrb = 0;
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b1;
        wb_stall = 1'b0;
        external_reads = 0;
        protocol_requests = 0;
        completions = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        launch_round(0);
        wait (completions == NUM_HARTS);
        if (external_reads != 8)
            $fatal(1, "N=%0d merged fill used %0d external reads",
                   NUM_HARTS, external_reads);

        reads_after_fill = external_reads;
        launch_round(1);
        wait (completions == 2*NUM_HARTS);
        if (external_reads != reads_after_fill)
            $fatal(1, "N=%0d L2 hits escaped to external bus", NUM_HARTS);
        if (protocol_requests != 2*NUM_HARTS)
            $fatal(1, "N=%0d protocol request count=%0d",
                   NUM_HARTS, protocol_requests);

        $display("PASS: %0d-hart core complex straps, L2 merging/hits, and %s backend",
                 NUM_HARTS,
                 (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ? "AXI4" :
                                                          "WISHBONE B4");
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "N=%0d core-complex test timeout", NUM_HARTS);
    end

endmodule
