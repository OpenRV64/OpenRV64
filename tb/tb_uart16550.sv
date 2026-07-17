`timescale 1ns/1ps

module tb_uart16550;

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;
    logic cts_n;
    logic dsr_n;
    logic ri_n;
    logic dcd_n;
    logic dtr_n;
    logic rts_n;
    logic out1_n;
    logic out2_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic irq;

    openrv64_uart16550 dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .rx_i(rx),
        .tx_o(tx),
        .cts_ni(cts_n),
        .dsr_ni(dsr_n),
        .ri_ni(ri_n),
        .dcd_ni(dcd_n),
        .dtr_no(dtr_n),
        .rts_no(rts_n),
        .out1_no(out1_n),
        .out2_no(out2_n),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .irq_o(irq)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_write8;
        input logic [2:0] offset;
        input logic [7:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = {61'h0, offset};
            mem_wdata = 64'h0;
            mem_wdata[8*offset +: 8] = data;
            mem_wstrb = 8'h01 << offset;
            #1;
            if (!mem_ready) begin
                $fatal(1, "UART did not accept write at offset %0d", offset);
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

    task automatic bus_read8;
        input  logic [2:0] offset;
        output logic [7:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = {61'h0, offset};
            mem_wdata = 64'h0;
            mem_wstrb = 8'h00;
            #1;
            if (!mem_ready) begin
                $fatal(1, "UART did not accept read at offset %0d", offset);
            end
            data = mem_rdata[8*offset +: 8];
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0;
        end
    endtask

    task automatic expect_read8;
        input logic [2:0] offset;
        input logic [7:0] expected;
        input [8*56-1:0] label;
        logic [7:0] actual;
        begin
            bus_read8(offset, actual);
            if (actual !== expected) begin
                $fatal(1, "%0s: read %02x, expected %02x",
                       label, actual, expected);
            end
        end
    endtask

    task automatic drive_serial_bit;
        input logic value;
        begin
            rx = value;
            repeat (16) @(posedge clk);
        end
    endtask

    task automatic send_serial_byte;
        input logic [7:0] data;
        integer bit_index;
        begin
            @(negedge clk);
            drive_serial_bit(1'b0);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                drive_serial_bit(data[bit_index]);
            end
            drive_serial_bit(1'b1);
            rx = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic send_serial_byte_bad_stop;
        input logic [7:0] data;
        integer bit_index;
        begin
            @(negedge clk);
            drive_serial_bit(1'b0);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                drive_serial_bit(data[bit_index]);
            end
            drive_serial_bit(1'b0);
            rx = 1'b1;
            repeat (20) @(posedge clk);
        end
    endtask

    task automatic expect_transmitted_byte;
        input logic [7:0] expected;
        integer bit_index;
        begin
            @(negedge tx);
            repeat (8) @(posedge clk);
            #1;
            if (tx !== 1'b0) begin
                $fatal(1, "transmit start bit was not low");
            end
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                repeat (16) @(posedge clk);
                #1;
                if (tx !== expected[bit_index]) begin
                    $fatal(1, "transmit bit %0d was %b, expected %b",
                           bit_index, tx, expected[bit_index]);
                end
            end
            repeat (16) @(posedge clk);
            #1;
            if (tx !== 1'b1) begin
                $fatal(1, "transmit stop bit was not high");
            end
        end
    endtask

    task automatic wait_for_irq;
        input integer maximum_cycles;
        input [8*56-1:0] label;
        integer cycle_count;
        begin : wait_loop
            for (cycle_count = 0; cycle_count < maximum_cycles;
                 cycle_count = cycle_count + 1) begin
                @(posedge clk);
                #1;
                if (irq) begin
                    disable wait_loop;
                end
            end
            $fatal(1, "%0s: interrupt did not assert", label);
        end
    endtask

    logic [7:0] read_data;

    initial begin
        rst_n = 1'b0;
        rx = 1'b1;
        cts_n = 1'b1;
        dsr_n = 1'b1;
        ri_n = 1'b1;
        dcd_n = 1'b1;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_read8(3'd5, 8'h60, "reset LSR has THRE and TEMT");
        expect_read8(3'd2, 8'h01, "reset IIR has no interrupt");
        if (irq) begin
            $fatal(1, "UART interrupt asserted after reset");
        end
        if (tx !== 1'b1 || dtr_n !== 1'b1 || rts_n !== 1'b1) begin
            $fatal(1, "serial or modem outputs were active after reset");
        end

        // The SoC assigns a 0x100-byte UART aperture, but only the first
        // eight bytes contain registers. Higher local offsets must not alias
        // the register bank.
        @(negedge clk);
        mem_valid = 1'b1;
        mem_write = 1'b1;
        mem_addr = 64'h0b;
        mem_wdata = 64'h0000_0000_ff00_0000;
        mem_wstrb = 8'h08;
        #1;
        if (!mem_ready) begin
            $fatal(1, "UART did not acknowledge reserved offset");
        end
        @(posedge clk);
        @(negedge clk);
        mem_write = 1'b0;
        mem_addr = 64'h08;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;
        #1;
        if (!mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "reserved UART offset did not read as zero");
        end
        @(posedge clk);
        @(negedge clk);
        mem_valid = 1'b0;
        mem_addr = 64'h0;
        expect_read8(3'd3, 8'h00, "reserved write did not alias LCR");

        bus_write8(3'd7, 8'ha5);
        expect_read8(3'd7, 8'ha5, "scratch register round trip");

        // DLAB aliases offsets zero and one onto the divisor latches.
        bus_write8(3'd3, 8'h83);
        bus_write8(3'd0, 8'h01);
        bus_write8(3'd1, 8'h00);
        expect_read8(3'd0, 8'h01, "DLL readback");
        expect_read8(3'd1, 8'h00, "DLM readback");
        bus_write8(3'd3, 8'h03);

        // Enabling FIFOs is reflected in IIR[7:6].
        bus_write8(3'd2, 8'h01);
        expect_read8(3'd2, 8'hc1, "FIFO status in IIR");

        // ETBEI on an empty transmitter raises the single UART interrupt.
        bus_write8(3'd1, 8'h02);
        #1;
        if (!irq) begin
            $fatal(1, "THRE interrupt did not assert");
        end
        expect_read8(3'd2, 8'hc2, "THRE interrupt identification");
        #1;
        if (irq) begin
            $fatal(1, "reading THRE IIR did not clear the interrupt");
        end

        // A real 8N1 frame is serialized LSB first.
        fork
            begin
                expect_transmitted_byte(8'ha5);
            end
            begin
                bus_write8(3'd0, 8'ha5);
            end
        join
        wait_for_irq(64, "THRE after FIFO drains");
        bus_read8(3'd5, read_data);
        if (read_data[5] !== 1'b1) begin
            $fatal(1, "THRE did not follow the empty transmit FIFO");
        end
        expect_read8(3'd2, 8'hc2, "drained transmitter interrupt");
        bus_write8(3'd1, 8'h00);

        // Receive one external frame and service its data-ready interrupt.
        bus_write8(3'd1, 8'h01);
        send_serial_byte(8'h5a);
        wait_for_irq(32, "received data available");
        expect_read8(3'd2, 8'hc4, "received-data interrupt priority");
        bus_read8(3'd5, read_data);
        if ((read_data & 8'h1f) !== 8'h01) begin
            $fatal(1, "unexpected receive line status %02x", read_data);
        end
        expect_read8(3'd0, 8'h5a, "received serial byte");
        #1;
        if (irq) begin
            $fatal(1, "RBR read did not clear received-data interrupt");
        end

        // With a four-byte trigger, one queued byte raises the character
        // timeout indication only after four idle character times.
        bus_write8(3'd2, 8'h41);
        send_serial_byte(8'h11);
        repeat (128) @(posedge clk);
        if (irq) begin
            $fatal(1, "receive timeout asserted too early");
        end
        wait_for_irq(900, "receive character timeout");
        expect_read8(3'd2, 8'hcc, "receive timeout identification");
        expect_read8(3'd0, 8'h11, "timeout byte remains readable");

        // Four queued bytes reach the programmed trigger; popping the first
        // immediately drops the level-sensitive data interrupt.
        bus_write8(3'd2, 8'h47);
        send_serial_byte(8'h31);
        if (irq) $fatal(1, "FIFO trigger fired after one byte");
        send_serial_byte(8'h32);
        if (irq) $fatal(1, "FIFO trigger fired after two bytes");
        send_serial_byte(8'h33);
        if (irq) $fatal(1, "FIFO trigger fired after three bytes");
        send_serial_byte(8'h34);
        wait_for_irq(32, "four-byte receive trigger");
        expect_read8(3'd2, 8'hc4, "FIFO trigger interrupt identification");
        expect_read8(3'd0, 8'h31, "FIFO preserves byte zero");
        #1;
        if (irq) begin
            $fatal(1, "FIFO interrupt did not drop below its trigger");
        end
        expect_read8(3'd0, 8'h32, "FIFO preserves byte one");
        expect_read8(3'd0, 8'h33, "FIFO preserves byte two");
        expect_read8(3'd0, 8'h34, "FIFO preserves byte three");

        // A low stop bit is attached to the affected FIFO byte and takes
        // priority over the normal received-data interrupt.
        bus_write8(3'd2, 8'h07);
        bus_write8(3'd1, 8'h05);
        send_serial_byte_bad_stop(8'h35);
        wait_for_irq(32, "receive framing error");
        expect_read8(3'd2, 8'hc6, "framing-error interrupt priority");
        bus_read8(3'd5, read_data);
        if ((read_data & 8'h09) !== 8'h09) begin
            $fatal(1, "framing error status missing: LSR=%02x", read_data);
        end
        expect_read8(3'd0, 8'h35, "framing-error byte remains readable");

        // Character mode has a one-byte RBR. A second complete frame before
        // the first is read sets OE and elevates the line-status interrupt.
        bus_write8(3'd2, 8'h00);
        bus_write8(3'd1, 8'h05);
        send_serial_byte(8'h21);
        send_serial_byte(8'h22);
        wait_for_irq(32, "receiver overrun");
        expect_read8(3'd2, 8'h06, "line-status interrupt priority");
        bus_read8(3'd5, read_data);
        if ((read_data & 8'h03) !== 8'h03) begin
            $fatal(1, "overrun status missing: LSR=%02x", read_data);
        end
        expect_read8(3'd0, 8'h22, "character-mode overrun replaces RBR");
        bus_write8(3'd1, 8'h00);

        // A modem input transition is the lowest-priority interrupt and an
        // MSR read clears its delta flags.
        bus_write8(3'd1, 8'h08);
        @(negedge clk);
        cts_n = 1'b0;
        wait_for_irq(16, "modem status change");
        expect_read8(3'd2, 8'h00, "modem interrupt identification");
        expect_read8(3'd6, 8'h11, "CTS state and delta reporting");
        #1;
        if (irq) begin
            $fatal(1, "MSR read did not clear modem interrupt");
        end
        bus_write8(3'd1, 8'h00);

        // Diagnostic loopback keeps TX high externally while feeding the
        // internal transmitted stream back through the receiver.
        bus_write8(3'd2, 8'h07);
        bus_write8(3'd1, 8'h01);
        bus_write8(3'd4, 8'h10);
        bus_write8(3'd0, 8'h3c);
        wait_for_irq(256, "diagnostic loopback receive");
        if (tx !== 1'b1) begin
            $fatal(1, "physical TX was active during diagnostic loopback");
        end
        expect_read8(3'd0, 8'h3c, "diagnostic serial loopback");
        bus_write8(3'd4, 8'h00);
        bus_write8(3'd1, 8'h00);

        $display("tb_uart16550: PASS");
        $finish;
    end

endmodule
