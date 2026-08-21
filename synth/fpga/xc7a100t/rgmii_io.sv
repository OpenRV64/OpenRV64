// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Series-7 RGMII I/O cells.  The MAC-facing interface is one byte per clock;
// RGMII carries the low nibble on the rising edge and the high nibble on the
// falling edge.  Control uses the standard DV / (DV xor ER) encoding.

`timescale 1ns/1ps

module openrv64_series7_rgmii_io (
    input  wire       tx_clk_i,
    input  wire       tx_forward_clk_i,
    input  wire [7:0] tx_data_i,
    input  wire       tx_valid_i,
    input  wire       tx_error_i,

    input  wire       rgmii_rx_clk_i,
    input  wire [3:0] rgmii_rxd_i,
    input  wire       rgmii_rx_ctl_i,
    output wire       rgmii_tx_clk_o,
    output wire [3:0] rgmii_txd_o,
    output wire       rgmii_tx_ctl_o,

    output wire       rx_clk_o,
    output wire [7:0] rx_data_o,
    output wire       rx_valid_o,
    output wire       rx_error_o
);

    wire rx_clk;
    BUFG u_rx_clock_bufg (
        .I(rgmii_rx_clk_i),
        .O(rx_clk)
    );
    assign rx_clk_o = rx_clk;

    wire [3:0] rx_rising;
    wire [3:0] rx_falling;
    genvar rx_bit;
    generate
        for (rx_bit = 0; rx_bit < 4; rx_bit = rx_bit + 1) begin : g_rx_data
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0),
                .INIT_Q2(1'b0),
                .SRTYPE("ASYNC")
            ) u_iddr (
                .Q1(rx_rising[rx_bit]),
                .Q2(rx_falling[rx_bit]),
                .C(rx_clk),
                .CE(1'b1),
                .D(rgmii_rxd_i[rx_bit]),
                .R(1'b0),
                .S(1'b0)
            );
        end
    endgenerate

    wire rx_ctl_rising;
    wire rx_ctl_falling;
    IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .INIT_Q1(1'b0),
        .INIT_Q2(1'b0),
        .SRTYPE("ASYNC")
    ) u_rx_ctl_iddr (
        .Q1(rx_ctl_rising),
        .Q2(rx_ctl_falling),
        .C(rx_clk),
        .CE(1'b1),
        .D(rgmii_rx_ctl_i),
        .R(1'b0),
        .S(1'b0)
    );

    assign rx_data_o = {rx_falling, rx_rising};
    assign rx_valid_o = rx_ctl_rising;
    assign rx_error_o = rx_ctl_rising ^ rx_ctl_falling;

    genvar tx_bit;
    generate
        for (tx_bit = 0; tx_bit < 4; tx_bit = tx_bit + 1) begin : g_tx_data
            ODDR #(
                .DDR_CLK_EDGE("SAME_EDGE"),
                .INIT(1'b0),
                .SRTYPE("ASYNC")
            ) u_oddr (
                .Q(rgmii_txd_o[tx_bit]),
                .C(tx_clk_i),
                .CE(1'b1),
                .D1(tx_data_i[tx_bit]),
                .D2(tx_data_i[tx_bit+4]),
                .R(1'b0),
                .S(1'b0)
            );
        end
    endgenerate

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_tx_ctl_oddr (
        .Q(rgmii_tx_ctl_o),
        .C(tx_clk_i),
        .CE(1'b1),
        .D1(tx_valid_i),
        .D2(tx_valid_i ^ tx_error_i),
        .R(1'b0),
        .S(1'b0)
    );

    // At 100 Mb/s a quarter-cycle phase shift places both forwarded-clock
    // edges at the center of their 20 ns data eyes.  This is intentionally a
    // fixed-speed implementation, not a gigabit-capable clock mux.
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_tx_clock_oddr (
        .Q(rgmii_tx_clk_o),
        .C(tx_forward_clk_i),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R(1'b0),
        .S(1'b0)
    );

endmodule
