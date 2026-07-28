`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_ccx_l1i;
    logic clk;
    logic rst_n;
    logic fetch_req_valid;
    wire fetch_req_ready;
    logic [63:0] fetch_req_addr;
    logic [1:0] fetch_priv;
    logic [3:0] fetch_vm_mode;
    logic [15:0] fetch_asid;
    logic [43:0] fetch_root_ppn;
    logic fetch_cancel;
    logic icache_invalidate;
    logic icache_prefetch_valid;
    logic [63:0] icache_prefetch_taken_addr;
    logic [63:0] icache_prefetch_fallthrough_addr;
    logic [2:0] icache_age_valid;
    logic [191:0] icache_age_addr;
    wire fetch_resp_valid;
    logic fetch_resp_ready;
    wire [63:0] fetch_resp_addr;
    wire [255:0] fetch_resp_data;
    wire fetch_resp_access_fault;
    wire fetch_resp_page_fault;

    logic pmp_allow;
    wire pmp_valid;
    wire [63:0] pmp_addr;
    wire [1:0] pmp_priv;
    wire [2:0] pmp_size;
    wire pmp_write;
    wire pmp_exec;

    wire ccx_req_valid;
    logic ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    wire ccx_wdata_valid;
    logic ccx_wdata_ready;
    logic ccx_resp_valid;
    wire ccx_resp_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    logic ccx_resp_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    logic ccx_resp_error;

    wire m_axi_arvalid;
    wire [2:0] m_axi_arid;
    wire [63:0] m_axi_araddr;
    wire m_axi_rready;
    wire m_axi_awvalid;
    wire m_axi_wvalid;
    logic axi_resp_valid_q;
    logic [2:0] axi_resp_id_q;
    integer axi_read_count_q;

    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] memory [0:7];
    logic response_pending_q;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] response_hart_q;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] response_txn_q;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] response_source_q;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] response_data_q;
    logic hold_ccx_responses;
    logic held_response_valid_q [0:15];
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        held_response_hart_q [0:15];
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        held_response_source_q [0:15];
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        held_response_data_q [0:15];
    logic held_response_found;
    logic [3:0] held_response_index;
    integer ccx_count_q;
    integer pte_count_q;
    integer memory_index;
    integer word_index;
    integer held_response_scan;
    integer held_response_reset;
    integer response_wait_cycles;
    logic [2:0] ooo_remaining_seen;

    always_comb begin
        held_response_found = 1'b0;
        held_response_index = 4'd0;
        for (held_response_scan = 0;
             held_response_scan < 16;
             held_response_scan = held_response_scan + 1) begin
            if (held_response_valid_q[held_response_scan]) begin
                held_response_found = 1'b1;
                held_response_index = held_response_scan[3:0];
            end
        end
    end

    openrv64_core_ccx_bus #(
        .ENABLE_L1I(1),
        .ENABLE_L1D(1),
        .L1D_PREFETCH_ENABLE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_req_valid_i(fetch_req_valid),
        .fetch_req_ready_o(fetch_req_ready),
        .fetch_req_addr_i(fetch_req_addr),
        .fetch_req_stash_i(1'b0),
        .fetch_req_demand_i(1'b1),
        .fetch_req_priv_i(fetch_priv),
        .fetch_req_vm_mode_i(fetch_vm_mode),
        .fetch_req_asid_i(fetch_asid),
        .fetch_req_root_ppn_i(fetch_root_ppn),
        .fetch_req_sum_i(1'b0),
        .fetch_req_mxr_i(1'b0),
        .fetch_cancel_i(fetch_cancel),
        .fetch_cancel_stash_i(1'b1),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(fetch_resp_ready),
        .fetch_resp_addr_o(fetch_resp_addr),
        .fetch_resp_data_o(fetch_resp_data),
        .fetch_resp_access_fault_o(fetch_resp_access_fault),
        .fetch_resp_page_fault_o(fetch_resp_page_fault),
        .lsu_valid_i(1'b0),
        .lsu_lock_i(1'b0),
        .lsu_write_i(1'b0),
        .lsu_addr_i(64'd0),
        .lsu_wdata_i(64'd0),
        .lsu_wstrb_i(8'd0),
        .lsu_size_i(3'd0),
        .lsu_priv_i(`RV64_PRIV_M),
        .lsu_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_asid_i(16'd0),
        .lsu_root_ppn_i(44'd0),
        .lsu_sum_i(1'b0),
        .lsu_mxr_i(1'b0),
        .lsu_pipe_req_valid_i(1'b0),
        .lsu_pipe_req_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .lsu_pipe_req_xlate_only_i(1'b0),
        .lsu_pipe_req_physical_i(1'b0),
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
        .lsu_pipe_store_done_ready_i(1'b1),
        .lsu_xlate_req_valid_i(1'b0),
        .lsu_xlate_req_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .lsu_xlate_req_write_i(1'b0),
        .lsu_xlate_req_vaddr_i(64'd0),
        .lsu_xlate_req_priv_i(`RV64_PRIV_M),
        .lsu_xlate_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_xlate_req_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .lsu_xlate_req_root_ppn_i({`RV64_SATP_PPN_WIDTH{1'b0}}),
        .lsu_xlate_req_sum_i(1'b0),
        .lsu_xlate_req_mxr_i(1'b0),
        .lsu_xlate_resp_ready_i(1'b1),
        .tlbi_i(1'b0),
        .icache_invalidate_i(icache_invalidate),
        .icache_prefetch_valid_i(icache_prefetch_valid),
        .icache_prefetch_taken_addr_i(icache_prefetch_taken_addr),
        .icache_prefetch_fallthrough_addr_i(
            icache_prefetch_fallthrough_addr),
        .icache_age_valid_i(icache_age_valid),
        .icache_age_addr_i(icache_age_addr),
        .pmp_valid_o(pmp_valid),
        .pmp_addr_o(pmp_addr),
        .pmp_priv_o(pmp_priv),
        .pmp_size_o(pmp_size),
        .pmp_write_o(pmp_write),
        .pmp_exec_o(pmp_exec),
        .pmp_allow_i(pmp_allow),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_order_o(ccx_req_order),
        .ccx_req_kind_o(ccx_req_kind),
        .ccx_req_attr_o(ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(ccx_req_burst_len),
        .ccx_wdata_valid_o(ccx_wdata_valid),
        .ccx_wdata_ready_i(ccx_wdata_ready),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_beat_index_i(ccx_resp_beat_index),
        .ccx_resp_last_i(ccx_resp_last),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_error_i(ccx_resp_error),
        .ccx_resp_sc_success_i(1'b0),
        .m_axi_arid_o(m_axi_arid),
        .m_axi_araddr_o(m_axi_araddr),
        .m_axi_arvalid_o(m_axi_arvalid),
        .m_axi_arready_i(1'b1),
        .m_axi_rid_i(axi_resp_id_q),
        .m_axi_rdata_i(256'd0),
        .m_axi_rresp_i(2'b00),
        .m_axi_rlast_i(1'b1),
        .m_axi_rvalid_i(axi_resp_valid_q),
        .m_axi_rready_o(m_axi_rready),
        .m_axi_awvalid_o(m_axi_awvalid),
        .m_axi_awready_i(1'b1),
        .m_axi_wvalid_o(m_axi_wvalid),
        .m_axi_wready_i(1'b1),
        .m_axi_bid_i(3'd7),
        .m_axi_bresp_i(2'b00),
        .m_axi_bvalid_i(1'b0)
    );

    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_pending_q <= 1'b0;
            response_hart_q <= '0;
            response_txn_q <= '0;
            response_source_q <= '0;
            response_data_q <= '0;
            ccx_resp_valid <= 1'b0;
            ccx_resp_hart_id <= '0;
            ccx_resp_txn_id <= '0;
            ccx_resp_source_id <= '0;
            ccx_resp_beat_index <= '0;
            ccx_resp_last <= 1'b1;
            ccx_resp_rdata <= '0;
            ccx_resp_error <= 1'b0;
            ccx_count_q <= 0;
            pte_count_q <= 0;
            axi_resp_valid_q <= 1'b0;
            axi_resp_id_q <= 3'd0;
            axi_read_count_q <= 0;
            for (held_response_reset = 0;
                 held_response_reset < 16;
                 held_response_reset = held_response_reset + 1) begin
                held_response_valid_q[held_response_reset] <= 1'b0;
                held_response_hart_q[held_response_reset] <= '0;
                held_response_source_q[held_response_reset] <= '0;
                held_response_data_q[held_response_reset] <= '0;
            end
        end else begin
            if (ccx_resp_valid && ccx_resp_ready)
                ccx_resp_valid <= 1'b0;

            if (response_pending_q && (!ccx_resp_valid || ccx_resp_ready)) begin
                response_pending_q <= 1'b0;
                ccx_resp_valid <= 1'b1;
                ccx_resp_hart_id <= response_hart_q;
                ccx_resp_txn_id <= response_txn_q;
                ccx_resp_source_id <= response_source_q;
                ccx_resp_beat_index <= '0;
                ccx_resp_last <= 1'b1;
                ccx_resp_rdata <= response_data_q;
                ccx_resp_error <= 1'b0;
            end

            if (!hold_ccx_responses && held_response_found &&
                !response_pending_q) begin
                held_response_valid_q[held_response_index] <= 1'b0;
                response_pending_q <= 1'b1;
                response_hart_q <=
                    held_response_hart_q[held_response_index];
                response_txn_q <= held_response_index;
                response_source_q <=
                    held_response_source_q[held_response_index];
                response_data_q <=
                    held_response_data_q[held_response_index];
            end

            if (ccx_req_valid && ccx_req_ready) begin
                if (!hold_ccx_responses &&
                    (response_pending_q || ccx_resp_valid ||
                     held_response_found))
                    $fatal(1, "hart issued a second request before response");
                if (ccx_req_hart_id != 0 ||
                    ccx_req_op != `OPENRV64_CCX_OP_READ ||
                    ccx_req_order != `OPENRV64_CCX_ORDER_NONE ||
                    ccx_req_size != 3'd6 || ccx_req_addr[5:0] != 0 ||
                    ccx_req_burst_len != 0)
                    $fatal(1, "native CCX read command mismatch");
                if (ccx_req_source_id ==
                    `OPENRV64_CCX_SOURCE_ICACHE) begin
                    if (ccx_req_kind != `OPENRV64_CCX_KIND_FETCH ||
                        (ccx_req_attr &
                         (`OPENRV64_CCX_ATTR_CACHEABLE |
                          `OPENRV64_CCX_ATTR_EXECUTABLE)) !=
                         (`OPENRV64_CCX_ATTR_CACHEABLE |
                          `OPENRV64_CCX_ATTR_EXECUTABLE))
                        $fatal(1, "native L1I CCX command mismatch");
                    ccx_count_q <= ccx_count_q + 1;
                end else if (ccx_req_source_id ==
                             `OPENRV64_CCX_SOURCE_PTW) begin
                    if (ccx_req_kind != `OPENRV64_CCX_KIND_PTE ||
                        ccx_req_attr !=
                            (`OPENRV64_CCX_ATTR_CACHEABLE |
                             `OPENRV64_CCX_ATTR_IDEMPOTENT))
                        $fatal(1, "native PTE CCX command mismatch");
                    pte_count_q <= pte_count_q + 1;
                end else begin
                    $fatal(1, "unexpected native CCX source");
                end
                if (hold_ccx_responses) begin
                    if (ccx_req_source_id !=
                        `OPENRV64_CCX_SOURCE_ICACHE)
                        $fatal(1,
                               "held response phase admitted non-L1I traffic");
                    if (held_response_valid_q[ccx_req_txn_id])
                        $fatal(1, "L1I reused an outstanding transaction ID");
                    held_response_valid_q[ccx_req_txn_id] <= 1'b1;
                    held_response_hart_q[ccx_req_txn_id] <=
                        ccx_req_hart_id;
                    held_response_source_q[ccx_req_txn_id] <=
                        ccx_req_source_id;
                    held_response_data_q[ccx_req_txn_id] <=
                        memory[ccx_req_addr[8:6]];
                end else begin
                    response_pending_q <= 1'b1;
                    response_hart_q <= ccx_req_hart_id;
                    response_txn_q <= ccx_req_txn_id;
                    response_source_q <= ccx_req_source_id;
                    response_data_q <= memory[ccx_req_addr[8:6]];
                end
            end

            if (axi_resp_valid_q && m_axi_rready)
                axi_resp_valid_q <= 1'b0;
            if (m_axi_arvalid) begin
                $fatal(1, "enabled L1I/PTW emitted residual AXI read");
            end

            if (ccx_wdata_valid)
                $fatal(1, "L1I emitted write data");
            if (m_axi_awvalid || m_axi_wvalid)
                $fatal(1, "L1I emitted an AXI write");
        end
    end

    task automatic issue_fetch(
        input [63:0] address,
        input [255:0] expected_data,
        input expected_access_fault,
        input [8*40-1:0] label
    );
        integer cycles;
        begin
            @(negedge clk);
            while (!fetch_req_ready)
                @(negedge clk);
            fetch_req_addr = address;
            fetch_req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fetch_req_valid = 1'b0;
            fetch_req_addr = 64'd0;

            cycles = 0;
            while (!fetch_resp_valid && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "%0s timed out", label);
            if (fetch_resp_addr !== address ||
                fetch_resp_access_fault !== expected_access_fault ||
                fetch_resp_page_fault ||
                (!expected_access_fault && fetch_resp_data !== expected_data))
                $fatal(1, "%0s response mismatch", label);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic push_fetch_only(input [63:0] address);
        begin
            @(negedge clk);
            while (!fetch_req_ready)
                @(negedge clk);
            fetch_req_addr = address;
            fetch_req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fetch_req_valid = 1'b0;
            fetch_req_addr = 64'd0;
        end
    endtask

    task automatic expect_fetch_only(
        input [63:0] address,
        input [255:0] expected_data,
        input [8*40-1:0] label
    );
        integer cycles;
        begin
            cycles = 0;
            while (!fetch_resp_valid && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "%0s timed out", label);
            if (fetch_resp_addr !== address ||
                fetch_resp_access_fault || fetch_resp_page_fault ||
                fetch_resp_data !== expected_data)
                $fatal(1, "%0s response mismatch", label);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic pulse_invalidate;
        integer cycles;
        begin
            @(negedge clk);
            icache_invalidate = 1'b1;
            @(posedge clk);
            @(negedge clk);
            icache_invalidate = 1'b0;
            cycles = 0;
            while (dut.l1i_invalidate_pending_q && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (dut.l1i_invalidate_pending_q)
                $fatal(1, "L1I invalidation did not drain");
        end
    endtask

    task automatic pulse_prefetch_pair;
        input [63:0] taken_address;
        input [63:0] fallthrough_address;
        begin
            @(negedge clk);
            icache_prefetch_taken_addr = taken_address;
            icache_prefetch_fallthrough_addr = fallthrough_address;
            icache_prefetch_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            icache_prefetch_valid = 1'b0;
            icache_prefetch_taken_addr = 64'd0;
            icache_prefetch_fallthrough_addr = 64'd0;
        end
    endtask

    task automatic wait_for_ccx_count;
        input integer expected_count;
        input [8*48-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while ((ccx_count_q != expected_count) && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (ccx_count_q != expected_count)
                $fatal(1, "%0s count=%0d expected=%0d", label,
                       ccx_count_q, expected_count);
        end
    endtask

    integer before_count;
    logic [255:0] stale_lower;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        fetch_req_valid = 1'b0;
        fetch_req_addr = 64'd0;
        fetch_priv = `RV64_PRIV_M;
        fetch_vm_mode = `RV64_SATP_MODE_BARE;
        fetch_asid = 16'd0;
        fetch_root_ppn = 44'd0;
        fetch_cancel = 1'b0;
        icache_invalidate = 1'b0;
        icache_prefetch_valid = 1'b0;
        icache_prefetch_taken_addr = 64'd0;
        icache_prefetch_fallthrough_addr = 64'd0;
        icache_age_valid = 3'b000;
        icache_age_addr = 192'd0;
        hold_ccx_responses = 1'b0;
        fetch_resp_ready = 1'b1;
        pmp_allow = 1'b1;
        ccx_req_ready = 1'b1;
        ccx_wdata_ready = 1'b1;
        for (memory_index = 0; memory_index < 8;
             memory_index = memory_index + 1)
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory[memory_index][word_index*64 +: 64] =
                    64'h1000_0000_0000_0000 + memory_index*8 + word_index;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        before_count = ccx_count_q;
        issue_fetch(64'h20, memory[0][511:256], 1'b0,
                    "upper-half cold miss");
        wait_for_ccx_count(before_count + 2,
                           "cold demand plus next-line prefetch");
        repeat (20) @(negedge clk);
        if ((ccx_count_q - before_count) != 2)
            $fatal(1, "demand did not issue exactly one next-line prefetch");
        before_count = ccx_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "lower-half resident hit");
        if (ccx_count_q != before_count)
            $fatal(1, "same-line hit escaped onto CCX");

        // Hold frontend responses while four resident requests enter.  The
        // bus and L1I must accept all four, then preserve request order.
        fetch_resp_ready = 1'b0;
        push_fetch_only(64'h00);
        push_fetch_only(64'h20);
        push_fetch_only(64'h00);
        push_fetch_only(64'h20);
        if (dut.fetch_count_q != 4)
            $fatal(1, "L1I did not retain four outstanding fetches");
        fetch_resp_ready = 1'b1;
        expect_fetch_only(64'h00, memory[0][255:0],
                          "multi-hit response 0");
        expect_fetch_only(64'h20, memory[0][511:256],
                          "multi-hit response 1");
        expect_fetch_only(64'h00, memory[0][255:0],
                          "multi-hit response 2");
        expect_fetch_only(64'h20, memory[0][511:256],
                          "multi-hit response 3");
        if (ccx_count_q != before_count)
            $fatal(1, "resident multi-hit traffic duplicated prefetch");

        // Four distinct cold lines must cross CCX before any response is
        // released.  Return transaction IDs in descending order and verify
        // that tagged frontend completions are visible in completion order.
        pulse_invalidate();
        before_count = ccx_count_q;
        hold_ccx_responses = 1'b1;
        push_fetch_only(64'h00);
        push_fetch_only(64'h40);
        push_fetch_only(64'h80);
        push_fetch_only(64'hc0);
        wait_for_ccx_count(before_count + 4,
                           "four concurrent L1I demand misses");
        if (!held_response_valid_q[0] ||
            !held_response_valid_q[1] ||
            !held_response_valid_q[2] ||
            !held_response_valid_q[3])
            $fatal(1, "L1I did not occupy four independent MSHRs");
        fetch_resp_ready = 1'b0;
        hold_ccx_responses = 1'b0;
        while (!fetch_resp_valid)
            @(negedge clk);
        repeat (12) begin
            @(negedge clk);
            if (!fetch_resp_valid || fetch_resp_addr !== 64'hc0 ||
                fetch_resp_data !== memory[3][255:0])
                $fatal(1,
                       "backpressured out-of-order response was not stable");
        end
        fetch_resp_ready = 1'b1;
        expect_fetch_only(64'hc0, memory[3][255:0],
                          "out-of-order miss response 3");
        // Once the held response is consumed, the fetch completion arbiter
        // may choose any of the other already-complete slots.  Require exact,
        // duplicate-free tagged delivery instead of imposing request order.
        ooo_remaining_seen = 3'b000;
        repeat (3) begin
            response_wait_cycles = 0;
            while (!fetch_resp_valid && response_wait_cycles < 200) begin
                @(negedge clk);
                response_wait_cycles = response_wait_cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "remaining out-of-order response timed out");
            if (fetch_resp_access_fault || fetch_resp_page_fault)
                $fatal(1, "remaining out-of-order response faulted");
            case (fetch_resp_addr)
                64'h00: begin
                    if (ooo_remaining_seen[0] ||
                        fetch_resp_data !== memory[0][255:0])
                        $fatal(1,
                               "bad or duplicate out-of-order response 0");
                    ooo_remaining_seen[0] = 1'b1;
                end
                64'h40: begin
                    if (ooo_remaining_seen[1] ||
                        fetch_resp_data !== memory[1][255:0])
                        $fatal(1,
                               "bad or duplicate out-of-order response 1");
                    ooo_remaining_seen[1] = 1'b1;
                end
                64'h80: begin
                    if (ooo_remaining_seen[2] ||
                        fetch_resp_data !== memory[2][255:0])
                        $fatal(1,
                               "bad or duplicate out-of-order response 2");
                    ooo_remaining_seen[2] = 1'b1;
                end
                default:
                    $fatal(1, "unexpected out-of-order response address");
            endcase
            @(posedge clk);
            @(negedge clk);
        end
        if (ooo_remaining_seen != 3'b111)
            $fatal(1, "out-of-order response set incomplete");

        pulse_invalidate();
        before_count = ccx_count_q;
        hold_ccx_responses = 1'b1;
        push_fetch_only(64'h00);
        push_fetch_only(64'h20);
        wait_for_ccx_count(before_count + 1,
                           "same-line demand miss merge");
        repeat (20) @(negedge clk);
        if (ccx_count_q != before_count + 1)
            $fatal(1, "same-line demand fetches allocated two MSHRs");
        hold_ccx_responses = 1'b0;
        expect_fetch_only(64'h00, memory[0][255:0],
                          "merged miss response lower");
        expect_fetch_only(64'h20, memory[0][511:256],
                          "merged miss response upper");
        wait_for_ccx_count(before_count + 2,
                           "merged demand next-line prefetch");

        // A resident hit behind an unresolved miss must bypass it all the way
        // back to fetch.  Keeping the miss response held proves this is not
        // merely multiple CCX requests followed by ordered completion.
        pulse_invalidate();
        before_count = ccx_count_q;
        issue_fetch(64'h100, memory[4][255:0], 1'b0,
                    "prime hit-under-miss resident line");
        wait_for_ccx_count(before_count + 2,
                           "hit-under-miss prime and next line");
        before_count = ccx_count_q;
        hold_ccx_responses = 1'b1;
        push_fetch_only(64'h180);
        wait_for_ccx_count(before_count + 1,
                           "hit-under-miss outstanding line");
        push_fetch_only(64'h100);
        expect_fetch_only(64'h100, memory[4][255:0],
                          "resident hit bypassed outstanding miss");
        if (!held_response_found)
            $fatal(1, "hit-under-miss test lost held miss response");
        hold_ccx_responses = 1'b0;
        expect_fetch_only(64'h180, memory[6][255:0],
                          "outstanding miss completed after bypass hit");
        wait_for_ccx_count(before_count + 2,
                           "hit-under-miss next-line prefetch");

        pulse_invalidate();
        before_count = ccx_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "prime pre-fence resident line");
        wait_for_ccx_count(before_count + 2,
                           "pre-fence prime and next line");
        stale_lower = memory[0][255:0];
        memory[0][255:0] = 256'hface_cafe;
        before_count = ccx_count_q;
        issue_fetch(64'h00, stale_lower, 1'b0, "pre-fence stale hit");
        if (ccx_count_q != before_count)
            $fatal(1, "resident stale hit duplicated next-line prefetch");
        pulse_invalidate();
        before_count = ccx_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "post-fence refill");
        wait_for_ccx_count(before_count + 2,
                           "post-fence refill plus next line");

        pmp_allow = 1'b0;
        before_count = ccx_count_q;
        issue_fetch(64'h00, 256'd0, 1'b1,
                    "PMP denial on resident line");
        if (ccx_count_q != before_count)
            $fatal(1, "PMP-denied hit issued CCX traffic");
        pmp_allow = 1'b1;

        before_count = ccx_count_q;
        fork
            issue_fetch(64'h80, memory[2][255:0], 1'b0,
                        "refill concurrent with FENCE.I");
            begin
                wait (ccx_count_q == before_count + 1);
                pulse_invalidate();
            end
        join
        if ((ccx_count_q - before_count) != 1)
            $fatal(1, "concurrent miss was not one CCX line");
        before_count = ccx_count_q;
        issue_fetch(64'h80, memory[2][255:0], 1'b0,
                    "held invalidation refetch");
        wait_for_ccx_count(before_count + 2,
                           "held invalidation refetch plus next line");

        pulse_invalidate();
        before_count = ccx_count_q;
        pulse_prefetch_pair(64'h100, 64'h180);
        wait_for_ccx_count(before_count + 2,
                           "taken/fallthrough prefetch");
        before_count = ccx_count_q;
        issue_fetch(64'h100, memory[4][255:0], 1'b0,
                    "taken prefetch demand hit");
        issue_fetch(64'h1a0, memory[6][511:256], 1'b0,
                    "fallthrough prefetch demand hit");
        wait_for_ccx_count(before_count + 2,
                           "branch-path demand next-line prefetches");

        pulse_invalidate();
        before_count = ccx_count_q;
        pulse_prefetch_pair(64'h200, 64'h220);
        wait_for_ccx_count(before_count + 1,
                           "same-line branch prefetch collapse");
        repeat (30) @(negedge clk);
        if (ccx_count_q != before_count + 1)
            $fatal(1, "same-line branch paths issued duplicate fills");

        // Speculative Sv39 faults are consumed by L1I.  Their PTE lines use
        // the shared CCX path, but they neither issue I-cache line fills nor
        // create an architectural fetch response.
        pulse_invalidate();
        fetch_priv = `RV64_PRIV_S;
        fetch_vm_mode = `RV64_SATP_MODE_SV39;
        before_count = ccx_count_q;
        memory_index = pte_count_q;
        pulse_prefetch_pair(64'h1000, 64'h2000);
        word_index = 0;
        while ((pte_count_q != memory_index + 2) &&
               word_index < 400) begin
            @(negedge clk);
            word_index = word_index + 1;
        end
        repeat (20) @(negedge clk);
        if (pte_count_q != memory_index + 2 ||
            ccx_count_q != before_count || fetch_resp_valid)
            $fatal(1, "speculative translation fault became architectural");
        fetch_priv = `RV64_PRIV_M;
        fetch_vm_mode = `RV64_SATP_MODE_BARE;

        $display("PASS: native CCX VIPT L1I refill/hit/prefetch/PMP/FENCE.I");
        $finish;
    end

endmodule
