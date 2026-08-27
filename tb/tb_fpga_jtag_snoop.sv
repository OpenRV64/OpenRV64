`timescale 1ns/1ps

// Minimal simulation shell for the 7-series hard primitive. The directed test
// drives the probe's stable JTAG-domain configuration registers directly; raw
// USER1 scan behavior is checked by the implemented bitstream and xsdb tool.
module BSCANE2 #(
    parameter DISABLE_JTAG = "FALSE",
    parameter integer JTAG_CHAIN = 1
) (
    output wire CAPTURE,
    output wire DRCK,
    output wire RESET,
    output wire RUNTEST,
    output wire SEL,
    output wire SHIFT,
    output wire TCK,
    output wire TDI,
    output wire TMS,
    output wire UPDATE,
    input  wire TDO
);
    assign CAPTURE = 1'b0;
    assign DRCK = 1'b0;
    assign RESET = 1'b0;
    assign RUNTEST = 1'b0;
    assign SEL = 1'b0;
    assign SHIFT = 1'b0;
    assign TCK = 1'b0;
    assign TDI = 1'b0;
    assign TMS = 1'b0;
    assign UPDATE = 1'b0;
    wire unused = &{1'b0, TDO, DISABLE_JTAG, JTAG_CHAIN};
endmodule

module tb_fpga_jtag_snoop;
    localparam integer SCAN_BITS = 960;

    logic clk;
    logic reset;
    logic [63:0] debug_pc;
    logic [31:0] debug_instr;
    logic [63:0] debug_rs1_data;
    logic [63:0] debug_rs2_data;
    logic retire_valid;
    logic [63:0] retire_pc;
    logic [31:0] retire_instr;
    logic retire_rd_write;
    logic [4:0] retire_rd;
    logic [63:0] retire_wdata;
    logic [9:0] debug_cache_index;
    logic debug_cache_req_toggle;
    logic [8:0] debug_snapshot_index;
    logic debug_snapshot_req_toggle;
    logic debug_snapshot_resume_pending;
    logic debug_snapshot_trigger_ack;
    logic [15:0] debug_stub_index;
    logic debug_stub_write;
    logic debug_stub_trace_read;
    logic debug_stub_wave_burst;
    logic [63:0] debug_stub_wdata;
    logic debug_stub_req_toggle;
    logic [10:0] debug_uart_trace_index;
    logic debug_uart_trace_req_toggle;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;
    logic mem_scalar;
    logic debug_irq;
    logic debug_trace_freeze;
    logic resume_toggle;
    logic reset_toggle;
    logic [SCAN_BITS-1:0] jtag_command;

    openrv64_fpga_jtag_snoop dut (
        .core_clk_i(clk),
        .core_reset_i(reset),
        .debug_pc_i(debug_pc),
        .debug_instr_i(debug_instr),
        .debug_rs1_data_i(debug_rs1_data),
        .debug_rs2_data_i(debug_rs2_data),
        .retire_valid_i(retire_valid),
        .retire_pc_i(retire_pc),
        .retire_instr_i(retire_instr),
        .retire_rd_write_i(retire_rd_write),
        .retire_rd_i(retire_rd),
        .retire_wdata_i(retire_wdata),
        .debug_cache_index_o(debug_cache_index),
        .debug_cache_req_toggle_o(debug_cache_req_toggle),
        .debug_cache_ack_toggle_i(1'b1),
        .debug_cache_result_index_i(10'd16),
        .debug_cache_valid_i(1'b1),
        .debug_cache_tag_i(64'h1fe0),
        .debug_cache_data_i({64'h3333_3333_3333_3333,
                             64'h2222_2222_2222_2222,
                             64'h1111_1111_1111_1111,
                             64'h0000_0000_0000_0000}),
        .debug_snapshot_index_o(debug_snapshot_index),
        .debug_snapshot_req_toggle_o(debug_snapshot_req_toggle),
        .debug_snapshot_ack_toggle_i(1'b1),
        .debug_snapshot_data_i(64'hfeed_face_dead_beef),
        .debug_snapshot_resume_pending_i(
            debug_snapshot_resume_pending),
        .debug_snapshot_trigger_ack_i(debug_snapshot_trigger_ack),
        .debug_stub_index_o(debug_stub_index),
        .debug_stub_write_o(debug_stub_write),
        .debug_stub_trace_read_o(debug_stub_trace_read),
        .debug_stub_wave_burst_o(debug_stub_wave_burst),
        .debug_stub_wdata_o(debug_stub_wdata),
        .debug_stub_req_toggle_o(debug_stub_req_toggle),
        .debug_stub_ack_toggle_i(1'b1),
        .debug_stub_rdata_i(64'h0123_4567_89ab_cdef),
        .debug_stub_wave_rdata_i({64'hdddd_dddd_dddd_dddd,
                                  64'hcccc_cccc_cccc_cccc,
                                  64'hbbbb_bbbb_bbbb_bbbb,
                                  64'haaaa_aaaa_aaaa_aaaa}),
        .debug_uart_trace_index_o(debug_uart_trace_index),
        .debug_uart_trace_req_toggle_o(debug_uart_trace_req_toggle),
        .debug_uart_trace_ack_toggle_i(1'b1),
        .debug_uart_trace_rdata_i({64'h1f1e_1d1c_1b1a_1918,
                                   64'h1716_1514_1312_1110,
                                   64'h0f0e_0d0c_0b0a_0908,
                                   64'h0706_0504_0302_0100}),
        .debug_uart_trace_byte_count_i(64'd20000),
        .mem_valid_i(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error),
        .mem_scalar_i(mem_scalar),
        .debug_irq_o(debug_irq),
        .debug_trace_freeze_o(debug_trace_freeze),
        .resume_toggle_o(resume_toggle),
        .reset_toggle_o(reset_toggle)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic wait_cycles(input integer count);
        repeat (count) @(posedge clk);
        #1;
    endtask

    initial begin
        reset = 1'b1;
        debug_pc = 64'h0000_0000_8000_1000;
        debug_instr = 32'h0000_0013;
        debug_rs1_data = 64'h1111_2222_3333_4444;
        debug_rs2_data = 64'haaaa_bbbb_cccc_dddd;
        retire_valid = 1'b0;
        retire_pc = 64'd0;
        retire_instr = 32'd0;
        retire_rd_write = 1'b0;
        retire_rd = 5'd0;
        retire_wdata = 64'd0;
        debug_snapshot_resume_pending = 1'b0;
        debug_snapshot_trigger_ack = 1'b0;
        mem_valid = 1'b0;
        mem_ready = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'd0;
        mem_wdata = 64'd0;
        mem_wstrb = 8'd0;
        mem_rdata = 64'd0;
        mem_error = 1'b0;
        mem_scalar = 1'b1;

        // Exercise the actual Update-DR command path and prove that a TAP
        // reset does not erase the persistent configuration. XSDB drives the
        // TAP through reset when establishing a known scan state.
        #1;
        if (dut.cfg_armed_jtag_q !== 1'b0 ||
            dut.cfg_read_jtag_q !== 1'b1)
            $fatal(1, "JTAG configuration initialization is wrong");
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[32] = 1'b1;
        jtag_command[33] = 1'b1;
        jtag_command[35] = 1'b1;
        jtag_command[36] = 1'b1;
        jtag_command[127:64] = 64'h0000_0000_8010_0008;
        jtag_command[191:128] = 64'hffff_ffff_ffff_fff8;
        jtag_command[41] = 1'b1;
        jtag_command[409:400] = 10'd16;
        jtag_command[411:410] = 2'd2;
        force dut.shift_q = jtag_command;
        force dut.bscan_sel = 1'b1;
        force dut.bscan_update = 1'b0;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (!dut.cfg_armed_jtag_q || !dut.cfg_read_jtag_q ||
            dut.cfg_mem_addr_jtag_q !== 64'h0000_0000_8010_0008 ||
            debug_cache_index !== 10'd16 || !debug_cache_req_toggle ||
            dut.status_value[895:832] !== 64'h2222_2222_2222_2222)
            $fatal(1, "Update-DR command did not latch");

        // An indexed snapshot read is observational. It must not disarm or
        // rewrite the live trigger configuration.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[42] = 1'b1;
        jtag_command[424:416] = 9'd10;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (!dut.cfg_armed_jtag_q || !dut.cfg_read_jtag_q ||
            dut.cfg_mem_addr_jtag_q !== 64'h0000_0000_8010_0008 ||
            debug_snapshot_index !== 9'd10 ||
            !debug_snapshot_req_toggle)
            $fatal(1, "indexed read rewrote the trigger configuration");

        // Stub reads and writes use the same paced USER1 port. The command
        // data overlaps status-only hit fields but must not alter the trigger.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[43] = 1'b1;
        jtag_command[431:416] = 16'd1298;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (debug_stub_index !== 16'd1298 || debug_stub_write ||
            !debug_stub_req_toggle || dut.status_value[817:816] !== 2'd2 ||
            dut.status_value[895:832] !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "stub indexed read command did not latch");

        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[44] = 1'b1;
        jtag_command[431:416] = 16'd2046;
        jtag_command[511:448] = 64'h4f52_5636_5354_5542;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (debug_stub_index !== 16'd2046 || !debug_stub_write ||
            debug_stub_wdata !== 64'h4f52_5636_5354_5542 ||
            debug_stub_req_toggle)
            $fatal(1, "stub indexed write command did not latch");

        // UART capture uses readback source three and carries the total-byte
        // count in the extension above the common indexed-read record.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[45] = 1'b1;
        jtag_command[426:416] = 11'd77;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (debug_uart_trace_index !== 11'd77 ||
            !debug_uart_trace_req_toggle ||
            dut.status_value[39:32] !== 8'd23 ||
            dut.status_value[817:816] !== 2'd3 ||
            dut.status_value[895:832] !== 64'h0706_0504_0302_0100 ||
            dut.status_value[639:384] !== {
                64'h1f1e_1d1c_1b1a_1918,
                64'h1716_1514_1312_1110,
                64'h0f0e_0d0c_0b0a_0908,
                64'h0706_0504_0302_0100} ||
            dut.status_value[959:896] !== 64'd20000)
            $fatal(1, "UART trace indexed read command did not latch");

        // Bit 47 selects the passive retirement ring while retaining the
        // existing stub readback source and request/acknowledgement path.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[43] = 1'b1;
        jtag_command[47] = 1'b1;
        jtag_command[431:416] = 16'd17;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (debug_stub_index !== 16'd17 || debug_stub_write ||
            !debug_stub_trace_read || !debug_stub_req_toggle)
            $fatal(1, "retire trace indexed read command did not latch");

        // Protocol v23 uses bit 48 to request all four waveform BRAM banks in
        // one USER1 readback.  It retains the ordinary stub source and index.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[43] = 1'b1;
        jtag_command[47] = 1'b1;
        jtag_command[48] = 1'b1;
        jtag_command[431:416] = 16'd511;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (debug_stub_index !== 16'd511 || debug_stub_write ||
            !debug_stub_trace_read || !debug_stub_wave_burst ||
            dut.status_value[639:384] !== {
                64'hdddd_dddd_dddd_dddd,
                64'hcccc_cccc_cccc_cccc,
                64'hbbbb_bbbb_bbbb_bbbb,
                64'haaaa_aaaa_aaaa_aaaa})
            $fatal(1, "wave trace burst command did not latch");

        // Reset is a persistent JTAG-domain toggle. It must not disarm or
        // otherwise rewrite the trigger that will be used after reboot.
        jtag_command = '0;
        jtag_command[31:0] = 32'h4f52_5636;
        jtag_command[46] = 1'b1;
        force dut.shift_q = jtag_command;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (!reset_toggle || !dut.cfg_armed_jtag_q ||
            dut.cfg_mem_addr_jtag_q !== 64'h0000_0000_8010_0008)
            $fatal(1, "reset command rewrote the trigger configuration");

        force dut.bscan_reset = 1'b1;
        #1 force dut.bscan_reset = 1'b0;
        if (!dut.cfg_armed_jtag_q || !dut.cfg_read_jtag_q)
            $fatal(1, "TAP reset erased persistent JTAG configuration");
        release dut.bscan_reset;
        release dut.bscan_update;
        release dut.bscan_sel;
        release dut.shift_q;

        force dut.cfg_armed_jtag_q = 1'b1;
        force dut.cfg_read_jtag_q = 1'b1;
        force dut.cfg_write_jtag_q = 1'b0;
        force dut.cfg_scalar_jtag_q = 1'b1;
        force dut.cfg_ptw_jtag_q = 1'b1;
        force dut.cfg_pc_jtag_q = 1'b0;
        force dut.cfg_cycle_enable_jtag_q = 1'b0;
        force dut.cfg_trace_window_jtag_q = 1'b0;
        force dut.cfg_mem_addr_jtag_q = 64'h0000_0000_8010_0008;
        force dut.cfg_mem_mask_jtag_q = 64'hffff_ffff_ffff_fff8;
        force dut.cfg_pc_addr_jtag_q = 64'd0;
        force dut.cfg_pc_mask_jtag_q = 64'hffff_ffff_ffff_fffc;
        force dut.cfg_cycle_target_jtag_q = 64'd0;
        force dut.clear_toggle_jtag_q = 1'b0;

        wait_cycles(3);
        reset = 1'b0;
        wait_cycles(3);

        // Scalar memory completion: capture the physical address, initiating
        // PC, response, and cycle on the exact handshake edge.
        mem_addr = 64'h0000_0000_0010_000b;
        mem_rdata = 64'h6370_7500_dead_beef;
        mem_wdata = 64'h0123_4567_89ab_cdef;
        mem_wstrb = 8'h0f;
        mem_valid = 1'b1;
        mem_ready = 1'b1;
        @(posedge clk);
        #1;
        mem_valid = 1'b0;
        mem_ready = 1'b0;
        if (!debug_irq || !debug_trace_freeze || !dut.hit_scalar_q ||
            dut.hit_ptw_q)
            $fatal(1, "scalar memory trigger did not latch");
        if (dut.hit_mem_addr_q !== 64'h0000_0000_8010_000b ||
            dut.hit_pc_value_q !== debug_pc ||
            dut.hit_mem_rdata_q !== mem_rdata ||
            dut.hit_instr_value_q !== debug_instr)
            $fatal(1, "scalar memory trigger captured the wrong record");

        // Clear uses a toggle so it is safe to transport from JTAG.
        force dut.clear_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (debug_irq)
            $fatal(1, "clear toggle did not release the captured hit");
        if (!debug_trace_freeze)
            $fatal(1, "clear toggle released trace before resume");
        force dut.resume_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (debug_trace_freeze)
            $fatal(1, "resume toggle did not release trace freeze");

        // PC match uses one coherent architectural retirement record.
        force dut.cfg_read_jtag_q = 1'b0;
        force dut.cfg_pc_jtag_q = 1'b1;
        force dut.cfg_pc_addr_jtag_q = 64'hffff_ffff_803e_2c18;
        wait_cycles(3);
        retire_pc = 64'hffff_ffff_803e_2c18;
        retire_instr = 32'h0204_3583;
        retire_rd_write = 1'b1;
        retire_rd = 5'd11;
        retire_wdata = 64'h0000_0000_0c30_0000;
        retire_valid = 1'b1;
        wait_cycles(1);
        retire_valid = 1'b0;
        if (!debug_irq || !debug_trace_freeze || !dut.hit_pc_q ||
            dut.hit_pc_value_q !== retire_pc ||
            dut.hit_instr_value_q !== retire_instr ||
            dut.hit_mem_addr_q[4:0] !== retire_rd ||
            dut.hit_mem_rdata_q !== retire_wdata)
            $fatal(1, "PC trigger did not capture");

        // The OpenSBI handler acknowledges through the snapshot MMIO control
        // register before returning from the PLIC callback. The JTAG resume
        // command disarms the comparator before that acknowledgement arrives.
        force dut.cfg_pc_jtag_q = 1'b0;
        wait_cycles(3);
        debug_snapshot_trigger_ack = 1'b1;
        wait_cycles(1);
        debug_snapshot_trigger_ack = 1'b0;
        wait_cycles(1);
        if (debug_irq)
            $fatal(1, "handler acknowledgement did not release PC hit");
        if (!debug_trace_freeze)
            $fatal(1, "handler acknowledgement released trace before resume");
        force dut.resume_toggle_jtag_q = 1'b0;
        wait_cycles(3);
        if (debug_trace_freeze)
            $fatal(1, "PC-hit resume did not release trace freeze");

        force dut.clear_toggle_jtag_q = 1'b0;
        wait_cycles(3);

        // PC+cycle mode uses the PC match only as an epoch marker. It must
        // wait the configured number of core cycles before raising the IRQ.
        force dut.cfg_pc_jtag_q = 1'b1;
        force dut.cfg_cycle_enable_jtag_q = 1'b1;
        force dut.cfg_cycle_target_jtag_q = 64'd10;
        force dut.cfg_pc_addr_jtag_q = 64'hffff_ffff_803e_5000;
        retire_pc = 64'hffff_ffff_803e_4000;
        retire_valid = 1'b1;
        wait_cycles(3);
        retire_pc = 64'hffff_ffff_803e_5000;
        wait_cycles(1);
        retire_valid = 1'b0;
        if (debug_irq || !dut.pc_delay_started_q)
            $fatal(1, "PC-relative cycle delay fired at the epoch PC");
        wait (debug_irq);
        #1;
        if (!dut.hit_cycle_q || dut.hit_pc_q ||
            dut.hit_cycle_count_q !== dut.pc_delay_target_q ||
            !debug_trace_freeze)
            $fatal(1, "PC-relative cycle delay captured the wrong count");

        force dut.clear_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (debug_irq)
            $fatal(1, "clear did not release PC-relative cycle hit");
        if (!debug_trace_freeze)
            $fatal(1, "clear released delayed-hit trace before resume");
        force dut.resume_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (debug_trace_freeze)
            $fatal(1, "delayed-hit resume did not release trace freeze");

        // Absolute cycle trigger is optional. The same counter is captured by
        // memory and PC triggers even when cycle triggering is disabled.
        force dut.cfg_pc_jtag_q = 1'b0;
        force dut.cfg_cycle_target_jtag_q = dut.cycle_count_q + 64'd10;
        force dut.cfg_cycle_enable_jtag_q = 1'b1;
        wait (debug_irq);
        #1;
        if (!dut.hit_cycle_q ||
            dut.hit_cycle_count_q !== dut.cfg_cycle_target_sync_q ||
            !debug_trace_freeze)
            $fatal(1, "cycle trigger captured the wrong count");

        force dut.clear_toggle_jtag_q = 1'b0;
        force dut.resume_toggle_jtag_q = 1'b0;
        wait_cycles(3);
        if (debug_irq || debug_trace_freeze)
            $fatal(1, "absolute-cycle resume did not release debug state");

        // Record-count mode starts on a fresh configuration edge and stops
        // after the requested number of exact retirements. This is independent
        // of JTAG scan latency and therefore supports short trace windows.
        force dut.cfg_cycle_enable_jtag_q = 1'b0;
        force dut.cfg_trace_window_jtag_q = 1'b1;
        force dut.cfg_cycle_target_jtag_q = 64'd4;
        wait_cycles(4);
        retire_valid = 1'b1;
        repeat (4) begin
            @(negedge clk);
            retire_pc = retire_pc + 64'd4;
            retire_instr = 32'h0010_8093;
        end
        @(posedge clk);
        @(negedge clk);
        retire_valid = 1'b0;
        wait_cycles(1);
        if (!debug_irq || !debug_trace_freeze || !dut.hit_trace_q ||
            dut.hit_cycle_q ||
            dut.trace_window_retire_count_q !== 16'd3)
            $fatal(1, "retirement watermark did not stop the trace window");

        debug_snapshot_trigger_ack = 1'b1;
        wait_cycles(1);
        debug_snapshot_trigger_ack = 1'b0;
        wait_cycles(1);
        if (debug_irq || !debug_trace_freeze)
            $fatal(1, "watermark trace did not remain frozen after ack");
        force dut.resume_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (debug_trace_freeze)
            $fatal(1, "watermark resume did not release trace freeze");

        debug_snapshot_resume_pending = 1'b1;
        #1;
        if (!dut.status_value[41])
            $fatal(1, "snapshot resume-pending status was not reported");

        $display("tb_fpga_jtag_snoop: PASS cycle=%0d",
                 dut.hit_cycle_count_q);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "tb_fpga_jtag_snoop timeout");
    end
endmodule
