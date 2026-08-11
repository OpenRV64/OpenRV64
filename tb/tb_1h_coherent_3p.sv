`timescale 1ns/1ps

/*
 * One-core structural baseline for the four-port coherent platform.
 *
 * The ICX crossbar, coherent L2 and directory, probe cluster, device path,
 * generic-bus adapter, and timed DDR3 backend remain identical to
 * tb_4h_3p. Only hart 0 is instantiated; hart ports 1-3 are tied off inside
 * tb_4h_3p through CORE_INSTANCES=1.
 */
module tb_1h_coherent_3p #(
    parameter integer MEMORY_LATENCY = 8,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer M_MODE_PREFETCH_ENABLE = 0,
    parameter integer L2_CACHE_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MSHRS = 8,
    parameter integer MEMORY_BYTES = 32'h0032_3000,
    parameter integer ENABLE_BOOT_ROM = 0,
    parameter logic [31:0] OPENSBI_FDT_BASE_LO = 32'h80f0_0000,
    parameter integer DDR3_ENABLE = 1,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer DDR3_MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer DDR3_BANK_ROW_SWIZZLE = 0
);
    wire [31:0] checkpoint_cycle_unused;

    initial
        $display(
            "1H coherent structural baseline: one core, four-port ICX/L2, timed DDR3");

    tb_4h_3p #(
        .CORE_INSTANCES(1),
        .MEMORY_LATENCY(MEMORY_LATENCY),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .M_MODE_PREFETCH_ENABLE(M_MODE_PREFETCH_ENABLE),
        .L2_CACHE_BYTES(L2_CACHE_BYTES),
        .L2_WAYS(L2_WAYS),
        .L2_MSHRS(L2_MSHRS),
        .MEMORY_BYTES(MEMORY_BYTES),
        .ENABLE_BOOT_ROM(ENABLE_BOOT_ROM),
        .OPENSBI_FDT_BASE_LO(OPENSBI_FDT_BASE_LO),
        .DDR3_ENABLE(DDR3_ENABLE),
        .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .DDR3_READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
        .DDR3_WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
        .DDR3_COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
        .DDR3_MAX_BURST_TRAIN_BURSTS(
            DDR3_MAX_BURST_TRAIN_BURSTS),
        .DDR3_BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE)
    ) u_tb (
        .checkpoint_cycle_o(checkpoint_cycle_unused)
    );
endmodule
