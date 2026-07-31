`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_ccx_l2;

    localparam integer MEMORY_LINES = 8192;
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
    logic bus_response_hold;
    logic pending_write_q;
    logic [63:0] pending_addr_q;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] pending_wdata_q;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] pending_wstrb_q;
    integer bus_reads;
    integer bus_writes;
    logic [63:0] last_bus_write_addr;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        last_bus_write_strb;
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
        .probe_valid_o(),
        .probe_ready_i(1'b0),
        .probe_id_o(),
        .probe_command_o(),
        .probe_cache_mask_o(),
        .probe_line_addr_o(),
        .probe_resp_valid_i(1'b0),
        .probe_resp_ready_o(),
        .probe_resp_id_i(
            {`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}}),
        .probe_resp_kind_i(
            {`OPENRV64_CCX_PROBE_RESP_WIDTH{1'b0}}),
        .probe_resp_data_i(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .probe_resp_error_i(1'b0),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(),
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
            last_bus_write_addr <= 0;
            last_bus_write_strb <= 0;
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
                if (bus_req_write) begin
                    bus_writes <= bus_writes + 1;
                    last_bus_write_addr <= bus_req_addr;
                    last_bus_write_strb <= bus_req_wstrb;
                end else
                    bus_reads <= bus_reads + 1;
            end

            if (bus_pending_q && !bus_resp_valid &&
                !bus_response_hold) begin
                memory_index = pending_addr_q[18:6];
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
        input locked;
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
            req_lock = locked;
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

    task automatic send_write_data_masked;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        input [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] strobes;
        integer cycles;
        begin
            wdata_hart_id = 0;
            wdata_txn_id = transaction;
            wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            wdata_beat_index = 0;
            wdata_last = 1'b1;
            wdata = data;
            wstrb = strobes;
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
                    dut.cmd_wdata_valid_q[dut.cmd_head_q]);
            @(negedge clk);
            wdata_valid = 1'b0;
        end
    endtask

    task automatic send_write_data;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        begin
            send_write_data_masked(
                transaction, data,
                {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}});
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
                $fatal(1,
                       "native L2 response data mismatch txn=%0d actual=%0128x expected=%0128x",
                       transaction, resp_rdata, expected_data);
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
            send_command(source, `OPENRV64_CCX_OP_READ, 1'b0, kind,
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
                         1'b0,
                         `OPENRV64_CCX_KIND_DATA,
                         `OPENRV64_CCX_ATTR_CACHEABLE,
                         3'd6, address, transaction);
            send_write_data(transaction, data);
            wait_response(transaction, `OPENRV64_CCX_SOURCE_DCACHE,
                          512'd0, 1'b0);
        end
    endtask

    task automatic start_masked_write;
        input [63:0] address;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        input [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] strobes;
        output [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                         `OPENRV64_CCX_OP_WRITE,
                         1'b0,
                         `OPENRV64_CCX_KIND_DATA,
                         `OPENRV64_CCX_ATTR_CACHEABLE,
                         3'd6, address, transaction);
            send_write_data_masked(transaction, data, strobes);
        end
    endtask

    task automatic send_fence;
        input [`OPENRV64_CCX_KIND_WIDTH-1:0] kind;
        reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            send_command(`OPENRV64_CCX_SOURCE_PTW,
                         `OPENRV64_CCX_OP_FENCE, 1'b0, kind,
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
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] masked_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] masked_store_data;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] scalar_response;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] masked_txn_0;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] masked_txn_1;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] early_txn_0;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] early_txn_1;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] locked_read_txn;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] locked_write_txn;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] early_line_0;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] early_line_1;
    integer masked_reads_before;
    integer masked_writes_before;
    integer congruent_index;
    reg [63:0] congruent_addr;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] congruent_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] snoop_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] snoop_dirty_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] snoop_evict_line;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] snoop_txn;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] snoop_evict_txn;
    integer snoop_wait_cycles;
    integer snoop_bus_reads_before;
    localparam [63:0] MASKED_LINE_ADDR = 64'h0000_0000_0000_2000;
    localparam [63:0] SNOOP_LINE_ADDR = 64'h0000_0000_0000_3000;
    localparam [63:0] L2_SET_STRIDE = 64'h0000_0000_0000_8000;

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
        bus_response_hold = 1'b0;
        txn_counter = 0;
        for (memory_index = 0; memory_index < MEMORY_LINES;
             memory_index = memory_index + 1)
            memory[memory_index] = 0;

        old_line = line_pattern(64'h1000_0000_0000_0000);
        new_line = line_pattern(64'h2000_0000_0000_0000);
        dirty_line = line_pattern(64'h3000_0000_0000_0000);
        newest_line = line_pattern(64'h4000_0000_0000_0000);
        masked_line = line_pattern(64'h5000_0000_0000_0000);
        masked_line[319:256] = 64'h1122_3344_aabb_ccdd;
        masked_store_data = 0;
        scalar_response = 0;
        memory[PTE_LINE_ADDR[18:6]] = old_line;
        memory[MASKED_LINE_ADDR[18:6]] = masked_line;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Once the current head write has buffered its data, the independent
        // write-data channel may present a future command's data.  Hold the
        // lookup stage so both commands coexist and prove that each command
        // queue entry buffers its own tagged data beat.
        early_line_0 = line_pattern(64'h0100_0000_0000_0000);
        early_line_1 = line_pattern(64'h0200_0000_0000_0000);
        force dut.lookup_stage_ready = 1'b0;
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_WRITE, 1'b0,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd6, 64'h4000, early_txn_0);
        send_write_data(early_txn_0, early_line_0);
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_WRITE, 1'b0,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd6, 64'h4040, early_txn_1);
        wdata_hart_id = 0;
        wdata_txn_id = early_txn_1;
        wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
        wdata_beat_index = 0;
        wdata_last = 1'b1;
        wdata = early_line_1;
        wstrb = {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}};
        wdata_valid = 1'b1;
        #1;
        if (!wdata_ready)
            $fatal(1,
                "future write data was not accepted into its slot: count=%0d head=%0d tail=%0d valid=%0b%0b%0b%0b txn=%0d slots=%0d,%0d,%0d,%0d data_valid=%0b%0b%0b%0b",
                dut.cmd_count_q, dut.cmd_head_q, dut.cmd_tail_q,
                dut.cmd_entry_valid_q[3], dut.cmd_entry_valid_q[2],
                dut.cmd_entry_valid_q[1], dut.cmd_entry_valid_q[0],
                early_txn_1, dut.cmd_txn_id_q[0],
                dut.cmd_txn_id_q[1], dut.cmd_txn_id_q[2],
                dut.cmd_txn_id_q[3], dut.cmd_wdata_valid_q[3],
                dut.cmd_wdata_valid_q[2], dut.cmd_wdata_valid_q[1],
                dut.cmd_wdata_valid_q[0]);
        @(posedge clk);
        @(negedge clk);
        if (wdata_ready)
            $fatal(1, "future write-data slot accepted the beat twice");
        wdata_valid = 1'b0;
        repeat (2) @(posedge clk);
        release dut.lookup_stage_ready;
        wait_response(early_txn_0, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        wait_response(early_txn_1, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA, 64'h4000, early_line_0);
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA, 64'h4040, early_line_1);
        bus_reads = 0;
        bus_writes = 0;
        last_bus_write_addr = 0;
        last_bus_write_strb = 0;

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
        memory[PTE_LINE_ADDR[18:6]] = new_line;
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
            (memory[PTE_LINE_ADDR[18:6]] !== dirty_line))
            $fatal(1, "dirty stale-PTE replacement was not writeback/refill");

        // Ordinary fences do not advance the PTE generation.
        memory[PTE_LINE_ADDR[18:6]] = newest_line;
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

        // Two adjacent scalar stack stores miss in L2.  They must write around
        // as partial cachelines without first reading the old line.  The
        // following demand read is the operation which allocates and fills it.
        masked_reads_before = bus_reads;
        masked_writes_before = bus_writes;
        masked_store_data[63:0] = 64'h0123_4567_89ab_cdef;
        start_masked_write(
            MASKED_LINE_ADDR, masked_store_data,
            64'h0000_0000_0000_00ff, masked_txn_0);
        masked_store_data[127:64] = 64'hfedc_ba98_7654_3210;
        start_masked_write(
            MASKED_LINE_ADDR, masked_store_data,
            64'h0000_0000_0000_ff00, masked_txn_1);
        wait_response(masked_txn_0, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        wait_response(masked_txn_1, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        if ((bus_reads != masked_reads_before) ||
            (bus_writes != masked_writes_before + 2))
            $fatal(1,
                "write misses fetched instead of writing around reads=%0d writes=%0d",
                bus_reads - masked_reads_before,
                bus_writes - masked_writes_before);
        masked_line[63:0] = 64'h0123_4567_89ab_cdef;
        masked_line[127:64] = 64'hfedc_ba98_7654_3210;
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA, MASKED_LINE_ADDR, masked_line);
        if (bus_reads != masked_reads_before + 1)
            $fatal(1, "read after write-around did not fill the line");

        // Locked scalar traffic bypasses L1 but must still operate on the
        // current L2 copy.  Scalar reads return their addressed 64-bit lane
        // in its natural position on the 512-bit response interface.
        scalar_response = 0;
        scalar_response[255:192] = masked_line[255:192];
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_READ, 1'b1,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd3, MASKED_LINE_ADDR + 24, locked_read_txn);
        wait_response(locked_read_txn, `OPENRV64_CCX_SOURCE_DCACHE,
                      scalar_response, 1'b1);
        masked_store_data = 0;
        masked_store_data[255:192] = 64'hcafe_f00d_dead_beef;
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_WRITE, 1'b1,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd3, MASKED_LINE_ADDR + 24, locked_write_txn);
        send_write_data_masked(
            locked_write_txn, masked_store_data,
            64'h0000_0000_ff00_0000);
        wait_response(locked_write_txn, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        masked_line[255:192] = 64'hcafe_f00d_dead_beef;
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA, MASKED_LINE_ADDR, masked_line);

        // A 32-bit atomic at address+4 consumes the high word of an aligned
        // 64-bit memory beat.  Preserve that subword position in the scalar
        // CCX response and in the masked write.
        scalar_response = 0;
        scalar_response[319:256] = masked_line[319:256];
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_READ, 1'b1,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd2, MASKED_LINE_ADDR + 36, locked_read_txn);
        wait_response(locked_read_txn, `OPENRV64_CCX_SOURCE_DCACHE,
                      scalar_response, 1'b1);
        masked_store_data = 0;
        masked_store_data[319:288] = 32'hdead_beef;
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_WRITE, 1'b1,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd2, MASKED_LINE_ADDR + 36, locked_write_txn);
        send_write_data_masked(
            locked_write_txn, masked_store_data,
            64'h0000_00f0_0000_0000);
        wait_response(locked_write_txn, `OPENRV64_CCX_SOURCE_DCACHE,
                      512'd0, 1'b0);
        masked_line[319:288] = 32'hdead_beef;
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA, MASKED_LINE_ADDR, masked_line);

        // The two resident scalar writes dirtied only bytes 24..31 and
        // 36..39.  Fill the remaining ways in this set, then force way zero
        // out.  Its writeback must retain that exact byte mask; the backing
        // memory already contains every other byte from the earlier
        // write-around and line fill.
        for (congruent_index = 1; congruent_index <= 8;
             congruent_index = congruent_index + 1) begin
            congruent_addr =
                MASKED_LINE_ADDR + congruent_index * L2_SET_STRIDE;
            congruent_line =
                line_pattern(64'h6000_0000_0000_0000 +
                             congruent_index * 64'h100);
            memory[congruent_addr[18:6]] = congruent_line;
            read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                      `OPENRV64_CCX_KIND_DATA,
                      congruent_addr, congruent_line);
        end
        if ((last_bus_write_addr != MASKED_LINE_ADDR) ||
            (last_bus_write_strb != 64'h0000_00f0_ff00_0000))
            $fatal(1,
                "dirty eviction was not partial addr=%016x strb=%016x",
                last_bus_write_addr, last_bus_write_strb);
        if (memory[MASKED_LINE_ADDR[18:6]] !== masked_line)
            $fatal(1, "partial dirty eviction corrupted backing line");

        // A reserved dirty victim is still the authoritative copy until its
        // writeback response.  Hold that response, then request the victim
        // line again.  The read must be served from the victim snapshot
        // without issuing a stale backing-memory read.
        snoop_line = line_pattern(64'h7000_0000_0000_0000);
        snoop_dirty_line =
            line_pattern(64'h7100_0000_0000_0000);
        memory[SNOOP_LINE_ADDR[18:6]] = snoop_line;
        read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                  `OPENRV64_CCX_KIND_DATA,
                  SNOOP_LINE_ADDR, snoop_line);
        write_line(SNOOP_LINE_ADDR, snoop_dirty_line);
        for (congruent_index = 1; congruent_index < 8;
             congruent_index = congruent_index + 1) begin
            congruent_addr =
                SNOOP_LINE_ADDR + congruent_index * L2_SET_STRIDE;
            congruent_line =
                line_pattern(64'h7200_0000_0000_0000 +
                             congruent_index * 64'h100);
            memory[congruent_addr[18:6]] = congruent_line;
            read_line(`OPENRV64_CCX_SOURCE_DCACHE,
                      `OPENRV64_CCX_KIND_DATA,
                      congruent_addr, congruent_line);
        end

        congruent_addr = SNOOP_LINE_ADDR + 8 * L2_SET_STRIDE;
        snoop_evict_line =
            line_pattern(64'h7300_0000_0000_0000);
        memory[congruent_addr[18:6]] = snoop_evict_line;
        bus_response_hold = 1'b1;
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_READ, 1'b0,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd6, congruent_addr, snoop_evict_txn);
        snoop_wait_cycles = 0;
        while ((!bus_pending_q || !pending_write_q ||
                (pending_addr_q != SNOOP_LINE_ADDR)) &&
               (snoop_wait_cycles < 100)) begin
            @(negedge clk);
            snoop_wait_cycles = snoop_wait_cycles + 1;
        end
        if (!bus_pending_q || !pending_write_q ||
            (pending_addr_q != SNOOP_LINE_ADDR))
            $fatal(1, "dirty victim writeback did not enter the bus");

        snoop_bus_reads_before = bus_reads;
        send_command(`OPENRV64_CCX_SOURCE_DCACHE,
                     `OPENRV64_CCX_OP_READ, 1'b0,
                     `OPENRV64_CCX_KIND_DATA,
                     `OPENRV64_CCX_ATTR_CACHEABLE,
                     3'd6, SNOOP_LINE_ADDR, snoop_txn);
        wait_response(snoop_txn, `OPENRV64_CCX_SOURCE_DCACHE,
                      snoop_dirty_line, 1'b1);
        if (bus_reads != snoop_bus_reads_before)
            $fatal(1,
                "dirty victim snoop issued a backing-memory read");

        bus_response_hold = 1'b0;
        wait_response(snoop_evict_txn,
                      `OPENRV64_CCX_SOURCE_DCACHE,
                      snoop_evict_line, 1'b1);
        if (memory[SNOOP_LINE_ADDR[18:6]] !== snoop_dirty_line)
            $fatal(1, "dirty victim writeback lost snooped data");

        $display("PASS: native L2 write-around, dirty-victim snooping, partial eviction, atomics, and PTE generations");
        $finish;
    end

endmodule
