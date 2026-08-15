// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// MYD-J7A100T destructive full-memory DDR3 test with UART diagnostics.

`timescale 1ns/1ps

module openrv64_myd_j7a100t_ddr3_memtest_top (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        rst_n,

    output wire        uart_tx_o,
    output wire        eth1_phy_reset_n_o,
    output wire        eth2_phy_reset_n_o,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);

    wire sys_clk_200m_unbuffered;
    wire sys_clk_200m;

    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("TRUE"),
        .IOSTANDARD("DIFF_SSTL15")
    ) u_sys_clk_ibuf (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .O(sys_clk_200m_unbuffered)
    );

    BUFG u_sys_clk_bufg (
        .I(sys_clk_200m_unbuffered),
        .O(sys_clk_200m)
    );

    logic [15:0] reset_hold_q = 16'h0000;
    always_ff @(posedge sys_clk_200m or negedge rst_n) begin
        if (!rst_n) begin
            reset_hold_q <= 16'h0000;
        end else if (!(&reset_hold_q)) begin
            reset_hold_q <= reset_hold_q + 16'd1;
        end
    end

    wire mig_sys_rst_n = &reset_hold_q;
    wire ui_clk;
    wire ui_clk_sync_rst;
    wire init_calib_complete;

    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    wire app_rdy;
    wire [255:0] app_wdf_data;
    wire app_wdf_end;
    wire [31:0] app_wdf_mask;
    wire app_wdf_wren;
    wire app_wdf_rdy;
    wire [255:0] app_rd_data;
    wire app_rd_data_end;
    wire app_rd_data_valid;
    wire app_sr_active;
    wire app_ref_ack;
    wire app_zq_ack;
    wire [11:0] device_temp;

    wire [2:0] memtest_status;
    wire [27:0] fail_addr;
    wire [2:0] fail_lane;
    wire [31:0] fail_expected;
    wire [31:0] fail_actual;
    wire [2:0] fail_reason;

    mig_7series_0 u_mig (
        .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),
        .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),
        .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt),
        .sys_clk_i(sys_clk_200m),
        .app_addr(app_addr),
        .app_cmd(app_cmd),
        .app_en(app_en),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data),
        .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rdy(app_rdy),
        .app_wdf_rdy(app_wdf_rdy),
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(app_sr_active),
        .app_ref_ack(app_ref_ack),
        .app_zq_ack(app_zq_ack),
        .ui_clk(ui_clk),
        .ui_clk_sync_rst(ui_clk_sync_rst),
        .init_calib_complete(init_calib_complete),
        .device_temp(device_temp),
        .sys_rst(mig_sys_rst_n)
    );

    openrv64_fpga_ddr3_memtest #(
        .ADDR_WIDTH(28),
        .LAST_ADDR(28'h7ff_fff8),
        .TIMEOUT_CYCLES(100_000_000)
    ) u_memtest (
        .clk_i(ui_clk),
        .reset_i(ui_clk_sync_rst),
        .calib_complete_i(init_calib_complete),
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
        .status_o(memtest_status),
        .fail_addr_o(fail_addr),
        .fail_lane_o(fail_lane),
        .fail_expected_o(fail_expected),
        .fail_actual_o(fail_actual),
        .fail_reason_o(fail_reason)
    );

    // DDR3-800 with a 4:1 MIG PHY produces a 100 MHz UI clock.
    openrv64_fpga_ddr3_memtest_uart_status #(
        .CLOCK_HZ(100_000_000),
        .BAUD(115_200),
        .FIRST_DELAY_CYCLES(1_000_000),
        .REPEAT_CYCLES(100_000_000)
    ) u_status (
        .clk_i(ui_clk),
        .reset_i(ui_clk_sync_rst),
        .status_i(memtest_status),
        .fail_addr_i(fail_addr),
        .fail_lane_i(fail_lane),
        .fail_expected_i(fail_expected),
        .fail_actual_i(fail_actual),
        .fail_reason_i(fail_reason),
        .tx_o(uart_tx_o)
    );

    assign eth1_phy_reset_n_o = 1'b0;
    assign eth2_phy_reset_n_o = 1'b0;

    wire unused_mig_outputs = &{
        1'b0,
        app_sr_active,
        app_ref_ack,
        app_zq_ack,
        device_temp
    };

endmodule
