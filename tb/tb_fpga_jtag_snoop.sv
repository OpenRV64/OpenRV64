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
    localparam integer SCAN_BITS = 832;

    logic clk;
    logic reset;
    logic clock_halted;
    logic [63:0] debug_pc;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;
    logic mem_scalar;
    logic halt_request;
    logic resume_toggle;
    logic [SCAN_BITS-1:0] jtag_command;

    openrv64_fpga_jtag_snoop dut (
        .core_clk_i(clk),
        .core_reset_i(reset),
        .clock_halted_i(clock_halted),
        .debug_pc_i(debug_pc),
        .mem_valid_i(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error),
        .mem_scalar_i(mem_scalar),
        .halt_request_o(halt_request),
        .resume_toggle_o(resume_toggle)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic wait_cycles(input integer count);
        repeat (count) @(posedge clk);
        #1;
    endtask

    initial begin
        reset = 1'b1;
        clock_halted = 1'b0;
        debug_pc = 64'h0000_0000_8000_1000;
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
        force dut.shift_q = jtag_command;
        force dut.bscan_sel = 1'b1;
        force dut.bscan_update = 1'b0;
        #1 force dut.bscan_update = 1'b1;
        #1 force dut.bscan_update = 1'b0;
        if (!dut.cfg_armed_jtag_q || !dut.cfg_read_jtag_q ||
            dut.cfg_mem_addr_jtag_q !== 64'h0000_0000_8010_0008)
            $fatal(1, "Update-DR command did not latch");
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
        if (!halt_request || !dut.hit_scalar_q || dut.hit_ptw_q)
            $fatal(1, "scalar memory trigger did not latch");
        if (dut.hit_mem_addr_q !== 64'h0000_0000_8010_000b ||
            dut.hit_pc_value_q !== debug_pc ||
            dut.hit_mem_rdata_q !== mem_rdata)
            $fatal(1, "scalar memory trigger captured the wrong record");

        // Clear uses a toggle so it is safe to transport from JTAG.
        force dut.clear_toggle_jtag_q = 1'b1;
        wait_cycles(3);
        if (halt_request)
            $fatal(1, "clear toggle did not release the captured hit");

        // PC match has its own mask and still records the common cycle field.
        force dut.cfg_read_jtag_q = 1'b0;
        force dut.cfg_pc_jtag_q = 1'b1;
        force dut.cfg_pc_addr_jtag_q = 64'hffff_ffff_803e_2c18;
        wait_cycles(3);
        debug_pc = 64'hffff_ffff_803e_2c18;
        wait_cycles(1);
        if (!halt_request || !dut.hit_pc_q ||
            dut.hit_pc_value_q !== debug_pc)
            $fatal(1, "PC trigger did not capture");

        force dut.clear_toggle_jtag_q = 1'b0;
        force dut.cfg_pc_jtag_q = 1'b0;
        wait_cycles(3);
        if (halt_request)
            $fatal(1, "second clear toggle did not release PC hit");

        // Absolute cycle trigger is optional. The same counter is captured by
        // memory and PC triggers even when cycle triggering is disabled.
        force dut.cfg_cycle_target_jtag_q = dut.cycle_count_q + 64'd10;
        force dut.cfg_cycle_enable_jtag_q = 1'b1;
        wait (halt_request);
        #1;
        if (!dut.hit_cycle_q ||
            dut.hit_cycle_count_q !== dut.cfg_cycle_target_sync_q)
            $fatal(1, "cycle trigger captured the wrong count");

        $display("tb_fpga_jtag_snoop: PASS cycle=%0d",
                 dut.hit_cycle_count_q);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "tb_fpga_jtag_snoop timeout");
    end
endmodule
