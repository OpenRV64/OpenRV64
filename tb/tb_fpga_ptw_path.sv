`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

module tb_fpga_ptw_path;

`ifdef VERILATOR
    localparam integer PTW_PTE_CACHE_ENTRIES = 0;
`else
    localparam integer PTW_PTE_CACHE_ENTRIES = 4;
`endif

    localparam logic [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam logic [63:0] MEMORY_BYTES = 64'h0000_0000_0040_0000;
    localparam logic [63:0] ROOT_ADDR = MEMORY_BASE + 64'h1000;
    localparam logic [63:0] LEVEL1_ADDR = MEMORY_BASE + 64'h2000;
    localparam logic [63:0] LEVEL0_ADDR = MEMORY_BASE + 64'h3000;
    localparam logic [63:0] TARGET_ADDR = MEMORY_BASE + 64'h0020_0000;
    localparam logic [63:0] TEST_VADDR = 64'h0000_0000_4020_0234;

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    always #5 clk = ~clk;

    logic invalidate;
    logic invalidate_busy;
    logic ptw_req_valid;
    logic ptw_req_ready;
    logic ptw_resp_valid;
    logic [63:0] ptw_resp_paddr;
    logic ptw_resp_page_fault;
    logic ptw_resp_access_fault;
    logic ptw_resp_invalidated;
    logic ptw_resp_global;
    logic [`RV64_PAGE_LEVEL_WIDTH-1:0] ptw_resp_level;
    logic ptw_resp_readable;
    logic ptw_resp_writable;
    logic ptw_resp_executable;
    logic ptw_resp_user;
    logic ptw_resp_accessed;
    logic ptw_resp_dirty;
    logic pmp_valid;
    logic [63:0] pmp_addr;

    logic icx_req_valid;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic icx_req_lock;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    logic [2:0] icx_req_size;
    logic [63:0] icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;

    logic icx_resp_valid;
    logic icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic icx_resp_error;
    logic icx_resp_sc_success;

    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;

    openrv64_bus_ptw #(
        // Icarus needs one active set because it gives the zero-entry PTW's
        // constant-folded @* cache block no sensitivity list. Verilator uses
        // the FPGA system's exact zero-entry configuration.
        .PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .ICX_TIMEOUT_CYCLES(1000),
        .HART_ID(4'd0),
        .TXN_ID(4'd0)
    ) u_ptw (
        .clk(clk),
        .rst_n(reset_n),
        .invalidate_i(invalidate),
        .invalidate_busy_o(invalidate_busy),
        .shootdown_ready_i(1'b1),
        .req_valid_i(ptw_req_valid),
        .req_ready_o(ptw_req_ready),
        .req_vaddr_i(TEST_VADDR),
        .req_access_i(2'd2),
        .req_priv_i(`RV64_PRIV_S),
        .req_vm_mode_i(`RV64_SATP_MODE_SV39),
        .req_asid_i('0),
        .req_root_ppn_i(ROOT_ADDR[55:12]),
        .req_sum_i(1'b0),
        .req_mxr_i(1'b0),
        .resp_valid_o(ptw_resp_valid),
        .resp_ready_i(1'b1),
        .resp_paddr_o(ptw_resp_paddr),
        .resp_page_fault_o(ptw_resp_page_fault),
        .resp_access_fault_o(ptw_resp_access_fault),
        .resp_invalidated_o(ptw_resp_invalidated),
        .resp_global_o(ptw_resp_global),
        .resp_level_o(ptw_resp_level),
        .resp_readable_o(ptw_resp_readable),
        .resp_writable_o(ptw_resp_writable),
        .resp_executable_o(ptw_resp_executable),
        .resp_user_o(ptw_resp_user),
        .resp_accessed_o(ptw_resp_accessed),
        .resp_dirty_o(ptw_resp_dirty),
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
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(icx_resp_beat_index),
        .icx_resp_last_i(icx_resp_last),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error)
    );

    openrv64_fpga_scalar_icx_arbiter #(
        .MEMORY_BASE(MEMORY_BASE),
        .MEMORY_BYTES(MEMORY_BYTES)
    ) u_arbiter (
        .clk_i(clk),
        .reset_i(!reset_n),
        .core_mem_valid_i(1'b0),
        .core_mem_ready_o(),
        .core_mem_write_i(1'b0),
        .core_mem_addr_i(64'd0),
        .core_mem_wdata_i(64'd0),
        .core_mem_wstrb_i(8'd0),
        .core_mem_rdata_o(),
        .core_mem_error_o(),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error)
    );

    logic [63:0] memory [0:524287];
    logic memory_pending_q;
    logic [1:0] memory_delay_q;
    logic [63:0] memory_addr_q;
    integer memory_request_count;

    assign mem_ready = memory_pending_q && (memory_delay_q == 0);
    assign mem_rdata = memory[memory_addr_q[21:3]];
    assign mem_error = 1'b0;

    always @(posedge clk) begin
        if (!reset_n) begin
            memory_pending_q <= 1'b0;
            memory_delay_q <= 2'd0;
            memory_addr_q <= 64'd0;
            memory_request_count <= 0;
        end else if (!memory_pending_q && mem_valid) begin
            if (mem_write)
                $fatal(1, "PTW path unexpectedly wrote memory");
            memory_pending_q <= 1'b1;
            memory_delay_q <= 2'd1;
            memory_addr_q <= mem_addr;
            memory_request_count <= memory_request_count + 1;
        end else if (memory_pending_q && (memory_delay_q != 0)) begin
            memory_delay_q <= memory_delay_q - 2'd1;
        end else if (mem_ready) begin
            memory_pending_q <= 1'b0;
        end
    end

    wire [8:0] vpn2 = TEST_VADDR[38:30];
    wire [8:0] vpn1 = TEST_VADDR[29:21];
    wire [8:0] vpn0 = TEST_VADDR[20:12];
    logic [63:0] expected_paddr;

    initial begin : watchdog
        repeat (5000) @(posedge clk);
        $fatal(1,
               "timeout ptw=%0d/%0d arb=%0d word=%0d requests=%0d",
               u_ptw.state_q, u_ptw.backend_state_q,
               u_arbiter.state_q, u_arbiter.ptw_word_q,
               memory_request_count);
    end

    initial begin
        invalidate = 1'b0;
        ptw_req_valid = 1'b0;
        expected_paddr = TARGET_ADDR + {52'd0, TEST_VADDR[11:0]};

        // Three-level Sv39 tables. All PTEs intentionally occupy nonzero
        // lanes within their 64-byte lines so line assembly is observable.
        memory[(ROOT_ADDR - MEMORY_BASE + vpn2*8) >> 3] =
            ((LEVEL1_ADDR >> 12) << 10) | 64'h001;
        memory[(LEVEL1_ADDR - MEMORY_BASE + vpn1*8) >> 3] =
            ((LEVEL0_ADDR >> 12) << 10) | 64'h001;
        memory[(LEVEL0_ADDR - MEMORY_BASE + vpn0*8) >> 3] =
            ((TARGET_ADDR >> 12) << 10) | 64'h0cf;

        repeat (5) @(posedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);

        ptw_req_valid = 1'b1;
        while (!ptw_req_ready)
            @(negedge clk);
        @(posedge clk);
        #1;
        ptw_req_valid = 1'b0;

        wait (ptw_resp_valid);
        if (ptw_resp_page_fault || ptw_resp_access_fault ||
            ptw_resp_invalidated)
            $fatal(1, "valid Sv39 walk faulted");
        if (ptw_resp_paddr != expected_paddr)
            $fatal(1, "Sv39 result %x expected %x",
                   ptw_resp_paddr, expected_paddr);
        if (ptw_resp_level != `RV64_PAGE_LEVEL_4K ||
            !ptw_resp_readable || !ptw_resp_writable ||
            !ptw_resp_executable || ptw_resp_user ||
            !ptw_resp_accessed || !ptw_resp_dirty)
            $fatal(1, "Sv39 leaf attributes mismatch");
        if (memory_request_count != 24)
            $fatal(1, "three-level walk used %0d reads instead of 24",
                   memory_request_count);
        @(posedge clk);

        // The invalidation fence must traverse the same endpoint but must not
        // generate a DDR transaction after all blocking reads have completed.
        invalidate = 1'b1;
        @(posedge clk);
        #1;
        invalidate = 1'b0;
        wait (invalidate_busy);
        wait (!invalidate_busy);
        if (memory_request_count != 24)
            $fatal(1, "shootdown fence touched DDR");

        $display("OPENRV64 FPGA PTW PATH PASS");
        $finish;
    end

endmodule
