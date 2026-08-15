`timescale 1ns/1ps

module tb_fpga_linux_uart_loader;

    localparam integer UART_BIT_CYCLES = 80; // divisor 5, 16x oversampling

    logic ui_clk = 1'b0;
    logic core_clk = 1'b0;
    logic ui_reset = 1'b1;
    logic calib_complete = 1'b0;
    logic uart_rx = 1'b1;
    // Preserve the board's 100 MHz MIG UI to 9.216 MHz core ratio.  UART
    // throughput depends on memory-service latency measured in core cycles.
    always #5 ui_clk = ~ui_clk;
    always #54.253472 core_clk = ~core_clk;

    logic uart_tx;
    logic boot_release;
    logic [63:0] debug_pc;
    logic [27:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en;
    logic [255:0] app_wdf_data;
    logic app_wdf_end;
    logic [31:0] app_wdf_mask;
    logic app_wdf_wren;
    logic [255:0] app_rd_data = 256'd0;
    logic app_rd_data_end = 1'b0;
    logic app_rd_data_valid = 1'b0;

    openrv64_fpga_opensbi_system #(
        .TRAMPOLINE_INIT_FILE(
            "build/fpga/xc7a100t/linux-uart-tlb4/images/trampoline-fpga.mem"),
        .FIRMWARE_INIT_FILE(
            "build/fpga/xc7a100t/linux-uart-tlb4/images/fw_jump-fpga-head.mem"),
        .FIRMWARE_TAIL_INIT_FILE(
            "build/fpga/xc7a100t/linux-uart-tlb4/images/fw_jump-fpga-tail.mem"),
        .PAYLOAD_INIT_FILE(
            "build/fpga/xc7a100t/linux-uart-tlb4/images/payload-fpga.mem"),
        .FDT_INIT_FILE(
            "build/fpga/xc7a100t/linux-uart-tlb4/images/openrv64-dtb-fpga.mem"),
        .TRAMPOLINE_WORDS(27),
        .FIRMWARE_WORDS(8340),
        .PAYLOAD_WORDS(14),
        .FDT_WORDS(49),
        .STATUS_BAUD(10_000_000),
        .STATUS_FIRST_DELAY_CYCLES(20),
        .STATUS_REPEAT_CYCLES(100_000)
    ) dut (
        .ui_clk_i(ui_clk),
        .ui_reset_i(ui_reset),
        .calib_complete_i(calib_complete),
        .core_clk_i(core_clk),
        .core_clock_locked_i(1'b1),
        .uart_rx_i(uart_rx),
        .uart_tx_o(uart_tx),
        .boot_release_o(boot_release),
        .debug_pc_o(debug_pc),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(1'b1),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(1'b1),
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid)
    );

    bit [255:0] memory [longint unsigned];
    logic command_pending = 1'b0;
    logic data_pending = 1'b0;
    logic [27:0] pending_addr;
    logic [255:0] pending_data;
    logic [31:0] pending_mask;
    logic [2:0] read_delay = 3'd0;
    logic [27:0] read_addr_q;
    integer write_byte;

    always_ff @(posedge ui_clk) begin : mig_model
        logic command_fire;
        logic data_fire;
        logic [27:0] completed_addr;
        logic [255:0] completed_data;
        logic [31:0] completed_mask;
        longint unsigned line_index;

        app_rd_data_valid <= 1'b0;
        app_rd_data_end <= 1'b0;
        command_fire = app_en;
        data_fire = app_wdf_wren;

        if (command_fire && app_cmd == 3'b001) begin
            read_addr_q <= app_addr;
            read_delay <= 3'd2;
        end else if (read_delay != 3'd0) begin
            read_delay <= read_delay - 3'd1;
            if (read_delay == 3'd1) begin
                line_index = read_addr_q >> 3;
                app_rd_data <= memory.exists(line_index) ?
                                   memory[line_index] : 256'd0;
                app_rd_data_valid <= 1'b1;
                app_rd_data_end <= 1'b1;
            end
        end

        completed_addr = command_pending ? pending_addr : app_addr;
        completed_data = data_pending ? pending_data : app_wdf_data;
        completed_mask = data_pending ? pending_mask : app_wdf_mask;
        if ((command_pending || (command_fire && app_cmd == 3'b000)) &&
            (data_pending || data_fire)) begin
            line_index = completed_addr >> 3;
            for (write_byte = 0; write_byte < 32;
                 write_byte = write_byte + 1) begin
                if (!completed_mask[write_byte])
                    memory[line_index][write_byte*8 +: 8] <=
                        completed_data[write_byte*8 +: 8];
            end
            command_pending <= 1'b0;
            data_pending <= 1'b0;
        end else begin
            if (command_fire && app_cmd == 3'b000) begin
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

    string ready_message = "OPENRV64 LINUX LOAD READY";
    string pass_message = "OPENRV64 LINUX LOAD PASS";
    integer ready_index = 0;
    integer pass_index = 0;
    integer ack_count = 0;
    logic saw_ready = 1'b0;
    logic saw_pass = 1'b0;

    always_ff @(posedge core_clk) begin
        if (dut.u_platform.u_uart.write_thr) begin
            $write("%c", dut.u_platform.u_uart.thr_write_data);
            if (dut.u_platform.u_uart.thr_write_data == 8'h2b)
                ack_count <= ack_count + 1;
            if (dut.u_platform.u_uart.thr_write_data ==
                ready_message[ready_index]) begin
                ready_index <= ready_index + 1;
                if (ready_index + 1 == ready_message.len())
                    saw_ready <= 1'b1;
            end else begin
                ready_index <=
                    (dut.u_platform.u_uart.thr_write_data ==
                     ready_message[0]) ? 1 : 0;
            end
            if (dut.u_platform.u_uart.thr_write_data ==
                pass_message[pass_index]) begin
                pass_index <= pass_index + 1;
                if (pass_index + 1 == pass_message.len())
                    saw_pass <= 1'b1;
            end else begin
                pass_index <=
                    (dut.u_platform.u_uart.thr_write_data ==
                     pass_message[0]) ? 1 : 0;
            end
        end
    end

    task automatic uart_send_byte(input logic [7:0] value);
        integer bit_index;
        begin
            @(negedge core_clk);
            uart_rx = 1'b0;
            repeat (UART_BIT_CYCLES) @(negedge core_clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (UART_BIT_CYCLES) @(negedge core_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_BIT_CYCLES) @(negedge core_clk);
        end
    endtask

    task automatic uart_send_u32(input logic [31:0] value);
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                uart_send_byte(value[byte_index*8 +: 8]);
        end
    endtask

    initial begin : test
        integer byte_index;
        static string magic = "ORV64LNX";

        repeat (20) @(posedge ui_clk);
        ui_reset = 1'b0;
        repeat (10) @(posedge ui_clk);
        calib_complete = 1'b1;

        fork
            begin
                wait (saw_ready);
            end
            begin
                repeat (5_000_000) @(posedge core_clk);
                $fatal(1, "Linux UART loader READY timeout at PC %016x",
                       debug_pc);
            end
        join_any
        disable fork;

        for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
            uart_send_byte(magic[byte_index]);
        uart_send_u32(32'd64);
        uart_send_u32(32'h100ece8c);
        for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
            uart_send_byte(byte_index[7:0]);
            if ((byte_index & 3) == 3)
                repeat (9216) @(negedge core_clk);
        end
        wait (ack_count == 1);

        fork
            begin
                wait (saw_pass);
            end
            begin
                repeat (2_000_000) @(posedge core_clk);
                $fatal(1, "Linux UART loader PASS timeout at PC %016x s2=%016x s5=%016x",
                       debug_pc,
                       dut.u_platform.u_core.u_core.u_gpr.regs[18],
                       dut.u_platform.u_core.u_core.u_gpr.regs[21]);
            end
        join_any
        disable fork;

        repeat (20) @(posedge ui_clk);
        if (!memory.exists(64'h10000) || !memory.exists(64'h10001))
            $fatal(1, "Linux UART loader did not write both DDR lines");
        for (byte_index = 0; byte_index < 32; byte_index = byte_index + 1) begin
            if (memory[64'h10000][byte_index*8 +: 8] !== byte_index[7:0])
                $fatal(1, "first line mismatch at byte %0d", byte_index);
            if (memory[64'h10001][byte_index*8 +: 8] !==
                (byte_index + 32))
                $fatal(1, "second line mismatch at byte %0d", byte_index);
        end
        $display("OPENRV64 FPGA LINUX UART LOADER PASS");
        $finish;
    end

endmodule
