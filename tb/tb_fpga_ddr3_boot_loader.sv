`timescale 1ns/1ps

module tb_fpga_ddr3_boot_loader;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic calib_complete = 1'b0;
    always #5 clk = ~clk;

    logic [27:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en;
    logic app_rdy;
    logic [255:0] app_wdf_data;
    logic app_wdf_end;
    logic [31:0] app_wdf_mask;
    logic app_wdf_wren;
    logic app_wdf_rdy;
    logic done;
    logic failed;

    openrv64_fpga_ddr3_boot_loader #(
        .TRAMPOLINE_INIT_FILE("tb/data/fpga_boot_trampoline.memh"),
        .FIRMWARE_INIT_FILE("tb/data/fpga_boot_firmware.memh"),
        .FIRMWARE_TAIL_INIT_FILE("tb/data/fpga_boot_firmware_tail.memh"),
        .PAYLOAD_INIT_FILE("tb/data/fpga_boot_payload.memh"),
        .FDT_INIT_FILE("tb/data/fpga_boot_fdt.memh"),
        .TRAMPOLINE_WORDS(1),
        .FIRMWARE_WORDS(2),
        .PAYLOAD_WORDS(1),
        .FDT_WORDS(1),
        .FIRMWARE_SPLIT_WORD(1),
        .TIMEOUT_CYCLES(100)
    ) dut (
        .clk_i(clk),
        .reset_i(reset),
        .calib_complete_i(calib_complete),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(app_rdy),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy),
        .done_o(done),
        .failed_o(failed)
    );

    logic [7:0] cycle_count = 8'd0;
    logic command_pending = 1'b0;
    logic data_pending = 1'b0;
    logic [27:0] pending_addr;
    logic [255:0] pending_data;
    integer write_count = 0;

    always_comb begin
        app_rdy = (cycle_count[1:0] != 2'd0);
        app_wdf_rdy = (cycle_count[2:0] != 3'd3);
    end

    task automatic check_write(
        input integer index,
        input logic [27:0] address,
        input logic [255:0] data
    );
        begin
            case (index)
                0: if (address !== 28'h000_0000 || data !==
                    256'hffeeddccbbaa998877665544332211000123456789abcdeffedcba9876543210)
                    $fatal(1, "trampoline write mismatch");
                1: if (address !== 28'h004_0000 || data !==
                    256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f)
                    $fatal(1, "firmware word zero mismatch");
                2: if (address !== 28'h004_0008 || data !==
                    256'h202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f)
                    $fatal(1, "firmware word one mismatch");
                3: if (address !== 28'h008_0000 || data !==
                    256'h1111111122222222333333334444444455555555666666667777777788888888)
                    $fatal(1, "payload write mismatch");
                4: if (address !== 28'h3fc_0000 || data !==
                    256'h89abcdef0123456776543210fedcba980f1e2d3c4b5a69788796a5b4c3d2e1f0)
                    $fatal(1, "FDT write mismatch");
                default: $fatal(1, "unexpected extra boot-loader write");
            endcase
        end
    endtask

    always_ff @(posedge clk) begin : capture_writes
        logic command_fire;
        logic data_fire;
        logic [27:0] completed_addr;
        logic [255:0] completed_data;

        cycle_count <= cycle_count + 8'd1;
        command_fire = app_en && app_rdy;
        data_fire = app_wdf_wren && app_wdf_rdy;
        if (command_fire && app_cmd !== 3'b000)
            $fatal(1, "boot loader issued non-write command");
        if (data_fire && (app_wdf_mask !== 32'd0 || !app_wdf_end))
            $fatal(1, "boot loader write mask/end mismatch");
        completed_addr = command_pending ? pending_addr : app_addr;
        completed_data = data_pending ? pending_data : app_wdf_data;

        if ((command_pending || command_fire) &&
            (data_pending || data_fire)) begin
            check_write(write_count, completed_addr, completed_data);
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
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);
        calib_complete = 1'b1;

        fork
            begin
                wait (done);
            end
            begin
                repeat (300) @(posedge clk);
                $fatal(1, "boot loader timed out in testbench");
            end
        join_any
        disable fork;

        if (failed || write_count != 5)
            $fatal(1, "boot loader did not complete all five writes");

        calib_complete = 1'b0;
        repeat (2) @(posedge clk);
        if (!failed)
            $fatal(1, "boot loader did not detect calibration loss");

        $display("OPENRV64 FPGA DDR3 BOOT LOADER PASS");
        $finish;
    end

endmodule
