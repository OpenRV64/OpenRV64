`timescale 1ns/1ps
`include "core/fetch/fetch.v"

module tb_fetch_2p;
    reg clk;
    reg rst_n;
    reg flush;
    reg redirect;
    reg redirect_replay;
    reg [63:0] redirect_pc;
    wire redirect_replayed;
    wire pc_ready;
    reg pc_valid;
    reg [63:0] pc;
    wire mem_valid;
    wire mem_next_valid;
    reg mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_exec_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    reg [63:0] mem_rdata;
    reg mem_fault;
    reg mem_page_fault;
    wire decode_valid0;
    reg decode_ready0;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus0;
    wire [63:0] decode_pc0;
    wire [31:0] decode_instr0;
    wire decode_fault0;
    wire decode_page_fault0;
    reg [63:0] trace_id_in;
    wire [63:0] trace_id0;
    wire decode_valid1;
    reg decode_ready1;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus1;
    wire [63:0] decode_pc1;
    wire [31:0] decode_instr1;
    wire decode_fault1;
    wire decode_page_fault1;
    wire [63:0] trace_id1;

    openrv64_fetch #(.ENABLE_TRACE(1), .DECODE_WIDTH(2)) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .redirect_i(redirect), .redirect_replay_i(redirect_replay),
        .redirect_pc_i(redirect_pc), .redirect_replay_o(redirect_replayed),
        .pc_ready_o(pc_ready), .pc_valid_i(pc_valid), .pc_i(pc),
        .mem_valid_o(mem_valid), .mem_next_valid_o(mem_next_valid),
        .mem_ready_i(mem_ready), .mem_write_o(mem_write),
        .mem_addr_o(mem_addr), .mem_exec_addr_o(mem_exec_addr),
        .mem_wdata_o(mem_wdata), .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata), .mem_fault_i(mem_fault),
        .mem_page_fault_i(mem_page_fault),
        .decode_valid_o(decode_valid0), .decode_ready_i(decode_ready0),
        .decode_bus_o(decode_bus0), .decode_pc_o(decode_pc0),
        .decode_instr_o(decode_instr0), .decode_fault_o(decode_fault0),
        .decode_page_fault_o(decode_page_fault0),
        .trace_id_i(trace_id_in), .trace_id_o(trace_id0),
        .decode_valid1_o(decode_valid1), .decode_ready1_i(decode_ready1),
        .decode_bus1_o(decode_bus1), .decode_pc1_o(decode_pc1),
        .decode_instr1_o(decode_instr1), .decode_fault1_o(decode_fault1),
        .decode_page_fault1_o(decode_page_fault1), .trace_id1_o(trace_id1)
    );

    always #5 clk = ~clk;
    task automatic tick; begin @(posedge clk); #1; end endtask
    task automatic fail;
        input [8*100-1:0] msg;
        begin $display("FAIL: %0s", msg); $fatal(1); end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        flush = 0;
        redirect = 0;
        redirect_replay = 0;
        redirect_pc = 0;
        pc_valid = 0;
        pc = 0;
        mem_ready = 0;
        mem_rdata = 64'h0020_0113_0010_0093;
        mem_fault = 0;
        mem_page_fault = 0;
        decode_ready0 = 0;
        decode_ready1 = 0;
        trace_id_in = 64'd100;
        repeat (3) tick();
        rst_n = 1;
        tick();

        if (!pc_ready) fail("fetch did not accept initial PC");
        pc = 64'h1000;
        pc_valid = 1;
        tick();
        pc_valid = 0;
        while (!mem_valid) tick();
        mem_ready = 1;
        tick();
        mem_ready = 0;
        #1;
        if (!decode_valid0 || !decode_valid1)
            fail("full 64-bit line was not presented two-wide");
        if (decode_pc0 != 64'h1000 || decode_pc1 != 64'h1004 ||
            decode_instr0 != 32'h0010_0093 ||
            decode_instr1 != 32'h0020_0113 ||
            trace_id0 != 64'd100 || trace_id1 != 64'd101)
            fail("two-wide fetch lane contents are wrong");

        // Lane 1 is inseparable from lane 0.  If lane 1 is backpressured the
        // lower word may advance alone and the upper word is replayed on lane0.
        decode_ready0 = 1;
        decode_ready1 = 0;
        tick();
        #1;
        if (!decode_valid0 || decode_valid1 || decode_pc0 != 64'h1004 ||
            decode_instr0 != 32'h0020_0113)
            fail("upper word was not preserved after one-lane acceptance");
        decode_ready0 = 1;
        tick();
        #1;
        if (decode_valid0 || decode_valid1)
            fail("line remained unread after upper word consumption");

        $display("PASS: two-wide fetch line delivery and partial acceptance");
        $finish;
    end
endmodule
