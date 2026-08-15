`timescale 1ns/1ps

module tb_fpga_opensbi_system;

    logic ui_clk = 1'b0;
    logic core_clk = 1'b0;
    logic ui_reset = 1'b1;
    logic calib_complete = 1'b0;
    // Keep the domains asynchronous but accelerate wall-clock simulation.
    // CDC protocol behavior is covered independently with physical-like rates.
    always #2.3 ui_clk = ~ui_clk;
    always #5 core_clk = ~core_clk;

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
            "build/fpga/xc7a100t/opensbi-smoke/images/trampoline-fpga.mem"),
        .FIRMWARE_INIT_FILE(
            "build/fpga/xc7a100t/opensbi-smoke/images/fw_jump-fpga-head.mem"),
        .FIRMWARE_TAIL_INIT_FILE(
            "build/fpga/xc7a100t/opensbi-smoke/images/fw_jump-fpga-tail.mem"),
        .PAYLOAD_INIT_FILE(
            "build/fpga/xc7a100t/opensbi-smoke/images/payload-fpga.mem"),
        .FDT_INIT_FILE(
            "build/fpga/xc7a100t/opensbi-smoke/images/openrv64-dtb-fpga.mem"),
        .TRAMPOLINE_WORDS(1),
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
        .uart_rx_i(1'b1),
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
                if (memory.exists(line_index))
                    app_rd_data <= memory[line_index];
                else
                    app_rd_data <= 256'd0;
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
                if (!app_wdf_end)
                    $fatal(1, "MIG write data did not mark end");
                data_pending <= 1'b1;
                pending_data <= app_wdf_data;
                pending_mask <= app_wdf_mask;
            end
        end
    end

    string expected_message = "OPENRV64 SBI SV39 PTW PASS";
    integer message_index = 0;
    logic saw_payload_message = 1'b0;
    logic saw_sv39 = 1'b0;
    integer ptw_line_requests = 0;
    integer core_cycles = 0;

    always_ff @(posedge core_clk) begin
        core_cycles <= core_cycles + 1;
        if (dut.u_platform.u_core.u_core.u_csrs.satp_q[63:60] == 4'd8)
            saw_sv39 <= 1'b1;
        if (dut.ext_icx_req_valid && dut.ext_icx_req_ready &&
            dut.ext_icx_req_op == `OPENRV64_ICX_OP_READ)
            ptw_line_requests <= ptw_line_requests + 1;
        if ((core_cycles % 2_000_000) == 0)
            $display("cycle=%0d pc=%016x satp_busy=%b satp_count=%0d csr_write=%b wb_valid=%b wb_clear=%b mem=%b/%b mtime=%0d mtimecmp=%0d mtip=%b mie=%016x mip=%016x wfi=%b",
                     core_cycles, debug_pc,
                     dut.u_platform.u_core.u_core.csr_satp_busy,
                     dut.u_platform.u_core.u_core.u_csrs.satp_count_q,
                     dut.u_platform.u_core.u_core.exec_csr_write,
                     dut.u_platform.u_core.u_core.exec_wb_valid,
                     dut.u_platform.u_core.u_core.exec_wb_clear,
                     dut.core_mem_valid, dut.core_mem_ready,
                     dut.u_platform.clint_mtime,
                     dut.u_platform.u_clint.mtimecmp_q[63:0],
                     dut.u_platform.clint_mtip[0],
                     dut.u_platform.u_core.u_core.u_csrs.mie_q,
                     dut.u_platform.u_core.u_core.u_csrs.mip_value,
                     dut.u_platform.u_core.u_core.wfi_sleep_q);
        if (dut.u_platform.u_uart.write_thr) begin
            $write("%c", dut.u_platform.u_uart.thr_write_data);
            if (dut.u_platform.u_uart.thr_write_data ==
                expected_message[message_index]) begin
                message_index <= message_index + 1;
                if (message_index + 1 == expected_message.len())
                    saw_payload_message <= 1'b1;
            end else begin
                message_index <=
                    (dut.u_platform.u_uart.thr_write_data ==
                     expected_message[0]) ? 1 : 0;
            end
        end
    end

    initial begin
        repeat (20) @(posedge ui_clk);
        ui_reset = 1'b0;
        repeat (10) @(posedge ui_clk);
        calib_complete = 1'b1;

        fork
            begin
                wait (saw_payload_message &&
                      dut.u_platform.u_core.u_core.wfi_sleep_q);
            end
            begin
                repeat (45_000_000) @(posedge core_clk);
                $fatal(1, "FPGA OpenSBI simulation timeout at PC %016x",
                       debug_pc);
            end
        join_any
        disable fork;

        if (!boot_release)
            $fatal(1, "CPU was not released after DDR image load");
        if (!saw_sv39 || ptw_line_requests < 3)
            $fatal(1, "Sv39/PTW activity missing: satp=%0b lines=%0d",
                   saw_sv39, ptw_line_requests);
        if (!memory.exists(64'h0001_0040) ||
            memory[64'h0001_0040][63:0] != 64'h5356333950545701)
            $fatal(1, "Payload completion store did not reach modeled DDR3");
        $display("OPENRV64 FPGA OPENSBI SYSTEM PASS");
        $finish;
    end

endmodule
