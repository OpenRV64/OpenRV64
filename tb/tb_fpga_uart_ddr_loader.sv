`timescale 1ns/1ps

module tb_fpga_uart_ddr_loader;

    localparam integer CLOCK_HZ = 1_000_000;
    localparam integer BAUD = 100_000;
    localparam integer BIT_CYCLES = CLOCK_HZ / BAUD;
    localparam integer IMAGE_BYTES = 36;
    localparam logic [31:0] IMAGE_CRC32 = 32'h2571_5854;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic start = 1'b0;
    logic calib_complete = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    always #500 clk = ~clk;

    logic [27:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en;
    logic app_rdy;
    logic [255:0] app_wdf_data;
    logic app_wdf_end;
    logic [31:0] app_wdf_mask;
    logic app_wdf_wren;
    logic app_wdf_rdy;
    logic active;
    logic done;
    logic failed;

    openrv64_fpga_uart_ddr_loader #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD),
        .TIMEOUT_CYCLES(100)
    ) dut (
        .clk_i(clk),
        .reset_i(reset),
        .start_i(start),
        .calib_complete_i(calib_complete),
        .uart_rx_i(uart_rx),
        .uart_tx_o(uart_tx),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(app_rdy),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy),
        .active_o(active),
        .done_o(done),
        .failed_o(failed)
    );

    task automatic send_uart_byte(input logic [7:0] value);
        integer bit_index;
        begin
            uart_rx = 1'b0;
            repeat (BIT_CYCLES) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    task automatic send_word_le(input logic [31:0] value);
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                send_uart_byte(value[byte_index*8 +: 8]);
        end
    endtask

    task automatic wait_for_message(input logic [1:0] message_id);
        integer cycles;
        begin
            cycles = 0;
            while (!(dut.message_done_q && dut.message_id_q == message_id)) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 5000)
                    $fatal(1, "UART loader message timed out");
            end
            @(posedge clk);
        end
    endtask

    logic [7:0] cycle_count = 8'd0;
    logic command_pending = 1'b0;
    logic data_pending = 1'b0;
    logic [27:0] pending_addr;
    logic [255:0] pending_data;
    logic [31:0] pending_mask;
    integer write_count = 0;

    always_comb begin
        app_rdy = cycle_count[1:0] != 2'd0;
        app_wdf_rdy = cycle_count[2:0] != 3'd3;
    end

    task automatic check_write(
        input integer index,
        input logic [27:0] address,
        input logic [255:0] data,
        input logic [31:0] mask
    );
        begin
            case (index)
                0: begin
                    if (address !== 28'h008_0000)
                        $fatal(1, "first line address mismatch: %h", address);
                    if (data !==
                        256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100)
                        $fatal(1, "first line data mismatch: %h", data);
                    if (mask !== 32'h0000_0000)
                        $fatal(1, "first line mask mismatch: %h", mask);
                end
                1: begin
                    if (address !== 28'h008_0008)
                        $fatal(1, "tail line address mismatch: %h", address);
                    if (data[31:0] !== 32'h2322_2120)
                        $fatal(1, "tail line data mismatch: %h", data);
                    if (mask !== 32'hffff_fff0)
                        $fatal(1, "tail line mask mismatch: %h", mask);
                end
                default: $fatal(1, "unexpected extra UART-loader write");
            endcase
        end
    endtask

    always_ff @(posedge clk) begin : capture_writes
        logic command_fire;
        logic data_fire;
        logic [27:0] completed_addr;
        logic [255:0] completed_data;
        logic [31:0] completed_mask;

        cycle_count <= cycle_count + 8'd1;
        command_fire = app_en && app_rdy;
        data_fire = app_wdf_wren && app_wdf_rdy;
        if (command_fire && app_cmd !== 3'b000)
            $fatal(1, "UART loader issued non-write command");
        if (data_fire && !app_wdf_end)
            $fatal(1, "UART loader did not mark write-data end");

        completed_addr = command_pending ? pending_addr : app_addr;
        completed_data = data_pending ? pending_data : app_wdf_data;
        completed_mask = data_pending ? pending_mask : app_wdf_mask;
        if ((command_pending || command_fire) &&
            (data_pending || data_fire)) begin
            check_write(write_count, completed_addr, completed_data,
                        completed_mask);
            write_count <= write_count + 1;
            command_pending <= 1'b0;
            data_pending <= 1'b0;
        end else begin
            if (command_fire) begin
                command_pending <= 1'b1;
                pending_addr <= app_addr;
            end
            if (data_fire) begin
                data_pending <= 1'b1;
                pending_data <= app_wdf_data;
                pending_mask <= app_wdf_mask;
            end
        end
    end

    initial begin : stimulus
        integer byte_index;

        repeat (4) @(posedge clk);
        reset = 1'b0;
        calib_complete = 1'b1;
        start = 1'b1;

        wait_for_message(2'd0);
        send_uart_byte("O");
        send_uart_byte("R");
        send_uart_byte("V");
        send_uart_byte("6");
        send_uart_byte("4");
        send_uart_byte("L");
        send_uart_byte("N");
        send_uart_byte("X");
        send_word_le(IMAGE_BYTES);
        send_word_le(IMAGE_CRC32);

        wait_for_message(2'd1);
        for (byte_index = 0; byte_index < IMAGE_BYTES;
             byte_index = byte_index + 1)
            send_uart_byte(byte_index[7:0]);

        fork
            begin
                wait (done);
            end
            begin
                repeat (5000) @(posedge clk);
                $fatal(1, "UART DDR loader completion timed out");
            end
        join_any
        disable fork;

        if (failed || active || write_count != 2)
            $fatal(1, "UART DDR loader did not complete two writes");
        if (dut.crc_q !== ~IMAGE_CRC32)
            $fatal(1, "UART DDR loader CRC state mismatch: %h", dut.crc_q);

        calib_complete = 1'b0;
        repeat (2) @(posedge clk);
        if (!failed)
            $fatal(1, "UART DDR loader did not detect calibration loss");

        $display("OPENRV64 FPGA UART DDR LOADER PASS");
        $finish;
    end

endmodule
