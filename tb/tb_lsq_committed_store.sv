`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

module tb_lsq_committed_store;
    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer SLOT_WIDTH = 3;
    localparam integer TAG_WIDTH = 3;
    localparam integer META_WIDTH =
        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash_younger;
    reg squash_inclusive;
    reg [ID_WIDTH-1:0] squash_id;

    reg store_alloc_valid;
    wire store_alloc_ready;
    reg [ID_WIDTH-1:0] store_alloc_id;
    reg [SLOT_WIDTH-1:0] store_alloc_slot;
    reg [META_WIDTH-1:0] store_alloc_meta;
    reg [63:0] store_alloc_vaddr;
    reg [2:0] store_alloc_size;
    reg [63:0] store_alloc_wdata;
    reg [7:0] store_alloc_wstrb;

    reg ordered_head_valid;
    reg [ID_WIDTH-1:0] ordered_head_id;
    reg [SLOT_WIDTH-1:0] ordered_head_slot;
    reg [2:0] store_commit_valid;
    reg [3*ID_WIDTH-1:0] store_commit_id;
    reg [3*SLOT_WIDTH-1:0] store_commit_slot;
    wire [2:0] store_commit_accept;

    wire xlate_req_valid;
    wire [TAG_WIDTH-1:0] xlate_req_tag;
    reg xlate_resp_valid;
    reg [TAG_WIDTH-1:0] xlate_resp_tag;
    reg [63:0] xlate_resp_paddr;

    wire req_valid;
    reg req_ready;
    wire [TAG_WIDTH-1:0] req_tag;
    wire req_write;
    wire [63:0] req_addr;

    wire posted_complete_valid;
    wire [ID_WIDTH-1:0] posted_complete_id;
    wire [SLOT_WIDTH-1:0] posted_complete_slot;

    reg resp_valid;
    wire resp_ready;
    reg [TAG_WIDTH-1:0] resp_tag;
    reg [63:0] resp_paddr;
    reg store_done_valid;
    wire store_done_ready;
    reg [TAG_WIDTH-1:0] store_done_tag;

    wire result_valid;
    reg result_ready;
    wire [ID_WIDTH-1:0] result_id;
    wire result_store;
    wire empty;

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(SLOT_WIDTH),
        .META_WIDTH(META_WIDTH),
        .LOAD_QUEUE_DEPTH(2),
        .STORE_QUEUE_DEPTH(4),
        .TAG_WIDTH(TAG_WIDTH),
        .ENABLE_ORDERED_STORE_WINDOW(1),
        .ENABLE_COMMITTED_STORE_QUEUE(1),
        .CACHEABLE_BASE(64'h1000),
        .CACHEABLE_SIZE(64'h1000),
        .TIMEOUT_CYCLES(200)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_younger_i(squash_younger),
        .squash_inclusive_i(squash_inclusive),
        .squash_id_i(squash_id),
        .translation_bypass_i(1'b0),
        .inhibit_load_speculation_i(1'b0),
        .load_alloc_valid_i(1'b0), .load_alloc_ready_o(),
        .load_alloc_id_i({ID_WIDTH{1'b0}}),
        .load_alloc_slot_i({SLOT_WIDTH{1'b0}}),
        .load_alloc_meta_i({META_WIDTH{1'b0}}),
        .load_alloc_immediate_i(1'b0),
        .load_alloc_access_fault_i(1'b0),
        .load_alloc_vaddr_i(64'd0), .load_alloc_size_i(3'd0),
        .store_alloc_valid_i(store_alloc_valid),
        .store_alloc_ready_o(store_alloc_ready),
        .store_alloc_id_i(store_alloc_id),
        .store_alloc_slot_i(store_alloc_slot),
        .store_alloc_meta_i(store_alloc_meta),
        .store_alloc_immediate_i(1'b0),
        .store_alloc_access_fault_i(1'b0),
        .store_alloc_atomic_i(1'b0),
        .store_alloc_vaddr_i(store_alloc_vaddr),
        .store_alloc_size_i(store_alloc_size),
        .store_alloc_wdata_i(store_alloc_wdata),
        .store_alloc_wstrb_i(store_alloc_wstrb),
        .ordered_head_valid_i(ordered_head_valid),
        .ordered_head_id_i(ordered_head_id),
        .ordered_head_slot_i(ordered_head_slot),
        .ordered_store_window_valid_i(3'b000),
        .ordered_store_window_complete_i(3'b000),
        .ordered_store_window_id_i({3*ID_WIDTH{1'b0}}),
        .ordered_store_window_slot_i({3*SLOT_WIDTH{1'b0}}),
        .store_commit_valid_i(store_commit_valid),
        .store_commit_id_i(store_commit_id),
        .store_commit_slot_i(store_commit_slot),
        .store_commit_accept_o(store_commit_accept),
        .atomic_start_valid_o(), .atomic_start_tag_o(),
        .atomic_start_id_o(), .atomic_start_slot_o(),
        .atomic_start_meta_o(), .atomic_start_vaddr_o(),
        .atomic_start_size_o(), .atomic_start_wdata_o(),
        .atomic_start_access_allowed_o(),
        .atomic_active_i(1'b0), .atomic_tag_i({TAG_WIDTH{1'b0}}),
        .atomic_irrevocable_i(1'b0), .atomic_done_i(1'b0),
        .xlate_req_valid_o(xlate_req_valid),
        .xlate_req_ready_i(1'b1), .xlate_req_tag_o(xlate_req_tag),
        .xlate_req_write_o(), .xlate_req_size_o(),
        .xlate_req_vaddr_o(), .xlate_resp_valid_i(xlate_resp_valid),
        .xlate_resp_ready_o(), .xlate_resp_tag_i(xlate_resp_tag),
        .xlate_resp_paddr_i(xlate_resp_paddr),
        .xlate_resp_access_fault_i(1'b0),
        .xlate_resp_page_fault_i(1'b0),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_tag_o(req_tag), .req_write_o(req_write),
        .req_pmp_checked_o(), .req_addr_o(req_addr), .req_vaddr_o(),
        .req_size_o(), .req_wdata_o(), .req_wstrb_o(),
        .posted_store_complete_valid_o(posted_complete_valid),
        .posted_store_complete_id_o(posted_complete_id),
        .posted_store_complete_slot_o(posted_complete_slot),
        .load_access_valid_o(), .load_access_id_o(),
        .load_access_slot_o(), .load_access_meta_o(),
        .load_access_paddr_o(), .store_address_valid_o(),
        .store_address_id_o(), .store_address_slot_o(),
        .store_address_meta_o(), .store_address_paddr_o(),
        .store_address_cacheable_o(),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_tag_i(resp_tag), .resp_paddr_i(resp_paddr),
        .resp_rdata_i(64'd0), .resp_access_fault_i(1'b0),
        .resp_page_fault_i(1'b0),
        .store_done_valid_i(store_done_valid),
        .store_done_ready_o(store_done_ready),
        .store_done_tag_i(store_done_tag),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_id_o(result_id), .result_slot_o(), .result_meta_o(),
        .result_vaddr_o(), .result_rdata_o(),
        .result_access_fault_o(), .result_page_fault_o(),
        .result_store_o(result_store), .store_pending_o(),
        .quiescent_o(), .empty_o(empty)
    );

    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task fail;
        input [1023:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task allocate_and_translate;
        input [ID_WIDTH-1:0] id;
        input [SLOT_WIDTH-1:0] slot;
        input [63:0] address;
        input expect_early_complete;
        reg [TAG_WIDTH-1:0] tag;
        begin
            store_alloc_id = id;
            store_alloc_slot = slot;
            store_alloc_vaddr = address;
            store_alloc_valid = 1'b1;
            #1;
            if (!store_alloc_ready || !xlate_req_valid)
                fail("store allocation did not launch translation");
            tag = xlate_req_tag;
            tick();
            store_alloc_valid = 1'b0;
            xlate_resp_tag = tag;
            xlate_resp_paddr = address;
            xlate_resp_valid = 1'b1;
            tick();
            xlate_resp_valid = 1'b0;
            if (expect_early_complete) begin
                if (!posted_complete_valid ||
                    (posted_complete_id != id) ||
                    (posted_complete_slot != slot))
                    fail("cacheable store did not complete after translation");
            end else if (posted_complete_valid) begin
                fail("uncacheable store completed through cacheable sideband");
            end
            if (req_valid)
                fail("uncommitted store reached the memory request port");
            tick();
        end
    endtask

    task drain_store;
        input [ID_WIDTH-1:0] expected_id;
        reg [TAG_WIDTH-1:0] tag;
        begin
            #1;
            if (!req_valid || !req_write ||
                (dut.request_id_r != expected_id))
                fail("committed store was not selected for L1D");
            tag = req_tag;
            req_ready = 1'b1;
            tick();
            req_ready = 1'b0;
            store_done_tag = tag;
            store_done_valid = 1'b1;
            if (!store_done_ready)
                fail("store acknowledgement port was not ready");
            tick();
            store_done_valid = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash_younger = 1'b0;
        squash_inclusive = 1'b0;
        squash_id = {ID_WIDTH{1'b0}};
        store_alloc_valid = 1'b0;
        store_alloc_id = {ID_WIDTH{1'b0}};
        store_alloc_slot = {SLOT_WIDTH{1'b0}};
        store_alloc_meta = {META_WIDTH{1'b0}};
        store_alloc_vaddr = 64'd0;
        store_alloc_size = 3'd3;
        store_alloc_wdata = 64'h8877_6655_4433_2211;
        store_alloc_wstrb = 8'hff;
        ordered_head_valid = 1'b0;
        ordered_head_id = {ID_WIDTH{1'b0}};
        ordered_head_slot = {SLOT_WIDTH{1'b0}};
        store_commit_valid = 3'b000;
        store_commit_id = {3*ID_WIDTH{1'b0}};
        store_commit_slot = {3*SLOT_WIDTH{1'b0}};
        xlate_resp_valid = 1'b0;
        xlate_resp_tag = {TAG_WIDTH{1'b0}};
        xlate_resp_paddr = 64'd0;
        req_ready = 1'b0;
        resp_valid = 1'b0;
        resp_tag = {TAG_WIDTH{1'b0}};
        resp_paddr = 64'd0;
        store_done_valid = 1'b0;
        store_done_tag = {TAG_WIDTH{1'b0}};
        result_ready = 1'b1;

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        allocate_and_translate(10, 1, 64'h1000, 1'b1);
        allocate_and_translate(11, 2, 64'h1008, 1'b1);
        allocate_and_translate(12, 3, 64'h1010, 1'b1);

        store_commit_id[0*ID_WIDTH +: ID_WIDTH] = 10;
        store_commit_id[1*ID_WIDTH +: ID_WIDTH] = 11;
        store_commit_id[2*ID_WIDTH +: ID_WIDTH] = 12;
        store_commit_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 1;
        store_commit_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 2;
        store_commit_slot[2*SLOT_WIDTH +: SLOT_WIDTH] = 3;
        store_commit_valid = 3'b111;
        #1;
        if (store_commit_accept != 3'b111)
            fail("three-lane store commit was not accepted");
        tick();
        store_commit_valid = 3'b000;

        drain_store(10);
        drain_store(11);
        drain_store(12);
        tick();
        if (!empty)
            fail("acknowledged committed stores did not leave the LSQ");

        // A store retiring in the same cycle as a full redirect has already
        // become architectural state and must survive that redirect.
        allocate_and_translate(20, 4, 64'h1020, 1'b1);
        store_commit_id[0*ID_WIDTH +: ID_WIDTH] = 20;
        store_commit_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 4;
        store_commit_valid = 3'b001;
        flush = 1'b1;
        #1;
        if (store_commit_accept != 3'b001)
            fail("same-cycle flush lost retiring store commit");
        tick();
        store_commit_valid = 3'b000;
        flush = 1'b0;
        drain_store(20);
        tick();

        // Completed but unretired stores remain speculative and are removed.
        allocate_and_translate(30, 5, 64'h1030, 1'b1);
        squash_id = 30;
        squash_inclusive = 1'b1;
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        squash_inclusive = 1'b0;
        if (!empty)
            fail("selective squash retained an uncommitted store");

        // Once committed, an SQ entry is outside speculative recovery.
        allocate_and_translate(40, 6, 64'h1040, 1'b1);
        store_commit_id[0*ID_WIDTH +: ID_WIDTH] = 40;
        store_commit_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 6;
        store_commit_valid = 3'b001;
        #1;
        if (store_commit_accept != 3'b001)
            fail("single store commit was not accepted");
        tick();
        store_commit_valid = 3'b000;
        squash_id = 40;
        squash_inclusive = 1'b1;
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        squash_inclusive = 1'b0;
        drain_store(40);
        tick();

        // Device/uncacheable stores retain ordered execution and the normal
        // result path; they are never inserted into the committed SQ path.
        allocate_and_translate(50, 7, 64'h4000, 1'b0);
        ordered_head_id = 50;
        ordered_head_slot = 7;
        ordered_head_valid = 1'b1;
        #1;
        if (!req_valid || !req_write || (req_addr != 64'h4000))
            fail("uncacheable head store did not request memory");
        resp_tag = req_tag;
        resp_paddr = 64'h4000;
        req_ready = 1'b1;
        tick();
        req_ready = 1'b0;
        resp_valid = 1'b1;
        #1;
        if (!resp_ready || !result_valid || !result_store ||
            (result_id != ID_WIDTH'(50)))
            fail("uncacheable store did not use normal completion path");
        tick();
        resp_valid = 1'b0;
        ordered_head_valid = 1'b0;
        tick();
        if (!empty)
            fail("uncacheable store did not leave the LSQ");

        $display("PASS: committed store queue retires independently and drains after commit");
        $finish;
    end
endmodule
