`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_icx_l1i;
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
    logic tlbi;
    logic context_flush;
    logic fetch_context_change;
    logic page_screen_csr_clear;
    logic pmp_update;
    wire tlbi_busy;
    logic icache_invalidate;
    logic m_mode_prefetch_enable;
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

    wire icx_req_valid;
    logic icx_req_ready;
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
    logic icx_wdata_ready;
    logic icx_resp_valid;
    wire icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic icx_resp_error;

    wire m_axi_arvalid;
    wire [2:0] m_axi_arid;
    wire [63:0] m_axi_araddr;
    wire m_axi_rready;
    wire m_axi_awvalid;
    wire m_axi_wvalid;
    logic axi_resp_valid_q;
    logic [2:0] axi_resp_id_q;
    integer axi_read_count_q;

    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory [0:7];
    logic response_pending_q;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] response_hart_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] response_txn_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] response_source_q;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] response_data_q;
    logic hold_icx_responses;
    logic sv39_mapping_enable;
    logic held_response_valid_q [0:15];
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        held_response_hart_q [0:15];
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        held_response_source_q [0:15];
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        held_response_data_q [0:15];
    logic held_response_found;
    logic [3:0] held_response_index;
    integer icx_count_q;
    integer pte_count_q;
    integer memory_index;
    integer word_index;
    integer held_response_scan;
    integer held_response_reset;
    integer response_wait_cycles;
    integer page_screen_accept_count_q;
    integer page_screen_launch_count_q;
    integer page_screen_bypass_count_q;
    integer pmp_probe_count_q;
    logic [2:0] ooo_remaining_seen;

    function automatic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        sv39_pte_line;
        input [63:0] address;
        reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] line;
        begin
            line = '0;
            case (address)
                // Root PPN 1 -> level-one PPN 2.
                64'h1000: line[63:0] = (64'd2 << 10) | 64'h1;
                // Level-one PPN 2 -> level-zero PPN 3.
                64'h2000: line[63:0] = (64'd3 << 10) | 64'h1;
                // Map virtual page zero to physical page zero as V/R/X/A.
                64'h3000: line[63:0] = 64'h4b;
                default: line = '0;
            endcase
            sv39_pte_line = line;
        end
    endfunction

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

    openrv64_core_mtl #(
        .ENABLE_L1I(1),
        .L1I_FETCH_DATA_WIDTH(256),
        .ENABLE_L1D(1),
        .L1D_PREFETCH_ENABLE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .l1d_sleep_i(1'b0),
        .l1d_probe_hit_o(),
        .l1d_probe_valid_i(1'b0),
        .l1d_probe_ready_o(),
        .l1d_probe_addr_i(64'd0),
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
        .lsu_pipe_store_done_ready_i(1'b1),
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
        .fetch_context_change_i(fetch_context_change),
        .page_screen_csr_clear_i(page_screen_csr_clear),
        .pmp_update_i(pmp_update),
        .tlbi_busy_o(tlbi_busy),
        .store_barrier_i(1'b0),
        .icache_invalidate_i(icache_invalidate),
        .m_mode_prefetch_enable_i(m_mode_prefetch_enable),
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
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_order_o(icx_req_order),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_attr_o(icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(icx_wdata_ready),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(icx_resp_beat_index),
        .icx_resp_last_i(icx_resp_last),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error),
        .icx_resp_sc_success_i(1'b0),
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
            icx_resp_valid <= 1'b0;
            icx_resp_hart_id <= '0;
            icx_resp_txn_id <= '0;
            icx_resp_source_id <= '0;
            icx_resp_beat_index <= '0;
            icx_resp_last <= 1'b1;
            icx_resp_rdata <= '0;
            icx_resp_error <= 1'b0;
            icx_count_q <= 0;
            pte_count_q <= 0;
            axi_resp_valid_q <= 1'b0;
            axi_resp_id_q <= 3'd0;
            axi_read_count_q <= 0;
            page_screen_accept_count_q <= 0;
            page_screen_launch_count_q <= 0;
            page_screen_bypass_count_q <= 0;
            pmp_probe_count_q <= 0;
            for (held_response_reset = 0;
                 held_response_reset < 16;
                 held_response_reset = held_response_reset + 1) begin
                held_response_valid_q[held_response_reset] <= 1'b0;
                held_response_hart_q[held_response_reset] <= '0;
                held_response_source_q[held_response_reset] <= '0;
                held_response_data_q[held_response_reset] <= '0;
            end
        end else begin
            if (dut.fetch_page_screen_accept)
                page_screen_accept_count_q <=
                    page_screen_accept_count_q + 1;
            if (dut.fetch_page_screen_launch)
                page_screen_launch_count_q <=
                    page_screen_launch_count_q + 1;
            if (dut.fetch_page_screen_resp_bypass && fetch_resp_ready)
                page_screen_bypass_count_q <=
                    page_screen_bypass_count_q + 1;
            if (pmp_valid)
                pmp_probe_count_q <= pmp_probe_count_q + 1;
            if (icx_resp_valid && icx_resp_ready)
                icx_resp_valid <= 1'b0;

            if (response_pending_q && (!icx_resp_valid || icx_resp_ready)) begin
                response_pending_q <= 1'b0;
                icx_resp_valid <= 1'b1;
                icx_resp_hart_id <= response_hart_q;
                icx_resp_txn_id <= response_txn_q;
                icx_resp_source_id <= response_source_q;
                icx_resp_beat_index <= '0;
                icx_resp_last <= 1'b1;
                icx_resp_rdata <= response_data_q;
                icx_resp_error <= 1'b0;
            end

            if (!hold_icx_responses && held_response_found &&
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

            if (icx_req_valid && icx_req_ready) begin
                if (!hold_icx_responses &&
                    (response_pending_q || icx_resp_valid ||
                     held_response_found))
                    $fatal(1, "hart issued a second request before response");
                if (icx_req_hart_id != 0 || icx_req_burst_len != 0)
                    $fatal(1,
                        "native ICX read command mismatch hart=%0d op=%0d order=%0d size=%0d addr=%016x burst=%0d source=%0d",
                        icx_req_hart_id, icx_req_op, icx_req_order,
                        icx_req_size, icx_req_addr, icx_req_burst_len,
                        icx_req_source_id);
                if (icx_req_source_id == `OPENRV64_ICX_SOURCE_PTW &&
                    icx_req_op == `OPENRV64_ICX_OP_FENCE) begin
                    if (icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                        icx_req_order != `OPENRV64_ICX_ORDER_ACQ_REL ||
                        icx_req_size != 0 || icx_req_addr != 0 ||
                        icx_req_attr != `OPENRV64_ICX_ATTR_NONE)
                        $fatal(1, "malformed PTW shootdown fence");
                end else if (icx_req_op != `OPENRV64_ICX_OP_READ ||
                             icx_req_order !=
                                `OPENRV64_ICX_ORDER_NONE ||
                             icx_req_size != 3'd6 ||
                             icx_req_addr[5:0] != 0) begin
                    $fatal(1,
                        "native ICX read command mismatch hart=%0d op=%0d order=%0d size=%0d addr=%016x burst=%0d source=%0d",
                        icx_req_hart_id, icx_req_op, icx_req_order,
                        icx_req_size, icx_req_addr, icx_req_burst_len,
                        icx_req_source_id);
                end else if (icx_req_source_id ==
                    `OPENRV64_ICX_SOURCE_ICACHE) begin
                    if (icx_req_kind != `OPENRV64_ICX_KIND_FETCH ||
                        (icx_req_attr &
                         (`OPENRV64_ICX_ATTR_CACHEABLE |
                          `OPENRV64_ICX_ATTR_EXECUTABLE)) !=
                         (`OPENRV64_ICX_ATTR_CACHEABLE |
                          `OPENRV64_ICX_ATTR_EXECUTABLE))
                        $fatal(1, "native L1I ICX command mismatch");
                    icx_count_q <= icx_count_q + 1;
                end else if (icx_req_source_id ==
                             `OPENRV64_ICX_SOURCE_PTW) begin
                    if (icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                        icx_req_attr !=
                            (`OPENRV64_ICX_ATTR_CACHEABLE |
                             `OPENRV64_ICX_ATTR_IDEMPOTENT))
                        $fatal(1, "native PTE ICX command mismatch");
                    pte_count_q <= pte_count_q + 1;
                end else begin
                    $fatal(1, "unexpected native ICX source");
                end
                if (hold_icx_responses) begin
                    if (icx_req_source_id !=
                        `OPENRV64_ICX_SOURCE_ICACHE)
                        $fatal(1,
                               "held response phase admitted non-L1I traffic");
                    if (held_response_valid_q[icx_req_txn_id])
                        $fatal(1, "L1I reused an outstanding transaction ID");
                    held_response_valid_q[icx_req_txn_id] <= 1'b1;
                    held_response_hart_q[icx_req_txn_id] <=
                        icx_req_hart_id;
                    held_response_source_q[icx_req_txn_id] <=
                        icx_req_source_id;
                    held_response_data_q[icx_req_txn_id] <=
                        memory[icx_req_addr[8:6]];
                end else begin
                    response_pending_q <= 1'b1;
                    response_hart_q <= icx_req_hart_id;
                    response_txn_q <= icx_req_txn_id;
                    response_source_q <= icx_req_source_id;
                    if (sv39_mapping_enable &&
                        (icx_req_source_id ==
                         `OPENRV64_ICX_SOURCE_PTW))
                        response_data_q <= sv39_pte_line(icx_req_addr);
                    else
                        response_data_q <= memory[icx_req_addr[8:6]];
                end
            end

            if (axi_resp_valid_q && m_axi_rready)
                axi_resp_valid_q <= 1'b0;
            if (m_axi_arvalid) begin
                $fatal(1, "enabled L1I/PTW emitted residual AXI read");
            end

            if (icx_wdata_valid)
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

    task automatic pulse_context_flush;
        integer cycles;
        begin
            @(negedge clk);
            context_flush = 1'b1;
            @(posedge clk);
            @(negedge clk);
            context_flush = 1'b0;
            cycles = 0;
            while (tlbi_busy && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (tlbi_busy)
                $fatal(1, "translation context flush did not drain");
        end
    endtask

    task automatic pulse_tlbi;
        integer cycles;
        begin
            @(negedge clk);
            tlbi = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tlbi = 1'b0;
            cycles = 0;
            while (tlbi_busy && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (tlbi_busy)
                $fatal(1, "SFENCE.VMA translation invalidation did not drain");
        end
    endtask

    task automatic pulse_pmp_update;
        begin
            @(negedge clk);
            pmp_update = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pmp_update = 1'b0;
        end
    endtask

    task automatic pulse_fetch_context_change;
        begin
            @(negedge clk);
            fetch_context_change = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fetch_context_change = 1'b0;
        end
    endtask

    task automatic pulse_page_screen_csr_clear;
        begin
            @(negedge clk);
            page_screen_csr_clear = 1'b1;
            @(posedge clk);
            @(negedge clk);
            page_screen_csr_clear = 1'b0;
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

    task automatic wait_for_icx_count;
        input integer expected_count;
        input [8*48-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while ((icx_count_q != expected_count) && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (icx_count_q != expected_count)
                $fatal(1, "%0s count=%0d expected=%0d", label,
                       icx_count_q, expected_count);
        end
    endtask

    integer before_count;
    integer screen_before_count;
    integer screen_launch_before_count;
    integer screen_bypass_before_count;
    integer pmp_before_count;
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
        tlbi = 1'b0;
        context_flush = 1'b0;
        fetch_context_change = 1'b0;
        page_screen_csr_clear = 1'b0;
        pmp_update = 1'b0;
        icache_invalidate = 1'b0;
        m_mode_prefetch_enable = 1'b0;
        icache_prefetch_valid = 1'b0;
        icache_prefetch_taken_addr = 64'd0;
        icache_prefetch_fallthrough_addr = 64'd0;
        icache_age_valid = 3'b000;
        icache_age_addr = 192'd0;
        hold_icx_responses = 1'b0;
        sv39_mapping_enable = 1'b0;
        fetch_resp_ready = 1'b1;
        pmp_allow = 1'b1;
        icx_req_ready = 1'b1;
        icx_wdata_ready = 1'b1;
        for (memory_index = 0; memory_index < 8;
             memory_index = memory_index + 1)
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory[memory_index][word_index*64 +: 64] =
                    64'h1000_0000_0000_0000 + memory_index*8 + word_index;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        before_count = icx_count_q;
        issue_fetch(64'h20, memory[0][511:256], 1'b0,
                    "upper-half cold miss");
        wait_for_icx_count(before_count + 1,
                           "M/BARE cold demand");
        repeat (20) @(negedge clk);
        if ((icx_count_q - before_count) != 1)
            $fatal(1, "M/BARE demand issued a next-line prefetch");
        before_count = icx_count_q;
        screen_before_count = page_screen_accept_count_q;
        screen_launch_before_count = page_screen_launch_count_q;
        screen_bypass_before_count = page_screen_bypass_count_q;
        pmp_before_count = pmp_probe_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "lower-half resident hit");
        if (icx_count_q != before_count)
            $fatal(1, "same-line hit escaped onto ICX");
        if (page_screen_accept_count_q != screen_before_count + 1 ||
            page_screen_launch_count_q != screen_launch_before_count + 1 ||
            page_screen_bypass_count_q != screen_bypass_before_count + 1)
            $fatal(1, "resident page-screen fetch missed fast path");
        if (pmp_probe_count_q != pmp_before_count)
            $fatal(1, "page-screen hit entered PMP arbitration");

        // A resident hit marks its tree path most-recently-used.  With all
        // tree bits clear, entry zero is initially the victim; touching it
        // redirects replacement into entry two's subtree.
        @(negedge clk);
        dut.fetch_page_plru_q = 3'b000;
        screen_before_count = page_screen_accept_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "fetch page-screen PLRU hit");
        if (page_screen_accept_count_q != screen_before_count + 1 ||
            dut.fetch_page_plru_q != 3'b011 ||
            dut.fetch_page_plru_victim_index != 2'd2)
            $fatal(1,
                   "fetch page-screen PLRU did not update state=%b victim=%0d",
                   dut.fetch_page_plru_q,
                   dut.fetch_page_plru_victim_index);

        // A later translation/PMP response for an already resident VPN can
        // occur when multiple fetch slots missed before the first proof was
        // installed.  It must refresh the matching entry, not consume the
        // replacement cursor and create a duplicate.
        @(negedge clk);
        dut.fetch_page_valid_q = 4'b0001;
        dut.fetch_page_vpn_q[0] = 52'd0;
        dut.fetch_page_ppn_q[0] = 27'd0;
        dut.fetch_page_plru_q = 3'b000;
        force dut.fetch_page_screen_fill = 1'b1;
        force dut.pmp_fetch_resp_vaddr = 64'd0;
        force dut.pmp_fetch_resp_paddr = 64'd0;
        @(posedge clk);
        @(negedge clk);
        release dut.fetch_page_screen_fill;
        release dut.pmp_fetch_resp_vaddr;
        release dut.pmp_fetch_resp_paddr;
        if (dut.fetch_page_valid_q != 4'b0001 ||
            dut.fetch_page_ppn_q[0] != 27'd0 ||
            dut.fetch_page_plru_q != 3'b011)
            $fatal(1,
                   "duplicate fetch proof allocated slot valid=%b ppn=%h plru=%b",
                   dut.fetch_page_valid_q, dut.fetch_page_ppn_q[0],
                   dut.fetch_page_plru_q);

        // Invalid entries have priority over PLRU.  Once full, a hit on the
        // old victim must redirect a simultaneous-later replacement away
        // from that entry.  Entry two is the resulting victim here.
        @(negedge clk);
        dut.fetch_page_valid_q = 4'b1111;
        dut.fetch_page_vpn_q[0] = 52'd0;
        dut.fetch_page_vpn_q[1] = 52'd1;
        dut.fetch_page_vpn_q[2] = 52'd2;
        dut.fetch_page_vpn_q[3] = 52'd3;
        dut.fetch_page_ppn_q[0] = 27'd0;
        dut.fetch_page_ppn_q[1] = 27'd1;
        dut.fetch_page_ppn_q[2] = 27'd2;
        dut.fetch_page_ppn_q[3] = 27'd3;
        dut.fetch_page_plru_q = 3'b000;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "fetch page-screen PLRU protection");
        force dut.fetch_page_screen_fill = 1'b1;
        force dut.pmp_fetch_resp_vaddr = 64'h4000;
        force dut.pmp_fetch_resp_paddr = 64'h4000;
        @(posedge clk);
        @(negedge clk);
        release dut.fetch_page_screen_fill;
        release dut.pmp_fetch_resp_vaddr;
        release dut.pmp_fetch_resp_paddr;
        if (dut.fetch_page_valid_q != 4'b1111 ||
            dut.fetch_page_vpn_q[0] != 52'd0 ||
            dut.fetch_page_vpn_q[2] != 52'd4 ||
            dut.fetch_page_plru_q != 3'b110)
            $fatal(1,
                   "fetch page-screen PLRU replacement valid=%b vpn0=%h vpn2=%h plru=%b",
                   dut.fetch_page_valid_q, dut.fetch_page_vpn_q[0],
                   dut.fetch_page_vpn_q[2], dut.fetch_page_plru_q);

        // A data-access permission change clears only the LSU screen.  A fast
        // fetch response already accepted under the current instruction-side
        // proof remains visible, and the fetch proof itself remains cached.
        fetch_resp_ready = 1'b0;
        push_fetch_only(64'h00);
        word_index = 0;
        while (!dut.fetch_resp_hold_valid_q && word_index < 100) begin
            @(negedge clk);
            word_index = word_index + 1;
        end
        if (!dut.fetch_resp_hold_valid_q)
            $fatal(1, "failed to hold page-screen response before CSR clear");
        pulse_page_screen_csr_clear();
        if (!dut.fetch_resp_hold_valid_q || dut.fetch_count_q != 1)
            $fatal(1,
                "data-permission clear dropped accepted fetch hold=%b count=%0d",
                dut.fetch_resp_hold_valid_q, dut.fetch_count_q);
        fetch_resp_ready = 1'b1;
        expect_fetch_only(64'h00, memory[0][255:0],
                          "accepted fetch across CSR screen clear");

        // The fetch screen is unaffected by SUM/MXR/MPRV/MPP changes.
        screen_before_count = page_screen_accept_count_q;
        pmp_before_count = pmp_probe_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "post-data-permission-change resident hit");
        if (page_screen_accept_count_q != screen_before_count + 1 ||
            pmp_probe_count_q != pmp_before_count)
            $fatal(1, "data permission change revoked fetch proof");

        // Hold L1I invalidation active so a screen hit is admitted but
        // cannot launch.  Revoking the screen proof must discard that job;
        // it must never fall back through translation/PMP or reach fetch.
        fetch_resp_ready = 1'b0;
        @(negedge clk);
        icache_invalidate = 1'b1;
        screen_before_count = page_screen_accept_count_q;
        pmp_before_count = pmp_probe_count_q;
        push_fetch_only(64'h00);
        if (page_screen_accept_count_q != screen_before_count + 1 ||
            !dut.fetch_fast_found_r)
            $fatal(1, "failed to queue page-screen invalidation job");
        pulse_tlbi();
        @(negedge clk);
        icache_invalidate = 1'b0;
        repeat (30) @(negedge clk);
        if (pmp_probe_count_q != pmp_before_count)
            $fatal(1, "invalidated page-screen job entered PMP");
        if (fetch_resp_valid || dut.fetch_count_q != 0)
            $fatal(1, "invalidated page-screen job reached fetch");
        fetch_resp_ready = 1'b1;

        // Privilege transitions invalidate only the cheap page screen.  The
        // resident L1I line remains usable, but the next fetch must re-enter
        // translation/PMP before the screen is refilled at cursor zero.
        pulse_fetch_context_change();
        screen_before_count = page_screen_accept_count_q;
        pmp_before_count = pmp_probe_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "post-context-change checked resident hit");
        if (page_screen_accept_count_q != screen_before_count)
            $fatal(1, "context change retained a page-screen entry");
        if (pmp_probe_count_q != pmp_before_count + 1)
            $fatal(1,
                   "context change PMP probes before=%0d after=%0d",
                   pmp_before_count, pmp_probe_count_q);
        if (dut.fetch_page_valid_q != 4'b0001 ||
            dut.fetch_page_plru_q != 3'b011)
            $fatal(1,
                   "page-screen refill did not update PLRU valid=%b state=%b",
                   dut.fetch_page_valid_q, dut.fetch_page_plru_q);
        before_count = icx_count_q;

        // Revoke the page-screen proof on the exact cycle that a resident
        // fast-path response returns.  The L1I response must be consumed as
        // a cancelled completion; it must not strand the fetch slot in
        // WAIT_L1I after the response transaction is gone.
        push_fetch_only(64'h00);
        word_index = 0;
        while (!(dut.l1i_resp_valid &&
                 dut.fetch_page_screen_resp_bypass) &&
               word_index < 100) begin
            @(negedge clk);
            word_index = word_index + 1;
        end
        if (!(dut.l1i_resp_valid &&
              dut.fetch_page_screen_resp_bypass))
            $fatal(1, "did not observe resident page-screen response");
        tlbi = 1'b1;
        @(posedge clk);
        @(negedge clk);
        tlbi = 1'b0;
        word_index = 0;
        while (tlbi_busy && word_index < 400) begin
            @(negedge clk);
            word_index = word_index + 1;
        end
        repeat (10) @(negedge clk);
        if (tlbi_busy || dut.fetch_count_q != 0)
            $fatal(1,
                "coincident SFENCE/page-screen response stranded fetch");

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
        if (icx_count_q != before_count)
            $fatal(1, "resident multi-hit traffic duplicated prefetch");

        // Four distinct cold lines must cross ICX before any response is
        // released.  Return transaction IDs in descending order and verify
        // that tagged frontend completions are visible in completion order.
        pulse_invalidate();
        before_count = icx_count_q;
        hold_icx_responses = 1'b1;
        push_fetch_only(64'h00);
        push_fetch_only(64'h40);
        push_fetch_only(64'h80);
        push_fetch_only(64'hc0);
        wait_for_icx_count(before_count + 4,
                           "four concurrent L1I demand misses");
        if (!held_response_valid_q[0] ||
            !held_response_valid_q[1] ||
            !held_response_valid_q[2] ||
            !held_response_valid_q[3])
            $fatal(1, "L1I did not occupy four independent MSHRs");
        fetch_resp_ready = 1'b0;
        hold_icx_responses = 1'b0;
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
        before_count = icx_count_q;
        hold_icx_responses = 1'b1;
        push_fetch_only(64'h00);
        push_fetch_only(64'h20);
        wait_for_icx_count(before_count + 1,
                           "same-line demand miss merge");
        repeat (20) @(negedge clk);
        if (icx_count_q != before_count + 1)
            $fatal(1, "same-line demand fetches allocated two MSHRs");
        hold_icx_responses = 1'b0;
        expect_fetch_only(64'h00, memory[0][255:0],
                          "merged miss response lower");
        expect_fetch_only(64'h20, memory[0][511:256],
                          "merged miss response upper");
        repeat (20) @(negedge clk);
        if (icx_count_q != before_count + 1)
            $fatal(1, "merged M/BARE demand issued a prefetch");

        // A resident hit behind an unresolved miss must bypass it all the way
        // back to fetch.  Keeping the miss response held proves this is not
        // merely multiple ICX requests followed by ordered completion.
        pulse_invalidate();
        before_count = icx_count_q;
        issue_fetch(64'h100, memory[4][255:0], 1'b0,
                    "prime hit-under-miss resident line");
        wait_for_icx_count(before_count + 1,
                           "hit-under-miss M/BARE prime");
        before_count = icx_count_q;
        hold_icx_responses = 1'b1;
        push_fetch_only(64'h180);
        wait_for_icx_count(before_count + 1,
                           "hit-under-miss outstanding line");
        push_fetch_only(64'h100);
        expect_fetch_only(64'h100, memory[4][255:0],
                          "resident hit bypassed outstanding miss");
        if (!held_response_found)
            $fatal(1, "hit-under-miss test lost held miss response");
        hold_icx_responses = 1'b0;
        expect_fetch_only(64'h180, memory[6][255:0],
                          "outstanding miss completed after bypass hit");
        repeat (20) @(negedge clk);
        if (icx_count_q != before_count + 1)
            $fatal(1, "hit-under-miss M/BARE demand issued a prefetch");

        pulse_invalidate();
        before_count = icx_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "prime pre-fence resident line");
        wait_for_icx_count(before_count + 1,
                           "pre-fence M/BARE prime");
        stale_lower = memory[0][255:0];
        memory[0][255:0] = 256'hface_cafe;
        before_count = icx_count_q;
        issue_fetch(64'h00, stale_lower, 1'b0, "pre-fence stale hit");
        if (icx_count_q != before_count)
            $fatal(1, "resident stale hit duplicated next-line prefetch");
        pulse_invalidate();
        before_count = icx_count_q;
        issue_fetch(64'h00, memory[0][255:0], 1'b0,
                    "post-fence refill");
        wait_for_icx_count(before_count + 1,
                           "post-fence M/BARE refill");

        pmp_allow = 1'b0;
        pulse_pmp_update();
        before_count = icx_count_q;
        issue_fetch(64'h00, 256'd0, 1'b1,
                    "PMP denial on resident line");
        if (icx_count_q != before_count)
            $fatal(1, "PMP-denied hit issued ICX traffic");
        pmp_allow = 1'b1;
        pulse_pmp_update();

        before_count = icx_count_q;
        fork
            issue_fetch(64'h80, memory[2][255:0], 1'b0,
                        "refill concurrent with FENCE.I");
            begin
                wait (icx_count_q == before_count + 1);
                pulse_invalidate();
            end
        join
        if ((icx_count_q - before_count) != 1)
            $fatal(1, "concurrent miss was not one ICX line");
        before_count = icx_count_q;
        issue_fetch(64'h80, memory[2][255:0], 1'b0,
                    "held invalidation refetch");
        wait_for_icx_count(before_count + 1,
                           "held invalidation M/BARE refetch");

        pulse_invalidate();
        before_count = icx_count_q;
        pulse_prefetch_pair(64'hffff_ffff_800f_0980,
                            64'hffff_ffff_800f_09c0);
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count)
            $fatal(1, "M/BARE admitted stale high-half branch prefetch");

        pulse_prefetch_pair(64'h100, 64'h180);
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count)
            $fatal(1, "M/BARE admitted branch-path prefetch");
        before_count = icx_count_q;
        issue_fetch(64'h100, memory[4][255:0], 1'b0,
                    "taken path demand miss");
        issue_fetch(64'h1a0, memory[6][511:256], 1'b0,
                    "fallthrough path demand miss");
        wait_for_icx_count(before_count + 2,
                           "M/BARE branch-path demand misses");

        pulse_invalidate();
        before_count = icx_count_q;
        pulse_prefetch_pair(64'h200, 64'h220);
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count)
            $fatal(1, "M/BARE admitted same-line branch prefetch");

        // Sv39 retains both automatic next-line and explicit branch-path
        // prefetching.  This positive check prevents the M/BARE guards from
        // degenerating into a global prefetch disable.
        pulse_invalidate();
        fetch_priv = `RV64_PRIV_S;
        fetch_vm_mode = `RV64_SATP_MODE_SV39;
        fetch_root_ppn = 44'd1;
        sv39_mapping_enable = 1'b1;
        before_count = icx_count_q;
        memory_index = pte_count_q;
        issue_fetch(64'h20, memory[0][511:256], 1'b0,
                    "Sv39 demand with next-line prefetch");
        wait_for_icx_count(before_count + 2,
                           "Sv39 demand plus next-line prefetch");
        if (pte_count_q != memory_index + 3)
            $fatal(1, "Sv39 demand did not perform one three-level walk");

        pulse_invalidate();
        before_count = icx_count_q;
        pulse_prefetch_pair(64'h100, 64'h180);
        wait_for_icx_count(before_count + 2,
                           "Sv39 taken/fallthrough prefetch");
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count + 2)
            $fatal(1, "Sv39 branch prefetch count changed after drain");

        // Speculative Sv39 faults are consumed by L1I.  Their PTE lines use
        // the shared ICX path, but they neither issue I-cache line fills nor
        // create an architectural fetch response.
        pulse_invalidate();
        pulse_context_flush();
        sv39_mapping_enable = 1'b0;
        before_count = icx_count_q;
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
            icx_count_q != before_count || fetch_resp_valid)
            $fatal(1, "speculative translation fault became architectural");
        fetch_priv = `RV64_PRIV_M;
        fetch_vm_mode = `RV64_SATP_MODE_BARE;
        fetch_root_ppn = 44'd0;

        // The opt-in path admits M/BARE prefetching while the default-off
        // phase above continues to prove the containment behavior.
        m_mode_prefetch_enable = 1'b1;
        pulse_invalidate();
        before_count = icx_count_q;
        pulse_prefetch_pair(64'h100, 64'h180);
        wait_for_icx_count(before_count + 2,
                           "enabled M/BARE branch-path prefetch");
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count + 2)
            $fatal(1, "enabled M/BARE branch prefetch count changed");

        pulse_invalidate();
        before_count = icx_count_q;
        issue_fetch(64'h20, memory[0][511:256], 1'b0,
                    "enabled M/BARE demand with next-line prefetch");
        wait_for_icx_count(before_count + 2,
                           "enabled M/BARE demand plus next-line prefetch");
        repeat (30) @(negedge clk);
        if (icx_count_q != before_count + 2)
            $fatal(1, "enabled M/BARE next-line prefetch count changed");

        $display("PASS: native ICX VIPT L1I refill/hit/Sv39/opt-in-M-prefetch/PMP/FENCE.I");
        $finish;
    end

endmodule
