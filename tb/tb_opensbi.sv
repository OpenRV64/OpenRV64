`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"
`include "core/backend/backend-defs.v"

module tb_opensbi #(
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P
);

    localparam logic [63:0] RAM_BASE = 64'h8000_0000;
    localparam logic [63:0] FIRMWARE_BASE = 64'h8010_0000;
    localparam logic [63:0] PAYLOAD_BASE = 64'h8020_0000;
    localparam logic [63:0] MAGIC_ADDR = 64'h80e0_0000;
    localparam logic [63:0] FDT_BASE = 64'h8ff0_0000;
    localparam logic [63:0] MAGIC_VALUE = 64'h5342_4950_4153_5301;

    localparam integer TRAMPOLINE_WORDS = 32'h0001_0000 / 8;
    localparam integer FIRMWARE_WORDS = 32'h0010_0000 / 8;
    localparam integer PAYLOAD_WORDS = 32'h0001_0000 / 8;
    localparam integer FDT_WORDS = 32'h0001_0000 / 8;

    logic clk;
    logic rst_n;
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

    string trampoline_memh;
    string firmware_memh;
    string payload_memh;
    string fdt_memh;
    string banner = "OpenSBI v1.9";
    string payload_text = "OPENRV64 SBI TIMER PAYLOAD";
    string linux_panic_text = "Kernel panic";
    integer banner_index;
    integer payload_index;
    integer linux_panic_index;
    integer cycle_count;
    integer uart_byte_count;
    integer payload_words;
    integer max_cycles;
    logic saw_banner;
    logic saw_payload_text;
    logic saw_linux_panic;
    logic saw_s_mode;
    logic linux_mode;
    wire [`RV64_PRIV_WIDTH-1:0] observed_priv_mode;
    wire [63:0] observed_t0;
    wire [63:0] observed_t1;
    wire [63:0] observed_mcause;
    wire [63:0] observed_mtval;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(32),
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64A(1'b1),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
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
            assign observed_t0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5];
            assign observed_t1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6];
            assign observed_mcause =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mcause_q;
            assign observed_mtval =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mtval_q;
        end else begin : g_observe_1p
            assign observed_priv_mode = dut.u_core.u_core.u_csrs.priv_mode_q;
            assign observed_t0 = dut.u_core.u_core.u_gpr.regs[5];
            assign observed_t1 = dut.u_core.u_core.u_gpr.regs[6];
            assign observed_mcause = dut.u_core.u_core.u_csrs.mcause_q;
            assign observed_mtval = dut.u_core.u_core.u_csrs.mtval_q;
        end
    endgenerate

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic match_byte;
        input logic [7:0] value;
        begin
            if (!saw_banner) begin
                if (value == banner[banner_index]) begin
                    banner_index = banner_index + 1;
                    if (banner_index == banner.len()) begin
                        saw_banner = 1'b1;
                    end
                end else begin
                    banner_index = (value == banner[0]) ? 1 : 0;
                end
            end

            if (!saw_payload_text) begin
                if (value == payload_text[payload_index]) begin
                    payload_index = payload_index + 1;
                    if (payload_index == payload_text.len()) begin
                        saw_payload_text = 1'b1;
                    end
                end else begin
                    payload_index = (value == payload_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_panic) begin
                if (value == linux_panic_text[linux_panic_index]) begin
                    linux_panic_index = linux_panic_index + 1;
                    if (linux_panic_index == linux_panic_text.len()) begin
                        saw_linux_panic = 1'b1;
                    end
                end else begin
                    linux_panic_index =
                        (value == linux_panic_text[0]) ? 1 : 0;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (core_rst_n &&
            (observed_priv_mode == `RV64_PRIV_S)) begin
            saw_s_mode <= 1'b1;
        end

        if (core_rst_n && dut.u_uart.write_thr) begin
            uart_byte_count <= uart_byte_count + 1;
            $write("%c", dut.uart_wdata[7:0]);
            match_byte(dut.uart_wdata[7:0]);
        end

        if (core_rst_n) begin
            cycle_count <= cycle_count + 1;
            if (((cycle_count != 0) && (cycle_count <= 10000) &&
                 ((cycle_count % 1000) == 0)) ||
                ((cycle_count > 10000) && (cycle_count <= 250000) &&
                 ((cycle_count % 10000) == 0)) ||
                ((cycle_count != 0) && ((cycle_count % 250000) == 0))) begin
                $display("OpenSBI progress cycles=%0d pc=%016x instr=%08x priv=%0d uart_bytes=%0d t0=%016x t1=%016x mcause=%016x mtval=%016x",
                         cycle_count, dbg_pc, dbg_instr,
                         observed_priv_mode,
                         uart_byte_count,
                         observed_t0, observed_t1,
                         observed_mcause, observed_mtval);
                if (linux_mode && (observed_priv_mode == `RV64_PRIV_S))
                    $display("Linux trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                             trace_valid, trace_stall, trace_flush,
                             trace_advance, trace_stall_causes,
                             trace_pcs[63:0], trace_pcs[127:64],
                             trace_pcs[191:128], trace_pcs[255:192],
                             trace_pcs[319:256],
                             trace_instrs[31:0], trace_instrs[63:32],
                             trace_instrs[95:64], trace_instrs[127:96],
                             trace_instrs[159:128]);
            end
        end

        if (core_rst_n && dut.core_mem_valid && dut.core_mem_ready &&
            dut.core_mem_error) begin
            $fatal(1,
                   "OpenSBI bus fault pc=%016x addr=%016x write=%b instr=%08x priv=%0d",
                   dbg_pc, dut.core_mem_addr, dut.core_mem_write, dbg_instr,
                   observed_priv_mode);
        end

        if (!linux_mode && saw_banner && saw_payload_text && saw_s_mode &&
            (dut.u_memory.memory_q[(MAGIC_ADDR - RAM_BASE) >> 3] ==
             MAGIC_VALUE)) begin
            if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P)
                $display("PASS: 3P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            else
                $display("PASS: 1P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            $finish;
        end

        if (linux_mode && saw_linux_panic) begin
            $display("PASS: Linux reached a kernel panic after OpenSBI handoff");
            $finish;
        end
    end

    initial begin
        rst_n = 1'b0;
        banner_index = 0;
        payload_index = 0;
        linux_panic_index = 0;
        cycle_count = 0;
        uart_byte_count = 0;
        saw_banner = 1'b0;
        saw_payload_text = 1'b0;
        saw_linux_panic = 1'b0;
        saw_s_mode = 1'b0;
        payload_words = PAYLOAD_WORDS;

        if (!$value$plusargs("payload_words=%d", payload_words))
            payload_words = PAYLOAD_WORDS;

        if (!$value$plusargs("trampoline_memh=%s", trampoline_memh) ||
            !$value$plusargs("firmware_memh=%s", firmware_memh) ||
            !$value$plusargs("payload_memh=%s", payload_memh) ||
            !$value$plusargs("fdt_memh=%s", fdt_memh)) begin
            $fatal(1, "missing OpenSBI memory-fragment plusargs");
        end

        #1;
        $display("OpenSBI load: trampoline");
        $readmemh(trampoline_memh, dut.u_memory.memory_q,
                  (RAM_BASE - RAM_BASE) >> 3,
                  ((RAM_BASE - RAM_BASE) >> 3) + TRAMPOLINE_WORDS - 1);
        $display("OpenSBI load: firmware");
        $readmemh(firmware_memh, dut.u_memory.memory_q,
                  (FIRMWARE_BASE - RAM_BASE) >> 3,
                  ((FIRMWARE_BASE - RAM_BASE) >> 3) + FIRMWARE_WORDS - 1);
        $display("OpenSBI load: payload");
        $readmemh(payload_memh, dut.u_memory.memory_q,
                  (PAYLOAD_BASE - RAM_BASE) >> 3,
                  ((PAYLOAD_BASE - RAM_BASE) >> 3) + payload_words - 1);
        $display("OpenSBI load: FDT");
        $readmemh(fdt_memh, dut.u_memory.memory_q,
                  (FDT_BASE - RAM_BASE) >> 3,
                  ((FDT_BASE - RAM_BASE) >> 3) + FDT_WORDS - 1);
        $display("OpenSBI load: complete");

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    initial begin
        linux_mode = $test$plusargs("linux_mode");
        if (linux_mode)
            payload_text = "Linux version";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 20000000;

        repeat (max_cycles) @(posedge clk);
        if (linux_mode) begin
            $display("LINUX TIMEOUT cycles=%0d pc=%016x instr=%08x priv=%0d banner=%b linux_banner=%b uart_bytes=%0d mcause=%016x mtval=%016x",
                     cycle_count, dbg_pc, dbg_instr, observed_priv_mode,
                     saw_banner, saw_payload_text, uart_byte_count,
                     observed_mcause, observed_mtval);
            $finish;
        end else begin
            $fatal(1,
                   "OpenSBI timeout pc=%016x instr=%08x priv=%0d banner=%b payload=%b magic=%016x mcause=%016x mtval=%016x",
                   dbg_pc, dbg_instr, observed_priv_mode,
                   saw_banner, saw_payload_text,
                   dut.u_memory.memory_q[(MAGIC_ADDR - RAM_BASE) >> 3],
                   observed_mcause, observed_mtval);
        end
    end

endmodule
