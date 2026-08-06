`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

module tb_ptw;

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    logic clk;
    logic rst_n;
    logic invalidate;
    logic shootdown_ready;
    wire invalidate_busy;

    logic req_valid;
    wire req_ready;
    logic [63:0] req_vaddr;
    logic [1:0] req_access;
    logic [1:0] req_priv;
    logic [3:0] req_vm_mode;
    logic [15:0] req_asid;
    logic [43:0] req_root_ppn;
    logic req_sum;
    logic req_mxr;

    wire resp_valid;
    logic resp_ready;
    wire [63:0] resp_paddr;
    wire resp_page_fault;
    wire resp_access_fault;
    wire resp_invalidated;
    wire resp_global;
    wire [1:0] resp_level;
    wire resp_readable;
    wire resp_writable;
    wire resp_executable;
    wire resp_user;
    wire resp_accessed;
    wire resp_dirty;

    wire pmp_valid;
    wire [63:0] pmp_addr;

    wire icx_req_valid;
    wire icx_req_ready;
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
    wire icx_resp_valid;
    wire icx_resp_ready;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    reg icx_resp_pending_q;
    reg [63:0] icx_resp_line_addr_q;
    reg icx_resp_error_q;

    reg [63:0] page_memory [0:8191];
    logic inject_mem_error;
    logic [63:0] mem_error_addr;
    logic mem_allow;
    logic suppress_response;
    integer memory_index;
    integer memory_reads;
    integer shootdowns;
    integer reads_before;
    integer root_a_reads;
    integer middle_a_reads;

    assign icx_req_ready = mem_allow && !icx_resp_pending_q;
    assign icx_resp_valid = icx_resp_pending_q && !suppress_response;
    integer response_word;
    always @* begin
        icx_resp_rdata = {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        for (response_word = 0; response_word < 8;
             response_word = response_word + 1)
            icx_resp_rdata[response_word*64 +: 64] =
                page_memory[(icx_resp_line_addr_q >> 3) + response_word];
    end

    openrv64_bus_ptw #(
        .PTE_CACHE_ENTRIES(4),
        .ICX_TIMEOUT_CYCLES(8)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .invalidate_i(invalidate),
        .invalidate_busy_o(invalidate_busy),
        .shootdown_ready_i(shootdown_ready),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_vaddr_i(req_vaddr),
        .req_access_i(req_access),
        .req_priv_i(req_priv),
        .req_vm_mode_i(req_vm_mode),
        .req_asid_i(req_asid),
        .req_root_ppn_i(req_root_ppn),
        .req_sum_i(req_sum),
        .req_mxr_i(req_mxr),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_paddr_o(resp_paddr),
        .resp_page_fault_o(resp_page_fault),
        .resp_access_fault_o(resp_access_fault),
        .resp_invalidated_o(resp_invalidated),
        .resp_global_o(resp_global),
        .resp_level_o(resp_level),
        .resp_readable_o(resp_readable),
        .resp_writable_o(resp_writable),
        .resp_executable_o(resp_executable),
        .resp_user_o(resp_user),
        .resp_accessed_o(resp_accessed),
        .resp_dirty_o(resp_dirty),
        .pmp_valid_o(pmp_valid),
        .pmp_ready_i(pmp_valid),
        .pmp_addr_o(pmp_addr),
        .pmp_allow_i(1'b1),
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
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i('0),
        .icx_resp_txn_id_i('0),
        .icx_resp_source_id_i(`OPENRV64_ICX_SOURCE_PTW),
        .icx_resp_beat_index_i('0),
        .icx_resp_last_i(1'b1),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error_q)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            memory_reads <= 0;
            root_a_reads <= 0;
            middle_a_reads <= 0;
            icx_resp_pending_q <= 1'b0;
            icx_resp_line_addr_q <= 64'd0;
            icx_resp_error_q <= 1'b0;
            shootdowns <= 0;
        end else begin
            if (icx_req_valid && icx_req_ready) begin
                if (icx_req_source_id != `OPENRV64_ICX_SOURCE_PTW ||
                    icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                    icx_req_burst_len != 0 || icx_req_lock)
                    $fatal(1, "invalid PTW ICX request envelope");
                if (icx_req_op == `OPENRV64_ICX_OP_READ) begin
                    if (icx_req_size != 3'd6 ||
                        icx_req_attr !=
                            (`OPENRV64_ICX_ATTR_CACHEABLE |
                             `OPENRV64_ICX_ATTR_IDEMPOTENT))
                        $fatal(1, "invalid PTW PTE-line read");
                end else if (icx_req_op == `OPENRV64_ICX_OP_FENCE) begin
                    if (icx_req_size != 3'd0 ||
                        icx_req_attr != `OPENRV64_ICX_ATTR_NONE ||
                        icx_req_order != `OPENRV64_ICX_ORDER_ACQ_REL)
                        $fatal(1, "invalid PTW generation shootdown");
                    shootdowns <= shootdowns + 1;
                end else begin
                    $fatal(1, "unexpected PTW ICX operation");
                end
                icx_resp_pending_q <= 1'b1;
                icx_resp_line_addr_q <= icx_req_addr;
                icx_resp_error_q <=
                    (icx_req_op == `OPENRV64_ICX_OP_READ) &&
                    inject_mem_error &&
                    (mem_error_addr[63:6] == icx_req_addr[63:6]);
            end
            if (icx_resp_valid && icx_resp_ready)
                icx_resp_pending_q <= 1'b0;
        end
        if (rst_n && icx_req_valid && icx_req_ready &&
            (icx_req_op == `OPENRV64_ICX_OP_READ)) begin
            memory_reads <= memory_reads + 1;
            if (icx_req_addr == 64'h0000_0000_0000_8000)
                root_a_reads <= root_a_reads + 1;
            if (icx_req_addr == 64'h0000_0000_0000_9000)
                middle_a_reads <= middle_a_reads + 1;
        end
    end

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [63:0] make_pte;
        input [43:0] ppn;
        input valid;
        input readable;
        input writable;
        input executable;
        input user_page;
        input global_entry;
        input accessed;
        input dirty;
        begin
            make_pte = 64'd0;
            make_pte[`RV64_PTE_PPN_BITS] = ppn;
            make_pte[`RV64_PTE_V_BIT] = valid;
            make_pte[`RV64_PTE_R_BIT] = readable;
            make_pte[`RV64_PTE_W_BIT] = writable;
            make_pte[`RV64_PTE_X_BIT] = executable;
            make_pte[`RV64_PTE_U_BIT] = user_page;
            make_pte[`RV64_PTE_G_BIT] = global_entry;
            make_pte[`RV64_PTE_A_BIT] = accessed;
            make_pte[`RV64_PTE_D_BIT] = dirty;
        end
    endfunction

    task automatic write_pte;
        input [43:0] table_ppn;
        input [8:0] vpn;
        input [63:0] pte;
        integer index;
        begin
            index = (table_ppn * 512) + vpn;
            page_memory[index] = pte;
        end
    endtask

    task automatic map_4k;
        input [63:0] vaddr;
        input [43:0] root_ppn;
        input [43:0] level1_ppn;
        input [43:0] level0_ppn;
        input [43:0] leaf_ppn;
        input readable;
        input writable;
        input executable;
        input user_page;
        input accessed;
        input dirty;
        input parent_global;
        begin
            write_pte(root_ppn, vaddr[38:30],
                      make_pte(level1_ppn, 1'b1, 1'b0, 1'b0, 1'b0,
                               1'b0, parent_global, 1'b0, 1'b0));
            write_pte(level1_ppn, vaddr[29:21],
                      make_pte(level0_ppn, 1'b1, 1'b0, 1'b0, 1'b0,
                               1'b0, 1'b0, 1'b0, 1'b0));
            write_pte(level0_ppn, vaddr[20:12],
                      make_pte(leaf_ppn, 1'b1, readable, writable,
                               executable, user_page, 1'b0,
                               accessed, dirty));
        end
    endtask

    task automatic issue_request;
        input [63:0] vaddr;
        input [1:0] access_kind;
        input [1:0] privilege;
        input [3:0] vm_mode;
        input [43:0] root_ppn;
        input sum;
        input mxr;
        input [63:0] expected_paddr;
        input expected_page_fault;
        input expected_access_fault;
        input [1:0] expected_level;
        input expected_global;
        input [8*48-1:0] label;
        integer cycles;
        begin
            @(negedge clk);
            if (!req_ready) begin
                $fatal(1, "%0s: PTW was not ready", label);
            end
            req_vaddr = vaddr;
            req_access = access_kind;
            req_priv = privilege;
            req_vm_mode = vm_mode;
            req_root_ppn = root_ppn;
            req_sum = sum;
            req_mxr = mxr;
            req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;

            cycles = 0;
            while (!resp_valid && cycles < 64) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!resp_valid ||
                resp_invalidated ||
                resp_page_fault !== expected_page_fault ||
                resp_access_fault !== expected_access_fault ||
                (!expected_page_fault && !expected_access_fault &&
                 (resp_paddr !== expected_paddr ||
                  resp_level !== expected_level ||
                  resp_global !== expected_global))) begin
                $fatal(1,
                    "%0s: paddr/pf/af/level/global=%016x/%b/%b/%0d/%b",
                    label, resp_paddr, resp_page_fault,
                    resp_access_fault, resp_level, resp_global);
            end

            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    task automatic flush_translation_caches;
        integer expected_shootdowns;
        integer cycles;
        begin
            expected_shootdowns = shootdowns + 1;
            @(negedge clk);
            invalidate = 1'b1;
            @(posedge clk);
            @(negedge clk);
            invalidate = 1'b0;
            cycles = 0;
            while (((shootdowns < expected_shootdowns) || !req_ready) &&
                   (cycles < 32)) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if ((shootdowns < expected_shootdowns) || !req_ready)
                $fatal(1, "PTW shootdown did not complete");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        invalidate = 1'b0;
        shootdown_ready = 1'b1;
        req_valid = 1'b0;
        req_vaddr = 64'd0;
        req_access = ACCESS_READ;
        req_priv = `RV64_PRIV_S;
        req_vm_mode = `RV64_SATP_MODE_SV39;
        req_asid = 16'h1234;
        req_root_ppn = 44'd1;
        req_sum = 1'b0;
        req_mxr = 1'b0;
        resp_ready = 1'b0;
        inject_mem_error = 1'b0;
        mem_error_addr = 64'd0;
        mem_allow = 1'b1;
        suppress_response = 1'b0;
        root_a_reads = 0;
        middle_a_reads = 0;

        for (memory_index = 0;
             memory_index < 8192;
             memory_index = memory_index + 1) begin
            page_memory[memory_index] = 64'd0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Invalidation is immediate, but integration may hold the downstream
        // ordered shootdown behind an L1D posted-store drain.
        shootdown_ready = 1'b0;
        @(negedge clk);
        invalidate = 1'b1;
        #1;
        if (!invalidate_busy)
            $fatal(1, "PTW invalidation barrier was not immediate");
        @(posedge clk);
        @(negedge clk);
        invalidate = 1'b0;
        repeat (4) @(negedge clk);
        if ((shootdowns != 0) || !invalidate_busy || req_ready)
            $fatal(1, "PTW shootdown escaped its ordering gate");
        shootdown_ready = 1'b1;
        memory_index = 0;
        while ((invalidate_busy || (shootdowns != 1)) &&
               (memory_index < 32)) begin
            @(negedge clk);
            memory_index = memory_index + 1;
        end
        if (invalidate_busy || (shootdowns != 1))
            $fatal(1, "PTW gated shootdown did not complete");

        // Shootdown wins over admission.  A request held beside invalidate
        // must not observe a false handshake and may be retried afterward.
        @(negedge clk);
        req_valid = 1'b1;
        invalidate = 1'b1;
        #1;
        if (req_ready)
            $fatal(1, "PTW admitted a new walk during shootdown");
        @(posedge clk);
        @(negedge clk);
        invalidate = 1'b0;
        memory_index = 0;
        while (!req_ready && memory_index < 32) begin
            @(negedge clk);
            memory_index = memory_index + 1;
        end
        if (!req_ready)
            $fatal(1, "PTW did not reopen admission after shootdown");
        req_valid = 1'b0;

        map_4k(64'h0000_0000_1234_5678,
               44'd1, 44'd2, 44'd3, 44'h80000,
               1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_8000_0678,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "4 KiB translation and inherited global");

        reads_before = memory_reads;
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_8000_0678,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "non-leaf PTE cache hit");
        if ((memory_reads - reads_before) != 1)
            $fatal(1, "cached non-leaf path used %0d memory reads",
                   memory_reads - reads_before);

        flush_translation_caches();
        reads_before = memory_reads;
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_8000_0678,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "shootdown flushes non-leaf PTE cache");
        if ((memory_reads - reads_before) != 3)
            $fatal(1, "post-shootdown walk used %0d memory reads",
                   memory_reads - reads_before);

        write_pte(44'd2, 9'h100,
                  make_pte(44'h90000, 1'b1,
                           1'b1, 1'b0, 1'b0, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_2000_1234,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_9000_1234,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_2M, 1'b1,
                      "2 MiB superpage");

        write_pte(44'd1, 9'h001,
                  make_pte(44'h100000, 1'b1,
                           1'b1, 1'b0, 1'b1, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_4000_1234,
                      ACCESS_EXEC, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0001_0000_1234,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_1G, 1'b0,
                      "1 GiB superpage");

        write_pte(44'd1, 9'h002,
                  make_pte(44'h100001, 1'b1,
                           1'b1, 1'b0, 1'b0, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_8000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "misaligned superpage fault");

        issue_request(64'h0000_0080_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "noncanonical virtual address");

        map_4k(64'h0000_0000_3000_0456,
               44'd1, 44'd2, 44'd3, 44'ha0000,
               1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0);
        flush_translation_caches();
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM blocks supervisor user-page load");
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b1, 1'b0,
                      64'h0000_0000_a000_0456,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM permits supervisor user-page load");
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_EXEC, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b1, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM never permits supervisor user-page execute");

        map_4k(64'h0000_0000_3200_0789,
               44'd1, 44'd2, 44'd3, 44'hb0000,
               1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_3200_0789,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "MXR disabled on execute-only page");
        issue_request(64'h0000_0000_3200_0789,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b1,
                      64'h0000_0000_b000_0789,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "MXR enabled on execute-only page");

        map_4k(64'h0000_0000_3400_0123,
               44'd1, 44'd2, 44'd3, 44'hc0000,
               1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
        issue_request(64'h0000_0000_3400_0123,
                      ACCESS_WRITE, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "dirty-bit write fault");
        issue_request(64'h0000_0000_3400_0123,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_c000_0123,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "dirty-bit read succeeds");

        // A shootdown terminates the walk.  If a PTE transaction has already
        // escaped, the walker drains that one transaction but must not consume
        // it, request another level, or repopulate the cache.
        flush_translation_caches();
        map_4k(64'h0000_0000_0100_0123,
               44'd4, 44'd5, 44'd6, 44'hd0000,
               1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        reads_before = memory_reads;
        mem_allow = 1'b0;
        @(negedge clk);
        req_vaddr = 64'h0000_0000_0100_0123;
        req_access = ACCESS_READ;
        req_priv = `RV64_PRIV_S;
        req_vm_mode = `RV64_SATP_MODE_SV39;
        req_root_ppn = 44'd4;
        req_sum = 1'b0;
        req_mxr = 1'b0;
        req_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        memory_index = 0;
        while (!icx_req_valid && memory_index < 4) begin
            @(negedge clk);
            memory_index = memory_index + 1;
        end
        if (!icx_req_valid)
            $fatal(1, "shootdown test did not start a ICX PTE request");
        invalidate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        invalidate = 1'b0;
        if (!icx_req_valid)
            $fatal(1, "shootdown abandoned an outstanding ICX request");
        mem_allow = 1'b1;
        while (!resp_valid)
            @(negedge clk);
        #1;
        if (!resp_invalidated || resp_page_fault || resp_access_fault)
            $fatal(1, "shootdown did not return an invalidated walk");
        if ((memory_reads - reads_before) != 1)
            $fatal(1, "terminated walk consumed %0d PTE transactions",
                   memory_reads - reads_before);
        resp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        resp_ready = 1'b0;
        memory_index = 0;
        while (!req_ready && memory_index < 32) begin
            @(negedge clk);
            memory_index = memory_index + 1;
        end
        if (!req_ready)
            $fatal(1, "terminated-walk shootdown did not complete");

        reads_before = memory_reads;
        issue_request(64'h0000_0000_0100_0123,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd4, 1'b0, 1'b0,
                      64'h0000_0000_d000_0123,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "terminated walk does not refill PTE cache");
        if ((memory_reads - reads_before) != 3)
            $fatal(1, "post-termination walk used %0d memory reads",
                   memory_reads - reads_before);

        // Four entries hold two paths.  Bringing in a third path must evict
        // the oldest middle-level entries before an older root-level entry.
        flush_translation_caches();
        map_4k(64'h0000_0000_0000_0000,
               44'd8, 44'd9, 44'd14, 44'h100,
               1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd8, 1'b0, 1'b0,
                      64'h0000_0000_0010_0000,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "weighted PTE path A");
        map_4k(64'h0000_0000_0000_0000,
               44'd10, 44'd11, 44'd15, 44'h200,
               1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd10, 1'b0, 1'b0,
                      64'h0000_0000_0020_0000,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "weighted PTE path B");
        map_4k(64'h0000_0000_0000_0000,
               44'd12, 44'd13, 44'd6, 44'h300,
               1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd12, 1'b0, 1'b0,
                      64'h0000_0000_0030_0000,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "weighted PTE path C");
        reads_before = root_a_reads;
        memory_index = middle_a_reads;
        issue_request(64'h0000_0000_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd8, 1'b0, 1'b0,
                      64'h0000_0000_0010_0000,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "weighted replacement retains root PTE");
        if (root_a_reads != reads_before)
            $fatal(1, "weighted replacement evicted a root-level PTE");
        if (middle_a_reads != (memory_index + 1))
            $fatal(1, "weighted replacement retained lower-level PTE");

        mem_error_addr = 64'h0000_0000_0000_1000;
        inject_mem_error = 1'b1;
        flush_translation_caches();
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b0, 1'b1,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "PTE physical access fault");
        inject_mem_error = 1'b0;

        // A ICX endpoint which never accepts a PTE request must become a
        // precise access fault instead of wedging translation forever.
        flush_translation_caches();
        mem_allow = 1'b0;
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b0, 1'b1,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "PTE ICX request timeout");
        mem_allow = 1'b1;

        // Once a request has been accepted, timeout reports the fault but
        // retains a tombstone until the late response has been drained.
        flush_translation_caches();
        suppress_response = 1'b1;
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b0, 1'b1,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "PTE ICX response timeout");
        if (req_ready)
            $fatal(1, "PTW reused a timed-out transaction before drain");
        suppress_response = 1'b0;
        memory_index = 0;
        while (!req_ready && memory_index < 32) begin
            @(negedge clk);
            memory_index = memory_index + 1;
        end
        if (!req_ready)
            $fatal(1, "PTW did not recover after late-response drain");

        issue_request(64'hdead_beef_cafe_0123,
                      ACCESS_READ, `RV64_PRIV_M,
                      `RV64_SATP_MODE_BARE, 44'd0, 1'b0, 1'b0,
                      64'hdead_beef_cafe_0123,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "Bare identity translation");

        $display("PASS: Sv39 PTW, weighted non-leaf cache, shootdown, faults, and ICX timeouts");
        $finish;
    end

    wire unused_ptw_sidebands = |{
        pmp_addr, icx_req_hart_id, icx_req_txn_id,
        icx_req_source_id, icx_req_op, icx_req_lock,
        icx_req_order, icx_req_kind, icx_req_attr,
        icx_req_size, icx_req_burst_len
    };
    wire unused_leaf_attrs = |{
        resp_readable, resp_writable, resp_executable,
        resp_user, resp_accessed, resp_dirty
    };

endmodule
