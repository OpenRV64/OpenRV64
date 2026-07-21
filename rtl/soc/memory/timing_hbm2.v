`timescale 1ns/1ps

// HBM2 pseudo-channel preset.
//
// This is one 64-DQ pseudo-channel: BL4 transfers 32 bytes in two clocks, with
// 16 banks and a 1 KiB page.  Two pseudo-channels share each 128-bit HBM2
// channel and eight physical channels form a stack.  Command timing follows
// the DRAMsim3 HBM2_4Gb_x128 preset, applied at pseudo-channel granularity.
module openrv64_timing_hbm2 #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 4,
    parameter integer BURST_CYCLES = 2,
    parameter integer BANK_BITS = 4,
    parameter integer ROW_BYTES = 1024,
    parameter integer DRAM_TCK_PS = 1000,
    parameter integer T_RCD_RD = 14,
    parameter integer T_RCD_WR = 14,
    parameter integer T_RP = 14,
    parameter integer T_RAS = 34,
    parameter integer T_WR = 16,
    parameter integer T_CL = 14,
    parameter integer T_CWL = 4,
    parameter integer T_CCD = 2,
    parameter integer T_RFC = 260,
    parameter integer REFRESH_INTERVAL = 3900
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,
    input  wire                  cmd_valid_i,
    output wire                  cmd_ready_o,
    input  wire                  cmd_write_i,
    input  wire [ADDR_WIDTH-1:0] cmd_addr_i,
    input  wire [7:0]            cmd_bytes_i,
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
