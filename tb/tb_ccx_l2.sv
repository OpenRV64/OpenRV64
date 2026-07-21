`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_ccx_l2 #(
    parameter integer BUS_DATA_WIDTH = 64
);

    localparam integer BUS_BYTES = BUS_DATA_WIDTH / 8;
    localparam integer LINE_BEATS = 64 / BUS_BYTES;
    localparam integer SCALAR_BEATS = (8 + BUS_BYTES - 1) / BUS_BYTES;
    localparam integer MEMORY_BYTES = 1024 * 1024;
    localparam [3:0] CACHEABLE = `OPENRV64_CCX_ATTR_CACHEABLE;

    logic clk;
    logic rst_n;

    logic req_valid;
    wire req_ready;
    logic [3:0] req_hart_id;
    logic [3:0] req_txn_id;
    logic [3:0] req_op;
    logic [1:0] req_order;
    logic [1:0] req_kind;
    logic [3:0] req_attr;
    logic [2:0] req_size;
    logic [63:0] req_addr;
    logic [63:0] req_wdata;
    logic [7:0] req_wstrb;

    wire resp_valid;
    logic resp_ready;
    wire [3:0] resp_hart_id;
    wire [3:0] resp_txn_id;
    wire [63:0] resp_rdata;
    wire resp_error;
    wire resp_sc_success;

    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [BUS_DATA_WIDTH-1:0] bus_req_wdata;
    wire [BUS_BYTES-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    logic bus_resp_valid;
    wire bus_resp_ready;
    logic [BUS_DATA_WIDTH-1:0] bus_resp_rdata;
    logic bus_resp_error;

    logic [7:0] memory [0:MEMORY_BYTES-1];
    logic bus_pending;
    logic bus_stall;
    logic pending_write;
    logic [63:0] pending_addr;
    logic [BUS_DATA_WIDTH-1:0] pending_wdata;
    logic [BUS_BYTES-1:0] pending_wstrb;
    logic fail_enable;
    logic [63:0] fail_addr;
    integer bus_reads;
    integer bus_writes;
    integer memory_index;
    integer byte_index;

    logic [3:0] observed_hart [0:127];
    logic [3:0] observed_txn [0:127];
    logic [63:0] observed_data [0:127];
    logic observed_error [0:127];
    integer response_count;

    openrv64_ccx_l2 #(
        .BUS_DATA_WIDTH(BUS_DATA_WIDTH),
        .CACHE_BYTES(256 * 1024),
        .LINE_BYTES(64),
        .WAYS(8),
        .MERGE_ENTRIES(16)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_hart_id_i(req_hart_id),
        .req_txn_id_i(req_txn_id),
        .req_op_i(req_op),
        .req_order_i(req_order),
        .req_kind_i(req_kind),
        .req_attr_i(req_attr),
        .req_size_i(req_size),
        .req_addr_i(req_addr),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_hart_id_o(resp_hart_id),
        .resp_txn_id_o(resp_txn_id),
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
        .bus_resp_error_i(bus_resp_error)
    );

    assign bus_req_ready = !bus_pending && !bus_resp_valid && !bus_stall;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [63:0] memory_word;
        input [63:0] address;
        integer function_byte;
        begin
            for (function_byte = 0; function_byte < 8;
                 function_byte = function_byte + 1)
                memory_word[8*function_byte +: 8] =
                    memory[(address + function_byte) % MEMORY_BYTES];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_pending <= 1'b0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <= 0;
            bus_resp_error <= 1'b0;
            pending_write <= 1'b0;
            pending_addr <= 0;
            pending_wdata <= 0;
            pending_wstrb <= 0;
            bus_reads <= 0;
            bus_writes <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if (bus_req_size !==
                    (bus_req_cacheable ? $clog2(BUS_BYTES) :
                     ((BUS_BYTES < 8) ? $clog2(BUS_BYTES) : 3)))
                    $fatal(1, "unexpected L2 external beat size %0d",
                           bus_req_size);
                pending_write <= bus_req_write;
                pending_addr <= bus_req_addr;
                pending_wdata <= bus_req_wdata;
                pending_wstrb <= bus_req_wstrb;
                bus_pending <= 1'b1;
                if (bus_req_write)
                    bus_writes <= bus_writes + 1;
                else
                    bus_reads <= bus_reads + 1;
            end

            if (bus_pending && !bus_resp_valid) begin
                bus_resp_rdata <= 0;
                bus_resp_error <= fail_enable &&
                    ({pending_addr[63:3], 3'b000} ==
                     {fail_addr[63:3], 3'b000});
                memory_index = pending_addr % MEMORY_BYTES;
                for (byte_index = 0; byte_index < BUS_BYTES;
                     byte_index = byte_index + 1) begin
                    bus_resp_rdata[8*byte_index +: 8] <=
                        memory[(memory_index + byte_index) % MEMORY_BYTES];
                    if (pending_write && pending_wstrb[byte_index])
                        memory[(memory_index + byte_index) % MEMORY_BYTES] <=
                            pending_wdata[8*byte_index +: 8];
                end
                bus_resp_valid <= 1'b1;
                bus_pending <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && resp_valid && resp_ready) begin
            observed_hart[response_count] <= resp_hart_id;
            observed_txn[response_count] <= resp_txn_id;
            observed_data[response_count] <= resp_rdata;
            observed_error[response_count] <= resp_error;
            response_count <= response_count + 1;
        end
    end

    task automatic send_request;
        input [3:0] hart;
        input [3:0] txn;
        input [3:0] operation;
        input [3:0] attributes;
        input [63:0] address;
        input [63:0] write_data;
        input [7:0] write_strobes;
        integer cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id = hart;
            req_txn_id = txn;
            req_op = operation;
            req_attr = attributes;
            req_addr = address;
            req_wdata = write_data;
            req_wstrb = write_strobes;
            cycles = 0;
            while (!req_ready && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "request hart=%0d txn=%0d timed out", hart, txn);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic expect_response;
        input integer response_index;
        input [3:0] hart;
        input [3:0] txn;
        input [63:0] data;
        input error;
        input check_data;
        integer cycles;
        begin
            cycles = 0;
            while ((response_count <= response_index) && cycles < 3000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (response_count <= response_index)
                $fatal(1, "response %0d timed out", response_index);
            if ((observed_hart[response_index] !== hart) ||
                (observed_txn[response_index] !== txn) ||
                (observed_error[response_index] !== error))
                $fatal(1,
                       "response %0d identity/error got h%0d/t%0d/e%b expected h%0d/t%0d/e%b",
                       response_index, observed_hart[response_index],
                       observed_txn[response_index],
                       observed_error[response_index], hart, txn, error);
            if (check_data && observed_data[response_index] !== data)
                $fatal(1, "response %0d data=%016x expected=%016x",
                       response_index, observed_data[response_index], data);
        end
    endtask

    integer before_reads;
    integer before_writes;
    integer way;
    integer initialization_index;
    reg [63:0] expected_word;
    localparam [63:0] CONFLICT_BASE = 64'h0001_0000;
    localparam [63:0] SET_STRIDE = 64'd32768;
    localparam [63:0] MERGED_WRITE = 64'hfeed_face_0123_4567;
    localparam [63:0] DIRTY_WRITE = 64'h8877_6655_4433_2211;

    initial begin
        for (initialization_index = 0;
             initialization_index < MEMORY_BYTES;
             initialization_index = initialization_index + 1)
            memory[initialization_index] =
                initialization_index[7:0] ^ 8'h5a;

        rst_n = 1'b0;
        req_valid = 1'b0;
        req_hart_id = 0;
        req_txn_id = 0;
        req_op = `OPENRV64_CCX_OP_READ;
        req_order = `OPENRV64_CCX_ORDER_NONE;
        req_kind = `OPENRV64_CCX_KIND_DATA;
        req_attr = CACHEABLE;
        req_size = 3'd3;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        resp_ready = 1'b1;
        bus_stall = 1'b0;
        fail_enable = 1'b0;
        fail_addr = 0;
        response_count = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        before_reads = bus_reads;
        expected_word = memory_word(64'h100);
        send_request(0, 0, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h100, 0, 0);
        expect_response(0, 0, 0, expected_word, 1'b0, 1'b1);
        if ((bus_reads - before_reads) != LINE_BEATS)
            $fatal(1, "read miss did not fetch exactly one line");

        before_reads = bus_reads;
        expected_word = memory_word(64'h108);
        send_request(1, 0, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h108, 0, 0);
        expect_response(1, 1, 0, expected_word, 1'b0, 1'b1);
        if (bus_reads != before_reads)
            $fatal(1, "same-line hit reached external memory");

        before_writes = bus_writes;
        send_request(0, 1, `OPENRV64_CCX_OP_WRITE, CACHEABLE,
                     64'h108, 64'h0123_4567_89ab_cdef, 8'hff);
        expect_response(2, 0, 1, 0, 1'b0, 1'b0);
        send_request(0, 2, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h108, 0, 0);
        expect_response(3, 0, 2, 64'h0123_4567_89ab_cdef,
                        1'b0, 1'b1);
        if (bus_writes != before_writes)
            $fatal(1, "write-back hit wrote through to the bus");

        before_reads = bus_reads;
        expected_word = memory_word(64'h300);
        send_request(2, 0, `OPENRV64_CCX_OP_READ,
                     `OPENRV64_CCX_ATTR_NONE, 64'h300, 0, 0);
        expect_response(4, 2, 0, expected_word, 1'b0, 1'b1);
        if ((bus_reads - before_reads) != SCALAR_BEATS)
            $fatal(1, "uncached read was not one scalar bus access");

        // Three harts enter one miss.  The write is accepted before the final
        // read and must therefore be visible to that read during FIFO replay.
        before_reads = bus_reads;
        expected_word = memory_word(64'h408);
        send_request(0, 3, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h400, 0, 0);
        send_request(1, 1, `OPENRV64_CCX_OP_WRITE, CACHEABLE,
                     64'h408, MERGED_WRITE, 8'hff);
        send_request(2, 1, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h408, 0, 0);
        expect_response(5, 0, 3, memory_word(64'h400), 1'b0, 1'b1);
        expect_response(6, 1, 1, 0, 1'b0, 1'b0);
        expect_response(7, 2, 1, MERGED_WRITE, 1'b0, 1'b1);
        if ((bus_reads - before_reads) != LINE_BEATS)
            $fatal(1, "merged miss fetched more than one line");

        // A failed refill must fail every joined request and leave the line
        // invalid so a later access retries the complete fill.
        fail_enable = 1'b1;
        fail_addr = 64'h1000;
        send_request(0, 4, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h1000, 0, 0);
        send_request(1, 2, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h1008, 0, 0);
        expect_response(8, 0, 4, 0, 1'b1, 1'b0);
        expect_response(9, 1, 2, 0, 1'b1, 1'b0);
        fail_enable = 1'b0;
        before_reads = bus_reads;
        expected_word = memory_word(64'h1000);
        send_request(0, 5, `OPENRV64_CCX_OP_READ, CACHEABLE,
                     64'h1000, 0, 0);
        expect_response(10, 0, 5, expected_word, 1'b0, 1'b1);
        if ((bus_reads - before_reads) != LINE_BEATS)
            $fatal(1, "failed refill incorrectly left a valid line");

        // Fill a set, dirty its last way, then cycle through the set until
        // that line is selected.  Its eviction must emit one full writeback.
        for (way = 0; way < 8; way = way + 1) begin
            expected_word = memory_word(CONFLICT_BASE + way*SET_STRIDE);
            send_request(3, way[3:0], `OPENRV64_CCX_OP_READ, CACHEABLE,
                         CONFLICT_BASE + way*SET_STRIDE, 0, 0);
            expect_response(11 + way, 3, way[3:0], expected_word,
                            1'b0, 1'b1);
        end
        send_request(3, 8, `OPENRV64_CCX_OP_WRITE, CACHEABLE,
                     CONFLICT_BASE + 7*SET_STRIDE,
                     DIRTY_WRITE, 8'hff);
        expect_response(19, 3, 8, 0, 1'b0, 1'b0);

        before_writes = bus_writes;
        for (way = 8; way < 16; way = way + 1) begin
            expected_word = memory_word(CONFLICT_BASE + way*SET_STRIDE);
            send_request(3, way[3:0], `OPENRV64_CCX_OP_READ, CACHEABLE,
                         CONFLICT_BASE + way*SET_STRIDE, 0, 0);
            expect_response(12 + way, 3, way[3:0], expected_word,
                            1'b0, 1'b1);
        end
        if ((bus_writes - before_writes) != LINE_BEATS)
            $fatal(1, "dirty eviction did not write exactly one line");
        if (memory_word(CONFLICT_BASE + 7*SET_STRIDE) !== DIRTY_WRITE)
            $fatal(1, "dirty writeback data did not reach memory");

        if (resp_sc_success !== 1'b0)
            $fatal(1, "non-atomic L2 response asserted SC success");

        $display("PASS: %0d-bit shared L2 hits, writeback, bypass, same-line merging, and ordered replay",
                 BUS_DATA_WIDTH);
        $finish;
    end

    initial begin
        repeat (30000) @(posedge clk);
        $fatal(1, "L2 test timeout");
    end

endmodule
