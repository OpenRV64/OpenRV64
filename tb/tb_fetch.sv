`timescale 1ns/1ps
`include "core/fetch/fetch.v"
`timescale 1ns/1ps

module tb_fetch;

    logic                             clk;
    logic                             rst_n;
    logic                             flush;
    logic                             pc_ready;
    logic                             pc_valid;
    logic [`RV64_XLEN-1:0]            pc;
    logic [63:0]                      trace_id_in;
    logic                             mem_valid;
    logic                             mem_ready;
    logic                             mem_write;
    logic [`RV64_XLEN-1:0]            mem_addr;
    logic [`RV64_XLEN-1:0]            mem_exec_addr;
    logic [`RV64_XLEN-1:0]            mem_wdata;
    logic [7:0]                       mem_wstrb;
    logic [`RV64_XLEN-1:0]            mem_rdata;
    logic                             mem_fault;
    logic                             mem_page_fault;
    logic                             decode_valid;
    logic                             decode_ready;
    logic [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    logic [`RV64_XLEN-1:0]            decode_pc;
    logic [`RV64_INSTR_WIDTH-1:0]     decode_instr;
    logic                             decode_fault;
    logic                             decode_page_fault;
    logic [63:0]                      trace_id;

    logic [`RV64_XLEN-1:0] memory [0:7];
    logic [`RV64_XLEN-1:0] pending_addr_q;
    logic                  pending_q;
    integer                request_count_q;

    openrv64_fetch dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .pc_ready_o(pc_ready),
        .pc_valid_i(pc_valid),
        .pc_i(pc),
        .trace_id_i(trace_id_in),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_exec_addr_o(mem_exec_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_fault_i(mem_fault),
        .mem_page_fault_i(mem_page_fault),
        .decode_valid_o(decode_valid),
        .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus),
        .decode_pc_o(decode_pc),
        .decode_instr_o(decode_instr),
        .decode_fault_o(decode_fault),
        .decode_page_fault_o(decode_page_fault),
        .trace_id_o(trace_id)
    );

    assign mem_ready = pending_q;
    assign mem_rdata = pending_q ? memory[pending_addr_q[5:3]] :
                                   {`RV64_XLEN{1'b0}};

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q      <= 1'b0;
            pending_addr_q <= {`RV64_XLEN{1'b0}};
            request_count_q <= 0;
        end else if (pending_q) begin
            pending_q <= 1'b0;
        end else if (mem_valid) begin
            pending_q      <= 1'b1;
            pending_addr_q <= mem_addr;
            request_count_q <= request_count_q + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            if (mem_write) begin
                $fatal(1, "fetch issued a write");
            end

            if (mem_wstrb != 8'h00) begin
                $fatal(1, "fetch write strobes nonzero: %02x", mem_wstrb);
            end

            if (mem_wdata != {`RV64_XLEN{1'b0}}) begin
                $fatal(1, "fetch write data nonzero: %016x", mem_wdata);
            end

            if (mem_addr[2:0] != 3'b000) begin
                $fatal(1, "fetch memory address not 64-bit aligned: %016x",
                       mem_addr);
            end
        end
    end

    task automatic issue_pc;
        input [`RV64_XLEN-1:0] issue_addr;
        input [63:0] issue_trace_id;
        begin
            wait (pc_ready);
            @(negedge clk);
            if (!pc_ready) begin
                $fatal(1, "pc lost ready before issue");
            end
            pc = issue_addr;
            trace_id_in = issue_trace_id;
            pc_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pc_valid = 1'b0;
            pc = {`RV64_XLEN{1'b0}};
            trace_id_in = 64'd0;
        end
    endtask

    task automatic expect_decode;
        input [`RV64_XLEN-1:0] exp_pc;
        input [`RV64_INSTR_WIDTH-1:0] exp_instr;
        input [63:0] exp_trace_id;
        input exp_fault;
        input exp_page_fault;
        input [8*40-1:0] label;
        begin
            wait (decode_valid);
            #1;
            if (decode_pc !== exp_pc ||
                decode_instr !== exp_instr ||
                trace_id !== exp_trace_id ||
                decode_fault !== exp_fault ||
                decode_page_fault !== exp_page_fault ||
                decode_bus[`RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT] !==
                    exp_fault ||
                decode_bus[`RV64_FETCH_DECODE_BUS_PAGE_FAULT_BIT] !==
                    exp_page_fault ||
                decode_bus[`RV64_FETCH_DECODE_BUS_PC_BITS] !== exp_pc ||
                decode_bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS] !== exp_instr) begin
                $fatal(1,
                    "%0s: decode pc=%016x instr=%08x trace=%016x bus=%025x expected pc=%016x instr=%08x trace=%016x",
                    label, decode_pc, decode_instr, trace_id, decode_bus,
                    exp_pc, exp_instr, exp_trace_id);
            end
        end
    endtask

    task automatic consume_decode;
        input [`RV64_XLEN-1:0] exp_pc;
        input [`RV64_INSTR_WIDTH-1:0] exp_instr;
        input [63:0] exp_trace_id;
        input exp_fault;
        input exp_page_fault;
        input [8*40-1:0] label;
        begin
            expect_decode(exp_pc, exp_instr, exp_trace_id, exp_fault,
                          exp_page_fault, label);
            @(negedge clk);
            decode_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            decode_ready = 1'b0;
        end
    endtask

    initial begin
        integer i;

        for (i = 0; i < 8; i = i + 1) begin
            memory[i] = {`RV64_XLEN{1'b0}};
        end

        memory[0] = {32'h1111_1111, 32'h2222_2222};
        memory[1] = {32'h3333_3333, 32'h4444_4444};
        memory[2] = {32'h5555_5555, 32'h6666_6666};
        memory[3] = {32'h7777_7777, 32'h8888_8888};
        memory[4] = {32'h9999_9999, 32'haaaa_aaaa};

        rst_n = 1'b0;
        flush = 1'b0;
        pc_valid = 1'b0;
        pc = {`RV64_XLEN{1'b0}};
        trace_id_in = 64'd0;
        decode_ready = 1'b0;
        mem_fault = 1'b0;
        mem_page_fault = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Fill all four line buffers while decode is held.  Four memory reads
        // must supply all eight instructions.
        issue_pc(64'h0000_0000_0000_0000, 64'd100);
        expect_decode(64'h0000_0000_0000_0000, 32'h2222_2222, 64'd100,
                      1'b0, 1'b0, "first buffer lower slot");

        repeat (2) @(posedge clk);
        #1;
        if (!decode_valid) begin
            $fatal(1, "decode output did not hold under backpressure");
        end

        issue_pc(64'h0000_0000_0000_0008, 64'd102);
        issue_pc(64'h0000_0000_0000_0010, 64'd104);
        issue_pc(64'h0000_0000_0000_0018, 64'd106);
        wait (!mem_valid);
        if (request_count_q != 4) begin
            $fatal(1, "expected four line reads for eight instructions, got %0d",
                   request_count_q);
        end
        if (pc_ready) begin
            $fatal(1, "fetch accepted a fifth line while all four were full");
        end

        consume_decode(64'h0000_0000_0000_0000, 32'h2222_2222, 64'd100,
                       1'b0, 1'b0, "first buffer lower slot");
        consume_decode(64'h0000_0000_0000_0004, 32'h1111_1111, 64'd101,
                       1'b0, 1'b0, "first buffer upper slot");
        consume_decode(64'h0000_0000_0000_0008, 32'h4444_4444, 64'd102,
                       1'b0, 1'b0, "second buffer lower slot");
        consume_decode(64'h0000_0000_0000_000c, 32'h3333_3333, 64'd103,
                       1'b0, 1'b0, "second buffer upper slot");
        consume_decode(64'h0000_0000_0000_0010, 32'h6666_6666, 64'd104,
                       1'b0, 1'b0, "third buffer lower slot");
        consume_decode(64'h0000_0000_0000_0014, 32'h5555_5555, 64'd105,
                       1'b0, 1'b0, "third buffer upper slot");
        consume_decode(64'h0000_0000_0000_0018, 32'h8888_8888, 64'd106,
                       1'b0, 1'b0, "fourth buffer lower slot");
        consume_decode(64'h0000_0000_0000_001c, 32'h7777_7777, 64'd107,
                       1'b0, 1'b0, "fourth buffer upper slot");

        // A redirect into an upper slot emits only that instruction.  The next
        // request begins at the following 8-byte line and again emits two.
        issue_pc(64'h0000_0000_0000_000c, 64'd200);
        issue_pc(64'h0000_0000_0000_0010, 64'd201);
        consume_decode(64'h0000_0000_0000_000c, 32'h3333_3333, 64'd200,
                       1'b0, 1'b0, "upper-half redirect");
        consume_decode(64'h0000_0000_0000_0010, 32'h6666_6666, 64'd201,
                       1'b0, 1'b0, "post-redirect lower slot");
        consume_decode(64'h0000_0000_0000_0014, 32'h5555_5555, 64'd202,
                       1'b0, 1'b0, "post-redirect upper slot");

        // A line failure marks both slots and substitutes NOPs for both.
        mem_fault = 1'b1;
        issue_pc(64'h0000_0000_0000_0018, 64'd300);
        consume_decode(64'h0000_0000_0000_0018, `RV64_INSTR_NOP, 64'd300,
                       1'b1, 1'b0, "line access fault lower slot");
        consume_decode(64'h0000_0000_0000_001c, `RV64_INSTR_NOP, 64'd301,
                       1'b1, 1'b0, "line access fault upper slot");
        mem_fault = 1'b0;

        mem_page_fault = 1'b1;
        issue_pc(64'h0000_0000_0000_0024, 64'd400);
        consume_decode(64'h0000_0000_0000_0024, `RV64_INSTR_NOP, 64'd400,
                       1'b0, 1'b1, "upper-slot page fault");
        mem_page_fault = 1'b0;

        // Flush invalidates both buffered lines and cancels an active request.
        issue_pc(64'h0000_0000_0000_0000, 64'd500);
        @(negedge clk);
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        #1;
        if (decode_valid || mem_valid) begin
            $fatal(1, "flush did not clear fetch buffers and request state");
        end

        $display("PASS: fetch four-line circular buffers");
        $finish;
    end

endmodule
