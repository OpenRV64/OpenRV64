`timescale 1ns/1ps

module tb_spi;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic card_present = 1'b0;
    wire spi_clk;
    wire spi_mosi;
    wire spi_miso = spi_mosi;
    wire spi_cs_n;

    logic mem_valid = 1'b0;
    wire mem_ready;
    logic mem_write = 1'b0;
    logic [63:0] mem_addr = 64'd0;
    logic [63:0] mem_wdata = 64'd0;
    logic [7:0] mem_wstrb = 8'hff;
    wire [63:0] mem_rdata;

    openrv64_spi #(
        .INIT_HALF_PERIOD_CYCLES(3),
        .FAST_HALF_PERIOD_CYCLES(1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .card_present_i(card_present),
        .spi_clk_o(spi_clk),
        .spi_mosi_o(spi_mosi),
        .spi_miso_i(spi_miso),
        .spi_cs_n_o(spi_cs_n),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata)
    );

    task automatic bus_write(input [63:0] address, input [63:0] data);
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = 8'hff;
            @(posedge clk);
            if (!mem_ready)
                $fatal(1, "SPI write was not acknowledged");
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
        end
    endtask

    task automatic bus_read(input [63:0] address, output [63:0] data);
        integer cycles;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            cycles = 0;
            do begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 8)
                    $fatal(1, "SPI read was not acknowledged");
            end while (!mem_ready);
            data = mem_rdata;
            @(negedge clk);
            mem_valid = 1'b0;
        end
    endtask

    task automatic wait_done(output integer elapsed_cycles);
        begin
            elapsed_cycles = 0;
            while (dut.busy_q) begin
                @(posedge clk);
                elapsed_cycles = elapsed_cycles + 1;
                if (elapsed_cycles > 20000)
                    $fatal(1, "SPI transfer timed out");
            end
            if (!dut.done_q)
                $fatal(1, "SPI transfer completed without DONE");
        end
    endtask

    reg [63:0] value;
    integer command_cycles;
    integer sector_cycles;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        card_present = 1'b1;
        repeat (3) @(posedge clk);

        bus_read(64'h08, value);
        if (!value[2] || value[1:0] != 2'b00)
            $fatal(1, "bad reset/card status: %016x", value);
        if (!spi_cs_n || spi_clk || !spi_mosi)
            $fatal(1, "SPI pins are not idle-high/clock-low after reset");

        bus_write(64'h00, 64'h1);
        bus_write(64'h18, 64'h0123_4567_89ab_cdef);
        bus_write(64'h20, 64'hfedc_ba98_7654_3210);
        bus_write(64'h10, 64'd16);
        wait_done(command_cycles);
        bus_read(64'h28, value);
        if (value !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "RX low loopback mismatch: %016x", value);
        bus_read(64'h30, value);
        if (value !== 64'hfedc_ba98_7654_3210)
            $fatal(1, "RX high loopback mismatch: %016x", value);

        bus_write(64'h08, 64'h2);
        bus_write(64'h00, 64'h3);
        bus_write(64'h10, 64'd512);
        wait_done(sector_cycles);
        bus_read(64'h100, value);
        if (value !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "sector word 0 mismatch: %016x", value);
        bus_read(64'h108, value);
        if (value !== 64'hfedc_ba98_7654_3210)
            $fatal(1, "sector word 1 mismatch: %016x", value);
        bus_read(64'h110, value);
        if (value !== 64'hffff_ffff_ffff_ffff)
            $fatal(1, "sector implicit-FF word mismatch: %016x", value);
        bus_read(64'h08, value);
        if (value[17:8] != 10'd512 || value[24] || !value[1])
            $fatal(1, "bad sector completion status: %016x", value);

        bus_write(64'h10, 64'd0);
        bus_read(64'h08, value);
        if (!value[24])
            $fatal(1, "zero-length transfer did not set ERROR");
        bus_write(64'h08, 64'h0100_0000);
        bus_read(64'h08, value);
        if (value[24])
            $fatal(1, "ERROR did not clear");

        bus_write(64'h00, 64'h0);
        if (!spi_cs_n)
            $fatal(1, "CONTROL did not release chip select");

        $display("tb_spi: PASS command_cycles=%0d sector_cycles=%0d",
                 command_cycles, sector_cycles);
        $finish;
    end
endmodule
