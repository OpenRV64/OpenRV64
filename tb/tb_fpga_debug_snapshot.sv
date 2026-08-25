`timescale 1ns/1ps

module tb_fpga_debug_snapshot;
    logic clk;
    logic rst_n;

    logic [32:0] irq_sources;
    logic plic_valid;
    logic plic_ready;
    logic plic_write;
    logic [63:0] plic_addr;
    logic [63:0] plic_wdata;
    logic [7:0] plic_wstrb;
    logic [63:0] plic_rdata;
    logic [0:0] meip;
    logic [0:0] seip;

    logic snapshot_valid;
    logic snapshot_ready;
    logic snapshot_write;
    logic [11:0] snapshot_addr;
    logic [63:0] snapshot_wdata;
    logic [7:0] snapshot_wstrb;
    logic [63:0] snapshot_rdata;
    logic [8:0] jtag_index;
    logic jtag_req_toggle;
    logic jtag_ack_toggle;
    logic [63:0] jtag_data;
    logic jtag_resume_toggle;
    logic trigger_ack;
    logic resume_pending;

    openrv64_plic #(
        .NUM_HARTS(1),
        .NUM_SOURCES(33),
        .PRIORITY_WIDTH(3),
        .M_CONTEXT_ENABLE(1)
    ) u_plic (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_sources_i(irq_sources),
        .mem_valid_i(plic_valid),
        .mem_ready_o(plic_ready),
        .mem_write_i(plic_write),
        .mem_addr_i(plic_addr),
        .mem_wdata_i(plic_wdata),
        .mem_wstrb_i(plic_wstrb),
        .mem_rdata_o(plic_rdata),
        .meip_o(meip),
        .seip_o(seip)
    );

    openrv64_soc_debug_snapshot_mem u_snapshot (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mem_valid_i(snapshot_valid),
        .mem_ready_o(snapshot_ready),
        .mem_write_i(snapshot_write),
        .mem_addr_i(snapshot_addr),
        .mem_wdata_i(snapshot_wdata),
        .mem_wstrb_i(snapshot_wstrb),
        .mem_rdata_o(snapshot_rdata),
        .jtag_read_index_i(jtag_index),
        .jtag_read_req_toggle_i(jtag_req_toggle),
        .jtag_read_ack_toggle_o(jtag_ack_toggle),
        .jtag_read_data_o(jtag_data),
        .jtag_resume_toggle_i(jtag_resume_toggle),
        .trigger_active_i(irq_sources[31]),
        .trigger_ack_o(trigger_ack),
        .resume_pending_o(resume_pending)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic plic_write32(
        input logic [63:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            plic_valid = 1'b1;
            plic_write = 1'b1;
            plic_addr = address;
            plic_wdata = address[2] ? {data, 32'd0} : {32'd0, data};
            plic_wstrb = address[2] ? 8'hf0 : 8'h0f;
            #1;
            if (!plic_ready)
                $fatal(1, "PLIC write did not complete");
            @(posedge clk);
            @(negedge clk);
            plic_valid = 1'b0;
            plic_write = 1'b0;
        end
    endtask

    task automatic plic_read32(
        input logic [63:0] address,
        output logic [31:0] data
    );
        begin
            @(negedge clk);
            plic_valid = 1'b1;
            plic_write = 1'b0;
            plic_addr = address;
            #1;
            if (!plic_ready)
                $fatal(1, "PLIC read did not complete");
            data = address[2] ? plic_rdata[63:32] : plic_rdata[31:0];
            @(posedge clk);
            @(negedge clk);
            plic_valid = 1'b0;
        end
    endtask

    task automatic snapshot_write64(
        input logic [11:0] address,
        input logic [63:0] data
    );
        begin
            @(negedge clk);
            snapshot_valid = 1'b1;
            snapshot_write = 1'b1;
            snapshot_addr = address;
            snapshot_wdata = data;
            snapshot_wstrb = 8'hff;
            while (!snapshot_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            snapshot_valid = 1'b0;
            snapshot_write = 1'b0;
        end
    endtask

    task automatic snapshot_read64(
        input logic [11:0] address,
        output logic [63:0] data
    );
        begin
            @(negedge clk);
            snapshot_valid = 1'b1;
            snapshot_write = 1'b0;
            snapshot_addr = address;
            snapshot_wstrb = 8'h00;
            while (!snapshot_ready)
                @(negedge clk);
            data = snapshot_rdata;
            @(posedge clk);
            @(negedge clk);
            snapshot_valid = 1'b0;
        end
    endtask

    logic [31:0] claim;
    logic [63:0] status;

    initial begin
        rst_n = 1'b0;
        irq_sources = 33'd0;
        plic_valid = 1'b0;
        plic_write = 1'b0;
        plic_addr = 64'd0;
        plic_wdata = 64'd0;
        plic_wstrb = 8'd0;
        snapshot_valid = 1'b0;
        snapshot_write = 1'b0;
        snapshot_addr = 12'd0;
        snapshot_wdata = 64'd0;
        snapshot_wstrb = 8'd0;
        jtag_index = 9'd0;
        jtag_req_toggle = 1'b0;
        jtag_resume_toggle = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // External interrupt 29 is PLIC source ID 32. With machine contexts
        // enabled, context zero is M mode and context one is S mode.
        plic_write32(64'h0000_0080, 32'd1);
        plic_write32(64'h0000_2004, 32'h0000_0001);
        plic_write32(64'h0020_0000, 32'd0);

        irq_sources[31] = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (meip !== 1'b1 || seip !== 1'b0)
            $fatal(1, "source 32 was not routed only to the M context");

        plic_read32(64'h0020_0004, claim);
        if (claim != 32)
            $fatal(1, "M-context claim returned %0d, expected 32", claim);
        if (meip !== 1'b0)
            $fatal(1, "claim did not clear MEIP");

        // Model the OpenSBI callback writing its saved trap frame.
        snapshot_write64(12'h028, 64'h0123_4567_89ab_cdef);
        snapshot_read64(12'h028, status);
        if (status !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "CPU snapshot readback mismatch");

        jtag_index = 9'd5;
        jtag_req_toggle = 1'b1;
        wait (jtag_ack_toggle == 1'b1);
        #1;
        if (jtag_data !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "JTAG snapshot readback mismatch");

        jtag_resume_toggle = 1'b1;
        wait (resume_pending);
        snapshot_read64(12'hff0, status);
        if (status[1:0] !== 2'b11)
            $fatal(1, "snapshot status omitted trigger/resume state");

        snapshot_write64(12'hff8, 64'd1);
        if (resume_pending)
            $fatal(1, "handler acknowledgement did not clear resume");
        irq_sources[31] = 1'b0;
        plic_write32(64'h0020_0004, 32'd32);
        repeat (2) @(posedge clk);
        if (meip || seip || u_plic.pending_q[31] ||
            u_plic.in_service_q[31])
            $fatal(1, "debug source did not quiesce after completion");

        $display("PASS: FPGA debug PLIC source 32 and snapshot BRAM");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "timeout in FPGA debug snapshot test");
    end

endmodule
