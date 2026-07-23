`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

module tb_soc_memory;

    localparam integer MEM_BYTES = 16 * 1024 * 1024;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    logic ccx_req_valid;
    logic ccx_req_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    logic ccx_req_lock;
    logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    logic [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    logic [2:0] ccx_req_size;
    logic [63:0] ccx_req_addr;
    logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    logic ccx_wdata_valid;
    logic ccx_wdata_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    logic ccx_wdata_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;
    logic ccx_resp_valid;
    logic ccx_resp_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    logic ccx_resp_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    logic ccx_resp_error;
    logic ccx_resp_sc_success;

    openrv64_soc_memory #(
        .MEM_BYTES(MEM_BYTES)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .ccx_req_valid_i(ccx_req_valid),
        .ccx_req_ready_o(ccx_req_ready),
        .ccx_req_hart_id_i(ccx_req_hart_id),
        .ccx_req_txn_id_i(ccx_req_txn_id),
        .ccx_req_source_id_i(ccx_req_source_id),
        .ccx_req_op_i(ccx_req_op),
        .ccx_req_lock_i(ccx_req_lock),
        .ccx_req_order_i(ccx_req_order),
        .ccx_req_kind_i(ccx_req_kind),
        .ccx_req_attr_i(ccx_req_attr),
        .ccx_req_size_i(ccx_req_size),
        .ccx_req_addr_i(ccx_req_addr),
        .ccx_req_burst_len_i(ccx_req_burst_len),
        .ccx_wdata_valid_i(ccx_wdata_valid),
        .ccx_wdata_ready_o(ccx_wdata_ready),
        .ccx_wdata_hart_id_i(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_i(ccx_wdata_txn_id),
        .ccx_wdata_source_id_i(ccx_wdata_source_id),
        .ccx_wdata_beat_index_i(ccx_wdata_beat_index),
        .ccx_wdata_last_i(ccx_wdata_last),
        .ccx_wdata_i(ccx_wdata),
        .ccx_wstrb_i(ccx_wstrb),
        .ccx_resp_valid_o(ccx_resp_valid),
        .ccx_resp_ready_i(ccx_resp_ready),
        .ccx_resp_hart_id_o(ccx_resp_hart_id),
        .ccx_resp_txn_id_o(ccx_resp_txn_id),
        .ccx_resp_source_id_o(ccx_resp_source_id),
        .ccx_resp_beat_index_o(ccx_resp_beat_index),
        .ccx_resp_last_o(ccx_resp_last),
        .ccx_resp_rdata_o(ccx_resp_rdata),
        .ccx_resp_error_o(ccx_resp_error),
        .ccx_resp_sc_success_o(ccx_resp_sc_success)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_write;
        input logic [63:0] address;
        input logic [63:0] data;
        input logic [7:0] strobe;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = strobe;
            #1;
            if (mem_ready) begin
                $fatal(1, "memory write completed combinationally at %016x",
                       address);
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!mem_ready || mem_rdata !== 64'h0) begin
                $fatal(1, "memory write response invalid at %016x", address);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'h0;
            mem_wdata = 64'h0;
            mem_wstrb = 8'h00;
        end
    endtask

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*56-1:0] label;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            #1;
            if (mem_ready) begin
                $fatal(1, "%0s: read completed combinationally", label);
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!mem_ready || mem_rdata !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, mem_rdata, expected);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0;
        end
    endtask

    task automatic ccx_command;
        input logic [`OPENRV64_CCX_OP_WIDTH-1:0] operation;
        input logic [63:0] address;
        input logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        begin
            @(negedge clk);
            ccx_req_valid = 1'b1;
            ccx_req_op = operation;
            ccx_req_addr = address;
            ccx_req_txn_id = transaction;
            while (!ccx_req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            ccx_req_valid = 1'b0;
        end
    endtask

    task automatic expect_ccx_response;
        input logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] transaction;
        input logic expected_error;
        input logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] expected_data;
        input [8*56-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while (!ccx_resp_valid && cycles < 20) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!ccx_resp_valid)
                $fatal(1, "%0s: CCX response timed out", label);
            if ((ccx_resp_txn_id !== transaction) ||
                (ccx_resp_source_id !== `OPENRV64_CCX_SOURCE_PTW) ||
                (ccx_resp_error !== expected_error) ||
                (ccx_resp_rdata !== expected_data) ||
                (ccx_resp_beat_index !== 0) || !ccx_resp_last ||
                ccx_resp_sc_success)
                $fatal(1, "%0s: malformed CCX response", label);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        mem_valid = 1'b0;
        rst_n = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;
        ccx_req_valid = 1'b0;
        ccx_req_hart_id = 0;
        ccx_req_txn_id = 0;
        ccx_req_source_id = `OPENRV64_CCX_SOURCE_PTW;
        ccx_req_op = `OPENRV64_CCX_OP_READ;
        ccx_req_lock = 1'b0;
        ccx_req_order = `OPENRV64_CCX_ORDER_NONE;
        ccx_req_kind = `OPENRV64_CCX_KIND_PTE;
        ccx_req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
        ccx_req_size = 3'd6;
        ccx_req_addr = `OPENRV64_SOC_MEMORY_BASE;
        ccx_req_burst_len = 0;
        ccx_wdata_valid = 1'b0;
        ccx_wdata_hart_id = 0;
        ccx_wdata_txn_id = 0;
        ccx_wdata_source_id = `OPENRV64_CCX_SOURCE_PTW;
        ccx_wdata_beat_index = 0;
        ccx_wdata_last = 1'b1;
        ccx_wdata = 0;
        ccx_wstrb = 0;
        ccx_resp_ready = 1'b1;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "idle memory produced a response");
        end

        expect_read(64'h0000, 64'h0, "zero-initialized first word");
        expect_read(MEM_BYTES - 8, 64'h0,
                    "zero-initialized final word");

        bus_write(64'h0000, 64'h0123_4567_89ab_cdef, 8'hff);
        expect_read(64'h0000, 64'h0123_4567_89ab_cdef,
                    "full-width write");

        bus_write(64'h0008, 64'h1122_3344_5566_7788, 8'ha5);
        expect_read(64'h0008, 64'h1100_3300_0066_0088,
                    "byte-strobe write");

        // Low address bits select the containing 64-bit word. Lane placement
        // remains encoded in wdata/wstrb by the requester.
        expect_read(64'h000b, 64'h1100_3300_0066_0088,
                    "unaligned address selects aligned word");

        bus_write(MEM_BYTES - 8, 64'hfeed_face_cafe_beef, 8'hff);
        expect_read(MEM_BYTES - 8, 64'hfeed_face_cafe_beef,
                    "final word write");

        bus_write(64'h0040, 64'h0123_4567_89ab_cdef, 8'hff);
        bus_write(64'h0078, 64'hfeed_face_cafe_beef, 8'hff);
        ccx_command(`OPENRV64_CCX_OP_READ,
                    `OPENRV64_SOC_MEMORY_BASE + 64'h40, 4'd3);
        expect_ccx_response(
            4'd3, 1'b0,
            {64'hfeed_face_cafe_beef, 384'h0,
             64'h0123_4567_89ab_cdef},
            "CCX observes scalar writes");

        ccx_wdata_hart_id = 0;
        ccx_wdata_txn_id = 4'd4;
        ccx_wdata_source_id = `OPENRV64_CCX_SOURCE_PTW;
        ccx_wdata = {64'h8877_6655_4433_2211, 384'h0,
                     64'hdead_beef_cafe_f00d};
        ccx_wstrb = {8'hff, 48'h0, 8'hff};
        @(negedge clk);
        ccx_wdata_valid = 1'b1;
        while (!ccx_wdata_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        ccx_wdata_valid = 1'b0;
        ccx_command(`OPENRV64_CCX_OP_WRITE,
                    `OPENRV64_SOC_MEMORY_BASE + 64'h80, 4'd4);
        expect_ccx_response(4'd4, 1'b0, 512'h0,
                            "CCX line write response");
        expect_read(64'h0080, 64'hdead_beef_cafe_f00d,
                    "scalar observes CCX low-word write");
        expect_read(64'h00b8, 64'h8877_6655_4433_2211,
                    "scalar observes CCX high-word write");

        ccx_req_size = 3'd0;
        ccx_req_attr = `OPENRV64_CCX_ATTR_NONE;
        ccx_req_order = `OPENRV64_CCX_ORDER_ACQ_REL;
        ccx_command(`OPENRV64_CCX_OP_FENCE, 64'h0, 4'd5);
        expect_ccx_response(4'd5, 1'b0, 512'h0,
                            "CCX fence response");

        ccx_req_size = 3'd6;
        ccx_req_attr = `OPENRV64_CCX_ATTR_CACHEABLE;
        ccx_req_order = `OPENRV64_CCX_ORDER_NONE;
        ccx_command(`OPENRV64_CCX_OP_READ,
                    `OPENRV64_SOC_MEMORY_BASE + MEM_BYTES, 4'd6);
        expect_ccx_response(4'd6, 1'b1, 512'h0,
                            "CCX out-of-range response");

        // Out-of-range local requests should never be issued by the decoder;
        // the RAM nevertheless returns zero and ignores writes defensively.
        bus_write(MEM_BYTES, 64'hffff_ffff_ffff_ffff, 8'hff);
        expect_read(MEM_BYTES, 64'h0, "out-of-range local request");

        $display("tb_soc_memory: PASS");
        $finish;
    end

endmodule
