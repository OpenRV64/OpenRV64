`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_ccx_l2;

    localparam integer MEMORY_LINES = 256;
    localparam [63:0] PTE_LINE_ADDR = 64'h0000_0000_0000_1000;

    logic clk;
    logic rst_n;

    logic req_valid;
    wire req_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] req_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] req_source_id;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] req_op;
    logic req_lock;
    logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] req_order;
    logic [`OPENRV64_CCX_KIND_WIDTH-1:0] req_kind;
    logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] req_attr;
    logic [2:0] req_size;
    logic [63:0] req_addr;
    logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] req_burst_len;

    logic wdata_valid;
    wire wdata_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] wdata_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] wdata_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] wdata_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] wdata_beat_index;
    logic wdata_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] wdata;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] wstrb;

    wire resp_valid;
    logic resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] resp_beat_index;
    wire resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] resp_rdata;
    wire resp_error;
    wire resp_sc_success;

    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_req_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    logic bus_resp_valid;
    wire bus_resp_ready;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_resp_rdata;

    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    logic bus_pending_q;
    logic pending_write_q;
    logic [63:0] pending_addr_q;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] pending_wdata_q;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] pending_wstrb_q;
    integer bus_reads;
    integer bus_writes;
    integer byte_index;
    integer memory_index;
    integer txn_counter;

    openrv64_ccx_l2_native #(
        .CACHE_BYTES(256 * 1024),
        .WAYS(8),
        .MSHR_ENTRIES(2),
        .WAITERS_PER_MSHR(4),
        .COMMAND_ENTRIES(4),
        .RESPONSE_ENTRIES(4),
        .BUS_TRACK_ENTRIES(2),
        .PTE_GENERATION_BITS(8)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_hart_id_i(req_hart_id),
        .req_txn_id_i(req_txn_id),
        .req_source_id_i(req_source_id),
        .req_op_i(req_op),
        .req_lock_i(req_lock),
        .req_order_i(req_order),
        .req_kind_i(req_kind),
        .req_attr_i(req_attr),
        .req_size_i(req_size),
        .req_addr_i(req_addr),
        .req_burst_len_i(req_burst_len),
        .wdata_valid_i(wdata_valid),
        .wdata_ready_o(wdata_ready),
        .wdata_hart_id_i(wdata_hart_id),
        .wdata_txn_id_i(wdata_txn_id),
        .wdata_source_id_i(wdata_source_id),
        .wdata_beat_index_i(wdata_beat_index),
        .wdata_last_i(wdata_last),
        .wdata_i(wdata),
        .wstrb_i(wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_hart_id_o(resp_hart_id),
        .resp_txn_id_o(resp_txn_id),
        .resp_source_id_o(resp_source_id),
        .resp_beat_index_o(resp_beat_index),
        .resp_last_o(resp_last),
        .resp_rdata_o(resp_rdata),
        .resp_error_o(resp_error),
        .resp_sc_success_o(resp_sc_success),
        .bus_req_valid_o(bus_req_valid),
        .bus_req_ready_i(bus_req_ready),
        .bus_req_write_o(bus_req_write),
        .bus_req_addr_o(bus_req_addr),
        .bus_req_size_o(bus_req_size),
        .bus_req_wdata_o(bus_req_wdata),
        .bus_req_wstrb_o(bus_req_wstrb),
        .bus_req_cacheable_o(bus_req_cacheable),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_o(bus_resp_ready),
        .bus_resp_rdata_i(bus_resp_rdata),
        .bus_resp_error_i(1'b0)
    );

    assign bus_req_ready = !bus_pending_q && !bus_resp_valid;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] line_pattern;
        input [63:0] seed;
        integer word_index;
        begin
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                line_pattern[word_index*64 +: 64] =
                    seed + word_index;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_pending_q <= 1'b0;
            pending_write_q <= 1'b0;
            pending_addr_q <= 0;
            pending_wdata_q <= 0;
            pending_wstrb_q <= 0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <= 0;
            bus_reads <= 0;
            bus_writes <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if ((bus_req_size != 3'd6) ||
                    (bus_req_addr[5:0] != 0) || !bus_req_cacheable)
                    $fatal(1, "native L2 emitted malformed line request");
                bus_pending_q <= 1'b1;
                pending_write_q <= bus_req_write;
                pending_addr_q <= bus_req_addr;
                pending_wdata_q <= bus_req_wdata;
                pending_wstrb_q <= bus_req_wstrb;
                if (bus_req_write)
                    bus_writes <= bus_writes + 1;
                else
                    bus_reads <= bus_reads + 1;
            end

            if (bus_pending_q && !bus_resp_valid) begin
                memory_index = pending_addr_q[13:6];
                bus_resp_rdata <= memory[memory_index];
                if (pending_write_q) begin
                    for (byte_index = 0;
                         byte_index < `OPENRV64_CCX_LINE_STRB_WIDTH;
                         byte_index = byte_index + 1)
                        if (pending_wstrb_q[byte_index])
                            memory[memory_index][byte_index*8 +: 8] <=
                                pending_wdata_q[byte_index*8 +: 8];
                end
                bus_resp_valid <= 1'b1;
                bus_pending_q <= 1'b0;
            end
        end
    end

    task automatic send_command;
        input [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] source;
        input [`OPENRV64_CCX_OP_WIDTH-1:0] operation;
        input [`OPENRV64_CCX_KIND_WIDTH-1:0] kind;
        input [`OPENRV64_CCX_ATTR_WIDTH-1:0] attributes;
        input [2:0] size;
        input [63:0] address;
        output [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        integer cycles;
        begin
            transaction =
                txn_counter[`OPENRV64_CCX_TXN_ID_WIDTH-1:0];
            txn_counter = txn_counter + 1;
            @(negedge clk);
            req_hart_id = 0;
            req_txn_id = transaction;
            req_source_id = source;
            req_op = operation;
            req_lock = 1'b0;
            req_order = (operation == `OPENRV64_CCX_OP_FENCE) ?
                        `OPENRV64_CCX_ORDER_ACQ_REL :
                        `OPENRV64_CCX_ORDER_NONE;
            req_kind = kind;
            req_attr = attributes;
            req_size = size;
            req_addr = address;
            req_burst_len = 0;
            req_valid = 1'b1;
            cycles = 0;
            while (!req_ready && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "native L2 command timed out");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic send_write_data;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        integer cycles;
        begin
            wdata_hart_id = 0;
            wdata_txn_id = transaction;
            wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            wdata_beat_index = 0;
            wdata_last = 1'b1;
            wdata = data;
            wstrb = {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}};
            wdata_valid = 1'b1;
            cycles = 0;
            @(posedge clk);
            while (!wdata_ready && cycles < 100) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!wdata_ready)
                $fatal(1,
                    "native L2 write data timed out: count=%0d head=%0d op=%0d txn=%0d expected_txn=%0d source=%0d expected_source=%0d beat=%0d expected_beat=%0d buffered=%0b",
                    dut.cmd_count_q, dut.cmd_head_q,
                    dut.cmd_op_q[dut.cmd_head_q],
                    wdata_txn_id, dut.cmd_txn_id_q[dut.cmd_head_q],
                    wdata_source_id,
                    dut.cmd_source_id_q[dut.cmd_head_q],
                    wdata_beat_index, dut.cmd_beat_q,
                    dut.cmd_wdata_valid_q);
            @(negedge clk);
            wdata_valid = 1'b0;
        end
    endtask

    task automatic wait_response;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] source;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] expected_data;
        input check_data;
        integer cycles;
        begin
            cycles = 0;
            while (!resp_valid && cycles < 500) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!resp_valid || resp_hart_id != 0 ||
                resp_txn_id != transaction || resp_source_id != source ||
                resp_beat_index != 0 || !resp_last || resp_error ||
                resp_sc_success)
                $fatal(1, "native L2 response envelope mismatch");
            if (check_data && (resp_rdata !== expected_data))
                $fatal(1, "native L2 response data mismatch");
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic read_line;
        input [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] source;
        input [`OPENRV64_CCX_KIND_WIDTH-1:0] kind;
        input [63:0] address;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] expected_data;
        reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            send_command(source, `OPENRV64_CCX_OP_READ, kind,
                         `OPENRV64_CCX_ATTR_CACHEABLE, 3'd6,
                         address, transaction);
            wait_response(transaction, source, expected_data, 1'b1);
        end
    endtask

    task automatic write_line;
        input [63:0] address;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                         `OPENRV64_CCX_OP_WRITE,
                         `OPENRV64_CCX_KIND_DATA,
                         `OPENRV64_CCX_ATTR_CACHEABLE,
                         3'd6, address, transaction);
            send_write_data(transaction, data);
            wait_response(transaction, `OPENRV64_CCX_SOURCE_DCACHE,
                          512'd0, 1'b0);
        end
    endtask

    task automatic send_fence;
        input [`OPENRV64_CCX_KIND_WIDTH-1:0] kind;
        reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            send_command(`OPENRV64_CCX_SOURCE_PTW,
                         `OPENRV64_CCX_OP_FENCE, kind,
                         `OPENRV64_CCX_ATTR_NONE,
                         3'd0, 64'd0, transaction);
            wait_response(transaction, `OPENRV64_CCX_SOURCE_PTW,
                          512'd0, 1'b0);
        end
    endtask

    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] old_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] new_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] dirty_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] newest_line;

    initial begin
        req_valid = 1'b0;
        req_hart_id = 0;
        req_txn_id = 0;
        req_source_id = 0;
        req_op = 0;
        req_lock = 1'b0;
        req_order = 0;
        req_kind = 0;
        req_attr = 0;
        req_size = 0;
        req_addr = 0;
        req_burst_len = 0;
        wdata_valid = 1'b0;
        wdata_hart_id = 0;
        wdata_txn_id = 0;
        wdata_source_id = 0;
        wdata_beat_index = 0;
        wdata_last = 1'b0;
        wdata = 0;
        wstrb = 0;
        resp_ready = 1'b1;
        txn_counter = 0;
        for (memory_index = 0; memory_index < MEMORY_LINES;
             memory_index = memory_index + 1)
            memory[memory_index] = 0;

        old_line = line_pattern(64'h1000_0000_0000_0000);
        new_line = line_pattern(64'h2000_0000_0000_0000);
        dirty_line = line_pattern(64'h3000_0000_0000_0000);
        newest_line = line_pattern(64'h4000_0000_0000_0000);
        memory[PTE_LINE_ADDR[13:6]] = old_line;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, old_line);
        if (bus_reads != 1)
            $fatal(1, "initial PTE access did not fill exactly one line");
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, old_line);
        if (bus_reads != 1)
            $fatal(1, "resident PTE line missed before shootdown");

        // Model a page-table store which bypassed this L2.  Without a
        // shootdown, the cached PTE line is deliberately still visible.
        memory[PTE_LINE_ADDR[13:6]] = new_line;
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, old_line);
        if (bus_reads != 1)
            $fatal(1, "PTE line unexpectedly self-invalidated");

        send_fence(`OPENRV64_CCX_KIND_PTE);
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, new_line);
        if (bus_reads != 2)
            $fatal(1, "PTE generation shootdown did not force refill");

        // A stale-generation dirty match must use the matching way as its
        // victim, write it back, then refill without creating a duplicate tag.
        write_line(PTE_LINE_ADDR, dirty_line);
        send_fence(`OPENRV64_CCX_KIND_PTE);
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, dirty_line);
        if ((bus_reads != 3) || (bus_writes != 1) ||
            (memory[PTE_LINE_ADDR[13:6]] !== dirty_line))
            $fatal(1, "dirty stale-PTE replacement was not writeback/refill");

        // Ordinary fences do not advance the PTE generation.
        memory[PTE_LINE_ADDR[13:6]] = newest_line;
        send_fence(`OPENRV64_CCX_KIND_DATA);
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, dirty_line);
        if (bus_reads != 3)
            $fatal(1, "non-PTE fence invalidated a PTE line");
        send_fence(`OPENRV64_CCX_KIND_PTE);
        read_line(`OPENRV64_CCX_SOURCE_PTW,
                  `OPENRV64_CCX_KIND_PTE, PTE_LINE_ADDR, newest_line);
        if (bus_reads != 4)
            $fatal(1, "second PTE generation did not force refill");

        $display("PASS: native 512-bit L2 hits, writes, and 8-bit PTE generations");
        $finish;
    end

endmodule
