`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"

module tb_lsq;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer TAGW = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer METAW = 8;

    logic clk, rst_n, flush, squash_younger, translation_bypass;
    logic [IDW-1:0] squash_id;
    logic l_valid, l_immediate, l_input_fault;
    wire l_ready;
    logic [IDW-1:0] l_id;
    logic [2:0] l_slot, l_size;
    logic [METAW-1:0] l_meta;
    logic [63:0] l_vaddr;
    logic s_valid, s_immediate, s_input_fault, s_atomic;
    wire s_ready;
    logic [IDW-1:0] s_id;
    logic [2:0] s_slot, s_size;
    logic [METAW-1:0] s_meta;
    logic [63:0] s_vaddr, s_wdata;
    logic [7:0] s_wstrb;
    logic head_valid;
    logic [IDW-1:0] head_id;
    logic [2:0] head_slot;

    wire atomic_start_valid, atomic_start_allowed;
    wire [TAGW-1:0] atomic_start_tag;
    wire [IDW-1:0] atomic_start_id;
    wire [2:0] atomic_start_slot;
    wire [METAW-1:0] atomic_start_meta;
    logic atomic_active, atomic_irrevocable, atomic_done;
    logic [TAGW-1:0] atomic_tag;

    wire xlate_valid, xlate_write;
    wire [2:0] xlate_size;
    logic xlate_ready;
    wire [TAGW-1:0] xlate_tag;
    wire [63:0] xlate_vaddr;
    logic xlate_resp_valid, xlate_resp_access_fault;
    logic xlate_resp_page_fault;
    wire xlate_resp_ready;
    logic [TAGW-1:0] xlate_resp_tag;
    logic [63:0] xlate_resp_paddr;

    wire req_valid, req_write, req_pmp_checked;
    logic req_ready;
    wire [TAGW-1:0] req_tag;
    wire [63:0] req_addr, req_vaddr, req_wdata;
    wire [2:0] req_size;
    wire [7:0] req_wstrb;
    logic resp_valid, resp_access_fault, resp_page_fault;
    wire resp_ready;
    logic [TAGW-1:0] resp_tag;
    logic [63:0] resp_paddr, resp_rdata;
    logic store_done_valid;
    logic [TAGW-1:0] store_done_tag;
    wire store_done_ready;
    wire result_valid, result_access_fault, result_page_fault;
    wire result_store, store_pending, quiescent, empty;
    logic result_ready;
    wire [IDW-1:0] result_id;
    wire [2:0] result_slot;
    wire [METAW-1:0] result_meta;
    wire [63:0] result_rdata;

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(3),
        .META_WIDTH(METAW),
        .LOAD_QUEUE_DEPTH(4),
        .STORE_QUEUE_DEPTH(2),
        .TAG_WIDTH(TAGW),
        .CACHEABLE_BASE(64'h0),
        .CACHEABLE_SIZE(64'h1_0000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_younger_i(squash_younger), .squash_id_i(squash_id),
        .translation_bypass_i(translation_bypass),
        .load_alloc_valid_i(l_valid), .load_alloc_ready_o(l_ready),
        .load_alloc_id_i(l_id), .load_alloc_slot_i(l_slot),
        .load_alloc_meta_i(l_meta), .load_alloc_immediate_i(l_immediate),
        .load_alloc_access_fault_i(l_input_fault),
        .load_alloc_vaddr_i(l_vaddr), .load_alloc_size_i(l_size),
        .store_alloc_valid_i(s_valid), .store_alloc_ready_o(s_ready),
        .store_alloc_id_i(s_id), .store_alloc_slot_i(s_slot),
        .store_alloc_meta_i(s_meta), .store_alloc_immediate_i(s_immediate),
        .store_alloc_access_fault_i(s_input_fault),
        .store_alloc_atomic_i(s_atomic), .store_alloc_vaddr_i(s_vaddr),
        .store_alloc_size_i(s_size), .store_alloc_wdata_i(s_wdata),
        .store_alloc_wstrb_i(s_wstrb),
        .ordered_head_valid_i(head_valid), .ordered_head_id_i(head_id),
        .ordered_head_slot_i(head_slot),
        .atomic_start_valid_o(atomic_start_valid),
        .atomic_start_tag_o(atomic_start_tag),
        .atomic_start_id_o(atomic_start_id),
        .atomic_start_slot_o(atomic_start_slot),
        .atomic_start_meta_o(atomic_start_meta),
        .atomic_start_access_allowed_o(atomic_start_allowed),
        .atomic_active_i(atomic_active), .atomic_tag_i(atomic_tag),
        .atomic_irrevocable_i(atomic_irrevocable),
        .atomic_done_i(atomic_done),
        .xlate_req_valid_o(xlate_valid),
        .xlate_req_ready_i(xlate_ready),
        .xlate_req_tag_o(xlate_tag),
        .xlate_req_write_o(xlate_write),
        .xlate_req_size_o(xlate_size),
        .xlate_req_vaddr_o(xlate_vaddr),
        .xlate_resp_valid_i(xlate_resp_valid),
        .xlate_resp_ready_o(xlate_resp_ready),
        .xlate_resp_tag_i(xlate_resp_tag),
        .xlate_resp_paddr_i(xlate_resp_paddr),
        .xlate_resp_access_fault_i(xlate_resp_access_fault),
        .xlate_resp_page_fault_i(xlate_resp_page_fault),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_tag_o(req_tag), .req_write_o(req_write),
        .req_pmp_checked_o(req_pmp_checked),
        .req_addr_o(req_addr), .req_vaddr_o(req_vaddr),
        .req_size_o(req_size), .req_wdata_o(req_wdata),
        .req_wstrb_o(req_wstrb),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_tag_i(resp_tag), .resp_paddr_i(resp_paddr),
        .resp_rdata_i(resp_rdata),
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .store_done_valid_i(store_done_valid),
        .store_done_ready_o(store_done_ready),
        .store_done_tag_i(store_done_tag),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_id_o(result_id), .result_slot_o(result_slot),
        .result_meta_o(result_meta), .result_rdata_o(result_rdata),
        .result_access_fault_o(result_access_fault),
        .result_page_fault_o(result_page_fault),
        .result_store_o(result_store), .store_pending_o(store_pending),
        .quiescent_o(quiescent),
        .empty_o(empty)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic complete_store(input [TAGW-1:0] tag);
        begin
            store_done_tag = tag;
            store_done_valid = 1'b1;
            #1;
            if (!store_done_ready)
                $fatal(1, "store completion blocked tag=%0d", tag);
            tick();
            store_done_valid = 1'b0;
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            repeat (2) tick();
            rst_n = 1'b1;
            tick();
            if (!empty)
                $fatal(1, "LSQ did not report empty after reset");
        end
    endtask

    task automatic alloc_store(
        input [IDW-1:0] id,
        input [2:0] slot,
        input [63:0] addr,
        input [2:0] size,
        input [63:0] data,
        input [7:0] strb
    );
        reg [TAGW-1:0] bare_tag;
        begin
            s_id = id; s_slot = slot; s_meta = id; s_vaddr = addr;
            s_size = size; s_wdata = data; s_wstrb = strb; s_valid = 1'b1;
            #1;
            if (!s_ready) $fatal(1, "store allocation blocked id=%0d", id);
            if (translation_bypass && !s_immediate && !s_atomic &&
                !atomic_active) begin
                if (!xlate_valid || !xlate_write ||
                    xlate_vaddr != addr || xlate_size != size)
                    $fatal(1,
                        "Bare store clearance absent id=%0d xlate=%b/%b/%h/%0d",
                        id, xlate_valid, xlate_write,
                        xlate_vaddr, xlate_size);
                bare_tag = xlate_tag;
                xlate_ready = 1'b1;
                xlate_resp_valid = 1'b1;
                xlate_resp_tag = bare_tag;
                xlate_resp_paddr = addr;
                xlate_resp_access_fault = 1'b0;
                xlate_resp_page_fault = 1'b0;
                tick();
                xlate_ready = 1'b0;
                xlate_resp_valid = 1'b0;
            end else begin
                tick();
            end
            s_valid = 1'b0;
        end
    endtask

    task automatic alloc_load(
        input [IDW-1:0] id,
        input [2:0] slot,
        input [63:0] addr,
        input [2:0] size
    );
        reg [TAGW-1:0] bare_tag;
        begin
            l_id = id; l_slot = slot; l_meta = id; l_vaddr = addr;
            l_size = size; l_valid = 1'b1;
            #1;
            if (!l_ready) $fatal(1, "load allocation blocked id=%0d", id);
            if (translation_bypass && !l_immediate && !atomic_active) begin
                if (!xlate_valid || xlate_write ||
                    xlate_vaddr != addr || xlate_size != size)
                    $fatal(1,
                        "Bare load clearance absent id=%0d xlate=%b/%b/%h/%0d",
                        id, xlate_valid, xlate_write,
                        xlate_vaddr, xlate_size);
                bare_tag = xlate_tag;
                xlate_ready = 1'b1;
                xlate_resp_valid = 1'b1;
                xlate_resp_tag = bare_tag;
                xlate_resp_paddr = addr;
                xlate_resp_access_fault = 1'b0;
                xlate_resp_page_fault = 1'b0;
                tick();
                xlate_ready = 1'b0;
                xlate_resp_valid = 1'b0;
            end else begin
                tick();
            end
            l_valid = 1'b0;
        end
    endtask

    task automatic take_req(
        input write,
        input [63:0] addr,
        output [TAGW-1:0] tag
    );
        integer n;
        begin
            n = 0;
            while (!req_valid && n < 20) begin tick(); n = n + 1; end
            if (!req_valid) $fatal(1, "request timeout addr=%h", addr);
            if (req_write != write || req_addr != addr)
                $fatal(1,
                    "request mismatch wr=%b/%b addr=%h/%h",
                    req_write, write, req_addr, addr);
            tag = req_tag;
            req_ready = 1'b1;
            tick();
            req_ready = 1'b0;
        end
    endtask

    task automatic take_xlate(
        input write,
        input [63:0] vaddr,
        output [TAGW-1:0] tag
    );
        integer n;
        begin
            n = 0;
            while (!xlate_valid && n < 20) begin tick(); n = n + 1; end
            if (!xlate_valid)
                $fatal(1, "translation request timeout addr=%h", vaddr);
            if (xlate_write != write || xlate_vaddr != vaddr)
                $fatal(1,
                    "translation mismatch wr=%b/%b addr=%h/%h",
                    xlate_write, write, xlate_vaddr, vaddr);
            tag = xlate_tag;
            xlate_ready = 1'b1;
            tick();
            xlate_ready = 1'b0;
        end
    endtask

    task automatic respond_xlate(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input access_fault,
        input page_fault
    );
        begin
            xlate_resp_tag = tag;
            xlate_resp_paddr = paddr;
            xlate_resp_access_fault = access_fault;
            xlate_resp_page_fault = page_fault;
            xlate_resp_valid = 1'b1;
            #1;
            if (!xlate_resp_ready)
                $fatal(1, "translation response blocked tag=%0d", tag);
            tick();
            xlate_resp_valid = 1'b0;
            xlate_resp_access_fault = 1'b0;
            xlate_resp_page_fault = 1'b0;
        end
    endtask

    task automatic respond(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input [63:0] data,
        input access_fault,
        input page_fault
    );
        begin
            resp_tag = tag; resp_paddr = paddr; resp_rdata = data;
            resp_access_fault = access_fault; resp_page_fault = page_fault;
            resp_valid = 1'b1;
            #1;
            if (!resp_ready) $fatal(1, "response blocked tag=%0d", tag);
            tick();
            resp_valid = 1'b0;
            resp_access_fault = 1'b0;
            resp_page_fault = 1'b0;
        end
    endtask

    task automatic take_result(
        input [IDW-1:0] id,
        input is_store,
        input [63:0] data,
        input access_fault,
        input page_fault
    );
        integer n;
        begin
            n = 0;
            while (!result_valid && n < 20) begin tick(); n = n + 1; end
            if (!result_valid) $fatal(1, "result timeout id=%0d", id);
            if (result_id != id || result_store != is_store ||
                result_rdata != data ||
                result_access_fault != access_fault ||
                result_page_fault != page_fault)
                $fatal(1,
                    "result mismatch id=%0d/%0d store=%b/%b data=%h/%h fault=%b%b/%b%b",
                    result_id, id, result_store, is_store,
                    result_rdata, data,
                    result_access_fault, result_page_fault,
                    access_fault, page_fault);
            result_ready = 1'b1;
            tick();
            result_ready = 1'b0;
        end
    endtask

    task automatic respond_result(
        input [TAGW-1:0] tag,
        input [63:0] paddr,
        input [63:0] response_data,
        input [IDW-1:0] id,
        input is_store,
        input [63:0] expected_data
    );
        begin
            resp_tag = tag; resp_paddr = paddr;
            resp_rdata = response_data;
            resp_access_fault = 1'b0; resp_page_fault = 1'b0;
            resp_valid = 1'b1; result_ready = 1'b1;
            #1;
            if (!resp_ready || !result_valid || result_id != id ||
                result_store != is_store || result_rdata != expected_data ||
                result_access_fault || result_page_fault)
                $fatal(1,
                    "access response/result mismatch tag=%0d id=%0d/%0d store=%b/%b data=%h/%h",
                    tag, result_id, id, result_store, is_store,
                    result_rdata, expected_data);
            tick();
            resp_valid = 1'b0; result_ready = 1'b0;
        end
    endtask

    reg [TAGW-1:0] st, lt;
    reg [TAGW-1:0] load_xlate_tags [0:3];
    reg [TAGW-1:0] load_request_tags [0:3];
    integer load_test_index;
    integer load_compare_index;
    reg [63:0] perf_block_before;
    initial begin
        clk = 0; rst_n = 0; flush = 0;
        squash_younger = 0; squash_id = 0;
        translation_bypass = 0;
        l_valid = 0; l_id = 0; l_slot = 0; l_meta = 0;
        l_immediate = 0; l_input_fault = 0; l_vaddr = 0; l_size = 0;
        s_valid = 0; s_id = 0; s_slot = 0; s_meta = 0;
        s_immediate = 0; s_input_fault = 0; s_atomic = 0;
        s_vaddr = 0; s_size = 0; s_wdata = 0; s_wstrb = 0;
        head_valid = 0; head_id = 0; head_slot = 0;
        atomic_active = 0; atomic_tag = 0; atomic_irrevocable = 0;
        atomic_done = 0; xlate_ready = 0; xlate_resp_valid = 0;
        xlate_resp_tag = 0; xlate_resp_paddr = 0;
        xlate_resp_access_fault = 0; xlate_resp_page_fault = 0;
        req_ready = 0; resp_valid = 0; resp_tag = 0;
        store_done_valid = 0; store_done_tag = 0;
        resp_paddr = 0; resp_rdata = 0; resp_access_fault = 0;
        resp_page_fault = 0; result_ready = 0;

        reset_dut();

        // The first untranslated operation probes the D micro-TLB directly
        // from its allocation port. A same-cycle hit is captured into the new
        // LSQ entry without a mandatory queue/readback bubble.
        l_id = IDW'(14);
        l_slot = 3'd6;
        l_meta = 8'd14;
        l_vaddr = 64'h1600;
        l_size = 3'd3;
        l_valid = 1'b1;
        xlate_ready = 1'b1;
        #1;
        if (!l_ready || !xlate_valid || xlate_write || xlate_size != 3'd3 ||
            xlate_vaddr != 64'h1600)
            $fatal(1,
                "allocation-time translation absent ready=%b xlate=%b/%b/%0d/%h",
                l_ready, xlate_valid, xlate_write, xlate_size, xlate_vaddr);
        lt = xlate_tag;
        xlate_resp_tag = lt;
        xlate_resp_paddr = 64'h2600;
        xlate_resp_valid = 1'b1;
        #1;
        if (!xlate_resp_ready)
            $fatal(1, "allocation-time translation response blocked");
        tick();
        l_valid = 1'b0;
        xlate_ready = 1'b0;
        xlate_resp_valid = 1'b0;
        #1;
        if (!req_pmp_checked)
            $fatal(1, "translated request lost its PMP clearance");
        take_req(1'b0, 64'h2600, lt);
        respond_result(lt, 64'h2600, 64'ha5a5_5a5a_a5a5_5a5a,
                       IDW'(14), 0, 64'ha5a5_5a5a_a5a5_5a5a);

        reset_dut();

        // PMP denial returns on the translation channel.  The LSQ turns it
        // into the architectural access fault without ever presenting the
        // denied physical address to the memory-access channel.
        alloc_load(IDW'(15), 3'd7, 64'h1680, 3'd2);
        take_xlate(1'b0, 64'h1680, lt);
        respond_xlate(lt, 64'h2680, 1'b1, 1'b0);
        #1;
        if (req_valid)
            $fatal(1, "PMP-denied translated load reached memory access");
        take_result(IDW'(15), 1'b0, 64'd0, 1'b1, 1'b0);

        reset_dut();

        // Bare mode uses the address-clearance channel as an identity
        // translation and carries its PMP verdict to the physical request.
        translation_bypass = 1'b1;
        alloc_load(IDW'(0), 3'd0, 64'h0800, 3'd3);
        #1;
        if (!req_pmp_checked)
            $fatal(1, "Bare identity request lost PMP clearance");
        take_req(1'b0, 64'h0800, lt);
        respond_result(lt, 64'h0800, 64'h0123_4567_89ab_cdef,
                       IDW'(0), 0, 64'h0123_4567_89ab_cdef);
        translation_bypass = 1'b0;

        reset_dut();

        // Early store translation, but physical access only at ordered head.
        alloc_store(IDW'(1), 3'd1, 64'h1000, 3'd3,
                    64'hfeed_face_cafe_beef, 8'hff);
        take_xlate(1'b1, 64'h1000, st);
        respond_xlate(st, 64'h2000, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1, "store physically issued before ordered head");
        end
        head_valid = 1; head_id = IDW'(1); head_slot = 3'd1;
        take_req(1'b1, 64'h2000, st);
        // Cacheable stores complete architecturally from request acceptance,
        // before the later L1D response.  Their tag remains occupied until
        // that response returns.
        take_result(IDW'(1), 1, 0, 0, 0);
        if (!store_pending)
            $fatal(1, "accepted posted store was released before response");
        alloc_store(IDW'(2), 3'd2, 64'h1100, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        s_id = IDW'(3); s_slot = 3'd3; s_meta = IDW'(3);
        s_vaddr = 64'h1200; s_size = 3'd3;
        s_wdata = 64'h5555_6666_7777_8888; s_wstrb = 8'hff;
        s_valid = 1'b1;
        #1;
        if (s_ready)
            $fatal(1, "posted store tag was reused before response");
        s_valid = 1'b0;
        complete_store(st);
        #1;
        if (result_valid)
            $fatal(1, "posted store response produced a second result");
        alloc_store(IDW'(3), 3'd3, 64'h1200, 3'd3,
                    64'h5555_6666_7777_8888, 8'hff);
        head_valid = 0;
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Once an ordered atomic starts, it owns the memory path until its
        // real response completes.  Younger LSQ work may allocate, but must
        // not translate or access L1D while the atomic is active.
        translation_bypass = 1'b1;
        s_atomic = 1'b1;
        alloc_store(IDW'(9), 3'd1, 64'h5000, 3'd3,
                    64'h0102_0304_0506_0708, 8'hff);
        s_atomic = 1'b0;
        head_valid = 1'b1;
        head_id = IDW'(9);
        head_slot = 3'd1;
        #1;
        if (!atomic_start_valid || atomic_start_id != IDW'(9))
            $fatal(1, "ordered atomic did not start");
        atomic_tag = atomic_start_tag;
        atomic_active = 1'b1;
        tick();
        alloc_load(IDW'(10), 3'd2, 64'h6000, 3'd3);
        repeat (2) begin
            #1;
            if (req_valid || xlate_valid || atomic_start_valid)
                $fatal(1,
                    "LSQ escaped active atomic req=%b xlate=%b restart=%b",
                    req_valid, xlate_valid, atomic_start_valid);
            tick();
        end
        atomic_done = 1'b1;
        atomic_active = 1'b0;
        tick();
        atomic_done = 1'b0;
        head_valid = 1'b0;
        take_xlate(1'b0, 64'h6000, lt);
        respond_xlate(lt, 64'h6000, 1'b0, 1'b0);
        take_req(1'b0, 64'h6000, lt);
        respond_result(lt, 64'h6000, 64'h8877_6655_4433_2211,
                       IDW'(10), 0, 64'h8877_6655_4433_2211);
        translation_bypass = 1'b0;

        reset_dut();

        // A full architectural flush must retain an already accepted posted
        // store until its independent L1D tag-release response arrives.
        translation_bypass = 1'b1;
        alloc_store(IDW'(4), 3'd4, 64'h1800, 3'd3,
                    64'h0123_4567_89ab_cdef, 8'hff);
        head_valid = 1; head_id = IDW'(4); head_slot = 3'd4;
        take_req(1'b1, 64'h1800, st);
        take_result(IDW'(4), 1, 0, 0, 0);
        head_valid = 0;
        flush = 1; tick(); flush = 0;
        if (!store_pending)
            $fatal(1, "full flush discarded accepted posted store");
        complete_store(st);
        #1;
        if (store_pending || result_valid)
            $fatal(1,
                "post-flush store completion left pending/result state");
        translation_bypass = 1'b0;

        reset_dut();

        // Store tag release and an unrelated load result are independent and
        // may fire together.  The store response must not consume or corrupt
        // the normal result port.
        translation_bypass = 1'b1;
        alloc_store(IDW'(5), 3'd5, 64'h2000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        head_valid = 1; head_id = IDW'(5); head_slot = 3'd5;
        take_req(1'b1, 64'h2000, st);
        take_result(IDW'(5), 1, 0, 0, 0);
        head_valid = 0;
        alloc_load(IDW'(6), 3'd6, 64'h3000, 3'd3);
        take_req(1'b0, 64'h3000, lt);
        store_done_tag = st;
        store_done_valid = 1'b1;
        resp_tag = lt;
        resp_paddr = 64'h3000;
        resp_rdata = 64'h8877_6655_4433_2211;
        resp_valid = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!store_done_ready || !resp_ready || !result_valid ||
            result_store || result_id != IDW'(6) ||
            result_rdata != 64'h8877_6655_4433_2211)
            $fatal(1,
                "concurrent store/load completion failed store_ready=%b resp_ready=%b result=%b/%b/%0d/%h",
                store_done_ready, resp_ready, result_valid, result_store,
                result_id, result_rdata);
        tick();
        store_done_valid = 1'b0;
        resp_valid = 1'b0;
        result_ready = 1'b0;
        if (store_pending)
            $fatal(1, "concurrent store completion retained stale state");
        translation_bypass = 1'b0;

        reset_dut();

        // Exercise the exact MRET-like boundary: architectural store result
        // consumption and full flush coincide, followed by delayed L1D tag
        // release.
        translation_bypass = 1'b1;
        alloc_store(IDW'(7), 3'd7, 64'h3800, 3'd3,
                    64'ha5a5_5a5a_a5a5_5a5a, 8'hff);
        head_valid = 1; head_id = IDW'(7); head_slot = 3'd7;
        take_req(1'b1, 64'h3800, st);
        head_valid = 0;
        flush = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!result_valid || !result_store || result_id != IDW'(7))
            $fatal(1, "flush-cycle posted-store result absent");
        tick();
        flush = 1'b0;
        result_ready = 1'b0;
        if (!store_pending)
            $fatal(1, "flush-cycle result released posted-store tag early");
        complete_store(st);
        if (store_pending)
            $fatal(1, "delayed completion after flush retained store");
        translation_bypass = 1'b0;

        reset_dut();

        // A tag release can arrive on the flush edge itself.  Both sides see
        // the pre-edge accepted-store state, so this must consume the tag
        // exactly once rather than preserve or discard it inconsistently.
        translation_bypass = 1'b1;
        alloc_store(IDW'(8), 3'd0, 64'h4000, 3'd3,
                    64'hccdd_eeff_0011_2233, 8'hff);
        head_valid = 1; head_id = IDW'(8); head_slot = 3'd0;
        take_req(1'b1, 64'h4000, st);
        take_result(IDW'(8), 1, 0, 0, 0);
        head_valid = 0;
        store_done_tag = st;
        store_done_valid = 1'b1;
        flush = 1'b1;
        tick();
        store_done_valid = 1'b0;
        flush = 1'b0;
        if (store_pending || result_valid)
            $fatal(1, "flush-edge store completion was not consumed once");
        translation_bypass = 1'b0;

        reset_dut();

        // Translation generations live in exec_lsu, above this raw slot-tag
        // interface.  A flushed load therefore releases its slot at once;
        // the wrapper filters the stale old-generation response.
        alloc_load(IDW'(40), 3'd0, 64'h8000, 3'd3);
        take_xlate(1'b0, 64'h8000, lt);
        flush = 1'b1;
        tick();
        flush = 1'b0;
        alloc_load(IDW'(41), 3'd1, 64'h9000, 3'd3);
        take_xlate(1'b0, 64'h9000, st);
        if (st != lt)
            $fatal(1, "flushed load did not reuse released tag=%0d/%0d",
                   st, lt);
        respond_xlate(st, 64'hb000, 0, 0);
        take_req(1'b0, 64'hb000, st);
        respond_result(st, 64'hb000, 64'h1234_5678_9abc_def0,
                       IDW'(41), 0, 64'h1234_5678_9abc_def0);

        reset_dut();

        // Physical requests use a different contract.  The ICX bus consumes
        // the flush as a cancellation, suppresses the old response, and keeps
        // its own copy of the tag busy until L1D drains it.  LSQ must release
        // this slot immediately instead of waiting for a response which is
        // deliberately hidden.
        translation_bypass = 1'b1;
        alloc_load(IDW'(42), 3'd2, 64'hc000, 3'd3);
        take_req(1'b0, 64'hc000, lt);
        flush = 1'b1;
        tick();
        flush = 1'b0;
        alloc_load(IDW'(43), 3'd3, 64'hd000, 3'd3);
        take_req(1'b0, 64'hd000, st);
        if (st != lt)
            $fatal(1, "full flush retained cancelled access tag=%0d/%0d",
                   st, lt);
        respond_result(st, 64'hd000, 64'h0fed_cba9_8765_4321,
                       IDW'(43), 0, 64'h0fed_cba9_8765_4321);
        translation_bypass = 1'b0;

        reset_dut();

        // Younger cacheable load waits for an older store paddr, then passes
        // because the translated physical lines differ.
        alloc_store(IDW'(2), 3'd2, 64'h3000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        alloc_load(IDW'(3), 3'd3, 64'h4000, 3'd3);
        take_xlate(1'b1, 64'h3000, st);
        take_xlate(1'b0, 64'h4000, lt);
        respond_xlate(lt, 64'h5000, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1, "load passed store with unknown paddr");
        end
        respond_xlate(st, 64'h6000, 0, 0);
        take_req(1'b0, 64'h5000, lt);
        respond_result(lt, 64'h5000, 64'h0123_4567_89ab_cdef,
                       IDW'(3), 0, 64'h0123_4567_89ab_cdef);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Translation and access are distinct channels. Once both physical
        // addresses are known, a younger disjoint load reaches L1D.
        alloc_store(IDW'(4), 3'd4, 64'h3000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        take_xlate(1'b1, 64'h3000, st);
        respond_xlate(st, 64'h6000, 0, 0);
        alloc_load(IDW'(5), 3'd5, 64'h4000, 3'd3);
        take_xlate(1'b0, 64'h4000, lt);
        respond_xlate(lt, 64'h5000, 0, 0);
        take_req(1'b0, 64'h5000, lt);
        respond_result(lt, 64'h5000, 64'h0123_4567_89ab_cdef,
                       IDW'(5), 0, 64'h0123_4567_89ab_cdef);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // All four compact load records translate and access memory
        // independently.  No translation or memory response is returned
        // until every slot has launched, so this catches accidental scalar
        // serialization in either half of the path.
        for (load_test_index = 0; load_test_index < 4;
             load_test_index = load_test_index + 1)
            alloc_load(IDW'(12 + load_test_index),
                       load_test_index[2:0],
                       64'h14_000 + load_test_index * 64'h1000, 3'd3);

        l_id = IDW'(16); l_slot = 3'd4; l_meta = IDW'(16);
        l_vaddr = 64'h18_000; l_size = 3'd3; l_valid = 1'b1;
        #1;
        if (l_ready)
            $fatal(1,
                "four-entry load table admitted a fifth load");
        l_valid = 1'b0;

        for (load_test_index = 0; load_test_index < 4;
             load_test_index = load_test_index + 1)
            take_xlate(1'b0,
                       64'h14_000 + load_test_index * 64'h1000,
                       load_xlate_tags[load_test_index]);
        for (load_test_index = 0; load_test_index < 4;
             load_test_index = load_test_index + 1)
            for (load_compare_index = load_test_index + 1;
                 load_compare_index < 4;
                 load_compare_index = load_compare_index + 1)
                if (load_xlate_tags[load_test_index] ==
                    load_xlate_tags[load_compare_index])
                    $fatal(1,
                        "concurrent loads shared translation tag %0d",
                        load_xlate_tags[load_test_index]);

        for (load_test_index = 0; load_test_index < 4;
             load_test_index = load_test_index + 1)
            respond_xlate(load_xlate_tags[load_test_index],
                          64'h4000 + load_test_index * 64'h1000,
                          0, 0);
        for (load_test_index = 0; load_test_index < 4;
             load_test_index = load_test_index + 1) begin
            take_req(1'b0,
                     64'h4000 + load_test_index * 64'h1000,
                     load_request_tags[load_test_index]);
            if (load_request_tags[load_test_index] !=
                load_xlate_tags[load_test_index])
                $fatal(1,
                    "load tag changed between translation and access %0d/%0d",
                    load_request_tags[load_test_index],
                    load_xlate_tags[load_test_index]);
        end

        for (load_test_index = 3; load_test_index >= 0;
             load_test_index = load_test_index - 1)
            respond_result(load_request_tags[load_test_index],
                           64'h4000 + load_test_index * 64'h1000,
                           64'h1111_0000_0000_0000 + load_test_index,
                           IDW'(12 + load_test_index), 0,
                           64'h1111_0000_0000_0000 + load_test_index);

        reset_dut();

        // An arbitrary VA may translate before ordered retirement, but a
        // translated physical address outside cacheable RAM must not issue a
        // device read until that load becomes the ordered head.
        alloc_load(IDW'(14), 3'd6, 64'hffff_ffd6_1000_2000, 3'd3);
        take_xlate(1'b0, 64'hffff_ffd6_1000_2000, lt);
        respond_xlate(lt, 64'h1_0020, 0, 0);
        repeat (2) begin
            tick();
            if (req_valid)
                $fatal(1,
                    "translated non-RAM load escaped before ordered head");
        end
        head_valid = 1'b1;
        head_id = IDW'(14);
        head_slot = 3'd6;
        take_req(1'b0, 64'h1_0020, lt);
        respond_result(lt, 64'h1_0020, 64'h0bad_f00d_dead_beef,
                       IDW'(14), 0, 64'h0bad_f00d_dead_beef);
        head_valid = 1'b0;

        reset_dut();

        // A cache-line guard is intentionally coarser than byte forwarding.
        // Same-line disjoint words wait until the older store drains.
        translation_bypass = 1'b1;
        alloc_store(IDW'(4), 3'd4, 64'h7000, 3'd3,
                    64'h1111_2222_3333_4444, 8'hff);
        alloc_load(IDW'(5), 3'd5, 64'h7008, 3'd3);
        #1;
        if (req_valid && !req_write)
            $fatal(1, "same-line load passed store guard");
        head_valid = 1'b1; head_id = IDW'(4); head_slot = 3'd4;
        take_req(1'b1, 64'h7000, st);
        take_result(IDW'(4), 1, 0, 0, 0);
        complete_store(st);
        head_valid = 1'b0;
        take_req(1'b0, 64'h7008, lt);
        respond_result(lt, 64'h7008, 64'h0123_4567_89ab_cdef,
                       IDW'(5), 0, 64'h0123_4567_89ab_cdef);
        translation_bypass = 1'b0;
        flush = 1; tick(); flush = 0;

        reset_dut();

        // Same-word accesses use the same guard flow.  This cut contains no
        // byte-owner matrix and no store-to-load forwarding path.
        alloc_store(IDW'(6), 3'd6, 64'h8002, 3'd2,
                    64'h0000_aabb_ccdd_0000, 8'h3c);
        alloc_load(IDW'(7), 3'd7, 64'h8002, 3'd2);
        take_xlate(1'b1, 64'h8002, st);
        respond_xlate(st, 64'h8002, 0, 0);
        take_xlate(1'b0, 64'h8002, lt);
        respond_xlate(lt, 64'h8002, 0, 0);
        #1;
        if (req_valid && !req_write)
            $fatal(1, "same-word load passed store guard");
        head_valid = 1'b1; head_id = IDW'(6); head_slot = 3'd6;
        take_req(1'b1, 64'h8002, st);
        take_result(IDW'(6), 1, 0, 0, 0);
        complete_store(st);
        head_valid = 1'b0;
        take_req(1'b0, 64'h8002, lt);
        respond_result(lt, 64'h8002, 64'h0000_aabb_ccdd_0000,
                       IDW'(7), 0, 64'h0000_aabb_ccdd_0000);
        flush = 1; tick(); flush = 0;

        reset_dut();

        // An uncacheable/device load must not consume store-forwarded data.
        // It waits for the older store to complete, then performs its own
        // physical access so device read side effects remain observable.
        translation_bypass = 1'b1;
        alloc_store(IDW'(8), 3'd0, 64'h1_0008, 3'd3,
                    64'h5566_7788_99aa_bbcc, 8'hff);
        alloc_load(IDW'(9), 3'd1, 64'h1_0008, 3'd3);
        #1;
        if (result_valid)
            $fatal(1, "uncacheable load forwarded from older store");
        head_valid = 1; head_id = IDW'(8); head_slot = 3'd0;
        take_req(1'b1, 64'h1_0008, st);
        respond_result(st, 64'h1_0008, 64'd0, IDW'(8), 1, 64'd0);
        head_id = IDW'(9); head_slot = 3'd1;
        take_req(1'b0, 64'h1_0008, lt);
        respond_result(lt, 64'h1_0008, 64'h0123_4567_89ab_cdef,
                       IDW'(9), 0, 64'h0123_4567_89ab_cdef);
        head_valid = 0;
        translation_bypass = 1'b0;

        reset_dut();

        // Translation faults complete locally and precisely.
        alloc_load(IDW'(8), 3'd0, 64'h9000, 3'd3);
        take_xlate(1'b0, 64'h9000, lt);
        respond_xlate(lt, 0, 0, 1);
        #1;
        if (req_valid)
            $fatal(1, "faulted translation issued physical access");
        take_result(IDW'(8), 0, 0, 0, 1);

        reset_dut();

        // An xlate-only selective squash releases its load slot immediately.
        // exec_lsu's generation filter consumes the stale response above this
        // interface before the reused raw tag can observe it.
        alloc_load(IDW'(10), 3'd2, 64'ha000, 3'd3);
        take_xlate(1'b0, 64'ha000, lt);
        squash_id = IDW'(9);
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        alloc_load(IDW'(11), 3'd3, 64'hb000, 3'd3);
        take_xlate(1'b0, 64'hb000, st);
        if (st != lt)
            $fatal(1, "selective squash did not reuse load tag=%0d/%0d",
                   st, lt);
        respond_xlate(st, 64'hd000, 0, 0);
        take_req(1'b0, 64'hd000, st);
        respond_result(st, 64'hd000, 64'h1122_3344_5566_7788,
                       IDW'(11), 0, 64'h1122_3344_5566_7788);

        reset_dut();

        // A killed physical request owns only its tagged load slot until the
        // raw response drains.  Other load slots remain independently usable.
        alloc_load(IDW'(30), 3'd6, 64'h10_000, 3'd3);
        take_xlate(1'b0, 64'h10_000, lt);
        respond_xlate(lt, 64'h3000, 0, 0);
        take_req(1'b0, 64'h3000, lt);
        squash_id = IDW'(29);
        squash_younger = 1'b1;
        tick();
        squash_younger = 1'b0;
        l_immediate = 1'b1;
        alloc_load(IDW'(31), 3'd7, 64'h12_000, 3'd3);
        l_immediate = 1'b0;
        take_result(IDW'(31), 0, 64'd0, 0, 0);
        if (!dut.load_valid_q[lt] || !dut.load_killed_q[lt])
            $fatal(1, "killed physical load lost response ownership");
        respond(lt, 64'h3000, 64'hdead_beef_dead_beef, 0, 0);
        if (!empty)
            $fatal(1, "killed physical load did not drain independently");

        reset_dut();

        // A redirect may coincide with the response of an older surviving
        // load.  That response must still complete rather than being consumed
        // as though the load were on the squashed path.
        alloc_load(IDW'(20), 3'd4, 64'he000, 3'd3);
        take_xlate(1'b0, 64'he000, lt);
        respond_xlate(lt, 64'hf000, 0, 0);
        take_req(1'b0, 64'hf000, lt);
        squash_id = IDW'(21);
        squash_younger = 1'b1;
        resp_tag = lt;
        resp_paddr = 64'hf000;
        resp_rdata = 64'h8877_6655_4433_2211;
        resp_valid = 1'b1;
        result_ready = 1'b1;
        #1;
        if (!resp_ready || !result_valid || result_id != IDW'(20) ||
            result_rdata != 64'h8877_6655_4433_2211)
            $fatal(1, "surviving redirect-cycle response was lost");
        tick();
        squash_younger = 1'b0;
        resp_valid = 1'b0;
        result_ready = 1'b0;
        if (!empty)
            $fatal(1, "LSQ did not report empty after final response");

        reset_dut();

        // The dependency counter measures loads which older stores prevent
        // from launching.  It must not count an in-flight load merely because
        // an older store allocates after that load has already launched.
        alloc_load(IDW'(31), 3'd7, 64'h1_1000, 3'd3);
        take_xlate(1'b0, 64'h1_1000, lt);
        respond_xlate(lt, 64'h2000, 0, 0);
        take_req(1'b0, 64'h2000, lt);
        perf_block_before = dut.perf_load_dependency_block_cycles_q;
        alloc_store(IDW'(30), 3'd6, 64'h1_2000, 3'd3,
                    64'h0123_4567_89ab_cdef, 8'hff);
        #1;
        if (!dut.load_block_r[lt])
            $fatal(1,
                "late older store did not exercise issued-load block predicate");
        req_ready = 1'b1;
        repeat (2) tick();
        req_ready = 1'b0;
        if (dut.perf_load_dependency_block_cycles_q != perf_block_before)
            $fatal(1,
                "dependency counter included already-issued load before=%0d after=%0d",
                perf_block_before,
                dut.perf_load_dependency_block_cycles_q);

        reset_dut();

        // An uncacheable load with an older store is not store-stalled until
        // it is also the ordered head.  Before that point ordered-device
        // eligibility is the independent reason it cannot launch.
        alloc_store(IDW'(22), 3'd4, 64'h3000, 3'd3,
                    64'hfeed_face_cafe_beef, 8'hff);
        take_xlate(1'b1, 64'h3000, st);
        respond_xlate(st, 64'h3000, 0, 0);
        alloc_load(IDW'(23), 3'd5, 64'h1_0008, 3'd3);
        take_xlate(1'b0, 64'h1_0008, lt);
        respond_xlate(lt, 64'h1_0008, 0, 0);
        #1;
        if (!dut.load_block_r[lt])
            $fatal(1,
                "device load did not exercise older-store block predicate");
        perf_block_before = dut.perf_load_dependency_block_cycles_q;
        req_ready = 1'b1;
        repeat (2) tick();
        if (dut.perf_load_dependency_block_cycles_q != perf_block_before)
            $fatal(1,
                "dependency counter included non-head device load before=%0d after=%0d",
                perf_block_before,
                dut.perf_load_dependency_block_cycles_q);
        head_valid = 1'b1;
        head_id = IDW'(23);
        head_slot = 3'd5;
        tick();
        if (dut.perf_load_dependency_block_cycles_q !=
            perf_block_before + 1'b1)
            $fatal(1,
                "dependency counter missed eligible device load before=%0d after=%0d",
                perf_block_before,
                dut.perf_load_dependency_block_cycles_q);
        head_valid = 1'b0;
        req_ready = 1'b0;

        $display("PASS: four-load table, hashed store guards, ordering, faults, and selective recovery");
        $finish;
    end

    wire unused = &{
        1'b0, result_slot, result_meta, store_pending, quiescent, empty,
        atomic_start_valid, atomic_start_tag, atomic_start_id,
        atomic_start_slot, atomic_start_meta, atomic_start_allowed,
        req_vaddr, req_size, req_wdata, req_wstrb
    };
endmodule
