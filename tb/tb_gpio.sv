`timescale 1ns/1ps

module tb_gpio;

    logic       clk;
    logic       rst_n;
    logic [7:0] gpio_in;
    logic [7:0] gpio_out;
    logic       irq;
    logic       mem_valid;
    logic       mem_ready;
    logic       mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    openrv64_gpio #(
        .NUM_PINS(8),
        .ENABLE_INTERRUPTS(1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .gpio_in_i(gpio_in),
        .gpio_out_o(gpio_out),
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
                $fatal(1, "GPIO did not accept write at %016x", address);
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
                $fatal(1, "GPIO did not accept read at %016x", address);
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

    task automatic settle_inputs;
        begin
            repeat (3) @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        gpio_in = 8'h00;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_read(64'h08, 64'h0, "reset output");
        expect_read(64'h10, 64'h0, "reset interrupt enables");
        if (gpio_out !== 8'h00 || irq) begin
            $fatal(1, "GPIO outputs or interrupt active after reset");
        end

        bus_write(64'h08, 64'h0000_0000_0000_00a5, 8'h01);
        expect_read(64'h08, 64'h0000_0000_0000_00a5,
                    "registered output and byte strobe");
        if (gpio_out !== 8'ha5) begin
            $fatal(1, "GPIO output pins did not follow output register");
        end

        gpio_in = 8'h5a;
        settle_inputs();
        expect_read(64'h00, 64'h0000_0000_0000_005a,
                    "synchronized GPIO input");
        expect_read(64'h30, 64'h0, "reserved local offset");

        // Pin zero: active-high level interrupt. It follows the synchronized
        // input and therefore needs no W1C operation.
        gpio_in = 8'h00;
        settle_inputs();
        bus_write(64'h28, 64'hff, 8'h01);
        bus_write(64'h20, 64'h01, 8'h01);
        bus_write(64'h18, 64'h00, 8'h01);
        bus_write(64'h10, 64'h01, 8'h01);
        gpio_in[0] = 1'b1;
        settle_inputs();
        if (!irq) begin
            $fatal(1, "active-high level interrupt did not assert");
        end
        expect_read(64'h28, 64'h01, "level interrupt pending source");
        gpio_in[0] = 1'b0;
        settle_inputs();
        if (irq) begin
            $fatal(1, "level interrupt did not follow deasserted input");
        end

        // A transition seen while a pin is in level mode must not become a
        // stale edge interrupt if software later changes that pin's type.
        gpio_in[3] = 1'b1;
        settle_inputs();
        gpio_in[3] = 1'b0;
        settle_inputs();
        bus_write(64'h20, 64'h09, 8'h01);
        bus_write(64'h18, 64'h08, 8'h01);
        bus_write(64'h10, 64'h09, 8'h01);
        if (irq) begin
            $fatal(1, "level-mode transition leaked into edge pending state");
        end

        // Pin one: rising edge remains pending after the input returns low.
        bus_write(64'h20, 64'h03, 8'h01);
        bus_write(64'h18, 64'h02, 8'h01);
        bus_write(64'h10, 64'h03, 8'h01);
        gpio_in[1] = 1'b1;
        settle_inputs();
        gpio_in[1] = 1'b0;
        settle_inputs();
        if (!irq) begin
            $fatal(1, "rising-edge interrupt did not remain latched");
        end
        bus_write(64'h28, 64'h02, 8'h01);
        if (irq) begin
            $fatal(1, "W1C did not clear rising-edge interrupt");
        end

        // Pin two: falling edge selection.
        gpio_in[2] = 1'b1;
        settle_inputs();
        bus_write(64'h18, 64'h06, 8'h01);
        bus_write(64'h20, 64'h03, 8'h01);
        bus_write(64'h10, 64'h07, 8'h01);
        gpio_in[2] = 1'b0;
        settle_inputs();
        if (!irq) begin
            $fatal(1, "falling-edge interrupt did not assert");
        end
        expect_read(64'h28, 64'h04, "falling-edge pending source");
        bus_write(64'h28, 64'h04, 8'h01);
        if (irq) begin
            $fatal(1, "W1C did not clear falling-edge interrupt");
        end

        $display("tb_gpio: PASS");
        $finish;
    end

endmodule
