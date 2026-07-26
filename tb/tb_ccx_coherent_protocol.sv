`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

module tb_ccx_coherent_protocol #(
    parameter integer NUM_HARTS = 2
);

    localparam integer HART_ID_BASE = 0;
    localparam integer DIRECTORY_ENTRIES = 2;
    localparam integer DIRECTORY_WAYS = 1;

    logic clk;
    logic rst_n;
    integer cycle_count;

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

    wire [NUM_HARTS-1:0] probe_valid;
    logic [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    logic [NUM_HARTS-1:0] probe_resp_valid;
    wire [NUM_HARTS-1:0] probe_resp_ready;
    logic [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
        probe_resp_id;
    logic [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    logic [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    logic [NUM_HARTS-1:0] probe_resp_error;

    wire l2_req_valid;
    logic l2_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l2_req_op;
    wire l2_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l2_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l2_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l2_req_attr;
    wire [2:0] l2_req_size;
    wire [63:0] l2_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l2_req_burst_len;

    wire l2_wdata_valid;
    logic l2_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_wdata_beat_index;
    wire l2_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l2_wstrb;

    logic l2_resp_valid;
    wire l2_resp_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_resp_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_resp_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_resp_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_resp_beat_index;
    logic l2_resp_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_resp_rdata;
    logic l2_resp_error;
    logic l2_resp_sc_success;

    logic protocol_error_clear;
    wire protocol_error;

    integer probe_transactions;
    integer l2_requests;
    integer l2_writes;
    integer last_probe_response_cycle;
    integer last_l2_request_cycle;
    logic [NUM_HARTS-1:0] last_probe_targets;
    logic [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        last_probe_cache_mask;
    logic [63:0] last_probe_address;
    logic l2_write_waiting;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] saved_l2_hart;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] saved_l2_txn;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] saved_l2_source;
    logic [63:0] saved_l2_addr;
    integer model_hart;
    integer wait_cycles;
    integer probes_before;
    integer l2_before;
    logic [NUM_HARTS-1:0] expected_targets;

    openrv64_ccx_coherent_protocol #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(HART_ID_BASE),
        .DIRECTORY_ENTRIES(DIRECTORY_ENTRIES),
        .DIRECTORY_WAYS(DIRECTORY_WAYS)
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
        .probe_valid_o(probe_valid),
        .probe_ready_i(probe_ready),
        .probe_id_o(probe_id),
        .probe_command_o(probe_command),
        .probe_cache_mask_o(probe_cache_mask),
        .probe_line_addr_o(probe_line_addr),
        .probe_resp_valid_i(probe_resp_valid),
        .probe_resp_ready_o(probe_resp_ready),
        .probe_resp_id_i(probe_resp_id),
        .probe_resp_kind_i(probe_resp_kind),
        .probe_resp_data_i(probe_resp_data),
        .probe_resp_error_i(probe_resp_error),
        .l2_req_valid_o(l2_req_valid),
        .l2_req_ready_i(l2_req_ready),
        .l2_req_hart_id_o(l2_req_hart_id),
        .l2_req_txn_id_o(l2_req_txn_id),
        .l2_req_source_id_o(l2_req_source_id),
        .l2_req_op_o(l2_req_op),
        .l2_req_lock_o(l2_req_lock),
        .l2_req_order_o(l2_req_order),
        .l2_req_kind_o(l2_req_kind),
        .l2_req_attr_o(l2_req_attr),
        .l2_req_size_o(l2_req_size),
        .l2_req_addr_o(l2_req_addr),
        .l2_req_burst_len_o(l2_req_burst_len),
        .l2_wdata_valid_o(l2_wdata_valid),
        .l2_wdata_ready_i(l2_wdata_ready),
        .l2_wdata_hart_id_o(l2_wdata_hart_id),
        .l2_wdata_txn_id_o(l2_wdata_txn_id),
        .l2_wdata_source_id_o(l2_wdata_source_id),
        .l2_wdata_beat_index_o(l2_wdata_beat_index),
        .l2_wdata_last_o(l2_wdata_last),
        .l2_wdata_o(l2_wdata),
        .l2_wstrb_o(l2_wstrb),
        .l2_resp_valid_i(l2_resp_valid),
        .l2_resp_ready_o(l2_resp_ready),
        .l2_resp_hart_id_i(l2_resp_hart_id),
        .l2_resp_txn_id_i(l2_resp_txn_id),
        .l2_resp_source_id_i(l2_resp_source_id),
        .l2_resp_beat_index_i(l2_resp_beat_index),
        .l2_resp_last_i(l2_resp_last),
        .l2_resp_rdata_i(l2_resp_rdata),
        .l2_resp_error_i(l2_resp_error),
        .l2_resp_sc_success_i(l2_resp_sc_success),
        .protocol_error_clear_i(protocol_error_clear),
        .protocol_error_o(protocol_error)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        model_read_data;
        input [63:0] address;
        integer lane;
        begin
            model_read_data =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            for (lane = 0; lane < 8; lane = lane + 1)
                model_read_data[lane*64 +: 64] =
                    address ^ (64'h1111_0000_0000_0000 + lane);
        end
    endfunction

    // Every private cache accepts a probe immediately and returns a clean ACK
    // one cycle later.  No data-bearing response is legal in the clean S/I
    // protocol under test.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            probe_resp_valid <= {NUM_HARTS{1'b0}};
            probe_resp_id <=
                {NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
            probe_resp_kind <=
                {NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH{1'b0}};
            probe_resp_data <=
                {NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            probe_resp_error <= {NUM_HARTS{1'b0}};
            probe_transactions <= 0;
            last_probe_response_cycle <= -1;
            last_probe_targets <= {NUM_HARTS{1'b0}};
            last_probe_cache_mask <=
                `OPENRV64_CCX_PROBE_CACHE_NONE;
            last_probe_address <= 64'd0;
        end else begin
            if (|(probe_resp_valid & probe_resp_ready)) begin
                probe_resp_valid <=
                    probe_resp_valid & ~probe_resp_ready;
                last_probe_response_cycle <= cycle_count;
            end

            if (|(probe_valid & probe_ready)) begin
                if (|(probe_resp_valid & ~probe_resp_ready))
                    $fatal(1, "probe response model overflow");
                probe_resp_valid <= probe_valid & probe_ready;
                probe_transactions <= probe_transactions + 1;
                last_probe_targets <= probe_valid & probe_ready;
                for (model_hart = 0; model_hart < NUM_HARTS;
                     model_hart = model_hart + 1) begin
                    if (probe_valid[model_hart] &&
                        probe_ready[model_hart]) begin
                        probe_resp_id[
                            model_hart*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                            `OPENRV64_CCX_PROBE_ID_WIDTH] <=
                            probe_id[
                                model_hart*
                                `OPENRV64_CCX_PROBE_ID_WIDTH +:
                                `OPENRV64_CCX_PROBE_ID_WIDTH];
                        probe_resp_kind[
                            model_hart*`OPENRV64_CCX_PROBE_RESP_WIDTH +:
                            `OPENRV64_CCX_PROBE_RESP_WIDTH] <=
                            `OPENRV64_CCX_PROBE_RESP_ACK;
                        if (probe_command[
                                model_hart*
                                `OPENRV64_CCX_PROBE_CMD_WIDTH +:
                                `OPENRV64_CCX_PROBE_CMD_WIDTH] !=
                            `OPENRV64_CCX_PROBE_INV)
                            $fatal(1,
                                   "clean protocol emitted data probe");
                        last_probe_cache_mask <=
                            probe_cache_mask[
                                model_hart*
                                `OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                                `OPENRV64_CCX_PROBE_CACHE_WIDTH];
                        last_probe_address <=
                            probe_line_addr[model_hart*64 +: 64];
                    end
                end
            end
        end
    end

    // Single-outstanding behavioral L2.  It deliberately knows nothing about
    // directory allocation or probes.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_resp_valid <= 1'b0;
            l2_resp_hart_id <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            l2_resp_txn_id <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            l2_resp_source_id <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            l2_resp_beat_index <=
                {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
            l2_resp_last <= 1'b1;
            l2_resp_rdata <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            l2_resp_error <= 1'b0;
            l2_resp_sc_success <= 1'b0;
            l2_write_waiting <= 1'b0;
            saved_l2_hart <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            saved_l2_txn <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            saved_l2_source <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            saved_l2_addr <= 64'd0;
            l2_requests <= 0;
            l2_writes <= 0;
            last_l2_request_cycle <= -1;
        end else begin
            if (l2_resp_valid && l2_resp_ready)
                l2_resp_valid <= 1'b0;

            if (l2_req_valid && l2_req_ready) begin
                if (l2_write_waiting)
                    $fatal(1, "L2 received a command before write data");
                if (l2_req_lock ||
                    (l2_req_order != `OPENRV64_CCX_ORDER_NONE) ||
                    (l2_req_burst_len != 0))
                    $fatal(1, "frontend leaked home-only ordering to L2");
                saved_l2_hart <= l2_req_hart_id;
                saved_l2_txn <= l2_req_txn_id;
                saved_l2_source <= l2_req_source_id;
                saved_l2_addr <= l2_req_addr;
                l2_requests <= l2_requests + 1;
                last_l2_request_cycle <= cycle_count;
                if (l2_req_op == `OPENRV64_CCX_OP_WRITE) begin
                    l2_write_waiting <= 1'b1;
                end else begin
                    l2_resp_valid <= 1'b1;
                    l2_resp_hart_id <= l2_req_hart_id;
                    l2_resp_txn_id <= l2_req_txn_id;
                    l2_resp_source_id <= l2_req_source_id;
                    l2_resp_rdata <=
                        (l2_req_op == `OPENRV64_CCX_OP_READ) ?
                            model_read_data(l2_req_addr) :
                            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                end
            end

            if (l2_wdata_valid && l2_wdata_ready) begin
                if (!l2_write_waiting)
                    $fatal(1, "L2 received write data without command");
                if ((l2_wdata_hart_id != saved_l2_hart) ||
                    (l2_wdata_txn_id != saved_l2_txn) ||
                    (l2_wdata_source_id != saved_l2_source) ||
                    (l2_wdata_beat_index != 0) || !l2_wdata_last)
                    $fatal(1, "L2 write-data identity mismatch");
                l2_write_waiting <= 1'b0;
                l2_writes <= l2_writes + 1;
                l2_resp_valid <= 1'b1;
                l2_resp_hart_id <= saved_l2_hart;
                l2_resp_txn_id <= saved_l2_txn;
                l2_resp_source_id <= saved_l2_source;
                l2_resp_rdata <=
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            end
        end
    end

    task automatic issue_read;
        input integer hart;
        input [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] source;
        input [`OPENRV64_CCX_ATTR_WIDTH-1:0] attributes;
        input [63:0] address;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            req_txn_id = transaction;
            req_source_id = source;
            req_op = `OPENRV64_CCX_OP_READ;
            req_kind =
                (source == `OPENRV64_CCX_SOURCE_ICACHE) ?
                    `OPENRV64_CCX_KIND_FETCH :
                    `OPENRV64_CCX_KIND_DATA;
            req_attr = attributes;
            req_size = 3'd6;
            req_addr = address;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;

            wait_cycles = 0;
            while (!resp_valid && (wait_cycles < 100)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid)
                $fatal(1, "N=%0d read response timeout", NUM_HARTS);
            if (resp_error ||
                (resp_hart_id !=
                 `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart)) ||
                (resp_txn_id != transaction) ||
                (resp_source_id != source) ||
                (resp_rdata != model_read_data(address)) ||
                (resp_beat_index != 0) || !resp_last)
                $fatal(1, "N=%0d read response mismatch", NUM_HARTS);
            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    task automatic issue_write;
        input integer hart;
        input [`OPENRV64_CCX_ATTR_WIDTH-1:0] attributes;
        input [63:0] address;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            req_txn_id = transaction;
            req_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            req_op = `OPENRV64_CCX_OP_WRITE;
            req_kind = `OPENRV64_CCX_KIND_DATA;
            req_attr = attributes;
            req_size = 3'd6;
            req_addr = address;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            wdata_valid = 1'b1;
            wdata_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            wdata_txn_id = transaction;
            wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            wdata_beat_index =
                {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
            wdata_last = 1'b1;
            wdata = {8{address}};
            wstrb = {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}};
            while (!wdata_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            wdata_valid = 1'b0;

            wait_cycles = 0;
            while (!resp_valid && (wait_cycles < 100)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid || resp_error ||
                (resp_txn_id != transaction))
                $fatal(1, "N=%0d write response mismatch", NUM_HARTS);
            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    task automatic issue_lr;
        input integer hart;
        input [63:0] address;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            req_txn_id = transaction;
            req_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            req_op = `OPENRV64_CCX_OP_LR;
            req_kind = `OPENRV64_CCX_KIND_DATA;
            req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
            req_size = 3'd3;
            req_addr = address;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;

            wait_cycles = 0;
            while (!resp_valid && (wait_cycles < 100)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid || resp_error || resp_sc_success ||
                (resp_hart_id !=
                 `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart)) ||
                (resp_txn_id != transaction) ||
                (resp_rdata != model_read_data(address)))
                $fatal(1, "N=%0d LR response mismatch", NUM_HARTS);
            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    task automatic issue_sc;
        input integer hart;
        input [63:0] address;
        input [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input expected_success;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            req_txn_id = transaction;
            req_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            req_op = `OPENRV64_CCX_OP_SC;
            req_kind = `OPENRV64_CCX_KIND_DATA;
            req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
            req_size = 3'd3;
            req_addr = address;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            wdata_valid = 1'b1;
            wdata_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart);
            wdata_txn_id = transaction;
            wdata_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            wdata_beat_index =
                {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
            wdata_last = 1'b1;
            wdata = {8{address ^ 64'h5c5c_5c5c_5c5c_5c5c}};
            wstrb = {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}};
            while (!wdata_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            wdata_valid = 1'b0;

            wait_cycles = 0;
            while (!resp_valid && (wait_cycles < 100)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!resp_valid || resp_error ||
                (resp_sc_success != expected_success) ||
                (resp_hart_id !=
                 `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart)) ||
                (resp_txn_id != transaction))
                $fatal(1,
                    "N=%0d SC response mismatch success=%0b expected=%0b",
                    NUM_HARTS, resp_sc_success, expected_success);
            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    task automatic issue_unsupported_amo;
        input [63:0] address;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_hart_id =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE);
            req_txn_id = 4'he;
            req_source_id = `OPENRV64_CCX_SOURCE_DCACHE;
            req_op = `OPENRV64_CCX_OP_AMOADD;
            req_kind = `OPENRV64_CCX_KIND_DATA;
            req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
            req_size = 3'd3;
            req_addr = address;
            while (!req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            if (!resp_valid || !resp_error)
                $fatal(1, "N=%0d unsupported AMO was not rejected",
                       NUM_HARTS);
            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cycle_count = 0;
        req_valid = 1'b0;
        req_hart_id = 0;
        req_txn_id = 0;
        req_source_id = 0;
        req_op = `OPENRV64_CCX_OP_READ;
        req_lock = 1'b0;
        req_order = `OPENRV64_CCX_ORDER_NONE;
        req_kind = `OPENRV64_CCX_KIND_DATA;
        req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
        req_size = 3'd6;
        req_addr = 64'd0;
        req_burst_len = 0;
        wdata_valid = 1'b0;
        wdata_hart_id = 0;
        wdata_txn_id = 0;
        wdata_source_id = 0;
        wdata_beat_index = 0;
        wdata_last = 1'b1;
        wdata = 0;
        wstrb = 0;
        resp_ready = 1'b0;
        probe_ready = {NUM_HARTS{1'b1}};
        l2_req_ready = 1'b1;
        l2_wdata_ready = 1'b1;
        protocol_error_clear = 1'b0;
        expected_targets = {NUM_HARTS{1'b0}};

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Two D$ fills of the same line create two recorded clean sharers.
        probes_before = probe_transactions;
        issue_read(0, `OPENRV64_CCX_SOURCE_DCACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE,
                   64'h0000_0000_8000_0000, 4'h1);
        issue_read(1, `OPENRV64_CCX_SOURCE_DCACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE,
                   64'h0000_0000_8000_0000, 4'h2);
        if (probe_transactions != probes_before)
            $fatal(1, "N=%0d ordinary shared fills probed", NUM_HARTS);

        // A write-through requester retains its newly updated clean copy.
        // Invalidate the other recorded D$ copy before exposing the write to
        // L2; probing the requester here can deadlock behind its own posted
        // store.
        expected_targets = {NUM_HARTS{1'b0}};
        expected_targets[1] = 1'b1;
        probes_before = probe_transactions;
        issue_write(0, `OPENRV64_CCX_ATTR_CACHEABLE,
                    64'h0000_0000_8000_0000, 4'h3);
        if ((probe_transactions != probes_before + 1) ||
            (last_probe_targets != expected_targets) ||
            (last_probe_cache_mask !=
             `OPENRV64_CCX_PROBE_CACHE_D) ||
            (last_probe_address != 64'h0000_0000_8000_0000) ||
            (last_l2_request_cycle <= last_probe_response_cycle))
            $fatal(1, "N=%0d write probe ordering mismatch", NUM_HARTS);

        // Record one new sharer, then force a non-inclusive directory
        // replacement with another line mapping to the same directory set.
        issue_read(1, `OPENRV64_CCX_SOURCE_DCACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE,
                   64'h0000_0000_8000_0000, 4'h4);
        probes_before = probe_transactions;
        issue_read(0, `OPENRV64_CCX_SOURCE_DCACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE,
                   64'h0000_0000_8000_0080, 4'h5);
        expected_targets = {NUM_HARTS{1'b0}};
        expected_targets[0] = 1'b1;
        expected_targets[1] = 1'b1;
        if ((probe_transactions != probes_before + 1) ||
            (last_probe_targets != expected_targets) ||
            (last_probe_cache_mask !=
             `OPENRV64_CCX_PROBE_CACHE_D) ||
            (last_probe_address != 64'h0000_0000_8000_0000))
            $fatal(1, "N=%0d directory victim probe mismatch",
                   NUM_HARTS);

        // Add an I$ sharer to the resident line.  Replacing it must invalidate
        // both recorded cache classes, but still requires no cross-hart data.
        issue_read(1, `OPENRV64_CCX_SOURCE_ICACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE |
                   `OPENRV64_CCX_ATTR_EXECUTABLE,
                   64'h0000_0000_8000_0080, 4'h6);
        probes_before = probe_transactions;
        issue_read(0, `OPENRV64_CCX_SOURCE_DCACHE,
                   `OPENRV64_CCX_ATTR_CACHEABLE,
                   64'h0000_0000_8000_0100, 4'h7);
        expected_targets = {NUM_HARTS{1'b0}};
        expected_targets[0] = 1'b1;
        expected_targets[1] = 1'b1;
        if ((probe_transactions != probes_before + 1) ||
            (last_probe_targets != expected_targets) ||
            (last_probe_cache_mask !=
             `OPENRV64_CCX_PROBE_CACHE_BOTH) ||
            (last_probe_address != 64'h0000_0000_8000_0080))
            $fatal(1, "N=%0d mixed I/D victim probe mismatch",
                   NUM_HARTS);

        // Device writes bypass the snoop filter.  Coherent and device aliases
        // are forbidden by the platform map; use an unrelated MMIO address.
        probes_before = probe_transactions;
        issue_write(0, `OPENRV64_CCX_ATTR_DEVICE,
                    64'h0000_0000_1000_0000, 4'h8);
        if (probe_transactions != probes_before)
            $fatal(1, "N=%0d device write entered coherence", NUM_HARTS);

        l2_before = l2_requests;
        issue_unsupported_amo(64'h0000_0000_8000_0200);
        if ((l2_requests != l2_before) || !protocol_error)
            $fatal(1, "N=%0d unsupported AMO reached L2", NUM_HARTS);
        protocol_error_clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        protocol_error_clear = 1'b0;
        if (protocol_error)
            $fatal(1, "N=%0d protocol error did not clear", NUM_HARTS);

        // The compatibility atomic marker is represented at this boundary as
        // LR followed by SC.  The home owns reservations and only forwards a
        // successful SC to L2.
        l2_before = l2_requests;
        issue_lr(0, 64'h0000_0000_8000_0300, 4'h9);
        if (l2_requests != l2_before + 1)
            $fatal(1, "N=%0d LR did not map to one L2 read", NUM_HARTS);
        l2_before = l2_requests;
        issue_sc(0, 64'h0000_0000_8000_0300, 4'ha, 1'b1);
        if ((l2_requests != l2_before + 1) ||
            (l2_writes == 0))
            $fatal(1, "N=%0d successful SC did not reach L2", NUM_HARTS);
        l2_before = l2_requests;
        issue_sc(0, 64'h0000_0000_8000_0300, 4'hb, 1'b0);
        if (l2_requests != l2_before)
            $fatal(1, "N=%0d failed SC reached L2", NUM_HARTS);

        // An intervening write to the reservation line invalidates it even
        // when the writer is a different hart.
        issue_lr(0, 64'h0000_0000_8000_0340, 4'hc);
        issue_write(1, `OPENRV64_CCX_ATTR_CACHEABLE,
                    64'h0000_0000_8000_0340, 4'hd);
        l2_before = l2_requests;
        issue_sc(0, 64'h0000_0000_8000_0340, 4'he, 1'b0);
        if (l2_requests != l2_before)
            $fatal(1,
                "N=%0d invalidated reservation SC reached L2",
                NUM_HARTS);

        // A failed SC to another line also consumes the requester's prior
        // reservation.
        issue_lr(0, 64'h0000_0000_8000_0380, 4'hf);
        l2_before = l2_requests;
        issue_sc(0, 64'h0000_0000_8000_03c0, 4'h0, 1'b0);
        issue_sc(0, 64'h0000_0000_8000_0380, 4'h1, 1'b0);
        if (l2_requests != l2_before)
            $fatal(1,
                "N=%0d failed SC did not consume reservation",
                NUM_HARTS);

        $display("PASS: %0d-hart non-inclusive coherent protocol directory",
                 NUM_HARTS);
        $finish;
    end

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "N=%0d coherent protocol test timeout", NUM_HARTS);
    end

endmodule
