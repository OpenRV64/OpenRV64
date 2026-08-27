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
    logic [15:0] jtag_index;
    logic jtag_write;
    logic jtag_trace_read;
    logic jtag_wave_burst;
    logic [63:0] jtag_wdata;
    logic jtag_req_toggle;
    logic jtag_ack_toggle;
    logic [63:0] jtag_rdata;
    logic [255:0] jtag_wave_rdata;
    logic trace_valid;
    logic trace_freeze;
    logic [63:0] trace_pc;
    logic [31:0] trace_instr;
    logic [63:0] trace_next_pc;
    logic trace_rd_write;
    logic [63:0] trace_wdata;
    logic fetch_trace_valid;
    logic [63:0] fetch_trace_pc;
    logic [63:0] fetch_trace_data;
    logic load_trace_valid;
    logic [63:0] load_trace_pc;
    logic [63:0] load_trace_addr;
    logic [63:0] load_trace_paddr;
    logic [4:0] load_trace_rd;
    logic [63:0] load_trace_data;
    logic store_trace_valid;
    logic [63:0] store_trace_pc;
    logic [63:0] store_trace_addr;
    logic [63:0] store_trace_paddr;
    logic [63:0] store_trace_data;
    logic [7:0] store_trace_wstrb;
    logic wave_trace_trigger;
    logic [255:0] wave_trace_data;

    openrv64_soc_debug_stub_mem #(
        .WAVE_POST_TRIGGER_CYCLES(4)
    ) dut (
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
        .jtag_wave_burst_i(jtag_wave_burst),
        .jtag_wdata_i(jtag_wdata),
        .jtag_req_toggle_i(jtag_req_toggle),
        .jtag_ack_toggle_o(jtag_ack_toggle),
        .jtag_rdata_o(jtag_rdata),
        .jtag_wave_rdata_o(jtag_wave_rdata),
        .trace_valid_i(trace_valid),
        .trace_freeze_i(trace_freeze),
        .trace_pc_i(trace_pc),
        .trace_instr_i(trace_instr),
        .trace_next_pc_i(trace_next_pc),
        .trace_rd_write_i(trace_rd_write),
        .trace_wdata_i(trace_wdata),
        .fetch_trace_valid_i(fetch_trace_valid),
        .fetch_trace_pc_i(fetch_trace_pc),
        .fetch_trace_data_i(fetch_trace_data),
        .load_trace_valid_i(load_trace_valid),
        .load_trace_pc_i(load_trace_pc),
        .load_trace_addr_i(load_trace_addr),
        .load_trace_paddr_i(load_trace_paddr),
        .load_trace_rd_i(load_trace_rd),
        .load_trace_data_i(load_trace_data),
        .store_trace_valid_i(store_trace_valid),
        .store_trace_pc_i(store_trace_pc),
        .store_trace_addr_i(store_trace_addr),
        .store_trace_paddr_i(store_trace_paddr),
        .store_trace_data_i(store_trace_data),
        .store_trace_wstrb_i(store_trace_wstrb),
        .wave_trace_trigger_i(wave_trace_trigger),
        .wave_trace_data_i(wave_trace_data)
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
        input logic [15:0] index,
        input logic write_access,
        input logic trace_access,
        input logic [63:0] data
    );
        begin
            jtag_index = index;
            jtag_write = write_access;
            jtag_trace_read = trace_access;
            jtag_wave_burst = 1'b0;
            jtag_wdata = data;
            jtag_req_toggle = !jtag_req_toggle;
            wait (jtag_ack_toggle == jtag_req_toggle);
            @(posedge clk);
        end
    endtask

    task automatic jtag_wave_access(input logic [15:0] index);
        begin
            jtag_index = index;
            jtag_write = 1'b0;
            jtag_trace_read = 1'b1;
            jtag_wave_burst = 1'b1;
            jtag_wdata = 64'd0;
            jtag_req_toggle = !jtag_req_toggle;
            wait (jtag_ack_toggle == jtag_req_toggle);
            @(posedge clk);
            jtag_wave_burst = 1'b0;
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
        jtag_index = 16'd0;
        jtag_write = 1'b0;
        jtag_trace_read = 1'b0;
        jtag_wave_burst = 1'b0;
        jtag_wdata = 64'd0;
        jtag_req_toggle = 1'b0;
        trace_valid = 1'b0;
        trace_freeze = 1'b0;
        trace_pc = 64'd0;
        trace_instr = 32'd0;
        trace_next_pc = 64'd0;
        trace_rd_write = 1'b0;
        trace_wdata = 64'd0;
        fetch_trace_valid = 1'b0;
        fetch_trace_pc = 64'd0;
        fetch_trace_data = 64'd0;
        load_trace_valid = 1'b0;
        load_trace_pc = 64'd0;
        load_trace_addr = 64'd0;
        load_trace_paddr = 64'd0;
        load_trace_rd = 5'd0;
        load_trace_data = 64'd0;
        store_trace_valid = 1'b0;
        store_trace_pc = 64'd0;
        store_trace_addr = 64'd0;
        store_trace_paddr = 64'd0;
        store_trace_data = 64'd0;
        store_trace_wstrb = 8'd0;
        wave_trace_trigger = 1'b0;
        wave_trace_data = 256'd0;

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
        jtag_access(16'd2046, 1'b0, 1'b0, 64'd0);
        if (jtag_rdata !== 64'h4f52_5636_5354_5542)
            $fatal(1, "CPU-write/JTAG-read descriptor mismatch");
        jtag_access(16'd2047, 1'b0, 1'b0, 64'd0);
        if (jtag_rdata !== 64'h0000_0020_0001_0004)
            $fatal(1, "JTAG descriptor metadata mismatch");

        @(negedge clk);
        trace_valid = 1'b1;
        trace_pc = 64'hffff_ffff_803d_22e4;
        trace_instr = 32'h0204_3583;
        trace_next_pc = 64'hffff_ffff_803d_22e8;
        trace_rd_write = 1'b1;
        trace_wdata = 64'h0000_0000_0c30_0000;
        @(posedge clk);
        @(negedge clk);
        trace_valid = 1'b0;

        jtag_access(16'd0, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== {32'h803d_22e4, 32'h0204_3583})
            $fatal(1, "passive retire trace record mismatch");
        jtag_access(16'd1, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'h0000_0000_0c30_0000)
            $fatal(1, "passive retire destination mismatch");

        @(negedge clk);
        trace_valid = 1'b1;
        trace_pc = 64'hffff_ffff_803d_22e8;
        trace_instr = 32'hfe04_1ce3;
        trace_next_pc = 64'hffff_ffff_803d_22e0;
        trace_rd_write = 1'b0;
        trace_wdata = 64'hffff_ffff_ffff_ffff;
        @(posedge clk);
        @(negedge clk);
        trace_valid = 1'b0;

        jtag_access(16'd2, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== {32'h803d_22e9, 32'hfe04_1ce3})
            $fatal(1, "taken-branch trace marker mismatch");
        jtag_access(16'd3, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd0)
            $fatal(1, "no-destination retire trace was not zero");
        jtag_access(16'd16384, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd2)
            $fatal(1, "passive retire trace count mismatch");
        jtag_access(16'd16385, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata[12:0] !== 13'd2)
            $fatal(1, "passive retire trace pointer mismatch");

        @(negedge clk);
        load_trace_valid = 1'b1;
        load_trace_pc = 64'hffff_ffff_803e_5260;
        load_trace_addr = 64'hffff_ffff_8062_f4a8;
        load_trace_paddr = 64'h0000_0000_8abc_d120;
        load_trace_rd = 5'd11;
        load_trace_data = 64'h0000_0000_0c30_0000;
        @(posedge clk);
        @(negedge clk);
        load_trace_valid = 1'b0;

        jtag_access(16'd16386, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== {load_trace_paddr[31:0],
                            load_trace_addr[31:0]})
            $fatal(1, "load trace VA/PA metadata mismatch");
        jtag_access(16'd16387, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'h0000_0000_0c30_0000)
            $fatal(1, "load trace data mismatch");
        jtag_access(16'd24578, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd1)
            $fatal(1, "load trace count mismatch");
        jtag_access(16'd24579, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata[11:0] !== 12'd1)
            $fatal(1, "load trace pointer mismatch");

        @(negedge clk);
        store_trace_valid = 1'b1;
        store_trace_pc = 64'hffff_ffff_803e_3a54;
        store_trace_addr = 64'hffff_ffff_8063_7c88;
        store_trace_paddr = 64'h0000_0000_8123_4c88;
        store_trace_data = 64'h0000_0000_9000_0000;
        store_trace_wstrb = 8'hff;
        @(posedge clk);
        @(negedge clk);
        store_trace_valid = 1'b0;

        jtag_access(16'd24580, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== {store_trace_paddr[31:0],
                            store_trace_addr[31:0]})
            $fatal(1, "store trace VA/PA metadata mismatch");
        jtag_access(16'd24581, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'h0000_0000_9000_0000)
            $fatal(1, "store trace data mismatch");
        jtag_access(16'd32772, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd1)
            $fatal(1, "store trace count mismatch");
        jtag_access(16'd32773, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata[11:0] !== 12'd1)
            $fatal(1, "store trace pointer mismatch");

        @(negedge clk);
        fetch_trace_valid = 1'b1;
        fetch_trace_pc = 64'hffff_ffff_8011_c4f0;
        fetch_trace_data = 64'hf9df_f06f_fff0_0c93;
        @(posedge clk);
        @(negedge clk);
        fetch_trace_valid = 1'b0;

        jtag_access(16'd32774, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== fetch_trace_pc)
            $fatal(1, "fetch trace virtual PC mismatch");
        jtag_access(16'd32775, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== fetch_trace_data)
            $fatal(1, "fetch trace response mismatch");
        jtag_access(16'd36870, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'd1)
            $fatal(1, "fetch trace count mismatch");
        jtag_access(16'd36871, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata[10:0] !== 11'd1)
            $fatal(1, "fetch trace pointer mismatch");

        // The waveform recorder runs continuously, wraps, records the trigger
        // sample, and then freezes after the requested number of post-trigger
        // cycles.  Exercise both an ordinary 64-bit bank read and the JTAG
        // four-bank burst used for physical readback.
        repeat (1024) @(posedge clk);
        @(negedge clk);
        wave_trace_data = {64'h4444_4444_4444_4444,
                           64'h3333_3333_3333_3333,
                           64'h2222_2222_2222_2222,
                           64'h1111_1111_1111_1111};
        wave_trace_trigger = 1'b1;
        @(posedge clk);
        @(negedge clk);
        wave_trace_trigger = 1'b0;
        repeat (4) begin
            wave_trace_data = wave_trace_data +
                {64'd1, 64'd1, 64'd1, 64'd1};
            @(posedge clk);
            @(negedge clk);
        end

        jtag_access(16'd40968, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata < 64'd1024)
            $fatal(1, "wave trace did not run long enough to wrap");
        jtag_access(16'd40969, 1'b0, 1'b1, 64'd0);
        if (!jtag_rdata[20] || !jtag_rdata[21])
            $fatal(1, "wave trace did not trigger and freeze");
        value = jtag_rdata[19:10];
        jtag_access(16'd36872 + 4 * value, 1'b0, 1'b1, 64'd0);
        if (jtag_rdata !== 64'h1111_1111_1111_1111)
            $fatal(1, "wave trace single-word trigger sample mismatch");
        jtag_wave_access(value[15:0]);
        if (jtag_wave_rdata !== {
                64'h4444_4444_4444_4444,
                64'h3333_3333_3333_3333,
                64'h2222_2222_2222_2222,
                64'h1111_1111_1111_1111})
            $fatal(1, "wave trace burst trigger sample mismatch");

        $display("PASS: FPGA executable debug stub and waveform BRAMs");
        $finish;
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1, "timeout in FPGA debug stub test");
    end

endmodule
