`timescale 1ns/1ps

module tb_emaclite;

    logic clk;
    logic tx_clk;
    logic rx_clk;
    logic rst_n;

    logic [7:0] tx_data;
    logic tx_valid;
    logic tx_error;
    logic [7:0] rx_data;
    logic rx_valid;
    logic rx_error;
    logic mdc;
    logic mdio_out;
    logic mdio_oe;
    wire mdio_in;
    logic phy_reset_n;
    logic irq;

    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;

    logic [7:0] frame [0:63];
    logic [7:0] tx_capture [0:127];
    integer tx_capture_count;
    logic [15:0] mdio_read_pattern;

    openrv64_emaclite #(
        .MDC_HALF_PERIOD_CYCLES(1),
        .PHY_RESET_CYCLES(8)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .tx_clk_i(tx_clk),
        .tx_data_o(tx_data),
        .tx_valid_o(tx_valid),
        .tx_error_o(tx_error),
        .rx_clk_i(rx_clk),
        .rx_data_i(rx_data),
        .rx_valid_i(rx_valid),
        .rx_error_i(rx_error),
        .mdc_o(mdc),
        .mdio_o(mdio_out),
        .mdio_oe_o(mdio_oe),
        .mdio_i(mdio_in),
        .phy_reset_no(phy_reset_n),
        .irq_o(irq),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata)
    );

    assign mdio_in = (dut.mdio_bit_index_q >= 6'd48) ?
        mdio_read_pattern[63-dut.mdio_bit_index_q] : 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        tx_clk = 1'b0;
        forever #20 tx_clk = ~tx_clk;
    end

    initial begin
        rx_clk = 1'b0;
        forever #17 rx_clk = ~rx_clk;
    end

    always @(posedge tx_clk) begin
        #1;
        if (tx_valid) begin
            tx_capture[tx_capture_count] = tx_data;
            tx_capture_count = tx_capture_count + 1;
        end
    end

    function automatic [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] value;
        integer bit_index;
        begin
            value = crc;
            for (bit_index = 0; bit_index < 8;
                 bit_index = bit_index + 1) begin
                if (value[0] ^ data[bit_index])
                    value = (value >> 1) ^ 32'hedb8_8320;
                else
                    value = value >> 1;
            end
            crc32_byte = value;
        end
    endfunction

    task automatic bus_write64;
        input logic [15:0] address;
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
            if (!mem_ready)
                $fatal(1, "Ethernet write was not accepted at %04x", address);
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'd0;
            mem_wdata = 64'd0;
            mem_wstrb = 8'd0;
        end
    endtask

    task automatic bus_write32;
        input logic [15:0] address;
        input logic [31:0] data;
        begin
            if (address[2])
                bus_write64(address, {data, 32'd0}, 8'hf0);
            else
                bus_write64(address, {32'd0, data}, 8'h0f);
        end
    endtask

    task automatic bus_read64;
        input logic [15:0] address;
        output logic [63:0] data;
        integer wait_cycles;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            mem_wdata = 64'd0;
            mem_wstrb = 8'd0;
            wait_cycles = 0;
            while (!mem_ready) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 8)
                    $fatal(1, "Ethernet read timed out at %04x", address);
            end
            #1 data = mem_rdata;
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'd0;
        end
    endtask

    task automatic bus_read32;
        input logic [15:0] address;
        output logic [31:0] data;
        logic [63:0] word_value;
        begin
            bus_read64(address, word_value);
            data = address[2] ? word_value[63:32] : word_value[31:0];
        end
    endtask

    task automatic rx_send_byte;
        input logic [7:0] value;
        begin
            @(negedge rx_clk);
            rx_valid = 1'b1;
            rx_data = value;
        end
    endtask

    task automatic wait_tx_complete;
        logic [31:0] status;
        integer polls;
        begin
            status = 32'h1;
            polls = 0;
            while (status[0]) begin
                bus_read32(16'h07fc, status);
                polls = polls + 1;
                if (polls > 2000)
                    $fatal(1, "TX did not complete");
            end
        end
    endtask

    integer index;
    integer word_index;
    reg [63:0] packet_word;
    reg [63:0] read_word;
    reg [31:0] status32;
    reg [31:0] frame_crc;

    initial begin
        rst_n = 1'b0;
        rx_data = 8'd0;
        rx_valid = 1'b0;
        rx_error = 1'b0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'd0;
        mem_wdata = 64'd0;
        mem_wstrb = 8'd0;
        tx_capture_count = 0;
        mdio_read_pattern = 16'ha5c3;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (12) @(posedge clk);
        if (!phy_reset_n)
            $fatal(1, "PHY reset did not release after its hold interval");

        // Full-depth aliases must not collapse to the legacy 2-KiB windows.
        bus_write64(16'h3ff8, 64'h0123_4567_89ab_cdef, 8'hff);
        bus_read64(16'h3ff8, read_word);
        if (read_word !== 64'h0123_4567_89ab_cdef)
            $fatal(1, "TX0 full-depth packet RAM alias failed");
        bus_write64(16'h9ff8, 64'hfedc_ba98_7654_3210, 8'hff);
        bus_read64(16'h9ff8, read_word);
        if (read_word !== 64'hfedc_ba98_7654_3210)
            $fatal(1, "RX1 full-depth packet RAM alias failed");

        // Program the MAC address using the standard EmacLite sequence.
        bus_write64(16'h0000, 64'h0000_0100_0000_0002, 8'h3f);
        bus_write32(16'h07f4, 32'd6);
        bus_write32(16'h07fc, 32'h0000_0003);
        bus_read32(16'h07fc, status32);
        if (status32[1:0] != 2'b00 ||
            dut.mac_address_q !== 48'h01_00_00_00_00_02)
            $fatal(1, "EmacLite MAC-address programming failed");

        // Build a minimum-size frame (without FCS) in TX0.
        for (index = 0; index < 60; index = index + 1)
            frame[index] = index[7:0] ^ 8'h5a;
        frame[0] = 8'h02;
        frame[1] = 8'h00;
        frame[2] = 8'h00;
        frame[3] = 8'h00;
        frame[4] = 8'h00;
        frame[5] = 8'h01;
        frame[6] = 8'h02;
        frame[7] = 8'h00;
        frame[8] = 8'h00;
        frame[9] = 8'h00;
        frame[10] = 8'h00;
        frame[11] = 8'h02;
        frame[12] = 8'h08;
        frame[13] = 8'h00;

        for (word_index = 0; word_index < 8;
             word_index = word_index + 1) begin
            packet_word = 64'd0;
            for (index = 0; index < 8; index = index + 1)
                if ((word_index*8 + index) < 60)
                    packet_word[8*index +: 8] =
                        frame[word_index*8 + index];
            bus_write64(word_index*8, packet_word, 8'hff);
        end
        bus_read64(16'h0000, read_word);
        if (read_word !== 64'h0002_0100_0000_0002)
            $fatal(1, "TX0 packet memory word is %016x", read_word);

        bus_write32(16'h07f8, 32'h8000_0000);
        bus_write32(16'h17fc, 32'h0000_0008);
        bus_write32(16'h07f4, 32'd60);
        bus_write32(16'h07fc, 32'h8000_0009);
        wait_tx_complete();
        repeat (4) @(posedge tx_clk);

        if (tx_capture_count != 72)
            $fatal(1, "TX byte count %0d, expected 72", tx_capture_count);
        for (index = 0; index < 7; index = index + 1)
            if (tx_capture[index] !== 8'h55)
                $fatal(1, "TX preamble byte %0d is %02x", index,
                       tx_capture[index]);
        if (tx_capture[7] !== 8'hd5)
            $fatal(1, "TX SFD is %02x", tx_capture[7]);
        for (index = 0; index < 60; index = index + 1)
            if (tx_capture[index+8] !== frame[index])
                $fatal(1, "TX payload byte %0d is %02x, expected %02x",
                       index, tx_capture[index+8], frame[index]);
        frame_crc = 32'hffff_ffff;
        for (index = 0; index < 60; index = index + 1)
            frame_crc = crc32_byte(frame_crc, frame[index]);
        frame_crc = ~frame_crc;
        if ({tx_capture[71], tx_capture[70],
             tx_capture[69], tx_capture[68]} !== frame_crc)
            $fatal(1, "TX FCS mismatch");
        if (!irq)
            $fatal(1, "TX completion interrupt did not assert");

        // The ISR clears ACTIVE while retaining interrupt enable.
        bus_write32(16'h07fc, 32'h0000_0008);
        repeat (3) @(posedge clk);
        if (irq)
            $fatal(1, "TX completion interrupt did not clear");

        // Feed the same frame and its FCS into the receive side.
        for (index = 0; index < 7; index = index + 1)
            rx_send_byte(8'h55);
        rx_send_byte(8'hd5);
        for (index = 0; index < 60; index = index + 1)
            rx_send_byte(frame[index]);
        rx_send_byte(frame_crc[7:0]);
        rx_send_byte(frame_crc[15:8]);
        rx_send_byte(frame_crc[23:16]);
        rx_send_byte(frame_crc[31:24]);
        @(negedge rx_clk);
        rx_valid = 1'b0;
        rx_data = 8'd0;

        repeat (8) @(posedge clk);
        bus_read32(16'h17fc, status32);
        if (!status32[0])
            $fatal(1, "RX frame did not set receive-done");
        if (!irq)
            $fatal(1, "RX interrupt did not assert");
        bus_read64(16'h1000, read_word);
        for (index = 0; index < 8; index = index + 1)
            if (read_word[8*index +: 8] !== frame[index])
                $fatal(1, "RX packet byte %0d mismatch", index);

        bus_write32(16'h17fc, 32'h0000_0008);
        repeat (16) @(posedge clk);
        bus_read32(16'h17fc, status32);
        if (status32[0] || irq)
            $fatal(1, "RX acknowledge did not clear status/interrupt");

        // One write and one read exercise the complete Clause 22 controller.
        bus_write32(16'h07f0, 32'h0000_0008);
        bus_write32(16'h07e4, 32'h0000_0020);
        bus_write32(16'h07e8, 32'h0000_1200);
        bus_write32(16'h07f0, 32'h0000_0009);
        status32 = 32'h1;
        while (status32[0])
            bus_read32(16'h07f0, status32);
        if (mdc || mdio_oe)
            $fatal(1, "MDIO write did not return bus to idle");

        bus_write32(16'h07e4, 32'h0000_0420);
        bus_write32(16'h07f0, 32'h0000_0009);
        status32 = 32'h1;
        while (status32[0])
            bus_read32(16'h07f0, status32);
        bus_read32(16'h07ec, status32);
        if (status32[15:0] !== mdio_read_pattern)
            $fatal(1, "MDIO read returned %04x, expected %04x",
                   status32[15:0], mdio_read_pattern);

        $display("PASS: EmacLite MMIO, 8-tile packet RAM, TX/RX, CRC, IRQ, MDIO");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout in EmacLite test");
    end

endmodule
