`timescale 1ns/1ps
`include "core/exec/bp/defs.v"

module tb_uart_firmware #(
    parameter integer BP_TYPE = `OPENRV64_BP_DEFAULT,
    parameter integer BP_RAS_ENABLE = 1,
    parameter integer BP_RAS_DEPTH = 8
);

    localparam integer FIRMWARE_IMAGE_WORDS = (64 * 1024) / 8;

    logic clk;
    logic rst_n;
    logic uart_rx;
    logic uart_tx;
    logic soc_rst_n;
    logic core_rst_n;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [31:0] gpio_out;

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

    integer phase;
    integer success_external_irqs;
    integer success_timer_irqs;
    integer success_claims;
    integer timeout_external_irqs;
    integer timeout_timer_irqs;
    integer timeout_claims;
    integer load_owner_stalls;
    integer phase_cycles;
    integer phase_retired;
    logic timeout_only;
    string memh_path;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(32),
        .MEMORY_BYTES(16 * 1024 * 1024),
        .ENABLE_TRACE(1'b1),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(BP_RAS_ENABLE),
        .BP_RAS_DEPTH(BP_RAS_DEPTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(uart_rx),
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

    openrv64_cycle_trace u_cycle_trace (
        .clk(clk),
        .rst_n(core_rst_n),
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

    task automatic drive_serial_bit;
        input logic value;
        begin
            uart_rx = value;
            repeat (16) @(posedge clk);
        end
    endtask

    task automatic send_serial_byte;
        input logic [7:0] data;
        integer bit_index;
        begin
            @(negedge clk);
            drive_serial_bit(1'b0);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                drive_serial_bit(data[bit_index]);
            end
            drive_serial_bit(1'b1);
            uart_rx = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic expect_transmitted_byte;
        input logic [7:0] expected;
        integer bit_index;
        begin
            @(negedge uart_tx);
            repeat (8) @(posedge clk);
            #1;
            if (uart_tx !== 1'b0) begin
                $fatal(1, "transmit start bit was not low");
            end
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                repeat (16) @(posedge clk);
                #1;
                if (uart_tx !== expected[bit_index]) begin
                    $fatal(1,
                           "TX byte %02x bit %0d was %b, expected %b",
                           expected, bit_index, uart_tx, expected[bit_index]);
                end
            end
            repeat (16) @(posedge clk);
            #1;
            if (uart_tx !== 1'b1) begin
                $fatal(1, "transmit stop bit was not high for %02x", expected);
            end
        end
    endtask

    task automatic wait_for_software_ready;
        integer cycles;
        begin : ready_loop
            for (cycles = 0; cycles < 20000; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (core_rst_n && dut.u_uart.ier_q[0] &&
                    dut.u_core.u_core.u_csrs.mie_q[9] &&
                    dut.u_core.u_core.u_csrs.mstatus_q[3]) begin
                    disable ready_loop;
                end
            end
            $fatal(1, "firmware did not enable UART, SEIP, and global interrupts");
        end
    endtask

    task automatic wait_for_halt;
        input [8*24-1:0] label;
        integer cycles;
        begin : halt_loop
            if (dbg_halted) begin
                disable halt_loop;
            end
            for (cycles = 0; cycles < 20000; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (dbg_halted) begin
                    disable halt_loop;
                end
            end
            $fatal(1, "%0s did not halt, pc=%016x instr=%08x",
                   label, dbg_pc, dbg_instr);
        end
    endtask

    always @(posedge clk) begin
        if (!core_rst_n) begin
            phase_cycles <= 0;
            phase_retired <= 0;
        end else begin
            phase_cycles <= phase_cycles + 1;
            if (trace_retire_arch)
                phase_retired <= phase_retired + 1;
        end

        if (core_rst_n && dut.core_mem_valid && dut.core_mem_ready &&
            dut.core_mem_error) begin
            $display("bus fault addr=%016x write=%b wdata=%016x wstrb=%02x",
                     dut.core_mem_addr, dut.core_mem_write,
                     dut.core_mem_wdata, dut.core_mem_wstrb);
            $display("pipeline mem pc=%016x instr=%08x wb pc=%016x instr=%08x",
                     dut.u_core.u_core.exec_trace_mem_pc,
                     dut.u_core.u_core.exec_trace_mem_instr,
                     dut.u_core.u_core.exec_wb_pc,
                     dut.u_core.u_core.exec_wb_instr);
            $display("gpr sp=%016x ra=%016x gp=%016x t0=%016x t1=%016x t2=%016x",
                     dut.u_core.u_core.u_gpr.regs[2],
                     dut.u_core.u_core.u_gpr.regs[1],
                     dut.u_core.u_core.u_gpr.regs[3],
                     dut.u_core.u_core.u_gpr.regs[5],
                     dut.u_core.u_core.u_gpr.regs[6],
                     dut.u_core.u_core.u_gpr.regs[7]);
            $display("gpr a0=%016x a1=%016x a2=%016x a3=%016x a4=%016x a5=%016x",
                     dut.u_core.u_core.u_gpr.regs[10],
                     dut.u_core.u_core.u_gpr.regs[11],
                     dut.u_core.u_core.u_gpr.regs[12],
                     dut.u_core.u_core.u_gpr.regs[13],
                     dut.u_core.u_core.u_gpr.regs[14],
                     dut.u_core.u_core.u_gpr.regs[15]);
            $fatal(1, "firmware bus decode error at %016x (dbg pc=%016x instr=%08x)",
                   dut.core_mem_addr, dbg_pc, dbg_instr);
        end

        if (core_rst_n && dut.u_core.u_core.hard_flush_irq_req) begin
            if (dut.u_core.u_core.csr_irq_cause == 5'd9) begin
                if (phase == 0) begin
                    success_external_irqs <= success_external_irqs + 1;
                end else begin
                    timeout_external_irqs <= timeout_external_irqs + 1;
                end
            end else if (dut.u_core.u_core.csr_irq_cause == 5'd7) begin
                if (phase == 0) begin
                    success_timer_irqs <= success_timer_irqs + 1;
                end else begin
                    timeout_timer_irqs <= timeout_timer_irqs + 1;
                end
            end
        end

        if (core_rst_n && dut.u_core.u_core.dispatch_scoreboard_stall) begin
            load_owner_stalls <= load_owner_stalls + 1;
        end

        if (core_rst_n && dut.plic_valid && !dut.plic_write &&
            (dut.plic_addr == 64'h0000_0000_0020_0004)) begin
            if (phase == 0) begin
                success_claims <= success_claims + 1;
            end else begin
                timeout_claims <= timeout_claims + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        uart_rx = 1'b1;
        phase = 0;
        success_external_irqs = 0;
        success_timer_irqs = 0;
        success_claims = 0;
        timeout_external_irqs = 0;
        timeout_timer_irqs = 0;
        timeout_claims = 0;
        load_owner_stalls = 0;
        phase_cycles = 0;
        phase_retired = 0;
        timeout_only = $test$plusargs("timeout_only");
        if (timeout_only)
            phase = 1;

        if (!$value$plusargs("memh=%s", memh_path)) begin
            $fatal(1, "missing +memh=<UART firmware image>");
        end

        // Avoid a time-zero race with the RAM model's initialization block.
        #1;
        $readmemh(memh_path, dut.u_memory.memory_q,
                  0, FIRMWARE_IMAGE_WORDS - 1);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        if (timeout_only) begin
            wait_for_software_ready();
            expect_transmitted_byte("t");
            expect_transmitted_byte("i");
            expect_transmitted_byte("m");
            expect_transmitted_byte("e");
            expect_transmitted_byte("o");
            expect_transmitted_byte("u");
            expect_transmitted_byte("t");
            expect_transmitted_byte(8'h0a);
            wait_for_halt("UART timeout-only run");
            $display(
                "PERF_UART_1P_TIMEOUT cycles=%0d retired=%0d IPC=%0.4f",
                phase_cycles, phase_retired,
                $itor(phase_retired) / $itor(phase_cycles));
            if (timeout_timer_irqs == 0)
                $fatal(1,
                       "timeout-only path did not take a CLINT machine-timer IRQ");
            if ((timeout_external_irqs == 0) || (timeout_claims == 0))
                $fatal(1,
                       "timeout-only response was not transmitted through UART IRQs");
            if (load_owner_stalls == 0)
                $fatal(1,
                       "compiled firmware did not exercise ownership stalls");
            $display(
                "PASS: timeout-only UART run with %0d ownership stalls",
                load_owner_stalls);
            $finish;
        end

        wait_for_software_ready();

        fork
            begin
                send_serial_byte("c");
                send_serial_byte("o");
                send_serial_byte("d");
                send_serial_byte("e");
                send_serial_byte("x");
                send_serial_byte(8'h0a);
            end
            begin
                expect_transmitted_byte("h");
                expect_transmitted_byte("e");
                expect_transmitted_byte("l");
                expect_transmitted_byte("l");
                expect_transmitted_byte("o");
                expect_transmitted_byte(" ");
                expect_transmitted_byte("c");
                expect_transmitted_byte("o");
                expect_transmitted_byte("d");
                expect_transmitted_byte("e");
                expect_transmitted_byte("x");
                expect_transmitted_byte(8'h0a);
            end
        join

        wait_for_halt("successful UART run");
        $display("PERF_UART_1P_SUCCESS cycles=%0d retired=%0d IPC=%0.4f",
                 phase_cycles, phase_retired,
                 $itor(phase_retired) / $itor(phase_cycles));
        if ((success_external_irqs == 0) || (success_claims == 0)) begin
            $fatal(1, "success path did not use PLIC/UART interrupts");
        end
        if (success_timer_irqs != 0) begin
            $fatal(1, "success path unexpectedly reached its timeout");
        end

        // Reboot the same image without input. RAM contents persist across the
        // platform reset, while startup clears .bss before re-entering main.
        @(negedge clk);
        rst_n = 1'b0;
        phase = 1;
        repeat (5) @(posedge clk);
        #1;
        if (dbg_halted || soc_rst_n || core_rst_n) begin
            $fatal(1, "warm reset did not clear platform/core state");
        end
        @(negedge clk);
        rst_n = 1'b1;
        wait_for_software_ready();

        expect_transmitted_byte("t");
        expect_transmitted_byte("i");
        expect_transmitted_byte("m");
        expect_transmitted_byte("e");
        expect_transmitted_byte("o");
        expect_transmitted_byte("u");
        expect_transmitted_byte("t");
        expect_transmitted_byte(8'h0a);
        wait_for_halt("UART timeout run");
        $display("PERF_UART_1P_TIMEOUT cycles=%0d retired=%0d IPC=%0.4f",
                 phase_cycles, phase_retired,
                 $itor(phase_retired) / $itor(phase_cycles));

        if (timeout_timer_irqs == 0) begin
            $fatal(1, "timeout path did not take a CLINT machine-timer IRQ");
        end
        if ((timeout_external_irqs == 0) || (timeout_claims == 0)) begin
            $fatal(1, "timeout response was not transmitted through UART IRQs");
        end

        if (load_owner_stalls == 0) begin
            $fatal(1, "compiled firmware did not exercise ownership stalls");
        end

        $display("PASS: interrupt-driven UART line input/output, CLINT timeout, and %0d ownership stalls",
                 load_owner_stalls);
        $finish;
    end

    initial begin
        repeat (120000) @(posedge clk);
        $fatal(1,
               "UART firmware test timeout phase=%0d pc=%016x halted=%b mtime=%0d mtimecmp=%0d seip=%b",
               phase, dbg_pc, dbg_halted, dut.clint_mtime,
               dut.u_clint.mtimecmp_q[63:0], dut.plic_seip);
    end

endmodule
