`timescale 1ns/1ps

module tb_timer;

    logic        clk;
    logic        rst_n;
    logic        irq;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    openrv64_timer #(
        .ENABLE_INTERRUPTS(1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_o(irq),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_write;
        input logic [63:0] address;
        input logic [63:0] data;
        input logic [7:0] strobe;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = strobe;
            #1;
            if (!mem_ready) begin
                $fatal(1, "timer did not accept write at %016x", address);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'h0;
            mem_wdata = 64'h0;
            mem_wstrb = 8'h00;
        end
    endtask

    task automatic bus_read;
        input  logic [63:0] address;
        output logic [63:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            mem_wdata = 64'h0;
            mem_wstrb = 8'h00;
            #1;
            if (!mem_ready) begin
                $fatal(1, "timer did not accept read at %016x", address);
            end
            data = mem_rdata;
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0;
        end
    endtask

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*48-1:0] label;
        logic [63:0] actual;
        begin
            bus_read(address, actual);
            if (actual !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, actual, expected);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_read(64'h00, 64'h0, "reset control");
        expect_read(64'h08, 64'h0, "reset divider");
        expect_read(64'h10, 64'h0, "reset reload");
        expect_read(64'h18, 64'h0, "reset value");
        expect_read(64'h20, 64'h0, "reset status");
        expect_read(64'h28, 64'h0, "reserved local offset");
        if (irq) begin
            $fatal(1, "timer interrupt active after reset");
        end

        // One-shot: divider=2 gives one decrement every three input clocks.
        bus_write(64'h08, 64'd2, 8'h0f);
        bus_write(64'h10, 64'd3, 8'hff);
        bus_write(64'h00, 64'h5, 8'h01);
        repeat (2) @(posedge clk);
        #1;
        if (dut.count_q !== 64'd3) begin
            $fatal(1, "divider decremented too early");
        end
        @(posedge clk);
        #1;
        if (dut.count_q !== 64'd2) begin
            $fatal(1, "divider did not decrement on third clock");
        end
        repeat (6) @(posedge clk);
        #1;
        if (!irq || dut.count_q !== 64'd0 || dut.enable_q !== 1'b0) begin
            $fatal(1, "one-shot expiry state is wrong");
        end
        expect_read(64'h20, 64'h1, "one-shot pending status");
        bus_write(64'h20, 64'h1, 8'h01);
        if (irq) begin
            $fatal(1, "timer W1C did not clear one-shot interrupt");
        end

        // Byte strobes apply to the divider and value registers.
        bus_write(64'h08, 64'h0000_0000_0000_12aa, 8'h01);
        expect_read(64'h08, 64'h0000_0000_0000_00aa,
                    "partial divider write");
        bus_write(64'h18, 64'h1122_3344_5566_7788, 8'h81);
        expect_read(64'h18, 64'h1100_0000_0000_0088,
                    "partial counter write");

        // Periodic mode reloads and can assert again after a W1C.
        bus_write(64'h08, 64'd0, 8'h0f);
        bus_write(64'h10, 64'd2, 8'hff);
        bus_write(64'h00, 64'h7, 8'h01);
        repeat (2) @(posedge clk);
        #1;
        if (!irq || dut.count_q !== 64'd2 || !dut.enable_q) begin
            $fatal(1, "periodic timer did not reload at expiry");
        end
        bus_write(64'h20, 64'h1, 8'h01);
        if (irq) begin
            $fatal(1, "periodic interrupt did not clear between expiries");
        end
        @(posedge clk);
        #1;
        if (!irq || dut.count_q !== 64'd2) begin
            $fatal(1, "periodic timer did not assert on next period");
        end

        // IRQ enable gates the output without destroying pending state.
        bus_write(64'h00, 64'h3, 8'h01);
        if (irq || !dut.irq_pending_q) begin
            $fatal(1, "interrupt enable did not gate pending timer IRQ");
        end
        bus_write(64'h00, 64'h0, 8'h01);
        bus_write(64'h20, 64'h1, 8'h01);

        $display("tb_timer: PASS");
        $finish;
    end

endmodule
