`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"

module tb_top_3p;
    reg clk;
    reg rst_n;
    wire mem_valid;
    reg mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    reg [63:0] mem_rdata;
    reg mem_error;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire [63:0] trace_cycle;
    wire [4:0] trace_valid;
    wire [4:0] trace_stall;
    wire [4:0] trace_flush;
    wire [4:0] trace_advance;
    wire [319:0] trace_ids;
    wire [319:0] trace_pcs;
    wire [159:0] trace_instrs;
    wire [7:0] trace_events;
    wire [7:0] trace_stall_causes;
    wire trace_retire_valid;
    wire trace_retire_arch;
    wire trace_retire_exception;
    wire [4:0] trace_retire_cause;
    wire [63:0] trace_retire_next_pc;
    wire trace_retire_rd_write;
    wire [4:0] trace_retire_rd;
    wire [63:0] trace_retire_wdata;

    reg [63:0] memory [0:63];
    reg pending_q;
    reg pending_write_q;
    reg [63:0] pending_addr_q;
    reg [63:0] pending_wdata_q;
    reg [7:0] pending_wstrb_q;
    integer i;
    integer cycles;
    reg saw_two_retire;

    openrv64_top #(
        .RESET_VECTOR(64'd0),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_RV64M(1), .ENABLE_TRACE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .mem_valid(mem_valid),
        .mem_ready(mem_ready), .mem_write(mem_write), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata), .mem_error(mem_error),
        .irq_m_software(1'b0), .irq_m_timer(1'b0),
        .irq_m_external(1'b0), .irq_s_software(1'b0),
        .irq_s_timer(1'b0), .irq_s_external(1'b0),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle), .trace_valid(trace_valid),
        .trace_stall(trace_stall), .trace_flush(trace_flush),
        .trace_advance(trace_advance), .trace_ids(trace_ids),
        .trace_pcs(trace_pcs), .trace_instrs(trace_instrs),
        .trace_events(trace_events), .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    always #5 clk = ~clk;
    always @* begin
        mem_ready = pending_q;
        mem_rdata = pending_q ? memory[pending_addr_q[8:3]] : 64'd0;
        mem_error = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q <= 1'b0;
            pending_write_q <= 1'b0;
            pending_addr_q <= 64'd0;
            pending_wdata_q <= 64'd0;
            pending_wstrb_q <= 8'd0;
        end else begin
            if (pending_q) begin
                if (pending_write_q) begin
                    for (i = 0; i < 8; i = i + 1)
                        if (pending_wstrb_q[i])
                            memory[pending_addr_q[8:3]][i*8 +: 8] <=
                                pending_wdata_q[i*8 +: 8];
                end
                pending_q <= 1'b0;
            end else if (mem_valid) begin
                pending_q <= 1'b1;
                pending_write_q <= mem_write;
                pending_addr_q <= mem_addr;
                pending_wdata_q <= mem_wdata;
                pending_wstrb_q <= mem_wstrb;
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        pending_q = 0;
        saw_two_retire = 0;
        for (i = 0; i < 64; i = i + 1) memory[i] = 64'd0;
        // Two independent ADDI instructions, then a dependency and another
        // independent ADDI.  The store must observe x7=33 before EBREAK halts.
        memory[0] = {32'h0160_0313, 32'h00b0_0293};
        memory[1] = {32'h0010_0413, 32'h0062_83b3};
        memory[2] = {32'h0010_0073, 32'h0870_3023};
        repeat (5) @(posedge clk);
        rst_n = 1;

        for (cycles = 0; cycles < 400 && !dbg_halted; cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            if (dut.g_backend_3p.u_core_3p.backend_retire_count == 2)
                saw_two_retire = 1;
        end
        if (!dbg_halted) begin
            $display("DBG pc=%h dbg=%h/%h mem=%b/%b addr=%h dq=%0d rq=%0d issue=%b comp=%b busy=%h barrier=%b",
                     dut.g_backend_3p.u_core_3p.pc_q, dbg_pc, dbg_instr,
                     mem_valid, mem_ready, mem_addr,
                     dut.g_backend_3p.u_core_3p.backend_dispatch_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_retire_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_issue_valid,
                     dut.g_backend_3p.u_core_3p.backend_complete_valid,
                     dut.g_backend_3p.u_core_3p.backend_write_busy,
                     dut.g_backend_3p.u_core_3p.backend_barrier);
            $display("DBG gpr x5=%0d x6=%0d x7=%0d x8=%0d mem80=%0d fetchv=%b decv=%b ready=%b",
                     dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5],
                     dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6],
                     dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7],
                     dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8],
                     memory[16],
                     dut.g_backend_3p.u_core_3p.fetch_mem_valid,
                     dut.g_backend_3p.u_core_3p.fetch_decode_valid,
                     dut.g_backend_3p.u_core_3p.fetch_decode_ready);
            $fatal(1, "3P core did not halt");
        end
        if (!saw_two_retire) $fatal(1, "3P core never retired two-wide");
        if (memory[16] != 64'd33)
            $fatal(1, "3P ordered store mismatch: %016x", memory[16]);
        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5] != 11 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6] != 22 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7] != 33 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8] != 1)
            $fatal(1, "3P architectural GPR results are wrong");

        $display("PASS: selectable 3P core two-wide fetch/retire and ordered store");
        $finish;
    end
endmodule
