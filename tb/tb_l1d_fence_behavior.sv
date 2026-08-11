`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_fence_behavior;

    localparam [63:0] BEFORE_ADDR = 64'h0000_0000_8000_4000;
    localparam [63:0] AFTER_ADDR  = 64'h0000_0000_8000_4040;
    localparam [63:0] BEFORE_OLD  = 64'h1111_2222_3333_4444;
    localparam [63:0] BEFORE_NEW  = 64'haaaa_bbbb_cccc_dddd;
    localparam [63:0] AFTER_OLD   = 64'h5555_6666_7777_8888;
    localparam [63:0] AFTER_NEW   = 64'heeee_ffff_0000_1111;
    localparam integer STORE_RESPONSE_DELAY = 10;
    localparam integer FENCE_RESPONSE_DELAY = 12;
    localparam integer PERF_ITERATIONS = 1024;
    localparam integer TIMEOUT_CYCLES = 1000;
    localparam integer TEST_TIMEOUT_CYCLES =
        PERF_ITERATIONS * (FENCE_RESPONSE_DELAY + 24) + 5000;

    reg clk;
    reg rst_n;
    integer cycle_count;

    reg req_valid;
    wire req_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] req_tag;
    reg req_write;
    reg [63:0] req_addr;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;
    wire posted_resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] posted_resp_tag;

    reg speculation_barrier;
    reg completion_fence;
    wire store_barrier_busy;

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

    reg response_pending_q;
    reg [`OPENRV64_ICX_OP_WIDTH-1:0] response_op_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] response_hart_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] response_txn_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] response_source_q;
    reg [63:0] response_addr_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] response_wdata_q;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] response_wstrb_q;
    integer response_delay_q;

    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory [0:3];
    integer memory_byte;
    integer memory_line;
    integer write_commands;
    integer fence_commands;
    integer last_write_response_cycle;
    integer last_fence_request_cycle;
    integer last_fence_response_cycle;
    reg require_before_visible_on_fence;
    reg require_before_visible_on_after_write;

    integer wait_cycles;
    integer barrier_start_cycle;
    integer barrier_cycles;
    integer relaxed_total_cycles;
    integer acknowledged_total_cycles;
    integer relaxed_fence_count;
    integer acknowledged_fence_start;
    integer perf_index;

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(2),
        .STORE_BUFFER_LINES(4),
        .STORE_BUFFER_TIMEOUT_CYCLES(256),
        .PREFETCH_ENABLE(0),
        .PREFETCH_OUTSTANDING(1),
        .PREFETCH_DEMAND_RESERVE(1),
        .REQ_DEPTH(4)
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
        .completion_fence_i(completion_fence),
        .store_barrier_busy_o(store_barrier_busy),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
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
            cycle_count <= 0;
            icx_resp_valid <= 1'b0;
            icx_resp_hart_id <= 0;
            icx_resp_txn_id <= 0;
            icx_resp_source_id <= 0;
            icx_resp_rdata <= 0;
            response_pending_q <= 1'b0;
            response_op_q <= `OPENRV64_ICX_OP_READ;
            response_hart_q <= 0;
            response_txn_q <= 0;
            response_source_q <= 0;
            response_addr_q <= 0;
            response_wdata_q <= 0;
            response_wstrb_q <= 0;
            response_delay_q <= 0;
            write_commands <= 0;
            fence_commands <= 0;
            last_write_response_cycle <= -1;
            last_fence_request_cycle <= -1;
            last_fence_response_cycle <= -1;
            for (memory_line = 0; memory_line < 4;
                 memory_line = memory_line + 1)
                memory[memory_line] <= 0;
            memory[BEFORE_ADDR[7:6]][63:0] <= BEFORE_OLD;
            memory[AFTER_ADDR[7:6]][63:0] <= AFTER_OLD;
        end else begin
            cycle_count <= cycle_count + 1;

            if (response_pending_q && !icx_resp_valid &&
                (response_delay_q != 0))
                response_delay_q <= response_delay_q - 1;
            if (response_pending_q && !icx_resp_valid &&
                (response_delay_q == 0)) begin
                icx_resp_valid <= 1'b1;
                icx_resp_hart_id <= response_hart_q;
                icx_resp_txn_id <= response_txn_q;
                icx_resp_source_id <= response_source_q;
                icx_resp_rdata <= 0;
            end

            if (icx_resp_valid && icx_resp_ready) begin
                icx_resp_valid <= 1'b0;
                response_pending_q <= 1'b0;
                if (response_op_q == `OPENRV64_ICX_OP_WRITE) begin
                    for (memory_byte = 0;
                         memory_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
                         memory_byte = memory_byte + 1)
                        if (response_wstrb_q[memory_byte])
                            memory[response_addr_q[7:6]][
                                memory_byte*8 +: 8] <=
                                response_wdata_q[memory_byte*8 +: 8];
                    last_write_response_cycle <= cycle_count;
                    if (require_before_visible_on_after_write &&
                        (response_addr_q == AFTER_ADDR) &&
                        (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_NEW))
                        $fatal(1,
                            "subsequent write became visible while preceding value was stale");
                end else if (response_op_q == `OPENRV64_ICX_OP_FENCE) begin
                    last_fence_response_cycle <= cycle_count;
                end
            end

            if (icx_req_valid) begin
                if (response_pending_q &&
                    !(icx_resp_valid && icx_resp_ready))
                    $fatal(1, "fence test responder saw overlapping requests");
                if ((icx_req_op != `OPENRV64_ICX_OP_WRITE) &&
                    (icx_req_op != `OPENRV64_ICX_OP_FENCE))
                    $fatal(1, "unexpected ICX op=%0d", icx_req_op);
                if ((icx_req_op == `OPENRV64_ICX_OP_WRITE) &&
                    ((icx_req_size != 3'd6) || !icx_wdata_valid))
                    $fatal(1, "malformed write preceding fence");
                if ((icx_req_op == `OPENRV64_ICX_OP_FENCE) &&
                    ((icx_req_size != 3'd0) || icx_wdata_valid))
                    $fatal(1, "malformed completion fence");
                response_pending_q <= 1'b1;
                response_op_q <= icx_req_op;
                response_hart_q <= icx_req_hart_id;
                response_txn_q <= icx_req_txn_id;
                response_source_q <= icx_req_source_id;
                response_addr_q <= icx_req_addr;
                response_wdata_q <= icx_wdata;
                response_wstrb_q <= icx_wstrb;
                response_delay_q <=
                    (icx_req_op == `OPENRV64_ICX_OP_FENCE) ?
                    FENCE_RESPONSE_DELAY : STORE_RESPONSE_DELAY;
                if (icx_req_op == `OPENRV64_ICX_OP_WRITE)
                    write_commands <= write_commands + 1;
                else begin
                    fence_commands <= fence_commands + 1;
                    last_fence_request_cycle <= cycle_count;
                    if (require_before_visible_on_fence &&
                        (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_NEW))
                        $fatal(1,
                            "L2 fence issued before preceding write became externally visible");
                end
            end
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
            completion_fence = 1'b0;
            require_before_visible_on_fence = 1'b0;
            require_before_visible_on_after_write = 1'b0;
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
            while (!req_ready && (wait_cycles < TIMEOUT_CYCLES)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "store acceptance timed out");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 0;
            req_wdata = 0;
            req_wstrb = 0;
            wait_cycles = 0;
            while (!posted_resp_valid &&
                   (wait_cycles < TIMEOUT_CYCLES)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!posted_resp_valid || (posted_resp_tag != req_tag))
                $fatal(1, "posted store response failed");
            @(posedge clk);
        end
    endtask

    task automatic start_barrier;
        output integer start_cycle;
        begin
            @(negedge clk);
            start_cycle = cycle_count;
            speculation_barrier = 1'b1;
            #1;
            if (!store_barrier_busy)
                $fatal(1, "barrier did not assert busy immediately");
            @(posedge clk);
            @(negedge clk);
            speculation_barrier = 1'b0;
        end
    endtask

    task automatic wait_barrier;
        input integer start_cycle;
        output integer elapsed_cycles;
        begin
            wait_cycles = 0;
            while (store_barrier_busy &&
                   (wait_cycles < TIMEOUT_CYCLES)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (store_barrier_busy)
                $fatal(1, "barrier completion timed out");
            elapsed_cycles = cycle_count - start_cycle;
        end
    endtask

    initial begin
        reset_dut();

        // Relaxed mode is still a correctness barrier for older posted
        // stores: busy may clear only after their downstream responses make
        // the writes externally visible.  It must not emit an ICX fence.
        completion_fence = 1'b0;
        issue_store(BEFORE_ADDR, BEFORE_NEW);
        if ((write_commands != 0) ||
            (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_OLD))
            $fatal(1, "relaxed-fence setup store drained prematurely");
        start_barrier(barrier_start_cycle);
        repeat (4) begin
            @(negedge clk);
            if (!store_barrier_busy)
                $fatal(1, "relaxed fence ignored pending store response");
            if (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_OLD)
                $fatal(1, "delayed store became visible too early");
        end
        wait_barrier(barrier_start_cycle, barrier_cycles);
        if ((fence_commands != 0) || (write_commands != 1) ||
            (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_NEW) ||
            (last_write_response_cycle < barrier_start_cycle))
            $fatal(1,
                "relaxed fence failed drain/visibility fence=%0d writes=%0d",
                fence_commands, write_commands);

        // A write after the barrier cannot become externally visible while
        // an observer could still obtain the old preceding value.
        require_before_visible_on_after_write = 1'b1;
        issue_store(AFTER_ADDR, AFTER_NEW);
        start_barrier(barrier_start_cycle);
        wait_barrier(barrier_start_cycle, barrier_cycles);
        if (memory[AFTER_ADDR[7:6]][63:0] !== AFTER_NEW)
            $fatal(1, "subsequent relaxed-mode write did not complete");

        reset_dut();

        // Acknowledged mode adds one ordered ICX fence after the same local
        // drain and holds busy through the deliberately delayed response.
        completion_fence = 1'b1;
        require_before_visible_on_fence = 1'b1;
        issue_store(BEFORE_ADDR, BEFORE_NEW);
        start_barrier(barrier_start_cycle);
        wait_cycles = 0;
        while ((fence_commands == 0) &&
               (wait_cycles < TIMEOUT_CYCLES)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if ((fence_commands != 1) || !store_barrier_busy ||
            (memory[BEFORE_ADDR[7:6]][63:0] !== BEFORE_NEW) ||
            (last_write_response_cycle > last_fence_request_cycle))
            $fatal(1, "acknowledged fence violated write/fence ordering");
        repeat (FENCE_RESPONSE_DELAY / 2) begin
            @(negedge clk);
            if (!store_barrier_busy)
                $fatal(1, "acknowledged fence released before L2 response");
        end
        wait_barrier(barrier_start_cycle, barrier_cycles);
        if ((last_fence_response_cycle < last_fence_request_cycle) ||
            (last_fence_response_cycle > cycle_count))
            $fatal(1, "acknowledged fence response was not observed");

        // Performance regression: identical empty barriers are measured in
        // both modes against the same fixed-latency responder.  Exact cycle
        // totals are printed; broad bounds catch accidental L2 transactions
        // in relaxed mode and unbounded extra serialization in either mode.
        reset_dut();
        relaxed_total_cycles = 0;
        completion_fence = 1'b0;
        for (perf_index = 0; perf_index < PERF_ITERATIONS;
             perf_index = perf_index + 1) begin
            start_barrier(barrier_start_cycle);
            wait_barrier(barrier_start_cycle, barrier_cycles);
            relaxed_total_cycles = relaxed_total_cycles + barrier_cycles;
        end
        relaxed_fence_count = fence_commands;
        if (relaxed_fence_count != 0)
            $fatal(1, "relaxed performance loop emitted %0d fences",
                   relaxed_fence_count);

        completion_fence = 1'b1;
        acknowledged_fence_start = fence_commands;
        acknowledged_total_cycles = 0;
        for (perf_index = 0; perf_index < PERF_ITERATIONS;
             perf_index = perf_index + 1) begin
            start_barrier(barrier_start_cycle);
            wait_barrier(barrier_start_cycle, barrier_cycles);
            acknowledged_total_cycles =
                acknowledged_total_cycles + barrier_cycles;
        end
        if ((fence_commands - acknowledged_fence_start) !=
            PERF_ITERATIONS)
            $fatal(1,
                "acknowledged loop fence count=%0d expected=%0d",
                fence_commands - acknowledged_fence_start,
                PERF_ITERATIONS);
        if (relaxed_total_cycles > PERF_ITERATIONS * 8)
            $fatal(1, "relaxed fences regressed to %0d cycles",
                   relaxed_total_cycles);
        if (acknowledged_total_cycles >
            PERF_ITERATIONS * (FENCE_RESPONSE_DELAY + 12))
            $fatal(1, "acknowledged fences regressed to %0d cycles",
                   acknowledged_total_cycles);
        if ((acknowledged_total_cycles - relaxed_total_cycles) <
            PERF_ITERATIONS * FENCE_RESPONSE_DELAY)
            $fatal(1,
                "acknowledged path did not expose injected L2 latency delta=%0d",
                acknowledged_total_cycles - relaxed_total_cycles);

        $display(
            "PERF: fences=%0d relaxed_cycles=%0d acknowledged_cycles=%0d delta_cycles=%0d",
            PERF_ITERATIONS, relaxed_total_cycles,
            acknowledged_total_cycles,
            acknowledged_total_cycles - relaxed_total_cycles);
        $display(
            "PASS: relaxed and acknowledged L1D fence correctness and performance behavior");
        $finish;
    end

    initial begin
        repeat (TEST_TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "L1D fence behavior test timed out");
    end

endmodule
