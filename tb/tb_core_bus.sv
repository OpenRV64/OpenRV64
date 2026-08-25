`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

module tb_core_bus;

    localparam [1:0] GEN_STATE_TRANSLATE = 2'd1;
    localparam [1:0] GEN_STATE_TLB_RESULT = 2'd3;

    logic clk;
    logic rst_n;

    logic fetch_valid;
    logic fetch_cancel;
    logic [63:0] fetch_addr;
    logic [1:0] fetch_priv;
    logic [3:0] fetch_vm_mode;
    logic [15:0] fetch_asid;
    logic [43:0] fetch_root_ppn;
    logic fetch_sum;
    logic fetch_mxr;
    logic fetch_next_valid;
    logic [63:0] fetch_next_addr;
    wire fetch_ready;
    wire [63:0] fetch_rdata;
    wire fetch_access_fault;
    wire fetch_page_fault;

    logic lsu_valid;
    logic lsu_write;
    logic [63:0] lsu_addr;
    logic [63:0] lsu_wdata;
    logic [7:0] lsu_wstrb;
    logic [2:0] lsu_size;
    logic [1:0] lsu_priv;
    logic [3:0] lsu_vm_mode;
    logic [15:0] lsu_asid;
    logic [43:0] lsu_root_ppn;
    logic lsu_sum;
    logic lsu_mxr;
    wire lsu_ready;
    wire [63:0] lsu_rdata;
    wire lsu_access_fault;
    wire lsu_page_fault;

    logic tlbi;
    logic context_flush;

    wire req_valid;
    logic req_ready;
    wire req_write;
    wire [63:0] req_addr;
    wire [63:0] req_pmp_addr;
    wire [1:0] req_priv;
    wire [2:0] req_size;
    wire req_exec;
    wire [63:0] req_wdata;
    wire [7:0] req_wstrb;
    logic [63:0] req_rdata;
    logic req_error;

    wire pmp_valid;
    wire [63:0] pmp_addr;
    wire [1:0] pmp_priv;
    wire [2:0] pmp_size;
    wire pmp_write;
    wire pmp_exec;

    wire icx_req_valid;
    logic icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    logic icx_resp_valid;
    wire icx_resp_ready;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;

    openrv64_core_bus dut (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_valid_i(fetch_valid),
        .fetch_cancel_i(fetch_cancel),
        .fetch_addr_i(fetch_addr),
        .fetch_priv_i(fetch_priv),
        .fetch_vm_mode_i(fetch_vm_mode),
        .fetch_asid_i(fetch_asid),
        .fetch_root_ppn_i(fetch_root_ppn),
        .fetch_sum_i(fetch_sum),
        .fetch_mxr_i(fetch_mxr),
        .fetch_ready_o(fetch_ready),
        .fetch_rdata_o(fetch_rdata),
        .fetch_access_fault_o(fetch_access_fault),
        .fetch_page_fault_o(fetch_page_fault),
        .lsu_valid_i(lsu_valid),
        .lsu_lock_i(1'b0),
        .lsu_write_i(lsu_write),
        .lsu_addr_i(lsu_addr),
        .lsu_wdata_i(lsu_wdata),
        .lsu_wstrb_i(lsu_wstrb),
        .lsu_size_i(lsu_size),
        .lsu_priv_i(lsu_priv),
        .lsu_vm_mode_i(lsu_vm_mode),
        .lsu_asid_i(lsu_asid),
        .lsu_root_ppn_i(lsu_root_ppn),
        .lsu_sum_i(lsu_sum),
        .lsu_mxr_i(lsu_mxr),
        .lsu_ready_o(lsu_ready),
        .lsu_rdata_o(lsu_rdata),
        .lsu_access_fault_o(lsu_access_fault),
        .lsu_page_fault_o(lsu_page_fault),
        .lsu_xlate_req_valid_i(1'b0),
        .lsu_xlate_req_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .lsu_xlate_req_write_i(1'b0),
        .lsu_xlate_req_size_i(3'd0),
        .lsu_xlate_req_vaddr_i(64'd0),
        .lsu_xlate_req_priv_i(`RV64_PRIV_M),
        .lsu_xlate_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_xlate_req_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .lsu_xlate_req_root_ppn_i({`RV64_SATP_PPN_WIDTH{1'b0}}),
        .lsu_xlate_req_sum_i(1'b0),
        .lsu_xlate_req_mxr_i(1'b0),
        .lsu_xlate_resp_ready_i(1'b1),
        .tlbi_i(tlbi),
        .context_flush_i(context_flush),
        .fetch_context_change_i(1'b0),
        .page_screen_csr_clear_i(1'b0),
        .pmp_update_i(1'b0),
        .store_barrier_i(1'b0),
        .icache_invalidate_i(1'b0),
        .icache_prefetch_valid_i(1'b0),
        .icache_prefetch_taken_addr_i(64'd0),
        .icache_prefetch_fallthrough_addr_i(64'd0),
        .icache_age_valid_i(3'b000),
        .icache_age_addr_i(192'd0),
        .req_valid_o(req_valid),
        .req_ready_i(req_ready),
        .req_write_o(req_write),
        .req_addr_o(req_addr),
        .req_pmp_addr_o(req_pmp_addr),
        .req_priv_o(req_priv),
        .req_size_o(req_size),
        .req_exec_o(req_exec),
        .req_wdata_o(req_wdata),
        .req_wstrb_o(req_wstrb),
        .req_rdata_i(req_rdata),
        .req_error_i(req_error),
        .fetch_next_valid_i(fetch_next_valid),
        .fetch_next_addr_i(fetch_next_addr),
        .pmp_valid_o(pmp_valid),
        .pmp_addr_o(pmp_addr),
        .pmp_priv_o(pmp_priv),
        .pmp_size_o(pmp_size),
        .pmp_write_o(pmp_write),
        .pmp_exec_o(pmp_exec),
        .pmp_allow_i(1'b1),
        .fetch_pipe_req_valid_i(1'b0),
        .fetch_pipe_req_addr_i(64'd0),
        .fetch_pipe_req_stash_i(1'b0),
        .fetch_pipe_req_demand_i(1'b0),
        .fetch_pipe_req_priv_i(`RV64_PRIV_M),
        .fetch_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .fetch_pipe_req_asid_i(16'd0),
        .fetch_pipe_req_root_ppn_i(44'd0),
        .fetch_pipe_req_sum_i(1'b0), .fetch_pipe_req_mxr_i(1'b0),
        .fetch_pipe_resp_ready_i(1'b0),
        .fetch_pipe_cancel_stash_i(1'b1),
        .lsu_pipe_req_valid_i(1'b0),
        .lsu_pipe_req_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .lsu_pipe_req_xlate_only_i(1'b0),
        .lsu_pipe_req_physical_i(1'b0),
        .lsu_pipe_req_pmp_checked_i(1'b0),
        .lsu_pipe_req_lock_i(1'b0),
        .lsu_pipe_req_write_i(1'b0),
        .lsu_pipe_req_addr_i(64'd0),
        .lsu_pipe_req_wdata_i(64'd0),
        .lsu_pipe_req_wstrb_i(8'd0),
        .lsu_pipe_req_size_i(3'd0),
        .lsu_pipe_req_priv_i(`RV64_PRIV_M),
        .lsu_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_pipe_req_asid_i(16'd0),
        .lsu_pipe_req_root_ppn_i(44'd0),
        .lsu_pipe_req_sum_i(1'b0),
        .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_req_translation_hit_o(),
        .lsu_pipe_req_translation_paddr_o(),
        .lsu_pipe_req_translation_page_fault_o(),
        .lsu_pipe_cancel_i(1'b0),
        .lsu_pipe_resp_ready_i(1'b0),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(icx_req_lock),
        .icx_req_order_o(icx_req_order),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_attr_o(icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_ready_i(1'b0),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_req_hart_id),
        .icx_resp_txn_id_i(icx_req_txn_id),
        .icx_resp_source_id_i(`OPENRV64_ICX_SOURCE_PTW),
        .icx_resp_beat_index_i('0),
        .icx_resp_last_i(1'b1),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(1'b0),
        .icx_resp_sc_success_i(1'b0),
        .m_axi_arready_i(1'b0),
        .m_axi_rid_i(3'd0), .m_axi_rdata_i(256'd0),
        .m_axi_rresp_i(2'd0), .m_axi_rlast_i(1'b0),
        .m_axi_rvalid_i(1'b0), .m_axi_awready_i(1'b0),
        .m_axi_wready_i(1'b0), .m_axi_bid_i(3'd0),
        .m_axi_bresp_i(2'd0), .m_axi_bvalid_i(1'b0)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic wait_for_request;
        input expected_write;
        input [63:0] expected_addr;
        input [63:0] expected_wdata;
        input [7:0] expected_wstrb;
        input [8*40-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while (!req_valid && cycles < 12) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!req_valid || req_write !== expected_write ||
                req_addr !== expected_addr ||
                req_wdata !== expected_wdata ||
                req_wstrb !== expected_wstrb) begin
                $fatal(1,
                    "%0s: request valid/write/addr/data/strb=%b/%b/%016x/%016x/%02x",
                    label, req_valid, req_write, req_addr,
                    req_wdata, req_wstrb);
            end
        end
    endtask

    task automatic wait_for_ptw_request;
        input [63:0] expected_line_addr;
        input [63:0] expected_pte_addr;
        input [8*40-1:0] label;
        integer cycles;
        reg saw_pmp;
        begin
            cycles = 0;
            saw_pmp = 1'b0;
            while (!icx_req_valid && cycles < 20) begin
                @(negedge clk);
                if (pmp_valid) begin
                    saw_pmp = 1'b1;
                    if (pmp_addr !== expected_pte_addr ||
                        pmp_priv !== `RV64_PRIV_S || pmp_size !== 3'd3 ||
                        pmp_write || pmp_exec)
                        $fatal(1, "%0s: PTW PMP probe mismatch", label);
                end
                if (req_valid)
                    $fatal(1, "%0s: PTW leaked onto scalar bus", label);
                cycles = cycles + 1;
            end
            #1;
            if (!icx_req_valid || !saw_pmp ||
                icx_req_addr !== expected_line_addr ||
                icx_req_source_id !== `OPENRV64_ICX_SOURCE_PTW ||
                icx_req_op !== `OPENRV64_ICX_OP_READ ||
                icx_req_kind !== `OPENRV64_ICX_KIND_PTE ||
                icx_req_size !== 3'd6 ||
                icx_req_burst_len !== '0 || icx_req_lock) begin
                $fatal(1,
                    "%0s: invalid PTW ICX request valid/addr/source/op/kind/size=%b/%016x/%0d/%0d/%0d/%0d",
                    label, icx_req_valid, icx_req_addr,
                    icx_req_source_id, icx_req_op, icx_req_kind,
                    icx_req_size);
            end
        end
    endtask

    task automatic respond_ptw_line;
        input [63:0] pte_addr;
        input [63:0] pte_data;
        begin
            icx_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            icx_req_ready = 1'b0;
            icx_resp_rdata = '0;
            icx_resp_rdata[pte_addr[5:3]*64 +: 64] = pte_data;
            icx_resp_valid = 1'b1;
            #1;
            if (!icx_resp_ready)
                $fatal(1, "PTW did not accept its ICX response");
            @(posedge clk);
            @(negedge clk);
            icx_resp_valid = 1'b0;
            icx_resp_rdata = '0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        fetch_valid = 1'b0;
        fetch_cancel = 1'b0;
        fetch_addr = 64'd0;
        fetch_priv = `RV64_PRIV_M;
        fetch_vm_mode = `RV64_SATP_MODE_BARE;
        fetch_asid = 16'd0;
        fetch_root_ppn = 44'd0;
        fetch_sum = 1'b0;
        fetch_mxr = 1'b0;
        fetch_next_valid = 1'b0;
        fetch_next_addr = 64'd0;
        lsu_valid = 1'b0;
        lsu_write = 1'b0;
        lsu_addr = 64'd0;
        lsu_wdata = 64'd0;
        lsu_wstrb = 8'h00;
        lsu_size = 3'd3;
        lsu_priv = `RV64_PRIV_M;
        lsu_vm_mode = `RV64_SATP_MODE_BARE;
        lsu_asid = 16'd0;
        lsu_root_ppn = 44'd0;
        lsu_sum = 1'b0;
        lsu_mxr = 1'b0;
        tlbi = 1'b0;
        context_flush = 1'b0;
        req_ready = 1'b0;
        req_rdata = 64'd0;
        req_error = 1'b0;
        icx_req_ready = 1'b0;
        icx_resp_valid = 1'b0;
        icx_resp_rdata = '0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // LSU wins a simultaneous request and owns the physical bus until its
        // completion. Changes on the waiting fetch request cannot disturb it.
        fetch_valid = 1'b1;
        fetch_addr = 64'h0000_0000_0000_1000;
        lsu_valid = 1'b1;
        lsu_write = 1'b1;
        lsu_addr = 64'h0000_0000_0000_2008;
        lsu_wdata = 64'h1122_3344_5566_7788;
        lsu_wstrb = 8'hff;

        // Ownership captures translation context with the request. Changing
        // the live LSU context after grant must not turn this Bare access into
        // an Sv39 request.
        @(posedge clk);
        @(negedge clk);
        lsu_vm_mode = `RV64_SATP_MODE_SV39;
        lsu_asid = 16'h1234;
        lsu_root_ppn = 44'h0000_0000_abc;

        wait_for_request(1'b1, 64'h2008,
                         64'h1122_3344_5566_7788, 8'hff,
                         "LSU priority");
        if (req_pmp_addr != 64'h2008 || req_priv != `RV64_PRIV_M ||
            req_size != 3'd3 || req_exec) begin
            $fatal(1, "LSU physical protection context mismatch");
        end
        fetch_addr = 64'h0000_0000_0000_3004;
        #1;
        if (req_addr !== 64'h2008) begin
            $fatal(1, "locked LSU request changed address");
        end

        req_rdata = 64'hfeed_face_cafe_beef;
        req_ready = 1'b1;
        #1;
        if (!lsu_ready || fetch_ready ||
            lsu_rdata !== 64'hfeed_face_cafe_beef ||
            lsu_access_fault || lsu_page_fault) begin
            $fatal(1, "LSU completion was routed incorrectly");
        end
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        lsu_valid = 1'b0;
        lsu_vm_mode = `RV64_SATP_MODE_BARE;
        lsu_asid = 16'd0;
        lsu_root_ppn = 44'd0;

        wait_for_request(1'b0, 64'h3000, 64'd0, 8'h00,
                         "waiting fetch");
        if (req_pmp_addr != 64'h3000 || req_priv != `RV64_PRIV_M ||
            req_size != 3'd3 || !req_exec) begin
            $fatal(1, "fetch physical protection context mismatch");
        end
        req_rdata = 64'h0000_0013_0000_0013;
        req_ready = 1'b1;
        fetch_next_valid = 1'b1;
        fetch_next_addr = 64'h0000_0000_0000_3008;
        #1;
        if (!fetch_ready || lsu_ready ||
            fetch_rdata !== 64'h0000_0013_0000_0013) begin
            $fatal(1, "fetch completion was routed incorrectly");
        end
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        fetch_next_valid = 1'b0;
        fetch_addr = 64'h0000_0000_0000_3008;

        if (dut.g_gen.u_bus.state_q != 2'd1 ||
            dut.g_gen.u_bus.vaddr_q != 64'h3008) begin
            $fatal(1, "fetch successor did not bypass IDLE");
        end

        wait_for_request(1'b0, 64'h3008, 64'd0, 8'h00,
                         "back-to-back fetch successor");
        req_rdata = 64'h0000_0013_0000_0013;
        req_ready = 1'b1;
        #1;
        if (!fetch_ready || lsu_ready) begin
            $fatal(1, "back-to-back fetch completion was misrouted");
        end
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        fetch_valid = 1'b0;

        // A data request waiting on a completing fetch takes priority over
        // the successor sideband.  The successor remains held by the fetch
        // queue and is acquired after the LSU completes.
        fetch_valid = 1'b1;
        fetch_addr = 64'h0000_0000_0000_5000;
        wait_for_request(1'b0, 64'h5000, 64'd0, 8'h00,
                         "fetch before LSU handoff");
        fetch_next_valid = 1'b1;
        fetch_next_addr = 64'h0000_0000_0000_5008;
        lsu_valid = 1'b1;
        lsu_write = 1'b0;
        lsu_addr = 64'h0000_0000_0000_6008;
        req_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        fetch_next_valid = 1'b0;
        fetch_addr = 64'h0000_0000_0000_5008;

        if (dut.g_gen.u_bus.state_q != 2'd1 ||
            dut.g_gen.u_bus.owner_q != 1'b1 ||
            dut.g_gen.u_bus.vaddr_q != 64'h6008) begin
            $fatal(1, "LSU did not preempt fetch successor");
        end

        wait_for_request(1'b0, 64'h6008, 64'd0, 8'h00,
                         "LSU completion-edge priority");
        req_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        lsu_valid = 1'b0;

        wait_for_request(1'b0, 64'h5008, 64'd0, 8'h00,
                         "fetch held across LSU priority");
        req_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        fetch_valid = 1'b0;

        // Fetch cancel is captured at the bus boundary.  A response already
        // present on that edge may complete speculatively; the simultaneously
        // flushed frontend discards it.  No successor from the cancelled
        // stream may be admitted, and the registered cancel suppresses any
        // later response.
        fetch_valid = 1'b1;
        fetch_addr = 64'h0000_0000_0000_4000;
        wait_for_request(1'b0, 64'h4000, 64'd0, 8'h00,
                         "cancelled fetch");
        fetch_cancel = 1'b1;
        fetch_next_valid = 1'b1;
        fetch_next_addr = 64'h0000_0000_0000_4008;
        req_ready = 1'b1;
        req_rdata = 64'hdead_beef_dead_beef;
        #1;
        if (!fetch_ready)
            $fatal(1, "fetch cancel remained in same-cycle response cone");
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != 2'd0 || fetch_ready ||
            !dut.g_gen.u_bus.cancelled_q)
            $fatal(1, "registered fetch cancel admitted a successor/result");
        fetch_valid = 1'b0;
        fetch_next_valid = 1'b0;
        fetch_cancel = 1'b0;
        req_ready = 1'b0;

        // A successful walk fills the TLB. The next matching request bypasses
        // the root PTE read, while TLBI turns that entry back into a miss.
        lsu_valid = 1'b1;
        lsu_write = 1'b0;
        lsu_addr = 64'h0000_0000_4000_1234;
        lsu_priv = `RV64_PRIV_S;
        lsu_vm_mode = `RV64_SATP_MODE_SV39;
        lsu_asid = 16'h4321;
        lsu_root_ppn = 44'd1;
        @(posedge clk);
        @(negedge clk);
        lsu_vm_mode = `RV64_SATP_MODE_BARE;
        lsu_asid = 16'd0;
        lsu_root_ppn = 44'd0;
        wait_for_ptw_request(64'h1000, 64'h1008,
                             "Sv39 root PTE read");
        respond_ptw_line(64'h1008, 64'h0000_0000_4000_00c3);

        wait_for_request(1'b0, 64'h0000_0001_0000_1234,
                         64'd0, 8'h00, "translated data access");
        req_rdata = 64'h0123_4567_89ab_cdef;
        req_ready = 1'b1;
        #1;
        if (!lsu_ready || lsu_page_fault || lsu_access_fault ||
            lsu_rdata !== 64'h0123_4567_89ab_cdef) begin
            $fatal(1, "walked LSU completion was routed incorrectly");
        end
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        lsu_valid = 1'b0;

        lsu_valid = 1'b1;
        lsu_priv = `RV64_PRIV_S;
        lsu_vm_mode = `RV64_SATP_MODE_SV39;
        lsu_asid = 16'h4321;
        lsu_root_ppn = 44'd1;
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != GEN_STATE_TRANSLATE || req_valid)
            $fatal(1, "TLB hit skipped registered lookup input state");
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != GEN_STATE_TLB_RESULT || req_valid)
            $fatal(1, "TLB hit did not stop at registered result state");
        wait_for_request(1'b0, 64'h0000_0001_0000_1234,
                         64'd0, 8'h00, "TLB-hit data access");
        req_ready = 1'b1;
        #1;
        if (!lsu_ready || lsu_page_fault || lsu_access_fault) begin
            $fatal(1, "TLB-hit completion faulted");
        end
        @(posedge clk);
        @(negedge clk);
        req_ready = 1'b0;
        lsu_valid = 1'b0;

        // Invalidate a hit after the asynchronous lookup has been captured but
        // before the registered result is consumed.  The staged hit must not
        // reach ACCESS; the held LSU request must miss and restart through PTW
        // after the local invalidation pulse.
        lsu_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != GEN_STATE_TRANSLATE)
            $fatal(1, "staged-hit TLBI test did not enter lookup");
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != GEN_STATE_TLB_RESULT)
            $fatal(1, "staged-hit TLBI test did not capture result");
        tlbi = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (dut.g_gen.u_bus.state_q != GEN_STATE_TRANSLATE ||
            req_valid || lsu_ready)
            $fatal(1, "TLBI did not discard staged TLB hit");
        tlbi = 1'b0;

        // The restarted walk's PMP probe is discardable.  Local invalidation
        // must not suppress PMP combinationally or emit an ICX fence.
        while (!dut.g_gen.u_bus.ptw_pmp_valid)
            @(negedge clk);
        tlbi = 1'b1;
        #1;
        if (!dut.g_gen.u_bus.ptw_pmp_valid)
            $fatal(1, "TLBI suppressed parallel PTW PMP probe");
        if (icx_req_valid &&
            (icx_req_op == `OPENRV64_ICX_OP_FENCE))
            $fatal(1, "noncoherent generic bus emitted ICX shootdown");
        @(posedge clk);
        @(negedge clk);
        tlbi = 1'b0;

        wait_for_ptw_request(64'h1000, 64'h1008,
                             "post-TLBI root PTE read");
        tlbi = 1'b1;
        respond_ptw_line(64'h1008, 64'h0000_0000_4000_00c3);
        tlbi = 1'b0;

        wait_for_ptw_request(64'h1000, 64'h1008,
                             "TLBI restarts active walk");
        respond_ptw_line(64'h1008, 64'd0);
        #1;
        if (!lsu_ready || !lsu_page_fault || lsu_access_fault) begin
            $fatal(1, "post-TLBI invalid PTE did not page fault");
        end
        @(posedge clk);
        @(negedge clk);
        lsu_valid = 1'b0;

        $display("PASS: core bus ownership, PTW, TLB, and TLBI");
        $finish;
    end

endmodule
