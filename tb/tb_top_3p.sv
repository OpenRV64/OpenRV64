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
    wire ccx_req_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire ccx_resp_ready;
    reg ccx_resp_valid_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id_q;

    reg [63:0] memory [0:63];
    reg pending_q;
    reg pending_write_q;
    reg [63:0] pending_addr_q;
    reg [63:0] pending_wdata_q;
    reg [7:0] pending_wstrb_q;
    integer i;
    integer cycles;
    reg saw_two_retire;
    reg saw_pmp_busy;
    reg saw_pmp_retire_hold;
    reg saw_satp_busy;
    reg saw_satp_retire_hold;
    integer satp_busy_cycles;
    reg hpm_busy_prev;
    integer hpm_busy_cycles;
    integer hpm_busy_bursts;
    reg hpm_read_prev;
    integer hpm_read_cycles;
    integer hpm_read_bursts;

    openrv64_top #(
        .RESET_VECTOR(64'd0),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_RV64M(1), .ENABLE_TRACE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .mem_valid(mem_valid),
        .mem_ready(mem_ready), .mem_write(mem_write), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata), .mem_error(mem_error),
        .ccx_req_valid(ccx_req_valid), .ccx_req_ready(1'b1),
        .ccx_req_hart_id(ccx_req_hart_id),
        .ccx_req_txn_id(ccx_req_txn_id),
        .ccx_req_source_id(ccx_req_source_id),
        .ccx_wdata_ready(1'b1),
        .ccx_resp_valid(ccx_resp_valid_q),
        .ccx_resp_ready(ccx_resp_ready),
        .ccx_resp_hart_id(ccx_resp_hart_id_q),
        .ccx_resp_txn_id(ccx_resp_txn_id_q),
        .ccx_resp_source_id(ccx_resp_source_id_q),
        .ccx_resp_beat_index({`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}),
        .ccx_resp_last(1'b1),
        .ccx_resp_rdata({`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .ccx_resp_error(1'b0), .ccx_resp_sc_success(1'b0),
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

    // Generic-bus Sv39 still uses the native CCX port for PTW traffic and
    // completion-tracked translation shootdowns.  This test runs in Bare mode,
    // so the only possible request is the SATP shootdown fence.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_resp_valid_q <= 1'b0;
            ccx_resp_hart_id_q <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            ccx_resp_txn_id_q <=
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            ccx_resp_source_id_q <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
        end else begin
            if (ccx_resp_valid_q && ccx_resp_ready)
                ccx_resp_valid_q <= 1'b0;
            if (ccx_req_valid) begin
                ccx_resp_valid_q <= 1'b1;
                ccx_resp_hart_id_q <= ccx_req_hart_id;
                ccx_resp_txn_id_q <= ccx_req_txn_id;
                ccx_resp_source_id_q <= ccx_req_source_id;
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        pending_q = 0;
        saw_two_retire = 0;
        saw_pmp_busy = 0;
        saw_pmp_retire_hold = 0;
        saw_satp_busy = 0;
        saw_satp_retire_hold = 0;
        satp_busy_cycles = 0;
        hpm_busy_prev = 0;
        hpm_busy_cycles = 0;
        hpm_busy_bursts = 0;
        hpm_read_prev = 0;
        hpm_read_cycles = 0;
        hpm_read_bursts = 0;
        for (i = 0; i < 64; i = i + 1) memory[i] = 64'd0;
        // First force a serialized 4 KiB RWX PMPADDR update.  The following
        // PMPCFG write and arithmetic must remain behind its hard-order
        // retirement entry until the 75-cycle atomic commit finishes.
        memory[0] = {32'h3b05_1073, 32'h1ff0_0513};
        memory[1] = {32'h3a05_1073, 32'h01f0_0513};
        // SATP is already a persistent hard-order operation.  Its write may
        // take thirty cycles, but nothing younger may issue or retire.
        memory[2] = {32'h0000_0013, 32'h1800_1073};
        // Two independent ADDI instructions, then a dependency and another
        // independent ADDI.  The store must observe x7=33 before EBREAK halts.
        memory[3] = {32'h0160_0313, 32'h00b0_0293};
        memory[4] = {32'h0010_0413, 32'h0062_83b3};
        // A CSRW exercises the three-cycle HPM read and write phases; the
        // following pure read exercises the read phase alone.
        memory[5] = {32'h3200_1073, 32'h0870_3023};
        memory[6] = {32'h0010_0073, 32'hb000_24f3};
        repeat (5) @(posedge clk);
        rst_n = 1;

        for (cycles = 0; cycles < 400 && !dbg_halted; cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            if (dut.g_backend_3p.u_core_3p.backend_retire_count == 2)
                saw_two_retire = 1;
            if (dut.g_backend_3p.u_core_3p.u_csrs.csr_pmp_busy_o) begin
                saw_pmp_busy = 1;
                if ((dut.g_backend_3p.u_core_3p.backend_retire_count == 0) &&
                    dut.g_backend_3p.u_core_3p.backend_barrier)
                    saw_pmp_retire_hold = 1;
                else
                    $fatal(1, "3P PMPADDR busy did not hold retirement barrier");
                if (dut.g_backend_3p.u_core_3p.u_csrs.u_pmp.pmpaddr_q[0] !=
                    54'd0)
                    $fatal(1, "3P PMPADDR became visible before serial commit");
            end
            if (dut.g_backend_3p.u_core_3p.u_csrs.csr_satp_busy_o) begin
                saw_satp_busy = 1;
                satp_busy_cycles = satp_busy_cycles + 1;
                if ((dut.g_backend_3p.u_core_3p.backend_retire_count == 0) &&
                    dut.g_backend_3p.u_core_3p.backend_barrier)
                    saw_satp_retire_hold = 1;
                else
                    $fatal(1, "3P SATP busy did not hold retirement barrier");
                if (dut.g_backend_3p.u_core_3p.backend_satp_write)
                    $fatal(1, "3P SATP restart fired before delayed commit");
            end
            if (dut.g_backend_3p.u_core_3p.u_csrs.csr_hpm_busy_o) begin
                hpm_busy_cycles = hpm_busy_cycles + 1;
                if ((dut.g_backend_3p.u_core_3p.backend_retire_count != 0) ||
                    !dut.g_backend_3p.u_core_3p.backend_barrier)
                    $fatal(1, "3P HPM busy did not hold hard-order barrier");
            end else if (hpm_busy_prev) begin
                if (hpm_busy_cycles != 3)
                    $fatal(1, "3P HPM access latency=%0d/3",
                           hpm_busy_cycles);
                hpm_busy_bursts = hpm_busy_bursts + 1;
                hpm_busy_cycles = 0;
            end
            hpm_busy_prev =
                dut.g_backend_3p.u_core_3p.u_csrs.csr_hpm_busy_o;
            if (dut.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p.u_exec
                    .u_ex1.hpm_pending_q) begin
                hpm_read_cycles = hpm_read_cycles + 1;
                if ((dut.g_backend_3p.u_core_3p.backend_retire_count != 0) ||
                    !dut.g_backend_3p.u_core_3p.backend_barrier)
                    $fatal(1, "3P HPM read did not hold hard-order barrier");
            end else if (hpm_read_prev) begin
                if (hpm_read_cycles != 3)
                    $fatal(1, "3P HPM read latency=%0d/3",
                           hpm_read_cycles);
                hpm_read_bursts = hpm_read_bursts + 1;
                hpm_read_cycles = 0;
            end
            hpm_read_prev =
                dut.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p.u_exec
                    .u_ex1.hpm_pending_q;
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
        // Posted stores may retire before the physical bus response.  EBREAK
        // stops architectural execution, but the committed write must still
        // be allowed to drain through the generic-bus adapter.
        for (cycles = 0; cycles < 20 && memory[16] != 64'd33;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
        end
        if (!saw_two_retire) $fatal(1, "3P core never retired two-wide");
        if (!saw_pmp_busy || !saw_pmp_retire_hold)
            $fatal(1, "3P core never held a serial PMPADDR retirement");
        if (!saw_satp_busy || !saw_satp_retire_hold)
            $fatal(1, "3P core never held a serial SATP retirement");
        if (satp_busy_cycles != 30)
            $fatal(1, "3P SATP busy latency=%0d/30", satp_busy_cycles);
        if (hpm_busy_bursts != 1)
            $fatal(1, "3P HPM write busy bursts=%0d/1",
                   hpm_busy_bursts);
        if (hpm_read_bursts != 2)
            $fatal(1, "3P HPM read delay bursts=%0d/2",
                   hpm_read_bursts);
        if (memory[16] != 64'd33)
            $fatal(1, "3P ordered store mismatch: %016x", memory[16]);
        if (dut.g_backend_3p.u_core_3p.u_csrs.u_pmp.pmpaddr_q[0] !=
            54'h1ff ||
            dut.g_backend_3p.u_core_3p.u_csrs.u_pmp.pmpcfg_q[7:0] !=
            8'h1f)
            $fatal(1, "3P PMP state did not commit after serial write");
        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5] != 11 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6] != 22 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7] != 33 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8] != 1 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9] == 0)
            $fatal(1, "3P architectural GPR results are wrong");

        $display("PASS: selectable 3P core serial PMP/SATP/HPM retirement, two-wide fetch/retire, and ordered store");
        $finish;
    end
endmodule
