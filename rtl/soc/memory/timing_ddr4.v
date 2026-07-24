`timescale 1ns/1ps

// DDR4-3200 channel preset using eight x8 devices.
//
// Physical channel: 64 DQs, BL8 (64-byte native burst), 16 banks, 8 KiB
// aggregate page.  Timing defaults follow the DRAMsim3
// DDR4_8Gb_x8_3200 configuration; CONTROLLER_TCK_PS converts them to the
// clock domain driving this behavioral fixture.
module openrv64_timing_ddr4 #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 8,
    parameter integer BURST_CYCLES = 4,
    parameter integer BANK_BITS = 4,
    parameter integer ROW_BYTES = 8192,
    parameter integer DRAM_TCK_PS = 625,
    parameter integer T_RCD_RD = 22,
    parameter integer T_RCD_WR = 22,
    parameter integer T_RP = 22,
    parameter integer T_RAS = 52,
    parameter integer T_WR = 24,
    parameter integer T_CL = 22,
    parameter integer T_CWL = 16,
    parameter integer T_CCD = 8,
    parameter integer T_RFC = 560,
    parameter integer REFRESH_INTERVAL = 12480
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,
    input  wire                  cmd_valid_i,
    output wire                  cmd_ready_o,
    input  wire                  cmd_write_i,
    input  wire [ADDR_WIDTH-1:0] cmd_addr_i,
    input  wire [15:0]           cmd_bytes_i,
    output wire                  resp_valid_o,
    input  wire                  resp_ready_i
);

    openrv64_timing_dram #(
        .ADDR_WIDTH(ADDR_WIDTH), .DQ_WIDTH(DQ_WIDTH),
        .BURST_LENGTH(BURST_LENGTH), .BURST_CYCLES(BURST_CYCLES),
        .BANK_BITS(BANK_BITS), .ROW_BYTES(ROW_BYTES),
        .CONTROLLER_TCK_PS(CONTROLLER_TCK_PS),
        .DRAM_TCK_PS(DRAM_TCK_PS),
        .T_RCD_RD(T_RCD_RD), .T_RCD_WR(T_RCD_WR), .T_RP(T_RP),
        .T_RAS(T_RAS), .T_WR(T_WR),
        .T_CL(T_CL), .T_CWL(T_CWL), .T_CCD(T_CCD),
        .T_RFC(T_RFC), .REFRESH_INTERVAL(REFRESH_INTERVAL)
    ) u_timing (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o),
        .cmd_write_i(cmd_write_i), .cmd_addr_i(cmd_addr_i),
        .cmd_bytes_i(cmd_bytes_i),
        .resp_valid_o(resp_valid_o), .resp_ready_i(resp_ready_i)
    );

endmodule
