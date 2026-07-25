`timescale 1ns/1ps

// DDR3-1600 channel preset using eight x8 devices.
//
// Physical channel: 64 DQs, BL8 (64-byte native burst), eight banks, and an
// 8 KiB aggregate page.  Timing defaults mirror gem5's DDR3_1600_8x8 preset
// used by the saved Cortex-A53/HPI comparison: tCK=1.25 ns, 13.75 ns
// tRCD/tRP/tCL/tCWL, 35 ns tRAS, 15 ns tWR, 260 ns tRFC, and 7.8 us tREFI.
// The 10 ns frontend and 10 ns backend defaults mirror gem5 MemCtrl's
// controller/PHY pipeline rather than folding that fixed cost into DRAM-array
// timings.
// The common timing engine queues commands and overlaps independent-bank row
// preparation while serializing native bursts on one shared rank data bus.
module openrv64_timing_ddr3 #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer TAG_WIDTH = 8,
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 8,
    parameter integer BURST_CYCLES = 4,
    parameter integer BANK_BITS = 3,
    parameter integer ROW_BYTES = 8192,
    parameter integer DRAM_TCK_PS = 1250,
    parameter integer T_RCD_RD = 11,
    parameter integer T_RCD_WR = 11,
    parameter integer T_RP = 11,
    parameter integer T_RAS = 28,
    parameter integer T_WR = 12,
    parameter integer T_CL = 11,
    parameter integer T_CWL = 11,
    parameter integer T_CCD = 4,
    parameter integer T_RFC = 208,
    parameter integer REFRESH_INTERVAL = 6240,
    parameter integer FRONTEND_LATENCY_PS = 10000,
    parameter integer BACKEND_LATENCY_PS = 10000,
    parameter integer COMMAND_QUEUE_DEPTH = 16
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,
    input  wire                  cmd_valid_i,
    output wire                  cmd_ready_o,
    input  wire                  cmd_write_i,
    input  wire [ADDR_WIDTH-1:0] cmd_addr_i,
    input  wire [15:0]           cmd_bytes_i,
    input  wire [TAG_WIDTH-1:0]  cmd_tag_i,
    output wire                  resp_valid_o,
    output wire [TAG_WIDTH-1:0]  resp_tag_o,
    input  wire                  resp_ready_i
);

    openrv64_timing_dram_banked #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .DQ_WIDTH(DQ_WIDTH),
        .BURST_LENGTH(BURST_LENGTH), .BURST_CYCLES(BURST_CYCLES),
        .BANK_BITS(BANK_BITS), .ROW_BYTES(ROW_BYTES),
        .CONTROLLER_TCK_PS(CONTROLLER_TCK_PS),
        .DRAM_TCK_PS(DRAM_TCK_PS),
        .T_RCD_RD(T_RCD_RD), .T_RCD_WR(T_RCD_WR), .T_RP(T_RP),
        .T_RAS(T_RAS), .T_WR(T_WR),
        .T_CL(T_CL), .T_CWL(T_CWL), .T_CCD(T_CCD),
        .T_RFC(T_RFC), .REFRESH_INTERVAL(REFRESH_INTERVAL),
        .FRONTEND_LATENCY_PS(FRONTEND_LATENCY_PS),
        .BACKEND_LATENCY_PS(BACKEND_LATENCY_PS),
        .COMMAND_QUEUE_DEPTH(COMMAND_QUEUE_DEPTH)
    ) u_timing (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o),
        .cmd_write_i(cmd_write_i), .cmd_addr_i(cmd_addr_i),
        .cmd_bytes_i(cmd_bytes_i), .cmd_tag_i(cmd_tag_i),
        .resp_valid_o(resp_valid_o), .resp_tag_o(resp_tag_o),
        .resp_ready_i(resp_ready_i)
    );

endmodule
