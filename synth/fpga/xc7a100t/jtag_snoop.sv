// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Small, deliberately non-architectural FPGA debug probe. USER1 supplies a
// raw JTAG data register used to arm memory, PC, or cycle-count triggers. A
// trigger captures a fixed record and raises a dedicated PLIC source. OpenSBI
// then enters at an architectural interrupt boundary and stores its trap frame
// in the machine-mode snapshot BRAM.

`timescale 1ns/1ps

module openrv64_fpga_jtag_snoop #(
    parameter logic [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000
) (
    input  logic        core_clk_i,
    input  logic        core_reset_i,
    input  logic [63:0] debug_pc_i,
    input  logic [31:0] debug_instr_i,
    input  logic [63:0] debug_rs1_data_i,
    input  logic [63:0] debug_rs2_data_i,

    // Indexed readback of the always-clocked DDR bridge cache. The request
    // and acknowledgement are toggles because USER1 and ui_clk are unrelated.
    output logic [9:0]  debug_cache_index_o,
    output logic        debug_cache_req_toggle_o,
    input  logic        debug_cache_ack_toggle_i,
    input  logic [9:0]  debug_cache_result_index_i,
    input  logic        debug_cache_valid_i,
    input  logic [63:0] debug_cache_tag_i,
    input  logic [255:0] debug_cache_data_i,

    // Indexed readback of the machine-mode snapshot BRAM.
    output logic [8:0]  debug_snapshot_index_o,
    output logic        debug_snapshot_req_toggle_o,
    input  logic        debug_snapshot_ack_toggle_i,
    input  logic [63:0] debug_snapshot_data_i,
    input  logic        debug_snapshot_resume_pending_i,
    input  logic        debug_snapshot_trigger_ack_i,

    // Full-word upload/readback port for the executable M-mode debug BRAM.
    output logic [10:0] debug_stub_index_o,
    output logic        debug_stub_write_o,
    output logic        debug_stub_trace_read_o,
    output logic [63:0] debug_stub_wdata_o,
    output logic        debug_stub_req_toggle_o,
    input  logic        debug_stub_ack_toggle_i,
    input  logic [63:0] debug_stub_rdata_i,

    // Indexed readback of the rolling 16 KiB UART transmit capture.
    output logic [10:0] debug_uart_trace_index_o,
    output logic        debug_uart_trace_req_toggle_o,
    input  logic        debug_uart_trace_ack_toggle_i,
    input  logic [255:0] debug_uart_trace_rdata_i,
    input  logic [63:0] debug_uart_trace_byte_count_i,

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

    output logic        debug_irq_o,
    output logic        resume_toggle_o,
    // Toggle transported to the board's 200 MHz reset controller. This
    // restarts MIG calibration and the complete boot flow while preserving
    // the configured FPGA image and JTAG-domain trigger configuration.
    output logic        reset_toggle_o
);

    localparam integer SCAN_BITS = 960;
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
    logic [9:0] cfg_cache_index_jtag_q;
    logic [1:0] cfg_cache_word_jtag_q;
    logic cfg_cache_tag_jtag_q;
    logic [8:0] cfg_snapshot_index_jtag_q;
    logic [10:0] cfg_stub_index_jtag_q;
    logic cfg_stub_write_jtag_q;
    logic cfg_stub_trace_read_jtag_q;
    logic [63:0] cfg_stub_wdata_jtag_q;
    logic [10:0] cfg_uart_trace_index_jtag_q;
    logic [1:0] readback_source_jtag_q;
    logic cache_req_toggle_jtag_q;
    logic snapshot_req_toggle_jtag_q;
    logic stub_req_toggle_jtag_q;
    logic uart_trace_req_toggle_jtag_q;
    logic clear_toggle_jtag_q;
    logic resume_toggle_jtag_q;
    logic reset_toggle_jtag_q;

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
        cfg_cache_index_jtag_q = 10'd0;
        cfg_cache_word_jtag_q = 2'd0;
        cfg_cache_tag_jtag_q = 1'b0;
        cfg_snapshot_index_jtag_q = 9'd0;
        cfg_stub_index_jtag_q = 11'd0;
        cfg_stub_write_jtag_q = 1'b0;
        cfg_stub_trace_read_jtag_q = 1'b0;
        cfg_stub_wdata_jtag_q = 64'd0;
        cfg_uart_trace_index_jtag_q = 11'd0;
        readback_source_jtag_q = 2'd0;
        cache_req_toggle_jtag_q = 1'b0;
        snapshot_req_toggle_jtag_q = 1'b0;
        stub_req_toggle_jtag_q = 1'b0;
        uart_trace_req_toggle_jtag_q = 1'b0;
        clear_toggle_jtag_q = 1'b0;
        resume_toggle_jtag_q = 1'b0;
        reset_toggle_jtag_q = 1'b0;
    end

    // A read shifts zeros in and therefore cannot accidentally execute a
    // command. Only an Update-DR value carrying COMMAND_KEY changes state.
    always_ff @(posedge bscan_update) begin
        if (bscan_sel && (shift_q[31:0] == COMMAND_KEY)) begin
            // Indexed reads must not silently rewrite a live trigger.
            // Trigger state changes only on arm, clear, or resume.
            if (shift_q[32] || shift_q[39] || shift_q[40]) begin
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
            end
            cfg_cache_index_jtag_q <= shift_q[409:400];
            cfg_cache_word_jtag_q <= shift_q[411:410];
            cfg_cache_tag_jtag_q <= shift_q[412];
            cfg_snapshot_index_jtag_q <= shift_q[424:416];
            cfg_stub_index_jtag_q <= shift_q[426:416];
            cfg_uart_trace_index_jtag_q <= shift_q[426:416];
            if (shift_q[41]) begin
                cache_req_toggle_jtag_q <= ~cache_req_toggle_jtag_q;
                readback_source_jtag_q <= 2'd0;
            end
            if (shift_q[42]) begin
                snapshot_req_toggle_jtag_q <=
                    ~snapshot_req_toggle_jtag_q;
                readback_source_jtag_q <= 2'd1;
            end
            if (shift_q[43] || shift_q[44]) begin
            cfg_stub_write_jtag_q <= shift_q[44];
            cfg_stub_trace_read_jtag_q <= shift_q[47];
                cfg_stub_wdata_jtag_q <= shift_q[511:448];
                stub_req_toggle_jtag_q <= ~stub_req_toggle_jtag_q;
                readback_source_jtag_q <= 2'd2;
            end
            if (shift_q[45]) begin
                uart_trace_req_toggle_jtag_q <=
                    ~uart_trace_req_toggle_jtag_q;
                readback_source_jtag_q <= 2'd3;
            end
            if (shift_q[39] || shift_q[40])
                clear_toggle_jtag_q <= ~clear_toggle_jtag_q;
            if (shift_q[39])
                resume_toggle_jtag_q <= ~resume_toggle_jtag_q;
            if (shift_q[46])
                reset_toggle_jtag_q <= ~reset_toggle_jtag_q;
        end
    end

    assign resume_toggle_o = resume_toggle_jtag_q;
    assign reset_toggle_o = reset_toggle_jtag_q;
    assign debug_cache_index_o = cfg_cache_index_jtag_q;
    assign debug_cache_req_toggle_o = cache_req_toggle_jtag_q;
    assign debug_snapshot_index_o = cfg_snapshot_index_jtag_q;
    assign debug_snapshot_req_toggle_o = snapshot_req_toggle_jtag_q;
    assign debug_stub_index_o = cfg_stub_index_jtag_q;
    assign debug_stub_write_o = cfg_stub_write_jtag_q;
    assign debug_stub_trace_read_o = cfg_stub_trace_read_jtag_q;
    assign debug_stub_wdata_o = cfg_stub_wdata_jtag_q;
    assign debug_stub_req_toggle_o = stub_req_toggle_jtag_q;
    assign debug_uart_trace_index_o = cfg_uart_trace_index_jtag_q;
    assign debug_uart_trace_req_toggle_o = uart_trace_req_toggle_jtag_q;

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
    logic [31:0] hit_instr_value_q;
    logic [63:0] hit_mem_addr_q;
    logic [63:0] hit_mem_rdata_q;
    logic [63:0] hit_mem_wdata_q;
    logic [7:0] hit_mem_wstrb_q;
    logic pc_delay_started_q;
    logic [63:0] pc_delay_target_q;

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
    wire pc_address_match =
        ((debug_pc_i & cfg_pc_mask_sync_q) ==
         (cfg_pc_addr_sync_q & cfg_pc_mask_sync_q));
    wire pc_delay_mode = cfg_pc_sync_q && cfg_cycle_enable_sync_q;
    wire pc_trigger = cfg_pc_sync_q && !cfg_cycle_enable_sync_q &&
                      pc_address_match;
    wire absolute_cycle_trigger = cfg_cycle_enable_sync_q &&
        !cfg_pc_sync_q && (cycle_count_q == cfg_cycle_target_sync_q);
    wire delayed_cycle_trigger = pc_delay_started_q &&
        (cycle_count_q == pc_delay_target_q);
    wire cycle_trigger = absolute_cycle_trigger || delayed_cycle_trigger;

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
            hit_instr_value_q <= 32'd0;
            hit_mem_addr_q <= 64'd0;
            hit_mem_rdata_q <= 64'd0;
            hit_mem_wdata_q <= 64'd0;
            hit_mem_wstrb_q <= 8'd0;
            pc_delay_started_q <= 1'b0;
            pc_delay_target_q <= 64'd0;
        end else begin
            cycle_count_q <= cycle_count_q + 64'd1;
            if ((clear_toggle_sync_q != clear_toggle_seen_q) ||
                debug_snapshot_trigger_ack_i) begin
                clear_toggle_seen_q <= clear_toggle_sync_q;
                hit_valid_q <= 1'b0;
                hit_scalar_q <= 1'b0;
                hit_ptw_q <= 1'b0;
                hit_pc_q <= 1'b0;
                hit_cycle_q <= 1'b0;
                hit_write_q <= 1'b0;
                hit_error_q <= 1'b0;
                pc_delay_started_q <= 1'b0;
                pc_delay_target_q <= 64'd0;
            end else begin
                if (!cfg_armed_sync_q || !pc_delay_mode) begin
                    pc_delay_started_q <= 1'b0;
                    pc_delay_target_q <= 64'd0;
                end else if (!pc_delay_started_q && pc_address_match) begin
                    // When PC and cycle matching are enabled together, the
                    // PC is a non-interrupting epoch marker and cycle_target
                    // is a relative delay. This removes reset-to-boot timing
                    // jitter from fine-grained replay samples.
                    pc_delay_started_q <= 1'b1;
                    pc_delay_target_q <= cycle_count_q +
                                         cfg_cycle_target_sync_q;
                end

                if (!hit_valid_q && cfg_armed_sync_q && memory_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_scalar_q <= mem_scalar_i;
                    hit_ptw_q <= !mem_scalar_i;
                    hit_write_q <= mem_write_i;
                    hit_error_q <= mem_error_i;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_instr_value_q <= debug_instr_i;
                    hit_mem_addr_q <= mem_phys_addr;
                    hit_mem_rdata_q <= mem_rdata_i;
                    hit_mem_wdata_q <= mem_wdata_i;
                    hit_mem_wstrb_q <= mem_wstrb_i;
                end else if (!hit_valid_q && cfg_armed_sync_q &&
                             pc_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_pc_q <= 1'b1;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_instr_value_q <= debug_instr_i;
                    hit_mem_addr_q <= 64'd0;
                    // For PC triggers these existing status words carry the
                    // exact forwarded source operands used by the matching
                    // WB instruction. The registered debug PC/instruction and
                    // operand probes are captured together in the core.
                    hit_mem_rdata_q <= debug_rs1_data_i;
                    hit_mem_wdata_q <= debug_rs2_data_i;
                    hit_mem_wstrb_q <= 8'd0;
                end else if (!hit_valid_q && cfg_armed_sync_q &&
                             cycle_trigger) begin
                    hit_valid_q <= 1'b1;
                    hit_cycle_q <= 1'b1;
                    hit_cycle_count_q <= cycle_count_q;
                    hit_pc_value_q <= debug_pc_i;
                    hit_instr_value_q <= debug_instr_i;
                    hit_mem_addr_q <= 64'd0;
                    hit_mem_rdata_q <= 64'd0;
                    hit_mem_wdata_q <= 64'd0;
                    hit_mem_wstrb_q <= 8'd0;
                end
            end
        end
    end

    assign debug_irq_o = hit_valid_q;

    wire [63:0] selected_cache_word = cfg_cache_tag_jtag_q ?
        debug_cache_tag_i :
        debug_cache_data_i[cfg_cache_word_jtag_q*64 +: 64];
    wire selected_read_req_toggle = (readback_source_jtag_q == 2'd3) ?
        uart_trace_req_toggle_jtag_q :
        ((readback_source_jtag_q == 2'd2) ? stub_req_toggle_jtag_q :
         ((readback_source_jtag_q == 2'd1) ?
          snapshot_req_toggle_jtag_q : cache_req_toggle_jtag_q));
    wire selected_read_ack_toggle = (readback_source_jtag_q == 2'd3) ?
        debug_uart_trace_ack_toggle_i :
        ((readback_source_jtag_q == 2'd2) ? debug_stub_ack_toggle_i :
         ((readback_source_jtag_q == 2'd1) ?
          debug_snapshot_ack_toggle_i : debug_cache_ack_toggle_i));
    wire [63:0] selected_read_data =
        (readback_source_jtag_q == 2'd3) ?
        debug_uart_trace_rdata_i[cfg_cache_word_jtag_q*64 +: 64] :
        ((readback_source_jtag_q == 2'd2) ? debug_stub_rdata_i :
         ((readback_source_jtag_q == 2'd1) ?
          debug_snapshot_data_i : selected_cache_word));
    wire [10:0] selected_read_index =
        (readback_source_jtag_q == 2'd3) ? cfg_uart_trace_index_jtag_q :
        ((readback_source_jtag_q == 2'd2) ? cfg_stub_index_jtag_q :
         ((readback_source_jtag_q == 2'd1) ?
          {2'd0, cfg_snapshot_index_jtag_q} :
          {1'b0, debug_cache_result_index_i}));

    always_comb begin
        status_value = '0;
        status_value[31:0] = COMMAND_KEY;
        status_value[39:32] = 8'd17;
        status_value[40] = cfg_armed_jtag_q;
        status_value[41] = debug_snapshot_resume_pending_i;
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
        status_value[55] = cfg_cache_tag_jtag_q;
        status_value[57:56] = cfg_cache_word_jtag_q;
        status_value[59] = pc_delay_started_q;
        status_value[127:64] = cfg_mem_addr_jtag_q;
        status_value[191:128] = cfg_mem_mask_jtag_q;
        status_value[255:192] = cfg_pc_addr_jtag_q;
        status_value[319:256] = cfg_pc_mask_jtag_q;
        status_value[383:320] = cfg_cycle_target_jtag_q;
        // This region is either one 256-bit UART burst or the four 64-bit
        // trigger fields. Express it as an exclusive mux rather than assigning
        // the four words and procedurally overriding the complete slice. Yosys
        // preserved only the first override word in physical v8-v11 images.
        if (readback_source_jtag_q == 2'd3) begin
            // Keep these as four explicit word assignments. The Yosys/EDIF
            // flow physically dropped words 1..3 of the equivalent 256-bit
            // assignment even though RTL simulation and the source vector
            // itself were correct.
            status_value[447:384] = debug_uart_trace_rdata_i[63:0];
            status_value[511:448] = debug_uart_trace_rdata_i[127:64];
            status_value[575:512] = debug_uart_trace_rdata_i[191:128];
            status_value[639:576] = debug_uart_trace_rdata_i[255:192];
        end else begin
            status_value[447:384] = hit_cycle_count_q;
            status_value[511:448] = hit_pc_value_q;
            status_value[575:512] = hit_mem_addr_q;
            status_value[639:576] = hit_mem_rdata_q;
        end
        status_value[703:640] = hit_mem_wdata_q;
        status_value[711:704] = hit_mem_wstrb_q;
        status_value[783:720] = cycle_count_q;
        status_value[815:784] = hit_instr_value_q;
        status_value[817:816] = readback_source_jtag_q;
        status_value[818] = selected_read_req_toggle;
        status_value[819] = selected_read_ack_toggle;
        status_value[820] = debug_cache_valid_i;
        status_value[831:821] = selected_read_index;
        status_value[895:832] = selected_read_data;
        status_value[959:896] = (readback_source_jtag_q == 2'd3) ?
            debug_uart_trace_byte_count_i : 64'd0;
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
