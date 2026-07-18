`timescale 1ns/1ps

module tb_sw_trace #(
    parameter ENABLE_FORWARDING = 1,
    parameter ENABLE_LOAD_FORWARDING = 0,
    parameter BP_TYPE = 0
);

    localparam logic [63:0] MEM_BASE = 64'h0000_0000_8000_0000;
    localparam int unsigned MEM_BYTES = 64 * 1024;
    localparam int unsigned MEM_WORDS = MEM_BYTES / 8;
    localparam logic [63:0] DEFAULT_DONE_PC =
        64'h0000_0000_8000_0010;
    localparam logic [63:0] DEFAULT_EXPECTED_A0 = 64'd100;
    localparam int unsigned DEFAULT_MAX_CYCLES = 20_000;

    logic         clk;
    logic         rst_n;
    logic         mem_valid;
    logic         mem_ready;
    logic         mem_write;
    logic [63:0]  mem_addr;
    logic [63:0]  mem_wdata;
    logic [7:0]   mem_wstrb;
    logic [63:0]  mem_rdata;
    logic         mem_error;
    logic [63:0]  dbg_pc;
    logic [31:0]  dbg_instr;
    logic         dbg_halted;
    logic [63:0]  trace_cycle;
    logic [4:0]   trace_valid;
    logic [4:0]   trace_stall;
    logic [4:0]   trace_flush;
    logic [4:0]   trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0]   trace_events;
    logic [7:0]   trace_stall_causes;
    logic         trace_retire_valid;
    logic         trace_retire_arch;
    logic         trace_retire_exception;
    logic [4:0]   trace_retire_cause;
    logic [63:0]  trace_retire_next_pc;
    logic         trace_retire_rd_write;
    logic [4:0]   trace_retire_rd;
    logic [63:0]  trace_retire_wdata;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic        mem_addr_in_range;
    logic [63:0] a0_value;
    integer      retired_count;
    integer      cycle_count;
    integer      frontend_starved_count;
    integer      frontend_fetch_wait_count;
    integer      frontend_refill_count;
    integer      frontend_request_gap_count;
    integer      frontend_backpressure_count;
    integer      frontend_bp_hold_count;
    integer      max_cycles;
    logic        done_pc_valid;
    logic        expect_a0_valid;
    logic        halt_ok;
    logic [63:0] done_pc;
    logic [63:0] expected_a0;
    string       memh_path;

    assign mem_addr_in_range =
        (mem_addr >= MEM_BASE) && (mem_addr < MEM_BASE + MEM_BYTES);
    assign mem_ready = mem_valid;
    assign mem_error = mem_valid && !mem_addr_in_range;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
        memory[(mem_addr - MEM_BASE) >> 3] : 64'h0;

    openrv64_top #(
        .RESET_VECTOR(MEM_BASE),
        .ENABLE_RV64M(1'b1),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .ENABLE_TRACE(1'b1),
        .BP_TYPE(BP_TYPE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_error(mem_error),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    openrv64_cycle_trace u_cycle_trace (
        .clk(clk),
        .rst_n(rst_n),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        if (!$value$plusargs("memh=%s", memh_path)) begin
            $fatal(1, "missing +memh=<path>");
        end

        done_pc = DEFAULT_DONE_PC;
        expected_a0 = DEFAULT_EXPECTED_A0;
        max_cycles = DEFAULT_MAX_CYCLES;
        done_pc_valid = !$test$plusargs("halt_only");
        expect_a0_valid = !$test$plusargs("no_expect_a0");
        halt_ok = $test$plusargs("halt_ok") ||
                  $test$plusargs("halt_only");
        if ($value$plusargs("done_pc=%h", done_pc))
            done_pc_valid = 1'b1;
        if ($value$plusargs("expect_a0=%h", expected_a0))
            expect_a0_valid = 1'b1;
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = DEFAULT_MAX_CYCLES;

        $readmemh(memh_path, memory);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin : monitor
        integer lane;

        if (!rst_n) begin
            a0_value <= 64'h0;
            retired_count <= 0;
            cycle_count <= 0;
            frontend_starved_count <= 0;
            frontend_fetch_wait_count <= 0;
            frontend_refill_count <= 0;
            frontend_request_gap_count <= 0;
            frontend_backpressure_count <= 0;
            frontend_bp_hold_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (dut.u_core.if_id_out_valid &&
                !dut.u_core.if_id_out_clear) begin
                frontend_backpressure_count <=
                    frontend_backpressure_count + 1;
            end

            if (dut.u_core.bp_fetch_stall ||
                dut.u_core.bp_decode_stall) begin
                frontend_bp_hold_count <= frontend_bp_hold_count + 1;
            end

            if (!dut.u_core.if_id_out_valid &&
                dut.u_core.dispatch_decode_clear &&
                !dut.u_core.bp_decode_stall &&
                !dut.u_core.hard_flush_req) begin
                frontend_starved_count <= frontend_starved_count + 1;

                if (dut.u_core.fetch_decode_valid ||
                    (dut.u_core.fetch_mem_valid &&
                     dut.u_core.fetch_mem_ready)) begin
                    frontend_refill_count <= frontend_refill_count + 1;
                end else if (dut.u_core.fetch_mem_valid) begin
                    frontend_fetch_wait_count <=
                        frontend_fetch_wait_count + 1;
                end else begin
                    frontend_request_gap_count <=
                        frontend_request_gap_count + 1;
                end
            end

            if (mem_valid && mem_ready && mem_write && mem_addr_in_range) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (mem_wstrb[lane]) begin
                        memory[(mem_addr - MEM_BASE) >> 3][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
                    end
                end
            end

            if (trace_retire_arch) begin
                retired_count <= retired_count + 1;
            end

            if (trace_retire_rd_write && trace_retire_rd == 5'd10) begin
                a0_value <= trace_retire_wdata;
            end

            if (trace_retire_exception &&
                !(halt_ok && (trace_retire_cause == 5'd3))) begin
                $fatal(1,
                    "unexpected exception at cycle %0d pc=%016x cause=%0d",
                    trace_cycle, trace_pcs[4*64 +: 64], trace_retire_cause);
            end

            if (done_pc_valid && trace_retire_arch &&
                trace_pcs[4*64 +: 64] == done_pc) begin
                if (expect_a0_valid && (a0_value != expected_a0)) begin
                    $fatal(1,
                        "program returned wrong a0=%016x expected=%016x at cycle %0d",
                        a0_value, expected_a0, trace_cycle);
                end
                $display(
                    "PASS sw trace: cycles=%0d retired=%0d a0=%0d pc=%016x",
                    trace_cycle + 1, retired_count + 1, a0_value, done_pc);
                $display(
                    "PERF_1P cycles=%0d retired=%0d IPC=%0.4f a0=%016x halted=%b",
                    trace_cycle + 1, retired_count + 1,
                    $itor(retired_count + 1) / $itor(trace_cycle + 1),
                    a0_value, dbg_halted);
                $display(
                    "FRONTEND starved=%0d fetch_wait=%0d refill=%0d request_gap=%0d backpressure=%0d bp_hold=%0d",
                    frontend_starved_count, frontend_fetch_wait_count,
                    frontend_refill_count, frontend_request_gap_count,
                    frontend_backpressure_count, frontend_bp_hold_count);
                $finish;
            end

            if (halt_ok && trace_retire_exception &&
                (trace_retire_cause == 5'd3)) begin
                if (expect_a0_valid && (a0_value != expected_a0)) begin
                    $fatal(1,
                        "halted image returned wrong a0=%016x expected=%016x at cycle %0d",
                        a0_value, expected_a0, trace_cycle);
                end
                $display(
                    "PASS sw trace halt: cycles=%0d retired=%0d a0=%016x pc=%016x",
                    trace_cycle + 1, retired_count, a0_value,
                    trace_pcs[4*64 +: 64]);
                $display(
                    "PERF_1P cycles=%0d retired=%0d IPC=%0.4f a0=%016x halted=%b",
                    trace_cycle + 1, retired_count,
                    $itor(retired_count) / $itor(trace_cycle + 1),
                    a0_value, dbg_halted);
                $display(
                    "FRONTEND starved=%0d fetch_wait=%0d refill=%0d request_gap=%0d backpressure=%0d bp_hold=%0d",
                    frontend_starved_count, frontend_fetch_wait_count,
                    frontend_refill_count, frontend_request_gap_count,
                    frontend_backpressure_count, frontend_bp_hold_count);
                $finish;
            end

            if (cycle_count >= max_cycles) begin
                $fatal(1,
                    "software trace timed out: cycles=%0d retired=%0d pc=%016x",
                    cycle_count, retired_count, dbg_pc);
            end
        end
    end

endmodule
