`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_invalidate_arbiter;

    localparam [63:0] TARGET_ADDR = 64'h0000_0000_8000_1000;
    localparam [63:0] ATOMIC_ADDR = 64'h0000_0000_8000_1048;
    localparam [63:0] TARGET_WORD = 64'h1122_3344_5566_7788;
    localparam [63:0] ATOMIC_WORD = 64'h8877_6655_4433_2211;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] req_tag;
    reg req_lock;
    reg req_write;
    reg [63:0] req_addr;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;

    reg invalidate_valid;
    wire invalidate_ready;
    reg [63:0] invalidate_addr;

    wire icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire icx_wdata_valid;

    reg icx_resp_valid;
    wire icx_resp_ready;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;

    reg response_pending_q;
    integer response_delay_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] response_hart_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] response_txn_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] response_source_q;
    reg [`OPENRV64_ICX_OP_WIDTH-1:0] response_op_q;
    reg [63:0] response_addr_q;
    integer target_read_commands;
    integer wait_cycles;

    function automatic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory_line;
        input [63:0] address;
        reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] line;
        begin
            line = {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            if ({address[63:6], 6'b0} == TARGET_ADDR)
                line[63:0] = TARGET_WORD;
            else if ({address[63:6], 6'b0} ==
                     {ATOMIC_ADDR[63:6], 6'b0})
                line[127:64] = ATOMIC_WORD;
            memory_line = line;
        end
    endfunction

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .SYNC_TAG_LOOKUP(1),
        .FILL_BUFFER_LINES(2),
        .DEMAND_MSHRS(1),
        .STORE_BUFFER_LINES(2),
        .PREFETCH_ENABLE(0),
        .PREFETCH_OUTSTANDING(1),
        .PREFETCH_DEMAND_RESERVE(1),
        .COHERENT_ATOMICS(1),
        .REQ_DEPTH(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_lock_i(req_lock),
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
        .resp_ready_i(1'b1),
        .resp_tag_o(resp_tag),
        .posted_resp_valid_o(),
        .posted_resp_ready_i(1'b1),
        .posted_resp_tag_o(),
        .store_resp_valid_o(),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(),
        .prefetch_issued_o(),
        .prefetch_useful_o(),
        .prefetch_late_o(),
        .prefetch_dropped_o(),
        .prefetch_useless_o(),
        .prefetch_depth_o(),
        .speculation_barrier_i(1'b0),
        .completion_fence_i(1'b0),
        .store_barrier_busy_o(),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(1'b0),
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
        .icx_wdata_o(),
        .icx_wstrb_o(),
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
        .icx_resp_sc_success_i(1'b1)
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
            response_pending_q <= 1'b0;
            response_delay_q <= 0;
            response_hart_q <= 0;
            response_txn_q <= 0;
            response_source_q <= 0;
            response_op_q <= 0;
            response_addr_q <= 0;
            target_read_commands <= 0;
        end else begin
            if (icx_req_valid) begin
                if (response_pending_q || icx_resp_valid)
                    $fatal(1, "test ICX accepted overlapping requests");
                if ((icx_req_op != `OPENRV64_ICX_OP_READ) &&
                    (icx_req_op != `OPENRV64_ICX_OP_SC))
                    $fatal(1, "unexpected ICX op=%0d", icx_req_op);
                if ((icx_req_op == `OPENRV64_ICX_OP_SC) &&
                    !icx_wdata_valid)
                    $fatal(1, "SC command lacked write data");
                response_pending_q <= 1'b1;
                response_delay_q <= 2;
                response_hart_q <= icx_req_hart_id;
                response_txn_q <= icx_req_txn_id;
                response_source_q <= icx_req_source_id;
                response_op_q <= icx_req_op;
                response_addr_q <= icx_req_addr;
                if ((icx_req_op == `OPENRV64_ICX_OP_READ) &&
                    ({icx_req_addr[63:6], 6'b0} == TARGET_ADDR))
                    target_read_commands <= target_read_commands + 1;
            end

            if (response_pending_q && (response_delay_q != 0))
                response_delay_q <= response_delay_q - 1;
            if (response_pending_q && (response_delay_q == 0) &&
                !icx_resp_valid) begin
                icx_resp_valid <= 1'b1;
                icx_resp_hart_id <= response_hart_q;
                icx_resp_txn_id <= response_txn_q;
                icx_resp_source_id <= response_source_q;
                icx_resp_rdata <=
                    (response_op_q == `OPENRV64_ICX_OP_READ) ?
                    memory_line(response_addr_q) :
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            end
            if (icx_resp_valid && icx_resp_ready) begin
                icx_resp_valid <= 1'b0;
                response_pending_q <= 1'b0;
            end
        end
    end

    task automatic issue_load;
        input [63:0] address;
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag;
        integer cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = tag;
            req_lock = 1'b0;
            req_write = 1'b0;
            req_addr = address;
            cycles = 0;
            while (!req_ready && (cycles < 200)) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "load request timed out addr=%016x", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 0;
            cycles = 0;
            while (!resp_valid && (cycles < 200)) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!resp_valid || req_error || (resp_tag != tag) ||
                (req_rdata !== TARGET_WORD))
                $fatal(1,
                    "load response failed valid=%0d error=%0d tag=%0d data=%016x",
                    resp_valid, req_error, resp_tag, req_rdata);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = 0;
        req_lock = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        invalidate_valid = 1'b0;
        invalidate_addr = 0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Install the target line.  The post-invalidate load must miss again.
        issue_load(TARGET_ADDR, 1);
        if (target_read_commands != 1)
            $fatal(1, "initial target load did not reach ICX");

        // Start an unrelated marked write.  Its local self-invalidate owns the
        // generic L1 tag lookup for one cycle.  Present the external snoop only
        // after that lookup is pending: delayed ready for the local operation
        // must not acknowledge this newly arrived external address.
        @(negedge clk);
        req_valid = 1'b1;
        req_tag = 2;
        req_lock = 1'b1;
        req_write = 1'b1;
        req_addr = ATOMIC_ADDR;
        req_wdata = 64'hdead_beef_cafe_f00d;
        req_wstrb = 8'hff;
        wait_cycles = 0;
        while (!dut.u_l1d.u_l1.g_cache.u_cache.u_debug.sync_invalidate_probe_q &&
               (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!dut.u_l1d.u_l1.g_cache.u_cache.u_debug.sync_invalidate_probe_q)
            $fatal(1, "local atomic invalidate did not enter tag pipeline");

        invalidate_valid = 1'b1;
        invalidate_addr = TARGET_ADDR;
        #1;
        if (invalidate_ready)
            $fatal(1,
                "external invalidate consumed completion of local invalidate");

        wait_cycles = 0;
        while (!invalidate_ready && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!invalidate_ready)
            $fatal(1, "external invalidate did not complete separately");
        if ({dut.l1_invalidate_addr[63:6], 6'b0} != TARGET_ADDR)
            $fatal(1, "external completion carried wrong address=%016x",
                   dut.l1_invalidate_addr);
        @(posedge clk);
        @(negedge clk);
        invalidate_valid = 1'b0;
        invalidate_addr = 0;

        wait_cycles = 0;
        while (!req_ready && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "marked write did not resume after snoop");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_lock = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        wait_cycles = 0;
        while (!resp_valid && (wait_cycles < 200)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!resp_valid || req_error || (resp_tag != 2))
            $fatal(1, "marked write did not complete");

        issue_load(TARGET_ADDR, 3);
        if (target_read_commands != 2)
            $fatal(1,
                "target line remained resident after external invalidate reads=%0d",
                target_read_commands);

        $display("PASS: external invalidate cannot consume local invalidate completion");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "L1D invalidate-arbiter test timed out");
    end

endmodule
