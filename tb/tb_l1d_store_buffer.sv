`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_store_buffer;

    localparam [63:0] BASE = 64'h0000_0000_8000_4000;
    localparam integer TIMEOUT_CYCLES = 64;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] req_tag;
    reg req_write;
    reg [63:0] req_addr;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    reg speculation_barrier;
    reg invalidate_valid;
    reg invalidate_all;
    reg [63:0] invalidate_addr;
    wire invalidate_ready;
    wire store_barrier_busy;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;
    wire posted_resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] posted_resp_tag;

    wire icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire icx_wdata_valid;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;

    reg icx_resp_valid;
    wire icx_resp_ready;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    localparam integer RESPONSE_SLOTS = 16;
    reg response_slot_valid_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        response_hart_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        response_txn_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        response_source_q [0:RESPONSE_SLOTS-1];
    reg response_write_q [0:RESPONSE_SLOTS-1];
    reg response_fence_q [0:RESPONSE_SLOTS-1];
    reg [63:0] response_addr_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        response_wdata_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        response_wstrb_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        response_rdata_q [0:RESPONSE_SLOTS-1];
    integer response_due_q [0:RESPONSE_SLOTS-1];
    integer response_count_q;
    integer max_response_count_q;
    integer response_active_slot_q;
    reg hold_responses;
    reg hold_fence_responses;
    reg response_free_found_r;
    integer response_free_slot_r;
    reg response_select_found_r;
    integer response_select_slot_r;
    integer response_scan;

    integer cycle_count;
    integer read_count;
    integer write_count;
    integer fence_count;
    integer wait_cycles;
    integer word_index;
    integer timeout_start_cycle;
    integer memory_byte;
    integer memory_reset_line;
    reg [3:0] overlay_epoch_before;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] overlap_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] overlap_store_tag;
    reg overlap_mshr_found;
    integer overlap_mshr_scan;
    localparam integer MEMORY_LINES = 16;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    reg [63:0] write_addr [0:15];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] write_data [0:15];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] write_strb [0:15];

    always @* begin
        response_free_found_r = 1'b0;
        response_free_slot_r = 0;
        response_select_found_r = 1'b0;
        response_select_slot_r = 0;
        for (response_scan = 0; response_scan < RESPONSE_SLOTS;
             response_scan = response_scan + 1) begin
            if (!response_free_found_r &&
                !response_slot_valid_q[response_scan]) begin
                response_free_found_r = 1'b1;
                response_free_slot_r = response_scan;
            end
            // Prefer the youngest eligible response.  The intentionally
            // decreasing delay makes a four-write drain complete in reverse
            // order and exercises transaction-ID response matching.
            if (response_slot_valid_q[response_scan] &&
                (!hold_fence_responses ||
                 !response_fence_q[response_scan]) &&
                (response_due_q[response_scan] <= cycle_count)) begin
                response_select_found_r = 1'b1;
                response_select_slot_r = response_scan;
            end
        end
    end

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(2),
        .STORE_BUFFER_LINES(8),
        .STORE_BUFFER_DRAIN_WATERMARK(4),
        .STORE_BUFFER_TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .PREFETCH_ENABLE(0),
        .PREFETCH_OUTSTANDING(1),
        .PREFETCH_DEMAND_RESERVE(1),
        .REQ_DEPTH(8)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_lock_i(1'b0),
        .req_posted_i(req_write),
        .req_write_i(req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(req_addr),
        .req_size_i(3'd3),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .req_rdata_o(req_rdata),
        .req_error_o(req_error),
        .resp_valid_o(resp_valid),
        .resp_ready_i(1'b1),
        .resp_tag_o(resp_tag),
        .posted_resp_valid_o(posted_resp_valid),
        .posted_resp_ready_i(1'b1),
        .posted_resp_tag_o(posted_resp_tag),
        .store_resp_valid_o(),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(),
        .prefetch_issued_o(),
        .prefetch_useful_o(),
        .prefetch_late_o(),
        .prefetch_dropped_o(),
        .prefetch_useless_o(),
        .prefetch_depth_o(),
        .speculation_barrier_i(speculation_barrier),
        .completion_fence_i(speculation_barrier),
        .store_barrier_busy_o(store_barrier_busy),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(invalidate_all),
        .invalidate_addr_i(invalidate_addr),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(1'b1),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(),
        .icx_req_order_o(),
        .icx_req_kind_o(),
        .icx_req_attr_o(),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(1'b1),
        .icx_wdata_hart_id_o(),
        .icx_wdata_txn_id_o(),
        .icx_wdata_source_id_o(),
        .icx_wdata_beat_index_o(),
        .icx_wdata_last_o(),
        .icx_wdata_o(icx_wdata),
        .icx_wstrb_o(icx_wstrb),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(
            {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last_i(1'b1),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(1'b0),
        .icx_resp_sc_success_i(1'b0)
    );

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_resp_valid <= 1'b0;
            icx_resp_hart_id <= 0;
            icx_resp_txn_id <= 0;
            icx_resp_source_id <= 0;
            icx_resp_rdata <= 0;
            response_count_q <= 0;
            max_response_count_q <= 0;
            response_active_slot_q <= 0;
            for (response_scan = 0; response_scan < RESPONSE_SLOTS;
                 response_scan = response_scan + 1) begin
                response_slot_valid_q[response_scan] <= 1'b0;
                response_hart_q[response_scan] <= 0;
                response_txn_q[response_scan] <= 0;
                response_source_q[response_scan] <= 0;
                response_write_q[response_scan] <= 1'b0;
                response_fence_q[response_scan] <= 1'b0;
                response_addr_q[response_scan] <= 0;
                response_wdata_q[response_scan] <= 0;
                response_wstrb_q[response_scan] <= 0;
                response_rdata_q[response_scan] <= 0;
                response_due_q[response_scan] <= 0;
            end
            for (memory_reset_line = 0;
                 memory_reset_line < MEMORY_LINES;
                 memory_reset_line = memory_reset_line + 1)
                memory[memory_reset_line] <= 0;
            cycle_count <= 0;
            read_count <= 0;
            write_count <= 0;
            fence_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (icx_req_valid) begin
                if (!response_free_found_r)
                    $fatal(1, "store-buffer response model overflow");
                if (icx_req_op == `OPENRV64_ICX_OP_WRITE) begin
                    if (icx_req_size != 3'd6)
                        $fatal(1,
                            "store-buffer write was not line-sized");
                    if (!icx_wdata_valid)
                        $fatal(1,
                            "store-buffer line write lacked write data");
                    if (write_count >= 16)
                        $fatal(1,
                            "store-buffer test write log overflow");
                    write_addr[write_count] <= icx_req_addr;
                    write_data[write_count] <= icx_wdata;
                    write_strb[write_count] <= icx_wstrb;
                    write_count <= write_count + 1;
                end else if (icx_req_op == `OPENRV64_ICX_OP_READ) begin
                    if (icx_req_size != 3'd6)
                        $fatal(1,
                            "store-buffer read was not line-sized");
                    read_count <= read_count + 1;
                end else if (icx_req_op == `OPENRV64_ICX_OP_FENCE) begin
                    if (icx_req_size != 3'd0 || icx_wdata_valid)
                        $fatal(1, "malformed L1D fence request");
                    fence_count <= fence_count + 1;
                end else begin
                    $fatal(1, "unexpected ICX operation");
                end
                response_slot_valid_q[response_free_slot_r] <= 1'b1;
                response_hart_q[response_free_slot_r] <=
                    icx_req_hart_id;
                response_txn_q[response_free_slot_r] <=
                    icx_req_txn_id;
                response_source_q[response_free_slot_r] <=
                    icx_req_source_id;
                response_write_q[response_free_slot_r] <=
                    icx_req_op == `OPENRV64_ICX_OP_WRITE;
                response_fence_q[response_free_slot_r] <=
                    icx_req_op == `OPENRV64_ICX_OP_FENCE;
                response_addr_q[response_free_slot_r] <= icx_req_addr;
                response_wdata_q[response_free_slot_r] <= icx_wdata;
                response_wstrb_q[response_free_slot_r] <= icx_wstrb;
                response_rdata_q[response_free_slot_r] <=
                    memory[icx_req_addr[9:6]];
                response_due_q[response_free_slot_r] <=
                    (icx_req_op == `OPENRV64_ICX_OP_FENCE) ?
                    cycle_count + 4 :
                    cycle_count + 20 - ((write_count % 4) * 4);
            end
            if (!icx_resp_valid && !hold_responses &&
                response_select_found_r) begin
                icx_resp_valid <= 1'b1;
                response_active_slot_q <= response_select_slot_r;
                icx_resp_hart_id <=
                    response_hart_q[response_select_slot_r];
                icx_resp_txn_id <=
                    response_txn_q[response_select_slot_r];
                icx_resp_source_id <=
                    response_source_q[response_select_slot_r];
                icx_resp_rdata <=
                    response_rdata_q[response_select_slot_r];
            end
            if (icx_resp_valid && icx_resp_ready) begin
                icx_resp_valid <= 1'b0;
                if (response_write_q[response_active_slot_q]) begin
                    for (memory_byte = 0;
                         memory_byte <
                             `OPENRV64_ICX_LINE_STRB_WIDTH;
                         memory_byte = memory_byte + 1)
                        if (response_wstrb_q[
                                response_active_slot_q][memory_byte])
                            memory[response_addr_q[
                                response_active_slot_q][9:6]][
                                    memory_byte*8 +: 8] <=
                                response_wdata_q[
                                    response_active_slot_q][
                                        memory_byte*8 +: 8];
                end
                response_slot_valid_q[response_active_slot_q] <= 1'b0;
            end
            case ({icx_req_valid,
                   icx_resp_valid && icx_resp_ready})
                2'b10: response_count_q <= response_count_q + 1;
                2'b01: response_count_q <= response_count_q - 1;
                default: response_count_q <= response_count_q;
            endcase
            if (response_count_q > max_response_count_q)
                max_response_count_q <= response_count_q;
            if (response_count_q > RESPONSE_SLOTS)
                $fatal(1, "store-buffer response count overflow");
        end
    end

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            req_valid = 1'b0;
            req_tag = 0;
            req_write = 1'b0;
            req_addr = 0;
            req_wdata = 0;
            req_wstrb = 0;
            speculation_barrier = 1'b0;
            invalidate_valid = 1'b0;
            invalidate_all = 1'b0;
            invalidate_addr = 64'd0;
            hold_responses = 1'b0;
            hold_fence_responses = 1'b0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic issue_store;
        input [63:0] address;
        input [63:0] data;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            req_tag = req_tag + 1'b1;
            wait_cycles = 0;
            while (!req_ready && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "store acceptance timed out addr=%016x", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 0;
            req_wdata = 0;
            req_wstrb = 0;
            wait_cycles = 0;
            while (!posted_resp_valid && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!posted_resp_valid || (posted_resp_tag != req_tag))
                $fatal(1, "posted store response failed");
            @(posedge clk);
        end
    endtask

    task automatic issue_load;
        input [63:0] address;
        input [63:0] expected;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr = address;
            req_wdata = 0;
            req_wstrb = 0;
            req_tag = req_tag + 1'b1;
            wait_cycles = 0;
            while (!req_ready && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "load acceptance timed out addr=%016x", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 0;
            wait_cycles = 0;
            while (!resp_valid && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid || req_error || (req_rdata !== expected))
                $fatal(1,
                    "load response mismatch addr=%016x actual=%016x expected=%016x error=%0b",
                    address, req_rdata, expected, req_error);
            @(posedge clk);
        end
    endtask

    task automatic wait_for_writes;
        input integer expected;
        begin
            wait_cycles = 0;
            while ((write_count < expected) && (wait_cycles < 500)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (write_count != expected)
                $fatal(1, "write count=%0d expected=%0d",
                       write_count, expected);
        end
    endtask

    initial begin
        reset_dut();

        // A cold first store authorizes direct same-line merges only while
        // the carried-forward nonresident result remains valid.  An external
        // coherence event must revoke that authorization before it completes.
        issue_store(BASE, 64'h1111_1111_1111_1111);
        #1;
        if (!dut.store_buffer_fast_merge_q[
                dut.store_buffer_newest_index])
            $fatal(1,
                "cold first store did not establish fast-merge context");
        @(negedge clk);
        invalidate_valid = 1'b1;
        invalidate_addr = BASE;
        wait_cycles = 0;
        while (!invalidate_ready && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!invalidate_ready)
            $fatal(1, "external invalidate did not complete");
        if (dut.store_buffer_fast_merge_q[
                dut.store_buffer_newest_index])
            $fatal(1,
                "external invalidate retained fast-merge context");
        @(posedge clk);
        @(negedge clk);
        invalidate_valid = 1'b0;
        invalidate_addr = 64'd0;

        reset_dut();

        // Put the line in L1, then present a load immediately behind a posted
        // store.  The registered tag stage lets the load enter as the store
        // advances into its write-through access.  There is one lookup bubble
        // so the outer dirty-byte overlay can observe the pending store.
        // Same-word forwarding must then return the new bytes even if the
        // inferred RAM is read-before-write.
        memory[BASE[9:6]][63:0] =
            64'h0123_4567_89ab_cdef;
        issue_load(BASE, 64'h0123_4567_89ab_cdef);
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr = BASE;
        req_wdata = 64'hfeed_face_cafe_beef;
        req_wstrb = 8'hff;
        req_tag = req_tag + 1'b1;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_write = 1'b0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        req_tag = req_tag + 1'b1;
        #1;
        wait_cycles = 0;
        while (!req_ready && (wait_cycles < 4)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1,
                "resident load did not follow posted-store lookup");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        #1;
        if (!posted_resp_valid || !resp_valid ||
            (posted_resp_tag != req_tag - 1'b1) ||
            (resp_tag != req_tag) || req_error ||
            (req_rdata !== 64'hfeed_face_cafe_beef))
            $fatal(1,
                "split store/load completion failed posted=%b ptag=%0d load=%b ltag=%0d data=%016x error=%b",
                posted_resp_valid, posted_resp_tag, resp_valid, resp_tag,
                req_rdata, req_error);
        @(posedge clk);

        reset_dut();

        // A dirty-overlay snapshot is indexed by the LSU request tag.  Once
        // that request completes, reusing its tag for an unrelated miss must
        // not attach the stale byte mask to the new line.
        memory[BASE[9:6]][63:0] =
            64'h0123_4567_89ab_cdef;
        memory[BASE[9:6] + 4][63:0] =
            64'h8877_6655_4433_2211;
        issue_load(BASE, 64'h0123_4567_89ab_cdef);
        issue_store(BASE, 64'hfeed_face_cafe_beef);
        issue_load(BASE, 64'hfeed_face_cafe_beef);
        // issue_load returns in the active region of the response edge;
        // sample state after the DUT's nonblocking retire updates.
        #1;
        overlay_epoch_before =
            dut.tag_overlay_owner_epoch_q[req_tag];
        if (dut.tag_overlay_bypass_valid_q)
            $fatal(1,
                "completed dirty-overlay owner remained live tag=%0d epoch=%0d",
                req_tag, overlay_epoch_before);
        if (!(|dut.tag_overlay_bypass_data_q[
                `OPENRV64_ICX_LINE_STRB_WIDTH-1:0]))
            $fatal(1,
                "dirty-overlay setup lost bypass payload tag=%0d strb=%016x",
                req_tag,
                dut.tag_overlay_bypass_data_q[
                    `OPENRV64_ICX_LINE_STRB_WIDTH-1:0]);
        req_tag = req_tag - 1'b1;
        issue_load(BASE + 64'h100, 64'h8877_6655_4433_2211);
        if (dut.tag_overlay_owner_epoch_q[req_tag] ==
            overlay_epoch_before)
            $fatal(1,
                "recycled LSU tag retained overlay epoch tag=%0d epoch=%0d",
                req_tag, overlay_epoch_before);
        if (dut.tag_overlay_bypass_valid_q)
            $fatal(1,
                "clean recycled tag acquired dirty-overlay bypass tag=%0d epoch=%0d",
                req_tag,
                dut.tag_overlay_owner_epoch_q[req_tag]);
        issue_load(BASE + 64'h100, 64'h8877_6655_4433_2211);

        reset_dut();

        // Eight scalar stores to one line must occupy one entry and emerge as
        // one fully enabled line write after three more distinct lines reach
        // the four-entry drain watermark.
        for (word_index = 0; word_index < 8;
             word_index = word_index + 1)
            issue_store(BASE + word_index * 8,
                        64'h1000_0000_0000_0000 + word_index);
        if ((dut.store_buffer_count_q != 1) || (write_count != 0))
            $fatal(1, "same-line stores did not combine count=%0d writes=%0d",
                   dut.store_buffer_count_q, write_count);

        issue_store(BASE + 64'h40, 64'h2222);
        issue_store(BASE + 64'h80, 64'h3333);
        issue_store(BASE + 64'hc0, 64'h4444);
        wait_for_writes(4);
        if (max_response_count_q < 2)
            $fatal(1,
                "store-buffer drain never had multiple writes outstanding");
        wait_cycles = 0;
        while ((dut.store_buffer_count_q != 0) &&
               (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (dut.store_buffer_count_q != 0)
            $fatal(1, "watermark drain did not empty FIFO");
        if ((write_addr[0] != BASE) ||
            (write_strb[0] !=
             {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b1}}))
            $fatal(1, "combined line geometry addr=%016x strb=%016x",
                   write_addr[0], write_strb[0]);
        for (word_index = 0; word_index < 8;
             word_index = word_index + 1)
            if (write_data[0][word_index*64 +: 64] !==
                (64'h1000_0000_0000_0000 + word_index))
                $fatal(1, "combined line word %0d mismatch", word_index);

        // A lone line cannot remain buffered indefinitely.
        reset_dut();
        issue_store(BASE, 64'h5555);
        timeout_start_cycle = cycle_count;
        wait_for_writes(1);
        if ((cycle_count - timeout_start_cycle) <
            (TIMEOUT_CYCLES - 8))
            $fatal(1, "store-buffer timeout fired too early delta=%0d",
                   cycle_count - timeout_start_cycle);

        // Only adjacent same-line stores combine. A,B,A,C must drain in that
        // order rather than moving the younger A ahead of B.
        reset_dut();
        issue_store(BASE, 64'ha0);
        issue_store(BASE + 64'h40, 64'hb0);
        issue_store(BASE + 8, 64'ha1);
        if (dut.store_buffer_count_q != 3)
            $fatal(1, "non-adjacent line stores were incorrectly combined");
        issue_store(BASE + 64'h80, 64'hc0);
        wait_for_writes(4);
        if ((write_addr[0] != BASE) ||
            (write_addr[1] != BASE + 64'h40) ||
            (write_addr[2] != BASE) ||
            (write_addr[3] != BASE + 64'h80))
            $fatal(1, "store FIFO order changed %x %x %x %x",
                   write_addr[0], write_addr[1],
                   write_addr[2], write_addr[3]);

        // A younger load must see the newest fragment when the FIFO contains
        // non-adjacent entries for the same line and the older entry is
        // draining.  This is the A,B,A pattern exercised by OpenSBI's
        // buffered console when its character data crosses a line boundary.
        reset_dut();
        memory[BASE[9:6]][63:0] = 64'h0000_0000_0000_000b;
        issue_load(BASE, 64'h0000_0000_0000_000b);
        issue_store(BASE, 64'h0000_0000_0000_000a);
        issue_store(BASE + 64'h40, 64'hbbbb_bbbb_bbbb_bbbb);
        issue_store(BASE, 64'h0000_0000_0000_0009);
        issue_store(BASE + 64'h80, 64'hcccc_cccc_cccc_cccc);
        issue_load(BASE, 64'h0000_0000_0000_0009);

        // Keep eight issued lines live.  A ninth posted store must be
        // backpressured at the request interface rather than retained as
        // hidden state in the shared L1 write-through stage.
        reset_dut();
        memory[BASE[9:6]][63:0] = 64'h1111_2222_3333_4444;
        memory[BASE[9:6]][127:64] = 64'h5555_6666_7777_8888;
        memory[BASE[9:6] + 1][63:0] =
            64'h9999_aaaa_bbbb_cccc;
        issue_load(BASE, 64'h1111_2222_3333_4444);
        issue_load(BASE + 64, 64'h9999_aaaa_bbbb_cccc);
        hold_responses = 1'b1;
        for (word_index = 1; word_index <= 8;
             word_index = word_index + 1)
            issue_store(BASE + word_index * 64,
                        64'h8000_0000_0000_0000 + word_index);
        if (dut.store_buffer_count_q != 8)
            $fatal(1, "failed to fill store buffer count=%0d",
                   dut.store_buffer_count_q);

        // The synchronous cold-line shortcut merges directly into the newest
        // entry on the accepting edge and suppresses a simultaneous drain of
        // that entry.  It is therefore safe even when all FIFO slots are
        // occupied; no hidden shared-L1 state is created.
        if (!dut.store_buffer_valid_q[dut.store_buffer_newest_index] ||
            dut.store_buffer_issued_q[dut.store_buffer_newest_index])
            $fatal(1,
                "full-buffer merge setup lacks newest unissued entry");
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr =
            dut.store_buffer_addr_q[dut.store_buffer_newest_index];
        req_wdata = 64'hfeed_face_cafe_beef;
        req_wstrb = 8'hff;
        req_tag = req_tag + 1'b1;
        #1;
        if (!req_ready || !dut.fast_store_fire)
            $fatal(1,
                "full store buffer rejected direct newest-line merge");
        @(posedge clk);
        #1;
        if ((dut.store_buffer_count_q != 8) ||
            (dut.store_buffer_data_q[dut.store_buffer_newest_index][63:0]
             != 64'hfeed_face_cafe_beef))
            $fatal(1,
                "full-buffer direct merge did not update newest entry");

        // Near timeout the shortcut must stop extending the entry.  The
        // request falls back to ordinary admission and therefore stalls while
        // the FIFO remains full.
        @(negedge clk);
        dut.store_buffer_age_q[dut.store_buffer_newest_index] =
            TIMEOUT_CYCLES - 1;
        #1;
        if (req_ready || dut.fast_store_fire)
            $fatal(1,
                "timed-out newest entry accepted a fast store merge");

        req_addr = BASE;
        req_wdata = 64'h0000_0000_0000_00aa;
        req_wstrb = 8'h01;
        req_tag = req_tag + 1'b1;
        #1;
        if (req_ready)
            $fatal(1, "full store buffer accepted a hidden ninth store");
        repeat (8) begin
            @(negedge clk);
            #1;
            if (req_ready)
                $fatal(1,
                    "posted store escaped backpressure while buffer full");
        end
        hold_responses = 1'b0;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        @(negedge clk);
        speculation_barrier = 1'b1;
        @(posedge clk);
        @(negedge clk);
        speculation_barrier = 1'b0;
        wait_cycles = 0;
        while (store_barrier_busy && (wait_cycles < 500)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (store_barrier_busy)
            $fatal(1, "backpressured partial store did not drain");
        issue_load(BASE, 64'h1111_2222_3333_44aa);

        // A translation barrier must force even one partial line to ICX and
        // remain busy until the downstream write response is consumed.
        reset_dut();
        issue_store(BASE, 64'hfeed_face_0123_4567);
        if ((dut.store_buffer_count_q != 1) || (write_count != 0))
            $fatal(1, "barrier setup store was not held for combining");
        timeout_start_cycle = cycle_count;
        hold_fence_responses = 1'b1;
        @(negedge clk);
        speculation_barrier = 1'b1;
        #1;
        if (!store_barrier_busy)
            $fatal(1, "translation barrier did not assert busy immediately");
        @(posedge clk);
        @(negedge clk);
        speculation_barrier = 1'b0;
        wait_for_writes(1);
        if ((cycle_count - timeout_start_cycle) >=
            (TIMEOUT_CYCLES - 8))
            $fatal(1, "translation barrier waited for store timeout");
        if (!store_barrier_busy)
            $fatal(1, "translation barrier completed before write response");
        wait_cycles = 0;
        while ((fence_count == 0) && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (fence_count != 1)
            $fatal(1, "translation barrier did not issue one ICX fence");
        repeat (8) begin
            @(negedge clk);
            if (!store_barrier_busy)
                $fatal(1,
                    "translation barrier released before fence response");
        end
        hold_fence_responses = 1'b0;
        wait_cycles = 0;
        while (store_barrier_busy && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (store_barrier_busy || (dut.store_buffer_count_q != 0) ||
            dut.store_completion_valid_q ||
            (dut.backend_state_q != 0))
            $fatal(1, "translation barrier released with store outstanding");

        // A cold store can authorize direct same-line FIFO merges without
        // installing the line in L1.  If an intervening load allocates a
        // demand MSHR, a later store must leave the shortcut and traverse the
        // shared L1 path so its bytes are merged into the eventual fill.
        // Otherwise the load response can forward the store transiently while
        // the resident line silently retains stale backing data.
        reset_dut();
        memory[BASE[9:6]][191:128] =
            64'h1122_3344_5566_7788;
        issue_store(BASE + 56, 64'h7777_7777_7777_7777);
        if (!dut.store_buffer_fast_merge_q[
                dut.store_buffer_newest_index])
            $fatal(1,
                "cold overlap setup did not establish fast-merge context");

        hold_responses = 1'b1;
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr = BASE + 16;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        req_tag = req_tag + 1'b1;
        overlap_load_tag = req_tag;
        wait_cycles = 0;
        while (!req_ready && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "overlap load acceptance timed out");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_addr = 64'd0;
        wait_cycles = 0;
        while (!dut.demand_mshr_any_valid_r &&
               (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!dut.demand_mshr_any_valid_r)
            $fatal(1, "overlap load did not allocate a demand MSHR");
        if (!dut.store_buffer_fast_merge_q[
                dut.store_buffer_newest_index])
            $fatal(1,
                "demand miss unexpectedly destroyed cold-store context");

        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr = BASE + 8;
        req_wdata = 64'hfeed_face_0123_4567;
        req_wstrb = 8'hff;
        req_tag = req_tag + 1'b1;
        overlap_store_tag = req_tag;
        #1;
        if (!dut.fast_store_demand_mshr_match_r ||
            dut.fast_store_fire)
            $fatal(1,
                "same-line demand MSHR did not exclude fast store match=%b fire=%b",
                dut.fast_store_demand_mshr_match_r,
                dut.fast_store_fire);
        wait_cycles = 0;
        while (!req_ready && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "overlap store acceptance timed out");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        wait_cycles = 0;
        while (!posted_resp_valid && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!posted_resp_valid ||
            (posted_resp_tag != overlap_store_tag))
            $fatal(1, "overlap store response failed");

        overlap_mshr_found = 1'b0;
        for (overlap_mshr_scan = 0;
             overlap_mshr_scan < 3;
             overlap_mshr_scan = overlap_mshr_scan + 1) begin
            if (dut.demand_mshr_valid_q[overlap_mshr_scan] &&
                (dut.demand_mshr_addr_q[overlap_mshr_scan] == BASE)) begin
                overlap_mshr_found = 1'b1;
                if (dut.demand_mshr_store_strb_q[
                        overlap_mshr_scan][15:8] != 8'hff)
                    $fatal(1,
                        "overlap store did not merge into demand MSHR strb=%016x",
                        dut.demand_mshr_store_strb_q[
                            overlap_mshr_scan]);
            end
        end
        if (!overlap_mshr_found)
            $fatal(1, "overlap demand MSHR disappeared before fill");

        @(posedge clk);
        @(negedge clk);
        hold_responses = 1'b0;
        wait_cycles = 0;
        while (!resp_valid && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!resp_valid || (resp_tag != overlap_load_tag) || req_error ||
            (req_rdata !== 64'h1122_3344_5566_7788))
            $fatal(1,
                "overlap load response failed tag=%0d data=%016x error=%b",
                resp_tag, req_rdata, req_error);
        @(posedge clk);

        @(negedge clk);
        speculation_barrier = 1'b1;
        @(posedge clk);
        @(negedge clk);
        speculation_barrier = 1'b0;
        wait_cycles = 0;
        while (store_barrier_busy && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (store_barrier_busy || (dut.store_buffer_count_q != 0))
            $fatal(1, "overlap store did not drain");
        issue_load(BASE + 8, 64'hfeed_face_0123_4567);
        if (read_count != 1)
            $fatal(1,
                "overlap verification missed instead of hitting merged fill");

        // A store miss leaves authoritative dirty bytes in the posted FIFO.
        // A younger same-line load miss may consume stale backing data for
        // untouched bytes, but the complete cacheline installed in L1 must
        // include the older dirty word.  After the store drains and its FIFO
        // entry disappears, a resident hit proves that the merge affected the
        // installed line rather than only the first load response.
        reset_dut();
        memory[BASE[9:6]][63:0] =
            64'h0bad_f00d_dead_beef;
        memory[BASE[9:6]][127:64] =
            64'h1122_3344_5566_7788;
        issue_store(BASE, 64'hfeed_face_0123_4567);
        if ((dut.store_buffer_count_q != 1) ||
            (write_count != 0) || (read_count != 0))
            $fatal(1, "dirty-refill setup did not retain the store");
        issue_load(BASE + 8, 64'h1122_3344_5566_7788);
        if ((write_count != 0) || (read_count != 1) ||
            (dut.store_buffer_count_q != 1))
            $fatal(1,
                "same-line load drained instead of snooping dirty bytes");

        @(negedge clk);
        speculation_barrier = 1'b1;
        @(posedge clk);
        @(negedge clk);
        speculation_barrier = 1'b0;
        wait_cycles = 0;
        while (store_barrier_busy && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (store_barrier_busy || (dut.store_buffer_count_q != 0))
            $fatal(1, "dirty-refill store did not drain");
        issue_load(BASE, 64'hfeed_face_0123_4567);
        if (read_count != 1)
            $fatal(1,
                "dirty-refill verification missed instead of hitting L1");

        $display("PASS: L1D store combining, independent drains, barriers, and dirty-line refill snooping");
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "L1D store-buffer test timed out");
    end

endmodule
