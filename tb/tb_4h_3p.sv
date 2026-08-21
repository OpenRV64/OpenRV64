`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"
`include "complex/bus/defs.v"

/*
 * Four full three-pipe cores behind one coherent ICX home and shared L2.
 *
 * The normal four-hart workloads may use either a bounded-latency 512-bit
 * memory or the production-width 512-to-256-bit generic-bus adapter followed
 * by the timed DDR3 endpoint.  The OpenSBI modes additionally route L2 device
 * bypasses to one shared CLINT, PLIC, and UART. +opensbi_held holds harts 1-3
 * in reset; +opensbi_smp releases all four and checks that the secondary harts
 * retire the build-derived OpenSBI HSM WFI instruction.
 *
 * Plusargs select the original private-root image, a shared Sv39 address
 * space, or a shared physical image running S-mode with satp Bare.
 * Shared-space workloads use mhartid-indexed private pages; the atomic
 * workload additionally contends on one common LR/SC word.  Those finite
 * workloads remain below the Linux/platform boundary.  Coherence transaction
 * state is carried by the shared L2 MSHRs, so independent lines may progress
 * concurrently while each line remains ordered.
 */
module tb_4h_3p #(
    parameter integer CORE_INSTANCES = 4,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer MEMORY_LATENCY = 8,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer M_MODE_PREFETCH_ENABLE = 0,
    parameter integer FETCH_CAROUSEL = 1,
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 1,
    parameter integer FETCH_ALT_PAIR_STACK_DEPTH = 2,
    parameter integer L1D_SYNC_TAG_LOOKUP = 1,
    parameter integer L1D_SYNC_STORE_EXTENSION = 1,
    parameter integer L2_CACHE_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MSHRS = 8,
    parameter integer MEMORY_BYTES = 32'h0032_3000,
    parameter integer ENABLE_BOOT_ROM = 0,
    parameter integer ENABLE_RV64ZBB = 1,
    parameter integer ENABLE_WFI_SLEEP = 1,
    parameter integer FENCE_L2_ACK_ENABLE = 1,
    parameter integer SC_EXCLUSIVE_RETAIN_ENABLE = 1,
    parameter logic [31:0] OPENSBI_FDT_BASE_LO = 32'h80f0_0000,
    parameter integer DDR3_ENABLE = 0,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer DDR3_MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer DDR3_BANK_ROW_SWIZZLE = 0
) (
    output wire [31:0] checkpoint_cycle_o
`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
    ,
    input  wire        checkpoint_clk_i
`endif
);
    localparam integer NUM_HARTS = 4;
    localparam [63:0] PHYSICAL_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] VIRTUAL_BASE = 64'h0000_0000_4000_0000;
    localparam [63:0] PREFIX_STRIDE = 64'h0000_0000_0010_0000;
    localparam integer MEMORY_WORDS = MEMORY_BYTES / 64;
    localparam integer RETIRE_RESULT_INSTR_LSB = 233;
    localparam integer RETIRE_RESULT_PC_LSB = 329;
    localparam [63:0] ROM_BASE = 64'h0000_0000_0000_1000;
    localparam [63:0] ROM_SIZE = 64'h0000_0000_0000_1000;
    localparam [63:0] CLINT_BASE = 64'h0000_0000_0200_0000;
    localparam [63:0] CLINT_SIZE = 64'h0000_0000_0001_0000;
    localparam [63:0] PLIC_BASE = 64'h0000_0000_0c00_0000;
    localparam [63:0] PLIC_SIZE = 64'h0000_0000_0400_0000;
    localparam [63:0] UART_BASE = 64'h0000_0000_1000_0000;
    localparam [63:0] UART_SIZE = 64'h0000_0000_0000_0100;
    localparam [63:0] OPENSBI_FDT_BASE =
        {32'd0, OPENSBI_FDT_BASE_LO};
    localparam [63:0] OPENSBI_MAGIC_ADDR =
        64'h0000_0000_80e0_0000;
    localparam [63:0] OPENSBI_MAGIC_VALUE =
        64'h5342_4950_4153_5301;
    localparam [63:0] HART_START_TEST_BASE =
        64'h0000_0000_80d0_0000;
    localparam [63:0] HART_START_MAILBOX_BASE =
        HART_START_TEST_BASE + 64'h0200;
    localparam [63:0] HART_START_COUNTER_ADDR =
        HART_START_TEST_BASE + 64'h1000;
    localparam [63:0] HART_START_FAILURE_ADDR =
        64'h0000_0000_80e0_0008;
    localparam [63:0] HART_START_SIGNATURE_BASE =
        64'h4841_5254_0000_0000;
    localparam [63:0] HART_START_COMMAND_BASE =
        64'h434d_4400_0000_0100;
    localparam integer HART_START_ATOMIC_ITERATIONS = 64;
    localparam integer OPENSBI_TRAMPOLINE_WORDS = 32'h0001_0000 / 8;
    localparam integer OPENSBI_FIRMWARE_WORDS = 32'h0010_0000 / 8;
    localparam integer OPENSBI_PAYLOAD_WORDS = 32'h0001_0000 / 8;
    localparam integer OPENSBI_MAX_PAYLOAD_WORDS = 32'h0100_0000 / 8;
    localparam integer OPENSBI_FDT_WORDS = 32'h0001_0000 / 8;
    localparam integer HOME_ID_STRIDE =
        1 << (`OPENRV64_ICX_SOURCE_ID_WIDTH +
              `OPENRV64_ICX_TXN_ID_WIDTH);
    localparam integer HOME_IDENTITIES = NUM_HARTS * HOME_ID_STRIDE;

    logic clk;
    logic rst_n;
    wire [NUM_HARTS-1:0] hart_clk;
    wire [NUM_HARTS-1:0] hart_rst_n;
    wire [NUM_HARTS-1:0] clint_msip;
    wire [NUM_HARTS-1:0] clint_mtip;
    wire [NUM_HARTS-1:0] plic_seip;
    wire [63:0] clint_mtime;
    wire uart_irq;
    integer opensbi_held;
    integer gate_held_hart_clocks;
    integer opensbi_smp;
    integer opensbi_hart_start;
    integer opensbi_active_harts;
    integer opensbi_mode;
    integer linux_mode;
    integer require_smp_threads;
    integer pc_trace_fd;
    integer pc_trace_mask;
    string pc_trace_path;
    logic [NUM_HARTS-1:0] opensbi_active_hart_mask;
    logic [63:0] opensbi_hsm_wfi_pc;
    logic [NUM_HARTS-1:0] opensbi_hsm_wfi_seen;
    logic [NUM_HARTS-1:0] opensbi_hsm_sleep_seen;
    logic [NUM_HARTS-1:0] opensbi_s_mode_hart_seen;
    wire [NUM_HARTS-1:0] opensbi_active_secondary_mask =
        opensbi_active_hart_mask &
        {{(NUM_HARTS-1){1'b1}}, 1'b0};

    wire [NUM_HARTS-1:0] hart_req_valid;
    wire [NUM_HARTS-1:0] hart_req_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        hart_req_hart_id;
    wire [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        hart_req_txn_id;
    wire [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        hart_req_source_id;
    wire [NUM_HARTS*`OPENRV64_ICX_OP_WIDTH-1:0] hart_req_op;
    wire [NUM_HARTS-1:0] hart_req_lock;
    wire [NUM_HARTS*`OPENRV64_ICX_ORDER_WIDTH-1:0]
        hart_req_order;
    wire [NUM_HARTS*`OPENRV64_ICX_KIND_WIDTH-1:0]
        hart_req_kind;
    wire [NUM_HARTS*`OPENRV64_ICX_ATTR_WIDTH-1:0]
        hart_req_attr;
    wire [NUM_HARTS*3-1:0] hart_req_size;
    wire [NUM_HARTS*64-1:0] hart_req_addr;
    wire [NUM_HARTS*`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        hart_req_burst_len;

    wire [NUM_HARTS-1:0] hart_wdata_valid;
    wire [NUM_HARTS-1:0] hart_wdata_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        hart_wdata_hart_id;
    wire [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        hart_wdata_txn_id;
    wire [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        hart_wdata_source_id;
    wire [NUM_HARTS*`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        hart_wdata_beat_index;
    wire [NUM_HARTS-1:0] hart_wdata_last;
    wire [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] hart_wdata;
    wire [NUM_HARTS*`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] hart_wstrb;

    wire [NUM_HARTS-1:0] hart_resp_valid;
    wire [NUM_HARTS-1:0] hart_resp_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        hart_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        hart_resp_txn_id;
    wire [NUM_HARTS*`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        hart_resp_source_id;
    wire [NUM_HARTS*`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        hart_resp_beat_index;
    wire [NUM_HARTS-1:0] hart_resp_last;
    wire [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        hart_resp_rdata;
    wire [NUM_HARTS-1:0] hart_resp_error;
    wire [NUM_HARTS-1:0] hart_resp_sc_success;

    wire icx_req_valid;
    wire icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    wire icx_wdata_valid;
    wire icx_wdata_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    wire icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    wire icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    wire icx_resp_error;
    wire icx_resp_sc_success;

    wire [NUM_HARTS-1:0] probe_valid;
    wire [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    wire [NUM_HARTS-1:0] probe_resp_valid;
    wire [NUM_HARTS-1:0] probe_resp_ready;
    wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] probe_resp_id;
    wire [NUM_HARTS*`OPENRV64_ICX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    wire [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    wire [NUM_HARTS-1:0] probe_resp_error;
    wire [NUM_HARTS-1:0] l1d_invalidate_valid;
    wire [NUM_HARTS-1:0] l1d_invalidate_ready;
    wire [NUM_HARTS*64-1:0] l1d_invalidate_addr;
    wire [NUM_HARTS-1:0] coherent_reservation_clear;

    wire l2_req_valid;
    wire l2_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l2_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l2_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] l2_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] l2_req_op;
    wire l2_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] l2_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] l2_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] l2_req_attr;
    wire [2:0] l2_req_size;
    wire [63:0] l2_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] l2_req_burst_len;
    wire l2_wdata_valid;
    wire l2_wdata_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l2_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l2_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] l2_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] l2_wdata_beat_index;
    wire l2_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l2_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] l2_wstrb;
    wire l2_resp_valid;
    wire l2_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l2_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l2_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] l2_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] l2_resp_beat_index;
    wire l2_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l2_resp_rdata;
    wire l2_resp_error;
    wire l2_resp_sc_success;

    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] bus_req_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    wire bus_resp_valid;
    wire bus_resp_ready;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] bus_resp_rdata;
    wire bus_resp_error;
    logic local_resp_valid;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] local_resp_rdata;
    logic local_resp_error;
    logic rom_pending;
    wire ddr_req_valid;
    wire ddr_req_ready;
    wire ddr_resp_valid;
    wire ddr_resp_ready;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] ddr_resp_rdata;
    wire ddr_resp_error;
    logic [5:0] ddr_outstanding;
    wire ddr_req_fire;
    wire ddr_resp_fire;
    wire [63:0] ddr_read_bursts;
    wire [63:0] ddr_write_bursts;
    wire [63:0] ddr_read_commands;
    wire [63:0] ddr_write_commands;
    wire [63:0] ddr_max_command_queue;
    wire [63:0] ddr_max_timing_owners;
    wire clint_selected;
    wire plic_selected;
    wire uart_selected;
    wire rom_selected;
    wire device_selected;
    wire dram_line_request_shape =
        (bus_req_size == 3'd6) && (bus_req_addr[5:0] == 6'd0);
    wire dram_scalar_write_shape =
        bus_req_write && (bus_req_size <= 3'd3) &&
        ((bus_req_addr & ((64'd1 << bus_req_size) - 1'b1)) == 0) &&
        (bus_req_wstrb ==
         ((((64'd1 << (64'd1 << bus_req_size)) - 1'b1)) <<
          bus_req_addr[5:0]));
    wire [63:0] device_wdata;
    wire [7:0] device_wstrb;
    wire [63:0] clint_rdata;
    wire [63:0] plic_rdata;
    wire [63:0] uart_rdata;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] rom_rdata;
    wire clint_ready;
    wire plic_ready;
    wire uart_ready;
    wire [7:0] rom_ready;
    wire uart_tx;
    wire uart_dtr_n;
    wire uart_rts_n;
    wire uart_out1_n;
    wire uart_out2_n;

    wire [NUM_HARTS*64-1:0] dbg_pc;
    wire [NUM_HARTS*32-1:0] dbg_instr;
    wire [NUM_HARTS-1:0] dbg_halted;
    wire [NUM_HARTS-1:0] hart_wfi_sleep;
    wire [NUM_HARTS*`RV64_PRIV_WIDTH-1:0] hart_priv_mode;

    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_WORDS-1];
    logic [63:0] image_words [0:OPENSBI_MAX_PAYLOAD_WORDS-1];
    logic memory_pending;
    logic memory_pending_write;
    logic [63:0] memory_pending_addr;
    integer memory_delay;
    integer memory_index;
    integer memory_byte;
    integer memory_reads;
    integer memory_writes;
`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
    integer checkpoint_reset_edges;
    logic checkpoint_ddr_load_pending;
`endif

    logic [63:0] done_pc;
    logic [63:0] mailbox_va;
    logic [63:0] result_va;
    logic [63:0] perf_results_va;
    logic [63:0] coherence_base_va;
    logic [63:0] coherence_measure_start_pc;
    logic [63:0] coherence_measure_end_pc;
    logic [63:0] atomic_counter_va;
    logic [63:0] tlbi_reservation_va;
    logic [63:0] tlbi_target_va;
    logic [63:0] tlbi_old_pa;
    logic [63:0] tlbi_new_pa;
    logic done_pc_valid;
    logic mailbox_va_valid;
    logic result_va_valid;
    logic perf_results_va_valid;
    logic atomic_counter_va_valid;
    logic tlbi_reservation_va_valid;
    logic tlbi_target_va_valid;
    logic tlbi_old_pa_valid;
    logic tlbi_new_pa_valid;
    integer shared_satp;
    integer bare_mode;
    integer mailbox_stride;
    integer result_expected;
    integer perf_iterations;
    string perf_name;
    integer coherence_perf;
    integer coherence_case;
    integer coherence_lines;
    integer coherence_line_stride;
    integer coherence_operations;
    integer atomic_expected;
    integer atomic_test;
    integer tlbi_test;
    integer ipi_test;
    integer ipi_expected;
    integer atomic_debug;
    integer max_cycles;
    integer cycles;
    integer first_done_cycle;
    logic progress_before_first_done;
    integer debug_counter_window_enabled;
    integer debug_counter_start_arg_seen;
    integer debug_counter_stop_arg_seen;
    logic [63:0] debug_counter_start_pc;
    logic [63:0] debug_counter_stop_pc;
    logic debug_counter_start_seen;
    logic debug_counter_report_seen;
    logic [63:0] debug_counter_start_cycle;
    logic [63:0] debug_counter_start_retired;
    logic [63:0] debug_counter_start_requests;
    integer debug_counter_start_memory_reads;
    integer debug_counter_start_memory_writes;
    logic [63:0] debug_counter_start_q [0:90];
    integer debug_counter_init_index;
    integer debug_counter_retire_lane;

    logic done_seen [0:NUM_HARTS-1];
    logic mailbox_seen [0:NUM_HARTS-1];
    logic result_seen [0:NUM_HARTS-1];
    logic [6:0] perf_fields_seen [0:NUM_HARTS-1];
    logic [63:0] perf_signature [0:NUM_HARTS-1];
    logic [63:0] perf_start_cycle [0:NUM_HARTS-1];
    logic [63:0] perf_end_cycle [0:NUM_HARTS-1];
    logic [63:0] perf_elapsed_cycles [0:NUM_HARTS-1];
    logic [63:0] perf_start_instret [0:NUM_HARTS-1];
    logic [63:0] perf_end_instret [0:NUM_HARTS-1];
    logic [63:0] perf_retired [0:NUM_HARTS-1];
    logic [63:0] perf_min_start;
    logic [63:0] perf_max_end;
    logic [63:0] perf_total_retired;
    logic [63:0] perf_parallel_span;
    logic [NUM_HARTS-1:0] coherence_measure_active;
    logic [NUM_HARTS-1:0] coherence_measure_started;
    logic [NUM_HARTS-1:0] coherence_measure_ended;
    integer coherence_target_reads [0:NUM_HARTS-1];
    integer coherence_target_writes [0:NUM_HARTS-1];
    integer coherence_target_atomics [0:NUM_HARTS-1];
    integer coherence_target_probes [0:NUM_HARTS-1];
    integer coherence_max_target_mshrs;
    integer coherence_target_mshrs;
    integer coherence_total_reads;
    integer coherence_total_writes;
    integer coherence_total_atomics;
    integer coherence_total_probes;
    integer coherence_total_sc_successes;
    integer coherence_total_sc_failures;
    logic all_active_done;
    logic all_active_mailbox;
    logic all_active_result;
    logic all_active_progress;
    integer active_status_scan;
    logic root_seen [0:NUM_HARTS-1];
    logic satp_seen [0:NUM_HARTS-1];
    logic supervisor_fetch_seen [0:NUM_HARTS-1];
    integer done_cycle [0:NUM_HARTS-1];
    integer retired [0:NUM_HARTS-1];
    integer requests [0:NUM_HARTS-1];
    integer store_allocations [0:NUM_HARTS-1];
    integer fast_store_requests [0:NUM_HARTS-1];
    integer fallback_store_requests [0:NUM_HARTS-1];

    logic l2_write_active;
    logic [63:0] l2_write_addr;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l2_write_hart;
    integer atomic_last_value;
    logic atomic_final_seen;
    integer atomic_l2_successes [0:NUM_HARTS-1];
    integer lr_requests [0:NUM_HARTS-1];
    integer sc_requests [0:NUM_HARTS-1];
    integer sc_successes [0:NUM_HARTS-1];
    integer sc_failures [0:NUM_HARTS-1];
    integer atomic_line_probes [0:NUM_HARTS-1];
    integer reservation_clears [0:NUM_HARTS-1];
    integer tlbi_sfence_retired [0:NUM_HARTS-1];
    integer tlbi_pte_fences [0:NUM_HARTS-1];
    integer tlbi_old_reads [0:NUM_HARTS-1];
    integer tlbi_new_reads [0:NUM_HARTS-1];
    integer tlbi_reservation_probes [0:NUM_HARTS-1];
    integer ipi_msip_assertions [0:NUM_HARTS-1];
    integer ipi_msip_clears [0:NUM_HARTS-1];
    integer ipi_interrupts [0:NUM_HARTS-1];
    integer ipi_fence_requests [0:NUM_HARTS-1];
    integer ipi_fence_responses [0:NUM_HARTS-1];
    integer ipi_send_requests [0:NUM_HARTS-1];
    integer ipi_worker_assertions;
    integer ipi_worker_clears;
    integer ipi_worker_interrupts;
    integer opensbi_msoft_interrupts [0:NUM_HARTS-1];
    integer opensbi_ssoft_interrupts [0:NUM_HARTS-1];
    logic [NUM_HARTS-1:0] ipi_msip_previous;
    logic [NUM_HARTS-1:0] ipi_wfi_seen;
    logic home_request_valid [0:HOME_IDENTITIES-1];
    logic [`OPENRV64_ICX_OP_WIDTH-1:0]
        home_request_op [0:HOME_IDENTITIES-1];
    integer home_request_count;
    integer home_request_identity;
    wire home_request_active = home_request_count != 0;
    logic protocol_error;
    logic probe_endpoint_protocol_error;
    logic opensbi_s_mode_seen;
    logic opensbi_banner_seen;
    logic opensbi_payload_seen;
    logic opensbi_magic_seen;
    logic [NUM_HARTS-1:0] hart_start_private_seen;
    logic [NUM_HARTS-1:0] hart_start_response_seen;
    logic [63:0] hart_start_counter_last;
    logic linux_prompt_seen;
    logic linux_panic_seen;
    logic linux_smp_online_seen;
    logic linux_smp_threads_seen;
    integer opensbi_banner_index;
    integer opensbi_payload_index;
    integer linux_prompt_index;
    integer linux_panic_index;
    integer linux_smp_online_index;
    integer linux_smp_threads_index;
    integer opensbi_uart_bytes;
    localparam integer OPENSBI_TRACE_DEPTH = 128;
    logic [63:0] opensbi_trace_pc [0:OPENSBI_TRACE_DEPTH-1];
    logic [31:0] opensbi_trace_instr [0:OPENSBI_TRACE_DEPTH-1];
    logic [4:0] opensbi_trace_cause [0:OPENSBI_TRACE_DEPTH-1];
    logic opensbi_trace_exception [0:OPENSBI_TRACE_DEPTH-1];
    integer opensbi_trace_write;
    integer opensbi_trace_count;
    integer opensbi_hang_cycles;
    integer opensbi_trace_dump;
    integer opensbi_trace_slot;
    string opensbi_banner = "OpenSBI v1.9";
    string opensbi_payload_text = "OPENRV64 SBI TIMER PAYLOAD";
    string linux_prompt_text = "openrv64# ";
    string linux_panic_text = "Kernel panic";
    string linux_smp_online_text;
    string linux_smp_threads_text = "SMP_THREADS_PASS";

    function automatic [63:0] hart_prefix(input integer hart);
        hart_prefix = PHYSICAL_BASE + PREFIX_STRIDE * hart;
    endfunction

    function automatic [63:0] hart_image_base(input integer hart);
        hart_image_base = ((shared_satp != 0) || (bare_mode != 0)) ?
            PHYSICAL_BASE : hart_prefix(hart);
    endfunction

    function automatic [63:0] hart_root_pa(input integer hart);
        hart_root_pa = hart_image_base(hart) + 64'h20000;
    endfunction

    function automatic [63:0] hart_va_pa(
        input integer hart,
        input [63:0] virtual_address
    );
        if (bare_mode != 0)
            hart_va_pa = virtual_address + mailbox_stride * hart;
        else
            hart_va_pa = hart_image_base(hart) +
                (virtual_address - VIRTUAL_BASE) +
                ((shared_satp != 0) ? mailbox_stride * hart : 0);
    endfunction

    function automatic integer memory_line(input [63:0] address);
        memory_line = (address - PHYSICAL_BASE) >> 6;
    endfunction

    function automatic [63:0] mailbox_pa(input integer hart);
        mailbox_pa = hart_va_pa(hart, mailbox_va);
    endfunction

    function automatic [63:0] result_pa(input integer hart);
        result_pa = hart_va_pa(hart, result_va);
    endfunction

    function automatic [63:0] perf_result_pa(input integer hart);
        perf_result_pa = hart_va_pa(hart, perf_results_va);
    endfunction

    function automatic [63:0] coherence_base_pa;
        coherence_base_pa = PHYSICAL_BASE +
            (coherence_base_va - VIRTUAL_BASE);
    endfunction

    function automatic logic coherence_target_address(
        input [63:0] address
    );
        integer target_line;
        begin
            coherence_target_address = 1'b0;
            for (target_line = 0;
                 target_line < coherence_lines;
                 target_line = target_line + 1)
                if ((address & 64'hffff_ffff_ffff_ffc0) ==
                    ((coherence_base_pa() +
                      target_line * coherence_line_stride) &
                     64'hffff_ffff_ffff_ffc0))
                    coherence_target_address = 1'b1;
        end
    endfunction

    always @* begin
        all_active_done = 1'b1;
        all_active_mailbox = 1'b1;
        all_active_result = 1'b1;
        all_active_progress = 1'b1;
        for (active_status_scan = 0;
             active_status_scan < NUM_HARTS;
             active_status_scan = active_status_scan + 1)
            if (opensbi_active_hart_mask[active_status_scan]) begin
                if (!done_seen[active_status_scan])
                    all_active_done = 1'b0;
                if (!mailbox_seen[active_status_scan])
                    all_active_mailbox = 1'b0;
                if (!result_seen[active_status_scan])
                    all_active_result = 1'b0;
                if (retired[active_status_scan] == 0)
                    all_active_progress = 1'b0;
            end
    end

    function automatic [63:0] atomic_counter_pa;
        atomic_counter_pa =
            PHYSICAL_BASE + (atomic_counter_va - VIRTUAL_BASE);
    endfunction

    function automatic [63:0] tlbi_reservation_pa;
        tlbi_reservation_pa =
            PHYSICAL_BASE + (tlbi_reservation_va - VIRTUAL_BASE);
    endfunction

    generate
        for (genvar reset_hart = 0;
             reset_hart < NUM_HARTS;
             reset_hart = reset_hart + 1) begin : g_hart_reset
            assign hart_rst_n[reset_hart] =
                rst_n && opensbi_active_hart_mask[reset_hart];
            assign hart_clk[reset_hart] =
                ((gate_held_hart_clocks != 0) &&
                 (opensbi_mode != 0) &&
                 rst_n &&
                 !opensbi_active_hart_mask[reset_hart]) ? 1'b0 : clk;
        end
    endgenerate

    genvar hart;
    generate
        for (hart = 0; hart < CORE_INSTANCES; hart = hart + 1) begin : g_hart
            integer pc_trace_lane;
            wire hart_done_retired =
                (u_core.u_debug.backend_retire_arch[0] &&
                 (u_core.u_debug.queue_retire_result[
                      0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.u_debug.backend_retire_arch[1] &&
                 (u_core.u_debug.queue_retire_result[
                      1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.u_debug.backend_retire_arch[2] &&
                 (u_core.u_debug.queue_retire_result[
                      2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc));

            openrv64_rv64_top_3p #(
                .RESET_VECTOR(
                    (ENABLE_BOOT_ROM != 0) ? ROM_BASE : PHYSICAL_BASE),
                .BUS_CONFIG(`OPENRV64_BUS_AXI),
                .HART_ID(`OPENRV64_ICX_HART_ID_WIDTH'(hart)),
                .ENABLE_RV64M(1),
                .ENABLE_RV64ZBB(ENABLE_RV64ZBB),
                .ENABLE_WFI_SLEEP(ENABLE_WFI_SLEEP),
                .ENABLE_ISSUE_WINDOW(1),
                .ENABLE_SPECULATION_WINDOW(1),
                .ENABLE_POSTED_STORES(1),
                .RETIRE_DEPTH(RETIRE_DEPTH),
                .PHYS_REG_COUNT(31),
                .ENABLE_FETCH_CAROUSEL(FETCH_CAROUSEL),
                .ENABLE_FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
                .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
                    FETCH_ALT_CONFIDENCE_GATE),
                .FETCH_ALT_PAIR_STACK_DEPTH(FETCH_ALT_PAIR_STACK_DEPTH),
                .ENABLE_L1I(1),
                .ENABLE_M_MODE_PREFETCH(M_MODE_PREFETCH_ENABLE),
                .ENABLE_L1D(1),
                .ENABLE_FENCE_L2_ACK(FENCE_L2_ACK_ENABLE),
                .ENABLE_L1D_COHERENCE_PROBES(1),
                .ENABLE_COHERENT_ATOMICS(1),
                .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
                .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
                .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
                .L1D_SYNC_TAG_LOOKUP(L1D_SYNC_TAG_LOOKUP),
                .L1D_SYNC_STORE_EXTENSION(L1D_SYNC_STORE_EXTENSION),
                .L1D_CACHEABLE_BASE(PHYSICAL_BASE),
                .L1D_CACHEABLE_SIZE(`OPENRV64_SOC_DRAM_PMA_SIZE)
            ) u_core (
                .clk(hart_clk[hart]),
                .rst_n(hart_rst_n[hart]),
                .mem_ready(1'b0),
                .mem_rdata(64'd0),
                .mem_error(1'b0),
                .pair512_req_ready(1'b0),
                .pair512_resp_valid(1'b0),
                .pair512_resp_predicted_addr(64'd0),
                .pair512_resp_predicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair512_resp_unpredicted_addr(64'd0),
                .pair512_resp_unpredicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair1024_req_ready(1'b0),
                .pair1024_resp_valid(1'b0),
                .pair1024_resp_predicted_addr(64'd0),
                .pair1024_resp_predicted_data(
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
                .pair1024_resp_unpredicted_addr(64'd0),
                .pair1024_resp_unpredicted_data(
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
                .m_axi_arready(1'b0),
                .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
                .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .m_axi_rresp(2'b00),
                .m_axi_rlast(1'b1),
                .m_axi_rvalid(1'b0),
                .m_axi_awready(1'b0),
                .m_axi_wready(1'b0),
                .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
                .m_axi_bresp(2'b00),
                .m_axi_bvalid(1'b0),
                .icx_req_valid(hart_req_valid[hart]),
                .icx_req_ready(hart_req_ready[hart]),
                .icx_req_hart_id(
                    hart_req_hart_id[
                        hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                        `OPENRV64_ICX_HART_ID_WIDTH]),
                .icx_req_txn_id(
                    hart_req_txn_id[
                        hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                        `OPENRV64_ICX_TXN_ID_WIDTH]),
                .icx_req_source_id(
                    hart_req_source_id[
                        hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                        `OPENRV64_ICX_SOURCE_ID_WIDTH]),
                .icx_req_op(
                    hart_req_op[
                        hart*`OPENRV64_ICX_OP_WIDTH +:
                        `OPENRV64_ICX_OP_WIDTH]),
                .icx_req_lock(hart_req_lock[hart]),
                .icx_req_order(
                    hart_req_order[
                        hart*`OPENRV64_ICX_ORDER_WIDTH +:
                        `OPENRV64_ICX_ORDER_WIDTH]),
                .icx_req_kind(
                    hart_req_kind[
                        hart*`OPENRV64_ICX_KIND_WIDTH +:
                        `OPENRV64_ICX_KIND_WIDTH]),
                .icx_req_attr(
                    hart_req_attr[
                        hart*`OPENRV64_ICX_ATTR_WIDTH +:
                        `OPENRV64_ICX_ATTR_WIDTH]),
                .icx_req_size(hart_req_size[hart*3 +: 3]),
                .icx_req_addr(hart_req_addr[hart*64 +: 64]),
                .icx_req_burst_len(
                    hart_req_burst_len[
                        hart*`OPENRV64_ICX_BURST_LEN_WIDTH +:
                        `OPENRV64_ICX_BURST_LEN_WIDTH]),
                .icx_wdata_valid(hart_wdata_valid[hart]),
                .icx_wdata_ready(hart_wdata_ready[hart]),
                .icx_wdata_hart_id(
                    hart_wdata_hart_id[
                        hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                        `OPENRV64_ICX_HART_ID_WIDTH]),
                .icx_wdata_txn_id(
                    hart_wdata_txn_id[
                        hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                        `OPENRV64_ICX_TXN_ID_WIDTH]),
                .icx_wdata_source_id(
                    hart_wdata_source_id[
                        hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                        `OPENRV64_ICX_SOURCE_ID_WIDTH]),
                .icx_wdata_beat_index(
                    hart_wdata_beat_index[
                        hart*`OPENRV64_ICX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_ICX_BEAT_INDEX_WIDTH]),
                .icx_wdata_last(hart_wdata_last[hart]),
                .icx_wdata(
                    hart_wdata[
                        hart*`OPENRV64_ICX_LINE_DATA_WIDTH +:
                        `OPENRV64_ICX_LINE_DATA_WIDTH]),
                .icx_wstrb(
                    hart_wstrb[
                        hart*`OPENRV64_ICX_LINE_STRB_WIDTH +:
                        `OPENRV64_ICX_LINE_STRB_WIDTH]),
                .icx_resp_valid(hart_resp_valid[hart]),
                .icx_resp_ready(hart_resp_ready[hart]),
                .icx_resp_hart_id(
                    hart_resp_hart_id[
                        hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                        `OPENRV64_ICX_HART_ID_WIDTH]),
                .icx_resp_txn_id(
                    hart_resp_txn_id[
                        hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                        `OPENRV64_ICX_TXN_ID_WIDTH]),
                .icx_resp_source_id(
                    hart_resp_source_id[
                        hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                        `OPENRV64_ICX_SOURCE_ID_WIDTH]),
                .icx_resp_beat_index(
                    hart_resp_beat_index[
                        hart*`OPENRV64_ICX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_ICX_BEAT_INDEX_WIDTH]),
                .icx_resp_last(hart_resp_last[hart]),
                .icx_resp_rdata(
                    hart_resp_rdata[
                        hart*`OPENRV64_ICX_LINE_DATA_WIDTH +:
                        `OPENRV64_ICX_LINE_DATA_WIDTH]),
                .icx_resp_error(hart_resp_error[hart]),
                .icx_resp_sc_success(hart_resp_sc_success[hart]),
                .l1d_probe_valid_i(l1d_invalidate_valid[hart]),
                .l1d_probe_ready_o(l1d_invalidate_ready[hart]),
                .l1d_probe_addr_i(
                    l1d_invalidate_addr[hart*64 +: 64]),
                .coherent_reservation_clear_i(
                    coherent_reservation_clear[hart]),
                .irq_m_software(
                    (opensbi_mode || (tlbi_test != 0) ||
                     (ipi_test != 0)) &&
                    clint_msip[hart]),
                .irq_m_timer(
                    opensbi_mode && clint_mtip[hart]),
                .irq_m_external(1'b0),
                .irq_s_software(1'b0),
                .irq_s_timer(1'b0),
                .irq_s_external(
                    opensbi_mode && plic_seip[hart]),
                .dbg_pc(dbg_pc[hart*64 +: 64]),
                .dbg_instr(dbg_instr[hart*32 +: 32]),
                .dbg_halted(dbg_halted[hart]),
                .wfi_sleep_o(hart_wfi_sleep[hart])
            );

            assign hart_priv_mode[
                hart*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH] =
                u_core.u_debug.csr_priv_mode;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    done_seen[hart] <= 1'b0;
                    done_cycle[hart] <= -1;
                    retired[hart] <= 0;
                    requests[hart] <= 0;
                    store_allocations[hart] <= 0;
                    fast_store_requests[hart] <= 0;
                    fallback_store_requests[hart] <= 0;
                    root_seen[hart] <= 1'b0;
                    satp_seen[hart] <= 1'b0;
                    supervisor_fetch_seen[hart] <= 1'b0;
                    opensbi_hsm_wfi_seen[hart] <= 1'b0;
                    opensbi_hsm_sleep_seen[hart] <= 1'b0;
                    opensbi_s_mode_hart_seen[hart] <= 1'b0;
                    tlbi_sfence_retired[hart] <= 0;
                    ipi_msip_assertions[hart] <= 0;
                    ipi_msip_clears[hart] <= 0;
                    ipi_interrupts[hart] <= 0;
                    opensbi_msoft_interrupts[hart] <= 0;
                    opensbi_ssoft_interrupts[hart] <= 0;
                    ipi_msip_previous[hart] <= 1'b0;
                    ipi_wfi_seen[hart] <= 1'b0;
                    coherence_measure_active[hart] <= 1'b0;
                    coherence_measure_started[hart] <= 1'b0;
                    coherence_measure_ended[hart] <= 1'b0;
                end else begin
                    ipi_msip_previous[hart] <= clint_msip[hart];
                    if ((pc_trace_fd != 0) &&
                        pc_trace_mask[hart]) begin
                        for (pc_trace_lane = 0;
                             pc_trace_lane < 3;
                             pc_trace_lane = pc_trace_lane + 1)
                            if (u_core.u_debug.backend_retire_arch[
                                    pc_trace_lane])
                                $fdisplay(pc_trace_fd,
                                    "RET cycle=%0d hart=%0d lane=%0d priv=%0d pc=%016h instr=%08h",
                                    cycles, hart, pc_trace_lane,
                                    u_core.u_debug.csr_priv_mode,
                                    u_core.u_debug.queue_retire_result[
                                        pc_trace_lane*
                                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                                        RETIRE_RESULT_PC_LSB +: 64],
                                    u_core.u_debug.queue_retire_result[
                                        pc_trace_lane*
                                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                                        RETIRE_RESULT_INSTR_LSB +: 32]);
                        if (u_core.u_debug.trap_enter) begin
                            $fdisplay(pc_trace_fd,
                                "TRAP cycle=%0d hart=%0d from_priv=%0d to_s=%0b interrupt=%0b cause=%0d epc=%016h vector=%016h msip=%0b mtip=%0b",
                                cycles, hart,
                                u_core.u_debug.csr_priv_mode,
                                u_core.u_debug.csr_trap_to_s,
                                u_core.u_debug.trap_interrupt,
                                u_core.u_debug.trap_cause,
                                u_core.u_debug.trap_pc,
                                u_core.u_debug.csr_trap_vector,
                                clint_msip[hart],
                                clint_mtip[hart]);
                            $fflush(pc_trace_fd);
                        end
                    end
                    if ((opensbi_mode != 0) &&
                        u_core.u_debug.trap_enter &&
                        u_core.u_debug.trap_interrupt &&
                        (u_core.u_debug.trap_cause ==
                         `RV64_IRQ_CAUSE_MACHINE_SOFTWARE)) begin
                        opensbi_msoft_interrupts[hart] <=
                            opensbi_msoft_interrupts[hart] + 1;
                        $display(
                            "OPENSBI_4H_IPI_TRAP cycle=%0d hart=%0d level=M cause=3 pc=%016h vector=%016h msip=%0b count=%0d",
                            cycles, hart, u_core.u_debug.trap_pc,
                            u_core.u_debug.csr_trap_vector,
                            clint_msip[hart],
                            opensbi_msoft_interrupts[hart] + 1);
                        $fflush();
                    end
                    if ((opensbi_mode != 0) &&
                        u_core.u_debug.trap_enter &&
                        u_core.u_debug.trap_interrupt &&
                        (u_core.u_debug.trap_cause ==
                         `RV64_IRQ_CAUSE_SUPERVISOR_SOFTWARE)) begin
                        opensbi_ssoft_interrupts[hart] <=
                            opensbi_ssoft_interrupts[hart] + 1;
                        $display(
                            "OPENSBI_4H_IPI_TRAP cycle=%0d hart=%0d level=S cause=1 pc=%016h vector=%016h count=%0d",
                            cycles, hart, u_core.u_debug.trap_pc,
                            u_core.u_debug.csr_trap_vector,
                            opensbi_ssoft_interrupts[hart] + 1);
                        $fflush();
                    end
                    if (ipi_test != 0) begin
                        if (!ipi_msip_previous[hart] &&
                            clint_msip[hart])
                            ipi_msip_assertions[hart] <=
                                ipi_msip_assertions[hart] + 1;
                        if (ipi_msip_previous[hart] &&
                            !clint_msip[hart])
                            ipi_msip_clears[hart] <=
                                ipi_msip_clears[hart] + 1;
                        if (hart_wfi_sleep[hart])
                            ipi_wfi_seen[hart] <= 1'b1;
                        if (u_core.u_debug.trap_enter &&
                            u_core.u_debug.trap_interrupt &&
                            (u_core.u_debug.trap_cause ==
                             `RV64_IRQ_CAUSE_MACHINE_SOFTWARE))
                            ipi_interrupts[hart] <=
                                ipi_interrupts[hart] + 1;
                    end
                    if ((atomic_debug != 0) && (cycles != 0) &&
                        ((cycles % 500) == 0))
                        $display(
                            "ATOMIC_HART_DEBUG cycle=%0d hart=%0d active=%b irrev=%b inflight=%b engine_state=%0d engine_op=%0d atomic_addr=%h local_res=%b l1_backend=%0d l1_array=%0d l1_res_req=%b l1_res_done=%b l1_req=%b/%b home_state=%0d home_active=%b home_op=%0d home_addr=%h home_src=%0d home_hart=%0d probe_target=%b mask=%b issue=%b ack=%b lane_vr=%b/%b resp_vr=%b/%b inv_vr=%b/%b l2_cmd=%0d l2_rsp=%0d l2_mshr=%b:%0d,%b:%0d bus=%b/%b/%b/%b mem=%b:%0d",
                            cycles, hart,
                            u_core.u_debug.atomic_active,
                            u_core.u_debug.atomic_irrevocable,
                            u_core.u_debug.atomic_req_inflight,
                            u_core.u_debug.atomic_state,
                            u_core.u_debug.atomic_op,
                            u_core.u_debug.atomic_addr,
                            u_core.u_debug.atomic_reservation_valid,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.backend_state,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                                g_cache.u_cache.u_debug.state_q,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.request_reservation,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.coherent_lr_reservation_done,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.req_valid,
                            u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.req_ready,
                            u_l2.u_debug.lookup_action,
                            home_request_active, u_l2.u_debug.lookup_op,
                            u_l2.u_debug.lookup_addr,
                            u_l2.u_debug.lookup_source_id,
                            u_l2.u_debug.lookup_hart_id,
                            u_l2.u_debug.mshr_probe_target[
                                u_l2.u_debug.active_probe_mshr],
                            u_l2.u_debug.mshr_probe_cache_mask[
                                u_l2.u_debug.active_probe_mshr],
                            u_l2.u_debug.probe_issue_pending,
                            u_l2.u_debug.probe_ack_pending,
                            probe_valid, probe_ready,
                            probe_resp_valid, probe_resp_ready,
                            l1d_invalidate_valid, l1d_invalidate_ready,
                            u_l2.u_debug.cmd_count,
                            u_l2.u_debug.response_count,
                            u_l2.u_debug.mshr_valid[0],
                            u_l2.u_debug.mshr_state[0],
                            u_l2.u_debug.mshr_valid[1],
                            u_l2.u_debug.mshr_state[1],
                            bus_req_valid, bus_req_ready,
                            bus_resp_valid, bus_resp_ready,
                            memory_pending, memory_delay);
                    retired[hart] <= retired[hart] +
                        u_core.u_debug.backend_retire_arch[0] +
                        u_core.u_debug.backend_retire_arch[1] +
                        u_core.u_debug.backend_retire_arch[2];
                    if ((coherence_perf != 0) &&
                        (|u_core.u_debug.backend_retire_arch) &&
                        (u_core.u_debug.backend_retire_pc ==
                         coherence_measure_start_pc)) begin
                        coherence_measure_active[hart] <= 1'b1;
                        coherence_measure_started[hart] <= 1'b1;
                    end
                    if ((coherence_perf != 0) &&
                        (|u_core.u_debug.backend_retire_arch) &&
                        (u_core.u_debug.backend_retire_pc ==
                         coherence_measure_end_pc)) begin
                        coherence_measure_active[hart] <= 1'b0;
                        coherence_measure_ended[hart] <= 1'b1;
                    end
                    if ((tlbi_test != 0) &&
                        u_core.u_debug.backend_sfence_vma)
                        tlbi_sfence_retired[hart] <=
                            tlbi_sfence_retired[hart] + 1;
                    if ((opensbi_smp != 0) && (hart != 0) &&
                        (|u_core.u_debug.backend_retire_arch) &&
                        (u_core.u_debug.backend_retire_pc ==
                         opensbi_hsm_wfi_pc) &&
                        (u_core.u_debug.backend_retire_instr ==
                         `RV64_INSTR_WFI))
                        opensbi_hsm_wfi_seen[hart] <= 1'b1;
                    if ((opensbi_smp != 0) && (hart != 0) &&
                        opensbi_hsm_wfi_seen[hart] &&
                        hart_wfi_sleep[hart])
                        opensbi_hsm_sleep_seen[hart] <= 1'b1;
                    if ((opensbi_mode != 0) &&
                        (u_core.u_debug.csr_priv_mode == `RV64_PRIV_S))
                        opensbi_s_mode_hart_seen[hart] <= 1'b1;
                    if (u_core.u_debug.store_alloc_fire)
                        store_allocations[hart] <=
                            store_allocations[hart] + 1;
                    if (u_core.u_bus.g_icx.u_bus.u_debug.
                            pipe_fast_request_fire &&
                        u_core.u_bus.g_icx.u_bus.u_debug.
                            lsu_pipe_req_write)
                        fast_store_requests[hart] <=
                            fast_store_requests[hart] + 1;
                    if (u_core.u_bus.g_icx.u_bus.u_debug.
                            pipe_fallback_candidate &&
                        u_core.u_bus.g_icx.u_bus.u_debug.
                            lsu_pipe_req_ready &&
                        u_core.u_bus.g_icx.u_bus.u_debug.
                            lsu_pipe_req_write)
                        fallback_store_requests[hart] <=
                            fallback_store_requests[hart] + 1;
                    if (hart_req_valid[hart] &&
                        hart_req_ready[hart]) begin
                        requests[hart] <= requests[hart] + 1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_ICX_SOURCE_ID_WIDTH] ==
                             `OPENRV64_ICX_SOURCE_PTW) &&
                            ((hart_req_addr[hart*64 +: 64] &
                              64'hffff_ffff_ffff_ffc0) ==
                             hart_root_pa(hart)))
                            root_seen[hart] <= 1'b1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_ICX_SOURCE_ID_WIDTH] ==
                            `OPENRV64_ICX_SOURCE_ICACHE) &&
                            (hart_req_addr[hart*64 +: 64] >=
                             hart_image_base(hart) + 64'h1000) &&
                            (hart_req_addr[hart*64 +: 64] <
                             hart_image_base(hart) + 64'h20000))
                            supervisor_fetch_seen[hart] <= 1'b1;
                    end
                    if (opensbi_mode == 0) begin
                        if ((bare_mode != 0) &&
                            (u_core.u_debug.csr_priv_mode == `RV64_PRIV_S) &&
                            (u_core.u_debug.csr_satp_mode ==
                             `RV64_SATP_MODE_BARE))
                            satp_seen[hart] <= 1'b1;
                        else if ((u_core.u_debug.csr_priv_mode ==
                                  `RV64_PRIV_S) &&
                                 (u_core.u_debug.csr_satp_mode ==
                                  `RV64_SATP_MODE_SV39)) begin
                            if ((u_core.u_debug.csr_satp_root_ppn !=
                                 (hart_root_pa(hart) >> 12)) ||
                                (u_core.u_debug.csr_satp_asid != 0))
                                $fatal(1,
                                    "hart %0d wrong SATP mode=%0d asid=%0d ppn=%h expected=%h",
                                    hart, u_core.u_debug.csr_satp_mode,
                                    u_core.u_debug.csr_satp_asid,
                                    u_core.u_debug.csr_satp_root_ppn,
                                    (hart_root_pa(hart) >> 12));
                            satp_seen[hart] <= 1'b1;
                        end
                    end
                    if (done_pc_valid && hart_done_retired &&
                        !done_seen[hart]) begin
                        done_seen[hart] <= 1'b1;
                        done_cycle[hart] <= cycles;
                    end
                end
            end
        end

        for (genvar tied_hart = CORE_INSTANCES;
             tied_hart < NUM_HARTS;
             tied_hart = tied_hart + 1) begin : g_tied_hart
            assign hart_req_valid[tied_hart] = 1'b0;
            assign hart_req_hart_id[
                tied_hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                `OPENRV64_ICX_HART_ID_WIDTH] = '0;
            assign hart_req_txn_id[
                tied_hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                `OPENRV64_ICX_TXN_ID_WIDTH] = '0;
            assign hart_req_source_id[
                tied_hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                `OPENRV64_ICX_SOURCE_ID_WIDTH] = '0;
            assign hart_req_op[
                tied_hart*`OPENRV64_ICX_OP_WIDTH +:
                `OPENRV64_ICX_OP_WIDTH] = '0;
            assign hart_req_lock[tied_hart] = 1'b0;
            assign hart_req_order[
                tied_hart*`OPENRV64_ICX_ORDER_WIDTH +:
                `OPENRV64_ICX_ORDER_WIDTH] = '0;
            assign hart_req_kind[
                tied_hart*`OPENRV64_ICX_KIND_WIDTH +:
                `OPENRV64_ICX_KIND_WIDTH] = '0;
            assign hart_req_attr[
                tied_hart*`OPENRV64_ICX_ATTR_WIDTH +:
                `OPENRV64_ICX_ATTR_WIDTH] = '0;
            assign hart_req_size[tied_hart*3 +: 3] = '0;
            assign hart_req_addr[tied_hart*64 +: 64] = '0;
            assign hart_req_burst_len[
                tied_hart*`OPENRV64_ICX_BURST_LEN_WIDTH +:
                `OPENRV64_ICX_BURST_LEN_WIDTH] = '0;

            assign hart_wdata_valid[tied_hart] = 1'b0;
            assign hart_wdata_hart_id[
                tied_hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                `OPENRV64_ICX_HART_ID_WIDTH] = '0;
            assign hart_wdata_txn_id[
                tied_hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                `OPENRV64_ICX_TXN_ID_WIDTH] = '0;
            assign hart_wdata_source_id[
                tied_hart*`OPENRV64_ICX_SOURCE_ID_WIDTH +:
                `OPENRV64_ICX_SOURCE_ID_WIDTH] = '0;
            assign hart_wdata_beat_index[
                tied_hart*`OPENRV64_ICX_BEAT_INDEX_WIDTH +:
                `OPENRV64_ICX_BEAT_INDEX_WIDTH] = '0;
            assign hart_wdata_last[tied_hart] = 1'b0;
            assign hart_wdata[
                tied_hart*`OPENRV64_ICX_LINE_DATA_WIDTH +:
                `OPENRV64_ICX_LINE_DATA_WIDTH] = '0;
            assign hart_wstrb[
                tied_hart*`OPENRV64_ICX_LINE_STRB_WIDTH +:
                `OPENRV64_ICX_LINE_STRB_WIDTH] = '0;

            assign hart_resp_ready[tied_hart] = 1'b1;
            assign l1d_invalidate_ready[tied_hart] = 1'b1;
            assign dbg_pc[tied_hart*64 +: 64] = '0;
            assign dbg_instr[tied_hart*32 +: 32] = '0;
            assign dbg_halted[tied_hart] = 1'b0;
            assign hart_wfi_sleep[tied_hart] = 1'b0;
            assign hart_priv_mode[
                tied_hart*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH] =
                `RV64_PRIV_M;

            initial begin
                done_seen[tied_hart] = 1'b0;
                done_cycle[tied_hart] = -1;
                retired[tied_hart] = 0;
                requests[tied_hart] = 0;
                store_allocations[tied_hart] = 0;
                fast_store_requests[tied_hart] = 0;
                fallback_store_requests[tied_hart] = 0;
                root_seen[tied_hart] = 1'b0;
                satp_seen[tied_hart] = 1'b0;
                supervisor_fetch_seen[tied_hart] = 1'b0;
                opensbi_hsm_wfi_seen[tied_hart] = 1'b0;
                opensbi_hsm_sleep_seen[tied_hart] = 1'b0;
                opensbi_s_mode_hart_seen[tied_hart] = 1'b0;
                tlbi_sfence_retired[tied_hart] = 0;
                ipi_msip_assertions[tied_hart] = 0;
                ipi_msip_clears[tied_hart] = 0;
                ipi_interrupts[tied_hart] = 0;
                opensbi_msoft_interrupts[tied_hart] = 0;
                opensbi_ssoft_interrupts[tied_hart] = 0;
                ipi_msip_previous[tied_hart] = 1'b0;
                ipi_wfi_seen[tied_hart] = 1'b0;
                coherence_measure_active[tied_hart] = 1'b0;
                coherence_measure_started[tied_hart] = 1'b0;
                coherence_measure_ended[tied_hart] = 1'b0;
            end
        end
    endgenerate

    openrv64_icx_line_crossbar #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0)
    ) u_crossbar (
        .clk_i(clk),
        .rst_ni(rst_n),
        .hart_req_valid_i(hart_req_valid),
        .hart_req_ready_o(hart_req_ready),
        .hart_req_hart_id_i(hart_req_hart_id),
        .hart_req_txn_id_i(hart_req_txn_id),
        .hart_req_source_id_i(hart_req_source_id),
        .hart_req_op_i(hart_req_op),
        .hart_req_lock_i(hart_req_lock),
        .hart_req_order_i(hart_req_order),
        .hart_req_kind_i(hart_req_kind),
        .hart_req_attr_i(hart_req_attr),
        .hart_req_size_i(hart_req_size),
        .hart_req_addr_i(hart_req_addr),
        .hart_req_burst_len_i(hart_req_burst_len),
        .mem_req_valid_o(icx_req_valid),
        .mem_req_ready_i(icx_req_ready),
        .mem_req_hart_id_o(icx_req_hart_id),
        .mem_req_txn_id_o(icx_req_txn_id),
        .mem_req_source_id_o(icx_req_source_id),
        .mem_req_op_o(icx_req_op),
        .mem_req_lock_o(icx_req_lock),
        .mem_req_order_o(icx_req_order),
        .mem_req_kind_o(icx_req_kind),
        .mem_req_attr_o(icx_req_attr),
        .mem_req_size_o(icx_req_size),
        .mem_req_addr_o(icx_req_addr),
        .mem_req_burst_len_o(icx_req_burst_len),
        .hart_wdata_valid_i(hart_wdata_valid),
        .hart_wdata_ready_o(hart_wdata_ready),
        .hart_wdata_hart_id_i(hart_wdata_hart_id),
        .hart_wdata_txn_id_i(hart_wdata_txn_id),
        .hart_wdata_source_id_i(hart_wdata_source_id),
        .hart_wdata_beat_index_i(hart_wdata_beat_index),
        .hart_wdata_last_i(hart_wdata_last),
        .hart_wdata_i(hart_wdata),
        .hart_wstrb_i(hart_wstrb),
        .mem_wdata_valid_o(icx_wdata_valid),
        .mem_wdata_ready_i(icx_wdata_ready),
        .mem_wdata_hart_id_o(icx_wdata_hart_id),
        .mem_wdata_txn_id_o(icx_wdata_txn_id),
        .mem_wdata_source_id_o(icx_wdata_source_id),
        .mem_wdata_beat_index_o(icx_wdata_beat_index),
        .mem_wdata_last_o(icx_wdata_last),
        .mem_wdata_o(icx_wdata),
        .mem_wstrb_o(icx_wstrb),
        .mem_resp_valid_i(icx_resp_valid),
        .mem_resp_ready_o(icx_resp_ready),
        .mem_resp_hart_id_i(icx_resp_hart_id),
        .mem_resp_txn_id_i(icx_resp_txn_id),
        .mem_resp_source_id_i(icx_resp_source_id),
        .mem_resp_beat_index_i(icx_resp_beat_index),
        .mem_resp_last_i(icx_resp_last),
        .mem_resp_rdata_i(icx_resp_rdata),
        .mem_resp_error_i(icx_resp_error),
        .mem_resp_sc_success_i(icx_resp_sc_success),
        .hart_resp_valid_o(hart_resp_valid),
        .hart_resp_ready_i(hart_resp_ready),
        .hart_resp_hart_id_o(hart_resp_hart_id),
        .hart_resp_txn_id_o(hart_resp_txn_id),
        .hart_resp_source_id_o(hart_resp_source_id),
        .hart_resp_beat_index_o(hart_resp_beat_index),
        .hart_resp_last_o(hart_resp_last),
        .hart_resp_rdata_o(hart_resp_rdata),
        .hart_resp_error_o(hart_resp_error),
        .hart_resp_sc_success_o(hart_resp_sc_success)
    );

    openrv64_icx_l2_native #(
        .CACHE_BYTES(L2_CACHE_BYTES),
        .LINE_BYTES(64),
        .WAYS(L2_WAYS),
        .MSHR_ENTRIES(L2_MSHRS),
        .WAITERS_PER_MSHR(8),
        .COMMAND_ENTRIES(16),
        .RESPONSE_ENTRIES(16),
        .BUS_TRACK_ENTRIES(L2_MSHRS),
        .ENABLE_COHERENCE(1),
        .SC_EXCLUSIVE_RETAIN_ENABLE(SC_EXCLUSIVE_RETAIN_ENABLE),
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0),
        .DIRECTORY_ENTRIES(1024),
        .DIRECTORY_WAYS(4)
    ) u_l2 (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(icx_req_valid),
        .req_ready_o(icx_req_ready),
        .req_hart_id_i(icx_req_hart_id),
        .req_txn_id_i(icx_req_txn_id),
        .req_source_id_i(icx_req_source_id),
        .req_op_i(icx_req_op),
        .req_lock_i(icx_req_lock),
        .req_order_i(icx_req_order),
        .req_kind_i(icx_req_kind),
        .req_attr_i(icx_req_attr),
        .req_size_i(icx_req_size),
        .req_addr_i(icx_req_addr),
        .req_burst_len_i(icx_req_burst_len),
        .wdata_valid_i(icx_wdata_valid),
        .wdata_ready_o(icx_wdata_ready),
        .wdata_hart_id_i(icx_wdata_hart_id),
        .wdata_txn_id_i(icx_wdata_txn_id),
        .wdata_source_id_i(icx_wdata_source_id),
        .wdata_beat_index_i(icx_wdata_beat_index),
        .wdata_last_i(icx_wdata_last),
        .wdata_i(icx_wdata),
        .wstrb_i(icx_wstrb),
        .resp_valid_o(icx_resp_valid),
        .resp_ready_i(icx_resp_ready),
        .resp_hart_id_o(icx_resp_hart_id),
        .resp_txn_id_o(icx_resp_txn_id),
        .resp_source_id_o(icx_resp_source_id),
        .resp_beat_index_o(icx_resp_beat_index),
        .resp_last_o(icx_resp_last),
        .resp_rdata_o(icx_resp_rdata),
        .resp_error_o(icx_resp_error),
        .resp_sc_success_o(icx_resp_sc_success),
        .probe_valid_o(probe_valid),
        .probe_ready_i(probe_ready),
        .probe_id_o(probe_id),
        .probe_command_o(probe_command),
        .probe_cache_mask_o(probe_cache_mask),
        .probe_line_addr_o(probe_line_addr),
        .probe_resp_valid_i(probe_resp_valid),
        .probe_resp_ready_o(probe_resp_ready),
        .probe_resp_id_i(probe_resp_id),
        .probe_resp_kind_i(probe_resp_kind),
        .probe_resp_data_i(probe_resp_data),
        .probe_resp_error_i(probe_resp_error),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(protocol_error),
        .bus_req_valid_o(bus_req_valid),
        .bus_req_ready_i(bus_req_ready),
        .bus_req_write_o(bus_req_write),
        .bus_req_addr_o(bus_req_addr),
        .bus_req_size_o(bus_req_size),
        .bus_req_wdata_o(bus_req_wdata),
        .bus_req_wstrb_o(bus_req_wstrb),
        .bus_req_cacheable_o(bus_req_cacheable),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_o(bus_resp_ready),
        .bus_resp_rdata_i(bus_resp_rdata),
        .bus_resp_error_i(bus_resp_error)
    );

    /* Count only benchmark-line MSHRs, not instruction/PTW/result traffic. */
    integer coherence_mshr_scan;
    always @* begin
        coherence_target_mshrs = 0;
        for (coherence_mshr_scan = 0;
             coherence_mshr_scan < L2_MSHRS;
             coherence_mshr_scan = coherence_mshr_scan + 1)
            if ((coherence_perf != 0) &&
                u_l2.u_debug.mshr_valid[coherence_mshr_scan] &&
                coherence_target_address(
                    u_l2.u_debug.mshr_line_addr[coherence_mshr_scan]))
                coherence_target_mshrs =
                    coherence_target_mshrs + 1;
    end

    /*
     * Preserve the old home-to-L2 observation point for the mailbox checker.
     * The coherence home now lives inside u_l2, so a lookup dispatch is the
     * equivalent accepted home operation.
     */
    wire l2_direct_commit = u_l2.u_debug.lookup_dispatch &&
        (u_l2.u_debug.lookup_action != u_l2.u_debug.lookup_coh_probe) &&
        !u_l2.u_debug.lookup_protocol_error &&
        !u_l2.u_debug.coherence_hart_error &&
        !u_l2.u_debug.lookup_sc_failed;
    wire l2_probe_commit = u_l2.u_debug.coherence_probe_completion;
    wire [31:0] l2_probe_waiter =
        32'(u_l2.u_debug.active_probe_mshr) * 8;
    assign l2_req_valid = l2_direct_commit || l2_probe_commit;
    assign l2_req_ready = 1'b1;
    assign l2_req_hart_id = l2_probe_commit ?
        u_l2.u_debug.waiter_hart_id[l2_probe_waiter] :
        u_l2.u_debug.lookup_hart_id;
    assign l2_req_txn_id = l2_probe_commit ?
        u_l2.u_debug.waiter_txn_id[l2_probe_waiter] :
        u_l2.u_debug.lookup_txn_id;
    assign l2_req_source_id = l2_probe_commit ?
        u_l2.u_debug.waiter_source_id[l2_probe_waiter] :
        u_l2.u_debug.lookup_source_id;
    assign l2_req_op =
        ((l2_probe_commit ?
          u_l2.u_debug.waiter_op[l2_probe_waiter] :
          u_l2.u_debug.lookup_op) == `OPENRV64_ICX_OP_LR) ?
            `OPENRV64_ICX_OP_READ :
        ((l2_probe_commit ?
          u_l2.u_debug.waiter_op[l2_probe_waiter] :
          u_l2.u_debug.lookup_op) == `OPENRV64_ICX_OP_SC) ?
            `OPENRV64_ICX_OP_WRITE :
        (l2_probe_commit ?
          u_l2.u_debug.waiter_op[l2_probe_waiter] :
          u_l2.u_debug.lookup_op);
    assign l2_req_lock = 1'b0;
    assign l2_req_order = `OPENRV64_ICX_ORDER_NONE;
    assign l2_req_kind = l2_probe_commit ?
        u_l2.u_debug.waiter_kind[l2_probe_waiter] :
        u_l2.u_debug.lookup_kind;
    assign l2_req_attr = l2_probe_commit ?
        u_l2.u_debug.waiter_attr[l2_probe_waiter] :
        u_l2.u_debug.lookup_attr;
    assign l2_req_size = l2_probe_commit ?
        u_l2.u_debug.waiter_size[l2_probe_waiter] :
        u_l2.u_debug.lookup_size;
    assign l2_req_addr = l2_probe_commit ?
        u_l2.u_debug.waiter_addr[l2_probe_waiter] :
        u_l2.u_debug.lookup_addr;
    assign l2_req_burst_len = 0;
    assign l2_wdata_valid =
        l2_req_valid && (l2_req_op == `OPENRV64_ICX_OP_WRITE);
    assign l2_wdata_ready = 1'b1;
    assign l2_wdata_hart_id = l2_req_hart_id;
    assign l2_wdata_txn_id = l2_req_txn_id;
    assign l2_wdata_source_id = l2_req_source_id;
    assign l2_wdata_beat_index = 0;
    assign l2_wdata_last = 1'b1;
    assign l2_wdata = l2_probe_commit ?
        u_l2.u_debug.waiter_wdata[l2_probe_waiter] :
        u_l2.u_debug.lookup_wdata;
    assign l2_wstrb = l2_probe_commit ?
        u_l2.u_debug.waiter_wstrb[l2_probe_waiter] :
        u_l2.u_debug.lookup_wstrb;

    openrv64_icx_4h_l1d_probe_cluster #(
        .PROBE_TIMEOUT_CYCLES(65536)
    ) u_probe_cluster (
        .clk_i(clk),
        .rst_ni(rst_n),
        .probe_valid_i(probe_valid),
        .probe_ready_o(probe_ready),
        .probe_id_i(probe_id),
        .probe_command_i(probe_command),
        .probe_cache_mask_i(probe_cache_mask),
        .probe_line_addr_i(probe_line_addr),
        .probe_resp_valid_o(probe_resp_valid),
        .probe_resp_ready_i(probe_resp_ready),
        .probe_resp_id_o(probe_resp_id),
        .probe_resp_kind_o(probe_resp_kind),
        .probe_resp_data_o(probe_resp_data),
        .probe_resp_error_o(probe_resp_error),
        .l1d_invalidate_valid_o(l1d_invalidate_valid),
        .l1d_invalidate_ready_i(l1d_invalidate_ready),
        .l1d_invalidate_addr_o(l1d_invalidate_addr),
        .clear_reservation_o(coherent_reservation_clear),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(probe_endpoint_protocol_error)
    );

    tb_4h_ddr3_backend #(
        .MEM_BASE(PHYSICAL_BASE),
        .MEM_BYTES(MEMORY_BYTES),
        .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .DDR3_READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
        .DDR3_WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
        .DDR3_COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
        .DDR3_MAX_BURST_TRAIN_BURSTS(
            DDR3_MAX_BURST_TRAIN_BURSTS),
        .DDR3_BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE)
    ) u_ddr_backend (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(ddr_req_valid),
        .req_ready_o(ddr_req_ready),
        .req_write_i(bus_req_write),
        .req_addr_i(bus_req_addr),
        .req_size_i(bus_req_size),
        .req_wdata_i(bus_req_wdata),
        .req_wstrb_i(bus_req_wstrb),
        .req_cacheable_i(bus_req_cacheable),
        .resp_valid_o(ddr_resp_valid),
        .resp_ready_i(ddr_resp_ready),
        .resp_rdata_o(ddr_resp_rdata),
        .resp_error_o(ddr_resp_error),
        .read_bursts_o(ddr_read_bursts),
        .write_bursts_o(ddr_write_bursts),
        .read_commands_o(ddr_read_commands),
        .write_commands_o(ddr_write_commands),
        .max_command_queue_o(ddr_max_command_queue),
        .max_timing_owners_o(ddr_max_timing_owners)
    );

    assign rom_selected =
        opensbi_mode && (ENABLE_BOOT_ROM != 0) &&
        (bus_req_addr >= ROM_BASE) &&
        (bus_req_addr < ROM_BASE + ROM_SIZE);
    assign clint_selected =
        (opensbi_mode || (tlbi_test != 0) || (ipi_test != 0)) &&
        !bus_req_cacheable &&
        (bus_req_addr >= CLINT_BASE) &&
        (bus_req_addr < CLINT_BASE + CLINT_SIZE);
    assign plic_selected =
        opensbi_mode && !bus_req_cacheable &&
        (bus_req_addr >= PLIC_BASE) &&
        (bus_req_addr < PLIC_BASE + PLIC_SIZE);
    assign uart_selected =
        opensbi_mode && !bus_req_cacheable &&
        (bus_req_addr >= UART_BASE) &&
        (bus_req_addr < UART_BASE + UART_SIZE);
    assign device_selected =
        rom_selected || clint_selected || plic_selected || uart_selected;
    assign device_wdata =
        bus_req_wdata >> (bus_req_addr[5:3] * 64);
    assign device_wstrb =
        bus_req_wstrb >> (bus_req_addr[5:3] * 8);

    generate
        for (genvar rom_lane = 0; rom_lane < 8;
             rom_lane = rom_lane + 1) begin : g_rom_lane
            openrv64_soc_rom u_rom (
                .clk_i(clk),
                .rst_ni(rst_n),
                .mem_valid_i(
                    bus_req_valid && bus_req_ready &&
                    rom_selected),
                .mem_ready_o(rom_ready[rom_lane]),
                .mem_write_i(bus_req_write),
                .mem_addr_i(
                    (bus_req_addr - ROM_BASE) +
                    rom_lane*8),
                .mem_wdata_i(device_wdata),
                .mem_wstrb_i(device_wstrb),
                .mem_rdata_o(
                    rom_rdata[rom_lane*64 +: 64])
            );
        end
    endgenerate

    openrv64_clint #(
        .NUM_HARTS(NUM_HARTS)
    ) u_clint (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .mem_valid_i(
            bus_req_valid && bus_req_ready && clint_selected),
        .mem_ready_o(clint_ready),
        .mem_write_i(bus_req_write),
        .mem_addr_i(bus_req_addr - CLINT_BASE),
        .mem_wdata_i(device_wdata),
        .mem_wstrb_i(device_wstrb),
        .mem_rdata_o(clint_rdata),
        .msip_o(clint_msip),
        .mtip_o(clint_mtip),
        .mtime_o(clint_mtime)
    );

    openrv64_plic #(
        .NUM_HARTS(NUM_HARTS),
        .NUM_SOURCES(32),
        .PRIORITY_WIDTH(3)
    ) u_plic (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_sources_i({31'd0, uart_irq}),
        .mem_valid_i(
            bus_req_valid && bus_req_ready && plic_selected),
        .mem_ready_o(plic_ready),
        .mem_write_i(bus_req_write),
        .mem_addr_i(bus_req_addr - PLIC_BASE),
        .mem_wdata_i(device_wdata),
        .mem_wstrb_i(device_wstrb),
        .mem_rdata_o(plic_rdata),
        .seip_o(plic_seip)
    );

    openrv64_uart16550 u_uart (
        .clk_i(clk),
        .rst_ni(rst_n),
        .rx_i(1'b1),
        .tx_o(uart_tx),
        .cts_ni(1'b1),
        .dsr_ni(1'b1),
        .ri_ni(1'b1),
        .dcd_ni(1'b1),
        .dtr_no(uart_dtr_n),
        .rts_no(uart_rts_n),
        .out1_no(uart_out1_n),
        .out2_no(uart_out2_n),
        .mem_valid_i(
            bus_req_valid && bus_req_ready && uart_selected),
        .mem_ready_o(uart_ready),
        .mem_write_i(bus_req_write),
        .mem_addr_i(bus_req_addr - UART_BASE),
        .mem_wdata_i(device_wdata),
        .mem_wstrb_i(device_wstrb),
        .mem_rdata_o(uart_rdata),
        .irq_o(uart_irq)
    );

    /*
     * The L2 response channel is untagged.  RAM requests may queue in genbus,
     * but a device request is admitted only after every queued RAM response
     * drains.  While a local device response is pending, no RAM request is
     * admitted.  This keeps the combined response stream in request order.
     */
    assign ddr_req_valid =
        (DDR3_ENABLE != 0) && bus_req_valid && !device_selected &&
        !local_resp_valid && !rom_pending;
    assign ddr_resp_ready = bus_resp_ready && !local_resp_valid;
    assign ddr_req_fire = ddr_req_valid && ddr_req_ready;
    assign ddr_resp_fire = ddr_resp_valid && ddr_resp_ready;
    assign bus_req_ready =
        (DDR3_ENABLE != 0) ?
            (device_selected ?
                ((ddr_outstanding == 0) && !local_resp_valid &&
                 !rom_pending) :
                (ddr_req_ready && !local_resp_valid && !rom_pending)) :
            (!memory_pending && !local_resp_valid && !rom_pending);
    assign bus_resp_valid =
        local_resp_valid ||
        ((DDR3_ENABLE != 0) && ddr_resp_valid);
    assign bus_resp_rdata =
        local_resp_valid ? local_resp_rdata : ddr_resp_rdata;
    assign bus_resp_error =
        local_resp_valid ? local_resp_error : ddr_resp_error;

    /*
     * Track requests by the ICX response identity.  The integrated coherence
     * home permits independent lines to overlap, so a single active-request
     * register would reject legal traffic and misattribute reordered replies.
     */
    wire [31:0] icx_req_identity =
        (32'(icx_req_hart_id) * HOME_ID_STRIDE) +
        (32'(icx_req_source_id) <<
         `OPENRV64_ICX_TXN_ID_WIDTH) +
        32'(icx_req_txn_id);
    wire [31:0] icx_resp_identity =
        (32'(icx_resp_hart_id) * HOME_ID_STRIDE) +
        (32'(icx_resp_source_id) <<
         `OPENRV64_ICX_TXN_ID_WIDTH) +
        32'(icx_resp_txn_id);
    wire icx_request_fire = icx_req_valid && icx_req_ready;
    wire icx_response_fire = icx_resp_valid && icx_resp_ready;
    integer atomic_hart;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            home_request_count <= 0;
            coherence_max_target_mshrs <= 0;
            for (home_request_identity = 0;
                 home_request_identity < HOME_IDENTITIES;
                 home_request_identity = home_request_identity + 1) begin
                home_request_valid[home_request_identity] <= 1'b0;
                home_request_op[home_request_identity] <=
                    `OPENRV64_ICX_OP_READ;
            end
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                lr_requests[atomic_hart] <= 0;
                sc_requests[atomic_hart] <= 0;
                sc_successes[atomic_hart] <= 0;
                sc_failures[atomic_hart] <= 0;
                atomic_line_probes[atomic_hart] <= 0;
                reservation_clears[atomic_hart] <= 0;
                coherence_target_reads[atomic_hart] <= 0;
                coherence_target_writes[atomic_hart] <= 0;
                coherence_target_atomics[atomic_hart] <= 0;
                coherence_target_probes[atomic_hart] <= 0;
                tlbi_pte_fences[atomic_hart] <= 0;
                tlbi_old_reads[atomic_hart] <= 0;
                tlbi_new_reads[atomic_hart] <= 0;
                tlbi_reservation_probes[atomic_hart] <= 0;
                ipi_fence_requests[atomic_hart] <= 0;
                ipi_fence_responses[atomic_hart] <= 0;
                ipi_send_requests[atomic_hart] <= 0;
            end
        end else begin
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                if (coherent_reservation_clear[atomic_hart])
                    reservation_clears[atomic_hart] <=
                        reservation_clears[atomic_hart] + 1;
                if ((coherence_perf != 0) &&
                    (|coherence_measure_active) &&
                    probe_valid[atomic_hart] &&
                    probe_ready[atomic_hart] &&
                    (probe_command[
                         atomic_hart*`OPENRV64_ICX_PROBE_CMD_WIDTH +:
                         `OPENRV64_ICX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_ICX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_ICX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_ICX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_ICX_PROBE_CACHE_D)) &&
                    coherence_target_address(
                        probe_line_addr[atomic_hart*64 +: 64]))
                    coherence_target_probes[atomic_hart] <=
                        coherence_target_probes[atomic_hart] + 1;
                if ((atomic_test != 0) &&
                    atomic_counter_va_valid &&
                    probe_valid[atomic_hart] &&
                    probe_ready[atomic_hart] &&
                    (probe_command[
                         atomic_hart*`OPENRV64_ICX_PROBE_CMD_WIDTH +:
                         `OPENRV64_ICX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_ICX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_ICX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_ICX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_ICX_PROBE_CACHE_D)) &&
                    (probe_line_addr[atomic_hart*64 +: 64] ==
                     (atomic_counter_pa() &
                      64'hffff_ffff_ffff_ffc0)))
                    atomic_line_probes[atomic_hart] <=
                        atomic_line_probes[atomic_hart] + 1;
                if ((tlbi_test != 0) &&
                    tlbi_reservation_va_valid &&
                    probe_valid[atomic_hart] &&
                    probe_ready[atomic_hart] &&
                    (probe_command[
                         atomic_hart*`OPENRV64_ICX_PROBE_CMD_WIDTH +:
                         `OPENRV64_ICX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_ICX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_ICX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_ICX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_ICX_PROBE_CACHE_D)) &&
                    (probe_line_addr[atomic_hart*64 +: 64] ==
                     (tlbi_reservation_pa() &
                      64'hffff_ffff_ffff_ffc0)))
                    tlbi_reservation_probes[atomic_hart] <=
                        tlbi_reservation_probes[atomic_hart] + 1;
            end
            if ((coherence_perf != 0) &&
                (|coherence_measure_active) &&
                l2_req_valid && l2_req_ready &&
                (l2_req_source_id ==
                 `OPENRV64_ICX_SOURCE_DCACHE) &&
                coherence_target_address(l2_req_addr)) begin
                if (l2_req_op == `OPENRV64_ICX_OP_WRITE)
                    coherence_target_writes[l2_req_hart_id] <=
                        coherence_target_writes[l2_req_hart_id] + 1;
                else if (l2_req_op == `OPENRV64_ICX_OP_READ)
                    coherence_target_reads[l2_req_hart_id] <=
                        coherence_target_reads[l2_req_hart_id] + 1;
            end
            if ((coherence_perf != 0) &&
                (|coherence_measure_active) &&
                (coherence_target_mshrs >
                 coherence_max_target_mshrs))
                coherence_max_target_mshrs <=
                    coherence_target_mshrs;
            if ((ipi_test == 2) && l2_req_valid && l2_req_ready &&
                (l2_req_source_id == `OPENRV64_ICX_SOURCE_DCACHE) &&
                (l2_req_op == `OPENRV64_ICX_OP_WRITE) &&
                (l2_req_addr >= CLINT_BASE) &&
                (l2_req_addr < CLINT_BASE + (NUM_HARTS * 4)) &&
                (l2_wdata[8*l2_req_addr[5:0] +: 32] == 32'd1)) begin
                /*
                 * Each test IPI is preceded by one publication fence.  The
                 * one credit available before the first send is its startup
                 * fence.  Requiring a completed, unconsumed response here
                 * proves that wake delivery cannot overtake the L2 response.
                 */
                if (ipi_fence_responses[l2_req_hart_id] !=
                    (ipi_send_requests[l2_req_hart_id] + 2))
                    $fatal(1,
                        "hart %0d MSIP write without current L2 fence acknowledgment fences=%0d prior_sends=%0d expected=%0d",
                        l2_req_hart_id,
                        ipi_fence_responses[l2_req_hart_id],
                        ipi_send_requests[l2_req_hart_id],
                        ipi_send_requests[l2_req_hart_id] + 2);
                ipi_send_requests[l2_req_hart_id] <=
                    ipi_send_requests[l2_req_hart_id] + 1;
            end
            if (icx_request_fire) begin
                if (icx_req_identity >= HOME_IDENTITIES)
                    $fatal(1,
                        "coherence home accepted invalid identity hart=%0d source=%0d txn=%0d",
                        icx_req_hart_id, icx_req_source_id,
                        icx_req_txn_id);
                if (home_request_valid[icx_req_identity])
                    $fatal(1,
                        "coherence home reused active identity hart=%0d source=%0d txn=%0d",
                        icx_req_hart_id, icx_req_source_id,
                        icx_req_txn_id);
                home_request_valid[icx_req_identity] <= 1'b1;
                home_request_op[icx_req_identity] <= icx_req_op;
                if ((ipi_test == 2) &&
                    (icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_DCACHE) &&
                    (icx_req_op == `OPENRV64_ICX_OP_FENCE))
                    ipi_fence_requests[icx_req_hart_id] <=
                        ipi_fence_requests[icx_req_hart_id] + 1;
                if (icx_req_op == `OPENRV64_ICX_OP_LR)
                    lr_requests[icx_req_hart_id] <=
                        lr_requests[icx_req_hart_id] + 1;
                if (icx_req_op == `OPENRV64_ICX_OP_SC)
                    sc_requests[icx_req_hart_id] <=
                        sc_requests[icx_req_hart_id] + 1;
                /*
                 * ISA AMOs are lowered by rv64-a into a coherent LR/SC
                 * sequence before this ICX boundary.  Count the target-line
                 * LR as an atomic attempt; SC success/failure is counted on
                 * the matching response below.
                 */
                if ((coherence_perf != 0) &&
                    (|coherence_measure_active) &&
                    (icx_req_source_id ==
                     `OPENRV64_ICX_SOURCE_DCACHE) &&
                    (icx_req_op == `OPENRV64_ICX_OP_LR) &&
                    coherence_target_address(icx_req_addr))
                    coherence_target_atomics[icx_req_hart_id] <=
                        coherence_target_atomics[icx_req_hart_id] + 1;
                if ((tlbi_test != 0) &&
                    (icx_req_hart_id < NUM_HARTS)) begin
                    if ((icx_req_source_id ==
                         `OPENRV64_ICX_SOURCE_PTW) &&
                        (icx_req_op == `OPENRV64_ICX_OP_FENCE))
                        tlbi_pte_fences[icx_req_hart_id] <=
                            tlbi_pte_fences[icx_req_hart_id] + 1;
                    if ((icx_req_source_id ==
                         `OPENRV64_ICX_SOURCE_DCACHE) &&
                        ((icx_req_op == `OPENRV64_ICX_OP_READ) ||
                         (icx_req_op == `OPENRV64_ICX_OP_LR))) begin
                        if ((icx_req_addr &
                             64'hffff_ffff_ffff_ffc0) ==
                            (tlbi_old_pa &
                             64'hffff_ffff_ffff_ffc0))
                            tlbi_old_reads[icx_req_hart_id] <=
                                tlbi_old_reads[icx_req_hart_id] + 1;
                        if ((icx_req_addr &
                             64'hffff_ffff_ffff_ffc0) ==
                            (tlbi_new_pa &
                             64'hffff_ffff_ffff_ffc0))
                            tlbi_new_reads[icx_req_hart_id] <=
                                tlbi_new_reads[icx_req_hart_id] + 1;
                    end
                end
            end

            if (icx_response_fire) begin
                if ((icx_resp_identity >= HOME_IDENTITIES) ||
                    !home_request_valid[icx_resp_identity])
                    $fatal(1,
                        "coherence home produced response without matching request hart=%0d source=%0d txn=%0d",
                        icx_resp_hart_id, icx_resp_source_id,
                        icx_resp_txn_id);
                if (home_request_op[icx_resp_identity] ==
                    `OPENRV64_ICX_OP_SC) begin
                    if (icx_resp_sc_success)
                        sc_successes[icx_resp_hart_id] <=
                            sc_successes[icx_resp_hart_id] + 1;
                    else
                        sc_failures[icx_resp_hart_id] <=
                            sc_failures[icx_resp_hart_id] + 1;
                end
                if ((ipi_test == 2) &&
                    (icx_resp_source_id ==
                     `OPENRV64_ICX_SOURCE_DCACHE) &&
                    (home_request_op[icx_resp_identity] ==
                     `OPENRV64_ICX_OP_FENCE))
                    ipi_fence_responses[icx_resp_hart_id] <=
                        ipi_fence_responses[icx_resp_hart_id] + 1;
                home_request_valid[icx_resp_identity] <= 1'b0;
            end

            case ({icx_request_fire, icx_response_fire})
                2'b10:
                    home_request_count <= home_request_count + 1;
                2'b01:
                    home_request_count <= home_request_count - 1;
                default:
                    home_request_count <= home_request_count;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memory_pending <= 1'b0;
            memory_pending_write <= 1'b0;
            memory_pending_addr <= 64'd0;
            memory_delay <= 0;
            local_resp_valid <= 1'b0;
            local_resp_rdata <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            local_resp_error <= 1'b0;
            rom_pending <= 1'b0;
            ddr_outstanding <= 6'd0;
            memory_reads <= 0;
            memory_writes <= 0;
        end else begin
            if (local_resp_valid && bus_resp_ready)
                local_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                local_resp_error <= 1'b0;
                if (device_selected) begin
                    if (rom_selected) begin
                        if ((bus_req_size != 3'd6) ||
                            (bus_req_addr[5:0] != 6'd0))
                            $fatal(1,
                                "malformed ROM line request addr=%h size=%0d",
                                bus_req_addr, bus_req_size);
                        rom_pending <= 1'b1;
                    end
                    else if (clint_selected) begin
                        local_resp_valid <= 1'b1;
                        local_resp_rdata <=
                            {448'd0, clint_rdata} <<
                            (bus_req_addr[5:3] * 64);
                    end else if (plic_selected) begin
                        local_resp_valid <= 1'b1;
                        local_resp_rdata <=
                            {448'd0, plic_rdata} <<
                            (bus_req_addr[5:3] * 64);
                    end else begin
                        local_resp_valid <= 1'b1;
                        local_resp_rdata <=
                            {448'd0, uart_rdata} <<
                            (bus_req_addr[5:3] * 64);
                    end
                end else begin
                    if (!(dram_line_request_shape ||
                          dram_scalar_write_shape) ||
                        !bus_req_cacheable ||
                        (bus_req_addr < PHYSICAL_BASE) ||
                        (bus_req_addr >= PHYSICAL_BASE + MEMORY_BYTES))
                        $fatal(1,
                            "malformed/out-of-range L2 request addr=%h size=%0d write=%0b cacheable=%0b wstrb=%h",
                            bus_req_addr, bus_req_size, bus_req_write,
                            bus_req_cacheable, bus_req_wstrb);
                    if (DDR3_ENABLE == 0) begin
                        memory_pending <= 1'b1;
                        memory_pending_write <= bus_req_write;
                        memory_pending_addr <= bus_req_addr;
                        memory_delay <= MEMORY_LATENCY - 1;
                    end
                    if (bus_req_write) begin
                        memory_writes <= memory_writes + 1;
                        if (DDR3_ENABLE == 0) begin
                            for (memory_byte = 0;
                                 memory_byte <
                                     `OPENRV64_ICX_LINE_STRB_WIDTH;
                                 memory_byte = memory_byte + 1)
                                if (bus_req_wstrb[memory_byte])
                                    memory[memory_line(bus_req_addr)][
                                        memory_byte*8 +: 8] <=
                                        bus_req_wdata[
                                            memory_byte*8 +: 8];
                        end
                    end else begin
                        memory_reads <= memory_reads + 1;
                    end
                end
            end else if (rom_pending && (&rom_ready)) begin
                rom_pending <= 1'b0;
                local_resp_valid <= 1'b1;
                local_resp_error <= 1'b0;
                local_resp_rdata <= rom_rdata;
            end else if ((DDR3_ENABLE == 0) && memory_pending) begin
                if (memory_delay == 0) begin
                    memory_pending <= 1'b0;
                    local_resp_valid <= 1'b1;
                    local_resp_error <= 1'b0;
                    local_resp_rdata <= memory_pending_write ?
                        {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}} :
                        memory[memory_line(memory_pending_addr)];
                end else begin
                    memory_delay <= memory_delay - 1;
                end
            end

            case ({ddr_req_fire, ddr_resp_fire})
                2'b10: ddr_outstanding <= ddr_outstanding + 1'b1;
                2'b01: ddr_outstanding <= ddr_outstanding - 1'b1;
                default: begin end
            endcase

            if ((DDR3_ENABLE != 0) && ddr_resp_fire &&
                (ddr_outstanding == 0))
                $fatal(1, "DDR3 response without an accepted L2 request");
            if ((DDR3_ENABLE != 0) && (ddr_outstanding > 6'd16))
                $fatal(1,
                    "DDR3/genbus outstanding count exceeded buffers: %0d",
                    ddr_outstanding);
        end
    end

    /*
     * Track the L2-facing write command/data pair.  Checking here, above the
     * write-back L2, proves each identical virtual mailbox reached the
     * physical prefix selected by that hart's page tables.
     */
    integer mailbox_hart;
    integer mailbox_byte_offset;
    integer result_byte_offset;
    integer atomic_byte_offset;
    logic [31:0] observed_atomic_value;
    logic [63:0] observed_write_addr;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] observed_write_hart;
    logic [63:0] hart_start_mailbox_addr;
    logic [63:0] hart_start_signature_expected;
    logic [63:0] hart_start_response_expected;
    logic [63:0] hart_start_counter_observed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_write_active <= 1'b0;
            l2_write_addr <= 64'd0;
            l2_write_hart <=
                {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            atomic_last_value <= 0;
            atomic_final_seen <= 1'b0;
            opensbi_magic_seen <= 1'b0;
            hart_start_counter_last <= 64'd0;
            for (mailbox_hart = 0;
                 mailbox_hart < NUM_HARTS;
                 mailbox_hart = mailbox_hart + 1) begin
                mailbox_seen[mailbox_hart] <= 1'b0;
                result_seen[mailbox_hart] <= 1'b0;
                perf_fields_seen[mailbox_hart] <= 7'd0;
                perf_signature[mailbox_hart] <= 64'd0;
                perf_start_cycle[mailbox_hart] <= 64'd0;
                perf_end_cycle[mailbox_hart] <= 64'd0;
                perf_elapsed_cycles[mailbox_hart] <= 64'd0;
                perf_start_instret[mailbox_hart] <= 64'd0;
                perf_end_instret[mailbox_hart] <= 64'd0;
                perf_retired[mailbox_hart] <= 64'd0;
                atomic_l2_successes[mailbox_hart] <= 0;
                hart_start_private_seen[mailbox_hart] <= 1'b0;
                hart_start_response_seen[mailbox_hart] <= 1'b0;
            end
        end else begin
            if (l2_req_valid && l2_req_ready &&
                (l2_req_op == `OPENRV64_ICX_OP_WRITE)) begin
                if (l2_write_active)
                    $fatal(1, "overlapping L2 write commands in scoreboard");
                l2_write_active <= 1'b1;
                l2_write_addr <= l2_req_addr;
                l2_write_hart <= l2_req_hart_id;
            end

            if (l2_wdata_valid && l2_wdata_ready) begin
                observed_write_addr = l2_write_active ?
                    l2_write_addr : l2_req_addr;
                observed_write_hart = l2_write_active ?
                    l2_write_hart : l2_req_hart_id;
                if (!l2_write_active &&
                    !(l2_req_valid && l2_req_ready &&
                      (l2_req_op == `OPENRV64_ICX_OP_WRITE)))
                    $fatal(1, "L2 write data without a write command");
                l2_write_active <= 1'b0;

                if (opensbi_mode &&
                    ((observed_write_addr &
                      64'hffff_ffff_ffff_ffc0) ==
                     (OPENSBI_MAGIC_ADDR &
                      64'hffff_ffff_ffff_ffc0)) &&
                    (l2_wstrb[
                        OPENSBI_MAGIC_ADDR[5:0] +: 8] == 8'hff) &&
                    (l2_wdata[
                        OPENSBI_MAGIC_ADDR[5:0]*8 +: 64] ==
                     OPENSBI_MAGIC_VALUE)) begin
                    if (observed_write_hart != 0)
                        $fatal(1,
                            "OpenSBI completion written by non-boot hart %0d",
                            observed_write_hart);
                    opensbi_magic_seen <= 1'b1;
                end

                if ((opensbi_hart_start != 0) &&
                    ((observed_write_addr &
                      64'hffff_ffff_ffff_ffc0) ==
                     (HART_START_FAILURE_ADDR &
                      64'hffff_ffff_ffff_ffc0)) &&
                    (l2_wstrb[
                        HART_START_FAILURE_ADDR[5:0] +: 8] ==
                     8'hff) &&
                    (l2_wdata[
                        HART_START_FAILURE_ADDR[5:0]*8 +: 64] !=
                     64'd0))
                    $fatal(1,
                        "SBI hart_start payload failure code=%h writer=%0d",
                        l2_wdata[
                            HART_START_FAILURE_ADDR[5:0]*8 +: 64],
                        observed_write_hart);

                if ((opensbi_hart_start != 0) &&
                    ((observed_write_addr &
                      64'hffff_ffff_ffff_ffc0) ==
                     (HART_START_COUNTER_ADDR &
                      64'hffff_ffff_ffff_ffc0)) &&
                    (l2_wstrb[
                        HART_START_COUNTER_ADDR[5:0] +: 8] ==
                     8'hff)) begin
                    hart_start_counter_observed =
                        l2_wdata[
                            HART_START_COUNTER_ADDR[5:0]*8 +: 64];
                    if (hart_start_counter_observed >
                        opensbi_active_harts *
                        HART_START_ATOMIC_ITERATIONS)
                        $fatal(1,
                            "SBI hart_start counter exceeded expected value observed=%0d expected=%0d",
                            hart_start_counter_observed,
                            opensbi_active_harts *
                            HART_START_ATOMIC_ITERATIONS);
                    hart_start_counter_last <=
                        hart_start_counter_observed;
                end

                for (mailbox_hart = 0;
                     mailbox_hart < NUM_HARTS;
                     mailbox_hart = mailbox_hart + 1) begin
                    hart_start_mailbox_addr =
                        HART_START_MAILBOX_BASE +
                        mailbox_hart * 64;
                    hart_start_signature_expected =
                        HART_START_SIGNATURE_BASE + mailbox_hart;
                    hart_start_response_expected =
                        HART_START_SIGNATURE_BASE +
                        HART_START_COMMAND_BASE +
                        mailbox_hart * 2;
                    if ((opensbi_hart_start != 0) &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         hart_start_mailbox_addr)) begin
                        if ((l2_wstrb[0 +: 8] == 8'hff) &&
                            (l2_wdata[0 +: 64] ==
                             hart_start_signature_expected)) begin
                            if (observed_write_hart != mailbox_hart)
                                $fatal(1,
                                    "SBI hart_start private signature written by wrong hart owner=%0d expected=%0d",
                                    observed_write_hart,
                                    mailbox_hart);
                            hart_start_private_seen[mailbox_hart] <=
                                1'b1;
                        end
                        if ((l2_wstrb[16 +: 8] == 8'hff) &&
                            (l2_wdata[16*8 +: 64] ==
                             hart_start_response_expected)) begin
                            if (observed_write_hart != mailbox_hart)
                                $fatal(1,
                                    "SBI hart_start response written by wrong hart owner=%0d expected=%0d",
                                    observed_write_hart,
                                    mailbox_hart);
                            hart_start_response_seen[mailbox_hart] <=
                                1'b1;
                        end
                    end

                    if (mailbox_va_valid &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         (mailbox_pa(mailbox_hart) &
                          64'hffff_ffff_ffff_ffc0))) begin
                        mailbox_byte_offset =
                            mailbox_pa(mailbox_hart)[5:0];
                        if (l2_wstrb[
                                mailbox_byte_offset +: 4] == 4'hf) begin
                            if ((observed_write_hart != mailbox_hart) ||
                                (l2_wdata[
                                     mailbox_byte_offset*8 +: 32] !=
                                 32'(mailbox_hart + 1)))
                                $fatal(1,
                                    "bad mailbox write hart=%0d owner=%0d addr=%h data=%h strb=%h",
                                    mailbox_hart, observed_write_hart,
                                    observed_write_addr, l2_wdata,
                                    l2_wstrb);
                            mailbox_seen[mailbox_hart] <= 1'b1;
                            $display(
                                "MAILBOX_VISIBLE cycle=%0d hart=%0d pa=%h value=%0d",
                                cycles, mailbox_hart,
                                mailbox_pa(mailbox_hart),
                                mailbox_hart + 1);
                        end
                    end

                    if (result_va_valid &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         (result_pa(mailbox_hart) &
                          64'hffff_ffff_ffff_ffc0))) begin
                        result_byte_offset =
                            result_pa(mailbox_hart)[5:0];
                        if (l2_wstrb[
                                result_byte_offset +: 4] == 4'hf) begin
                            if ((observed_write_hart != mailbox_hart) ||
                                (l2_wdata[
                                     result_byte_offset*8 +: 32] !=
                                 32'(result_expected)))
                                $fatal(1,
                                    "bad result write hart=%0d owner=%0d addr=%h value=%0d expected=%0d",
                                    mailbox_hart, observed_write_hart,
                                    observed_write_addr,
                                    l2_wdata[
                                        result_byte_offset*8 +: 32],
                                    result_expected);
                            result_seen[mailbox_hart] <= 1'b1;
                        end
                    end

                    if (perf_results_va_valid &&
                        ((observed_write_addr &
                          64'hffff_ffff_ffff_ffc0) ==
                         (perf_result_pa(mailbox_hart) &
                          64'hffff_ffff_ffff_ffc0))) begin
                        if (observed_write_hart != mailbox_hart)
                            $fatal(1,
                                "bare performance result written by wrong hart owner=%0d expected=%0d addr=%h",
                                observed_write_hart, mailbox_hart,
                                observed_write_addr);
                        if (l2_wstrb[8 +: 8] == 8'hff) begin
                            perf_signature[mailbox_hart] <=
                                l2_wdata[8*8 +: 64];
                            perf_fields_seen[mailbox_hart][0] <= 1'b1;
                        end
                        if (l2_wstrb[16 +: 8] == 8'hff) begin
                            perf_start_cycle[mailbox_hart] <=
                                l2_wdata[16*8 +: 64];
                            perf_fields_seen[mailbox_hart][1] <= 1'b1;
                        end
                        if (l2_wstrb[24 +: 8] == 8'hff) begin
                            perf_end_cycle[mailbox_hart] <=
                                l2_wdata[24*8 +: 64];
                            perf_fields_seen[mailbox_hart][2] <= 1'b1;
                        end
                        if (l2_wstrb[32 +: 8] == 8'hff) begin
                            perf_elapsed_cycles[mailbox_hart] <=
                                l2_wdata[32*8 +: 64];
                            perf_fields_seen[mailbox_hart][3] <= 1'b1;
                        end
                        if (l2_wstrb[40 +: 8] == 8'hff) begin
                            perf_start_instret[mailbox_hart] <=
                                l2_wdata[40*8 +: 64];
                            perf_fields_seen[mailbox_hart][4] <= 1'b1;
                        end
                        if (l2_wstrb[48 +: 8] == 8'hff) begin
                            perf_end_instret[mailbox_hart] <=
                                l2_wdata[48*8 +: 64];
                            perf_fields_seen[mailbox_hart][5] <= 1'b1;
                        end
                        if (l2_wstrb[56 +: 8] == 8'hff) begin
                            perf_retired[mailbox_hart] <=
                                l2_wdata[56*8 +: 64];
                            perf_fields_seen[mailbox_hart][6] <= 1'b1;
                        end
                    end
                end

                if (atomic_counter_va_valid &&
                    ((observed_write_addr &
                      64'hffff_ffff_ffff_ffc0) ==
                     (atomic_counter_pa() &
                      64'hffff_ffff_ffff_ffc0))) begin
                    atomic_byte_offset = atomic_counter_pa() & 63;
                    if (l2_wstrb[
                            atomic_byte_offset +: 4] != 4'hf)
                        $fatal(1,
                            "partial atomic counter write addr=%h strb=%h",
                            observed_write_addr, l2_wstrb);
                    observed_atomic_value =
                        l2_wdata[atomic_byte_offset*8 +: 32];
                    if ((observed_write_hart !=
                         (atomic_last_value & 3)) ||
                        (observed_atomic_value !=
                         atomic_last_value + 1))
                        $fatal(1,
                            "atomic order failure old=%0d new=%0d owner=%0d expected_owner=%0d",
                            atomic_last_value, observed_atomic_value,
                            observed_write_hart,
                            atomic_last_value & 3);
                    atomic_last_value <= observed_atomic_value;
                    atomic_l2_successes[observed_write_hart] <=
                        atomic_l2_successes[observed_write_hart] + 1;
                    if (observed_atomic_value == atomic_expected)
                        atomic_final_seen <= 1'b1;
                    else if (observed_atomic_value > atomic_expected)
                        $fatal(1,
                            "atomic counter exceeded expected value %0d",
                            atomic_expected);
                end
            end
        end
    end

    assign checkpoint_cycle_o = cycles;

`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
    always @* clk = checkpoint_clk_i;
`else
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end
`endif

    integer init_hart;
    string memh_path;
    string trampoline_memh_path;
    string firmware_memh_path;
    string payload_memh_path;
    string fdt_memh_path;
    integer memh_words;

    task automatic load_image_fragment;
        input string path;
        input [63:0] base;
        input integer word_count;
        integer image_word;
        begin
            if ((base < PHYSICAL_BASE) ||
                (base + word_count*8 >
                 PHYSICAL_BASE + MEMORY_BYTES))
                $fatal(1,
                    "OpenSBI image out of range base=%h words=%0d memory_bytes=%0d",
                    base, word_count, MEMORY_BYTES);
            $readmemh(path, image_words, 0, word_count - 1);
            for (image_word = 0;
                 image_word < word_count;
                 image_word = image_word + 1)
                memory[
                    memory_line(base) + (image_word >> 3)][
                    (image_word & 7)*64 +: 64] =
                        image_words[image_word];
        end
    endtask

    task automatic match_opensbi_byte;
        input logic [7:0] value;
        begin
            if (!opensbi_banner_seen) begin
                if (value ==
                    opensbi_banner[opensbi_banner_index]) begin
                    opensbi_banner_index =
                        opensbi_banner_index + 1;
                    if (opensbi_banner_index ==
                        opensbi_banner.len())
                        opensbi_banner_seen = 1'b1;
                end else begin
                    opensbi_banner_index =
                        (value == opensbi_banner[0]) ? 1 : 0;
                end
            end
            if (!opensbi_payload_seen) begin
                if (value ==
                    opensbi_payload_text[
                        opensbi_payload_index]) begin
                    opensbi_payload_index =
                        opensbi_payload_index + 1;
                    if (opensbi_payload_index ==
                        opensbi_payload_text.len())
                        opensbi_payload_seen = 1'b1;
                end else begin
                    opensbi_payload_index =
                        (value == opensbi_payload_text[0]) ? 1 : 0;
                end
            end
            if ((linux_mode != 0) && !linux_prompt_seen) begin
                if (value == linux_prompt_text[linux_prompt_index]) begin
                    linux_prompt_index = linux_prompt_index + 1;
                    if (linux_prompt_index ==
                        linux_prompt_text.len())
                        linux_prompt_seen = 1'b1;
                end else begin
                    linux_prompt_index =
                        (value == linux_prompt_text[0]) ? 1 : 0;
                end
            end
            if ((linux_mode != 0) && !linux_panic_seen) begin
                if (value == linux_panic_text[linux_panic_index]) begin
                    linux_panic_index = linux_panic_index + 1;
                    if (linux_panic_index ==
                        linux_panic_text.len())
                        linux_panic_seen = 1'b1;
                end else begin
                    linux_panic_index =
                        (value == linux_panic_text[0]) ? 1 : 0;
                end
            end
            if ((linux_mode != 0) && (opensbi_smp != 0) &&
                !linux_smp_online_seen) begin
                if (value ==
                    linux_smp_online_text[linux_smp_online_index]) begin
                    linux_smp_online_index =
                        linux_smp_online_index + 1;
                    if (linux_smp_online_index ==
                        linux_smp_online_text.len()) begin
                        linux_smp_online_seen = 1'b1;
                        $display(
                            "\nLINUX_SMP_ONLINE cycles=%0d active_harts=%0d s_mode=%b retired=%0d,%0d,%0d,%0d",
                            cycles, opensbi_active_harts,
                            opensbi_s_mode_hart_seen,
                            retired[0], retired[1],
                            retired[2], retired[3]);
                    end
                end else begin
                    linux_smp_online_index =
                        (value == linux_smp_online_text[0]) ? 1 : 0;
                end
            end
            if ((linux_mode != 0) && !linux_smp_threads_seen) begin
                if (value ==
                    linux_smp_threads_text[linux_smp_threads_index]) begin
                    linux_smp_threads_index =
                        linux_smp_threads_index + 1;
                    if (linux_smp_threads_index ==
                        linux_smp_threads_text.len()) begin
                        linux_smp_threads_seen = 1'b1;
                        $display(
                            "\nLINUX_SMP_THREADS cycles=%0d retired=%0d,%0d,%0d,%0d",
                            cycles, retired[0], retired[1],
                            retired[2], retired[3]);
                    end
                end else begin
                    linux_smp_threads_index =
                        (value == linux_smp_threads_text[0]) ? 1 : 0;
                end
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
        checkpoint_reset_edges = 0;
        checkpoint_ddr_load_pending = 1'b0;
`endif
        opensbi_held = $test$plusargs("opensbi_held");
        gate_held_hart_clocks =
            $test$plusargs("gate_held_hart_clocks");
        opensbi_smp = $test$plusargs("opensbi_smp");
        opensbi_hart_start =
            $test$plusargs("opensbi_hart_start");
        linux_mode = $test$plusargs("linux_mode");
        require_smp_threads =
            $test$plusargs("require_smp_threads");
        pc_trace_fd = 0;
        pc_trace_mask = (1 << NUM_HARTS) - 1;
        pc_trace_path = "";
        void'($value$plusargs("pc_trace_mask=%h", pc_trace_mask));
        if ($value$plusargs("pc_trace=%s", pc_trace_path)) begin
            pc_trace_fd = $fopen(pc_trace_path, "w");
            if (pc_trace_fd == 0)
                $fatal(1,
                    "failed to open PC trace %s", pc_trace_path);
            $fdisplay(pc_trace_fd,
                "# OpenRV64 4H retirement and trap PC trace mask=%h",
                pc_trace_mask);
            $fflush(pc_trace_fd);
        end
        opensbi_mode =
            (opensbi_held != 0) || (opensbi_smp != 0);
        opensbi_active_harts =
            (opensbi_held != 0) ? 1 : CORE_INSTANCES;
        if (opensbi_mode != 0)
            void'($value$plusargs(
                "opensbi_active_harts=%d", opensbi_active_harts));
        else
            void'($value$plusargs(
                "active_harts=%d", opensbi_active_harts));
        if ((CORE_INSTANCES < 1) || (CORE_INSTANCES > NUM_HARTS))
            $fatal(1,
                "CORE_INSTANCES must be 1 through %0d", NUM_HARTS);
        if (opensbi_active_harts > CORE_INSTANCES)
            $fatal(1,
                "active hart count %0d exceeds instantiated cores %0d",
                opensbi_active_harts, CORE_INSTANCES);
        case (opensbi_active_harts)
            1: opensbi_active_hart_mask = 4'b0001;
            2: opensbi_active_hart_mask = 4'b0011;
            3: opensbi_active_hart_mask = 4'b0111;
            4: opensbi_active_hart_mask = 4'b1111;
            default:
                $fatal(1,
                    "active hart count must be 1 through 4");
        endcase
        linux_smp_online_text = $sformatf(
            "smp: Brought up 1 node, %0d CPUs",
            opensbi_active_harts);
        opensbi_hsm_wfi_pc = 64'd0;
        done_pc = 64'd0;
        mailbox_va = 64'd0;
        result_va = 64'd0;
        perf_results_va = 64'd0;
        coherence_base_va = 64'd0;
        coherence_measure_start_pc = 64'd0;
        coherence_measure_end_pc = 64'd0;
        atomic_counter_va = 64'd0;
        tlbi_reservation_va = 64'd0;
        tlbi_target_va = 64'd0;
        tlbi_old_pa = 64'd0;
        tlbi_new_pa = 64'd0;
        done_pc_valid = 1'b0;
        mailbox_va_valid = 1'b0;
        result_va_valid = 1'b0;
        perf_results_va_valid = 1'b0;
        atomic_counter_va_valid = 1'b0;
        tlbi_reservation_va_valid = 1'b0;
        tlbi_target_va_valid = 1'b0;
        tlbi_old_pa_valid = 1'b0;
        tlbi_new_pa_valid = 1'b0;
        shared_satp = 0;
        bare_mode = 0;
        mailbox_stride = 0;
        result_expected = 0;
        perf_iterations = 0;
        perf_name = "BARE";
        coherence_perf = 0;
        coherence_case = 0;
        coherence_lines = 0;
        coherence_line_stride = 64;
        coherence_operations = 0;
        atomic_expected = 0;
        atomic_test = 0;
        tlbi_test = 0;
        ipi_test = 0;
        ipi_expected = 0;
        atomic_debug = 0;
        max_cycles = 800000;
        cycles = 0;
        first_done_cycle = -1;
        debug_counter_window_enabled = 0;
        debug_counter_start_arg_seen = 0;
        debug_counter_stop_arg_seen = 0;
        debug_counter_start_pc = 64'd0;
        debug_counter_stop_pc = 64'd0;
        debug_counter_start_seen = 1'b0;
        debug_counter_report_seen = 1'b0;
        debug_counter_start_cycle = 64'd0;
        debug_counter_start_retired = 64'd0;
        debug_counter_start_requests = 64'd0;
        debug_counter_start_memory_reads = 0;
        debug_counter_start_memory_writes = 0;
        for (debug_counter_init_index = 0;
             debug_counter_init_index < 91;
             debug_counter_init_index = debug_counter_init_index + 1)
            debug_counter_start_q[debug_counter_init_index] = 64'd0;
        progress_before_first_done = 1'b0;
        opensbi_s_mode_seen = 1'b0;
        opensbi_banner_seen = 1'b0;
        opensbi_payload_seen = 1'b0;
        opensbi_banner_index = 0;
        opensbi_payload_index = 0;
        linux_prompt_seen = 1'b0;
        linux_panic_seen = 1'b0;
        linux_smp_online_seen = 1'b0;
        linux_smp_threads_seen = 1'b0;
        linux_prompt_index = 0;
        linux_panic_index = 0;
        linux_smp_online_index = 0;
        linux_smp_threads_index = 0;
        opensbi_uart_bytes = 0;
        opensbi_trace_write = 0;
        opensbi_trace_count = 0;
        opensbi_hang_cycles = 0;
        if (opensbi_hart_start != 0)
            opensbi_payload_text =
                "OPENRV64 SBI HART_START MEMORY PASS";

        for (memory_index = 0;
             memory_index < MEMORY_WORDS;
             memory_index = memory_index + 1)
            memory[memory_index] =
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};

        if (opensbi_mode) begin
            if ((gate_held_hart_clocks != 0) &&
                (opensbi_active_harts == NUM_HARTS))
                $fatal(1,
                    "+gate_held_hart_clocks requires inactive harts");
            if ((opensbi_held != 0) && (opensbi_smp != 0))
                $fatal(1,
                    "+opensbi_held and +opensbi_smp are mutually exclusive");
            if ((opensbi_held != 0) &&
                (opensbi_active_harts != 1))
                $fatal(1,
                    "+opensbi_held requires +opensbi_active_harts=1");
            if ((opensbi_smp != 0) &&
                (opensbi_active_harts == 1))
                $fatal(1,
                    "+opensbi_smp requires at least two active harts");
            if ((opensbi_hart_start != 0) &&
                ((opensbi_smp == 0) || (linux_mode != 0)))
                $fatal(1,
                    "+opensbi_hart_start requires +opensbi_smp and excludes +linux_mode");
            if ((linux_mode != 0) && (opensbi_mode == 0))
                $fatal(1,
                    "+linux_mode requires an OpenSBI mode");
            if (ENABLE_BOOT_ROM == 0)
                $fatal(1,
                    "OpenSBI mode requires ENABLE_BOOT_ROM=1");
            if ((opensbi_smp != 0) &&
                !$value$plusargs(
                    "opensbi_hsm_wfi_pc=%h",
                    opensbi_hsm_wfi_pc))
                $fatal(1,
                    "+opensbi_smp requires +opensbi_hsm_wfi_pc");
            if (!$value$plusargs(
                    "trampoline_memh=%s",
                    trampoline_memh_path) ||
                !$value$plusargs(
                    "firmware_memh=%s",
                    firmware_memh_path) ||
                !$value$plusargs(
                    "payload_memh=%s",
                    payload_memh_path) ||
                !$value$plusargs(
                    "fdt_memh=%s",
                    fdt_memh_path))
                $fatal(1,
                    "OpenSBI mode requires trampoline, firmware, payload, and FDT memh paths");
            load_image_fragment(
                trampoline_memh_path,
                PHYSICAL_BASE,
                OPENSBI_TRAMPOLINE_WORDS);
            load_image_fragment(
                firmware_memh_path,
                PHYSICAL_BASE + 64'h0010_0000,
                OPENSBI_FIRMWARE_WORDS);
            memh_words = OPENSBI_PAYLOAD_WORDS;
            void'($value$plusargs("payload_words=%d", memh_words));
            if ((memh_words <= 0) ||
                (memh_words > OPENSBI_MAX_PAYLOAD_WORDS))
                $fatal(1,
                    "invalid OpenSBI payload_words=%0d max=%0d",
                    memh_words, OPENSBI_MAX_PAYLOAD_WORDS);
            load_image_fragment(
                payload_memh_path,
                PHYSICAL_BASE + 64'h0020_0000,
                memh_words);
            load_image_fragment(
                fdt_memh_path,
                OPENSBI_FDT_BASE,
                OPENSBI_FDT_WORDS);
            max_cycles = 20000000;
            if (opensbi_smp != 0)
                $display(
                    "OpenSBI 4H SMP load complete ROM=%h FDT=%h HSM_WFI_PC=%h memory_bytes=%0d",
                    ROM_BASE, OPENSBI_FDT_BASE,
                    opensbi_hsm_wfi_pc, MEMORY_BYTES);
            else
                $display(
                    "OpenSBI 4H held-reset load complete ROM=%h FDT=%h memory_bytes=%0d held_clock_gating=%0d",
                    ROM_BASE, OPENSBI_FDT_BASE, MEMORY_BYTES,
                    gate_held_hart_clocks);
        end else begin
            if (!$value$plusargs("memh=%s", memh_path))
                $fatal(1,
                    "tb_4h_3p requires +memh=<512-bit image>");
            memh_words = MEMORY_WORDS;
            void'($value$plusargs("memh_words=%d", memh_words));
            if ((memh_words <= 0) ||
                (memh_words > MEMORY_WORDS))
                $fatal(1, "invalid memh_words=%0d", memh_words);
            $readmemh(memh_path, memory, 0, memh_words - 1);

            if ($value$plusargs("done_pc=%h", done_pc))
                done_pc_valid = 1'b1;
            if ($value$plusargs("mailbox_va=%h", mailbox_va))
                mailbox_va_valid = 1'b1;
            if ($value$plusargs("result_va=%h", result_va))
                result_va_valid = 1'b1;
            if ($value$plusargs(
                    "perf_results_va=%h", perf_results_va))
                perf_results_va_valid = 1'b1;
            if ($value$plusargs(
                    "atomic_counter_va=%h", atomic_counter_va))
                atomic_counter_va_valid = 1'b1;
            if ($value$plusargs(
                    "tlbi_reservation_va=%h",
                    tlbi_reservation_va))
                tlbi_reservation_va_valid = 1'b1;
            if ($value$plusargs(
                    "tlbi_target_va=%h", tlbi_target_va))
                tlbi_target_va_valid = 1'b1;
            if ($value$plusargs("tlbi_old_pa=%h", tlbi_old_pa))
                tlbi_old_pa_valid = 1'b1;
            if ($value$plusargs("tlbi_new_pa=%h", tlbi_new_pa))
                tlbi_new_pa_valid = 1'b1;
        end
        void'($value$plusargs("shared_satp=%d", shared_satp));
        void'($value$plusargs("bare=%d", bare_mode));
        void'($value$plusargs("mailbox_stride=%d", mailbox_stride));
        void'($value$plusargs("result_expected=%d", result_expected));
        void'($value$plusargs("perf_iterations=%d", perf_iterations));
        void'($value$plusargs("perf_name=%s", perf_name));
        debug_counter_start_arg_seen = $value$plusargs(
            "debug_counter_start_pc=%h", debug_counter_start_pc);
        debug_counter_stop_arg_seen = $value$plusargs(
            "debug_counter_stop_pc=%h", debug_counter_stop_pc);
        if (debug_counter_start_arg_seen != debug_counter_stop_arg_seen)
            $fatal(1,
                "debug counter window requires both start and stop PCs");
        debug_counter_window_enabled = debug_counter_start_arg_seen &&
                                       debug_counter_stop_arg_seen;
        if (debug_counter_window_enabled)
            $display(
                "DEBUG_COUNTER_WINDOW_CONFIG sync_tag=%0d store_extension=%0d start_pc=%016h stop_pc=%016h",
                L1D_SYNC_TAG_LOOKUP, L1D_SYNC_STORE_EXTENSION,
                debug_counter_start_pc, debug_counter_stop_pc);
        void'($value$plusargs("coherence_perf=%d", coherence_perf));
        void'($value$plusargs("coherence_case=%d", coherence_case));
        void'($value$plusargs("coherence_lines=%d", coherence_lines));
        void'($value$plusargs(
            "coherence_line_stride=%d", coherence_line_stride));
        void'($value$plusargs(
            "coherence_operations=%d", coherence_operations));
        void'($value$plusargs(
            "coherence_base_va=%h", coherence_base_va));
        void'($value$plusargs(
            "coherence_measure_start_pc=%h",
            coherence_measure_start_pc));
        void'($value$plusargs(
            "coherence_measure_end_pc=%h",
            coherence_measure_end_pc));
        void'($value$plusargs("atomic_expected=%d", atomic_expected));
        void'($value$plusargs("atomic_test=%d", atomic_test));
        void'($value$plusargs("tlbi_test=%d", tlbi_test));
        void'($value$plusargs("ipi_test=%d", ipi_test));
        void'($value$plusargs("ipi_expected=%d", ipi_expected));
        void'($value$plusargs("atomic_debug=%d", atomic_debug));
        void'($value$plusargs("max_cycles=%d", max_cycles));
        if (!opensbi_mode &&
            (!done_pc_valid || !mailbox_va_valid))
            $fatal(1, "tb_4h_3p requires +done_pc and +mailbox_va");
        if (!opensbi_mode &&
            ((shared_satp != 0) || (bare_mode != 0)) &&
            (mailbox_stride <= 0))
            $fatal(1,
                "shared-image workload requires positive +mailbox_stride");
        if (!opensbi_mode &&
            (shared_satp != 0) && (bare_mode != 0))
            $fatal(1, "+shared_satp and +bare are mutually exclusive");
        if (!opensbi_mode && perf_results_va_valid &&
            (((bare_mode == 0) && (shared_satp == 0)) ||
             !result_va_valid ||
             (perf_iterations <= 0) ||
             (perf_results_va != mailbox_va)))
            $fatal(1,
                "performance workload requires Bare or shared Sv39, result status, positive iterations, and matching result/mailbox bases");
        if (!opensbi_mode && (coherence_perf != 0) &&
            ((shared_satp == 0) || (bare_mode != 0) ||
             !perf_results_va_valid ||
             (coherence_case < 0) || (coherence_case > 22) ||
             (coherence_lines <= 0) ||
             (coherence_line_stride < 64) ||
             ((coherence_line_stride & 63) != 0) ||
             (coherence_operations <= 0) ||
             (coherence_base_va < VIRTUAL_BASE) ||
             (coherence_measure_start_pc < VIRTUAL_BASE) ||
             (coherence_measure_end_pc < VIRTUAL_BASE) ||
             (coherence_measure_start_pc ==
              coherence_measure_end_pc)))
            $fatal(1,
                "coherence performance workload requires shared Sv39, performance results, case/range/operation metadata, and distinct measurement PCs");
        if (!opensbi_mode &&
            (((atomic_test != 0) && (tlbi_test != 0)) ||
             ((atomic_test != 0) && (ipi_test != 0)) ||
             ((tlbi_test != 0) && (ipi_test != 0))))
            $fatal(1,
                "+atomic_test, +tlbi_test, and +ipi_test are mutually exclusive");
        if (!opensbi_mode && (atomic_test != 0) &&
            (!atomic_counter_va_valid || !result_va_valid ||
             (atomic_expected <= 0) || (result_expected <= 0)))
            $fatal(1,
                "atomic workload requires counter/result addresses and positive expectations");
        if (!opensbi_mode && (tlbi_test != 0) &&
            (!tlbi_reservation_va_valid || !tlbi_target_va_valid ||
             !tlbi_old_pa_valid || !tlbi_new_pa_valid ||
             !result_va_valid || (result_expected != 1) ||
             (shared_satp == 0) || (bare_mode != 0)))
            $fatal(1,
                "TLBI workload requires shared Sv39, reservation/target/old/new addresses, and result=1");
        if (!opensbi_mode && (ipi_test != 0) &&
            (((ipi_test != 1) && (ipi_test != 2)) ||
             ((ipi_test == 1) && (opensbi_active_harts != 2)) ||
             ((ipi_test == 2) && (opensbi_active_harts != 4)) ||
             (ipi_expected <= 0) || !result_va_valid ||
             (result_expected != ipi_expected) ||
             (shared_satp == 0) || (bare_mode != 0)))
            $fatal(1,
                "IPI workload requires mode 1 with two harts or mode 2 with four harts, shared Sv39, a result address, and matching positive expectations");

        if (DDR3_ENABLE != 0) begin
            /*
             * Let the memory-channel initializer finish before copying the
             * assembled 512-bit image into its 256-bit backing array.
             */
`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
            checkpoint_ddr_load_pending = 1'b1;
`else
            #1;
            for (memory_index = 0;
                 memory_index < MEMORY_WORDS;
                 memory_index = memory_index + 1)
                u_ddr_backend.load_line(
                    memory_index, memory[memory_index]);
`endif
            $display(
                "4H memory backend: timed DDR3, 256-bit AXI, genbus=%0dx%0d ddr_queue=%0dx%0dx%0d burst_train=%0d swizzle=%0d",
                GENBUS_READ_BUFFER_DEPTH,
                GENBUS_WRITE_BUFFER_DEPTH,
                DDR3_READ_QUEUE_DEPTH,
                DDR3_WRITE_QUEUE_DEPTH,
                DDR3_COMMAND_QUEUE_DEPTH,
                DDR3_MAX_BURST_TRAIN_BURSTS,
                DDR3_BANK_ROW_SWIZZLE);
        end else begin
            $display(
                "4H memory backend: fixed-latency 512-bit memory latency=%0d",
                MEMORY_LATENCY);
        end

`ifndef OPENRV64_4H_VERILATOR_CHECKPOINT
        repeat (12) @(posedge clk);
        rst_n = 1'b1;
`endif
    end

`ifdef OPENRV64_4H_VERILATOR_CHECKPOINT
    always @(posedge clk) begin
        if (checkpoint_ddr_load_pending) begin
            for (memory_index = 0;
                 memory_index < MEMORY_WORDS;
                 memory_index = memory_index + 1)
                u_ddr_backend.load_line(
                    memory_index, memory[memory_index]);
            checkpoint_ddr_load_pending <= 1'b0;
        end
        if (!rst_n) begin
            checkpoint_reset_edges <= checkpoint_reset_edges + 1;
            if (checkpoint_reset_edges == 11)
                rst_n <= 1'b1;
        end
    end
`endif

    task automatic capture_debug_counter_window;
        begin
            debug_counter_start_cycle = cycles;
            debug_counter_start_retired = retired[0];
            debug_counter_start_requests = requests[0];
            debug_counter_start_memory_reads = memory_reads;
            debug_counter_start_memory_writes = memory_writes;
            debug_counter_start_q[0] =
                g_hart[0].u_core.u_debug.lsq_load_allocations;
            debug_counter_start_q[1] =
                g_hart[0].u_core.u_debug.lsq_load_alloc_wait_cycles;
            debug_counter_start_q[2] =
                g_hart[0].u_core.u_debug.lsq_load_queue_full_cycles;
            debug_counter_start_q[3] =
                g_hart[0].u_core.u_debug.lsq_load_xlate_requests;
            debug_counter_start_q[4] =
                g_hart[0].u_core.u_debug.lsq_load_xlate_wait_cycles;
            debug_counter_start_q[5] =
                g_hart[0].u_core.u_debug.lsq_load_access_requests;
            debug_counter_start_q[6] =
                g_hart[0].u_core.u_debug.lsq_load_access_wait_cycles;
            debug_counter_start_q[7] =
                g_hart[0].u_core.u_debug.lsq_load_responses;
            debug_counter_start_q[8] =
                g_hart[0].u_core.u_debug.lsq_load_completions;
            debug_counter_start_q[9] =
                g_hart[0].u_core.u_debug.lsq_load_dependency_block_cycles;
            debug_counter_start_q[10] = g_hart[0].u_core.u_debug.
                lsq_load_dependency_block_entry_cycles;
            debug_counter_start_q[11] =
                g_hart[0].u_core.u_debug.lsq_load_occupancy_cycles;
            debug_counter_start_q[12] =
                g_hart[0].u_core.u_debug.lsq_store_allocations;
            debug_counter_start_q[13] =
                g_hart[0].u_core.u_debug.lsq_store_alloc_wait_cycles;
            debug_counter_start_q[14] =
                g_hart[0].u_core.u_debug.lsq_store_queue_full_cycles;
            debug_counter_start_q[15] =
                g_hart[0].u_core.u_debug.lsq_store_xlate_requests;
            debug_counter_start_q[16] =
                g_hart[0].u_core.u_debug.lsq_store_xlate_wait_cycles;
            debug_counter_start_q[17] =
                g_hart[0].u_core.u_debug.lsq_store_access_requests;
            debug_counter_start_q[18] =
                g_hart[0].u_core.u_debug.lsq_store_access_wait_cycles;
            debug_counter_start_q[19] =
                g_hart[0].u_core.u_debug.lsq_store_done;
            debug_counter_start_q[20] =
                g_hart[0].u_core.u_debug.lsq_store_order_wait_cycles;
            debug_counter_start_q[21] = g_hart[0].u_core.u_debug.
                lsq_store_order_wait_entry_cycles;
            debug_counter_start_q[22] =
                g_hart[0].u_core.u_debug.lsq_store_occupancy_cycles;
            debug_counter_start_q[23] =
                g_hart[0].u_core.u_debug.lsq_atomic_active_cycles;

            debug_counter_start_q[24] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_req_wait_cycles_q;
            debug_counter_start_q[25] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_read_wait_cycles_q;
            debug_counter_start_q[26] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_write_wait_cycles_q;
            debug_counter_start_q[27] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_req_wait_cycles_q;
            debug_counter_start_q[28] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_miss_q;
            debug_counter_start_q[29] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_miss_wait_cycles_q;
            debug_counter_start_q[30] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_fill_q;
            debug_counter_start_q[31] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_fill_wait_cycles_q;
            debug_counter_start_q[32] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_command_q;
            debug_counter_start_q[33] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_response_q;
            debug_counter_start_q[34] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_l1_response_q;
            debug_counter_start_q[35] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_prefetch_response_q;
            debug_counter_start_q[36] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_normal_overlay_wait_cycles_q;
            debug_counter_start_q[37] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_demand_overlay_wait_cycles_q;
            debug_counter_start_q[38] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_store_buffer_block_cycles_q;
            debug_counter_start_q[39] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_load_store_block_cycles_q;
            debug_counter_start_q[40] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_store_buffer_occupancy_cycles_q;
            debug_counter_start_q[41] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_demand_mshr_occupancy_cycles_q;
            debug_counter_start_q[42] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_demand_mshr_full_cycles_q;
            debug_counter_start_q[43] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_invalidate_capture_q;
            debug_counter_start_q[44] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_invalidate_hold_cycles_q;
            debug_counter_start_q[45] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_invalidate_complete_q;
            debug_counter_start_q[90] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_debug.perf_fast_store_merge_q;

            debug_counter_start_q[46] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_request_wait_cycles_q;
            debug_counter_start_q[47] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_read_wait_cycles_q;
            debug_counter_start_q[48] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_write_wait_cycles_q;
            debug_counter_start_q[49] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_request_fire_q;
            debug_counter_start_q[50] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_read_fire_q;
            debug_counter_start_q[51] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_write_fire_q;
            debug_counter_start_q[52] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_response_fire_q;
            debug_counter_start_q[53] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_hit_response_q;
            debug_counter_start_q[54] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_miss_fire_q;
            debug_counter_start_q[55] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_fill_fire_q;
            debug_counter_start_q[56] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_fill_wait_cycles_q;
            debug_counter_start_q[57] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_fill_probe_launch_q;
            debug_counter_start_q[58] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_fill_probe_cycles_q;
            debug_counter_start_q[59] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_invalidate_fire_q;
            debug_counter_start_q[60] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_invalidate_wait_cycles_q;
            debug_counter_start_q[61] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_invalidate_probe_launch_q;
            debug_counter_start_q[62] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_invalidate_probe_cycles_q;
            debug_counter_start_q[63] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_lookup_occupied_cycles_q;
            debug_counter_start_q[64] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_access_cycles_q;
            debug_counter_start_q[65] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_access_write_cycles_q;
            debug_counter_start_q[66] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_store_extension_fire_q;
            debug_counter_start_q[67] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_wait_fill_probe_q;
            debug_counter_start_q[68] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_wait_invalidate_probe_q;
            debug_counter_start_q[69] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_wait_lookup_slot_q;
            debug_counter_start_q[70] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_wait_tag_port_q;
            debug_counter_start_q[71] = g_hart[0].u_core.u_bus.g_icx.
                u_bus.u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_wait_access_state_q;

            debug_counter_start_q[72] = u_l2.u_debug.perf_lookup_dispatch_q;
            debug_counter_start_q[73] = u_l2.u_debug.perf_lookup_immediate_q;
            debug_counter_start_q[74] = u_l2.u_debug.perf_lookup_hit_q;
            debug_counter_start_q[75] = u_l2.u_debug.perf_lookup_merge_q;
            debug_counter_start_q[76] = u_l2.u_debug.perf_lookup_alloc_q;
            debug_counter_start_q[77] = u_l2.u_debug.perf_lookup_bypass_q;
            debug_counter_start_q[78] =
                u_l2.u_debug.perf_lookup_write_around_q;
            debug_counter_start_q[79] =
                u_l2.u_debug.perf_lookup_victim_hit_q;
            debug_counter_start_q[80] = u_l2.u_debug.perf_lookup_probe_q;
            debug_counter_start_q[81] = u_l2.u_debug.perf_bus_request_q;
            debug_counter_start_q[82] = u_l2.u_debug.perf_bus_response_q;
            debug_counter_start_q[83] =
                u_l2.u_debug.perf_response_enqueue_q;
            debug_counter_start_q[84] = u_l2.u_debug.perf_hit_enqueue_q;
            debug_counter_start_q[85] =
                u_l2.u_debug.perf_probe_issue_cycles_q;
            debug_counter_start_q[86] =
                u_l2.u_debug.perf_probe_ack_cycles_q;
            debug_counter_start_q[87] =
                u_l2.u_debug.perf_probe_completion_q;
            debug_counter_start_q[88] =
                u_l2.u_debug.perf_mshr_occupancy_cycles_q;
            debug_counter_start_q[89] =
                u_l2.u_debug.perf_mshr_full_cycles_q;
        end
    endtask

    task automatic report_lsq_older_store_stall;
        input string name;
        begin
            $display(
                "PERF_4H_LSQ_OLDER_STORE_STALL name=%0s run_cycles=%0d blocked_cycles=%0d blocked_load_entry_cycles=%0d load_allocations=%0d load_completions=%0d load_occupancy_entry_cycles=%0d",
                name,
                cycles,
                g_hart[0].u_core.u_debug.
                    lsq_load_dependency_block_cycles,
                g_hart[0].u_core.u_debug.
                    lsq_load_dependency_block_entry_cycles,
                g_hart[0].u_core.u_debug.lsq_load_allocations,
                g_hart[0].u_core.u_debug.lsq_load_completions,
                g_hart[0].u_core.u_debug.lsq_load_occupancy_cycles);
        end
    endtask

    task automatic report_debug_counter_window;
        begin
            $display(
                "DEBUG_COUNTER_WINDOW sync_tag=%0d store_extension=%0d start_pc=%016h stop_pc=%016h start_cycle=%0d stop_cycle=%0d cycles=%0d retired=%0d icx_req=%0d memory_reads=%0d memory_writes=%0d",
                L1D_SYNC_TAG_LOOKUP, L1D_SYNC_STORE_EXTENSION,
                debug_counter_start_pc, debug_counter_stop_pc,
                debug_counter_start_cycle, cycles,
                cycles - debug_counter_start_cycle,
                retired[0] - debug_counter_start_retired,
                requests[0] - debug_counter_start_requests,
                memory_reads - debug_counter_start_memory_reads,
                memory_writes - debug_counter_start_memory_writes);
            $display(
                "DEBUG_LSQ_LOAD alloc=%0d alloc_wait=%0d queue_full=%0d xlate=%0d xlate_wait=%0d access=%0d access_wait=%0d responses=%0d complete=%0d dependency_cycles=%0d dependency_entries=%0d occupancy=%0d",
                g_hart[0].u_core.u_debug.lsq_load_allocations -
                    debug_counter_start_q[0],
                g_hart[0].u_core.u_debug.lsq_load_alloc_wait_cycles -
                    debug_counter_start_q[1],
                g_hart[0].u_core.u_debug.lsq_load_queue_full_cycles -
                    debug_counter_start_q[2],
                g_hart[0].u_core.u_debug.lsq_load_xlate_requests -
                    debug_counter_start_q[3],
                g_hart[0].u_core.u_debug.lsq_load_xlate_wait_cycles -
                    debug_counter_start_q[4],
                g_hart[0].u_core.u_debug.lsq_load_access_requests -
                    debug_counter_start_q[5],
                g_hart[0].u_core.u_debug.lsq_load_access_wait_cycles -
                    debug_counter_start_q[6],
                g_hart[0].u_core.u_debug.lsq_load_responses -
                    debug_counter_start_q[7],
                g_hart[0].u_core.u_debug.lsq_load_completions -
                    debug_counter_start_q[8],
                g_hart[0].u_core.u_debug.lsq_load_dependency_block_cycles -
                    debug_counter_start_q[9],
                g_hart[0].u_core.u_debug.
                    lsq_load_dependency_block_entry_cycles -
                    debug_counter_start_q[10],
                g_hart[0].u_core.u_debug.lsq_load_occupancy_cycles -
                    debug_counter_start_q[11]);
            $display(
                "DEBUG_LSQ_STORE alloc=%0d alloc_wait=%0d queue_full=%0d xlate=%0d xlate_wait=%0d access=%0d access_wait=%0d done=%0d order_cycles=%0d order_entries=%0d occupancy=%0d atomic_cycles=%0d",
                g_hart[0].u_core.u_debug.lsq_store_allocations -
                    debug_counter_start_q[12],
                g_hart[0].u_core.u_debug.lsq_store_alloc_wait_cycles -
                    debug_counter_start_q[13],
                g_hart[0].u_core.u_debug.lsq_store_queue_full_cycles -
                    debug_counter_start_q[14],
                g_hart[0].u_core.u_debug.lsq_store_xlate_requests -
                    debug_counter_start_q[15],
                g_hart[0].u_core.u_debug.lsq_store_xlate_wait_cycles -
                    debug_counter_start_q[16],
                g_hart[0].u_core.u_debug.lsq_store_access_requests -
                    debug_counter_start_q[17],
                g_hart[0].u_core.u_debug.lsq_store_access_wait_cycles -
                    debug_counter_start_q[18],
                g_hart[0].u_core.u_debug.lsq_store_done -
                    debug_counter_start_q[19],
                g_hart[0].u_core.u_debug.lsq_store_order_wait_cycles -
                    debug_counter_start_q[20],
                g_hart[0].u_core.u_debug.
                    lsq_store_order_wait_entry_cycles -
                    debug_counter_start_q[21],
                g_hart[0].u_core.u_debug.lsq_store_occupancy_cycles -
                    debug_counter_start_q[22],
                g_hart[0].u_core.u_debug.lsq_atomic_active_cycles -
                    debug_counter_start_q[23]);
            $display(
                "DEBUG_L1D req_wait=%0d read_wait=%0d write_wait=%0d inner_req_wait=%0d miss=%0d miss_wait=%0d fill=%0d fill_wait=%0d commands=%0d responses=%0d resident_responses=%0d prefetch_responses=%0d fast_store_merges=%0d",
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_req_wait_cycles_q - debug_counter_start_q[24],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_read_wait_cycles_q - debug_counter_start_q[25],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_write_wait_cycles_q - debug_counter_start_q[26],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_req_wait_cycles_q - debug_counter_start_q[27],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_miss_q - debug_counter_start_q[28],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_miss_wait_cycles_q - debug_counter_start_q[29],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_fill_q - debug_counter_start_q[30],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_fill_wait_cycles_q - debug_counter_start_q[31],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_command_q - debug_counter_start_q[32],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_response_q - debug_counter_start_q[33],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_l1_response_q - debug_counter_start_q[34],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_prefetch_response_q - debug_counter_start_q[35],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_fast_store_merge_q - debug_counter_start_q[90]);
            $display(
                "DEBUG_L1D_BLOCK normal_overlay=%0d demand_overlay=%0d store_buffer=%0d load_store=%0d store_buffer_occupancy=%0d demand_mshr_occupancy=%0d demand_mshr_full=%0d invalidate_capture=%0d invalidate_hold=%0d invalidate_complete=%0d",
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_normal_overlay_wait_cycles_q -
                    debug_counter_start_q[36],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_demand_overlay_wait_cycles_q -
                    debug_counter_start_q[37],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_store_buffer_block_cycles_q -
                    debug_counter_start_q[38],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_load_store_block_cycles_q -
                    debug_counter_start_q[39],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_store_buffer_occupancy_cycles_q -
                    debug_counter_start_q[40],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_demand_mshr_occupancy_cycles_q -
                    debug_counter_start_q[41],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_demand_mshr_full_cycles_q -
                    debug_counter_start_q[42],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_invalidate_capture_q - debug_counter_start_q[43],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_invalidate_hold_cycles_q - debug_counter_start_q[44],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_debug.
                    perf_invalidate_complete_q - debug_counter_start_q[45]);
            $display(
                "DEBUG_L1_ARRAY req_wait=%0d read_wait=%0d write_wait=%0d req=%0d reads=%0d writes=%0d responses=%0d hits=%0d misses=%0d fills=%0d fill_wait=%0d fill_probe_launch=%0d fill_probe_cycles=%0d",
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_request_wait_cycles_q -
                    debug_counter_start_q[46],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_read_wait_cycles_q -
                    debug_counter_start_q[47],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_write_wait_cycles_q -
                    debug_counter_start_q[48],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_request_fire_q -
                    debug_counter_start_q[49],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_read_fire_q -
                    debug_counter_start_q[50],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_write_fire_q -
                    debug_counter_start_q[51],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_response_fire_q -
                    debug_counter_start_q[52],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_hit_response_q -
                    debug_counter_start_q[53],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_miss_fire_q -
                    debug_counter_start_q[54],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_fill_fire_q -
                    debug_counter_start_q[55],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_fill_wait_cycles_q -
                    debug_counter_start_q[56],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_fill_probe_launch_q -
                    debug_counter_start_q[57],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_fill_probe_cycles_q -
                    debug_counter_start_q[58]);
            $display(
                "DEBUG_L1_BLOCK invalidate=%0d invalidate_wait=%0d invalidate_probe_launch=%0d invalidate_probe_cycles=%0d lookup_cycles=%0d access_cycles=%0d access_write_cycles=%0d store_extensions=%0d wait_fill_probe=%0d wait_invalidate_probe=%0d wait_lookup=%0d wait_tag_port=%0d wait_access=%0d",
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_invalidate_fire_q -
                    debug_counter_start_q[59],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_invalidate_wait_cycles_q -
                    debug_counter_start_q[60],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.
                    perf_invalidate_probe_launch_q -
                    debug_counter_start_q[61],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.
                    perf_invalidate_probe_cycles_q -
                    debug_counter_start_q[62],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.
                    perf_lookup_occupied_cycles_q -
                    debug_counter_start_q[63],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_access_cycles_q -
                    debug_counter_start_q[64],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_access_write_cycles_q -
                    debug_counter_start_q[65],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_store_extension_fire_q -
                    debug_counter_start_q[66],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_wait_fill_probe_q -
                    debug_counter_start_q[67],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.
                    perf_wait_invalidate_probe_q -
                    debug_counter_start_q[68],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_wait_lookup_slot_q -
                    debug_counter_start_q[69],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_wait_tag_port_q -
                    debug_counter_start_q[70],
                g_hart[0].u_core.u_bus.g_icx.u_bus.u_l1d.u_l1d.u_l1.
                    g_cache.u_cache.u_debug.perf_wait_access_state_q -
                    debug_counter_start_q[71]);
            $display(
                "DEBUG_L2 dispatch=%0d immediate=%0d hit=%0d merge=%0d alloc=%0d bypass=%0d write_around=%0d victim_hit=%0d probe=%0d bus_req=%0d bus_resp=%0d response_enqueue=%0d hit_enqueue=%0d probe_issue_cycles=%0d probe_ack_cycles=%0d probe_complete=%0d mshr_occupancy=%0d mshr_full=%0d",
                u_l2.u_debug.perf_lookup_dispatch_q -
                    debug_counter_start_q[72],
                u_l2.u_debug.perf_lookup_immediate_q -
                    debug_counter_start_q[73],
                u_l2.u_debug.perf_lookup_hit_q -
                    debug_counter_start_q[74],
                u_l2.u_debug.perf_lookup_merge_q -
                    debug_counter_start_q[75],
                u_l2.u_debug.perf_lookup_alloc_q -
                    debug_counter_start_q[76],
                u_l2.u_debug.perf_lookup_bypass_q -
                    debug_counter_start_q[77],
                u_l2.u_debug.perf_lookup_write_around_q -
                    debug_counter_start_q[78],
                u_l2.u_debug.perf_lookup_victim_hit_q -
                    debug_counter_start_q[79],
                u_l2.u_debug.perf_lookup_probe_q -
                    debug_counter_start_q[80],
                u_l2.u_debug.perf_bus_request_q -
                    debug_counter_start_q[81],
                u_l2.u_debug.perf_bus_response_q -
                    debug_counter_start_q[82],
                u_l2.u_debug.perf_response_enqueue_q -
                    debug_counter_start_q[83],
                u_l2.u_debug.perf_hit_enqueue_q -
                    debug_counter_start_q[84],
                u_l2.u_debug.perf_probe_issue_cycles_q -
                    debug_counter_start_q[85],
                u_l2.u_debug.perf_probe_ack_cycles_q -
                    debug_counter_start_q[86],
                u_l2.u_debug.perf_probe_completion_q -
                    debug_counter_start_q[87],
                u_l2.u_debug.perf_mshr_occupancy_cycles_q -
                    debug_counter_start_q[88],
                u_l2.u_debug.perf_mshr_full_cycles_q -
                    debug_counter_start_q[89]);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_counter_start_seen <= 1'b0;
            debug_counter_report_seen <= 1'b0;
        end else if (debug_counter_window_enabled) begin
            for (debug_counter_retire_lane = 0;
                 debug_counter_retire_lane < 3;
                 debug_counter_retire_lane =
                     debug_counter_retire_lane + 1) begin
                if (!debug_counter_start_seen &&
                    g_hart[0].u_core.u_debug.backend_retire_arch[
                        debug_counter_retire_lane] &&
                    (g_hart[0].u_core.u_debug.queue_retire_result[
                        debug_counter_retire_lane *
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        RETIRE_RESULT_PC_LSB +: 64] ==
                     debug_counter_start_pc)) begin
                    capture_debug_counter_window();
                    debug_counter_start_seen <= 1'b1;
                    $display(
                        "DEBUG_COUNTER_WINDOW_START pc=%016h cycle=%0d",
                        debug_counter_start_pc, cycles);
                end
                if (debug_counter_start_seen &&
                    !debug_counter_report_seen &&
                    g_hart[0].u_core.u_debug.backend_retire_arch[
                        debug_counter_retire_lane] &&
                    (g_hart[0].u_core.u_debug.queue_retire_result[
                        debug_counter_retire_lane *
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        RETIRE_RESULT_PC_LSB +: 64] ==
                     debug_counter_stop_pc)) begin
                    report_debug_counter_window();
                    debug_counter_report_seen <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;

            if (opensbi_mode) begin
                if ((|g_hart[0].u_core.u_debug.backend_retire_arch) ||
                    g_hart[0].u_core.u_debug.backend_exception) begin
                    opensbi_trace_pc[opensbi_trace_write] <=
                        g_hart[0].u_core.u_debug.backend_retire_pc;
                    opensbi_trace_instr[opensbi_trace_write] <=
                        g_hart[0].u_core.u_debug.backend_retire_instr;
                    opensbi_trace_cause[opensbi_trace_write] <=
                        g_hart[0].u_core.u_debug.backend_cause;
                    opensbi_trace_exception[opensbi_trace_write] <=
                        g_hart[0].u_core.u_debug.backend_exception;
                    opensbi_trace_write <=
                        (opensbi_trace_write + 1) %
                        OPENSBI_TRACE_DEPTH;
                    if (opensbi_trace_count < OPENSBI_TRACE_DEPTH)
                        opensbi_trace_count <=
                            opensbi_trace_count + 1;
                end

                if ((dbg_pc[63:0] ==
                     64'h0000_0000_8010_0410) ||
                    (dbg_pc[63:0] ==
                     64'h0000_0000_8010_0414))
                    opensbi_hang_cycles <= opensbi_hang_cycles + 1;
                else
                    opensbi_hang_cycles <= 0;

                if (opensbi_hang_cycles == 64) begin
                    $display(
                        "OpenSBI entered _start_hang: mcause=%016h mtval=%016h mepc=%016h mstatus=%016h priv=%0d",
                        g_hart[0].u_core.u_debug.csr_mcause,
                        g_hart[0].u_core.u_debug.csr_mtval,
                        g_hart[0].u_core.u_debug.csr_mepc,
                        g_hart[0].u_core.u_debug.csr_mstatus,
                        g_hart[0].u_core.u_debug.csr_priv_mode);
                    for (opensbi_trace_dump = 0;
                         opensbi_trace_dump < opensbi_trace_count;
                         opensbi_trace_dump =
                             opensbi_trace_dump + 1) begin
                        opensbi_trace_slot =
                            (opensbi_trace_write -
                             opensbi_trace_count +
                             opensbi_trace_dump +
                             OPENSBI_TRACE_DEPTH) %
                            OPENSBI_TRACE_DEPTH;
                        $display(
                            "OPENSBI_4H_TRACE pc=%016h instr=%08h exception=%0b cause=%0d",
                            opensbi_trace_pc[opensbi_trace_slot],
                            opensbi_trace_instr[opensbi_trace_slot],
                            opensbi_trace_exception[
                                opensbi_trace_slot],
                            opensbi_trace_cause[
                                opensbi_trace_slot]);
                    end
                    $fatal(1,
                        "OpenSBI hart 0 parked in _start_hang before payload completion");
                end

                if (g_hart[0].u_core.u_debug.csr_priv_mode ==
                    `RV64_PRIV_S)
                    opensbi_s_mode_seen <= 1'b1;

                if (u_uart.write_thr) begin
                    opensbi_uart_bytes <=
                        opensbi_uart_bytes + 1;
                    $write("%c", device_wdata[7:0]);
                    $fflush();
                    match_opensbi_byte(device_wdata[7:0]);
                end

                if ((opensbi_mode != 0) &&
                    ((|(hart_req_valid &
                        ~opensbi_active_hart_mask)) ||
                     (|(hart_wdata_valid &
                        ~opensbi_active_hart_mask))))
                    $fatal(1,
                        "inactive hart emitted ICX traffic active=%b req=%b wdata=%b",
                        opensbi_active_hart_mask,
                        hart_req_valid, hart_wdata_valid);

                if ((cycles != 0) &&
                    ((cycles % 1000000) == 0)) begin
                    $write(
                    "OPENSBI_4H_PROGRESS cycles=%0d active=%b pc=%016h,%016h,%016h,%016h priv=%0d,%0d,%0d,%0d hsm_wfi=%b hsm_sleep=%b sleep=%b s_mode=%b uart=%0d",
                        cycles,
                        opensbi_active_hart_mask,
                        dbg_pc[0*64 +: 64],
                        dbg_pc[1*64 +: 64],
                        dbg_pc[2*64 +: 64],
                        dbg_pc[3*64 +: 64],
                        hart_priv_mode[0*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[1*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[2*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[3*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        opensbi_hsm_wfi_seen,
                        opensbi_hsm_sleep_seen,
                        hart_wfi_sleep,
                        opensbi_s_mode_hart_seen,
                        opensbi_uart_bytes);
                    if (opensbi_banner_seen)
                        $write(" banner");
                    if (opensbi_payload_seen)
                        $write(" payload");
                    if (opensbi_magic_seen)
                        $write(" magic");
                    if (hart_start_counter_last != 0)
                        $write(" hstart=%0d",
                               hart_start_counter_last);
                    if (linux_smp_online_seen)
                        $write(" online");
                    if (linux_smp_threads_seen)
                        $write(" threads");
                    if (linux_prompt_seen)
                        $write(" prompt");
                    if (linux_panic_seen)
                        $write(" linux_panic=1");
                    $write("\n");
                    report_lsq_older_store_stall("progress");
                    if (pc_trace_fd != 0)
                        $fflush(pc_trace_fd);
                    $fflush();
                end
            end

            if ((atomic_test != 0) && (cycles != 0) &&
                ((cycles % 50000) == 0)) begin
                $display(
                    "ATOMIC_PROGRESS cycle=%0d value=%0d lr=%0d,%0d,%0d,%0d sc=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d",
                    cycles, atomic_last_value,
                    lr_requests[0], lr_requests[1],
                    lr_requests[2], lr_requests[3],
                    sc_successes[0] + sc_failures[0],
                    sc_successes[1] + sc_failures[1],
                    sc_successes[2] + sc_failures[2],
                    sc_successes[3] + sc_failures[3],
                    atomic_line_probes[0], atomic_line_probes[1],
                    atomic_line_probes[2], atomic_line_probes[3]);
                $fflush();
            end
            if ((tlbi_test != 0) && (cycles != 0) &&
                ((cycles % 50000) == 0)) begin
                $display(
                    "TLBI_PROGRESS cycle=%0d sfence=%0d,%0d,%0d,%0d pte_fence=%0d,%0d,%0d,%0d old=%0d,%0d,%0d,%0d new=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d sleep=%b",
                    cycles,
                    tlbi_sfence_retired[0],
                    tlbi_sfence_retired[1],
                    tlbi_sfence_retired[2],
                    tlbi_sfence_retired[3],
                    tlbi_pte_fences[0], tlbi_pte_fences[1],
                    tlbi_pte_fences[2], tlbi_pte_fences[3],
                    tlbi_old_reads[0], tlbi_old_reads[1],
                    tlbi_old_reads[2], tlbi_old_reads[3],
                    tlbi_new_reads[0], tlbi_new_reads[1],
                    tlbi_new_reads[2], tlbi_new_reads[3],
                    tlbi_reservation_probes[0],
                    tlbi_reservation_probes[1],
                    tlbi_reservation_probes[2],
                    tlbi_reservation_probes[3],
                    hart_wfi_sleep);
                $fflush();
            end
            if ((ipi_test != 0) && (cycles != 0) &&
                ((cycles % 50000) == 0)) begin
                $display(
                    "IPI_PROGRESS cycle=%0d expected=%0d msip=%b asserted=%0d,%0d,%0d,%0d cleared=%0d,%0d,%0d,%0d interrupts=%0d,%0d,%0d,%0d wfi=%b",
                    cycles, ipi_expected, clint_msip,
                    ipi_msip_assertions[0],
                    ipi_msip_assertions[1],
                    ipi_msip_assertions[2],
                    ipi_msip_assertions[3],
                    ipi_msip_clears[0], ipi_msip_clears[1],
                    ipi_msip_clears[2], ipi_msip_clears[3],
                    ipi_interrupts[0], ipi_interrupts[1],
                    ipi_interrupts[2], ipi_interrupts[3],
                    ipi_wfi_seen);
                $fflush();
            end

            if (protocol_error || probe_endpoint_protocol_error)
                $fatal(1,
                    "coherence protocol error home=%0b endpoint=%0b",
                    protocol_error, probe_endpoint_protocol_error);
            if (((opensbi_mode != 0) &&
                 (|(dbg_halted & opensbi_active_hart_mask))) ||
                ((opensbi_mode == 0) &&
                 (|(dbg_halted & opensbi_active_hart_mask))))
                $fatal(1,
                    "active hart halted active=%b halted=%b pc=%h instr=%h",
                    opensbi_active_hart_mask, dbg_halted,
                    dbg_pc, dbg_instr);

            if (!opensbi_mode &&
                (first_done_cycle < 0) &&
                ((done_seen[0] && opensbi_active_hart_mask[0]) ||
                 (done_seen[1] && opensbi_active_hart_mask[1]) ||
                 (done_seen[2] && opensbi_active_hart_mask[2]) ||
                 (done_seen[3] && opensbi_active_hart_mask[3]))) begin
                first_done_cycle <= cycles;
                progress_before_first_done <= all_active_progress;
            end

            if (!opensbi_mode &&
                (first_done_cycle >= 0) &&
                all_active_done && all_active_mailbox &&
                (!result_va_valid || all_active_result) &&
                ((atomic_test == 0) || atomic_final_seen)) begin
                if (!progress_before_first_done)
                    $fatal(1,
                        "a hart completed before all active harts made retirement progress");
                for (init_hart = 0;
                     init_hart < NUM_HARTS;
                     init_hart = init_hart + 1) begin
                    if (!opensbi_active_hart_mask[init_hart])
                        continue;
                    if ((bare_mode == 0) && !root_seen[init_hart])
                        $fatal(1,
                            "hart %0d never fetched its Sv39 root", init_hart);
                    if (!satp_seen[init_hart])
                        $fatal(1,
                            "hart %0d never entered expected supervisor address mode",
                            init_hart);
                    if (!supervisor_fetch_seen[init_hart])
                        $fatal(1,
                            "hart %0d never fetched from its physical prefix",
                            init_hart);
                    if (perf_results_va_valid) begin
                        if (perf_fields_seen[init_hart] != 7'h7f)
                            $fatal(1,
                                "hart %0d incomplete performance result fields=%b",
                                init_hart,
                                perf_fields_seen[init_hart]);
                        if ((perf_start_cycle[init_hart] == 0) ||
                            (perf_end_cycle[init_hart] <=
                             perf_start_cycle[init_hart]) ||
                            (perf_elapsed_cycles[init_hart] !=
                             perf_end_cycle[init_hart] -
                             perf_start_cycle[init_hart]))
                            $fatal(1,
                                "hart %0d invalid performance cycle record start=%0d end=%0d elapsed=%0d",
                                init_hart,
                                perf_start_cycle[init_hart],
                                perf_end_cycle[init_hart],
                                perf_elapsed_cycles[init_hart]);
                        if ((perf_end_instret[init_hart] <=
                             perf_start_instret[init_hart]) ||
                            (perf_retired[init_hart] !=
                             perf_end_instret[init_hart] -
                             perf_start_instret[init_hart]))
                            $fatal(1,
                                "hart %0d invalid performance instret record start=%0d end=%0d retired=%0d",
                                init_hart,
                                perf_start_instret[init_hart],
                                perf_end_instret[init_hart],
                                perf_retired[init_hart]);
                        if ((init_hart != 0) &&
                            (perf_signature[init_hart] !=
                             perf_signature[0]))
                            $fatal(1,
                                "hart %0d performance signature=%h differs from hart0=%h",
                                init_hart,
                                perf_signature[init_hart],
                                perf_signature[0]);
                    end
                    if (atomic_test != 0) begin
                        if (atomic_l2_successes[init_hart] !=
                            result_expected)
                            $fatal(1,
                                "hart %0d L2 atomic successes=%0d expected=%0d",
                                init_hart,
                                atomic_l2_successes[init_hart],
                                result_expected);
                        if (sc_successes[init_hart] !=
                            result_expected)
                            $fatal(1,
                                "hart %0d SC successes=%0d expected=%0d",
                                init_hart, sc_successes[init_hart],
                                result_expected);
                        if (sc_requests[init_hart] !=
                            sc_successes[init_hart] +
                            sc_failures[init_hart])
                            $fatal(1,
                                "hart %0d SC accounting requests=%0d success=%0d failure=%0d",
                                init_hart, sc_requests[init_hart],
                                sc_successes[init_hart],
                                sc_failures[init_hart]);
                        if (atomic_line_probes[init_hart] == 0)
                            $fatal(1,
                                "hart %0d received no atomic-line invalidation probes",
                                init_hart);
                        if (reservation_clears[init_hart] <
                            atomic_line_probes[init_hart])
                            $fatal(1,
                                "hart %0d reservation clears=%0d probes=%0d",
                                init_hart,
                                reservation_clears[init_hart],
                                atomic_line_probes[init_hart]);
                    end
                    if (tlbi_test != 0) begin
                        if (tlbi_sfence_retired[init_hart] != 2)
                            $fatal(1,
                                "hart %0d SFENCE.VMA retire count=%0d expected=2",
                                init_hart,
                                tlbi_sfence_retired[init_hart]);
                        if (tlbi_pte_fences[init_hart] < 3)
                            $fatal(1,
                                "hart %0d PTE fences=%0d expected at least 3",
                                init_hart,
                                tlbi_pte_fences[init_hart]);
                        if ((tlbi_old_reads[init_hart] == 0) ||
                            (tlbi_new_reads[init_hart] == 0))
                            $fatal(1,
                                "hart %0d remap reads old=%0d new=%0d",
                                init_hart,
                                tlbi_old_reads[init_hart],
                                tlbi_new_reads[init_hart]);
                        if (init_hart != 0) begin
                            if (tlbi_reservation_probes[
                                    init_hart] == 0)
                                $fatal(1,
                                    "hart %0d received no reservation-line invalidate",
                                    init_hart);
                            if (reservation_clears[init_hart] <
                                tlbi_reservation_probes[init_hart])
                                $fatal(1,
                                    "hart %0d reservation clears=%0d TLBI probes=%0d",
                                    init_hart,
                                    reservation_clears[init_hart],
                                    tlbi_reservation_probes[
                                        init_hart]);
                            /*
                             * The probe clears the backend reservation, so
                             * the directed SC fails locally and need not
                             * reach the coherent home.  The per-hart result
                             * word checked above proves the architectural
                             * nonzero SC result.
                             */
                            if (sc_successes[init_hart] != 0)
                                $fatal(1,
                                    "hart %0d post-invalidate SC unexpectedly succeeded externally count=%0d",
                                    init_hart,
                                    sc_successes[init_hart]);
                        end
                    end
                end
                if (ipi_test == 1) begin
                    for (init_hart = 0;
                         init_hart < NUM_HARTS;
                         init_hart = init_hart + 1) begin
                        if (opensbi_active_hart_mask[init_hart]) begin
                            if ((ipi_msip_assertions[init_hart] !=
                                 ipi_expected) ||
                                (ipi_msip_clears[init_hart] !=
                                 ipi_expected) ||
                                (ipi_interrupts[init_hart] !=
                                 ipi_expected))
                                $fatal(1,
                                    "hart %0d IPI accounting asserted=%0d cleared=%0d interrupts=%0d expected=%0d",
                                    init_hart,
                                    ipi_msip_assertions[init_hart],
                                    ipi_msip_clears[init_hart],
                                    ipi_interrupts[init_hart],
                                    ipi_expected);
                            if (!ipi_wfi_seen[init_hart])
                                $fatal(1,
                                    "hart %0d never slept in WFI while awaiting an IPI",
                                    init_hart);
                        end else if ((ipi_msip_assertions[init_hart] != 0) ||
                                     (ipi_msip_clears[init_hart] != 0) ||
                                     (ipi_interrupts[init_hart] != 0))
                            $fatal(1,
                                "inactive hart %0d observed IPI activity asserted=%0d cleared=%0d interrupts=%0d",
                                init_hart,
                                ipi_msip_assertions[init_hart],
                                ipi_msip_clears[init_hart],
                                ipi_interrupts[init_hart]);
                    end
                    if (clint_msip != {NUM_HARTS{1'b0}})
                        $fatal(1,
                            "IPI test completed with asserted MSIP bits=%b",
                            clint_msip);
                    $display(
                        "IPI_2H_SV39 rounds=%0d asserted=%0d,%0d cleared=%0d,%0d interrupts=%0d,%0d wfi=%b",
                        ipi_expected,
                        ipi_msip_assertions[0],
                        ipi_msip_assertions[1],
                        ipi_msip_clears[0], ipi_msip_clears[1],
                        ipi_interrupts[0], ipi_interrupts[1],
                        ipi_wfi_seen);
                end else if (ipi_test == 2) begin
                    ipi_worker_assertions = 0;
                    ipi_worker_clears = 0;
                    ipi_worker_interrupts = 0;
                    for (init_hart = 0;
                         init_hart < NUM_HARTS;
                         init_hart = init_hart + 1) begin
                        if ((ipi_msip_assertions[init_hart] !=
                             ipi_msip_clears[init_hart]) ||
                            (ipi_msip_assertions[init_hart] !=
                             ipi_interrupts[init_hart]))
                            $fatal(1,
                                "hart %0d WFI mailbox IPI mismatch asserted=%0d cleared=%0d interrupts=%0d",
                                init_hart,
                                ipi_msip_assertions[init_hart],
                                ipi_msip_clears[init_hart],
                                ipi_interrupts[init_hart]);
                        if (!ipi_wfi_seen[init_hart])
                            $fatal(1,
                                "hart %0d never slept in WFI during mailbox test",
                                init_hart);
                        if (ipi_fence_requests[init_hart] !=
                            ipi_fence_responses[init_hart])
                            $fatal(1,
                                "hart %0d WFI mailbox fence request/response mismatch requests=%0d responses=%0d",
                                init_hart,
                                ipi_fence_requests[init_hart],
                                ipi_fence_responses[init_hart]);
                        if (ipi_fence_responses[init_hart] !=
                            (ipi_send_requests[init_hart] + 2))
                            $fatal(1,
                                "hart %0d WFI mailbox fence/send mismatch fences=%0d sends=%0d expected startup and completion fences",
                                init_hart,
                                ipi_fence_responses[init_hart],
                                ipi_send_requests[init_hart]);
                        if (init_hart == 0) begin
                            if (ipi_interrupts[init_hart] !=
                                (ipi_expected + 3))
                                $fatal(1,
                                    "coordinator IPI count=%0d expected=%0d",
                                    ipi_interrupts[init_hart],
                                    ipi_expected + 3);
                        end else begin
                            if (ipi_interrupts[init_hart] == 0)
                                $fatal(1,
                                    "worker hart %0d received no wakeups",
                                    init_hart);
                            ipi_worker_assertions =
                                ipi_worker_assertions +
                                ipi_msip_assertions[init_hart];
                            ipi_worker_clears = ipi_worker_clears +
                                ipi_msip_clears[init_hart];
                            ipi_worker_interrupts =
                                ipi_worker_interrupts +
                                ipi_interrupts[init_hart];
                        end
                    end
                    if ((ipi_worker_assertions != (ipi_expected + 3)) ||
                        (ipi_worker_clears != (ipi_expected + 3)) ||
                        (ipi_worker_interrupts != (ipi_expected + 3)))
                        $fatal(1,
                            "worker IPI totals asserted=%0d cleared=%0d interrupts=%0d expected=%0d",
                            ipi_worker_assertions, ipi_worker_clears,
                            ipi_worker_interrupts, ipi_expected + 3);
                    if (clint_msip != {NUM_HARTS{1'b0}})
                        $fatal(1,
                            "WFI mailbox test completed with asserted MSIP bits=%b",
                            clint_msip);
                    $display(
                        "WFI_MAILBOX_4H_SV39 rounds=%0d asserted=%0d,%0d,%0d,%0d cleared=%0d,%0d,%0d,%0d interrupts=%0d,%0d,%0d,%0d wfi=%b",
                        ipi_expected,
                        ipi_msip_assertions[0],
                        ipi_msip_assertions[1],
                        ipi_msip_assertions[2],
                        ipi_msip_assertions[3],
                        ipi_msip_clears[0], ipi_msip_clears[1],
                        ipi_msip_clears[2], ipi_msip_clears[3],
                        ipi_interrupts[0], ipi_interrupts[1],
                        ipi_interrupts[2], ipi_interrupts[3],
                        ipi_wfi_seen);
                    $display(
                        "WFI_MAILBOX_FENCE_ACK requests=%0d,%0d,%0d,%0d responses=%0d,%0d,%0d,%0d sends=%0d,%0d,%0d,%0d",
                        ipi_fence_requests[0], ipi_fence_requests[1],
                        ipi_fence_requests[2], ipi_fence_requests[3],
                        ipi_fence_responses[0],
                        ipi_fence_responses[1],
                        ipi_fence_responses[2],
                        ipi_fence_responses[3],
                        ipi_send_requests[0], ipi_send_requests[1],
                        ipi_send_requests[2], ipi_send_requests[3]);
                end
                if ((atomic_test != 0) &&
                    (atomic_last_value != atomic_expected))
                    $fatal(1,
                        "atomic final value=%0d expected=%0d",
                        atomic_last_value, atomic_expected);
                $display(
                    "PASS tb_4h_3p cycles=%0d first_done=%0d done=%0d,%0d,%0d,%0d",
                    cycles, first_done_cycle,
                    done_cycle[0], done_cycle[1],
                    done_cycle[2], done_cycle[3]);
                $display(
                    "  retired=%0d,%0d,%0d,%0d icx_req=%0d,%0d,%0d,%0d",
                    retired[0], retired[1], retired[2], retired[3],
                    requests[0], requests[1], requests[2], requests[3]);
                $display(
                    "  stores allocated=%0d,%0d,%0d,%0d fast=%0d,%0d,%0d,%0d fallback=%0d,%0d,%0d,%0d",
                    store_allocations[0], store_allocations[1],
                    store_allocations[2], store_allocations[3],
                    fast_store_requests[0], fast_store_requests[1],
                    fast_store_requests[2], fast_store_requests[3],
                    fallback_store_requests[0], fallback_store_requests[1],
                    fallback_store_requests[2],
                    fallback_store_requests[3]);
                $display(
                    "  l2_memory reads=%0d writes=%0d shared_satp=%0d bare=%0d",
                    memory_reads, memory_writes, shared_satp, bare_mode);
                if (perf_results_va_valid) begin
                    perf_min_start = perf_start_cycle[0];
                    perf_max_end = perf_end_cycle[0];
                    perf_total_retired = perf_retired[0];
                    for (init_hart = 1;
                         init_hart < NUM_HARTS;
                         init_hart = init_hart + 1) begin
                        if (!opensbi_active_hart_mask[init_hart])
                            continue;
                        if (perf_start_cycle[init_hart] <
                            perf_min_start)
                            perf_min_start =
                                perf_start_cycle[init_hart];
                        if (perf_end_cycle[init_hart] >
                            perf_max_end)
                            perf_max_end =
                                perf_end_cycle[init_hart];
                        perf_total_retired =
                            perf_total_retired +
                            perf_retired[init_hart];
                    end
                    perf_parallel_span =
                        perf_max_end - perf_min_start;
                    if (perf_parallel_span == 0)
                        $fatal(1,
                            "zero four-hart performance span");
                    $display(
                        "PERF_4H_%0s iterations=%0d signature=%h parallel_start=%0d parallel_end=%0d parallel_cycles=%0d total_instret=%0d aggregate_ipc_x1000=%0d",
                        perf_name, perf_iterations,
                        perf_signature[0],
                        perf_min_start, perf_max_end,
                        perf_parallel_span, perf_total_retired,
                        (perf_total_retired * 1000) /
                            perf_parallel_span);
                    for (init_hart = 0;
                        init_hart < NUM_HARTS;
                         init_hart = init_hart + 1)
                        if (opensbi_active_hart_mask[init_hart])
                            $display(
                                "PERF_4H_%0s_HART hart=%0d start=%0d end=%0d cycles=%0d instret=%0d ipc_x1000=%0d",
                                perf_name, init_hart,
                                perf_start_cycle[init_hart],
                                perf_end_cycle[init_hart],
                                perf_elapsed_cycles[init_hart],
                                perf_retired[init_hart],
                                (perf_retired[init_hart] * 1000) /
                                    perf_elapsed_cycles[init_hart]);
                    if (coherence_perf != 0) begin
                        if ((coherence_measure_started !=
                             opensbi_active_hart_mask) ||
                            (coherence_measure_ended !=
                             opensbi_active_hart_mask) ||
                            (coherence_measure_active !=
                             {NUM_HARTS{1'b0}}))
                            $fatal(1,
                                "coherence measurement markers start=%b end=%b active=%b",
                                coherence_measure_started,
                                coherence_measure_ended,
                                coherence_measure_active);
                        coherence_total_reads = 0;
                        coherence_total_writes = 0;
                        coherence_total_atomics = 0;
                        coherence_total_probes = 0;
                        coherence_total_sc_successes = 0;
                        coherence_total_sc_failures = 0;
                        for (init_hart = 0;
                             init_hart < NUM_HARTS;
                             init_hart = init_hart + 1) begin
                            if (!opensbi_active_hart_mask[init_hart])
                                continue;
                            coherence_total_reads =
                                coherence_total_reads +
                                coherence_target_reads[init_hart];
                            coherence_total_writes =
                                coherence_total_writes +
                                coherence_target_writes[init_hart];
                            coherence_total_atomics =
                                coherence_total_atomics +
                                coherence_target_atomics[init_hart];
                            coherence_total_probes =
                                coherence_total_probes +
                                coherence_target_probes[init_hart];
                            coherence_total_sc_successes =
                                coherence_total_sc_successes +
                                sc_successes[init_hart];
                            coherence_total_sc_failures =
                                coherence_total_sc_failures +
                                sc_failures[init_hart];
                        end
                        if ((coherence_case == 0) &&
                            (coherence_total_probes != 0))
                            $fatal(1,
                                "private-line control generated %0d target probes",
                                coherence_total_probes);
                        if ((((coherence_case >= 1) &&
                              (coherence_case <= 5)) ||
                             (coherence_case == 14) ||
                             (coherence_case == 15) ||
                             ((coherence_case >= 17) &&
                              (coherence_case <= 22))) &&
                            (opensbi_active_harts > 1) &&
                            (coherence_total_probes == 0))
                            $fatal(1,
                                "shared coherence case generated no target probes");
                        if ((coherence_case == 4) &&
                            (coherence_total_sc_successes !=
                             coherence_operations))
                            $fatal(1,
                                "LR/SC coherence successes=%0d expected=%0d",
                                coherence_total_sc_successes,
                                coherence_operations);
                        if ((coherence_case == 5) &&
                            (coherence_total_sc_successes !=
                             coherence_operations))
                            $fatal(1,
                                "ticket-lock successful SCs=%0d expected acquisitions=%0d",
                                coherence_total_sc_successes,
                                coherence_operations);
                        if ((coherence_case == 22) &&
                            (coherence_total_sc_successes !=
                             coherence_operations))
                            $fatal(1,
                                "lock-walk successful SCs=%0d expected acquisitions=%0d",
                                coherence_total_sc_successes,
                                coherence_operations);
                        $display(
                            "COHERENCE_4H case=%0s active_harts=%0d operations=%0d parallel_cycles=%0d operations_per_kcycle=%0d target_reads=%0d target_writes=%0d target_atomic_lrs=%0d target_probes=%0d probes_per_operation_x1000=%0d max_target_mshrs=%0d",
                            perf_name, opensbi_active_harts,
                            coherence_operations,
                            perf_parallel_span,
                            (coherence_operations * 1000) /
                                perf_parallel_span,
                            coherence_total_reads,
                            coherence_total_writes,
                            coherence_total_atomics,
                            coherence_total_probes,
                            (coherence_total_probes * 1000) /
                                coherence_operations,
                            coherence_max_target_mshrs);
                        for (init_hart = 0;
                             init_hart < NUM_HARTS;
                             init_hart = init_hart + 1)
                            if (opensbi_active_hart_mask[init_hart])
                                $display(
                                    "COHERENCE_4H_HART hart=%0d reads=%0d writes=%0d atomic_lrs=%0d probes=%0d sc_success=%0d sc_failure=%0d",
                                    init_hart,
                                    coherence_target_reads[init_hart],
                                    coherence_target_writes[init_hart],
                                    coherence_target_atomics[init_hart],
                                    coherence_target_probes[init_hart],
                                    sc_successes[init_hart],
                                    sc_failures[init_hart]);
                    end
                end
                if (atomic_test != 0) begin
                    $display(
                        "  atomic final=%0d lr=%0d,%0d,%0d,%0d",
                        atomic_last_value,
                        lr_requests[0], lr_requests[1],
                        lr_requests[2], lr_requests[3]);
                    $display(
                        "  sc success=%0d,%0d,%0d,%0d failure=%0d,%0d,%0d,%0d",
                        sc_successes[0], sc_successes[1],
                        sc_successes[2], sc_successes[3],
                        sc_failures[0], sc_failures[1],
                        sc_failures[2], sc_failures[3]);
                    $display(
                        "  atomic probes=%0d,%0d,%0d,%0d reservation_clears=%0d,%0d,%0d,%0d",
                        atomic_line_probes[0], atomic_line_probes[1],
                        atomic_line_probes[2], atomic_line_probes[3],
                        reservation_clears[0], reservation_clears[1],
                        reservation_clears[2], reservation_clears[3]);
                end
                if (tlbi_test != 0) begin
                    $display(
                        "  tlbi sfence=%0d,%0d,%0d,%0d pte_fence=%0d,%0d,%0d,%0d",
                        tlbi_sfence_retired[0],
                        tlbi_sfence_retired[1],
                        tlbi_sfence_retired[2],
                        tlbi_sfence_retired[3],
                        tlbi_pte_fences[0], tlbi_pte_fences[1],
                        tlbi_pte_fences[2], tlbi_pte_fences[3]);
                    $display(
                        "  tlbi old_reads=%0d,%0d,%0d,%0d new_reads=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d",
                        tlbi_old_reads[0], tlbi_old_reads[1],
                        tlbi_old_reads[2], tlbi_old_reads[3],
                        tlbi_new_reads[0], tlbi_new_reads[1],
                        tlbi_new_reads[2], tlbi_new_reads[3],
                        tlbi_reservation_probes[0],
                        tlbi_reservation_probes[1],
                        tlbi_reservation_probes[2],
                        tlbi_reservation_probes[3]);
                end
                $finish;
            end

            if ((opensbi_held != 0) && (linux_mode == 0) &&
                opensbi_banner_seen &&
                opensbi_payload_seen &&
                opensbi_s_mode_seen &&
                opensbi_magic_seen) begin
                if ((retired[1] != 0) || (retired[2] != 0) ||
                    (retired[3] != 0) || (requests[1] != 0) ||
                    (requests[2] != 0) || (requests[3] != 0))
                    $fatal(1,
                        "held harts made progress retired=%0d,%0d,%0d requests=%0d,%0d,%0d",
                        retired[1], retired[2], retired[3],
                        requests[1], requests[2], requests[3]);
                if ((DDR3_ENABLE != 0) &&
                    (ddr_read_commands == 0))
                    $fatal(1,
                        "OpenSBI passed without a timed DDR3 read command");
                $display(
                    "\nPASS: 4H coherent OpenSBI v1.9 on hart 0 with harts 1-3 held in reset; ROM handoff, banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
                $display(
                    "  cycles=%0d hart0_retired=%0d hart0_icx_req=%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles, retired[0], requests[0],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
                if (DDR3_ENABLE != 0) begin
                    $display(
                        "  ddr3 read_bursts=%0d write_bursts=%0d read_commands=%0d write_commands=%0d max_command_queue=%0d max_timing_owners=%0d",
                        ddr_read_bursts, ddr_write_bursts,
                        ddr_read_commands, ddr_write_commands,
                        ddr_max_command_queue,
                        ddr_max_timing_owners);
                end
                $finish;
            end

            if ((opensbi_held != 0) && (linux_mode != 0) &&
                linux_prompt_seen) begin
                if ((retired[1] != 0) || (retired[2] != 0) ||
                    (retired[3] != 0) || (requests[1] != 0) ||
                    (requests[2] != 0) || (requests[3] != 0))
                    $fatal(1,
                        "held harts made Linux progress retired=%0d,%0d,%0d requests=%0d,%0d,%0d",
                        retired[1], retired[2], retired[3],
                        requests[1], requests[2], requests[3]);
                report_lsq_older_store_stall("bash");
                $display(
                    "\nPASS: Linux reached interactive Bash on the four-hart coherent rig with harts 1-3 held in reset and omitted from the device tree");
                $display(
                    "  cycles=%0d hart0_retired=%0d hart0_icx_req=%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles, retired[0], requests[0],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
                $display(
                    "PERF_ATOMIC_STORES hart=0 core_success=%0d core_failed=%0d observed_sc_success=%0d observed_sc_failed=%0d home_sc_success=%0d home_sc_failed=%0d",
                    g_hart[0].u_core.u_debug.
                        perf_atomic_store_success_q,
                    g_hart[0].u_core.u_debug.
                        perf_atomic_store_failed_q,
                    sc_successes[0], sc_failures[0],
                    u_l2.u_debug.perf_atomic_store_success_q,
                    u_l2.u_debug.perf_atomic_store_failed_q);
                $finish;
            end

            if ((opensbi_smp != 0) && (linux_mode != 0) &&
                (require_smp_threads != 0) && linux_prompt_seen &&
                !linux_smp_threads_seen)
                $fatal(1,
                    "Linux reached the prompt without passing the two-thread SMP userspace probe");

            if ((opensbi_smp != 0) && (linux_mode != 0) &&
                linux_smp_online_seen && linux_prompt_seen &&
                !$test$plusargs("defer_linux_completion")) begin
                for (init_hart = 0;
                     init_hart < NUM_HARTS;
                     init_hart = init_hart + 1) begin
                    if (opensbi_active_hart_mask[init_hart]) begin
                        if (!opensbi_s_mode_hart_seen[init_hart])
                            $fatal(1,
                                "Linux SMP active hart %0d never entered S-mode",
                                init_hart);
                        if ((retired[init_hart] == 0) ||
                            (requests[init_hart] == 0))
                            $fatal(1,
                                "Linux SMP active hart %0d made insufficient progress retired=%0d requests=%0d",
                                init_hart, retired[init_hart],
                                requests[init_hart]);
                        if ((init_hart != 0) &&
                            (!opensbi_hsm_wfi_seen[init_hart] ||
                             ((ENABLE_WFI_SLEEP != 0) &&
                              !opensbi_hsm_sleep_seen[init_hart])))
                            $fatal(1,
                                "Linux SMP secondary %0d did not reach configured WFI park behavior wfi=%0b sleep=%0b sleep_enable=%0d",
                                init_hart,
                                opensbi_hsm_wfi_seen[init_hart],
                                opensbi_hsm_sleep_seen[init_hart],
                                ENABLE_WFI_SLEEP);
                    end else if ((retired[init_hart] != 0) ||
                                 (requests[init_hart] != 0)) begin
                        $fatal(1,
                            "Linux SMP inactive hart %0d made progress retired=%0d requests=%0d",
                            init_hart, retired[init_hart],
                            requests[init_hart]);
                    end
                end
                if ((DDR3_ENABLE != 0) &&
                    (ddr_read_commands == 0))
                    $fatal(1,
                        "Linux SMP passed without a timed DDR3 read command");
                $display(
                    "\nPASS: %0dH Linux SMP brought every advertised CPU online and reached interactive Bash on the coherent timed-DDR3 rig",
                    opensbi_active_harts);
                $display(
                    "  cycles=%0d active=%b retired=%0d,%0d,%0d,%0d icx_req=%0d,%0d,%0d,%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles, opensbi_active_hart_mask,
                    retired[0], retired[1],
                    retired[2], retired[3],
                    requests[0], requests[1],
                    requests[2], requests[3],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
                if (DDR3_ENABLE != 0)
                    $display(
                        "  ddr3 read_bursts=%0d write_bursts=%0d read_commands=%0d write_commands=%0d max_command_queue=%0d max_timing_owners=%0d",
                        ddr_read_bursts, ddr_write_bursts,
                        ddr_read_commands, ddr_write_commands,
                        ddr_max_command_queue,
                        ddr_max_timing_owners);
                $finish;
            end

            if ((linux_mode != 0) && linux_panic_seen)
                $fatal(1,
                    "Linux kernel panic on coherent OpenSBI rig active_harts=%0d",
                    opensbi_active_harts);

            if ((opensbi_hart_start != 0) &&
                opensbi_banner_seen &&
                opensbi_payload_seen &&
                opensbi_magic_seen) begin
                for (init_hart = 0;
                     init_hart < NUM_HARTS;
                     init_hart = init_hart + 1) begin
                    if (opensbi_active_hart_mask[init_hart]) begin
                        if (!opensbi_s_mode_hart_seen[init_hart])
                            $fatal(1,
                                "SBI hart_start active hart %0d never entered S-mode",
                                init_hart);
                        if (!hart_start_private_seen[init_hart])
                            $fatal(1,
                                "SBI hart_start active hart %0d private publication was not observed",
                                init_hart);
                        if (!hart_start_response_seen[init_hart])
                            $fatal(1,
                                "SBI hart_start active hart %0d coherent response was not observed",
                                init_hart);
                        if (sc_successes[init_hart] <
                            HART_START_ATOMIC_ITERATIONS)
                            $fatal(1,
                                "SBI hart_start active hart %0d SC successes=%0d expected at least %0d",
                                init_hart, sc_successes[init_hart],
                                HART_START_ATOMIC_ITERATIONS);
                        if ((init_hart != 0) &&
                            (!opensbi_hsm_wfi_seen[init_hart] ||
                             ((ENABLE_WFI_SLEEP != 0) &&
                              !opensbi_hsm_sleep_seen[init_hart])))
                            $fatal(1,
                                "SBI hart_start secondary %0d did not reach configured WFI park behavior wfi=%0b sleep=%0b sleep_enable=%0d",
                                init_hart,
                                opensbi_hsm_wfi_seen[init_hart],
                                opensbi_hsm_sleep_seen[init_hart],
                                ENABLE_WFI_SLEEP);
                    end else if ((retired[init_hart] != 0) ||
                                 (requests[init_hart] != 0)) begin
                        $fatal(1,
                            "SBI hart_start inactive hart %0d made progress retired=%0d requests=%0d",
                            init_hart, retired[init_hart],
                            requests[init_hart]);
                    end
                end
                if (hart_start_counter_last !=
                    opensbi_active_harts *
                    HART_START_ATOMIC_ITERATIONS)
                    $fatal(1,
                        "SBI hart_start final counter=%0d expected=%0d",
                        hart_start_counter_last,
                        opensbi_active_harts *
                        HART_START_ATOMIC_ITERATIONS);
                if ((DDR3_ENABLE != 0) &&
                    (ddr_read_commands == 0))
                    $fatal(1,
                        "SBI hart_start passed without a timed DDR3 read command");
                $display(
                    "\nPASS: %0dH OpenSBI SBI hart_start woke all secondaries into S-mode and completed private, bidirectional coherent, and contended LR/SC memory tests",
                    opensbi_active_harts);
                $display(
                    "  cycles=%0d active=%b retired=%0d,%0d,%0d,%0d icx_req=%0d,%0d,%0d,%0d",
                    cycles, opensbi_active_hart_mask,
                    retired[0], retired[1],
                    retired[2], retired[3],
                    requests[0], requests[1],
                    requests[2], requests[3]);
                $display(
                    "  hsm_wfi=%b hsm_sleep=%b s_mode=%b private=%b response=%b counter=%0d",
                    opensbi_hsm_wfi_seen,
                    opensbi_hsm_sleep_seen,
                    opensbi_s_mode_hart_seen,
                    hart_start_private_seen,
                    hart_start_response_seen,
                    hart_start_counter_last);
                $display(
                    "  sc success=%0d,%0d,%0d,%0d failure=%0d,%0d,%0d,%0d",
                    sc_successes[0], sc_successes[1],
                    sc_successes[2], sc_successes[3],
                    sc_failures[0], sc_failures[1],
                    sc_failures[2], sc_failures[3]);
                $finish;
            end

            if ((opensbi_smp != 0) &&
                (opensbi_hart_start == 0) &&
                (linux_mode == 0) &&
                opensbi_banner_seen &&
                opensbi_payload_seen &&
                opensbi_s_mode_seen &&
                opensbi_magic_seen &&
                (&opensbi_hsm_wfi_seen[NUM_HARTS-1:1]) &&
                ((ENABLE_WFI_SLEEP == 0) ||
                 (&hart_wfi_sleep[NUM_HARTS-1:1]))) begin
                if ((hart_priv_mode[
                         1*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH] !=
                     `RV64_PRIV_M) ||
                    (hart_priv_mode[
                         2*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH] !=
                     `RV64_PRIV_M) ||
                    (hart_priv_mode[
                         3*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH] !=
                     `RV64_PRIV_M))
                    $fatal(1,
                        "secondary hart left M-mode priv=%0d,%0d,%0d",
                        hart_priv_mode[
                            1*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH],
                        hart_priv_mode[
                            2*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH],
                        hart_priv_mode[
                            3*`RV64_PRIV_WIDTH +: `RV64_PRIV_WIDTH]);
                if ((DDR3_ENABLE != 0) &&
                    (ddr_read_commands == 0))
                    $fatal(1,
                        "OpenSBI SMP passed without a timed DDR3 read command");
                $display(
                    "\nPASS: 4H coherent OpenSBI v1.9; hart 0 completed the S-mode payload and harts 1-3 sleep at HSM WFI %016h",
                    opensbi_hsm_wfi_pc);
                $display(
                    "  cycles=%0d retired=%0d,%0d,%0d,%0d icx_req=%0d,%0d,%0d,%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles,
                    retired[0], retired[1],
                    retired[2], retired[3],
                    requests[0], requests[1],
                    requests[2], requests[3],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
                if (DDR3_ENABLE != 0) begin
                    $display(
                        "  ddr3 read_bursts=%0d write_bursts=%0d read_commands=%0d write_commands=%0d max_command_queue=%0d max_timing_owners=%0d",
                        ddr_read_bursts, ddr_write_bursts,
                        ddr_read_commands, ddr_write_commands,
                        ddr_max_command_queue,
                        ddr_max_timing_owners);
                end
                $finish;
            end

            if ((cycles >= max_cycles) && (atomic_test != 0))
                $display(
                    "ATOMIC_TIMEOUT value=%0d lr=%0d,%0d,%0d,%0d sc_success=%0d,%0d,%0d,%0d sc_failure=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d clears=%0d,%0d,%0d,%0d home_state=%0d",
                    atomic_last_value,
                    lr_requests[0], lr_requests[1],
                    lr_requests[2], lr_requests[3],
                    sc_successes[0], sc_successes[1],
                    sc_successes[2], sc_successes[3],
                    sc_failures[0], sc_failures[1],
                    sc_failures[2], sc_failures[3],
                    atomic_line_probes[0], atomic_line_probes[1],
                    atomic_line_probes[2], atomic_line_probes[3],
                    reservation_clears[0], reservation_clears[1],
                    reservation_clears[2], reservation_clears[3],
                    u_l2.u_debug.lookup_action);
            if ((cycles >= max_cycles) && (tlbi_test != 0))
                $display(
                    "TLBI_TIMEOUT sfence=%0d,%0d,%0d,%0d pte_fence=%0d,%0d,%0d,%0d old=%0d,%0d,%0d,%0d new=%0d,%0d,%0d,%0d probes=%0d,%0d,%0d,%0d clears=%0d,%0d,%0d,%0d sc_failure=%0d,%0d,%0d,%0d sleep=%b priv=%0d,%0d,%0d,%0d home_state=%0d",
                    tlbi_sfence_retired[0],
                    tlbi_sfence_retired[1],
                    tlbi_sfence_retired[2],
                    tlbi_sfence_retired[3],
                    tlbi_pte_fences[0], tlbi_pte_fences[1],
                    tlbi_pte_fences[2], tlbi_pte_fences[3],
                    tlbi_old_reads[0], tlbi_old_reads[1],
                    tlbi_old_reads[2], tlbi_old_reads[3],
                    tlbi_new_reads[0], tlbi_new_reads[1],
                    tlbi_new_reads[2], tlbi_new_reads[3],
                    tlbi_reservation_probes[0],
                    tlbi_reservation_probes[1],
                    tlbi_reservation_probes[2],
                    tlbi_reservation_probes[3],
                    reservation_clears[0], reservation_clears[1],
                    reservation_clears[2], reservation_clears[3],
                    sc_failures[0], sc_failures[1],
                    sc_failures[2], sc_failures[3],
                    hart_wfi_sleep,
                    hart_priv_mode[0*`RV64_PRIV_WIDTH +:
                        `RV64_PRIV_WIDTH],
                    hart_priv_mode[1*`RV64_PRIV_WIDTH +:
                        `RV64_PRIV_WIDTH],
                    hart_priv_mode[2*`RV64_PRIV_WIDTH +:
                        `RV64_PRIV_WIDTH],
                    hart_priv_mode[3*`RV64_PRIV_WIDTH +:
                        `RV64_PRIV_WIDTH],
                    u_l2.u_debug.lookup_action);
            if (cycles >= max_cycles) begin
                if (opensbi_mode) begin
                    report_lsq_older_store_stall("timeout");
                    $fatal(1,
                        "OpenSBI/Linux 4H timeout cycles=%0d pc=%h instr=%h priv=%0d,%0d,%0d,%0d hsm_wfi=%b banner=%0b payload=%0b s_mode=%0b magic=%0b linux_online=%0b linux_threads=%0b linux_prompt=%0b linux_panic=%0b req=%0d,%0d,%0d,%0d",
                        cycles, dbg_pc, dbg_instr,
                        hart_priv_mode[0*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[1*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[2*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        hart_priv_mode[3*`RV64_PRIV_WIDTH +:
                            `RV64_PRIV_WIDTH],
                        opensbi_hsm_wfi_seen,
                        opensbi_banner_seen,
                        opensbi_payload_seen,
                        opensbi_s_mode_seen,
                        opensbi_magic_seen,
                        linux_smp_online_seen,
                        linux_smp_threads_seen,
                        linux_prompt_seen,
                        linux_panic_seen,
                        requests[0], requests[1],
                        requests[2], requests[3]);
                end else
                    $fatal(1,
                        "timeout cycles=%0d done=%0b%0b%0b%0b mailbox=%0b%0b%0b%0b pc=%h",
                        cycles, done_seen[3], done_seen[2],
                        done_seen[1], done_seen[0],
                        mailbox_seen[3], mailbox_seen[2],
                        mailbox_seen[1], mailbox_seen[0], dbg_pc);
            end
        end
    end

    final begin
        if (pc_trace_fd != 0)
            $fclose(pc_trace_fd);
    end

endmodule

/*
 * Timed backing-memory endpoint for the four-hart testbench.
 *
 * The shared L2 presents one 512-bit neutral request per cache line.  The
 * generic-bus adapter converts that line to a two-beat 256-bit AXI burst; the
 * AXI memory channel holds data and the DDR3 scheduler supplies completion
 * timing.  WISHBONE is deliberately unconnected.
 */
module tb_4h_ddr3_backend #(
    parameter [63:0] MEM_BASE = 64'h0000_0000_8000_0000,
    parameter integer MEM_BYTES = 16 * 1024 * 1024,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer DDR3_MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer DDR3_BANK_ROW_SWIZZLE = 0
) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire req_valid_i,
    output wire req_ready_o,
    input  wire req_write_i,
    input  wire [63:0] req_addr_i,
    input  wire [2:0] req_size_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] req_wdata_i,
    input  wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] req_wstrb_i,
    input  wire req_cacheable_i,
    output wire resp_valid_o,
    input  wire resp_ready_i,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] resp_rdata_o,
    output wire resp_error_o,
    output reg [63:0] read_bursts_o,
    output reg [63:0] write_bursts_o,
    output reg [63:0] read_commands_o,
    output reg [63:0] write_commands_o,
    output reg [63:0] max_command_queue_o,
    output reg [63:0] max_timing_owners_o
);
    localparam integer AXI_DATA_WIDTH = 256;
    localparam integer AXI_ID_WIDTH = 3;

    wire [AXI_ID_WIDTH-1:0] axi_arid;
    wire [63:0] axi_araddr;
    wire [7:0] axi_arlen;
    wire [2:0] axi_arsize;
    wire [1:0] axi_arburst;
    wire axi_arlock;
    wire [3:0] axi_arcache;
    wire [2:0] axi_arprot;
    wire [3:0] axi_arqos;
    wire axi_arvalid;
    wire axi_arready;
    wire [AXI_ID_WIDTH-1:0] axi_rid;
    wire [AXI_DATA_WIDTH-1:0] axi_rdata;
    wire [1:0] axi_rresp;
    wire axi_rlast;
    wire axi_rvalid;
    wire axi_rready;

    wire [AXI_ID_WIDTH-1:0] axi_awid;
    wire [63:0] axi_awaddr;
    wire [7:0] axi_awlen;
    wire [2:0] axi_awsize;
    wire [1:0] axi_awburst;
    wire axi_awlock;
    wire [3:0] axi_awcache;
    wire [2:0] axi_awprot;
    wire [3:0] axi_awqos;
    wire axi_awvalid;
    wire axi_awready;
    wire [AXI_DATA_WIDTH-1:0] axi_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] axi_wstrb;
    wire axi_wlast;
    wire axi_wvalid;
    wire axi_wready;
    wire [AXI_ID_WIDTH-1:0] axi_bid;
    wire [1:0] axi_bresp;
    wire axi_bvalid;
    wire axi_bready;

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [AXI_DATA_WIDTH-1:0] wb_dat;
    wire [AXI_DATA_WIDTH/8-1:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;

    genbus_interface #(
        .BUS_TYPE(`OPENRV64_COMPLEX_BUS_AXI),
        .ADDR_WIDTH(64),
        .UPSTREAM_DATA_WIDTH(`OPENRV64_ICX_LINE_DATA_WIDTH),
        .DOWNSTREAM_DATA_WIDTH(AXI_DATA_WIDTH),
        .READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(3'd7),
        .WB_ADDR_SHIFT(5),
        .WB_MAX_RETRIES(0)
    ) u_genbus (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .upstream_req_valid_i(req_valid_i),
        .upstream_req_ready_o(req_ready_o),
        .upstream_req_write_i(req_write_i),
        .upstream_req_addr_i(req_addr_i),
        .upstream_req_size_i(req_size_i),
        .upstream_req_burst_i(8'd0),
        .upstream_req_wdata_i(req_wdata_i),
        .upstream_req_wstrb_i(req_wstrb_i),
        .upstream_req_cacheable_i(req_cacheable_i),
        .upstream_resp_valid_o(resp_valid_o),
        .upstream_resp_ready_i(resp_ready_i),
        .upstream_resp_rdata_o(resp_rdata_o),
        .upstream_resp_error_o(resp_error_o),
        .m_axi_arid_o(axi_arid),
        .m_axi_araddr_o(axi_araddr),
        .m_axi_arlen_o(axi_arlen),
        .m_axi_arsize_o(axi_arsize),
        .m_axi_arburst_o(axi_arburst),
        .m_axi_arlock_o(axi_arlock),
        .m_axi_arcache_o(axi_arcache),
        .m_axi_arprot_o(axi_arprot),
        .m_axi_arqos_o(axi_arqos),
        .m_axi_arvalid_o(axi_arvalid),
        .m_axi_arready_i(axi_arready),
        .m_axi_rid_i(axi_rid),
        .m_axi_rdata_i(axi_rdata),
        .m_axi_rresp_i(axi_rresp),
        .m_axi_rlast_i(axi_rlast),
        .m_axi_rvalid_i(axi_rvalid),
        .m_axi_rready_o(axi_rready),
        .m_axi_awid_o(axi_awid),
        .m_axi_awaddr_o(axi_awaddr),
        .m_axi_awlen_o(axi_awlen),
        .m_axi_awsize_o(axi_awsize),
        .m_axi_awburst_o(axi_awburst),
        .m_axi_awlock_o(axi_awlock),
        .m_axi_awcache_o(axi_awcache),
        .m_axi_awprot_o(axi_awprot),
        .m_axi_awqos_o(axi_awqos),
        .m_axi_awvalid_o(axi_awvalid),
        .m_axi_awready_i(axi_awready),
        .m_axi_wdata_o(axi_wdata),
        .m_axi_wstrb_o(axi_wstrb),
        .m_axi_wlast_o(axi_wlast),
        .m_axi_wvalid_o(axi_wvalid),
        .m_axi_wready_i(axi_wready),
        .m_axi_bid_i(axi_bid),
        .m_axi_bresp_i(axi_bresp),
        .m_axi_bvalid_i(axi_bvalid),
        .m_axi_bready_o(axi_bready),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_we_o(wb_we),
        .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat),
        .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte),
        .wb_lock_o(wb_lock),
        .wb_stall_i(1'b0),
        .wb_ack_i(1'b0),
        .wb_err_i(1'b0),
        .wb_rty_i(1'b0),
        .wb_dat_i({AXI_DATA_WIDTH{1'b0}})
    );

    openrv64_axi_ddr3 #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH),
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES),
        .READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
        .WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
        .CONTROLLER_TCK_PS(1000),
        .REFRESH_INTERVAL(6240),
        .FRONTEND_LATENCY_PS(10000),
        .BACKEND_LATENCY_PS(10000),
        .COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
        .MAX_BURST_TRAIN_BURSTS(
            DDR3_MAX_BURST_TRAIN_BURSTS),
        .BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE),
        .TIMING_MODEL(0)
    ) u_ddr3 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .s_axi_arid_i(axi_arid),
        .s_axi_araddr_i(axi_araddr),
        .s_axi_arlen_i(axi_arlen),
        .s_axi_arsize_i(axi_arsize),
        .s_axi_arburst_i(axi_arburst),
        .s_axi_arlock_i(axi_arlock),
        .s_axi_arcache_i(axi_arcache),
        .s_axi_arprot_i(axi_arprot),
        .s_axi_arqos_i(axi_arqos),
        .s_axi_arvalid_i(axi_arvalid),
        .s_axi_arready_o(axi_arready),
        .s_axi_rid_o(axi_rid),
        .s_axi_rdata_o(axi_rdata),
        .s_axi_rresp_o(axi_rresp),
        .s_axi_rlast_o(axi_rlast),
        .s_axi_rvalid_o(axi_rvalid),
        .s_axi_rready_i(axi_rready),
        .s_axi_awid_i(axi_awid),
        .s_axi_awaddr_i(axi_awaddr),
        .s_axi_awlen_i(axi_awlen),
        .s_axi_awsize_i(axi_awsize),
        .s_axi_awburst_i(axi_awburst),
        .s_axi_awlock_i(axi_awlock),
        .s_axi_awcache_i(axi_awcache),
        .s_axi_awprot_i(axi_awprot),
        .s_axi_awqos_i(axi_awqos),
        .s_axi_awvalid_i(axi_awvalid),
        .s_axi_awready_o(axi_awready),
        .s_axi_wdata_i(axi_wdata),
        .s_axi_wstrb_i(axi_wstrb),
        .s_axi_wlast_i(axi_wlast),
        .s_axi_wvalid_i(axi_wvalid),
        .s_axi_wready_o(axi_wready),
        .s_axi_bid_o(axi_bid),
        .s_axi_bresp_o(axi_bresp),
        .s_axi_bvalid_o(axi_bvalid),
        .s_axi_bready_i(axi_bready)
    );

    task automatic load_line;
        input integer line_index;
        input [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] line_data;
        begin
            if ((line_index < 0) ||
                (line_index >= (MEM_BYTES / 64)))
                $fatal(1,
                    "DDR3 initialization line out of range: %0d",
                    line_index);
            u_ddr3.u_channel.memory_q[line_index*2] =
                line_data[255:0];
            u_ddr3.u_channel.memory_q[line_index*2 + 1] =
                line_data[511:256];
        end
    endtask

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_bursts_o <= 64'd0;
            write_bursts_o <= 64'd0;
            read_commands_o <= 64'd0;
            write_commands_o <= 64'd0;
            max_command_queue_o <= 64'd0;
            max_timing_owners_o <= 64'd0;
        end else begin
            if (axi_arvalid && axi_arready) begin
                read_bursts_o <= read_bursts_o + 1'b1;
                if ((axi_arid != 3'd7) ||
                    (axi_arlen != 8'd1) ||
                    (axi_arsize != 3'd5) ||
                    (axi_arburst != 2'b01) ||
                    axi_arlock || (axi_araddr[5:0] != 0))
                    $fatal(1,
                        "malformed 4H DDR3 AXI read id=%0d addr=%h len=%0d size=%0d burst=%0d lock=%0b",
                        axi_arid, axi_araddr, axi_arlen,
                        axi_arsize, axi_arburst, axi_arlock);
            end
            if (axi_awvalid && axi_awready) begin
                write_bursts_o <= write_bursts_o + 1'b1;
                if ((axi_awid != 3'd7) ||
                    (axi_awlen != 8'd1) ||
                    (axi_awsize != 3'd5) ||
                    (axi_awburst != 2'b01) ||
                    axi_awlock || (axi_awaddr[5:0] != 0))
                    $fatal(1,
                        "malformed 4H DDR3 AXI write id=%0d addr=%h len=%0d size=%0d burst=%0d lock=%0b",
                        axi_awid, axi_awaddr, axi_awlen,
                        axi_awsize, axi_awburst, axi_awlock);
            end
            if (u_ddr3.timing_cmd_valid &&
                u_ddr3.timing_cmd_ready) begin
                if (u_ddr3.timing_cmd_bytes != 16'd64)
                    $fatal(1,
                        "4H L2 request scheduled as %0d DDR3 bytes",
                        u_ddr3.timing_cmd_bytes);
                if (u_ddr3.timing_cmd_write)
                    write_commands_o <= write_commands_o + 1'b1;
                else
                    read_commands_o <= read_commands_o + 1'b1;
            end
            if (u_ddr3.g_ddr3.u_timing.u_timing.command_count_q >
                max_command_queue_o)
                max_command_queue_o <=
                    u_ddr3.g_ddr3.u_timing.u_timing.command_count_q;
            if (u_ddr3.u_channel.timing_owner_count_q >
                max_timing_owners_o)
                max_timing_owners_o <=
                    u_ddr3.u_channel.timing_owner_count_q;
            if (wb_cyc || wb_stb || wb_we)
                $fatal(1,
                    "4H AXI DDR3 backend drove WISHBONE");
        end
    end

endmodule
