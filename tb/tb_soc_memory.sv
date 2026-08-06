`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

module tb_soc_memory;

    localparam integer MEM_BYTES = 16 * 1024 * 1024;
    localparam integer WIDE_DATA_WIDTH = 256;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic wide_valid;
    logic wide_ready;
    logic wide_write;
    logic [63:0] wide_addr;
    logic [WIDE_DATA_WIDTH-1:0] wide_wdata;
    logic [WIDE_DATA_WIDTH/8-1:0] wide_wstrb;
    logic [WIDE_DATA_WIDTH-1:0] wide_rdata;
    logic wide_error;

    logic icx_req_valid;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic icx_req_lock;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    logic [2:0] icx_req_size;
    logic [63:0] icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    logic icx_wdata_valid;
    logic icx_wdata_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    logic icx_wdata_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
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

    openrv64_soc_memory #(
        .MEM_BYTES(MEM_BYTES),
        .WIDE_DATA_WIDTH(WIDE_DATA_WIDTH)
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
        .wide_valid_i(wide_valid),
        .wide_ready_o(wide_ready),
        .wide_write_i(wide_write),
        .wide_addr_i(wide_addr),
        .wide_wdata_i(wide_wdata),
        .wide_wstrb_i(wide_wstrb),
        .wide_rdata_o(wide_rdata),
        .wide_error_o(wide_error),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_order_i(icx_req_order),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_attr_i(icx_req_attr),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_wdata_valid_i(icx_wdata_valid),
        .icx_wdata_ready_o(icx_wdata_ready),
        .icx_wdata_hart_id_i(icx_wdata_hart_id),
        .icx_wdata_txn_id_i(icx_wdata_txn_id),
        .icx_wdata_source_id_i(icx_wdata_source_id),
        .icx_wdata_beat_index_i(icx_wdata_beat_index),
        .icx_wdata_last_i(icx_wdata_last),
        .icx_wdata_i(icx_wdata),
        .icx_wstrb_i(icx_wstrb),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success)
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

    task automatic wide_write_beat;
        input logic [63:0] address;
        input logic [WIDE_DATA_WIDTH-1:0] data;
        input logic [WIDE_DATA_WIDTH/8-1:0] strobe;
        begin
            @(negedge clk);
            wide_valid = 1'b1;
            wide_write = 1'b1;
            wide_addr = address;
            wide_wdata = data;
            wide_wstrb = strobe;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!wide_ready || wide_error)
                $fatal(1, "wide memory write failed at %016x", address);
            @(posedge clk);
            @(negedge clk);
            wide_valid = 1'b0;
            wide_write = 1'b0;
            wide_addr = 0;
            wide_wdata = 0;
            wide_wstrb = 0;
        end
    endtask

    task automatic expect_wide_read;
        input logic [63:0] address;
        input logic [WIDE_DATA_WIDTH-1:0] expected;
        input [8*56-1:0] label;
        begin
            @(negedge clk);
            wide_valid = 1'b1;
            wide_write = 1'b0;
            wide_addr = address;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!wide_ready || wide_error || (wide_rdata !== expected))
                $fatal(1, "%0s: wide read mismatch", label);
            @(posedge clk);
            @(negedge clk);
            wide_valid = 1'b0;
            wide_addr = 0;
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

    task automatic icx_command;
        input logic [`OPENRV64_ICX_OP_WIDTH-1:0] operation;
        input logic [63:0] address;
        input logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] transaction;
        begin
            @(negedge clk);
            icx_req_valid = 1'b1;
            icx_req_op = operation;
            icx_req_addr = address;
            icx_req_txn_id = transaction;
            while (!icx_req_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            icx_req_valid = 1'b0;
        end
    endtask

    task automatic expect_icx_response;
        input logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] transaction;
        input logic expected_error;
        input logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] expected_data;
        input [8*56-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while (!icx_resp_valid && cycles < 20) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!icx_resp_valid)
                $fatal(1, "%0s: ICX response timed out", label);
            if ((icx_resp_txn_id !== transaction) ||
                (icx_resp_source_id !== `OPENRV64_ICX_SOURCE_PTW) ||
                (icx_resp_error !== expected_error) ||
                (icx_resp_rdata !== expected_data) ||
                (icx_resp_beat_index !== 0) || !icx_resp_last ||
                icx_resp_sc_success)
                $fatal(1, "%0s: malformed ICX response", label);
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
        wide_valid = 1'b0;
        wide_write = 1'b0;
        wide_addr = 0;
        wide_wdata = 0;
        wide_wstrb = 0;
        icx_req_valid = 1'b0;
        icx_req_hart_id = 0;
        icx_req_txn_id = 0;
        icx_req_source_id = `OPENRV64_ICX_SOURCE_PTW;
        icx_req_op = `OPENRV64_ICX_OP_READ;
        icx_req_lock = 1'b0;
        icx_req_order = `OPENRV64_ICX_ORDER_NONE;
        icx_req_kind = `OPENRV64_ICX_KIND_PTE;
        icx_req_attr = `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_size = 3'd6;
        icx_req_addr = `OPENRV64_SOC_MEMORY_BASE;
        icx_req_burst_len = 0;
        icx_wdata_valid = 1'b0;
        icx_wdata_hart_id = 0;
        icx_wdata_txn_id = 0;
        icx_wdata_source_id = `OPENRV64_ICX_SOURCE_PTW;
        icx_wdata_beat_index = 0;
        icx_wdata_last = 1'b1;
        icx_wdata = 0;
        icx_wstrb = 0;
        icx_resp_ready = 1'b1;

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

        wide_write_beat(
            `OPENRV64_SOC_MEMORY_BASE + 64'h20,
            {64'hdddd_dddd_dddd_dddd, 64'hcccc_cccc_cccc_cccc,
             64'hbbbb_bbbb_bbbb_bbbb, 64'haaaa_aaaa_aaaa_aaaa},
            {WIDE_DATA_WIDTH/8{1'b1}});
        expect_wide_read(
            `OPENRV64_SOC_MEMORY_BASE + 64'h20,
            {64'hdddd_dddd_dddd_dddd, 64'hcccc_cccc_cccc_cccc,
             64'hbbbb_bbbb_bbbb_bbbb, 64'haaaa_aaaa_aaaa_aaaa},
            "wide write/read");
        expect_read(64'h0030, 64'hcccc_cccc_cccc_cccc,
                    "scalar observes wide write");
        bus_write(64'h0038, 64'heeee_eeee_eeee_eeee, 8'hff);
        expect_wide_read(
            `OPENRV64_SOC_MEMORY_BASE + 64'h20,
            {64'heeee_eeee_eeee_eeee, 64'hcccc_cccc_cccc_cccc,
             64'hbbbb_bbbb_bbbb_bbbb, 64'haaaa_aaaa_aaaa_aaaa},
            "wide observes scalar write");

        // Low address bits select the containing 64-bit word. Lane placement
        // remains encoded in wdata/wstrb by the requester.
        expect_read(64'h000b, 64'h1100_3300_0066_0088,
                    "unaligned address selects aligned word");

        bus_write(MEM_BYTES - 8, 64'hfeed_face_cafe_beef, 8'hff);
        expect_read(MEM_BYTES - 8, 64'hfeed_face_cafe_beef,
                    "final word write");

        bus_write(64'h0040, 64'h0123_4567_89ab_cdef, 8'hff);
        bus_write(64'h0078, 64'hfeed_face_cafe_beef, 8'hff);
        icx_command(`OPENRV64_ICX_OP_READ,
                    `OPENRV64_SOC_MEMORY_BASE + 64'h40, 4'd3);
        expect_icx_response(
            4'd3, 1'b0,
            {64'hfeed_face_cafe_beef, 384'h0,
             64'h0123_4567_89ab_cdef},
            "ICX observes scalar writes");

        icx_wdata_hart_id = 0;
        icx_wdata_txn_id = 4'd4;
        icx_wdata_source_id = `OPENRV64_ICX_SOURCE_PTW;
        icx_wdata = {64'h8877_6655_4433_2211, 384'h0,
                     64'hdead_beef_cafe_f00d};
        icx_wstrb = {8'hff, 48'h0, 8'hff};
        @(negedge clk);
        icx_wdata_valid = 1'b1;
        while (!icx_wdata_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        icx_wdata_valid = 1'b0;
        icx_command(`OPENRV64_ICX_OP_WRITE,
                    `OPENRV64_SOC_MEMORY_BASE + 64'h80, 4'd4);
        expect_icx_response(4'd4, 1'b0, 512'h0,
                            "ICX line write response");
        expect_read(64'h0080, 64'hdead_beef_cafe_f00d,
                    "scalar observes ICX low-word write");
        expect_read(64'h00b8, 64'h8877_6655_4433_2211,
                    "scalar observes ICX high-word write");

        icx_req_size = 3'd0;
        icx_req_attr = `OPENRV64_ICX_ATTR_NONE;
        icx_req_order = `OPENRV64_ICX_ORDER_ACQ_REL;
        icx_command(`OPENRV64_ICX_OP_FENCE, 64'h0, 4'd5);
        expect_icx_response(4'd5, 1'b0, 512'h0,
                            "ICX fence response");

        icx_req_size = 3'd6;
        icx_req_attr = `OPENRV64_ICX_ATTR_CACHEABLE;
        icx_req_order = `OPENRV64_ICX_ORDER_NONE;
        icx_command(`OPENRV64_ICX_OP_READ,
                    `OPENRV64_SOC_MEMORY_BASE + MEM_BYTES, 4'd6);
        expect_icx_response(4'd6, 1'b1, 512'h0,
                            "ICX out-of-range response");

        // Out-of-range local requests should never be issued by the decoder;
        // the RAM nevertheless returns zero and ignores writes defensively.
        bus_write(MEM_BYTES, 64'hffff_ffff_ffff_ffff, 8'hff);
        expect_read(MEM_BYTES, 64'h0, "out-of-range local request");

        $display("tb_soc_memory: PASS");
        $finish;
    end

endmodule
