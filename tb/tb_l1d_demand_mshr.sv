`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_demand_mshr;

    localparam [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam integer DEMAND_MSHRS = 3;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer TAG_COUNT = 1 << TAG_WIDTH;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg [TAG_WIDTH-1:0] req_tag;
    reg req_write;
    reg [63:0] req_addr;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    reg resp_ready;
    wire [TAG_WIDTH-1:0] resp_tag;

    reg ccx_resp_valid;
    wire ccx_resp_ready;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;

    wire ccx_req_valid;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;

    wire unused_store_resp_valid;
    wire unused_store_resp_error;
    wire unused_store_barrier_busy;
    wire unused_invalidate_ready;
    wire unused_prefetch_issued;
    wire unused_prefetch_useful;
    wire unused_prefetch_late;
    wire unused_prefetch_dropped;
    wire unused_prefetch_useless;
    wire [4:0] unused_prefetch_depth;
    wire unused_ccx_req_lock;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        unused_ccx_req_hart_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        unused_ccx_req_source_id;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0]
        unused_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0]
        unused_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0]
        unused_ccx_req_attr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        unused_ccx_req_burst_len;
    wire unused_ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        unused_ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        unused_ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        unused_ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        unused_ccx_wdata_beat_index;
    wire unused_ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        unused_ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        unused_ccx_wstrb;

    integer command_count;
    reg [63:0] command_addr [0:15];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] command_txn [0:15];
    integer store_command_count;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] store_command_txn;
    integer completion_count;
    reg expected_valid [0:TAG_COUNT-1];
    reg [63:0] expected_data [0:TAG_COUNT-1];
    reg completion_seen [0:TAG_COUNT-1];
    integer reset_index;
    integer cycles;
    reg [TAG_WIDTH-1:0] held_resp_tag;
    reg [63:0] held_resp_data;
    reg overlay_fill_seen;
    localparam [63:0] OVERLAY_STORE_DATA =
        64'hfeed_face_0123_4567;

    function automatic [63:0] memory_word;
        input [63:0] address;
        begin
            memory_word = address ^ 64'h4d53_4852_5f44_4154;
        end
    endfunction

    function automatic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] memory_line;
        input [63:0] address;
        integer word_index;
        begin
            memory_line = {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory_line[word_index*64 +: 64] =
                    memory_word({address[63:6], 6'b0} +
                                word_index * 8);
        end
    endfunction

    openrv64_l1d_ccx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(4),
        .DEMAND_MSHRS(DEMAND_MSHRS),
        .STORE_BUFFER_LINES(2),
        .PREFETCH_ENABLE(0),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .REQ_DEPTH(TAG_COUNT)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_lock_i(1'b0),
        .req_posted_i(1'b0),
        .req_write_i(req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(req_addr),
        .req_size_i(3'd3),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .req_rdata_o(req_rdata),
        .req_error_o(req_error),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_tag_o(resp_tag),
        .store_resp_valid_o(unused_store_resp_valid),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(unused_store_resp_error),
        .prefetch_issued_o(unused_prefetch_issued),
        .prefetch_useful_o(unused_prefetch_useful),
        .prefetch_late_o(unused_prefetch_late),
        .prefetch_dropped_o(unused_prefetch_dropped),
        .prefetch_useless_o(unused_prefetch_useless),
        .prefetch_depth_o(unused_prefetch_depth),
        .speculation_barrier_i(1'b0),
        .store_barrier_busy_o(unused_store_barrier_busy),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(unused_invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(1'b1),
        .ccx_req_hart_id_o(unused_ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(unused_ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_lock_o(unused_ccx_req_lock),
        .ccx_req_order_o(unused_ccx_req_order),
        .ccx_req_kind_o(unused_ccx_req_kind),
        .ccx_req_attr_o(unused_ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(unused_ccx_req_burst_len),
        .ccx_wdata_valid_o(unused_ccx_wdata_valid),
        .ccx_wdata_ready_i(1'b1),
        .ccx_wdata_hart_id_o(unused_ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(unused_ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(unused_ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(unused_ccx_wdata_beat_index),
        .ccx_wdata_last_o(unused_ccx_wdata_last),
        .ccx_wdata_o(unused_ccx_wdata),
        .ccx_wstrb_o(unused_ccx_wstrb),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(
            {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(`OPENRV64_CCX_SOURCE_DCACHE),
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
            command_count <= 0;
            store_command_count <= 0;
            completion_count <= 0;
            overlay_fill_seen <= 1'b0;
            for (reset_index = 0; reset_index < TAG_COUNT;
                 reset_index = reset_index + 1) begin
                expected_valid[reset_index] <= 1'b0;
                expected_data[reset_index] <= 64'd0;
                completion_seen[reset_index] <= 1'b0;
            end
        end else begin
            if (ccx_req_valid) begin
                if (ccx_req_size != 3'd6 ||
                    ccx_req_addr[5:0] != 0)
                    $fatal(1, "L1D emitted malformed CCX command");
                if (ccx_req_op == `OPENRV64_CCX_OP_READ) begin
                    command_addr[command_count] <= ccx_req_addr;
                    command_txn[command_count] <= ccx_req_txn_id;
                    command_count <= command_count + 1;
                end else if (ccx_req_op ==
                             `OPENRV64_CCX_OP_WRITE) begin
                    store_command_txn <= ccx_req_txn_id;
                    store_command_count <= store_command_count + 1;
                end else begin
                    $fatal(1, "L1D emitted unexpected CCX operation");
                end
            end
            if (resp_valid && resp_ready) begin
                if (!expected_valid[resp_tag])
                    $fatal(1,
                        "unexpected or duplicate response tag=%0d",
                        resp_tag);
                if (req_error)
                    $fatal(1, "demand response tag=%0d returned error",
                           resp_tag);
                if (req_rdata !== expected_data[resp_tag])
                    $fatal(1,
                        "response tag=%0d data=%016x expected=%016x",
                        resp_tag, req_rdata, expected_data[resp_tag]);
                expected_valid[resp_tag] <= 1'b0;
                completion_seen[resp_tag] <= 1'b1;
                completion_count <= completion_count + 1;
            end
            if (dut.l1_fill_fire &&
                (dut.l1_fill_addr == MEMORY_BASE) &&
                (dut.l1_fill_data[63:0] !== OVERLAY_STORE_DATA))
                $fatal(1,
                    "late same-line store was absent from installed fill");
            if (dut.l1_fill_fire &&
                (dut.l1_fill_addr == MEMORY_BASE))
                overlay_fill_seen <= 1'b1;
        end
    end

    task automatic issue_load;
        input [TAG_WIDTH-1:0] tag;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = tag;
            req_write = 1'b0;
            req_addr = address;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
            expected_valid[tag] = 1'b1;
            expected_data[tag] = memory_word(address);
            completion_seen[tag] = 1'b0;
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "load tag=%0d acceptance timed out", tag);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 64'd0;
        end
    endtask

    task automatic issue_store;
        input [TAG_WIDTH-1:0] tag;
        input [63:0] address;
        input [63:0] data;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = tag;
            req_write = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            expected_valid[tag] = 1'b1;
            expected_data[tag] = 64'd0;
            completion_seen[tag] = 1'b0;
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "store tag=%0d acceptance timed out", tag);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 64'd0;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
        end
    endtask

    task automatic wait_for_commands;
        input integer expected;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (command_count < expected && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (command_count != expected)
                $fatal(1, "CCX commands=%0d expected=%0d",
                       command_count, expected);
        end
    endtask

    task automatic return_command;
        input integer command_index;
        integer wait_cycles;
        begin
            @(negedge clk);
            ccx_resp_valid = 1'b1;
            ccx_resp_txn_id = command_txn[command_index];
            ccx_resp_rdata = memory_line(command_addr[command_index]);
            wait_cycles = 0;
            #1;
            while (!ccx_resp_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!ccx_resp_ready)
                $fatal(1, "CCX response %0d was not accepted",
                       command_index);
            @(posedge clk);
            @(negedge clk);
            ccx_resp_valid = 1'b0;
            ccx_resp_txn_id =
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            ccx_resp_rdata =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
        end
    endtask

    task automatic return_store;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (store_command_count == 0 &&
                   wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (store_command_count != 1)
                $fatal(1, "store commands=%0d expected=1",
                       store_command_count);
            @(negedge clk);
            ccx_resp_valid = 1'b1;
            ccx_resp_txn_id = store_command_txn;
            ccx_resp_rdata =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            wait_cycles = 0;
            #1;
            while (!ccx_resp_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!ccx_resp_ready)
                $fatal(1, "store CCX response was not accepted");
            @(posedge clk);
            @(negedge clk);
            ccx_resp_valid = 1'b0;
            ccx_resp_txn_id =
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
        end
    endtask

    task automatic wait_for_completions;
        input integer expected;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (completion_count < expected &&
                   wait_cycles < 200) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (completion_count != expected)
                $fatal(1, "completions=%0d expected=%0d",
                       completion_count, expected);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = {TAG_WIDTH{1'b0}};
        req_write = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        resp_ready = 1'b1;
        ccx_resp_valid = 1'b0;
        ccx_resp_txn_id =
            {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
        ccx_resp_rdata =
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Three independent lines allocate all three demand MSHRs before any
        // lower-level response returns.
        issue_load(TAG_WIDTH'(0), MEMORY_BASE + 64'h0000);
        issue_load(TAG_WIDTH'(1), MEMORY_BASE + 64'h1040);
        issue_load(TAG_WIDTH'(2), MEMORY_BASE + 64'h2080);
        wait_for_commands(3);
        if (command_addr[0] != MEMORY_BASE + 64'h0000 ||
            command_addr[1] != MEMORY_BASE + 64'h1040 ||
            command_addr[2] != MEMORY_BASE + 64'h2080)
            $fatal(1, "demand commands were reordered or misaddressed");
        if (command_txn[0] == command_txn[1] ||
            command_txn[0] == command_txn[2] ||
            command_txn[1] == command_txn[2])
            $fatal(1, "concurrent demand MSHRs reused a transaction ID");

        // A fourth unique line must backpressure while all entries remain
        // live.  The request is deliberately withdrawn without a handshake.
        @(negedge clk);
        req_valid = 1'b1;
        req_tag = TAG_WIDTH'(3);
        req_addr = MEMORY_BASE + 64'h30c0;
        #1;
        repeat (4) begin
            if (req_ready)
                $fatal(1, "fourth unique miss bypassed a full MSHR set");
            @(negedge clk);
            #1;
        end
        req_valid = 1'b0;
        req_addr = 64'd0;

        // Free one MSHR first, but leave the MEMORY_BASE miss outstanding.
        // This keeps the store test focused on same-line fill integration
        // rather than coupling it to full-MSHR backpressure.
        return_command(2);
        wait_for_completions(1);

        // A younger store to an outstanding line must update eventual cache
        // installation without forwarding into the older load response.
        issue_store(TAG_WIDTH'(3), MEMORY_BASE, OVERLAY_STORE_DATA);
        return_store();
        wait_for_completions(2);

        // Return the lines in reverse/mixed order.  Tag-qualified completion
        // must still associate each word with its original requester.
        return_command(0);
        return_command(1);
        wait_for_completions(4);
        if (!completion_seen[0] || !completion_seen[1] ||
            !completion_seen[2])
            $fatal(1, "not every independent demand completed");
        if (!overlay_fill_seen)
            $fatal(1, "same-line store overlay was never installed");

        // Two words from one absent line share one CCX transaction but retain
        // independent response tags and word selection.
        issue_load(TAG_WIDTH'(4), MEMORY_BASE + 64'h4000);
        issue_load(TAG_WIDTH'(5), MEMORY_BASE + 64'h4008);
        wait_for_commands(4);
        repeat (4) @(negedge clk);
        if (command_count != 4)
            $fatal(1, "same-line demands launched duplicate CCX reads");
        return_command(3);
        wait_for_completions(6);
        if (!completion_seen[4] || !completion_seen[5])
            $fatal(1, "same-line merged waiters did not both complete");

        // A completed miss may install its line while the northbound response
        // is backpressured, but tag and data must remain stable.
        resp_ready = 1'b0;
        issue_load(TAG_WIDTH'(6), MEMORY_BASE + 64'h5040);
        wait_for_commands(5);
        return_command(4);
        while (!resp_valid)
            @(negedge clk);
        held_resp_tag = resp_tag;
        held_resp_data = req_rdata;
        repeat (4) begin
            @(negedge clk);
            if (!resp_valid || resp_tag != held_resp_tag ||
                req_rdata !== held_resp_data)
                $fatal(1,
                    "backpressured demand response was not held stable");
        end
        resp_ready = 1'b1;
        wait_for_completions(7);

        // The installed line must subsequently hit without another CCX read.
        issue_load(TAG_WIDTH'(7), MEMORY_BASE + 64'h5048);
        wait_for_completions(8);
        if (command_count != 5)
            $fatal(1, "resident line reissued a demand CCX read");

        $display(
            "PASS: three demand MSHRs, OOO matching, merge, store overlay, and hold");
        $finish;
    end

    initial begin
        cycles = 0;
        forever begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 2000)
                $fatal(1, "L1D demand MSHR test timed out");
        end
    end

endmodule
