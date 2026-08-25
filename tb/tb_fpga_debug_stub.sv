`timescale 1ns/1ps

module tb_fpga_debug_stub;
    logic clk;
    logic rst_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic cpu_write_enable;
    logic [13:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic [10:0] jtag_index;
    logic jtag_write;
    logic jtag_trace_read;
    logic [63:0] jtag_wdata;
    logic jtag_req_toggle;
    logic jtag_ack_toggle;
    logic [63:0] jtag_rdata;
    logic trace_valid;
    logic trace_freeze;
    logic [63:0] trace_pc;
    logic trace_rd_write;
    logic [4:0] trace_rd;
    logic [63:0] trace_wdata;

    openrv64_soc_debug_stub_mem dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .cpu_write_enable_i(cpu_write_enable),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .jtag_index_i(jtag_index),
        .jtag_write_i(jtag_write),
        .jtag_trace_read_i(jtag_trace_read),
        .jtag_wdata_i(jtag_wdata),
        .jtag_req_toggle_i(jtag_req_toggle),
        .jtag_ack_toggle_o(jtag_ack_toggle),
        .jtag_rdata_o(jtag_rdata),
        .trace_valid_i(trace_valid),
        .trace_freeze_i(trace_freeze),
        .trace_pc_i(trace_pc),
        .trace_rd_write_i(trace_rd_write),
        .trace_rd_i(trace_rd),
        .trace_wdata_i(trace_wdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic cpu_write64(
        input logic [13:0] address,
        input logic [63:0] data,
        input logic [7:0] strobes
    );
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = strobes;
            while (!mem_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
        end
    endtask

    task automatic cpu_read64(
        input logic [13:0] address,
        output logic [63:0] data
    );
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            mem_wstrb = 8'd0;
            while (!mem_ready)
                @(negedge clk);
            data = mem_rdata;
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
        end
    endtask

    task automatic jtag_access(
        input logic [10:0] index,
        input logic write_access,
        input logic trace_access,
        input logic [63:0] data
    );
        begin
            jtag_index = index;
            jtag_write = write_access;
            jtag_trace_read = trace_access;
            jtag_wdata = data;
            jtag_req_toggle = !jtag_req_toggle;
            wait (jtag_ack_toggle == jtag_req_toggle);
            @(posedge clk);
        end
    endtask

    logic [63:0] value;

    initial begin
        rst_n = 1'b0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        cpu_write_enable = 1'b1;
        mem_addr = 14'd0;
        mem_wdata = 64'd0;
        mem_wstrb = 8'd0;
        jtag_index = 11'd0;
        jtag_write = 1'b0;
        jtag_trace_read = 1'b0;
        jtag_wdata = 64'd0;
        jtag_req_toggle = 1'b0;
        trace_valid = 1'b0;
        trace_freeze = 1'b0;
        trace_pc = 64'd0;
        trace_rd_write = 1'b0;
        trace_rd = 5'd0;
        trace_wdata = 64'd0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        cpu_write64(14'h0000, 64'h0123_4567_89ab_cdef, 8'hff);
        cpu_write_enable = 1'b0;
        cpu_write64(14'h0000, 64'hffff_ffff_ffff_ffff, 8'hff);
        cpu_read64(14'h0000, value);
        if (value !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "CPU write escaped the debug-trigger gate");
        cpu_write_enable = 1'b1;
        cpu_write64(14'h0000, 64'h0000_0000_0000_005a, 8'h01);
        cpu_read64(14'h0000, value);
        if (value !== 64'h0123_4567_89ab_cd5a)
            $fatal(1, "CPU byte-write/readback mismatch");

        jtag_access(11'd1024, 1'b1, 1'b0,
                    64'hdead_beef_cafe_f00d);
        cpu_read64(14'h2000, value);
        if (value !== 64'hdead_beef_cafe_f00d)
            $fatal(1, "JTAG-write/CPU-read mismatch");

        cpu_write64(14'h3ff0, 64'h4f52_5636_5354_5542, 8'hff);
        cpu_write64(14'h3ff8, 64'h0000_0020_0001_0004, 8'hff);
        jtag_access(11'd2046, 1'b0, 1'b0, 64'd0);
        if (jtag_rdata !== 64'h4f52_5636_5354_5542)
            $fatal(1, "CPU-write/JTAG-read descriptor mismatch");
        jtag_access(11'd2047, 1'b0, 1'b0, 64'd0);
        if (jtag_rdata !== 64'h0000_0020_0001_0004)
            $fatal(1, "JTAG descriptor metadata mismatch");

        @(negedge clk);
        trace_valid = 1'b1;
        trace_pc = 64'hffff_ffff_803d_22e4;
        trace_rd_write = 1'b1;
        trace_rd = 5'd10;
        trace_wdata = -64'd14;
        @(posedge clk);
        @(negedge clk);
        trace_valid = 1'b0;

        jtag_access(11'd0, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== {32'h803d_22e4, 1'b1, 5'd10,
                            26'h3ff_fff2})
            $fatal(1, "passive retire trace record mismatch");
        jtag_access(11'd256, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd1)
            $fatal(1, "passive retire trace count mismatch");
        jtag_access(11'd257, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata[7:0] !== 8'd1)
            $fatal(1, "passive retire trace pointer mismatch");

        $display("PASS: FPGA 16 KiB executable debug stub BRAM");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "timeout in FPGA debug stub test");
    end

endmodule
