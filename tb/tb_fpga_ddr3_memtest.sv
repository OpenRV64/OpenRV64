`timescale 1ns/1ps

module tb_fpga_ddr3_memtest;
    localparam integer ADDR_WIDTH = 28;
    localparam logic [ADDR_WIDTH-1:0] LAST_ADDR = 28'h000_0078;

    logic clk = 1'b0;
    logic reset;
    logic calib_complete;
    logic allow_ready;
    logic inject_error;

    wire [ADDR_WIDTH-1:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    logic app_rdy;
    wire [255:0] app_wdf_data;
    wire app_wdf_end;
    wire [31:0] app_wdf_mask;
    wire app_wdf_wren;
    logic app_wdf_rdy;
    logic [255:0] app_rd_data;
    logic app_rd_data_end;
    logic app_rd_data_valid;
    wire [2:0] status;
    wire [ADDR_WIDTH-1:0] fail_addr;
    wire [2:0] fail_lane;
    wire [31:0] fail_expected;
    wire [31:0] fail_actual;
    wire [2:0] fail_reason;

    logic [255:0] memory [0:15];
    logic [7:0] cycle_q;
    logic have_write_cmd_q;
    logic [ADDR_WIDTH-1:0] write_addr_q;
    logic have_write_data_q;
    logic [255:0] write_data_q;
    logic read_pending_q;
    logic [2:0] read_delay_q;
    logic [ADDR_WIDTH-1:0] read_addr_q;

    wire write_cmd_accept = app_en && app_rdy && (app_cmd == 3'b000);
    wire read_cmd_accept = app_en && app_rdy && (app_cmd == 3'b001);
    wire write_data_accept = app_wdf_wren && app_wdf_rdy;

    always #5 clk = !clk;

    always @* begin
        app_rdy = allow_ready && (cycle_q[1:0] != 2'b00);
        app_wdf_rdy = allow_ready && (cycle_q[2:0] != 3'b001);
    end

    openrv64_fpga_ddr3_memtest #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LAST_ADDR(LAST_ADDR),
        .TIMEOUT_CYCLES(20)
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
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid),
        .status_o(status),
        .fail_addr_o(fail_addr),
        .fail_lane_o(fail_lane),
        .fail_expected_o(fail_expected),
        .fail_actual_o(fail_actual),
        .fail_reason_o(fail_reason)
    );

    always @(posedge clk) begin
        if (reset) begin
            cycle_q            <= 8'h00;
            have_write_cmd_q   <= 1'b0;
            write_addr_q       <= '0;
            have_write_data_q  <= 1'b0;
            write_data_q       <= '0;
            read_pending_q     <= 1'b0;
            read_delay_q       <= '0;
            read_addr_q        <= '0;
            app_rd_data        <= '0;
            app_rd_data_end    <= 1'b0;
            app_rd_data_valid  <= 1'b0;
        end else begin
            cycle_q <= cycle_q + 1'b1;
            app_rd_data_valid <= 1'b0;
            app_rd_data_end <= 1'b0;

            if ((have_write_cmd_q || write_cmd_accept) &&
                (have_write_data_q || write_data_accept)) begin
                memory[(write_cmd_accept ? app_addr : write_addr_q) >> 3] <=
                    write_data_accept ? app_wdf_data : write_data_q;
                have_write_cmd_q  <= 1'b0;
                have_write_data_q <= 1'b0;
            end else begin
                if (write_cmd_accept) begin
                    have_write_cmd_q <= 1'b1;
                    write_addr_q     <= app_addr;
                end
                if (write_data_accept) begin
                    have_write_data_q <= 1'b1;
                    write_data_q      <= app_wdf_data;
                end
            end

            if (read_cmd_accept) begin
                if (read_pending_q)
                    $fatal(1, "more than one read outstanding");
                read_pending_q <= 1'b1;
                read_delay_q   <= 3'd2;
                read_addr_q    <= app_addr;
            end else if (read_pending_q) begin
                if (read_delay_q != 0) begin
                    read_delay_q <= read_delay_q - 1'b1;
                end else begin
                    app_rd_data <= memory[read_addr_q >> 3];
                    if (inject_error && (read_addr_q == 28'h000_0020))
                        app_rd_data[0] <= !memory[read_addr_q >> 3][0];
                    app_rd_data_valid <= 1'b1;
                    app_rd_data_end   <= 1'b1;
                    read_pending_q    <= 1'b0;
                end
            end

            if ((app_en && app_rdy) && (app_addr[2:0] != 3'b000))
                $fatal(1, "unaligned command address %h", app_addr);
            if (app_wdf_wren && !app_wdf_end)
                $fatal(1, "write data beat missing end");
            if (app_wdf_wren && (app_wdf_mask != 0))
                $fatal(1, "write data unexpectedly masked");
        end
    end

    task automatic reset_test(input logic ready, input logic corrupt);
        begin
            reset          = 1'b1;
            calib_complete = 1'b0;
            allow_ready    = ready;
            inject_error   = corrupt;
            repeat (4) @(posedge clk);
            reset = 1'b0;
            repeat (3) @(posedge clk);
            calib_complete = 1'b1;
        end
    endtask

    task automatic wait_for_terminal;
        integer cycles;
        begin
            cycles = 0;
            while ((status != 3'd5) && (status != 3'd6) &&
                   (cycles < 5000)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles == 5000)
                $fatal(1, "memory test did not terminate");
        end
    endtask

    initial begin
        reset_test(1'b1, 1'b0);
        wait_for_terminal();
        if (status != 3'd5)
            $fatal(1, "clean memory model failed, reason=%0d addr=%h",
                fail_reason, fail_addr);

        reset_test(1'b1, 1'b1);
        wait_for_terminal();
        if (status != 3'd6 || fail_reason != 3'd1 ||
            fail_addr != 28'h000_0020 || fail_lane != 3'd0 ||
            fail_actual != (fail_expected ^ 32'h0000_0001))
            $fatal(1,
                "bad compare diagnostic status=%0d reason=%0d addr=%h lane=%0d expected=%h actual=%h",
                status, fail_reason, fail_addr, fail_lane,
                fail_expected, fail_actual);

        reset_test(1'b0, 1'b0);
        wait_for_terminal();
        if (status != 3'd6 || fail_reason != 3'd5 || fail_addr != 0)
            $fatal(1, "timeout diagnostic failed reason=%0d addr=%h",
                fail_reason, fail_addr);

        $display("OPENRV64 FPGA DDR3 MEMTEST CORE PASS");
        $finish;
    end

endmodule
