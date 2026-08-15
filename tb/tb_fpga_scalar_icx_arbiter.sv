`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_fpga_scalar_icx_arbiter;

    localparam logic [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam logic [63:0] MEMORY_BYTES = 64'h0000_0000_0001_0000;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic core_mem_valid;
    logic core_mem_ready;
    logic core_mem_write;
    logic [63:0] core_mem_addr;
    logic [63:0] core_mem_wdata;
    logic [7:0] core_mem_wstrb;
    logic [63:0] core_mem_rdata;
    logic core_mem_error;

    logic icx_req_valid;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic icx_req_lock;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [2:0] icx_req_size;
    logic [63:0] icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;

    logic icx_resp_valid;
    logic icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic icx_resp_error;
    logic icx_resp_sc_success;

    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;

    openrv64_fpga_scalar_icx_arbiter #(
        .MEMORY_BASE(MEMORY_BASE),
        .MEMORY_BYTES(MEMORY_BYTES)
    ) dut (
        .clk_i(clk),
        .reset_i(reset),
        .core_mem_valid_i(core_mem_valid),
        .core_mem_ready_o(core_mem_ready),
        .core_mem_write_i(core_mem_write),
        .core_mem_addr_i(core_mem_addr),
        .core_mem_wdata_i(core_mem_wdata),
        .core_mem_wstrb_i(core_mem_wstrb),
        .core_mem_rdata_o(core_mem_rdata),
        .core_mem_error_o(core_mem_error),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error)
    );

    logic [63:0] memory [0:8191];
    logic memory_pending_q;
    logic [1:0] memory_delay_q;
    logic memory_write_q;
    logic [63:0] memory_addr_q;
    logic [63:0] memory_wdata_q;
    logic [7:0] memory_wstrb_q;
    logic error_address_valid;
    logic [63:0] error_address;
    integer memory_request_count;
    integer byte_index;
    integer init_index;

    assign mem_ready = memory_pending_q && (memory_delay_q == 0);
    assign mem_rdata = memory[memory_addr_q[15:3]];
    assign mem_error = mem_ready && error_address_valid &&
                       (memory_addr_q == error_address);

    always @(posedge clk) begin
        if (reset) begin
            memory_pending_q <= 1'b0;
            memory_delay_q <= 2'd0;
            memory_write_q <= 1'b0;
            memory_addr_q <= 64'd0;
            memory_wdata_q <= 64'd0;
            memory_wstrb_q <= 8'd0;
            memory_request_count <= 0;
        end else if (!memory_pending_q && mem_valid) begin
            if (mem_addr >= MEMORY_BYTES)
                $fatal(1, "downstream address was not RAM-local: %x",
                       mem_addr);
            memory_pending_q <= 1'b1;
            memory_delay_q <= 2'd2;
            memory_write_q <= mem_write;
            memory_addr_q <= mem_addr;
            memory_wdata_q <= mem_wdata;
            memory_wstrb_q <= mem_wstrb;
            memory_request_count <= memory_request_count + 1;
        end else if (memory_pending_q && (memory_delay_q != 0)) begin
            memory_delay_q <= memory_delay_q - 2'd1;
        end else if (mem_ready) begin
            if (memory_write_q) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (memory_wstrb_q[byte_index])
                        memory[memory_addr_q[15:3]][byte_index*8 +: 8] <=
                            memory_wdata_q[byte_index*8 +: 8];
                end
            end
            memory_pending_q <= 1'b0;
        end
    end

    task automatic set_icx_read(input logic [63:0] address,
                                input logic [3:0] transaction);
        begin
            icx_req_hart_id = 4'd3;
            icx_req_txn_id = transaction;
            icx_req_source_id = `OPENRV64_ICX_SOURCE_PTW;
            icx_req_op = `OPENRV64_ICX_OP_READ;
            icx_req_lock = 1'b0;
            icx_req_kind = `OPENRV64_ICX_KIND_PTE;
            icx_req_size = 3'd6;
            icx_req_addr = address;
            icx_req_burst_len = '0;
        end
    endtask

    task automatic send_icx_request;
        begin
            icx_req_valid = 1'b1;
            while (!icx_req_ready)
                @(negedge clk);
            @(posedge clk);
            #1;
            icx_req_valid = 1'b0;
        end
    endtask

    task automatic consume_icx_response;
        begin
            icx_resp_ready = 1'b1;
            while (!icx_resp_valid)
                @(negedge clk);
            @(posedge clk);
            #1;
            icx_resp_ready = 1'b0;
        end
    endtask

    integer line_word;
    integer count_before;
    logic [511:0] held_response;
    integer test_phase;

    initial begin : watchdog
        repeat (5000) @(posedge clk);
        $fatal(1,
               "timeout phase=%0d state=%0d core=%b/%b icx_req=%b/%b icx_resp=%b/%b mem=%b/%b word=%0d",
               test_phase, dut.state_q, core_mem_valid, core_mem_ready,
               icx_req_valid, icx_req_ready, icx_resp_valid,
               icx_resp_ready, mem_valid, mem_ready, dut.ptw_word_q);
    end

    initial begin
        core_mem_valid = 1'b0;
        core_mem_write = 1'b0;
        core_mem_addr = 64'd0;
        core_mem_wdata = 64'd0;
        core_mem_wstrb = 8'd0;
        icx_req_valid = 1'b0;
        icx_req_hart_id = '0;
        icx_req_txn_id = '0;
        icx_req_source_id = `OPENRV64_ICX_SOURCE_PTW;
        icx_req_op = `OPENRV64_ICX_OP_READ;
        icx_req_lock = 1'b0;
        icx_req_kind = `OPENRV64_ICX_KIND_PTE;
        icx_req_size = 3'd6;
        icx_req_addr = MEMORY_BASE;
        icx_req_burst_len = '0;
        icx_resp_ready = 1'b0;
        error_address_valid = 1'b0;
        error_address = 64'd0;
        test_phase = 0;
        for (init_index = 0; init_index < 8192;
             init_index = init_index + 1)
            memory[init_index] = 64'h1000_0000_0000_0000 + init_index;

        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);

        // Ordinary scalar traffic remains a single blocking transaction.
        core_mem_addr = 64'h100;
        core_mem_valid = 1'b1;
        while (!core_mem_ready)
            @(negedge clk);
        if (core_mem_error ||
            core_mem_rdata != memory[64'h100 >> 3])
            $fatal(1, "scalar read response mismatch");
        @(posedge clk);
        #1;
        core_mem_valid = 1'b0;
        @(posedge clk);
        test_phase = 1;

        // One 64-byte ICX read must become eight ordered, RAM-local reads.
        for (line_word = 0; line_word < 8; line_word = line_word + 1)
            memory[(64'h240 >> 3) + line_word] =
                64'h5054_4500_0000_0000 + line_word;
        count_before = memory_request_count;
        set_icx_read(MEMORY_BASE + 64'h240, 4'ha);
        send_icx_request();
        wait (icx_resp_valid);
        if (memory_request_count != count_before + 8)
            $fatal(1, "PTW read used %0d scalar requests instead of eight",
                   memory_request_count - count_before);
        if (icx_resp_hart_id != 4'd3 || icx_resp_txn_id != 4'ha ||
            icx_resp_source_id != `OPENRV64_ICX_SOURCE_PTW ||
            icx_resp_beat_index != 0 || !icx_resp_last ||
            icx_resp_error || icx_resp_sc_success)
            $fatal(1, "PTW response metadata mismatch");
        for (line_word = 0; line_word < 8; line_word = line_word + 1) begin
            if (icx_resp_rdata[line_word*64 +: 64] !=
                (64'h5054_4500_0000_0000 + line_word))
                $fatal(1, "PTW line lane %0d mismatch", line_word);
        end

        // Response data and metadata must remain stable under backpressure.
        held_response = icx_resp_rdata;
        repeat (3) begin
            @(posedge clk);
            if (!icx_resp_valid || icx_resp_rdata != held_response)
                $fatal(1, "PTW response changed under backpressure");
        end
        consume_icx_response();
        @(posedge clk);
        test_phase = 2;

        // A core write presented with a fence wins first. The fence performs
        // no DDR read/write and responds only after that write completes.
        core_mem_write = 1'b1;
        core_mem_addr = 64'h180;
        core_mem_wdata = 64'hfeed_face_cafe_beef;
        core_mem_wstrb = 8'hff;
        core_mem_valid = 1'b1;
        icx_req_hart_id = 4'd1;
        icx_req_txn_id = 4'd7;
        icx_req_source_id = `OPENRV64_ICX_SOURCE_PTW;
        icx_req_op = `OPENRV64_ICX_OP_FENCE;
        icx_req_lock = 1'b0;
        icx_req_kind = `OPENRV64_ICX_KIND_PTE;
        icx_req_size = 3'd0;
        icx_req_addr = 64'd0;
        icx_req_burst_len = '0;
        icx_req_valid = 1'b1;
        @(posedge clk);
        if (icx_req_ready)
            $fatal(1, "fence bypassed simultaneous scalar write");
        while (!core_mem_ready)
            @(negedge clk);
        @(posedge clk);
        #1;
        core_mem_valid = 1'b0;
        core_mem_write = 1'b0;
        while (!icx_req_ready)
            @(negedge clk);
        @(posedge clk);
        #1;
        icx_req_valid = 1'b0;
        wait (icx_resp_valid);
        if (icx_resp_error || memory[64'h180 >> 3] !=
            64'hfeed_face_cafe_beef)
            $fatal(1, "fence completed before scalar write");
        consume_icx_response();
        @(posedge clk);
        test_phase = 3;

        // Any failed scalar beat makes the complete line response fail.
        error_address_valid = 1'b1;
        error_address = 64'h288;
        set_icx_read(MEMORY_BASE + 64'h280, 4'd4);
        send_icx_request();
        wait (icx_resp_valid);
        if (!icx_resp_error)
            $fatal(1, "PTW line did not accumulate scalar read error");
        consume_icx_response();
        error_address_valid = 1'b0;
        @(posedge clk);
        test_phase = 4;

        // Malformed line geometry is rejected without touching DDR.
        count_before = memory_request_count;
        set_icx_read(MEMORY_BASE + 64'h308, 4'd5);
        send_icx_request();
        wait (icx_resp_valid);
        if (!icx_resp_error || memory_request_count != count_before)
            $fatal(1, "malformed PTW read was not locally rejected");
        consume_icx_response();

        $display("OPENRV64 FPGA SCALAR ICX ARBITER PASS");
        $finish;
    end

endmodule
