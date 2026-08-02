`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

// A successful SC whose LR line has left L2 must refill the cacheline before
// applying the scalar update.  It must never use the ordinary write-miss
// write-around path.
module tb_ccx_l2_sc_refill;

    localparam [63:0] ATOMIC_ADDR = 64'h0000_0000_8000_0000;
    // A one-way 256 KiB L2 has 4096 sets, so this maps to the same set.
    localparam [63:0] EVICT_ADDR  = ATOMIC_ADDR + 64'h0000_0000_0004_0000;

    logic clk;
    logic rst_n;

    logic req_valid;
    wire req_ready;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] req_txn_id;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] req_op;
    logic [2:0] req_size;
    logic [63:0] req_addr;

    logic wdata_valid;
    wire wdata_ready;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] wdata_txn_id;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] wdata;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] wstrb;

    wire resp_valid;
    logic resp_ready;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] resp_txn_id;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] resp_rdata;
    wire resp_error;
    wire resp_sc_success;

    wire [1:0] probe_valid;
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

    logic bus_pending;
    logic [63:0] pending_addr;
    logic pending_write;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] atomic_memory;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] evict_memory;
    integer bus_reads;
    integer bus_writes;
    integer byte_index;
    integer txn_counter;
    integer reads_before_sc;
    integer writes_before_sc;

    openrv64_ccx_l2_native #(
        .CACHE_BYTES(256 * 1024),
        .WAYS(1),
        .MSHR_ENTRIES(2),
        .WAITERS_PER_MSHR(2),
        .COMMAND_ENTRIES(4),
        .RESPONSE_ENTRIES(4),
        .BUS_TRACK_ENTRIES(2),
        .ENABLE_COHERENCE(1),
        .NUM_HARTS(2),
        .DIRECTORY_ENTRIES(8),
        .DIRECTORY_WAYS(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_hart_id_i(4'd0),
        .req_txn_id_i(req_txn_id),
        .req_source_id_i(`OPENRV64_CCX_SOURCE_DCACHE),
        .req_op_i(req_op),
        .req_lock_i(1'b0),
        .req_order_i(`OPENRV64_CCX_ORDER_NONE),
        .req_kind_i(`OPENRV64_CCX_KIND_DATA),
        .req_attr_i(`OPENRV64_CCX_ATTR_CACHEABLE),
        .req_size_i(req_size),
        .req_addr_i(req_addr),
        .req_burst_len_i(8'd0),
        .wdata_valid_i(wdata_valid),
        .wdata_ready_o(wdata_ready),
        .wdata_hart_id_i(4'd0),
        .wdata_txn_id_i(wdata_txn_id),
        .wdata_source_id_i(`OPENRV64_CCX_SOURCE_DCACHE),
        .wdata_beat_index_i(8'd0),
        .wdata_last_i(1'b1),
        .wdata_i(wdata),
        .wstrb_i(wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_hart_id_o(),
        .resp_txn_id_o(resp_txn_id),
        .resp_source_id_o(),
        .resp_beat_index_o(),
        .resp_last_o(),
        .resp_rdata_o(resp_rdata),
        .resp_error_o(resp_error),
        .resp_sc_success_o(resp_sc_success),
        .probe_valid_o(probe_valid),
        .probe_ready_i(2'b11),
        .probe_id_o(),
        .probe_command_o(),
        .probe_cache_mask_o(),
        .probe_line_addr_o(),
        .probe_resp_valid_i(2'b00),
        .probe_resp_ready_o(),
        .probe_resp_id_i(8'd0),
        .probe_resp_kind_i(4'd0),
        .probe_resp_data_i(1024'd0),
        .probe_resp_error_i(2'b00),
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

    assign bus_req_ready = !bus_pending && !bus_resp_valid;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_pending <= 1'b0;
            pending_addr <= 0;
            pending_write <= 1'b0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <= 0;
            bus_reads <= 0;
            bus_writes <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                if (!bus_req_cacheable || (bus_req_size != 3'd6) ||
                    (bus_req_addr[5:0] != 0))
                    $fatal(1,
                        "SC-refill test observed non-line L2 request addr=%h size=%0d write=%0b",
                        bus_req_addr, bus_req_size, bus_req_write);
                bus_pending <= 1'b1;
                pending_addr <= bus_req_addr;
                pending_write <= bus_req_write;
                if (bus_req_write) begin
                    bus_writes <= bus_writes + 1;
                    for (byte_index = 0; byte_index < 64;
                         byte_index = byte_index + 1) begin
                        if (bus_req_wstrb[byte_index] &&
                            (bus_req_addr == ATOMIC_ADDR))
                            atomic_memory[byte_index*8 +: 8] <=
                                bus_req_wdata[byte_index*8 +: 8];
                        if (bus_req_wstrb[byte_index] &&
                            (bus_req_addr == EVICT_ADDR))
                            evict_memory[byte_index*8 +: 8] <=
                                bus_req_wdata[byte_index*8 +: 8];
                    end
                end else begin
                    bus_reads <= bus_reads + 1;
                end
            end else if (bus_pending && !bus_resp_valid) begin
                bus_pending <= 1'b0;
                bus_resp_valid <= 1'b1;
                if (pending_write)
                    bus_resp_rdata <= 0;
                else if (pending_addr == ATOMIC_ADDR)
                    bus_resp_rdata <= atomic_memory;
                else if (pending_addr == EVICT_ADDR)
                    bus_resp_rdata <= evict_memory;
                else begin
                    bus_resp_rdata <= 0;
                    $fatal(1, "unexpected backing read addr=%h", pending_addr);
                end
            end

            if (|probe_valid)
                $fatal(1, "SC-refill test unexpectedly requested a probe");
        end
    end

    task automatic send_command;
        input [`OPENRV64_CCX_OP_WIDTH-1:0] operation;
        input [2:0] size;
        input [63:0] address;
        output [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        integer cycles;
        begin
            transaction = txn_counter[`OPENRV64_CCX_TXN_ID_WIDTH-1:0];
            txn_counter = txn_counter + 1;
            @(negedge clk);
            req_txn_id = transaction;
            req_op = operation;
            req_size = size;
            req_addr = address;
            req_valid = 1'b1;
            cycles = 0;
            while (!req_ready && (cycles < 100)) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "SC-refill command timeout");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic send_write_data;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        input [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] strobes;
        integer cycles;
        begin
            wdata_txn_id = transaction;
            wdata = data;
            wstrb = strobes;
            wdata_valid = 1'b1;
            cycles = 0;
            @(posedge clk);
            while (!wdata_ready && (cycles < 100)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!wdata_ready)
                $fatal(1,
                    "SC-refill write-data timeout count=%0d head=%0d tail=%0d txn=%0d slots=%0d,%0d,%0d,%0d op=%0d,%0d,%0d,%0d valid=%0b%0b%0b%0b data_valid=%0b%0b%0b%0b",
                    dut.cmd_count_q, dut.cmd_head_q, dut.cmd_tail_q,
                    wdata_txn_id,
                    dut.cmd_txn_id_q[0], dut.cmd_txn_id_q[1],
                    dut.cmd_txn_id_q[2], dut.cmd_txn_id_q[3],
                    dut.cmd_op_q[0], dut.cmd_op_q[1],
                    dut.cmd_op_q[2], dut.cmd_op_q[3],
                    dut.cmd_entry_valid_q[3], dut.cmd_entry_valid_q[2],
                    dut.cmd_entry_valid_q[1], dut.cmd_entry_valid_q[0],
                    dut.cmd_wdata_valid_q[3], dut.cmd_wdata_valid_q[2],
                    dut.cmd_wdata_valid_q[1], dut.cmd_wdata_valid_q[0]);
            @(negedge clk);
            wdata_valid = 1'b0;
        end
    endtask

    task automatic wait_response;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] expected_data;
        input expected_sc_success;
        integer cycles;
        begin
            cycles = 0;
            while (!resp_valid && (cycles < 500)) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!resp_valid || (resp_txn_id != transaction) || resp_error ||
                (resp_sc_success != expected_sc_success) ||
                (resp_rdata !== expected_data))
                $fatal(1,
                    "SC-refill response mismatch txn=%0d/%0d error=%0b sc=%0b/%0b data=%h expected=%h",
                    resp_txn_id, transaction, resp_error,
                    resp_sc_success, expected_sc_success,
                    resp_rdata, expected_data);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] expected_line;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] scalar_data;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] sc_data;

    initial begin
        req_valid = 1'b0;
        req_txn_id = 0;
        req_op = 0;
        req_size = 0;
        req_addr = 0;
        wdata_valid = 1'b0;
        wdata_txn_id = 0;
        wdata = 0;
        wstrb = 0;
        resp_ready = 1'b1;
        txn_counter = 0;
        atomic_memory = 0;
        atomic_memory[63:0] = 64'h0123_4567_89ab_cdef;
        evict_memory = {8{64'hfeed_0000_0000_0001}};

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        while (dut.coherence_directory_init_busy)
            @(posedge clk);

        scalar_data = 0;
        scalar_data[63:0] = atomic_memory[63:0];
        send_command(`OPENRV64_CCX_OP_LR, 3'd2,
                     ATOMIC_ADDR, transaction);
        wait_response(transaction, scalar_data, 1'b0);

        send_command(`OPENRV64_CCX_OP_READ, 3'd6,
                     EVICT_ADDR, transaction);
        wait_response(transaction, evict_memory, 1'b0);

        reads_before_sc = bus_reads;
        writes_before_sc = bus_writes;
        sc_data = 0;
        sc_data[31:0] = 32'h5c5c_a7a7;
        send_command(`OPENRV64_CCX_OP_SC, 3'd2,
                     ATOMIC_ADDR, transaction);
        send_write_data(transaction, sc_data, 64'hf);
        wait_response(transaction, 512'd0, 1'b1);

        if ((bus_reads != reads_before_sc + 1) ||
            (bus_writes != writes_before_sc))
            $fatal(1,
                "SC miss did not use one refill and zero write-arounds reads=%0d writes=%0d",
                bus_reads - reads_before_sc,
                bus_writes - writes_before_sc);
        if (atomic_memory[31:0] != 32'h89ab_cdef)
            $fatal(1, "SC miss modified backing memory before eviction");

        expected_line = atomic_memory;
        expected_line[31:0] = 32'h5c5c_a7a7;
        reads_before_sc = bus_reads;
        send_command(`OPENRV64_CCX_OP_READ, 3'd6,
                     ATOMIC_ADDR, transaction);
        wait_response(transaction, expected_line, 1'b0);
        if (bus_reads != reads_before_sc)
            $fatal(1, "post-SC line was not resident in L2");

        $display("PASS: successful SC miss refilled, modified, and retained the L2 line");
        $finish;
    end

endmodule
