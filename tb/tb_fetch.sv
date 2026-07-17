`timescale 1ns/1ps
`include "core/fetch/fetch.v"
`timescale 1ns/1ps

module tb_fetch;

    logic                             clk;
    logic                             rst_n;
    logic                             flush;
    logic                             redirect;
    logic                             redirect_replay;
    logic [`RV64_XLEN-1:0]            redirect_pc;
    logic                             redirect_replayed;
    logic                             pc_ready;
    logic                             pc_valid;
    logic [`RV64_XLEN-1:0]            pc;
    logic [63:0]                      trace_id_in;
    logic                             mem_valid;
    logic                             mem_next_valid;
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

    logic [`RV64_XLEN-1:0] memory [0:15];
    logic [`RV64_XLEN-1:0] pending_addr_q;
    logic                  pending_q;
    integer                request_count_q;

    openrv64_fetch dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .redirect_i(redirect),
        .redirect_replay_i(redirect_replay),
        .redirect_pc_i(redirect_pc),
        .redirect_replay_o(redirect_replayed),
        .pc_ready_o(pc_ready),
        .pc_valid_i(pc_valid),
        .pc_i(pc),
        .trace_id_i(trace_id_in),
        .mem_valid_o(mem_valid),
        .mem_next_valid_o(mem_next_valid),
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
                    "%0s: decode pc=%016x instr=%08x trace=%016x bus=%041x expected pc=%016x instr=%08x trace=%016x",
                    label, decode_pc, decode_instr, trace_id, decode_bus,
                    exp_pc, exp_instr, exp_trace_id);
            end
        end
    endtask

    task automatic expect_predecode;
        input exp_valid;
        input exp_conditional;
        input [`RV64_XLEN-1:0] exp_target;
        input [8*40-1:0] label;
        begin
            wait (decode_valid);
            #1;
            if (decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT] !==
                    exp_valid ||
                decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT] !==
                    exp_conditional ||
                (exp_valid &&
                 decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_TARGET_BITS] !==
                    exp_target)) begin
                $fatal(1,
                    "%0s: predecode valid=%0b conditional=%0b target=%016x expected valid=%0b conditional=%0b target=%016x",
                    label,
                    decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT],
                    decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT],
                    decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_TARGET_BITS],
                    exp_valid, exp_conditional, exp_target);
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
        integer request_count_before;

        for (i = 0; i < 16; i = i + 1) begin
            memory[i] = {32'h1000_0000 + i, 32'h2000_0000 + i};
        end
        // Direct controls exercise the stored sideband.  JAL +16 at PC 0
        // and BEQ +12 at PC 4 both target 0x10.  The next line contains an
        // illegal BRANCH funct3 and a targetless JALR; neither may claim
        // direct-target metadata.
        memory[0] = {32'h0000_0663, 32'h0100_006f};
        memory[1] = {32'h0000_0067, 32'h0000_2063};

        rst_n = 1'b0;
        flush = 1'b0;
        redirect = 1'b0;
        redirect_replay = 1'b0;
        redirect_pc = {`RV64_XLEN{1'b0}};
        pc_valid = 1'b0;
        pc = {`RV64_XLEN{1'b0}};
        trace_id_in = 64'd0;
        decode_ready = 1'b0;
        mem_fault = 1'b0;
        mem_page_fault = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Fill all eight line buffers while decode is held.  Eight memory
        // reads must supply all sixteen instructions.
        for (i = 0; i < 8; i = i + 1) begin
            issue_pc(i * 8, 64'd100 + (i * 2));
        end

        expect_decode(64'h0000_0000_0000_0000, memory[0][31:0], 64'd100,
                      1'b0, 1'b0, "first buffer lower slot");

        repeat (2) @(posedge clk);
        #1;
        if (!decode_valid) begin
            $fatal(1, "decode output did not hold under backpressure");
        end

        wait (!mem_valid);
        if (request_count_q != 8) begin
            $fatal(1, "expected eight line reads for sixteen instructions, got %0d",
                   request_count_q);
        end
        if (pc_ready) begin
            $fatal(1, "fetch accepted a ninth line while all eight were full");
        end

        for (i = 0; i < 8; i = i + 1) begin
            if (i == 0) begin
                expect_predecode(1'b1, 1'b0, 64'h10,
                                 "resident JAL target");
            end else if (i == 1) begin
                expect_predecode(1'b0, 1'b0, 64'h0,
                                 "illegal branch no target");
            end
            consume_decode(i * 8, memory[i][31:0], 64'd100 + (i * 2),
                           1'b0, 1'b0, "sixteen-entry fill lower slot");
            if (i == 0) begin
                expect_predecode(1'b1, 1'b1, 64'h10,
                                 "resident conditional target");
            end else if (i == 1) begin
                expect_predecode(1'b0, 1'b0, 64'h0,
                                 "JALR has no direct target");
            end
            consume_decode((i * 8) + 4, memory[i][63:32],
                           64'd101 + (i * 2), 1'b0, 1'b0,
                           "sixteen-entry fill upper slot");
        end

        // A soft redirect preserves resident lines.  Replaying an upper slot
        // and the following line must perform no additional memory reads and
        // must assign fresh dynamic trace IDs.
        @(negedge clk);
        redirect = 1'b1;
        @(posedge clk);
        @(negedge clk);
        redirect = 1'b0;
        request_count_before = request_count_q;

        issue_pc(64'h0000_0000_0000_000c, 64'd200);
        issue_pc(64'h0000_0000_0000_0010, 64'd201);
        if (request_count_q != request_count_before) begin
            $fatal(1, "resident redirect replay unexpectedly read memory");
        end
        consume_decode(64'h0000_0000_0000_000c, memory[1][63:32], 64'd200,
                       1'b0, 1'b0, "upper-half redirect");
        consume_decode(64'h0000_0000_0000_0010, memory[2][31:0], 64'd201,
                       1'b0, 1'b0, "post-redirect lower slot");
        consume_decode(64'h0000_0000_0000_0014, memory[2][63:32], 64'd202,
                       1'b0, 1'b0, "post-redirect upper slot");

        // A predicted redirect can drive a resident target directly into the
        // clearing IF/ID stage on the redirect edge.
        request_count_before = request_count_q;
        @(negedge clk);
        redirect = 1'b1;
        redirect_replay = 1'b1;
        redirect_pc = 64'h0000_0000_0000_0004;
        trace_id_in = 64'd250;
        decode_ready = 1'b1;
        #1;
        if (!redirect_replayed || !decode_valid ||
            decode_pc !== 64'h0000_0000_0000_0004 ||
            decode_instr !== memory[0][63:32] ||
            trace_id !== 64'd250 ||
            decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT] !== 1'b1 ||
            decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT] !== 1'b1 ||
            decode_bus[`RV64_FETCH_DECODE_BUS_PREDECODE_TARGET_BITS] !== 64'h10) begin
            $fatal(1, "same-edge predicted redirect replay failed");
        end
        @(posedge clk);
        @(negedge clk);
        redirect = 1'b0;
        redirect_replay = 1'b0;
        redirect_pc = {`RV64_XLEN{1'b0}};
        trace_id_in = 64'd0;
        decode_ready = 1'b0;
        if (request_count_q != request_count_before) begin
            $fatal(1, "same-edge predicted replay unexpectedly read memory");
        end

        // A line failure marks both slots and substitutes NOPs for both.
        mem_fault = 1'b1;
        issue_pc(64'h0000_0000_0000_0044, 64'd300);
        consume_decode(64'h0000_0000_0000_0044, `RV64_INSTR_NOP, 64'd300,
                       1'b1, 1'b0, "upper-slot access fault");
        mem_fault = 1'b0;

        mem_page_fault = 1'b1;
        issue_pc(64'h0000_0000_0000_004c, 64'd400);
        consume_decode(64'h0000_0000_0000_004c, `RV64_INSTR_NOP, 64'd400,
                       1'b0, 1'b1, "upper-slot page fault");
        mem_page_fault = 1'b0;

        // A hard flush invalidates resident lines, not just unread state.
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

        request_count_before = request_count_q;
        issue_pc(64'h0000_0000_0000_0000, 64'd600);
        wait (request_count_q != request_count_before);
        consume_decode(64'h0000_0000_0000_0000, memory[0][31:0], 64'd600,
                       1'b0, 1'b0, "hard-flush invalidation refetch");

        $display("PASS: fetch two-set four-way resident replay buffers");
        $finish;
    end

endmodule
