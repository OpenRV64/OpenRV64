`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_compliance_3p #(
    parameter bit ENABLE_RV64M = 1'b1,
    parameter bit BANKED_GPR = 1'b0,
    parameter integer RAM_BYTES = 1 * 1024 * 1024,
    parameter integer DEFAULT_MAX_CYCLES = 2_000_000
);
    localparam logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000;
    localparam integer RESULT_CAUSE = 143;
    localparam integer RESULT_EXCEPTION = 149;
    localparam integer RESULT_REG_WRITE = 153;
    localparam integer RESULT_RD = 154;
    localparam integer RESULT_DATA = 169;
    localparam integer RESULT_INSTR = 233;
    localparam integer RESULT_NEXT_PC = 265;
    localparam integer RESULT_PC = 329;

    reg clk;
    reg rst_n;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    wire arready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] rid;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    wire rready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid;
    wire awready;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] wstrb;
    wire wlast;
    wire wvalid;
    wire wready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    wire bready;
    wire bus_valid;
    wire icx_req_valid;
    wire icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    wire icx_wdata_valid;
    wire icx_wdata_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    wire icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    wire icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    wire icx_resp_error;
    wire icx_resp_sc_success;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire [63:0] trace_cycle;
    wire [4:0] trace_valid;
    wire [4:0] trace_stall;
    wire [4:0] trace_flush;
    wire [4:0] trace_advance;
    wire [319:0] trace_ids;
    wire [319:0] trace_pcs;
    wire [159:0] trace_instrs;
    wire [7:0] trace_events;
    wire [7:0] trace_stall_causes;
    wire trace_retire_valid;
    wire trace_retire_arch;
    wire trace_retire_exception;
    wire [4:0] trace_retire_cause;
    wire [63:0] trace_retire_next_pc;
    wire trace_retire_rd_write;
    wire [4:0] trace_retire_rd;
    wire [63:0] trace_retire_wdata;

    wire [2:0] retire_accept =
        dut.u_core.u_backend.queue_retire_accept;
    wire [2:0] retire_arch = dut.u_core.u_backend.retire_arch_o;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] retire_result =
        dut.u_core.u_backend.queue_retire_result;

    integer cycle_count;
    integer retired_count;
    integer max_cycles;
    integer trace_fd;
    integer lane;
    longint unsigned tohost_addr;
    longint unsigned tohost_line;
    string memh_path;
    string test_name;
    string trace_path;
    wire [63:0] tohost_value =
        u_axi_fabric.ram_q[tohost_line][tohost_addr[4:3]*64 +: 64];

    openrv64_top_3p #(
        .RESET_VECTOR(RAM_BASE),
        .ENABLE_RV64M(ENABLE_RV64M),
        .BANKED_GPR(BANKED_GPR),
        .BRANCH_COMPLETION_FORWARD_MASK(BANKED_GPR ? 3'b000 : 3'b001),
        .RELAX_WAW(BANKED_GPR ? 1'b0 : 1'b1),
        .ENABLE_RV64A(1'b1),
        .ENABLE_POSTED_STORES(1'b0),
        .ENABLE_L1I(1'b0),
        .ENABLE_L1D(1'b0),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .m_axi_arid(arid), .m_axi_araddr(araddr),
        .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arlock(),
        .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awlock(),
        .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bid(bid),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .icx_req_valid(icx_req_valid), .icx_req_ready(icx_req_ready),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id), .icx_req_op(icx_req_op),
        .icx_req_order(icx_req_order), .icx_req_kind(icx_req_kind),
        .icx_req_attr(icx_req_attr), .icx_req_size(icx_req_size),
        .icx_req_addr(icx_req_addr),
        .icx_req_burst_len(icx_req_burst_len),
        .icx_wdata_valid(icx_wdata_valid),
        .icx_wdata_ready(icx_wdata_ready),
        .icx_wdata_hart_id(icx_wdata_hart_id),
        .icx_wdata_txn_id(icx_wdata_txn_id),
        .icx_wdata_source_id(icx_wdata_source_id),
        .icx_wdata_beat_index(icx_wdata_beat_index),
        .icx_wdata_last(icx_wdata_last), .icx_wdata(icx_wdata),
        .icx_wstrb(icx_wstrb), .icx_resp_valid(icx_resp_valid),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id),
        .icx_resp_txn_id(icx_resp_txn_id),
        .icx_resp_source_id(icx_resp_source_id),
        .icx_resp_beat_index(icx_resp_beat_index),
        .icx_resp_last(icx_resp_last),
        .icx_resp_rdata(icx_resp_rdata),
        .icx_resp_error(icx_resp_error),
        .icx_resp_sc_success(icx_resp_sc_success),
        .irq_m_software(1'b0), .irq_m_timer(1'b0),
        .irq_m_external(1'b0), .irq_s_software(1'b0),
        .irq_s_timer(1'b0), .irq_s_external(1'b0),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle), .trace_valid(trace_valid),
        .trace_stall(trace_stall), .trace_flush(trace_flush),
        .trace_advance(trace_advance), .trace_ids(trace_ids),
        .trace_pcs(trace_pcs), .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    tb_axi256_soc_fabric #(
        .RAM_BYTES(RAM_BYTES),
        .ZERO_INIT_LINES(RAM_BYTES / 32)
    ) u_axi_fabric (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axi_arid_i(arid), .s_axi_araddr_i(araddr),
        .s_axi_arlen_i(arlen), .s_axi_arsize_i(arsize),
        .s_axi_arburst_i(arburst), .s_axi_arvalid_i(arvalid),
        .s_axi_arready_o(arready), .s_axi_rid_o(rid),
        .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp),
        .s_axi_rlast_o(rlast), .s_axi_rvalid_o(rvalid),
        .s_axi_rready_i(rready), .s_axi_awid_i(awid),
        .s_axi_awaddr_i(awaddr), .s_axi_awlen_i(awlen),
        .s_axi_awsize_i(awsize), .s_axi_awburst_i(awburst),
        .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
        .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb),
        .s_axi_wlast_i(wlast), .s_axi_wvalid_i(wvalid),
        .s_axi_wready_o(wready), .s_axi_bid_o(bid),
        .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid),
        .s_axi_bready_i(bready),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op), .icx_req_order_i(icx_req_order),
        .icx_req_kind_i(icx_req_kind), .icx_req_attr_i(icx_req_attr),
        .icx_req_size_i(icx_req_size), .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_wdata_valid_i(icx_wdata_valid),
        .icx_wdata_ready_o(icx_wdata_ready),
        .icx_wdata_hart_id_i(icx_wdata_hart_id),
        .icx_wdata_txn_id_i(icx_wdata_txn_id),
        .icx_wdata_source_id_i(icx_wdata_source_id),
        .icx_wdata_beat_index_i(icx_wdata_beat_index),
        .icx_wdata_last_i(icx_wdata_last), .icx_wdata_i(icx_wdata),
        .icx_wstrb_i(icx_wstrb), .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
        .mem_valid_o(bus_valid),
        .mem_ready_i(bus_valid), .mem_write_o(), .mem_addr_o(),
        .mem_wdata_o(), .mem_wstrb_o(), .mem_rdata_i(64'h0),
        // External architectural tests may mask platform interrupt sources
        // before entering even unprivileged tests. The direct 3p seam has no
        // peripherals, so acknowledge those accesses as inert MMIO. Tests
        // that require real CLINT/PLIC behavior use the platform backend.
        .mem_error_i(1'b0)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "COMPLIANCE FAIL missing +memh=<path>");
        if (!$value$plusargs("tohost=%h", tohost_addr))
            $fatal(1, "COMPLIANCE FAIL missing +tohost=<hex-address>");
        if (!$value$plusargs("test=%s", test_name))
            test_name = "unnamed";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = DEFAULT_MAX_CYCLES;
        if ((tohost_addr < RAM_BASE) ||
            (tohost_addr + 8 > RAM_BASE + RAM_BYTES) ||
            (tohost_addr[2:0] != 3'b000))
            $fatal(1, "COMPLIANCE FAIL invalid tohost address 0x%016x",
                   tohost_addr);
        tohost_line = (tohost_addr - RAM_BASE) >> 5;
        $readmemh(memh_path, u_axi_fabric.ram_q);

        trace_fd = 0;
        if ($value$plusargs("arch_trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0)
                $fatal(1, "COMPLIANCE FAIL cannot open trace %s", trace_path);
            $fwrite(trace_fd,
                    "order,cycle,lane,arch,pc,instr,next_pc,rd_write,rd,wdata,exception,cause,mode\n");
        end
        cycle_count = 0;
        retired_count = 0;
        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            for (lane = 0; lane < 3; lane = lane + 1) begin
                if (retire_accept[lane] && trace_fd != 0)
                    $fwrite(trace_fd,
                            "%0d,%0d,%0d,%0d,%016x,%08x,%016x,%0d,%0d,%016x,%0d,%0d,%0d\n",
                            retired_count + lane, cycle_count, lane,
                            retire_arch[lane],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_PC +: 64],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_INSTR +: 32],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_NEXT_PC +: 64],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_REG_WRITE],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_RD +: 5],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_DATA +: 64],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_EXCEPTION],
                            retire_result[lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CAUSE +: 5],
                            dut.u_core.u_csrs.priv_mode_q);
            end
            retired_count <= retired_count + retire_accept[0] +
                             retire_accept[1] + retire_accept[2];

            if (tohost_value != 64'h0) begin
                if (tohost_value == 64'h1) begin
                    $display("COMPLIANCE PASS test=%s backend=3p cycles=%0d retired=%0d",
                             test_name, cycle_count, retired_count);
                    if (trace_fd != 0)
                        $fclose(trace_fd);
                    $finish;
                end
                $fatal(1,
                       "COMPLIANCE FAIL test=%s backend=3p tohost=0x%016x cycles=%0d pc=0x%016x instr=0x%08x",
                       test_name, tohost_value, cycle_count,
                       dbg_pc, dbg_instr);
            end
            if (cycle_count >= max_cycles)
                $fatal(1,
                       "COMPLIANCE TIMEOUT test=%s backend=3p cycles=%0d retired=%0d pc=0x%016x instr=0x%08x",
                       test_name, cycle_count, retired_count,
                       dbg_pc, dbg_instr);
        end
    end
endmodule
