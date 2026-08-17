`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "complex/protocol/defs.v"

// Platform-backed architectural-test harness. Unlike the direct 1p/3p harnesses, this
// instance includes the boot ROM, CLINT, PLIC, and MMIO peripherals required
// by privileged architectural tests.
module tb_compliance_platform #(
    parameter bit ENABLE_RV64M = 1'b1,
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer RAM_BYTES = 1 * 1024 * 1024,
    parameter integer DEFAULT_MAX_CYCLES = 2_000_000
);
    localparam logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000;

    logic clk;
    logic rst_n;
    logic mtime_tick;
    logic uart_tx;
    logic soc_rst_n;
    logic core_rst_n;
    logic [31:0] gpio_out;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] trace_cycle;
    logic [4:0] trace_valid;
    logic [4:0] trace_stall;
    logic [4:0] trace_flush;
    logic [4:0] trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0] trace_events;
    logic [7:0] trace_stall_causes;
    logic trace_retire_valid;
    logic trace_retire_arch;
    logic trace_retire_exception;
    logic [4:0] trace_retire_cause;
    logic [63:0] trace_retire_next_pc;
    logic trace_retire_rd_write;
    logic [4:0] trace_retire_rd;
    logic [63:0] trace_retire_wdata;
    wire [1:0] observed_priv_mode;

    integer cycle_count;
    integer retired_count;
    integer max_cycles;
    integer trace_fd;
    longint unsigned tohost_addr;
    longint unsigned tohost_index;
    string memh_path;
    string test_name;
    string trace_path;

    logic tohost_icx_pending_q;
    logic tohost_icx_wdata_seen_q;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] tohost_icx_hart_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] tohost_icx_txn_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] tohost_icx_source_q;
    logic [63:0] tohost_icx_wdata_q;
    logic [7:0] tohost_icx_wstrb_q;
    logic [63:0] tohost_icx_value_q;
    integer tohost_byte;

    wire [63:0] tohost_value =
        (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) ?
        tohost_icx_value_q : dut.u_memory.memory_q[tohost_index];

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .MEMORY_BYTES(RAM_BYTES),
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .L2_BYTES(L2_BYTES),
        .L2_WAYS(L2_WAYS),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(1'b1),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(mtime_tick),
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
        .spi_card_present_i(1'b0),
        .spi_clk_o(),
        .spi_mosi_o(),
        .spi_miso_i(1'b1),
        .spi_cs_n_o(),
        .gpio_in_i(32'h0),
        .gpio_out_o(gpio_out),
        .external_irq_i(29'h0),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n),
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

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_observe_3p
            assign observed_priv_mode =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.priv_mode_q;
        end else begin : g_observe_1p
            assign observed_priv_mode =
                dut.u_core.u_core.u_csrs.priv_mode_q;
        end
    endgenerate

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        mtime_tick = 1'b1;
        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "COMPLIANCE FAIL missing +memh=<path>");
        if (!$value$plusargs("tohost=%h", tohost_addr))
            $fatal(1, "COMPLIANCE FAIL missing +tohost=<hex-address>");
        if (!$value$plusargs("test=%s", test_name))
            test_name = "unnamed";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = DEFAULT_MAX_CYCLES;
        if ((tohost_addr < RAM_BASE) ||
            (tohost_addr + 8 > RAM_BASE + RAM_BYTES) ||
            (tohost_addr[2:0] != 3'b000))
            $fatal(1, "COMPLIANCE FAIL invalid tohost address 0x%016x",
                   tohost_addr);
        tohost_index = (tohost_addr - RAM_BASE) >> 3;

        // Let the RAM model's zero-fill initial block finish first.
        #1;
        $readmemh(memh_path, dut.u_memory.memory_q);

        trace_fd = 0;
        if ($value$plusargs("arch_trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0)
                $fatal(1, "COMPLIANCE FAIL cannot open trace %s", trace_path);
            $fwrite(trace_fd,
                    "order,cycle,lane,arch,pc,instr,next_pc,rd_write,rd,wdata,exception,cause,mode\n");
        end
        cycle_count = 0;
        retired_count = 0;
        tohost_icx_pending_q = 1'b0;
        tohost_icx_wdata_seen_q = 1'b0;
        tohost_icx_hart_q = 0;
        tohost_icx_txn_q = 0;
        tohost_icx_source_q = 0;
        tohost_icx_wdata_q = 0;
        tohost_icx_wstrb_q = 0;
        tohost_icx_value_q = 0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            // The integrated L2 is write-back, so polling the backing RAM
            // cannot observe a cached external-test tohost store. Track only the
            // requested tohost word and commit it when the matching ICX write
            // response completes.
            if ((BACKEND_CONFIG == `OPENRV64_BACKEND_3P) &&
                dut.icx_req_valid && dut.icx_req_ready &&
                (dut.icx_req_op == `OPENRV64_ICX_OP_WRITE) &&
                (dut.icx_req_addr[63:6] == tohost_addr[63:6])) begin
                tohost_icx_pending_q <= 1'b1;
                tohost_icx_wdata_seen_q <= 1'b0;
                tohost_icx_hart_q <= dut.icx_req_hart_id;
                tohost_icx_txn_q <= dut.icx_req_txn_id;
                tohost_icx_source_q <= dut.icx_req_source_id;
                tohost_icx_wdata_q <= 0;
                tohost_icx_wstrb_q <= 0;
            end
            if ((BACKEND_CONFIG == `OPENRV64_BACKEND_3P) &&
                tohost_icx_pending_q &&
                dut.icx_wdata_valid && dut.icx_wdata_ready &&
                (dut.icx_wdata_hart_id == tohost_icx_hart_q) &&
                (dut.icx_wdata_txn_id == tohost_icx_txn_q) &&
                (dut.icx_wdata_source_id == tohost_icx_source_q)) begin
                for (tohost_byte = 0; tohost_byte < 8;
                     tohost_byte = tohost_byte + 1) begin
                    tohost_icx_wdata_q[tohost_byte*8 +: 8] <=
                        dut.icx_wdata[
                            (tohost_addr[5:0] + tohost_byte)*8 +: 8];
                    tohost_icx_wstrb_q[tohost_byte] <=
                        dut.icx_wstrb[tohost_addr[5:0] + tohost_byte];
                end
                tohost_icx_wdata_seen_q <= 1'b1;
            end
            if ((BACKEND_CONFIG == `OPENRV64_BACKEND_3P) &&
                tohost_icx_pending_q && tohost_icx_wdata_seen_q &&
                dut.icx_resp_valid && dut.icx_resp_ready &&
                (dut.icx_resp_hart_id == tohost_icx_hart_q) &&
                (dut.icx_resp_txn_id == tohost_icx_txn_q) &&
                (dut.icx_resp_source_id == tohost_icx_source_q)) begin
                for (tohost_byte = 0; tohost_byte < 8;
                     tohost_byte = tohost_byte + 1)
                    if (tohost_icx_wstrb_q[tohost_byte])
                        tohost_icx_value_q[tohost_byte*8 +: 8] <=
                            tohost_icx_wdata_q[tohost_byte*8 +: 8];
                tohost_icx_pending_q <= 1'b0;
            end

            cycle_count <= cycle_count + 1;
            if (trace_retire_valid) begin
                if (trace_fd != 0)
                    $fwrite(trace_fd,
                            "%0d,%0d,0,%0d,%016x,%08x,%016x,%0d,%0d,%016x,%0d,%0d,%0d\n",
                            retired_count, cycle_count,
                            trace_retire_arch, trace_pcs[319:256],
                            trace_instrs[159:128], trace_retire_next_pc,
                            trace_retire_rd_write, trace_retire_rd,
                            trace_retire_wdata, trace_retire_exception,
                            trace_retire_cause,
                            observed_priv_mode);
                retired_count <= retired_count + 1;
            end

            if (core_rst_n && tohost_value != 64'h0) begin
                if (tohost_value == 64'h1) begin
                    $display("COMPLIANCE PASS test=%s backend=platform-%s cycles=%0d retired=%0d",
                             test_name,
                             (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) ?
                             "3p" : "1p",
                             cycle_count, retired_count);
                    if (trace_fd != 0)
                        $fclose(trace_fd);
                    $finish;
                end else begin
                    $fatal(1,
                           "COMPLIANCE FAIL test=%s backend=platform tohost=0x%016x cycles=%0d pc=0x%016x instr=0x%08x",
                           test_name, tohost_value, cycle_count,
                           dbg_pc, dbg_instr);
                end
            end
            if (cycle_count >= max_cycles)
                $fatal(1,
                       "COMPLIANCE TIMEOUT test=%s backend=platform cycles=%0d retired=%0d pc=0x%016x instr=0x%08x",
                       test_name, cycle_count, retired_count,
                       dbg_pc, dbg_instr);
        end
    end
endmodule
