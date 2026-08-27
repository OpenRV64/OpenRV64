`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/lsu-defs.v"

module tb_lsu_atomics;
    localparam integer RETIRE_SLOT_WIDTH = 3;
    localparam integer META_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;

    logic clk;
    logic rst_n;
    logic flush;
    logic start_valid;
    wire start_ready;
    logic [`OPENRV64_LSU_TAG_WIDTH-1:0] start_tag;
    logic [`OPENRV64_INSTR_ID_WIDTH-1:0] start_id;
    logic [RETIRE_SLOT_WIDTH-1:0] start_slot;
    logic [META_WIDTH-1:0] start_meta;
    logic [`RV64_LSU_OP_WIDTH-1:0] start_op;
    logic [`RV64_XLEN-1:0] start_addr;
    logic [2:0] start_size;
    logic [`RV64_XLEN-1:0] start_wdata;
    logic start_access_allowed;
    logic clear_reservation;

    wire active;
    wire irrevocable;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] active_tag;
    wire mem_valid;
    logic mem_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag;
    wire mem_lock;
    wire mem_write;
    wire [`RV64_XLEN-1:0] mem_addr;
    wire [`RV64_XLEN-1:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire [`RV64_XLEN-1:0] mem_effective_addr;
    wire [2:0] mem_size;

    logic mem_resp_valid;
    wire mem_resp_claim;
    wire mem_resp_ready;
    logic [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag;
    logic [`RV64_XLEN-1:0] mem_rdata;
    logic mem_error;
    logic mem_page_fault;

    wire result_valid;
    logic result_ready;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] result_id;
    wire [RETIRE_SLOT_WIDTH-1:0] result_slot;
    wire [META_WIDTH-1:0] result_meta;
    wire [`RV64_XLEN-1:0] result_data;
    wire result_illegal;
    wire result_misaligned;
    wire result_access_fault;
    wire result_page_fault;
    wire done;

    openrv64_lsu_atomics #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .LSU_TAG_WIDTH(`OPENRV64_LSU_TAG_WIDTH),
        .META_WIDTH(META_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .start_valid_i(start_valid),
        .start_ready_o(start_ready),
        .start_tag_i(start_tag),
        .start_id_i(start_id),
        .start_slot_i(start_slot),
        .start_meta_i(start_meta),
        .start_op_i(start_op),
        .start_addr_i(start_addr),
        .start_size_i(start_size),
        .start_wdata_i(start_wdata),
        .start_access_allowed_i(start_access_allowed),
        .clear_reservation_i(clear_reservation),
        .active_o(active),
        .irrevocable_o(irrevocable),
        .active_tag_o(active_tag),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_tag_o(mem_tag),
        .mem_lock_o(mem_lock),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_effective_addr_o(mem_effective_addr),
        .mem_size_o(mem_size),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_claim_o(mem_resp_claim),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error),
        .mem_page_fault_i(mem_page_fault),
        .result_valid_o(result_valid),
        .result_ready_i(result_ready),
        .result_id_o(result_id),
        .result_slot_o(result_slot),
        .result_meta_o(result_meta),
        .result_data_o(result_data),
        .result_illegal_o(result_illegal),
        .result_misaligned_o(result_misaligned),
        .result_access_fault_o(result_access_fault),
        .result_page_fault_o(result_page_fault),
        .done_o(done)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic issue_amo;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        input [`RV64_XLEN-1:0] addr;
        input [`RV64_XLEN-1:0] operand;
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] id;
        input [RETIRE_SLOT_WIDTH-1:0] slot;
        begin
            @(negedge clk);
            if (!start_ready)
                $fatal(1, "atomic start was not ready");
            start_meta = {META_WIDTH{1'b0}};
            start_meta[7:0] = id[7:0];
            start_op = op;
            start_addr = addr;
            start_size = {1'b0, `RV64_LSU_SIZE_DWORD};
            start_wdata = operand;
            start_tag = tag;
            start_id = id;
            start_slot = slot;
            start_valid = 1'b1;
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task automatic wait_request;
        input exp_write;
        input [`RV64_XLEN-1:0] exp_addr;
        input [`RV64_XLEN-1:0] exp_wdata;
        integer cycles;
        begin
            cycles = 0;
            while (!mem_valid && cycles < 16) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!mem_valid)
                $fatal(1, "atomic request timeout");
            if (mem_write !== exp_write || !mem_lock ||
                mem_addr !== exp_addr || mem_tag !== active_tag ||
                mem_effective_addr !== exp_addr ||
                mem_size !== {1'b0, `RV64_LSU_SIZE_DWORD})
                $fatal(1, "bad atomic request metadata");
            if (exp_write &&
                (mem_wdata !== exp_wdata || mem_wstrb !== 8'hff))
                $fatal(1, "bad atomic write payload");
        end
    endtask

    task automatic accept_request;
        begin
            @(negedge clk);
            mem_ready = 1'b1;
            @(negedge clk);
            mem_ready = 1'b0;
            if (!irrevocable)
                $fatal(1, "accepted atomic did not become irrevocable");
            if (mem_valid)
                $fatal(1, "atomic request repeated while inflight");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        flush = 1'b0;
        start_valid = 1'b0;
        start_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        start_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        start_slot = {RETIRE_SLOT_WIDTH{1'b0}};
        start_meta = {META_WIDTH{1'b0}};
        start_op = {`RV64_LSU_OP_WIDTH{1'b0}};
        start_addr = {`RV64_XLEN{1'b0}};
        start_size = 3'd0;
        start_wdata = {`RV64_XLEN{1'b0}};
        start_access_allowed = 1'b1;
        clear_reservation = 1'b0;
        mem_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        mem_rdata = {`RV64_XLEN{1'b0}};
        mem_error = 1'b0;
        mem_page_fault = 1'b0;
        result_ready = 1'b0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        issue_amo(`RV64_LSU_OP_AMOADD, 64'h200, 64'd7,
                  3'd3, 10'd17, 3'd2);
        wait_request(1'b0, 64'h200, 64'd0);
        repeat (2) begin
            @(negedge clk);
            if (!mem_valid || !mem_lock || mem_write ||
                mem_tag !== 3'd3 || mem_addr !== 64'h200)
                $fatal(1, "atomic read changed under backpressure");
        end
        accept_request();

        @(negedge clk);
        mem_resp_tag = 3'd4;
        mem_resp_valid = 1'b1;
        #1;
        if (mem_resp_claim || mem_resp_ready)
            $fatal(1, "atomic sequencer claimed another request's response");
        @(negedge clk);
        mem_resp_valid = 1'b0;

        // Exercise the redirect/response collision that deadlocked the old
        // inline request tracker.  The accepted AMO must advance to its write.
        @(negedge clk);
        flush = 1'b1;
        mem_resp_tag = 3'd3;
        mem_rdata = 64'd5;
        mem_resp_valid = 1'b1;
        #1;
        if (!mem_resp_claim || !mem_resp_ready)
            $fatal(1, "atomic read response was not claimed");
        @(negedge clk);
        flush = 1'b0;
        mem_resp_valid = 1'b0;
        mem_rdata = 64'd0;

        wait_request(1'b1, 64'h200, 64'd12);
        // Once irrevocable, a later RMW phase may issue during a redirect.
        @(negedge clk);
        flush = 1'b1;
        mem_ready = 1'b1;
        #1;
        if (!mem_valid)
            $fatal(1, "redirect suppressed an irrevocable AMO write");
        @(negedge clk);
        flush = 1'b0;
        mem_ready = 1'b0;

        @(negedge clk);
        mem_resp_tag = 3'd3;
        mem_resp_valid = 1'b1;
        @(negedge clk);
        mem_resp_valid = 1'b0;

        repeat (2) @(negedge clk);
        if (!result_valid || result_data !== 64'd5 ||
            result_id !== 10'd17 || result_slot !== 3'd2 ||
            result_meta !== start_meta || result_illegal ||
            result_misaligned || result_access_fault || result_page_fault)
            $fatal(1, "bad atomic completion");
        result_ready = 1'b1;
        #1;
        if (!done)
            $fatal(1, "atomic done did not follow result handshake");
        @(negedge clk);
        result_ready = 1'b0;
        if (active || irrevocable)
            $fatal(1, "atomic state did not clear after completion");

        // A redirect before request acceptance must cancel the operation and
        // must not leak a request in the redirect cycle.
        issue_amo(`RV64_LSU_OP_AMOADD, 64'h300, 64'd1,
                  3'd6, 10'd21, 3'd4);
        @(negedge clk);
        flush = 1'b1;
        #1;
        if (mem_valid)
            $fatal(1, "pre-request atomic leaked through redirect");
        @(negedge clk);
        flush = 1'b0;
        if (active || irrevocable || mem_valid || result_valid)
            $fatal(1, "redirect did not cancel pre-request atomic");

        $display("PASS: atomic sequencer tags, redirects, and RMW lifetime");
        $finish;
    end
endmodule
