// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// MYD-J7A100T MIG-only DDR3 calibration test with UART status.

`timescale 1ns/1ps

module openrv64_myd_j7a100t_ddr3_calibration_top (
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

    // Hold MIG in active-low reset for 65,535 input-clock cycles after FPGA
    // configuration or a board reset.  Assertion remains asynchronous;
    // release is synchronous to the stable 200 MHz board clock.
    logic [15:0] reset_hold_q = 16'h0000;
    always_ff @(posedge sys_clk_200m or negedge rst_n) begin
        if (!rst_n) begin
            reset_hold_q <= 16'h0000;
        end else if (!(&reset_hold_q)) begin
            reset_hold_q <= reset_hold_q + 16'd1;
        end
    end

    wire local_reset = !(&reset_hold_q);
    wire mig_sys_rst_n = &reset_hold_q;

    wire ui_clk;
    wire ui_clk_sync_rst;
    wire init_calib_complete;
    wire [255:0] app_rd_data;
    wire app_rd_data_end;
    wire app_rd_data_valid;
    wire app_rdy;
    wire app_wdf_rdy;
    wire app_sr_active;
    wire app_ref_ack;
    wire app_zq_ack;
    wire [11:0] device_temp;

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
        .app_addr(28'h0000000),
        .app_cmd(3'b000),
        .app_en(1'b0),
        .app_wdf_data(256'h0),
        .app_wdf_end(1'b0),
        .app_wdf_mask(32'hffff_ffff),
        .app_wdf_wren(1'b0),
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

    // init_calib_complete is a persistent status generated in the MIG UI
    // clock domain.  Synchronize it before reporting from the 200 MHz domain.
    (* ASYNC_REG = "TRUE" *) logic [1:0] calib_sync_q;
    always_ff @(posedge sys_clk_200m) begin
        if (local_reset) begin
            calib_sync_q <= 2'b00;
        end else begin
            calib_sync_q <= {calib_sync_q[0], init_calib_complete};
        end
    end

    openrv64_fpga_ddr3_uart_status #(
        .CLOCK_HZ(200_000_000),
        .BAUD(115_200),
        .FIRST_DELAY_CYCLES(20_000_000),
        .REPEAT_CYCLES(200_000_000)
    ) u_status (
        .clk_i(sys_clk_200m),
        .reset_i(local_reset),
        .calib_complete_i(calib_sync_q[1]),
        .tx_o(uart_tx_o)
    );

    // Keep both unrelated Ethernet PHYs quiescent during DDR bring-up.
    assign eth1_phy_reset_n_o = 1'b0;
    assign eth2_phy_reset_n_o = 1'b0;

    wire unused_mig_outputs = &{
        1'b0,
        ui_clk,
        ui_clk_sync_rst,
        app_rd_data,
        app_rd_data_end,
        app_rd_data_valid,
        app_rdy,
        app_wdf_rdy,
        app_sr_active,
        app_ref_ack,
        app_zq_ack,
        device_temp
    };

endmodule
