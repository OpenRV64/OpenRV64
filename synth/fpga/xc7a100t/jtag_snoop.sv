// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Small, deliberately non-architectural FPGA debug probe. USER1 supplies a
// raw JTAG data register used to arm memory, PC, or cycle-count triggers. A
// trigger captures a fixed record and asks the board wrapper to stop the SoC
// clock. This is not a RISC-V Debug Module and does not claim precise debug
// entry: the captured trigger is exact, but the clock buffer can stop a small
// number of cycles later.

`timescale 1ns/1ps

module openrv64_fpga_jtag_snoop #(
    parameter logic [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000
) (
    input  logic        core_clk_i,
    input  logic        core_reset_i,
    input  logic        clock_halted_i,
    input  logic [63:0] debug_pc_i,

    // Completed request on the scalar port after scalar/PTW arbitration. This
    // point observes both DDR-cache hits and misses, unlike the native MIG
    // command interface.
    input  logic        mem_valid_i,
    input  logic        mem_ready_i,
    input  logic        mem_write_i,
    input  logic [63:0] mem_addr_i,
    input  logic [63:0] mem_wdata_i,
    input  logic [7:0]  mem_wstrb_i,
    input  logic [63:0] mem_rdata_i,
    input  logic        mem_error_i,
    input  logic        mem_scalar_i,

    output logic        halt_request_o,
    output logic        resume_toggle_o
);

    localparam integer SCAN_BITS = 832;
    localparam logic [31:0] COMMAND_KEY = 32'h4f52_5636; // "ORV6"

    logic bscan_capture;
    logic bscan_drck;
    logic bscan_reset;
    logic bscan_runtest;
    logic bscan_sel;
    logic bscan_shift;
    logic bscan_tck;
    logic bscan_tdi;
    logic bscan_tms;
    logic bscan_update;
    logic bscan_tdo;

    BSCANE2 #(
        .JTAG_CHAIN(1)
    ) u_bscan (
        .CAPTURE(bscan_capture),
        .DRCK(bscan_drck),
        .RESET(bscan_reset),
        .RUNTEST(bscan_runtest),
        .SEL(bscan_sel),
        .SHIFT(bscan_shift),
        .TCK(bscan_tck),
        .TDI(bscan_tdi),
        .TMS(bscan_tms),
        .UPDATE(bscan_update),
        .TDO(bscan_tdo)
    );

    logic [SCAN_BITS-1:0] shift_q;
    logic [SCAN_BITS-1:0] status_value;

    logic cfg_armed_jtag_q;
    logic cfg_read_jtag_q;
    logic cfg_write_jtag_q;
    logic cfg_scalar_jtag_q;
    logic cfg_ptw_jtag_q;
    logic cfg_pc_jtag_q;
    logic cfg_cycle_enable_jtag_q;
    logic [63:0] cfg_mem_addr_jtag_q;
    logic [63:0] cfg_mem_mask_jtag_q;
    logic [63:0] cfg_pc_addr_jtag_q;
    logic [63:0] cfg_pc_mask_jtag_q;
    logic [63:0] cfg_cycle_target_jtag_q;
    logic clear_toggle_jtag_q;
    logic resume_toggle_jtag_q;

    // XSDB commonly drives the TAP through Test-Logic-Reset before a raw
    // scan. BSCANE2 RESET therefore cannot reset this persistent state: doing
    // so would make a status read erase the command it is meant to inspect.
    // The FPGA configuration GSR applies these initial values instead.
    initial begin
        cfg_armed_jtag_q = 1'b0;
        cfg_read_jtag_q = 1'b1;
        cfg_write_jtag_q = 1'b0;
        cfg_scalar_jtag_q = 1'b1;
        cfg_ptw_jtag_q = 1'b1;
        cfg_pc_jtag_q = 1'b0;
        cfg_cycle_enable_jtag_q = 1'b0;
        cfg_mem_addr_jtag_q = 64'd0;
        cfg_mem_mask_jtag_q = 64'hffff_ffff_ffff_ffff;
        cfg_pc_addr_jtag_q = 64'd0;
        cfg_pc_mask_jtag_q = 64'hffff_ffff_ffff_ffff;
        cfg_cycle_target_jtag_q = 64'd0;
        clear_toggle_jtag_q = 1'b0;
        resume_toggle_jtag_q = 1'b0;
    end

    // A read shifts zeros in and therefore cannot accidentally execute a
    // command. Only an Update-DR value carrying COMMAND_KEY changes state.
    always_ff @(posedge bscan_update) begin
        if (bscan_sel && (shift_q[31:0] == COMMAND_KEY)) begin
            cfg_armed_jtag_q <= shift_q[32];
            cfg_read_jtag_q <= shift_q[33];
            cfg_write_jtag_q <= shift_q[34];
            cfg_scalar_jtag_q <= shift_q[35];
            cfg_ptw_jtag_q <= shift_q[36];
            cfg_pc_jtag_q <= shift_q[37];
            cfg_cycle_enable_jtag_q <= shift_q[38];
            cfg_mem_addr_jtag_q <= shift_q[127:64];
            cfg_mem_mask_jtag_q <= shift_q[191:128];
            cfg_pc_addr_jtag_q <= shift_q[255:192];
            cfg_pc_mask_jtag_q <= shift_q[319:256];
            cfg_cycle_target_jtag_q <= shift_q[383:320];
            if (shift_q[39] || shift_q[40])
                clear_toggle_jtag_q <= ~clear_toggle_jtag_q;
            if (shift_q[39])
                resume_toggle_jtag_q <= ~resume_toggle_jtag_q;
        end
    end

    assign resume_toggle_o = resume_toggle_jtag_q;

    (* ASYNC_REG = "TRUE" *) logic cfg_armed_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_armed_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_read_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_read_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_write_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_write_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_scalar_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_scalar_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_ptw_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_ptw_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_pc_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_pc_sync_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_cycle_enable_meta_q;
    (* ASYNC_REG = "TRUE" *) logic cfg_cycle_enable_sync_q;
    (* ASYNC_REG = "TRUE" *) logic clear_toggle_meta_q;
    (* ASYNC_REG = "TRUE" *) logic clear_toggle_sync_q;

    logic [63:0] cfg_mem_addr_meta_q;
    logic [63:0] cfg_mem_addr_sync_q;
    logic [63:0] cfg_mem_mask_meta_q;
    logic [63:0] cfg_mem_mask_sync_q;
    logic [63:0] cfg_pc_addr_meta_q;
    logic [63:0] cfg_pc_addr_sync_q;
    logic [63:0] cfg_pc_mask_meta_q;
    logic [63:0] cfg_pc_mask_sync_q;
    logic [63:0] cfg_cycle_target_meta_q;
    logic [63:0] cfg_cycle_target_sync_q;

    logic clear_toggle_seen_q;
    logic [63:0] cycle_count_q;
    logic hit_valid_q;
    logic hit_scalar_q;
    logic hit_ptw_q;
    logic hit_pc_q;
    logic hit_cycle_q;
    logic hit_write_q;
    logic hit_error_q;
    logic [63:0] hit_cycle_count_q;
    logic [63:0] hit_pc_value_q;
    logic [63:0] hit_mem_addr_q;
    logic [63:0] hit_mem_rdata_q;
    logic [63:0] hit_mem_wdata_q;
    logic [7:0] hit_mem_wstrb_q;

    wire [63:0] mem_phys_addr = MEMORY_BASE + mem_addr_i;
    wire mem_access = mem_valid_i && mem_ready_i;
    wire mem_direction_match = mem_write_i ? cfg_write_sync_q :
                                                    cfg_read_sync_q;
    wire mem_source_match = mem_scalar_i ? cfg_scalar_sync_q :
                                                  cfg_ptw_sync_q;
    wire mem_address_match =
        ((mem_phys_addr & cfg_mem_mask_sync_q) ==
         (cfg_mem_addr_sync_q & cfg_mem_mask_sync_q));
    wire memory_trigger = mem_access && mem_direction_match &&
                          mem_source_match && mem_address_match;
    wire pc_trigger = cfg_pc_sync_q &&
        ((debug_pc_i & cfg_pc_mask_sync_q) ==
         (cfg_pc_addr_sync_q & cfg_pc_mask_sync_q));
    wire cycle_trigger = cfg_cycle_enable_sync_q &&
                         (cycle_count_q == cfg_cycle_target_sync_q);

    always_ff @(posedge core_clk_i) begin
        if (core_reset_i) begin
            cfg_armed_meta_q <= 1'b0;
            cfg_armed_sync_q <= 1'b0;
            cfg_read_meta_q <= 1'b0;
            cfg_read_sync_q <= 1'b0;
            cfg_write_meta_q <= 1'b0;
            cfg_write_sync_q <= 1'b0;
            cfg_scalar_meta_q <= 1'b0;
            cfg_scalar_sync_q <= 1'b0;
            cfg_ptw_meta_q <= 1'b0;
            cfg_ptw_sync_q <= 1'b0;
            cfg_pc_meta_q <= 1'b0;
            cfg_pc_sync_q <= 1'b0;
            cfg_cycle_enable_meta_q <= 1'b0;
            cfg_cycle_enable_sync_q <= 1'b0;
            clear_toggle_meta_q <= 1'b0;
            clear_toggle_sync_q <= 1'b0;
            cfg_mem_addr_meta_q <= 64'd0;
            cfg_mem_addr_sync_q <= 64'd0;
            cfg_mem_mask_meta_q <= 64'd0;
            cfg_mem_mask_sync_q <= 64'd0;
            cfg_pc_addr_meta_q <= 64'd0;
            cfg_pc_addr_sync_q <= 64'd0;
            cfg_pc_mask_meta_q <= 64'd0;
            cfg_pc_mask_sync_q <= 64'd0;
            cfg_cycle_target_meta_q <= 64'd0;
            cfg_cycle_target_sync_q <= 64'd0;
        end else begin
            cfg_armed_meta_q <= cfg_armed_jtag_q;
            cfg_armed_sync_q <= cfg_armed_meta_q;
            cfg_read_meta_q <= cfg_read_jtag_q;
            cfg_read_sync_q <= cfg_read_meta_q;
            cfg_write_meta_q <= cfg_write_jtag_q;
            cfg_write_sync_q <= cfg_write_meta_q;
            cfg_scalar_meta_q <= cfg_scalar_jtag_q;
            cfg_scalar_sync_q <= cfg_scalar_meta_q;
            cfg_ptw_meta_q <= cfg_ptw_jtag_q;
            cfg_ptw_sync_q <= cfg_ptw_meta_q;
            cfg_pc_meta_q <= cfg_pc_jtag_q;
            cfg_pc_sync_q <= cfg_pc_meta_q;
            cfg_cycle_enable_meta_q <= cfg_cycle_enable_jtag_q;
            cfg_cycle_enable_sync_q <= cfg_cycle_enable_meta_q;
            clear_toggle_meta_q <= clear_toggle_jtag_q;
            clear_toggle_sync_q <= clear_toggle_meta_q;
            cfg_mem_addr_meta_q <= cfg_mem_addr_jtag_q;
            cfg_mem_addr_sync_q <= cfg_mem_addr_meta_q;
            cfg_mem_mask_meta_q <= cfg_mem_mask_jtag_q;
            cfg_mem_mask_sync_q <= cfg_mem_mask_meta_q;
            cfg_pc_addr_meta_q <= cfg_pc_addr_jtag_q;
            cfg_pc_addr_sync_q <= cfg_pc_addr_meta_q;
            cfg_pc_mask_meta_q <= cfg_pc_mask_jtag_q;
            cfg_pc_mask_sync_q <= cfg_pc_mask_meta_q;
            cfg_cycle_target_meta_q <= cfg_cycle_target_jtag_q;
            cfg_cycle_target_sync_q <= cfg_cycle_target_meta_q;
        end
    end

    always_ff @(posedge core_clk_i) begin
        if (core_reset_i) begin
            clear_toggle_seen_q <= 1'b0;
            cycle_count_q <= 64'd0;
            hit_valid_q <= 1'b0;
            hit_scalar_q <= 1'b0;
            hit_ptw_q <= 1'b0;
            hit_pc_q <= 1'b0;
            hit_cycle_q <= 1'b0;
            hit_write_q <= 1'b0;
            hit_error_q <= 1'b0;
            hit_cycle_count_q <= 64'd0;
            hit_pc_value_q <= 64'd0;
            hit_mem_addr_q <= 64'd0;
            hit_mem_rdata_q <= 64'd0;
            hit_mem_wdata_q <= 64'd0;
            hit_mem_wstrb_q <= 8'd0;
        end else begin
            cycle_count_q <= cycle_count_q + 64'd1;
            if (clear_toggle_sync_q != clear_toggle_seen_q) begin
                clear_toggle_seen_q <= clear_toggle_sync_q;
                hit_valid_q <= 1'b0;
                hit_scalar_q <= 1'b0;
                hit_ptw_q <= 1'b0;
                hit_pc_q <= 1'b0;
                hit_cycle_q <= 1'b0;
                hit_write_q <= 1'b0;
                hit_error_q <= 1'b0;
            end else if (!hit_valid_q && cfg_armed_sync_q) begin
                if (memory_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_scalar_q <= mem_scalar_i;
                    hit_ptw_q <= !mem_scalar_i;
                    hit_write_q <= mem_write_i;
                    hit_error_q <= mem_error_i;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_mem_addr_q <= mem_phys_addr;
                    hit_mem_rdata_q <= mem_rdata_i;
                    hit_mem_wdata_q <= mem_wdata_i;
                    hit_mem_wstrb_q <= mem_wstrb_i;
                end else if (pc_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_pc_q <= 1'b1;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_mem_addr_q <= 64'd0;
                    hit_mem_rdata_q <= 64'd0;
                    hit_mem_wdata_q <= 64'd0;
                    hit_mem_wstrb_q <= 8'd0;
                end else if (cycle_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_cycle_q <= 1'b1;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_mem_addr_q <= 64'd0;
                    hit_mem_rdata_q <= 64'd0;
                    hit_mem_wdata_q <= 64'd0;
                    hit_mem_wstrb_q <= 8'd0;
                end
            end
        end
    end

    assign halt_request_o = hit_valid_q;

    always_comb begin
        status_value = '0;
        status_value[31:0] = COMMAND_KEY;
        status_value[39:32] = 8'd1;
        status_value[40] = cfg_armed_jtag_q;
        status_value[41] = clock_halted_i;
        status_value[42] = hit_valid_q;
        status_value[43] = hit_scalar_q;
        status_value[44] = hit_ptw_q;
        status_value[45] = hit_pc_q;
        status_value[46] = hit_cycle_q;
        status_value[47] = hit_write_q;
        status_value[48] = hit_error_q;
        status_value[49] = cfg_read_jtag_q;
        status_value[50] = cfg_write_jtag_q;
        status_value[51] = cfg_scalar_jtag_q;
        status_value[52] = cfg_ptw_jtag_q;
        status_value[53] = cfg_pc_jtag_q;
        status_value[54] = cfg_cycle_enable_jtag_q;
        status_value[127:64] = cfg_mem_addr_jtag_q;
        status_value[191:128] = cfg_mem_mask_jtag_q;
        status_value[255:192] = cfg_pc_addr_jtag_q;
        status_value[319:256] = cfg_pc_mask_jtag_q;
        status_value[383:320] = cfg_cycle_target_jtag_q;
        status_value[447:384] = hit_cycle_count_q;
        status_value[511:448] = hit_pc_value_q;
        status_value[575:512] = hit_mem_addr_q;
        status_value[639:576] = hit_mem_rdata_q;
        status_value[703:640] = hit_mem_wdata_q;
        status_value[711:704] = hit_mem_wstrb_q;
        status_value[783:720] = cycle_count_q;
    end

    always_ff @(posedge bscan_drck) begin
        if (bscan_sel) begin
            if (bscan_capture)
                shift_q <= status_value;
            else if (bscan_shift)
                shift_q <= {bscan_tdi, shift_q[SCAN_BITS-1:1]};
        end
    end

    assign bscan_tdo = shift_q[0];

    wire unused_bscan = &{1'b0, bscan_reset, bscan_runtest, bscan_tck,
                          bscan_tms};

endmodule
