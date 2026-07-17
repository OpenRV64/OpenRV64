`timescale 1ns/1ps

module tb_plic;

    localparam logic [63:0] PRIORITY0_ADDR = 64'h0000;
    localparam logic [63:0] PRIORITY1_ADDR = 64'h0004;
    localparam logic [63:0] PRIORITY2_ADDR = 64'h0008;
    localparam logic [63:0] PRIORITY3_ADDR = 64'h000c;
    localparam logic [63:0] PRIORITY32_ADDR = 64'h0080;
    localparam logic [63:0] PENDING_ADDR = 64'h1000;
    localparam logic [63:0] PENDING_WORD1_ADDR = 64'h1004;
    localparam logic [63:0] ENABLE0_ADDR = 64'h2000;
    localparam logic [63:0] ENABLE0_WORD1_ADDR = 64'h2004;
    localparam logic [63:0] ENABLE1_ADDR = 64'h2080;
    localparam logic [63:0] THRESHOLD0_ADDR = 64'h20_0000;
    localparam logic [63:0] CLAIM0_ADDR = 64'h20_0004;
    localparam logic [63:0] THRESHOLD1_ADDR = 64'h20_1000;
    localparam logic [63:0] CLAIM1_ADDR = 64'h20_1004;

    logic        clk;
    logic        rst_n;
    logic [39:0] irq_sources;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic [1:0]  meip;

    openrv64_plic #(
        .NUM_HARTS(2),
        .NUM_SOURCES(40),
        .PRIORITY_WIDTH(3)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_sources_i(irq_sources),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .meip_o(meip)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_read32;
        input  logic [63:0] address;
        output logic [31:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            mem_wdata = 64'h0000_0000_0000_0000;
            mem_wstrb = 8'h00;
            #1;
            if (!mem_ready) begin
                $fatal(1, "PLIC did not accept read at %016x", address);
            end
            data = address[2] ? mem_rdata[63:32] : mem_rdata[31:0];
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0000_0000_0000_0000;
        end
    endtask

    task automatic bus_write32;
        input logic [63:0] address;
        input logic [31:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = address[2] ? {data, 32'h0000_0000} :
                                          {32'h0000_0000, data};
            mem_wstrb = address[2] ? 8'hf0 : 8'h0f;
            #1;
            if (!mem_ready) begin
                $fatal(1, "PLIC did not accept write at %016x", address);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'h0000_0000_0000_0000;
            mem_wdata = 64'h0000_0000_0000_0000;
            mem_wstrb = 8'h00;
        end
    endtask

    task automatic idle_cycle;
        begin
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic expect_read32;
        input logic [63:0] address;
        input logic [31:0] expected;
        input [8*48-1:0] label;
        logic [31:0] actual;
        begin
            bus_read32(address, actual);
            if (actual !== expected) begin
                $fatal(1, "%0s: read %08x, expected %08x",
                       label, actual, expected);
            end
        end
    endtask

    task automatic expect_meip;
        input logic [1:0] expected;
        input [8*48-1:0] label;
        begin
            #1;
            if (meip !== expected) begin
                $fatal(1,
                       "%0s: meip=%02b/%02b pending=%02x priorities=%06x enables=%04x thresholds=%02x selected=%016x",
                       label, meip, expected, dut.pending_q, dut.priority_q,
                       dut.enable_q, dut.threshold_q, dut.selected_id);
            end
        end
    endtask

    task automatic expect_claim;
        input logic [63:0] address;
        input logic [31:0] expected;
        input [8*48-1:0] label;
        logic [31:0] actual;
        begin
            bus_read32(address, actual);
            if (actual !== expected) begin
                $fatal(1, "%0s: claimed %0d, expected %0d",
                       label, actual, expected);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        irq_sources = 40'h0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0000_0000_0000_0000;
        mem_wdata = 64'h0000_0000_0000_0000;
        mem_wstrb = 8'h00;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_meip(2'b00, "reset interrupt outputs");
        expect_read32(PRIORITY0_ADDR, 32'h0, "reserved source zero priority");
        expect_read32(PRIORITY1_ADDR, 32'h0, "reset source priority");
        expect_read32(PENDING_ADDR, 32'h0, "reset pending bits");
        expect_read32(ENABLE0_ADDR, 32'h0, "reset enables");
        expect_read32(THRESHOLD0_ADDR, 32'h0, "reset threshold");
        expect_claim(CLAIM0_ADDR, 32'h0, "empty claim");

        // The SoC decoder owns the global window; the PLIC itself receives
        // local offsets and acknowledges reserved ones with zero data.
        expect_read32(64'h1800, 32'h0, "reserved local offset");

        // Source ID zero is hardwired absent. Context zero enables IDs 1-3;
        // context one enables IDs 2-3.
        bus_write32(PRIORITY0_ADDR, 32'h7);
        expect_read32(PRIORITY0_ADDR, 32'h0, "source zero remains reserved");
        bus_write32(PRIORITY1_ADDR, 32'd3);
        bus_write32(PRIORITY2_ADDR, 32'd5);
        bus_write32(PRIORITY3_ADDR, 32'd5);
        expect_read32(PRIORITY1_ADDR, 32'd3, "upper bus lane priority");
        expect_read32(PRIORITY2_ADDR, 32'd5, "lower bus lane priority");
        expect_read32(PRIORITY3_ADDR, 32'd5, "second upper lane priority");

        bus_write32(ENABLE0_ADDR, 32'h0000_000f);
        bus_write32(ENABLE1_ADDR, 32'h0000_000c);
        expect_read32(ENABLE0_ADDR, 32'h0000_000e,
                      "source zero enable is hardwired off");
        expect_read32(ENABLE1_ADDR, 32'h0000_000c,
                      "independent hart enables");
        bus_write32(THRESHOLD1_ADDR, 32'd5);

        // Assert source IDs 1, 2 and 3. Context zero is notified; context one
        // is blocked because a priority must be strictly above its threshold.
        @(negedge clk);
        irq_sources = 40'h0000_0000_07;
        idle_cycle();
        expect_meip(2'b01, "threshold blocks context one");
        expect_read32(PENDING_ADDR, 32'h0000_000e,
                      "level inputs become pending");

        // Reading the lower threshold lane must not trigger the claim side
        // effect in the upper lane of the same 64-bit bus word.
        expect_read32(THRESHOLD0_ADDR, 32'd0,
                      "threshold read is not a claim");
        expect_read32(PENDING_ADDR, 32'h0000_000e,
                      "threshold read preserves pending bits");

        // IDs 2 and 3 tie at priority 5, so the lower ID wins.
        expect_claim(CLAIM0_ADDR, 32'd2, "priority tie uses lowest ID");
        expect_read32(PENDING_ADDR, 32'h0000_000a,
                      "claim atomically clears source two");
        expect_meip(2'b01, "next source remains visible");

        bus_write32(THRESHOLD1_ADDR, 32'd4);
        expect_meip(2'b11, "lower threshold enables context one");
        expect_claim(CLAIM1_ADDR, 32'd3, "context one claims source three");
        expect_read32(PENDING_ADDR, 32'h0000_0002,
                      "independent context claim clears source three");
        expect_meip(2'b01, "only source one remains eligible");

        // Remove sources 2 and 3, complete them, then claim source 1 while its
        // level remains asserted. It must not re-pend before completion.
        irq_sources = 40'h0000_0000_01;
        bus_write32(CLAIM0_ADDR, 32'd2);
        bus_write32(CLAIM1_ADDR, 32'd3);
        expect_claim(CLAIM0_ADDR, 32'd1, "claim source one");
        expect_read32(PENDING_ADDR, 32'h0,
                      "claimed active level waits for completion");
        idle_cycle();
        idle_cycle();
        expect_read32(PENDING_ADDR, 32'h0,
                      "in-service source cannot re-pend");

        bus_write32(CLAIM0_ADDR, 32'd1);
        idle_cycle();
        expect_read32(PENDING_ADDR, 32'h0000_0002,
                      "active level re-pends after completion");
        expect_meip(2'b01, "re-pended source notifies context zero");

        irq_sources = 40'h0;
        expect_claim(CLAIM0_ADDR, 32'd1, "claim re-pended source one");
        bus_write32(CLAIM0_ADDR, 32'd1);
        expect_meip(2'b00, "deasserted completed source stays idle");

        // Priority equal to threshold is blocked. The same pending source can
        // still notify a context with a lower threshold.
        bus_write32(THRESHOLD0_ADDR, 32'd5);
        irq_sources = 40'h0000_0000_02;
        idle_cycle();
        expect_read32(PENDING_ADDR, 32'h0000_0004,
                      "source two pending for threshold test");
        expect_meip(2'b10, "per-context threshold comparison");

        // Pending registers are read-only.
        bus_write32(PENDING_ADDR, 32'h0);
        expect_read32(PENDING_ADDR, 32'h0000_0004,
                      "pending write is ignored");

        bus_write32(PRIORITY2_ADDR, 32'd6);
        expect_meip(2'b11, "priority above both thresholds");
        expect_claim(CLAIM0_ADDR, 32'd2, "claim reprioritized source");
        expect_meip(2'b00, "one claim removes global pending request");
        irq_sources = 40'h0;
        bus_write32(CLAIM0_ADDR, 32'd2);
        expect_claim(CLAIM0_ADDR, 32'd0, "claim with no eligible source");

        // Exercise the architectural bit packing across a 32-bit word
        // boundary. Source ID 32 occupies bit zero of pending/enable word 1.
        bus_write32(PRIORITY32_ADDR, 32'd7);
        bus_write32(ENABLE0_WORD1_ADDR, 32'h0000_0001);
        irq_sources[31] = 1'b1;
        idle_cycle();
        expect_read32(PENDING_WORD1_ADDR, 32'h0000_0001,
                      "source 32 pending word placement");
        expect_read32(ENABLE0_WORD1_ADDR, 32'h0000_0001,
                      "source 32 enable word placement");
        expect_meip(2'b01, "source 32 notifies context zero");
        expect_claim(CLAIM0_ADDR, 32'd32, "claim source 32");
        irq_sources[31] = 1'b0;
        bus_write32(CLAIM0_ADDR, 32'd32);

        @(negedge clk);
        rst_n = 1'b0;
        #1;
        expect_meip(2'b00, "asynchronous reset clears notifications");
        rst_n = 1'b1;
        expect_read32(PRIORITY2_ADDR, 32'h0, "reset clears priorities");
        expect_read32(ENABLE0_ADDR, 32'h0, "reset clears enables");

        $display("PASS: PLIC priorities, contexts, claim/complete, and gateways");
        $finish;
    end

    initial begin
        repeat (512) @(posedge clk);
        $fatal(1, "timeout in PLIC test");
    end

endmodule
