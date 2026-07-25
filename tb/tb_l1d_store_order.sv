`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_store_order;

    localparam [63:0] LINE_ADDR = 64'h0000_0000_8000_1000;
    localparam [63:0] STORE_ADDR = LINE_ADDR + 64'd8;
    localparam [63:0] STORE_DATA = 64'h8011_9e8c_cafe_f00d;

    reg clk;
    reg rst_n;

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
    reg resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;
    wire posted_resp_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] posted_resp_tag;

    wire store_resp_valid;
    reg store_resp_ready;
    wire store_resp_error;

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
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_ready;

    reg response_pending_q;
    reg response_write_q;
    integer response_delay_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] response_hart_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] response_txn_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] response_source_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] memory_line_q;
    integer write_commands;
    integer read_commands;
    integer byte_index;
    integer wait_cycles;

    openrv64_l1d_ccx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(2),
        .STORE_BUFFER_LINES(4),
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
        .resp_ready_i(resp_ready),
        .resp_tag_o(resp_tag),
        .posted_resp_valid_o(posted_resp_valid),
        .posted_resp_ready_i(1'b1),
        .posted_resp_tag_o(posted_resp_tag),
        .store_resp_valid_o(store_resp_valid),
        .store_resp_ready_i(store_resp_ready),
        .store_resp_error_o(store_resp_error),
        .prefetch_issued_o(),
        .prefetch_useful_o(),
        .prefetch_late_o(),
        .prefetch_dropped_o(),
        .prefetch_useless_o(),
        .prefetch_depth_o(),
        .speculation_barrier_i(1'b0),
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
            response_pending_q <= 1'b0;
            response_write_q <= 1'b0;
            response_delay_q <= 0;
            response_hart_q <= 0;
            response_txn_q <= 0;
            response_source_q <= 0;
            memory_line_q <= 512'h0123_4567_89ab_cdef;
            write_commands <= 0;
            read_commands <= 0;
        end else begin
            if (ccx_req_valid) begin
                if (response_pending_q || ccx_resp_valid)
                    $fatal(1, "test CCX accepted overlapping main requests");
                if (ccx_req_size != 3'd6 || ccx_req_addr != LINE_ADDR)
                    $fatal(1,
                        "unexpected CCX request size=%0d addr=%016x",
                        ccx_req_size, ccx_req_addr);
                response_pending_q <= 1'b1;
                response_write_q <=
                    ccx_req_op == `OPENRV64_CCX_OP_WRITE;
                response_delay_q <= 4;
                response_hart_q <= ccx_req_hart_id;
                response_txn_q <= ccx_req_txn_id;
                response_source_q <= ccx_req_source_id;
                if (ccx_req_op == `OPENRV64_CCX_OP_WRITE) begin
                    write_commands <= write_commands + 1;
                    if (!ccx_wdata_valid)
                        $fatal(1, "write command lacked same-cycle data");
                    for (byte_index = 0; byte_index < 64;
                         byte_index = byte_index + 1)
                        if (ccx_wstrb[byte_index])
                            memory_line_q[byte_index*8 +: 8] <=
                                ccx_wdata[byte_index*8 +: 8];
                end else if (ccx_req_op == `OPENRV64_CCX_OP_READ) begin
                    read_commands <= read_commands + 1;
                end else begin
                    $fatal(1, "unexpected CCX operation");
                end
            end

            if (response_pending_q && (response_delay_q != 0))
                response_delay_q <= response_delay_q - 1;
            if (response_pending_q && (response_delay_q == 0) &&
                !ccx_resp_valid) begin
                ccx_resp_valid <= 1'b1;
                ccx_resp_hart_id <= response_hart_q;
                ccx_resp_txn_id <= response_txn_q;
                ccx_resp_source_id <= response_source_q;
                ccx_resp_rdata <= response_write_q ? 512'd0 :
                                  memory_line_q;
            end
            if (ccx_resp_valid && ccx_resp_ready) begin
                ccx_resp_valid <= 1'b0;
                response_pending_q <= 1'b0;
            end
        end
    end

    task automatic issue_store;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = 0;
            req_write = 1'b1;
            req_addr = STORE_ADDR;
            req_wdata = STORE_DATA;
            req_wstrb = 8'hff;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 0;
            req_wdata = 0;
            req_wstrb = 0;
            wait_cycles = 0;
            while (!posted_resp_valid && (wait_cycles < 100)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!posted_resp_valid || (posted_resp_tag != 0))
                $fatal(1, "posted store did not complete northbound");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = 0;
        req_write = 1'b0;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        resp_ready = 1'b1;
        store_resp_ready = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        issue_store();

        // Present the dependent load while the store is still buffered.  The
        // load may reach CCX for the clean base line, but its returned word
        // must be overlaid from the older dirty store without forcing that
        // partial line to drain.
        @(negedge clk);
        req_valid = 1'b1;
        req_tag = 1;
        req_write = 1'b0;
        req_addr = STORE_ADDR;
        wait_cycles = 0;
        while (!req_ready && (wait_cycles < 20)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "dependent load did not snoop buffered store");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_addr = 0;

        wait_cycles = 0;
        while (!resp_valid && (wait_cycles < 100)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        #1;
        if (!resp_valid || req_error || (resp_tag != 1))
            $fatal(1, "dependent load did not complete");
        if (req_rdata !== STORE_DATA)
            $fatal(1, "dependent load data=%016x expected=%016x",
                   req_rdata, STORE_DATA);
        if ((write_commands != 0) || (read_commands != 1) ||
            (dut.store_buffer_count_q != 1))
            $fatal(1, "unexpected CCX command counts w=%0d r=%0d",
                   write_commands, read_commands);

        $display("PASS: same-line load forwards buffered dirty bytes without draining");
        $finish;
    end

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "L1D store-order test timed out");
    end

endmodule
