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
    wire store_barrier_busy;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;

    wire ccx_req_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire ccx_wdata_valid;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;

    reg ccx_resp_valid;
    wire ccx_resp_ready;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    localparam integer RESPONSE_SLOTS = 16;
    reg response_slot_valid_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        response_hart_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        response_txn_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        response_source_q [0:RESPONSE_SLOTS-1];
    reg response_write_q [0:RESPONSE_SLOTS-1];
    reg [63:0] response_addr_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        response_wdata_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        response_wstrb_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        response_rdata_q [0:RESPONSE_SLOTS-1];
    integer response_due_q [0:RESPONSE_SLOTS-1];
    integer response_count_q;
    integer max_response_count_q;
    integer response_active_slot_q;
    reg response_free_found_r;
    integer response_free_slot_r;
    reg response_select_found_r;
    integer response_select_slot_r;
    integer response_scan;

    integer cycle_count;
    integer read_count;
    integer write_count;
    integer wait_cycles;
    integer word_index;
    integer timeout_start_cycle;
    integer memory_byte;
    integer memory_reset_line;
    localparam integer MEMORY_LINES = 16;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    reg [63:0] write_addr [0:15];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] write_data [0:15];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] write_strb [0:15];

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
                (response_due_q[response_scan] <= cycle_count)) begin
                response_select_found_r = 1'b1;
                response_select_slot_r = response_scan;
            end
        end
    end

    openrv64_l1d_ccx #(
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
        .req_posted_i(1'b1),
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
        .store_barrier_busy_o(store_barrier_busy),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(1'b1),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_lock_o(),
        .ccx_req_order_o(),
        .ccx_req_kind_o(),
        .ccx_req_attr_o(),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(),
        .ccx_wdata_valid_o(ccx_wdata_valid),
        .ccx_wdata_ready_i(1'b1),
        .ccx_wdata_hart_id_o(),
        .ccx_wdata_txn_id_o(),
        .ccx_wdata_source_id_o(),
        .ccx_wdata_beat_index_o(),
        .ccx_wdata_last_o(),
        .ccx_wdata_o(ccx_wdata),
        .ccx_wstrb_o(ccx_wstrb),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_beat_index_i(
            {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}),
        .ccx_resp_last_i(1'b1),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_error_i(1'b0),
        .ccx_resp_sc_success_i(1'b0)
    );

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_resp_valid <= 1'b0;
            ccx_resp_hart_id <= 0;
            ccx_resp_txn_id <= 0;
            ccx_resp_source_id <= 0;
            ccx_resp_rdata <= 0;
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
        end else begin
            cycle_count <= cycle_count + 1;
            if (ccx_req_valid) begin
                if (!response_free_found_r)
                    $fatal(1, "store-buffer response model overflow");
                if (ccx_req_size != 3'd6)
                    $fatal(1, "store-buffer request was not line-sized");
                if (ccx_req_op == `OPENRV64_CCX_OP_WRITE) begin
                    if (!ccx_wdata_valid)
                        $fatal(1,
                            "store-buffer line write lacked write data");
                    if (write_count >= 16)
                        $fatal(1,
                            "store-buffer test write log overflow");
                    write_addr[write_count] <= ccx_req_addr;
                    write_data[write_count] <= ccx_wdata;
                    write_strb[write_count] <= ccx_wstrb;
                    write_count <= write_count + 1;
                end else if (ccx_req_op == `OPENRV64_CCX_OP_READ) begin
                    read_count <= read_count + 1;
                end else begin
                    $fatal(1, "unexpected CCX operation");
                end
                response_slot_valid_q[response_free_slot_r] <= 1'b1;
                response_hart_q[response_free_slot_r] <=
                    ccx_req_hart_id;
                response_txn_q[response_free_slot_r] <=
                    ccx_req_txn_id;
                response_source_q[response_free_slot_r] <=
                    ccx_req_source_id;
                response_write_q[response_free_slot_r] <=
                    ccx_req_op == `OPENRV64_CCX_OP_WRITE;
                response_addr_q[response_free_slot_r] <= ccx_req_addr;
                response_wdata_q[response_free_slot_r] <= ccx_wdata;
                response_wstrb_q[response_free_slot_r] <= ccx_wstrb;
                response_rdata_q[response_free_slot_r] <=
                    memory[ccx_req_addr[9:6]];
                response_due_q[response_free_slot_r] <=
                    cycle_count + 20 - ((write_count % 4) * 4);
            end
            if (!ccx_resp_valid && response_select_found_r) begin
                ccx_resp_valid <= 1'b1;
                response_active_slot_q <= response_select_slot_r;
                ccx_resp_hart_id <=
                    response_hart_q[response_select_slot_r];
                ccx_resp_txn_id <=
                    response_txn_q[response_select_slot_r];
                ccx_resp_source_id <=
                    response_source_q[response_select_slot_r];
                ccx_resp_rdata <=
                    response_rdata_q[response_select_slot_r];
            end
            if (ccx_resp_valid && ccx_resp_ready) begin
                ccx_resp_valid <= 1'b0;
                if (response_write_q[response_active_slot_q]) begin
                    for (memory_byte = 0;
                         memory_byte <
                             `OPENRV64_CCX_LINE_STRB_WIDTH;
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
            case ({ccx_req_valid,
                   ccx_resp_valid && ccx_resp_ready})
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
            while (!resp_valid && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid || req_error)
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
             {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}}))
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

        // A translation barrier must force even one partial line to CCX and
        // remain busy until the downstream write response is consumed.
        reset_dut();
        issue_store(BASE, 64'hfeed_face_0123_4567);
        if ((dut.store_buffer_count_q != 1) || (write_count != 0))
            $fatal(1, "barrier setup store was not held for combining");
        timeout_start_cycle = cycle_count;
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
        while (store_barrier_busy && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (store_barrier_busy || (dut.store_buffer_count_q != 0) ||
            dut.store_completion_valid_q ||
            (dut.backend_state_q != 0))
            $fatal(1, "translation barrier released with store outstanding");

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
