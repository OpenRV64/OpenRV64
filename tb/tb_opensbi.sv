`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zifencei.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"

module tb_opensbi #(
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_DEFAULT,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter bit ENABLE_ZICCLSM = 1'b1,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 8,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer L2_TLB_ENTRIES = 256,
    parameter integer L2_TLB_WAYS = 4,
    parameter integer FETCH_CAROUSEL = 1,
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter integer L1I_DEMAND_MSHRS = 4,
    parameter integer ICX_BUS_TYPE = 0,
    parameter integer ICX_BUS_DATA_WIDTH = 256,
    parameter integer DDR3_ENABLE = 0,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer DDR3_BANK_ROW_SWIZZLE = 1,
    parameter integer MEMORY_TIMING_MODEL = 0,
    parameter bit L1D_PREFETCH_ENABLE = 1'b1,
    parameter integer L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter integer L1D_PREFETCH_QUEUE_LINES = 4,
    parameter integer L1D_PREFETCH_OUTSTANDING = 4,
    parameter integer L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter integer L1D_PREFETCH_PAGE_GATING = 1,
    parameter integer MEMORY_BYTES = 256 * 1024 * 1024,
    parameter logic [31:0] FDT_BASE_LO = 32'h8ff0_0000
) (
    output wire [31:0] checkpoint_cycle_o
`ifdef OPENRV64_VERILATOR_CHECKPOINT
    ,
    input  wire        checkpoint_clk_i
`endif
);

    localparam logic [63:0] RAM_BASE = 64'h8000_0000;
    localparam logic [63:0] FIRMWARE_BASE = 64'h8010_0000;
    localparam logic [63:0] PAYLOAD_BASE = 64'h8020_0000;
    localparam logic [63:0] MAGIC_ADDR = 64'h80e0_0000;
    localparam logic [63:0] FDT_BASE = {32'd0, FDT_BASE_LO};
    localparam logic [63:0] MAGIC_VALUE = 64'h5342_4950_4153_5301;

    localparam integer TRAMPOLINE_WORDS = 32'h0001_0000 / 8;
    localparam integer FIRMWARE_WORDS = 32'h0010_0000 / 8;
    localparam integer PAYLOAD_WORDS = 32'h0001_0000 / 8;
    localparam integer FDT_WORDS = 32'h0001_0000 / 8;

    logic clk;
    logic rst_n;
    logic uart_tx;
    logic soc_rst_n;
    logic core_rst_n;
    logic [31:0] gpio_out;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] trace_cycle;
    logic [4:0] trace_valid;
    logic [4:0] trace_stall;
    logic [4:0] trace_flush;
    logic [4:0] trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0] trace_events;
    logic [7:0] trace_stall_causes;
    logic trace_retire_valid;
    logic trace_retire_arch;
    logic trace_retire_exception;
    logic [4:0] trace_retire_cause;
    logic [63:0] trace_retire_next_pc;
    logic trace_retire_rd_write;
    logic [4:0] trace_retire_rd;
    logic [63:0] trace_retire_wdata;

    string trampoline_memh;
    string firmware_memh;
    string payload_memh;
    string fdt_memh;
    string banner = "OpenSBI v1.9";
    string payload_text = "OPENRV64 SBI TIMER PAYLOAD";
    string linux_panic_text = "Kernel panic";
    string linux_prompt_text = "openrv64# ";
    string linux_plic_text = "riscv-plic:";
    string linux_memory_text = "Memory: ";
    string linux_devtmpfs_text = "devtmpfs: initialized";
    string linux_uart_text = "serial: ttyS0";
    string linux_initmem_text = "Freeing unused kernel image";
    string linux_init_text = "Run /init as init process";
    integer banner_index;
    integer payload_index;
    integer linux_panic_index;
    integer linux_prompt_index;
    integer linux_plic_index;
    integer linux_memory_index;
    integer linux_devtmpfs_index;
    integer linux_uart_index;
    integer linux_initmem_index;
    integer linux_init_index;
    integer cycle_count;
    logic [63:0] progress_last_cycle;
    logic [63:0] progress_last_instret;
    integer uart_byte_count;
    integer payload_words;
    integer max_cycles;
    integer linux_trap_count;
    integer linux_same_trap_count;
    integer linux_ptw_trace_count;
    integer instruction_trace_fd;
    integer lsu_trace_fd;
    integer icx_trace_fd;
    integer l1d_lock_trace_count;
    integer perf_init_index;
    string instruction_trace_path;
    string lsu_trace_path;
    string icx_trace_path;
    logic perf_summary_enabled;

    function automatic string format_ipc;
        input logic [63:0] instructions;
        input logic [63:0] cycles;
        logic [63:0] whole;
        logic [63:0] fraction;
        begin
            if (cycles == 0) begin
                format_ipc = "0.000000";
            end else begin
                whole = instructions / cycles;
                fraction = ((instructions % cycles) * 64'd1000000) /
                           cycles;
                format_ipc = $sformatf("%0d.%06d", whole, fraction);
            end
        end
    endfunction

    logic [63:0] perf_cycles;
    logic [63:0] perf_issued;
    logic [63:0] perf_decoded;
    logic [63:0] perf_retired;
    logic [63:0] perf_issue_width [0:4];
    logic [63:0] perf_decode_width [0:3];
    logic [63:0] perf_retire_width [0:3];
    logic [63:0] perf_frontend_empty;
    logic [63:0] perf_frontend_held;
    logic [63:0] perf_fetch_request_wait;
    logic [63:0] perf_l1i_busy_cycles;
    logic [63:0] perf_dispatch_nonempty;
    logic [63:0] perf_dispatch_no_issue;
    logic [63:0] perf_dispatch_full;
    logic [63:0] perf_retire_nonempty;
    logic [63:0] perf_retire_no_progress;
    logic [63:0] perf_retire_head_incomplete;
    logic [63:0] perf_retire_completed_behind;
    logic [63:0] perf_retire_head_block_load;
    logic [63:0] perf_retire_head_block_store;
    logic [63:0] perf_retire_head_block_branch;
    logic [63:0] perf_retire_head_block_barrier;
    logic [63:0] perf_retire_head_block_alu;
    logic [63:0] perf_lsu_request_wait;
    logic [63:0] perf_barrier_cycles;
    logic [63:0] perf_barrier_entries;
    logic [63:0] perf_barrier_frontend_block_cycles;
    logic [63:0] perf_fence_retired;
    logic [63:0] perf_fence_rr;
    logic [63:0] perf_fence_rw;
    logic [63:0] perf_fence_wr;
    logic [63:0] perf_fence_ww;
    logic [63:0] perf_fence_io;
    logic [63:0] perf_fence_i_retired;
    logic [63:0] perf_sfence_vma_retired;
    logic [63:0] perf_satp_writes;
    logic [63:0] perf_translation_barrier_cycles;
    logic [63:0] perf_store_barrier_cycles;
    logic [63:0] perf_fence_with_posted_stores;
    logic perf_barrier_active_q;
    logic [63:0] perf_control_flushes;

    logic [63:0] perf_branch_allocations;
    logic [63:0] perf_branch_predictions_taken;
    logic [63:0] perf_branch_resolutions;
    logic [63:0] perf_conditional_branches;
    logic [63:0] perf_branches_taken;
    logic [63:0] perf_direction_mispredicts;
    logic [63:0] perf_target_mispredicts;
    logic [63:0] perf_bp_fetch_stall_cycles;

    logic [63:0] perf_itlb_demand_lookups;
    logic [63:0] perf_itlb_demand_hits;
    logic [63:0] perf_itlb_demand_misses;
    logic [63:0] perf_itlb_demand_faults;
    logic [63:0] perf_itlb_prefetch_lookups;
    logic [63:0] perf_itlb_prefetch_hits;
    logic [63:0] perf_itlb_prefetch_misses;
    logic [63:0] perf_itlb_prefetch_faults;
    logic [63:0] perf_dtlb_pipe_lookups;
    logic [63:0] perf_dtlb_pipe_hits;
    logic [63:0] perf_dtlb_pipe_misses;
    logic [63:0] perf_dtlb_pipe_faults;
    logic [63:0] perf_dtlb_serial_lookups;
    logic [63:0] perf_dtlb_serial_hits;
    logic [63:0] perf_dtlb_serial_misses;
    logic [63:0] perf_dtlb_serial_faults;
    logic [63:0] perf_tlb_invalidates;
    logic [63:0] perf_itlb_fills;
    logic [63:0] perf_dtlb_fills;
    logic [63:0] perf_l2_tlb_lookups;
    logic [63:0] perf_l2_tlb_hits;
    logic [63:0] perf_l2_tlb_misses;
    logic [63:0] perf_l2_tlb_fills;
    logic [63:0] perf_l2_tlb_evictions;
    logic [63:0] perf_l2_tlb_superpage_bypasses;
    logic [63:0] perf_ptw_lsu_starts;
    logic [63:0] perf_ptw_fetch_starts;
    logic [63:0] perf_ptw_prefetch_starts;
    logic [63:0] perf_ptw_responses;
    logic [63:0] perf_ptw_faults;
    logic [63:0] perf_ptw_pte_cache_hits;
    logic [63:0] perf_ptw_icx_reads;
    logic [63:0] perf_ptw_active_cycles;

    logic [63:0] perf_l1i_demand_requests;
    logic [63:0] perf_l1i_prefetch_requests;
    logic [63:0] perf_l1i_demand_responses;
    logic [63:0] perf_l1i_prefetch_responses;
    logic [63:0] perf_l1i_line_misses;
    logic [63:0] perf_l1i_line_responses;

    logic [63:0] perf_l1d_load_requests;
    logic [63:0] perf_l1d_store_requests;
    logic [63:0] perf_l1d_load_wait_cycles;
    logic [63:0] perf_l1d_store_wait_cycles;
    logic [63:0] perf_l1d_misses;
    logic [63:0] perf_l1d_mshr_allocations;
    logic [63:0] perf_l1d_mshr_merges;
    logic [63:0] perf_l1d_mshr_responses;
    logic [63:0] perf_l1d_mshr_full_cycles;
    logic [63:0] perf_l1d_mshr_max;
    logic [63:0] perf_l1d_store_allocations;
    logic [63:0] perf_l1d_store_merges;
    logic [63:0] perf_l1d_store_responses;
    logic [63:0] perf_l1d_store_full_cycles;
    logic [63:0] perf_l1d_store_max;
    logic [63:0] perf_l1d_prefetch_issued;
    logic [63:0] perf_l1d_prefetch_useful;
    logic [63:0] perf_l1d_prefetch_on_time_useful;
    logic [63:0] perf_l1d_prefetch_late_useful;
    logic [63:0] perf_l1d_prefetch_late;
    logic [63:0] perf_l1d_prefetch_late_queued;
    logic [63:0] perf_l1d_prefetch_late_command;
    logic [63:0] perf_l1d_prefetch_late_mshr;
    logic [63:0] perf_l1d_prefetch_dropped;
    logic [63:0] perf_l1d_prefetch_useless;
    logic [63:0] perf_l1d_prefetch_max_depth;
    logic [63:0] perf_l1d_store_poison_any_events;
    logic [63:0] perf_l1d_store_poison_prefetch_events;
    logic [63:0] perf_l1d_store_poison_prefetch_queue;
    logic [63:0] perf_l1d_store_poison_prefetch_command;
    logic [63:0] perf_l1d_store_poison_prefetch_mshr;
    logic [63:0] perf_l1d_store_poison_prefetch_fill;
    logic [63:0] perf_l1d_store_poison_demand_events;
    logic [63:0] perf_l1d_store_poison_demand_wait_prefetch;
    logic [63:0] perf_l1d_store_poison_demand_fill;
    logic [63:0] perf_l1d_store_overlay_demand_mshr;

    wire [63:0] perf_lsq_load_allocations;
    wire [63:0] perf_lsq_load_spec_allocations;
    wire [63:0] perf_lsq_load_ordered_allocations;
    wire [63:0] perf_lsq_load_alloc_wait_cycles;
    wire [63:0] perf_lsq_load_queue_full_cycles;
    wire [63:0] perf_lsq_load_xlate_requests;
    wire [63:0] perf_lsq_load_spec_xlate_requests;
    wire [63:0] perf_lsq_load_xlate_wait_cycles;
    wire [63:0] perf_lsq_load_access_requests;
    wire [63:0] perf_lsq_load_spec_access_requests;
    wire [63:0] perf_lsq_load_ordered_access_requests;
    wire [63:0] perf_lsq_load_access_wait_cycles;
    wire [63:0] perf_lsq_load_responses;
    wire [63:0] perf_lsq_load_completions;
    wire [63:0] perf_lsq_load_forwarded;
    wire [63:0] perf_lsq_load_faults;
    wire [63:0] perf_lsq_load_squashed;
    wire [63:0] perf_lsq_load_squashed_before_xlate;
    wire [63:0] perf_lsq_load_squashed_xlate_inflight;
    wire [63:0] perf_lsq_load_squashed_xlate_done;
    wire [63:0] perf_lsq_load_squashed_access_inflight;
    wire [63:0] perf_lsq_load_killed_responses;
    wire [63:0] perf_lsq_load_flushed;
    wire [63:0] perf_lsq_load_dependency_block_cycles;
    wire [63:0] perf_lsq_load_dependency_block_entry_cycles;
    wire [63:0] perf_lsq_load_forward_ready_cycles;
    wire [63:0] perf_lsq_load_forward_ready_entry_cycles;
    wire [63:0] perf_lsq_load_occupancy_entry_cycles;
    wire [63:0] perf_lsq_load_spec_occupancy_entry_cycles;
    wire [63:0] perf_lsq_load_max_occupancy;

    wire [63:0] perf_lsq_store_allocations;
    wire [63:0] perf_lsq_store_spec_allocations;
    wire [63:0] perf_lsq_store_ordered_allocations;
    wire [63:0] perf_lsq_store_atomic_allocations;
    wire [63:0] perf_lsq_store_alloc_wait_cycles;
    wire [63:0] perf_lsq_store_queue_full_cycles;
    wire [63:0] perf_lsq_store_xlate_requests;
    wire [63:0] perf_lsq_store_spec_xlate_requests;
    wire [63:0] perf_lsq_store_xlate_wait_cycles;
    wire [63:0] perf_lsq_store_access_requests;
    wire [63:0] perf_lsq_store_access_wait_cycles;
    wire [63:0] perf_lsq_store_posted_results;
    wire [63:0] perf_lsq_store_done;
    wire [63:0] perf_lsq_store_squashed;
    wire [63:0] perf_lsq_store_squashed_before_xlate;
    wire [63:0] perf_lsq_store_squashed_xlate_inflight;
    wire [63:0] perf_lsq_store_squashed_xlate_done;
    wire [63:0] perf_lsq_store_squashed_access_inflight;
    wire [63:0] perf_lsq_store_killed_responses;
    wire [63:0] perf_lsq_store_flushed;
    wire [63:0] perf_lsq_store_order_wait_cycles;
    wire [63:0] perf_lsq_store_order_wait_entry_cycles;
    wire [63:0] perf_lsq_store_occupancy_entry_cycles;
    wire [63:0] perf_lsq_store_spec_occupancy_entry_cycles;
    wire [63:0] perf_lsq_store_max_occupancy;
    wire [63:0] perf_lsq_atomic_starts;
    wire [63:0] perf_lsq_atomic_done;
    wire [63:0] perf_lsq_atomic_active_cycles;
    wire [63:0] perf_lsq_load_retired;
    wire [63:0] perf_lsq_load_spec_retired;
    wire [63:0] perf_lsq_load_ordered_retired;
    wire [63:0] perf_lsq_store_retired;
    wire [63:0] perf_lsq_store_spec_retired;
    wire [63:0] perf_lsq_store_ordered_retired;
    wire [63:0] perf_lsq_retired_untracked;
    wire [63:0] perf_l1d_demand_reissues;
    wire [63:0] perf_l1d_prefetch_page_ends;

    logic [63:0] perf_icx_requests;
    logic [63:0] perf_icx_icache_reads;
    logic [63:0] perf_icx_dcache_reads;
    logic [63:0] perf_icx_dcache_writes;
    logic [63:0] perf_icx_request_wait_cycles;
    logic [63:0] perf_icx_wdata_wait_cycles;
    logic [63:0] perf_icx_responses;
    logic [63:0] perf_icx_response_wait_cycles;

    logic [63:0] perf_l2_hits;
    logic [63:0] perf_l2_merges;
    logic [63:0] perf_l2_allocations;
    logic [63:0] perf_l2_bypasses;
    logic [63:0] perf_l2_write_arounds;
    logic [63:0] perf_l2_victim_hits;
    logic [63:0] perf_l2_lookup_stall_cycles;
    logic [63:0] perf_l2_command_full_cycles;
    logic [63:0] perf_l2_mshr_full_cycles;
    logic [63:0] perf_l2_mshr_max;
    logic [63:0] perf_l2_command_max;
    logic [63:0] perf_l2_response_max;
    logic [63:0] perf_l2_bus_track_max;
    logic [63:0] perf_l2_bus_reads;
    logic [63:0] perf_l2_bus_writes;
    logic [63:0] perf_l2_bus_wait_cycles;
    logic [63:0] perf_l2_bus_responses;

    logic [63:0] perf_mem_wide_reads;
    logic [63:0] perf_mem_wide_writes;
    logic [63:0] perf_mem_wide_wait_cycles;
    logic [63:0] perf_mem_scalar_reads;
    logic [63:0] perf_mem_scalar_writes;
    logic [63:0] perf_mem_scalar_wait_cycles;
    wire [63:0] perf_ddr3_read_bursts;
    wire [63:0] perf_ddr3_write_bursts;
    wire [63:0] perf_ddr3_read_beats_requested;
    wire [63:0] perf_ddr3_write_beats_requested;
    wire [63:0] perf_ddr3_read_beats_returned;
    wire [63:0] perf_ddr3_write_beats_received;
    wire [63:0] perf_ddr3_read_address_wait;
    wire [63:0] perf_ddr3_write_address_wait;
    wire [63:0] perf_ddr3_write_data_wait;
    wire [63:0] perf_ddr3_read_response_wait;
    wire [63:0] perf_ddr3_write_response_wait;
    wire [63:0] perf_ddr3_timing_backend_wait;
    wire [63:0] perf_ddr3_timing_owner_full;
    wire [63:0] perf_ddr3_read_timing_wait;
    wire [63:0] perf_ddr3_write_timing_wait;
    wire [63:0] perf_ddr3_timing_read_commands;
    wire [63:0] perf_ddr3_timing_write_commands;
    wire [63:0] perf_ddr3_max_read_queue;
    wire [63:0] perf_ddr3_max_write_queue;
    wire [63:0] perf_ddr3_max_timing_owners;
    logic images_staged_q;
    wire memory_images_ready;
    logic saw_banner;
    logic saw_payload_text;
    logic saw_linux_panic;
    logic saw_linux_prompt;
    logic saw_linux_plic;
    logic saw_linux_memory;
    logic saw_linux_devtmpfs;
    logic saw_linux_uart;
    logic saw_linux_initmem;
    logic saw_linux_init;
    logic saw_s_mode;
    logic linux_mode;
    logic stop_at_linux_plic;
    logic delay_probe;
    logic delay_probe_fired;
    logic panic_probe;
    logic panic_probe_fired;
    logic dbcn_probe;
    logic dbcn_probe_fired;
    logic printk_probe;
    logic [11:0] printk_probe_seen;
    wire [`RV64_PRIV_WIDTH-1:0] observed_priv_mode;
    wire [63:0] observed_ra;
    wire [63:0] observed_sp;
    wire [63:0] observed_s0;
    wire [63:0] observed_a0;
    wire [63:0] observed_a1;
    wire [63:0] observed_a2;
    wire [63:0] observed_a6;
    wire [63:0] observed_a7;
    wire [63:0] observed_t0;
    wire [63:0] observed_t1;
    wire [63:0] observed_mcycle;
    wire [63:0] observed_minstret;
    wire [63:0] observed_mcountinhibit;
    wire [63:0] observed_mcause;
    wire [63:0] observed_mtval;
    wire [63:0] observed_scause;
    wire [63:0] observed_stval;
    wire [63:0] observed_satp;
    wire [63:0] observed_stvec;
    wire observed_trap_enter;
    wire [4:0] observed_trap_cause;
    wire [63:0] observed_trap_tval;
    wire observed_ptw_response;
    wire [1:0] observed_ptw_level;
    wire [63:0] observed_ptw_pte_addr;
    wire [63:0] observed_ptw_pte_data;
    wire observed_lsu_req_valid;
    wire observed_lsu_req_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] observed_lsu_req_tag;
    wire observed_lsu_req_lock;
    wire observed_lsu_req_write;
    wire [63:0] observed_lsu_req_addr;
    wire [63:0] observed_lsu_req_wdata;
    wire [7:0] observed_lsu_req_wstrb;
    wire [2:0] observed_lsu_req_size;
    wire observed_lsu_resp_valid;
    wire observed_lsu_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] observed_lsu_resp_tag;
    wire [63:0] observed_lsu_resp_rdata;
    wire observed_lsu_resp_access_fault;
    wire observed_lsu_resp_page_fault;
    wire observed_icx_local_lock;
    wire [1:0] observed_l1d_backend_state;
    wire observed_l1d_input_valid;
    wire observed_l1d_input_ready;
    wire observed_l1d_lock_invalidate_request;
    wire observed_l1d_lock_invalidated;
    wire observed_l1d_l1_req_valid;
    wire observed_l1d_l1_req_ready;
    wire observed_l1d_mem_valid;
    wire observed_l1d_mem_write;
    wire observed_l1d_icx_req_valid;

    assign checkpoint_cycle_o = cycle_count;
    logic [4:0] previous_trap_cause;
    logic [63:0] previous_trap_tval;
    wire [63:0] observed_root_base =
        {8'd0, observed_satp[43:0], 12'd0};
    wire [63:0] observed_root_pte_addr =
        observed_root_base + {52'd0, observed_trap_tval[38:30], 3'b000};
    wire [31:0] observed_root_word_index =
        (observed_root_pte_addr - RAM_BASE) >> 3;
    wire [63:0] observed_trampoline_pte_addr =
        observed_root_base + 64'h0000_0000_0000_0ff0;
    wire [31:0] observed_trampoline_word_index =
        (observed_trampoline_pte_addr - RAM_BASE) >> 3;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(32),
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .BP_TYPE(BP_TYPE),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .ENABLE_ZICCLSM(ENABLE_ZICCLSM),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .L2_BYTES(L2_BYTES),
        .L2_WAYS(L2_WAYS),
        .L2_MERGE_ENTRIES(L2_MERGE_ENTRIES),
        .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
        .L2_TLB_WAYS(L2_TLB_WAYS),
        .FETCH_CAROUSEL(FETCH_CAROUSEL),
        .FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
        .FETCH_ALT_CONFIDENCE_GATE(FETCH_ALT_CONFIDENCE_GATE),
        .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
        .ICX_BUS_TYPE(ICX_BUS_TYPE),
        .ICX_BUS_DATA_WIDTH(ICX_BUS_DATA_WIDTH),
        .DDR3_ENABLE(DDR3_ENABLE),
        .DDR3_READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
        .DDR3_WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
        .DDR3_COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
        .DDR3_BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE),
        .MEMORY_TIMING_MODEL(MEMORY_TIMING_MODEL),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .L1D_PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .L1D_PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .L1D_PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .L1D_PREFETCH_DEMAND_RESERVE(L1D_PREFETCH_DEMAND_RESERVE),
        .L1D_PREFETCH_PAGE_GATING(L1D_PREFETCH_PAGE_GATING),
        .MEMORY_BYTES(MEMORY_BYTES),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64A(1'b1),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
        .gpio_in_i(32'h0),
        .gpio_out_o(gpio_out),
        .external_irq_i(29'h0),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    generate
        if ((DDR3_ENABLE != 0) &&
            (BACKEND_CONFIG == `OPENRV64_BACKEND_3P)) begin :
                g_ddr3_observe
            assign perf_ddr3_read_bursts =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_bursts_q;
            assign perf_ddr3_write_bursts =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_bursts_q;
            assign perf_ddr3_read_beats_requested =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_beats_requested_q;
            assign perf_ddr3_write_beats_requested =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_beats_requested_q;
            assign perf_ddr3_read_beats_returned =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_beats_returned_q;
            assign perf_ddr3_write_beats_received =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_beats_received_q;
            assign perf_ddr3_read_address_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_address_wait_cycles_q;
            assign perf_ddr3_write_address_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_address_wait_cycles_q;
            assign perf_ddr3_write_data_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_data_wait_cycles_q;
            assign perf_ddr3_read_response_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_response_wait_cycles_q;
            assign perf_ddr3_write_response_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_response_wait_cycles_q;
            assign perf_ddr3_timing_backend_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_timing_backend_wait_cycles_q;
            assign perf_ddr3_timing_owner_full =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_timing_owner_full_cycles_q;
            assign perf_ddr3_read_timing_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_read_timing_wait_cycles_q;
            assign perf_ddr3_write_timing_wait =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_write_timing_wait_cycles_q;
            assign perf_ddr3_timing_read_commands =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_timing_read_commands_q;
            assign perf_ddr3_timing_write_commands =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_timing_write_commands_q;
            assign perf_ddr3_max_read_queue =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_max_read_queue_q;
            assign perf_ddr3_max_write_queue =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_max_write_queue_q;
            assign perf_ddr3_max_timing_owners =
                dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram.u_ddr3
                    .u_channel.perf_max_timing_owners_q;
        end else begin : g_no_ddr3_observe
            assign {
                perf_ddr3_read_bursts,
                perf_ddr3_write_bursts,
                perf_ddr3_read_beats_requested,
                perf_ddr3_write_beats_requested,
                perf_ddr3_read_beats_returned,
                perf_ddr3_write_beats_received,
                perf_ddr3_read_address_wait,
                perf_ddr3_write_address_wait,
                perf_ddr3_write_data_wait,
                perf_ddr3_read_response_wait,
                perf_ddr3_write_response_wait,
                perf_ddr3_timing_backend_wait,
                perf_ddr3_timing_owner_full,
                perf_ddr3_read_timing_wait,
                perf_ddr3_write_timing_wait,
                perf_ddr3_timing_read_commands,
                perf_ddr3_timing_write_commands,
                perf_ddr3_max_read_queue,
                perf_ddr3_max_write_queue,
                perf_ddr3_max_timing_owners
            } = '0;
        end
    endgenerate

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_observe_3p
            assign observed_priv_mode =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.priv_mode_q;
            assign observed_ra =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[1];
            assign observed_sp =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2];
            assign observed_s0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8];
            assign observed_a0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[10];
            assign observed_a1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[11];
            assign observed_a2 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[12];
            assign observed_a6 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[16];
            assign observed_a7 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[17];
            assign observed_t0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5];
            assign observed_t1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6];
            assign observed_mcycle =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.u_cmu.mcycle_q;
            assign observed_minstret =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.u_cmu.minstret_q;
            assign observed_mcountinhibit =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.u_cmu.mcountinhibit_q;
            assign observed_mcause =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mcause_q;
            assign observed_mtval =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mtval_q;
            assign observed_scause =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.scause_q;
            assign observed_stval =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.stval_q;
            assign observed_satp =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.satp_q;
            assign observed_stvec =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.stvec_q;
            assign observed_trap_enter =
                dut.u_core.g_backend_3p.u_core_3p.trap_enter;
            assign observed_trap_cause =
                dut.u_core.g_backend_3p.u_core_3p.backend_cause;
            assign observed_trap_tval =
                dut.u_core.g_backend_3p.u_core_3p.trap_tval;
            assign observed_ptw_response = 1'b0;
            assign observed_ptw_level = 2'd0;
            assign observed_ptw_pte_addr = 64'd0;
            assign observed_ptw_pte_data = 64'd0;
            assign observed_lsu_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_valid;
            assign observed_lsu_req_ready =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_bus_ready;
            assign observed_lsu_req_tag =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_tag;
            assign observed_lsu_req_lock =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_lock;
            assign observed_lsu_req_write =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_write;
            assign observed_lsu_req_addr =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_addr;
            assign observed_lsu_req_wdata =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_wdata;
            assign observed_lsu_req_wstrb =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_wstrb;
            assign observed_lsu_req_size =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_size;
            assign perf_lsq_load_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_allocations_q;
            assign perf_lsq_load_spec_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_spec_allocations_q;
            assign perf_lsq_load_ordered_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_ordered_allocations_q;
            assign perf_lsq_load_alloc_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_alloc_wait_cycles_q;
            assign perf_lsq_load_queue_full_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_queue_full_cycles_q;
            assign perf_lsq_load_xlate_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_xlate_requests_q;
            assign perf_lsq_load_spec_xlate_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_spec_xlate_requests_q;
            assign perf_lsq_load_xlate_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_xlate_wait_cycles_q;
            assign perf_lsq_load_access_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_access_requests_q;
            assign perf_lsq_load_spec_access_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_spec_access_requests_q;
            assign perf_lsq_load_ordered_access_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_ordered_access_requests_q;
            assign perf_lsq_load_access_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_access_wait_cycles_q;
            assign perf_lsq_load_responses =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_responses_q;
            assign perf_lsq_load_completions =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_completions_q;
            assign perf_lsq_load_forwarded =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_forwarded_q;
            assign perf_lsq_load_faults =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_faults_q;
            assign perf_lsq_load_squashed =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_squashed_q;
            assign perf_lsq_load_squashed_before_xlate =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_squashed_before_xlate_q;
            assign perf_lsq_load_squashed_xlate_inflight =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_squashed_xlate_inflight_q;
            assign perf_lsq_load_squashed_xlate_done =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_squashed_xlate_done_q;
            assign perf_lsq_load_squashed_access_inflight =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_squashed_access_inflight_q;
            assign perf_lsq_load_killed_responses =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_killed_responses_q;
            assign perf_lsq_load_flushed =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_flushed_q;
            assign perf_lsq_load_dependency_block_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_dependency_block_cycles_q;
            assign perf_lsq_load_dependency_block_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_dependency_block_entry_cycles_q;
            assign perf_lsq_load_forward_ready_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_forward_ready_cycles_q;
            assign perf_lsq_load_forward_ready_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_forward_ready_entry_cycles_q;
            assign perf_lsq_load_occupancy_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_occupancy_cycles_q;
            assign perf_lsq_load_spec_occupancy_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_load_spec_occupancy_cycles_q;
            assign perf_lsq_load_max_occupancy =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_load_max_occupancy_q;
            assign perf_lsq_store_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_allocations_q;
            assign perf_lsq_store_spec_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_spec_allocations_q;
            assign perf_lsq_store_ordered_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_ordered_allocations_q;
            assign perf_lsq_store_atomic_allocations =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_atomic_allocations_q;
            assign perf_lsq_store_alloc_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_alloc_wait_cycles_q;
            assign perf_lsq_store_queue_full_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_queue_full_cycles_q;
            assign perf_lsq_store_xlate_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_xlate_requests_q;
            assign perf_lsq_store_spec_xlate_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_spec_xlate_requests_q;
            assign perf_lsq_store_xlate_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_xlate_wait_cycles_q;
            assign perf_lsq_store_access_requests =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_access_requests_q;
            assign perf_lsq_store_access_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_access_wait_cycles_q;
            assign perf_lsq_store_posted_results =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_posted_results_q;
            assign perf_lsq_store_done =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_done_q;
            assign perf_lsq_store_squashed =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_squashed_q;
            assign perf_lsq_store_squashed_before_xlate =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_squashed_before_xlate_q;
            assign perf_lsq_store_squashed_xlate_inflight =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_store_squashed_xlate_inflight_q;
            assign perf_lsq_store_squashed_xlate_done =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_squashed_xlate_done_q;
            assign perf_lsq_store_squashed_access_inflight =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_store_squashed_access_inflight_q;
            assign perf_lsq_store_killed_responses =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_killed_responses_q;
            assign perf_lsq_store_flushed =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_flushed_q;
            assign perf_lsq_store_order_wait_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_order_wait_cycles_q;
            assign perf_lsq_store_order_wait_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_store_order_wait_entry_cycles_q;
            assign perf_lsq_store_occupancy_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_occupancy_cycles_q;
            assign perf_lsq_store_spec_occupancy_entry_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq
                        .perf_store_spec_occupancy_cycles_q;
            assign perf_lsq_store_max_occupancy =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_store_max_occupancy_q;
            assign perf_lsq_atomic_starts =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_atomic_starts_q;
            assign perf_lsq_atomic_done =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_atomic_done_q;
            assign perf_lsq_atomic_active_cycles =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p
                    .u_exec.u_lsu.u_lsq.perf_atomic_active_cycles_q;
            assign perf_lsq_load_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_load_retired_q;
            assign perf_lsq_load_spec_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_load_spec_retired_q;
            assign perf_lsq_load_ordered_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_load_ordered_retired_q;
            assign perf_lsq_store_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_store_retired_q;
            assign perf_lsq_store_spec_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_store_spec_retired_q;
            assign perf_lsq_store_ordered_retired =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_store_ordered_retired_q;
            assign perf_lsq_retired_untracked =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .perf_lsq_retired_untracked_q;
            assign perf_l1d_demand_reissues =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.perf_demand_reissues_q;
            assign perf_l1d_prefetch_page_ends =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.perf_prefetch_page_ends_q;
            assign observed_lsu_resp_valid =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_valid;
            assign observed_lsu_resp_ready =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_ready;
            assign observed_lsu_resp_tag =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_tag;
            assign observed_lsu_resp_rdata =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_rdata;
            assign observed_lsu_resp_access_fault =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_access_fault;
            assign observed_lsu_resp_page_fault =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_page_fault;
            assign observed_icx_local_lock = 1'b0;
            assign observed_l1d_backend_state =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.backend_state_q;
            assign observed_l1d_input_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .l1d_req_valid;
            assign observed_l1d_input_ready =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .l1d_req_ready;
            assign observed_l1d_lock_invalidate_request =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.lock_invalidate_request;
            assign observed_l1d_lock_invalidated =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.locked_line_invalidated_q;
            assign observed_l1d_l1_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.l1_req_valid;
            assign observed_l1d_l1_req_ready =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.l1_req_ready;
            assign observed_l1d_mem_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.l1_mem_valid;
            assign observed_l1d_mem_write =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.l1_mem_write;
            assign observed_l1d_icx_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .l1d_icx_req_valid;

            wire [2:0] perf_issued_this_cycle =
                dut.u_core.g_backend_3p.u_core_3p.backend_issue_valid[0] +
                dut.u_core.g_backend_3p.u_core_3p.backend_issue_valid[1] +
                dut.u_core.g_backend_3p.u_core_3p.backend_issue_valid[2] +
                dut.u_core.g_backend_3p.u_core_3p.backend_issue_valid[3];
            wire [1:0] perf_decoded_this_cycle =
                dut.u_core.g_backend_3p.u_core_3p.frontend_decode_fire[0] +
                dut.u_core.g_backend_3p.u_core_3p.frontend_decode_fire[1] +
                dut.u_core.g_backend_3p.u_core_3p.frontend_decode_fire[2];
            wire [2:0] perf_l1d_mshr_occupancy =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.demand_mshr_valid_q[0] +
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.demand_mshr_valid_q[1] +
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.demand_mshr_valid_q[2];
            wire perf_retire_head_mem_read =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_record[
                        `OPENRV64_RETIRE_ALLOC_MEM_READ_BIT];
            wire perf_retire_head_mem_write =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_record[
                        `OPENRV64_RETIRE_ALLOC_MEM_WRITE_BIT];
            wire perf_retire_head_control =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_record[
                        `OPENRV64_RETIRE_ALLOC_BRANCH_BIT] ||
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_record[
                        `OPENRV64_RETIRE_ALLOC_JUMP_BIT];
            wire perf_retire_head_hard =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_record[
                        `OPENRV64_RETIRE_ALLOC_HARD_BIT];
            // The classes are mutually exclusive and exhaustive.  A
            // read-modify-write operation is a store; branch/jump is
            // separated from the broader hard-order class; ALU is the
            // catch-all for every remaining non-memory instruction.
            wire perf_retire_head_is_store =
                perf_retire_head_mem_write;
            wire perf_retire_head_is_load =
                !perf_retire_head_is_store &&
                perf_retire_head_mem_read;
            wire perf_retire_head_is_branch =
                !perf_retire_head_is_store &&
                !perf_retire_head_is_load &&
                perf_retire_head_control;
            wire perf_retire_head_is_barrier =
                !perf_retire_head_is_store &&
                !perf_retire_head_is_load &&
                !perf_retire_head_is_branch &&
                perf_retire_head_hard;
            wire [31:0] perf_retire_instr0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_result[
                        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        233 +: 32];
            wire [31:0] perf_retire_instr1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_result[
                        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        233 +: 32];
            wire [31:0] perf_retire_instr2 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend
                    .queue_retire_result[
                        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        233 +: 32];
            wire perf_retire_fence0 =
                dut.u_core.g_backend_3p.u_core_3p.backend_retire_arch[0] &&
                (`RV64_OPCODE(perf_retire_instr0) ==
                    `RV64_OPCODE_MISC_MEM) &&
                (`RV64_FUNCT3(perf_retire_instr0) == `RV64_FUNCT3_FENCE);
            wire perf_retire_fence1 =
                dut.u_core.g_backend_3p.u_core_3p.backend_retire_arch[1] &&
                (`RV64_OPCODE(perf_retire_instr1) ==
                    `RV64_OPCODE_MISC_MEM) &&
                (`RV64_FUNCT3(perf_retire_instr1) == `RV64_FUNCT3_FENCE);
            wire perf_retire_fence2 =
                dut.u_core.g_backend_3p.u_core_3p.backend_retire_arch[2] &&
                (`RV64_OPCODE(perf_retire_instr2) ==
                    `RV64_OPCODE_MISC_MEM) &&
                (`RV64_FUNCT3(perf_retire_instr2) == `RV64_FUNCT3_FENCE);
            wire [2:0] perf_retire_fence = {
                perf_retire_fence2,
                perf_retire_fence1,
                perf_retire_fence0
            };
            wire [31:0] perf_retire_fence_instr =
                perf_retire_fence0 ? perf_retire_instr0 :
                perf_retire_fence1 ? perf_retire_instr1 :
                                     perf_retire_instr2;
            wire perf_fence_rr_event = (|perf_retire_fence) &&
                perf_retire_fence_instr[25] &&
                perf_retire_fence_instr[21];
            wire perf_fence_rw_event = (|perf_retire_fence) &&
                perf_retire_fence_instr[25] &&
                perf_retire_fence_instr[20];
            wire perf_fence_wr_event = (|perf_retire_fence) &&
                perf_retire_fence_instr[24] &&
                perf_retire_fence_instr[21];
            wire perf_fence_ww_event = (|perf_retire_fence) &&
                perf_retire_fence_instr[24] &&
                perf_retire_fence_instr[20];
            wire perf_fence_io_event = (|perf_retire_fence) &&
                (|{perf_retire_fence_instr[27:26],
                   perf_retire_fence_instr[23:22]});
            wire perf_l1d_posted_store_pending =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx.u_bus
                    .u_l1d.store_buffer_count_q != 0;

            always @(posedge clk) begin
                if (core_rst_n && perf_summary_enabled) begin
                    perf_cycles <= perf_cycles + 1'b1;
                    perf_issued <= perf_issued + perf_issued_this_cycle;
                    perf_decoded <= perf_decoded + perf_decoded_this_cycle;
                    perf_retired <= perf_retired +
                        dut.u_core.g_backend_3p.u_core_3p
                            .backend_retire_count;
                    perf_issue_width[perf_issued_this_cycle] <=
                        perf_issue_width[perf_issued_this_cycle] + 1'b1;
                    perf_decode_width[perf_decoded_this_cycle] <=
                        perf_decode_width[perf_decoded_this_cycle] + 1'b1;
                    perf_retire_width[
                        dut.u_core.g_backend_3p.u_core_3p
                            .backend_retire_count] <=
                        perf_retire_width[
                            dut.u_core.g_backend_3p.u_core_3p
                                .backend_retire_count] + 1'b1;

                    if (dut.u_core.g_backend_3p.u_core_3p
                            .fetch_decode_valid == 0)
                        perf_frontend_empty <= perf_frontend_empty + 1'b1;
                    if ((dut.u_core.g_backend_3p.u_core_3p
                             .fetch_decode_valid != 0) &&
                        (dut.u_core.g_backend_3p.u_core_3p
                             .frontend_decode_fire == 0))
                        perf_frontend_held <= perf_frontend_held + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .fetch_pipe_req_valid &&
                        !dut.u_core.g_backend_3p.u_core_3p
                             .fetch_pipe_req_ready)
                        perf_fetch_request_wait <=
                            perf_fetch_request_wait + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.demand_mshr_any_valid_r)
                        perf_l1i_busy_cycles <=
                            perf_l1i_busy_cycles + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_dispatch_occupancy != 0) begin
                        perf_dispatch_nonempty <=
                            perf_dispatch_nonempty + 1'b1;
                        if (perf_issued_this_cycle == 0)
                            perf_dispatch_no_issue <=
                                perf_dispatch_no_issue + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_dispatch_occupancy == 6)
                        perf_dispatch_full <= perf_dispatch_full + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_retire_occupancy != 0) begin
                        perf_retire_nonempty <=
                            perf_retire_nonempty + 1'b1;
                        if (dut.u_core.g_backend_3p.u_core_3p
                                .backend_retire_count == 0)
                            perf_retire_no_progress <=
                                perf_retire_no_progress + 1'b1;
                        if (!dut.u_core.g_backend_3p.u_core_3p.u_backend
                                 .queue_retire_valid[0]) begin
                            perf_retire_head_incomplete <=
                                perf_retire_head_incomplete + 1'b1;
                            if (perf_retire_head_is_store)
                                perf_retire_head_block_store <=
                                    perf_retire_head_block_store + 1'b1;
                            else if (perf_retire_head_is_load)
                                perf_retire_head_block_load <=
                                    perf_retire_head_block_load + 1'b1;
                            else if (perf_retire_head_is_branch)
                                perf_retire_head_block_branch <=
                                    perf_retire_head_block_branch + 1'b1;
                            else if (perf_retire_head_is_barrier)
                                perf_retire_head_block_barrier <=
                                    perf_retire_head_block_barrier + 1'b1;
                            else
                                perf_retire_head_block_alu <=
                                    perf_retire_head_block_alu + 1'b1;
                            if (dut.u_core.g_backend_3p.u_core_3p.u_backend
                                    .completed_entry_valid != 0)
                                perf_retire_completed_behind <=
                                    perf_retire_completed_behind + 1'b1;
                        end
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_mem_valid &&
                        !dut.u_core.g_backend_3p.u_core_3p
                             .backend_mem_ready)
                        perf_lsu_request_wait <=
                            perf_lsu_request_wait + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.backend_barrier)
                        perf_barrier_cycles <= perf_barrier_cycles + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.backend_barrier &&
                        !perf_barrier_active_q)
                        perf_barrier_entries <=
                            perf_barrier_entries + 1'b1;
                    perf_barrier_active_q <=
                        dut.u_core.g_backend_3p.u_core_3p.backend_barrier;
                    if (dut.u_core.g_backend_3p.u_core_3p.backend_barrier &&
                        (dut.u_core.g_backend_3p.u_core_3p
                             .fetch_decode_valid != 0) &&
                        (dut.u_core.g_backend_3p.u_core_3p
                             .frontend_decode_fire == 0))
                        perf_barrier_frontend_block_cycles <=
                            perf_barrier_frontend_block_cycles + 1'b1;
                    if (|perf_retire_fence)
                        perf_fence_retired <= perf_fence_retired +
                            perf_retire_fence0 + perf_retire_fence1 +
                            perf_retire_fence2;
                    if (perf_fence_rr_event)
                        perf_fence_rr <= perf_fence_rr + 1'b1;
                    if (perf_fence_rw_event)
                        perf_fence_rw <= perf_fence_rw + 1'b1;
                    if (perf_fence_wr_event)
                        perf_fence_wr <= perf_fence_wr + 1'b1;
                    if (perf_fence_ww_event)
                        perf_fence_ww <= perf_fence_ww + 1'b1;
                    if (perf_fence_io_event)
                        perf_fence_io <= perf_fence_io + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.backend_fence_i)
                        perf_fence_i_retired <=
                            perf_fence_i_retired + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_sfence_vma)
                        perf_sfence_vma_retired <=
                            perf_sfence_vma_retired + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .backend_satp_write)
                        perf_satp_writes <= perf_satp_writes + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .translation_barrier_busy)
                        perf_translation_barrier_cycles <=
                            perf_translation_barrier_cycles + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.l1d_store_barrier_busy)
                        perf_store_barrier_cycles <=
                            perf_store_barrier_cycles + 1'b1;
                    if ((|perf_retire_fence) &&
                        perf_l1d_posted_store_pending)
                        perf_fence_with_posted_stores <=
                            perf_fence_with_posted_stores + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.control_flush)
                        perf_control_flushes <=
                            perf_control_flushes + 1'b1;

                    if (dut.u_core.g_backend_3p.u_core_3p
                            .bp_branch_allocate)
                        perf_branch_allocations <=
                            perf_branch_allocations + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .bp_prediction_taken)
                        perf_branch_predictions_taken <=
                            perf_branch_predictions_taken + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.branch_resolved)
                        perf_branch_resolutions <=
                            perf_branch_resolutions + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.branch_resolved &&
                        dut.u_core.g_backend_3p.u_core_3p.branch_conditional)
                        perf_conditional_branches <=
                            perf_conditional_branches + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.branch_resolved &&
                        dut.u_core.g_backend_3p.u_core_3p.branch_taken)
                        perf_branches_taken <= perf_branches_taken + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.backend_redirect)
                        perf_direction_mispredicts <=
                            perf_direction_mispredicts + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p
                            .bp_target_mispredict)
                        perf_target_mispredicts <=
                            perf_target_mispredicts + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.bp_fetch_stall)
                        perf_bp_fetch_stall_cycles <=
                            perf_bp_fetch_stall_cycles + 1'b1;

                    if ((dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.fetch_lookup_valid &&
                         !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                              .u_bus.fetch_lookup_bare &&
                         dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.itlb_lookup_hit) ||
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_fetch_walk)
                        perf_itlb_demand_lookups <=
                            perf_itlb_demand_lookups + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.fetch_lookup_valid &&
                        !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.fetch_lookup_bare &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_hit)
                        perf_itlb_demand_hits <=
                            perf_itlb_demand_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_fetch_walk)
                        perf_itlb_demand_misses <=
                            perf_itlb_demand_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.fetch_lookup_valid &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_hit &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_page_fault)
                        perf_itlb_demand_faults <=
                            perf_itlb_demand_faults + 1'b1;
                    if ((dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.prefetch_xlate_lookup &&
                         !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                              .u_bus.prefetch_xlate_bare &&
                         dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.itlb_lookup_hit) ||
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_prefetch_walk)
                        perf_itlb_prefetch_lookups <=
                            perf_itlb_prefetch_lookups + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.prefetch_xlate_lookup &&
                        !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.prefetch_xlate_bare &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_hit)
                        perf_itlb_prefetch_hits <=
                            perf_itlb_prefetch_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_prefetch_walk)
                        perf_itlb_prefetch_misses <=
                            perf_itlb_prefetch_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.prefetch_xlate_lookup &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_hit &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_lookup_page_fault)
                        perf_itlb_prefetch_faults <=
                            perf_itlb_prefetch_faults + 1'b1;

                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_is_xlate)
                        perf_dtlb_pipe_lookups <=
                            perf_dtlb_pipe_lookups + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_is_xlate &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_hit)
                        perf_dtlb_pipe_hits <= perf_dtlb_pipe_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_is_xlate &&
                        !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.dtlb_lookup_hit)
                        perf_dtlb_pipe_misses <=
                            perf_dtlb_pipe_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_is_xlate &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_hit &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_page_fault)
                        perf_dtlb_pipe_faults <=
                            perf_dtlb_pipe_faults + 1'b1;
                    if ((dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.serial_dtlb_lookup &&
                         dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.dtlb_lookup_hit) ||
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_lsu_walk)
                        perf_dtlb_serial_lookups <=
                            perf_dtlb_serial_lookups + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.serial_dtlb_lookup &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_hit)
                        perf_dtlb_serial_hits <=
                            perf_dtlb_serial_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_lsu_walk)
                        perf_dtlb_serial_misses <=
                            perf_dtlb_serial_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.serial_dtlb_lookup &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_hit &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_lookup_page_fault)
                        perf_dtlb_serial_faults <=
                            perf_dtlb_serial_faults + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.tlbi_i)
                        perf_tlb_invalidates <=
                            perf_tlb_invalidates + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.itlb_ptw_fill_valid)
                        perf_itlb_fills <= perf_itlb_fills + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.dtlb_ptw_fill_valid)
                        perf_dtlb_fills <= perf_dtlb_fills + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_lookup)
                        perf_l2_tlb_lookups <=
                            perf_l2_tlb_lookups + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_hit)
                        perf_l2_tlb_hits <= perf_l2_tlb_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_miss)
                        perf_l2_tlb_misses <= perf_l2_tlb_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_fill)
                        perf_l2_tlb_fills <= perf_l2_tlb_fills + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_evict)
                        perf_l2_tlb_evictions <=
                            perf_l2_tlb_evictions + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l2_tlb.diag_superpage_fill)
                        perf_l2_tlb_superpage_bypasses <=
                            perf_l2_tlb_superpage_bypasses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_lsu_walk)
                        perf_ptw_lsu_starts <=
                            perf_ptw_lsu_starts + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_fetch_walk)
                        perf_ptw_fetch_starts <=
                            perf_ptw_fetch_starts + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.start_prefetch_walk)
                        perf_ptw_prefetch_starts <=
                            perf_ptw_prefetch_starts + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.ptw_resp_valid) begin
                        perf_ptw_responses <= perf_ptw_responses + 1'b1;
                        if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.ptw_resp_page_fault ||
                            dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.ptw_resp_access_fault)
                            perf_ptw_faults <= perf_ptw_faults + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_ptw.pte_cache_hit_use)
                        perf_ptw_pte_cache_hits <=
                            perf_ptw_pte_cache_hits + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.ptw_icx_req_valid &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.ptw_icx_req_ready)
                        perf_ptw_icx_reads <=
                            perf_ptw_icx_reads + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.miss_active_q)
                        perf_ptw_active_cycles <=
                            perf_ptw_active_cycles + 1'b1;

                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.l1_request_fire &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.select_demand)
                        perf_l1i_demand_requests <=
                            perf_l1i_demand_requests + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.l1_request_fire &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.select_prefetch)
                        perf_l1i_prefetch_requests <=
                            perf_l1i_prefetch_requests + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.resp_valid_o &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.resp_ready_i)
                        perf_l1i_demand_responses <=
                            perf_l1i_demand_responses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.response_pop &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.response_prefetch_q[
                                dut.u_core.g_backend_3p.u_core_3p.u_bus
                                    .g_icx.u_bus.u_l1i
                                    .response_pop_index])
                        perf_l1i_prefetch_responses <=
                            perf_l1i_prefetch_responses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.icx_req_valid_o &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.icx_req_ready_i)
                        perf_l1i_line_misses <=
                            perf_l1i_line_misses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1i.response_fire)
                        perf_l1i_line_responses <=
                            perf_l1i_line_responses + 1'b1;

                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.l1d_req_valid &&
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.l1d_req_ready) begin
                        if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.l1d_req_write)
                            perf_l1d_store_requests <=
                                perf_l1d_store_requests + 1'b1;
                        else
                            perf_l1d_load_requests <=
                                perf_l1d_load_requests + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.l1d_req_valid &&
                        !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.l1d_req_ready) begin
                        if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.l1d_req_write)
                            perf_l1d_store_wait_cycles <=
                                perf_l1d_store_wait_cycles + 1'b1;
                        else
                            perf_l1d_load_wait_cycles <=
                                perf_l1d_load_wait_cycles + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.l1_miss_fire) begin
                        perf_l1d_misses <= perf_l1d_misses + 1'b1;
                        if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.u_l1d.demand_mshr_match_found_r)
                            perf_l1d_mshr_merges <=
                                perf_l1d_mshr_merges + 1'b1;
                        else
                            perf_l1d_mshr_allocations <=
                                perf_l1d_mshr_allocations + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.demand_mshr_response_fire)
                        perf_l1d_mshr_responses <=
                            perf_l1d_mshr_responses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.demand_mshr_any_valid_r &&
                        !dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                             .u_bus.u_l1d.demand_mshr_free_found_r)
                        perf_l1d_mshr_full_cycles <=
                            perf_l1d_mshr_full_cycles + 1'b1;
                    if (perf_l1d_mshr_occupancy > perf_l1d_mshr_max)
                        perf_l1d_mshr_max <= perf_l1d_mshr_occupancy;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_buffer_accept) begin
                        if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.u_l1d.store_buffer_merge)
                            perf_l1d_store_merges <=
                                perf_l1d_store_merges + 1'b1;
                        else
                            perf_l1d_store_allocations <=
                                perf_l1d_store_allocations + 1'b1;
                    end
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_response_fire)
                        perf_l1d_store_responses <=
                            perf_l1d_store_responses + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_buffer_full)
                        perf_l1d_store_full_cycles <=
                            perf_l1d_store_full_cycles + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_buffer_count_q >
                        perf_l1d_store_max)
                        perf_l1d_store_max <=
                            dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.u_l1d.store_buffer_count_q;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_issued_o)
                        perf_l1d_prefetch_issued <=
                            perf_l1d_prefetch_issued + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_useful_o)
                        perf_l1d_prefetch_useful <=
                            perf_l1d_prefetch_useful + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_on_time_useful)
                        perf_l1d_prefetch_on_time_useful <=
                            perf_l1d_prefetch_on_time_useful + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_late_useful)
                        perf_l1d_prefetch_late_useful <=
                            perf_l1d_prefetch_late_useful + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_late_o)
                        perf_l1d_prefetch_late <=
                            perf_l1d_prefetch_late + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_queued_demand_match_r)
                        perf_l1d_prefetch_late_queued <=
                            perf_l1d_prefetch_late_queued + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_inflight_late_match)
                        perf_l1d_prefetch_late_command <=
                            perf_l1d_prefetch_late_command + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_mshr_late_match_r)
                        perf_l1d_prefetch_late_mshr <=
                            perf_l1d_prefetch_late_mshr + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_dropped_o)
                        perf_l1d_prefetch_dropped <=
                            perf_l1d_prefetch_dropped + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_useless_o)
                        perf_l1d_prefetch_useless <=
                            perf_l1d_prefetch_useless + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.prefetch_depth_o >
                        perf_l1d_prefetch_max_depth)
                        perf_l1d_prefetch_max_depth <=
                            dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                                .u_bus.u_l1d.prefetch_depth_o;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_poison_any_event_r)
                        perf_l1d_store_poison_any_events <=
                            perf_l1d_store_poison_any_events + 1'b1;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_poison_prefetch_event_r)
                        perf_l1d_store_poison_prefetch_events <=
                            perf_l1d_store_poison_prefetch_events + 1'b1;
                    perf_l1d_store_poison_prefetch_queue <=
                        perf_l1d_store_poison_prefetch_queue +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_poison_prefetch_queue_count_r;
                    perf_l1d_store_poison_prefetch_command <=
                        perf_l1d_store_poison_prefetch_command +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_poison_prefetch_command_count_r;
                    perf_l1d_store_poison_prefetch_mshr <=
                        perf_l1d_store_poison_prefetch_mshr +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_poison_prefetch_mshr_count_r;
                    perf_l1d_store_poison_prefetch_fill <=
                        perf_l1d_store_poison_prefetch_fill +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_poison_prefetch_fill_count_r;
                    if (dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d.store_poison_demand_event_r)
                        perf_l1d_store_poison_demand_events <=
                            perf_l1d_store_poison_demand_events + 1'b1;
                    perf_l1d_store_poison_demand_wait_prefetch <=
                        perf_l1d_store_poison_demand_wait_prefetch +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                            .store_poison_demand_wait_prefetch_count_r;
                    perf_l1d_store_poison_demand_fill <=
                        perf_l1d_store_poison_demand_fill +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_poison_demand_fill_count_r;
                    perf_l1d_store_overlay_demand_mshr <=
                        perf_l1d_store_overlay_demand_mshr +
                        dut.u_core.g_backend_3p.u_core_3p.u_bus.g_icx
                            .u_bus.u_l1d
                                .store_overlay_demand_mshr_count_r;

                    if (dut.icx_req_valid && dut.icx_req_ready) begin
                        perf_icx_requests <= perf_icx_requests + 1'b1;
                        if (dut.icx_req_source_id ==
                                `OPENRV64_ICX_SOURCE_ICACHE)
                            perf_icx_icache_reads <=
                                perf_icx_icache_reads + 1'b1;
                        else if (dut.icx_req_source_id ==
                                 `OPENRV64_ICX_SOURCE_DCACHE) begin
                            if (dut.icx_req_op ==
                                    `OPENRV64_ICX_OP_WRITE)
                                perf_icx_dcache_writes <=
                                    perf_icx_dcache_writes + 1'b1;
                            else
                                perf_icx_dcache_reads <=
                                    perf_icx_dcache_reads + 1'b1;
                        end
                    end
                    if (dut.icx_req_valid && !dut.icx_req_ready)
                        perf_icx_request_wait_cycles <=
                            perf_icx_request_wait_cycles + 1'b1;
                    if (dut.icx_wdata_valid && !dut.icx_wdata_ready)
                        perf_icx_wdata_wait_cycles <=
                            perf_icx_wdata_wait_cycles + 1'b1;
                    if (dut.icx_resp_valid && dut.icx_resp_ready)
                        perf_icx_responses <= perf_icx_responses + 1'b1;
                    if (dut.icx_resp_valid && !dut.icx_resp_ready)
                        perf_icx_response_wait_cycles <=
                            perf_icx_response_wait_cycles + 1'b1;

                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .lookup_dispatch_r) begin
                        case (dut.g_icx_l2_platform.u_icx_l2.u_complex
                                  .u_l2.lookup_action_r)
                            3'd2:
                                perf_l2_hits <= perf_l2_hits + 1'b1;
                            3'd3:
                                perf_l2_merges <= perf_l2_merges + 1'b1;
                            3'd4:
                                perf_l2_allocations <=
                                    perf_l2_allocations + 1'b1;
                            3'd5:
                                perf_l2_bypasses <=
                                    perf_l2_bypasses + 1'b1;
                            3'd6:
                                perf_l2_write_arounds <=
                                    perf_l2_write_arounds + 1'b1;
                            3'd7:
                                perf_l2_victim_hits <=
                                    perf_l2_victim_hits + 1'b1;
                            default: begin
                            end
                        endcase
                    end
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .lookup_valid_q &&
                        !dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                             .lookup_dispatch_r)
                        perf_l2_lookup_stall_cycles <=
                            perf_l2_lookup_stall_cycles + 1'b1;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .command_queue_full)
                        perf_l2_command_full_cycles <=
                            perf_l2_command_full_cycles + 1'b1;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .active_mshr_count_r == 8)
                        perf_l2_mshr_full_cycles <=
                            perf_l2_mshr_full_cycles + 1'b1;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .active_mshr_count_r > perf_l2_mshr_max)
                        perf_l2_mshr_max <=
                            dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                                .active_mshr_count_r;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .cmd_count_q > perf_l2_command_max)
                        perf_l2_command_max <=
                            dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                                .cmd_count_q;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .response_count_q > perf_l2_response_max)
                        perf_l2_response_max <=
                            dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                                .response_count_q;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .bus_track_count_q > perf_l2_bus_track_max)
                        perf_l2_bus_track_max <=
                            dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                                .bus_track_count_q;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .bus_req_valid_o &&
                        dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .bus_req_ready_i) begin
                        if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                                .bus_req_write_o)
                            perf_l2_bus_writes <=
                                perf_l2_bus_writes + 1'b1;
                        else
                            perf_l2_bus_reads <=
                                perf_l2_bus_reads + 1'b1;
                    end
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .bus_req_valid_o &&
                        !dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                             .bus_req_ready_i)
                        perf_l2_bus_wait_cycles <=
                            perf_l2_bus_wait_cycles + 1'b1;
                    if (dut.g_icx_l2_platform.u_icx_l2.u_complex.u_l2
                            .bus_response_fire)
                        perf_l2_bus_responses <=
                            perf_l2_bus_responses + 1'b1;

                    if (dut.memory_wide_valid && dut.memory_wide_ready) begin
                        if (dut.memory_wide_write)
                            perf_mem_wide_writes <=
                                perf_mem_wide_writes + 1'b1;
                        else
                            perf_mem_wide_reads <=
                                perf_mem_wide_reads + 1'b1;
                    end
                    if (dut.memory_wide_valid && !dut.memory_wide_ready)
                        perf_mem_wide_wait_cycles <=
                            perf_mem_wide_wait_cycles + 1'b1;
                    if (dut.platform_mem_valid &&
                        dut.platform_mem_ready) begin
                        if (dut.platform_mem_write)
                            perf_mem_scalar_writes <=
                                perf_mem_scalar_writes + 1'b1;
                        else
                            perf_mem_scalar_reads <=
                                perf_mem_scalar_reads + 1'b1;
                    end
                    if (dut.platform_mem_valid && !dut.platform_mem_ready)
                        perf_mem_scalar_wait_cycles <=
                            perf_mem_scalar_wait_cycles + 1'b1;
                end
            end
        end else begin : g_observe_1p
            assign observed_priv_mode = dut.u_core.u_core.u_csrs.priv_mode_q;
            assign observed_ra = dut.u_core.u_core.u_gpr.regs[1];
            assign observed_sp = dut.u_core.u_core.u_gpr.regs[2];
            assign observed_s0 = dut.u_core.u_core.u_gpr.regs[8];
            assign observed_a0 = dut.u_core.u_core.u_gpr.regs[10];
            assign observed_a1 = dut.u_core.u_core.u_gpr.regs[11];
            assign observed_a2 = dut.u_core.u_core.u_gpr.regs[12];
            assign observed_a6 = dut.u_core.u_core.u_gpr.regs[16];
            assign observed_a7 = dut.u_core.u_core.u_gpr.regs[17];
            assign observed_t0 = dut.u_core.u_core.u_gpr.regs[5];
            assign observed_t1 = dut.u_core.u_core.u_gpr.regs[6];
            assign observed_mcycle = dut.u_core.u_core.u_csrs.u_cmu.mcycle_q;
            assign observed_minstret =
                dut.u_core.u_core.u_csrs.u_cmu.minstret_q;
            assign observed_mcountinhibit =
                dut.u_core.u_core.u_csrs.u_cmu.mcountinhibit_q;
            assign observed_mcause = dut.u_core.u_core.u_csrs.mcause_q;
            assign observed_mtval = dut.u_core.u_core.u_csrs.mtval_q;
            assign observed_scause = dut.u_core.u_core.u_csrs.scause_q;
            assign observed_stval = dut.u_core.u_core.u_csrs.stval_q;
            assign observed_satp = dut.u_core.u_core.u_csrs.satp_q;
            assign observed_stvec = dut.u_core.u_core.u_csrs.stvec_q;
            assign observed_trap_enter = dut.u_core.u_core.trap_enter;
            assign observed_trap_cause = dut.u_core.u_core.trap_cause;
            assign observed_trap_tval = dut.u_core.u_core.trap_tval;
            assign observed_ptw_response =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.icx_resp_fire;
            assign observed_ptw_level =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.level_q;
            assign observed_ptw_pte_addr =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.walk_pte_addr;
            assign observed_ptw_pte_data =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.icx_pte_data;
            assign observed_lsu_req_valid = 1'b0;
            assign observed_lsu_req_ready = 1'b0;
            assign observed_lsu_req_tag = 0;
            assign observed_lsu_req_lock = 1'b0;
            assign observed_lsu_req_write = 1'b0;
            assign observed_lsu_req_addr = 64'd0;
            assign observed_lsu_req_wdata = 64'd0;
            assign observed_lsu_req_wstrb = 8'd0;
            assign observed_lsu_req_size = 3'd0;
            assign {
                perf_lsq_load_allocations,
                perf_lsq_load_spec_allocations,
                perf_lsq_load_ordered_allocations,
                perf_lsq_load_alloc_wait_cycles,
                perf_lsq_load_queue_full_cycles,
                perf_lsq_load_xlate_requests,
                perf_lsq_load_spec_xlate_requests,
                perf_lsq_load_xlate_wait_cycles,
                perf_lsq_load_access_requests,
                perf_lsq_load_spec_access_requests,
                perf_lsq_load_ordered_access_requests,
                perf_lsq_load_access_wait_cycles,
                perf_lsq_load_responses,
                perf_lsq_load_completions,
                perf_lsq_load_forwarded,
                perf_lsq_load_faults,
                perf_lsq_load_squashed,
                perf_lsq_load_squashed_before_xlate,
                perf_lsq_load_squashed_xlate_inflight,
                perf_lsq_load_squashed_xlate_done,
                perf_lsq_load_squashed_access_inflight,
                perf_lsq_load_killed_responses,
                perf_lsq_load_flushed,
                perf_lsq_load_dependency_block_cycles,
                perf_lsq_load_dependency_block_entry_cycles,
                perf_lsq_load_forward_ready_cycles,
                perf_lsq_load_forward_ready_entry_cycles,
                perf_lsq_load_occupancy_entry_cycles,
                perf_lsq_load_spec_occupancy_entry_cycles,
                perf_lsq_load_max_occupancy,
                perf_lsq_store_allocations,
                perf_lsq_store_spec_allocations,
                perf_lsq_store_ordered_allocations,
                perf_lsq_store_atomic_allocations,
                perf_lsq_store_alloc_wait_cycles,
                perf_lsq_store_queue_full_cycles,
                perf_lsq_store_xlate_requests,
                perf_lsq_store_spec_xlate_requests,
                perf_lsq_store_xlate_wait_cycles,
                perf_lsq_store_access_requests,
                perf_lsq_store_access_wait_cycles,
                perf_lsq_store_posted_results,
                perf_lsq_store_done,
                perf_lsq_store_squashed,
                perf_lsq_store_squashed_before_xlate,
                perf_lsq_store_squashed_xlate_inflight,
                perf_lsq_store_squashed_xlate_done,
                perf_lsq_store_squashed_access_inflight,
                perf_lsq_store_killed_responses,
                perf_lsq_store_flushed,
                perf_lsq_store_order_wait_cycles,
                perf_lsq_store_order_wait_entry_cycles,
                perf_lsq_store_occupancy_entry_cycles,
                perf_lsq_store_spec_occupancy_entry_cycles,
                perf_lsq_store_max_occupancy,
                perf_lsq_atomic_starts,
                perf_lsq_atomic_done,
                perf_lsq_atomic_active_cycles,
                perf_lsq_load_retired,
                perf_lsq_load_spec_retired,
                perf_lsq_load_ordered_retired,
                perf_lsq_store_retired,
                perf_lsq_store_spec_retired,
                perf_lsq_store_ordered_retired,
                perf_lsq_retired_untracked,
                perf_l1d_demand_reissues,
                perf_l1d_prefetch_page_ends
            } = '0;
            assign observed_lsu_resp_valid = 1'b0;
            assign observed_lsu_resp_ready = 1'b0;
            assign observed_lsu_resp_tag = 0;
            assign observed_lsu_resp_rdata = 64'd0;
            assign observed_lsu_resp_access_fault = 1'b0;
            assign observed_lsu_resp_page_fault = 1'b0;
            assign observed_icx_local_lock = 1'b0;
            assign observed_l1d_backend_state = 2'd0;
            assign observed_l1d_input_valid = 1'b0;
            assign observed_l1d_input_ready = 1'b0;
            assign observed_l1d_lock_invalidate_request = 1'b0;
            assign observed_l1d_lock_invalidated = 1'b0;
            assign observed_l1d_l1_req_valid = 1'b0;
            assign observed_l1d_l1_req_ready = 1'b0;
            assign observed_l1d_mem_valid = 1'b0;
            assign observed_l1d_mem_write = 1'b0;
            assign observed_l1d_icx_req_valid = 1'b0;
        end
    endgenerate

`ifdef OPENRV64_VERILATOR_CHECKPOINT
    always @* clk = checkpoint_clk_i;
`else
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end
`endif

    task automatic report_perf;
        input string name;
        begin
            if (perf_summary_enabled) begin
                $display("PERF BROAD CORE name=%0s cycles=%0d issued=%0d decoded=%0d retired=%0d issue_w0=%0d issue_w1=%0d issue_w2=%0d issue_w3=%0d issue_w4=%0d decode_w0=%0d decode_w1=%0d decode_w2=%0d decode_w3=%0d retire_w0=%0d retire_w1=%0d retire_w2=%0d retire_w3=%0d",
                         name, perf_cycles, perf_issued, perf_decoded,
                         perf_retired,
                         perf_issue_width[0], perf_issue_width[1],
                         perf_issue_width[2], perf_issue_width[3],
                         perf_issue_width[4],
                         perf_decode_width[0], perf_decode_width[1],
                         perf_decode_width[2], perf_decode_width[3],
                         perf_retire_width[0], perf_retire_width[1],
                         perf_retire_width[2], perf_retire_width[3]);
                $display("PERF BROAD STALL name=%0s frontend_empty=%0d frontend_held=%0d fetch_request_wait=%0d l1i_busy=%0d dispatch_nonempty=%0d dispatch_no_issue=%0d dispatch_full=%0d retire_nonempty=%0d retire_no_progress=%0d retire_head_incomplete=%0d retire_completed_behind=%0d lsu_request_wait=%0d barrier_cycles=%0d control_flushes=%0d",
                         name, perf_frontend_empty, perf_frontend_held,
                         perf_fetch_request_wait, perf_l1i_busy_cycles,
                         perf_dispatch_nonempty, perf_dispatch_no_issue,
                         perf_dispatch_full, perf_retire_nonempty,
                         perf_retire_no_progress,
                         perf_retire_head_incomplete,
                         perf_retire_completed_behind,
                         perf_lsu_request_wait, perf_barrier_cycles,
                         perf_control_flushes);
                $display("PERF BROAD RETIRE_HEAD_BLOCK name=%0s load=%0d store=%0d branch=%0d barrier=%0d alu=%0d accounted=%0d",
                         name,
                         perf_retire_head_block_load,
                         perf_retire_head_block_store,
                         perf_retire_head_block_branch,
                         perf_retire_head_block_barrier,
                         perf_retire_head_block_alu,
                         perf_retire_head_block_load +
                             perf_retire_head_block_store +
                             perf_retire_head_block_branch +
                             perf_retire_head_block_barrier +
                             perf_retire_head_block_alu);
                if ((perf_retire_head_block_load +
                     perf_retire_head_block_store +
                     perf_retire_head_block_branch +
                     perf_retire_head_block_barrier +
                     perf_retire_head_block_alu) !=
                    perf_retire_head_incomplete)
                    $fatal(1,
                        "retirement-head block classification mismatch");
                $display("PERF BROAD BARRIER name=%0s hard_entries=%0d hard_active_cycles=%0d hard_frontend_block_cycles=%0d fence=%0d fence_rr=%0d fence_rw=%0d fence_wr=%0d fence_ww=%0d fence_io=%0d fence_i=%0d sfence_vma=%0d satp_writes=%0d translation_cycles=%0d store_drain_cycles=%0d fence_with_posted_stores=%0d",
                         name, perf_barrier_entries,
                         perf_barrier_cycles,
                         perf_barrier_frontend_block_cycles,
                         perf_fence_retired, perf_fence_rr,
                         perf_fence_rw, perf_fence_wr,
                         perf_fence_ww, perf_fence_io,
                         perf_fence_i_retired,
                         perf_sfence_vma_retired,
                         perf_satp_writes,
                         perf_translation_barrier_cycles,
                         perf_store_barrier_cycles,
                         perf_fence_with_posted_stores);
                $display("PERF BROAD BRANCH name=%0s allocations=%0d predicted_taken_cycles=%0d resolutions=%0d conditional=%0d taken=%0d direction_mispredicts=%0d target_mispredicts=%0d fetch_stall_cycles=%0d",
                         name, perf_branch_allocations,
                         perf_branch_predictions_taken,
                         perf_branch_resolutions,
                         perf_conditional_branches, perf_branches_taken,
                         perf_direction_mispredicts,
                         perf_target_mispredicts,
                         perf_bp_fetch_stall_cycles);
                $display("PERF BROAD TLB name=%0s itlb_demand_lookups=%0d itlb_demand_hits=%0d itlb_demand_misses=%0d itlb_demand_faults=%0d itlb_prefetch_lookups=%0d itlb_prefetch_hits=%0d itlb_prefetch_misses=%0d itlb_prefetch_faults=%0d dtlb_pipe_probe_cycles=%0d dtlb_pipe_accepted_hits=%0d dtlb_pipe_miss_cycles=%0d dtlb_pipe_fault_cycles=%0d dtlb_serial_lookups=%0d dtlb_serial_hits=%0d dtlb_serial_misses=%0d dtlb_serial_faults=%0d invalidates=%0d itlb_fills=%0d dtlb_fills=%0d",
                         name, perf_itlb_demand_lookups,
                         perf_itlb_demand_hits,
                         perf_itlb_demand_misses,
                         perf_itlb_demand_faults,
                         perf_itlb_prefetch_lookups,
                         perf_itlb_prefetch_hits,
                         perf_itlb_prefetch_misses,
                         perf_itlb_prefetch_faults,
                         perf_dtlb_pipe_lookups,
                         perf_dtlb_pipe_hits,
                         perf_dtlb_pipe_misses,
                         perf_dtlb_pipe_faults,
                         perf_dtlb_serial_lookups,
                         perf_dtlb_serial_hits,
                         perf_dtlb_serial_misses,
                         perf_dtlb_serial_faults,
                         perf_tlb_invalidates, perf_itlb_fills,
                         perf_dtlb_fills);
                $display("PERF BROAD L2TLB name=%0s lookups=%0d hits=%0d misses=%0d fills=%0d evictions=%0d superpage_bypasses=%0d",
                         name, perf_l2_tlb_lookups,
                         perf_l2_tlb_hits, perf_l2_tlb_misses,
                         perf_l2_tlb_fills, perf_l2_tlb_evictions,
                         perf_l2_tlb_superpage_bypasses);
                $display("PERF BROAD PTW name=%0s lsu_starts=%0d fetch_starts=%0d prefetch_starts=%0d responses=%0d faults=%0d pte_cache_hits=%0d icx_line_reads=%0d active_cycles=%0d",
                         name, perf_ptw_lsu_starts,
                         perf_ptw_fetch_starts,
                         perf_ptw_prefetch_starts,
                         perf_ptw_responses, perf_ptw_faults,
                         perf_ptw_pte_cache_hits, perf_ptw_icx_reads,
                         perf_ptw_active_cycles);
                $display("PERF BROAD L1I name=%0s demand_requests=%0d prefetch_requests=%0d demand_responses=%0d prefetch_responses=%0d line_misses=%0d line_responses=%0d busy_cycles=%0d",
                         name, perf_l1i_demand_requests,
                         perf_l1i_prefetch_requests,
                         perf_l1i_demand_responses,
                         perf_l1i_prefetch_responses,
                         perf_l1i_line_misses,
                         perf_l1i_line_responses,
                         perf_l1i_busy_cycles);
                $display("PERF BROAD L1D name=%0s load_requests=%0d store_requests=%0d load_wait_cycles=%0d store_wait_cycles=%0d misses=%0d mshr_allocations=%0d mshr_merges=%0d mshr_responses=%0d mshr_full_cycles=%0d mshr_max=%0d store_allocations=%0d store_merges=%0d store_responses=%0d store_full_cycles=%0d store_max=%0d prefetch_issued=%0d prefetch_useful=%0d prefetch_useful_pct=%0.2f prefetch_on_time_useful=%0d prefetch_on_time_pct=%0.2f prefetch_late_useful=%0d prefetch_late_useful_pct=%0.2f prefetch_late=%0d prefetch_late_queued=%0d prefetch_late_command=%0d prefetch_late_mshr=%0d prefetch_dropped=%0d prefetch_useless=%0d prefetch_max_depth=%0d",
                         name, perf_l1d_load_requests,
                         perf_l1d_store_requests,
                         perf_l1d_load_wait_cycles,
                         perf_l1d_store_wait_cycles,
                         perf_l1d_misses,
                         perf_l1d_mshr_allocations,
                         perf_l1d_mshr_merges,
                         perf_l1d_mshr_responses,
                         perf_l1d_mshr_full_cycles,
                         perf_l1d_mshr_max,
                         perf_l1d_store_allocations,
                         perf_l1d_store_merges,
                         perf_l1d_store_responses,
                         perf_l1d_store_full_cycles,
                         perf_l1d_store_max,
                         perf_l1d_prefetch_issued,
                         perf_l1d_prefetch_useful,
                         (perf_l1d_prefetch_issued == 0) ? 0.0 :
                            (100.0 * perf_l1d_prefetch_useful /
                             perf_l1d_prefetch_issued),
                         perf_l1d_prefetch_on_time_useful,
                         (perf_l1d_prefetch_issued == 0) ? 0.0 :
                            (100.0 * perf_l1d_prefetch_on_time_useful /
                             perf_l1d_prefetch_issued),
                         perf_l1d_prefetch_late_useful,
                         (perf_l1d_prefetch_issued == 0) ? 0.0 :
                            (100.0 * perf_l1d_prefetch_late_useful /
                             perf_l1d_prefetch_issued),
                         perf_l1d_prefetch_late,
                         perf_l1d_prefetch_late_queued,
                         perf_l1d_prefetch_late_command,
                         perf_l1d_prefetch_late_mshr,
                         perf_l1d_prefetch_dropped,
                         perf_l1d_prefetch_useless,
                         perf_l1d_prefetch_max_depth);
                $display("PERF BROAD L1D_STORE_POISON name=%0s any_events=%0d prefetch_events=%0d prefetch_queue=%0d prefetch_command=%0d prefetch_mshr=%0d prefetch_fill=%0d demand_events=%0d demand_wait_prefetch=%0d demand_fill=%0d demand_mshr_overlays=%0d",
                         name,
                         perf_l1d_store_poison_any_events,
                         perf_l1d_store_poison_prefetch_events,
                         perf_l1d_store_poison_prefetch_queue,
                         perf_l1d_store_poison_prefetch_command,
                         perf_l1d_store_poison_prefetch_mshr,
                         perf_l1d_store_poison_prefetch_fill,
                         perf_l1d_store_poison_demand_events,
                         perf_l1d_store_poison_demand_wait_prefetch,
                         perf_l1d_store_poison_demand_fill,
                         perf_l1d_store_overlay_demand_mshr);
                $display("PERF BROAD SPEC_LOAD name=%0s alloc=%0d spec_alloc=%0d ordered_alloc=%0d xlate=%0d spec_xlate=%0d access=%0d spec_access=%0d ordered_access=%0d responses=%0d completions=%0d forwarded=%0d faults=%0d",
                         name,
                         perf_lsq_load_allocations,
                         perf_lsq_load_spec_allocations,
                         perf_lsq_load_ordered_allocations,
                         perf_lsq_load_xlate_requests,
                         perf_lsq_load_spec_xlate_requests,
                         perf_lsq_load_access_requests,
                         perf_lsq_load_spec_access_requests,
                         perf_lsq_load_ordered_access_requests,
                         perf_lsq_load_responses,
                         perf_lsq_load_completions,
                         perf_lsq_load_forwarded,
                         perf_lsq_load_faults);
                $display("PERF BROAD SPEC_LOAD_WAIT name=%0s alloc_wait=%0d queue_full=%0d xlate_wait=%0d access_wait=%0d dependency_cycles=%0d dependency_entry_cycles=%0d forward_cycles=%0d forward_entry_cycles=%0d occupancy_entry_cycles=%0d spec_occupancy_entry_cycles=%0d max_occupancy=%0d",
                         name,
                         perf_lsq_load_alloc_wait_cycles,
                         perf_lsq_load_queue_full_cycles,
                         perf_lsq_load_xlate_wait_cycles,
                         perf_lsq_load_access_wait_cycles,
                         perf_lsq_load_dependency_block_cycles,
                         perf_lsq_load_dependency_block_entry_cycles,
                         perf_lsq_load_forward_ready_cycles,
                         perf_lsq_load_forward_ready_entry_cycles,
                         perf_lsq_load_occupancy_entry_cycles,
                         perf_lsq_load_spec_occupancy_entry_cycles,
                         perf_lsq_load_max_occupancy);
                $display("PERF BROAD SPEC_LOAD_SQUASH name=%0s branch_total=%0d before_xlate=%0d xlate_inflight=%0d xlate_done=%0d access_inflight=%0d killed_responses=%0d flushed=%0d",
                         name,
                         perf_lsq_load_squashed,
                         perf_lsq_load_squashed_before_xlate,
                         perf_lsq_load_squashed_xlate_inflight,
                         perf_lsq_load_squashed_xlate_done,
                         perf_lsq_load_squashed_access_inflight,
                         perf_lsq_load_killed_responses,
                         perf_lsq_load_flushed);
                $display("PERF BROAD SPEC_LOAD_OUTCOME name=%0s retired=%0d spec_retired=%0d ordered_retired=%0d cache_reissues=%0d branch_aborted=%0d flush_aborted=%0d",
                         name,
                         perf_lsq_load_retired,
                         perf_lsq_load_spec_retired,
                         perf_lsq_load_ordered_retired,
                         perf_l1d_demand_reissues,
                         perf_lsq_load_squashed,
                         perf_lsq_load_flushed);
                $display("PERF BROAD SPEC_STORE name=%0s alloc=%0d spec_alloc=%0d ordered_alloc=%0d atomic_alloc=%0d xlate=%0d spec_xlate=%0d ordered_access=%0d posted_results=%0d done=%0d",
                         name,
                         perf_lsq_store_allocations,
                         perf_lsq_store_spec_allocations,
                         perf_lsq_store_ordered_allocations,
                         perf_lsq_store_atomic_allocations,
                         perf_lsq_store_xlate_requests,
                         perf_lsq_store_spec_xlate_requests,
                         perf_lsq_store_access_requests,
                         perf_lsq_store_posted_results,
                         perf_lsq_store_done);
                $display("PERF BROAD SPEC_STORE_WAIT name=%0s alloc_wait=%0d queue_full=%0d xlate_wait=%0d access_wait=%0d order_wait_cycles=%0d order_wait_entry_cycles=%0d occupancy_entry_cycles=%0d spec_occupancy_entry_cycles=%0d max_occupancy=%0d",
                         name,
                         perf_lsq_store_alloc_wait_cycles,
                         perf_lsq_store_queue_full_cycles,
                         perf_lsq_store_xlate_wait_cycles,
                         perf_lsq_store_access_wait_cycles,
                         perf_lsq_store_order_wait_cycles,
                         perf_lsq_store_order_wait_entry_cycles,
                         perf_lsq_store_occupancy_entry_cycles,
                         perf_lsq_store_spec_occupancy_entry_cycles,
                         perf_lsq_store_max_occupancy);
                $display("PERF BROAD SPEC_STORE_SQUASH name=%0s branch_total=%0d before_xlate=%0d xlate_inflight=%0d xlate_done=%0d access_inflight=%0d killed_responses=%0d flushed=%0d",
                         name,
                         perf_lsq_store_squashed,
                         perf_lsq_store_squashed_before_xlate,
                         perf_lsq_store_squashed_xlate_inflight,
                         perf_lsq_store_squashed_xlate_done,
                         perf_lsq_store_squashed_access_inflight,
                         perf_lsq_store_killed_responses,
                         perf_lsq_store_flushed);
                $display("PERF BROAD SPEC_STORE_OUTCOME name=%0s retired=%0d spec_retired=%0d ordered_retired=%0d cache_reissues=0 branch_aborted=%0d flush_aborted=%0d untracked_retired=%0d",
                         name,
                         perf_lsq_store_retired,
                         perf_lsq_store_spec_retired,
                         perf_lsq_store_ordered_retired,
                         perf_lsq_store_squashed,
                         perf_lsq_store_flushed,
                         perf_lsq_retired_untracked);
                $display("PERF BROAD ATOMIC name=%0s starts=%0d done=%0d active_cycles=%0d",
                         name, perf_lsq_atomic_starts,
                         perf_lsq_atomic_done,
                         perf_lsq_atomic_active_cycles);
                $display("PERF BROAD PREFETCH_PAGE_END name=%0s boundaries_seen=%0d",
                         name, perf_l1d_prefetch_page_ends);
                $display("PERF BROAD ICX name=%0s requests=%0d icache_reads=%0d dcache_reads=%0d dcache_writes=%0d ptw_reads=%0d request_wait_cycles=%0d wdata_wait_cycles=%0d responses=%0d response_wait_cycles=%0d",
                         name, perf_icx_requests,
                         perf_icx_icache_reads,
                         perf_icx_dcache_reads,
                         perf_icx_dcache_writes,
                         perf_ptw_icx_reads,
                         perf_icx_request_wait_cycles,
                         perf_icx_wdata_wait_cycles,
                         perf_icx_responses,
                         perf_icx_response_wait_cycles);
                $display("PERF BROAD L2 name=%0s hits=%0d merges=%0d allocations=%0d bypasses=%0d write_arounds=%0d victim_hits=%0d lookup_stall_cycles=%0d command_full_cycles=%0d mshr_full_cycles=%0d mshr_max=%0d command_max=%0d response_max=%0d bus_track_max=%0d bus_reads=%0d bus_writes=%0d bus_wait_cycles=%0d bus_responses=%0d",
                         name, perf_l2_hits, perf_l2_merges,
                         perf_l2_allocations, perf_l2_bypasses,
                         perf_l2_write_arounds, perf_l2_victim_hits,
                         perf_l2_lookup_stall_cycles,
                         perf_l2_command_full_cycles,
                         perf_l2_mshr_full_cycles,
                         perf_l2_mshr_max, perf_l2_command_max,
                         perf_l2_response_max, perf_l2_bus_track_max,
                         perf_l2_bus_reads, perf_l2_bus_writes,
                         perf_l2_bus_wait_cycles,
                         perf_l2_bus_responses);
                $display("PERF BROAD MEM name=%0s wide_reads=%0d wide_writes=%0d wide_wait_cycles=%0d scalar_reads=%0d scalar_writes=%0d scalar_wait_cycles=%0d",
                         name, perf_mem_wide_reads,
                         perf_mem_wide_writes,
                         perf_mem_wide_wait_cycles,
                         perf_mem_scalar_reads,
                         perf_mem_scalar_writes,
                         perf_mem_scalar_wait_cycles);
                $display("PERF BROAD DDR3_AXI name=%0s read_bursts=%0d write_bursts=%0d read_beats_requested=%0d write_beats_requested=%0d read_beats_returned=%0d write_beats_received=%0d ar_wait=%0d aw_wait=%0d w_wait=%0d r_wait=%0d b_wait=%0d",
                         name, perf_ddr3_read_bursts,
                         perf_ddr3_write_bursts,
                         perf_ddr3_read_beats_requested,
                         perf_ddr3_write_beats_requested,
                         perf_ddr3_read_beats_returned,
                         perf_ddr3_write_beats_received,
                         perf_ddr3_read_address_wait,
                         perf_ddr3_write_address_wait,
                         perf_ddr3_write_data_wait,
                         perf_ddr3_read_response_wait,
                         perf_ddr3_write_response_wait);
                $display("PERF BROAD DDR3_TIMING name=%0s backend_wait=%0d owner_full=%0d read_wait=%0d write_wait=%0d read_commands=%0d write_commands=%0d max_read_queue=%0d max_write_queue=%0d max_timing_owners=%0d",
                         name, perf_ddr3_timing_backend_wait,
                         perf_ddr3_timing_owner_full,
                         perf_ddr3_read_timing_wait,
                         perf_ddr3_write_timing_wait,
                         perf_ddr3_timing_read_commands,
                         perf_ddr3_timing_write_commands,
                         perf_ddr3_max_read_queue,
                         perf_ddr3_max_write_queue,
                         perf_ddr3_max_timing_owners);
            end
        end
    endtask

    task automatic match_byte;
        input logic [7:0] value;
        begin
            if (!saw_banner) begin
                if (value == banner[banner_index]) begin
                    banner_index = banner_index + 1;
                    if (banner_index == banner.len()) begin
                        saw_banner = 1'b1;
                        if (linux_mode)
                            $display("\nPERF SIGNPOST name=opensbi cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                                     cycle_count, observed_minstret,
                                     uart_byte_count, dbg_pc);
                        if (linux_mode)
                            report_perf("opensbi");
                    end
                end else begin
                    banner_index = (value == banner[0]) ? 1 : 0;
                end
            end

            if (!saw_payload_text) begin
                if (value == payload_text[payload_index]) begin
                    payload_index = payload_index + 1;
                    if (payload_index == payload_text.len()) begin
                        saw_payload_text = 1'b1;
                        if (linux_mode)
                            $display("\nPERF SIGNPOST name=linux cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                                     cycle_count, observed_minstret,
                                     uart_byte_count, dbg_pc);
                        if (linux_mode)
                            report_perf("linux");
                    end
                end else begin
                    payload_index = (value == payload_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_panic) begin
                if (value == linux_panic_text[linux_panic_index]) begin
                    linux_panic_index = linux_panic_index + 1;
                    if (linux_panic_index == linux_panic_text.len()) begin
                        saw_linux_panic = 1'b1;
                    end
                end else begin
                    linux_panic_index =
                        (value == linux_panic_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_prompt) begin
                if (value == linux_prompt_text[linux_prompt_index]) begin
                    linux_prompt_index = linux_prompt_index + 1;
                    if (linux_prompt_index == linux_prompt_text.len()) begin
                        saw_linux_prompt = 1'b1;
                        $display("\nPERF SIGNPOST name=bash cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                                 cycle_count, observed_minstret,
                                 uart_byte_count, dbg_pc);
                        report_perf("bash");
                    end
                end else begin
                    linux_prompt_index =
                        (value == linux_prompt_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_plic) begin
                if (value == linux_plic_text[linux_plic_index]) begin
                    linux_plic_index = linux_plic_index + 1;
                    if (linux_plic_index == linux_plic_text.len()) begin
                        saw_linux_plic = 1'b1;
                        $display("\nPERF SIGNPOST name=plic cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                                 cycle_count, observed_minstret,
                                 uart_byte_count, dbg_pc);
                        report_perf("plic");
                    end
                end else begin
                    linux_plic_index =
                        (value == linux_plic_text[0]) ? 1 : 0;
                end
            end

            match_linux_signpost(
                value, linux_memory_text, "memory",
                linux_memory_index, saw_linux_memory);
            match_linux_signpost(
                value, linux_devtmpfs_text, "devtmpfs",
                linux_devtmpfs_index, saw_linux_devtmpfs);
            match_linux_signpost(
                value, linux_uart_text, "uart",
                linux_uart_index, saw_linux_uart);
            match_linux_signpost(
                value, linux_initmem_text, "initmem",
                linux_initmem_index, saw_linux_initmem);
            match_linux_signpost(
                value, linux_init_text, "init",
                linux_init_index, saw_linux_init);
        end
    endtask

    task automatic match_linux_signpost;
        input logic [7:0] value;
        input string text;
        input string name;
        inout integer index;
        inout logic seen;
        begin
            if (linux_mode && !seen) begin
                if (value == text[index]) begin
                    index = index + 1;
                    if (index == text.len()) begin
                        seen = 1'b1;
                        $display("\nPERF SIGNPOST name=%0s cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                                 name, cycle_count, observed_minstret,
                                 uart_byte_count, dbg_pc);
                        report_perf(name);
                    end
                end else begin
                    index = (value == text[0]) ? 1 : 0;
                end
            end
        end
    endtask

    task automatic load_images;
        begin
            $display("OpenSBI load: trampoline");
            $readmemh(trampoline_memh, dut.u_memory.memory_q,
                      (RAM_BASE - RAM_BASE) >> 3,
                      ((RAM_BASE - RAM_BASE) >> 3)
                          + TRAMPOLINE_WORDS - 1);
            $display("OpenSBI load: firmware");
            $readmemh(firmware_memh, dut.u_memory.memory_q,
                      (FIRMWARE_BASE - RAM_BASE) >> 3,
                      ((FIRMWARE_BASE - RAM_BASE) >> 3)
                          + FIRMWARE_WORDS - 1);
            $display("OpenSBI load: payload");
            $readmemh(payload_memh, dut.u_memory.memory_q,
                      (PAYLOAD_BASE - RAM_BASE) >> 3,
                      ((PAYLOAD_BASE - RAM_BASE) >> 3)
                          + payload_words - 1);
            $display("OpenSBI load: FDT");
            $readmemh(fdt_memh, dut.u_memory.memory_q,
                      (FDT_BASE - RAM_BASE) >> 3,
                      ((FDT_BASE - RAM_BASE) >> 3) + FDT_WORDS - 1);
            $display("OpenSBI load: complete");
            images_staged_q = 1'b1;
        end
    endtask

    generate
        if ((DDR3_ENABLE != 0) &&
            (BACKEND_CONFIG == `OPENRV64_BACKEND_3P)) begin :
                g_ddr3_image_mirror
            integer mirror_word;
            reg ddr3_images_mirrored_q;

            initial ddr3_images_mirrored_q = 1'b0;

            always @(posedge clk) begin
                if (images_staged_q && !ddr3_images_mirrored_q) begin
                    for (mirror_word =
                             (RAM_BASE - RAM_BASE) >> 3;
                         mirror_word <
                             ((RAM_BASE - RAM_BASE) >> 3) +
                             TRAMPOLINE_WORDS;
                         mirror_word = mirror_word + 1)
                        dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram
                            .u_ddr3.u_channel.memory_q[mirror_word >> 2]
                            [(mirror_word & 3) * 64 +: 64] =
                            dut.u_memory.memory_q[mirror_word];
                    for (mirror_word =
                             (FIRMWARE_BASE - RAM_BASE) >> 3;
                         mirror_word <
                             ((FIRMWARE_BASE - RAM_BASE) >> 3) +
                             FIRMWARE_WORDS;
                         mirror_word = mirror_word + 1)
                        dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram
                            .u_ddr3.u_channel.memory_q[mirror_word >> 2]
                            [(mirror_word & 3) * 64 +: 64] =
                            dut.u_memory.memory_q[mirror_word];
                    for (mirror_word =
                             (PAYLOAD_BASE - RAM_BASE) >> 3;
                         mirror_word <
                             ((PAYLOAD_BASE - RAM_BASE) >> 3) +
                             payload_words;
                         mirror_word = mirror_word + 1)
                        dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram
                            .u_ddr3.u_channel.memory_q[mirror_word >> 2]
                            [(mirror_word & 3) * 64 +: 64] =
                            dut.u_memory.memory_q[mirror_word];
                    for (mirror_word =
                             (FDT_BASE - RAM_BASE) >> 3;
                         mirror_word <
                             ((FDT_BASE - RAM_BASE) >> 3) + FDT_WORDS;
                         mirror_word = mirror_word + 1)
                        dut.g_icx_l2_platform.u_icx_l2.g_ddr3_ram
                            .u_ddr3.u_channel.memory_q[mirror_word >> 2]
                            [(mirror_word & 3) * 64 +: 64] =
                            dut.u_memory.memory_q[mirror_word];
                    ddr3_images_mirrored_q = 1'b1;
                    $display("OpenSBI load: DDR3 mirror complete");
                end
            end

            assign memory_images_ready = ddr3_images_mirrored_q;
        end else begin : g_no_ddr3_image_mirror
            assign memory_images_ready = images_staged_q;
        end
    endgenerate

    task automatic report_timeout;
        begin
            if (linux_mode) begin
                $display("LINUX TIMEOUT cycles=%0d instret=%0d pc=%016x instr=%08x priv=%0d banner=%b linux_banner=%b uart_bytes=%0d mcause=%016x mtval=%016x scause=%016x stval=%016x",
                         cycle_count, observed_minstret, dbg_pc, dbg_instr,
                         observed_priv_mode, saw_banner, saw_payload_text,
                         uart_byte_count, observed_mcause, observed_mtval,
                         observed_scause, observed_stval);
                report_perf("timeout");
                $finish;
            end else begin
                $fatal(1,
                       "OpenSBI timeout pc=%016x instr=%08x priv=%0d banner=%b payload=%b magic=%016x mcause=%016x mtval=%016x",
                       dbg_pc, dbg_instr, observed_priv_mode,
                       saw_banner, saw_payload_text,
                       dut.u_memory.memory_q[
                           (MAGIC_ADDR - RAM_BASE) >> 3],
                       observed_mcause, observed_mtval);
            end
        end
    endtask

    always @(posedge clk) begin
        if (core_rst_n &&
            (observed_priv_mode == `RV64_PRIV_S)) begin
            saw_s_mode <= 1'b1;
        end

        if (core_rst_n && dut.u_uart.write_thr) begin
            uart_byte_count <= uart_byte_count + 1;
            $write("%c", dut.uart_wdata[7:0]);
            match_byte(dut.uart_wdata[7:0]);
        end

        if (core_rst_n) begin
            cycle_count <= cycle_count + 1;
            if ((instruction_trace_fd != 0) && trace_retire_valid)
                $fdisplay(instruction_trace_fd,
                    "cycle=%0d pc=%016x instr=%08x priv=%0d arch=%0d exception=%0d cause=%0d next=%016x rd_write=%0d rd=%0d wdata=%016x",
                    cycle_count, trace_pcs[319:256],
                    trace_instrs[159:128], observed_priv_mode,
                    trace_retire_arch, trace_retire_exception,
                    trace_retire_cause, trace_retire_next_pc,
                    trace_retire_rd_write, trace_retire_rd,
                    trace_retire_wdata);
            if ((lsu_trace_fd != 0) &&
                observed_lsu_req_valid && observed_lsu_req_ready)
                $fdisplay(lsu_trace_fd,
                    "REQ cycle=%0d pc=%016x tag=%0d lock=%0d write=%0d addr=%016x data=%016x strb=%02x size=%0d",
                    cycle_count, dbg_pc, observed_lsu_req_tag,
                    observed_lsu_req_lock, observed_lsu_req_write,
                    observed_lsu_req_addr, observed_lsu_req_wdata,
                    observed_lsu_req_wstrb, observed_lsu_req_size);
            if ((lsu_trace_fd != 0) &&
                observed_lsu_resp_valid && observed_lsu_resp_ready)
                $fdisplay(lsu_trace_fd,
                    "RESP cycle=%0d pc=%016x tag=%0d data=%016x access_fault=%0d page_fault=%0d",
                    cycle_count, dbg_pc, observed_lsu_resp_tag,
                    observed_lsu_resp_rdata,
                    observed_lsu_resp_access_fault,
                    observed_lsu_resp_page_fault);
            if ((lsu_trace_fd != 0) && observed_icx_local_lock &&
                (l1d_lock_trace_count < 256)) begin
                l1d_lock_trace_count <= l1d_lock_trace_count + 1;
                $fdisplay(lsu_trace_fd,
                    "LOCK cycle=%0d input=%0d/%0d invreq=%0d invalidated=%0d l1=%0d/%0d mem=%0d/%0d backend=%0d icx=%0d",
                    cycle_count, observed_l1d_input_valid,
                    observed_l1d_input_ready,
                    observed_l1d_lock_invalidate_request,
                    observed_l1d_lock_invalidated,
                    observed_l1d_l1_req_valid,
                    observed_l1d_l1_req_ready,
                    observed_l1d_mem_valid,
                    observed_l1d_mem_write,
                    observed_l1d_backend_state,
                    observed_l1d_icx_req_valid);
            end
            if ((icx_trace_fd != 0) &&
                dut.icx_req_valid && dut.icx_req_ready)
                $fdisplay(icx_trace_fd,
                    "CMD cycle=%0d hart=%0d txn=%0d source=%0d op=%0d lock=%0d kind=%0d attr=%02x size=%0d addr=%016x burst=%0d",
                    cycle_count, dut.icx_req_hart_id,
                    dut.icx_req_txn_id, dut.icx_req_source_id,
                    dut.icx_req_op, dut.icx_req_lock, dut.icx_req_kind,
                    dut.icx_req_attr, dut.icx_req_size,
                    dut.icx_req_addr, dut.icx_req_burst_len);
            if ((icx_trace_fd != 0) &&
                dut.icx_wdata_valid && dut.icx_wdata_ready)
                $fdisplay(icx_trace_fd,
                    "WDATA cycle=%0d hart=%0d txn=%0d source=%0d beat=%0d last=%0d data=%0128x strb=%016x",
                    cycle_count, dut.icx_wdata_hart_id,
                    dut.icx_wdata_txn_id, dut.icx_wdata_source_id,
                    dut.icx_wdata_beat_index, dut.icx_wdata_last,
                    dut.icx_wdata, dut.icx_wstrb);
            if ((icx_trace_fd != 0) &&
                dut.icx_resp_valid && dut.icx_resp_ready)
                $fdisplay(icx_trace_fd,
                    "RESP cycle=%0d hart=%0d txn=%0d source=%0d beat=%0d last=%0d error=%0d data=%0128x",
                    cycle_count, dut.icx_resp_hart_id,
                    dut.icx_resp_txn_id, dut.icx_resp_source_id,
                    dut.icx_resp_beat_index, dut.icx_resp_last,
                    dut.icx_resp_error, dut.icx_resp_rdata);
            if (linux_mode && saw_s_mode && observed_ptw_response &&
                (linux_ptw_trace_count < 16)) begin
                linux_ptw_trace_count <= linux_ptw_trace_count + 1;
                $display("Linux PTW cycles=%0d level=%0d pte_addr=%016x pte=%016x",
                         cycle_count, observed_ptw_level,
                         observed_ptw_pte_addr, observed_ptw_pte_data);
            end
            if (linux_mode && saw_s_mode && observed_trap_enter) begin
                linux_trap_count <= linux_trap_count + 1;
                if ((observed_trap_cause == previous_trap_cause) &&
                    (observed_trap_tval == previous_trap_tval))
                    linux_same_trap_count <= linux_same_trap_count + 1;
                else
                    linux_same_trap_count <= 0;
                previous_trap_cause <= observed_trap_cause;
                previous_trap_tval <= observed_trap_tval;
                if (linux_trap_count < 16)
                    $display("Linux trap cycles=%0d cause=%0d tval=%016x priv=%0d satp=%016x stvec=%016x mcause=%016x mtval=%016x scause=%016x stval=%016x",
                         cycle_count, observed_trap_cause,
                         observed_trap_tval, observed_priv_mode,
                         observed_satp, observed_stvec,
                         observed_mcause, observed_mtval,
                         observed_scause, observed_stval);
                if (linux_trap_count == 0) begin
                    $display("Linux faulting root PTE addr=%016x value=%016x",
                             observed_root_pte_addr,
                             dut.u_memory.memory_q[
                                 observed_root_word_index]);
                    $display("Linux trampoline root PTE addr=%016x value=%016x",
                             observed_trampoline_pte_addr,
                             dut.u_memory.memory_q[
                                 observed_trampoline_word_index]);
                end
                if (linux_same_trap_count == 255) begin
                    $display("LINUX TRAP LOOP cycles=%0d cause=%0d tval=%016x satp=%016x stvec=%016x",
                             cycle_count, observed_trap_cause,
                             observed_trap_tval,
                             observed_satp, observed_stvec);
                    $finish;
                end
            end
            if (((cycle_count != 0) && (cycle_count <= 10000) &&
                 ((cycle_count % 1000) == 0)) ||
                ((cycle_count > 10000) && (cycle_count <= 250000) &&
                 ((cycle_count % 10000) == 0)) ||
                ((cycle_count != 0) && ((cycle_count % 250000) == 0))) begin
                $display("OpenSBI progress cycles=%0d instret=%0d ipc=%0s interval_ipc=%0s pc=%016x instr=%08x priv=%0d uart_bytes=%0d t0=%016x t1=%016x mcause=%016x mtval=%016x",
                         cycle_count, observed_minstret,
                         format_ipc(observed_minstret, cycle_count),
                         format_ipc(
                             observed_minstret - progress_last_instret,
                             cycle_count - progress_last_cycle),
                         dbg_pc, dbg_instr,
                         observed_priv_mode,
                         uart_byte_count,
                         observed_t0, observed_t1,
                         observed_mcause, observed_mtval);
                progress_last_cycle <= cycle_count;
                progress_last_instret <= observed_minstret;
                if (linux_mode && (observed_priv_mode == `RV64_PRIV_S))
                    $display("Linux trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                             trace_valid, trace_stall, trace_flush,
                             trace_advance, trace_stall_causes,
                             trace_pcs[63:0], trace_pcs[127:64],
                             trace_pcs[191:128], trace_pcs[255:192],
                             trace_pcs[319:256],
                             trace_instrs[31:0], trace_instrs[63:32],
                             trace_instrs[95:64], trace_instrs[127:96],
                             trace_instrs[159:128]);
            end
            if (linux_mode && delay_probe && !delay_probe_fired &&
                (dbg_pc >= 64'hffff_ffff_801d_4d48) &&
                (dbg_pc <= 64'hffff_ffff_801d_4d58)) begin
                delay_probe_fired <= 1'b1;
                $display("LINUX DELAY ENTRY cycles=%0d pc=%016x instr=%08x ra=%016x caller_pc=%016x sp=%016x s0=%016x a0=%016x mcycle=%016x mcountinhibit=%016x",
                         cycle_count, dbg_pc, dbg_instr,
                         observed_ra, observed_ra - 64'd4,
                         observed_sp, observed_s0, observed_a0,
                         observed_mcycle, observed_mcountinhibit);
                $display("Linux delay trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                         trace_valid, trace_stall, trace_flush,
                         trace_advance, trace_stall_causes,
                         trace_pcs[63:0], trace_pcs[127:64],
                         trace_pcs[191:128], trace_pcs[255:192],
                         trace_pcs[319:256],
                         trace_instrs[31:0], trace_instrs[63:32],
                         trace_instrs[95:64], trace_instrs[127:96],
                         trace_instrs[159:128]);
                $finish;
            end
            if (linux_mode && panic_probe && !panic_probe_fired &&
                (dbg_pc == 64'hffff_ffff_8000_13b4)) begin
                panic_probe_fired <= 1'b1;
                $display("LINUX PANIC ENTRY cycles=%0d pc=%016x instr=%08x ra=%016x caller_pc=%016x sp=%016x a0=%016x a1=%016x a2=%016x",
                         cycle_count, dbg_pc, dbg_instr,
                         observed_ra, observed_ra - 64'd4,
                         observed_sp, observed_a0, observed_a1, observed_a2);
                $display("Linux panic trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                         trace_valid, trace_stall, trace_flush,
                         trace_advance, trace_stall_causes,
                         trace_pcs[63:0], trace_pcs[127:64],
                         trace_pcs[191:128], trace_pcs[255:192],
                         trace_pcs[319:256],
                         trace_instrs[31:0], trace_instrs[63:32],
                         trace_instrs[95:64], trace_instrs[127:96],
                         trace_instrs[159:128]);
                $finish;
            end
            if (linux_mode && dbcn_probe && !dbcn_probe_fired &&
                observed_trap_enter && (observed_trap_cause == 5'd9) &&
                (observed_a7 == 64'h0000_0000_4442_434e)) begin
                dbcn_probe_fired <= 1'b1;
                $display("LINUX DBCN ECALL cycles=%0d func=%0d count=%0d phys=%016x phys_hi=%016x pc=%016x",
                         cycle_count, observed_a6, observed_a0,
                         observed_a1, observed_a2, dbg_pc);
                if ((observed_a1 >= RAM_BASE) &&
                    (observed_a1 < FDT_BASE)) begin
                    $display("Linux DBCN buffer qwords=%016x %016x %016x %016x",
                             dut.u_memory.memory_q[
                                 (observed_a1 - RAM_BASE) >> 3],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 1],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 2],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 3]);
                end
                $finish;
            end
            if (linux_mode && printk_probe) begin
                if (!printk_probe_seen[0] &&
                    (dbg_pc == 64'hffff_ffff_801e_c71c)) begin
                    printk_probe_seen[0] <= 1'b1;
                    $display("LINUX PRINTK PC start_kernel cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[1] &&
                    (dbg_pc == 64'hffff_ffff_801e_f7a4)) begin
                    printk_probe_seen[1] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_init cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[2] &&
                    (dbg_pc == 64'hffff_ffff_801e_f7bc)) begin
                    printk_probe_seen[2] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_spec_result cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[3] &&
                    (dbg_pc == 64'hffff_ffff_801e_f970)) begin
                    printk_probe_seen[3] <= 1'b1;
                    $display("LINUX PRINTK PC dbcn_probe_result cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[4] &&
                    (dbg_pc == 64'hffff_ffff_801e_f988)) begin
                    printk_probe_seen[4] <= 1'b1;
                    $display("LINUX PRINTK PC dbcn_available_store cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[5] &&
                    (dbg_pc == 64'hffff_ffff_801e_c69c)) begin
                    printk_probe_seen[5] <= 1'b1;
                    $display("LINUX PRINTK PC parse_early_param cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[6] &&
                    (dbg_pc == 64'hffff_ffff_8020_0684)) begin
                    printk_probe_seen[6] <= 1'b1;
                    $display("LINUX PRINTK PC param_setup_earlycon cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[7] &&
                    (dbg_pc == 64'hffff_ffff_8020_03c8)) begin
                    printk_probe_seen[7] <= 1'b1;
                    $display("LINUX PRINTK PC setup_earlycon cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[8] &&
                    (dbg_pc == 64'hffff_ffff_8020_09dc)) begin
                    printk_probe_seen[8] <= 1'b1;
                    $display("LINUX PRINTK PC early_sbi_setup cycles=%0d pc=%016x available_qword=%016x",
                             cycle_count, dbg_pc,
                             dut.u_memory.memory_q[
                                 (64'h804e_10d8 - RAM_BASE) >> 3]);
                end
                if (!printk_probe_seen[9] &&
                    (dbg_pc == 64'hffff_ffff_8005_80cc)) begin
                    printk_probe_seen[9] <= 1'b1;
                    $display("LINUX PRINTK PC register_console cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[10] &&
                    (dbg_pc == 64'hffff_ffff_8017_3c80)) begin
                    printk_probe_seen[10] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_dbcn_console_write cycles=%0d pc=%016x buf=%016x count=%0d",
                             cycle_count, dbg_pc, observed_a1, observed_a2);
                end
                if (!printk_probe_seen[11] &&
                    (dbg_pc == 64'hffff_ffff_8000_a8d8)) begin
                    printk_probe_seen[11] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_debug_console_write cycles=%0d pc=%016x buf=%016x count=%0d available_qword=%016x",
                             cycle_count, dbg_pc, observed_a0, observed_a1,
                             dut.u_memory.memory_q[
                                 (64'h804e_10d8 - RAM_BASE) >> 3]);
                end
            end
        end

        if (core_rst_n && dut.core_mem_valid && dut.core_mem_ready &&
            dut.core_mem_error) begin
            $fatal(1,
                   "OpenSBI bus fault pc=%016x addr=%016x write=%b instr=%08x priv=%0d",
                   dbg_pc, dut.core_mem_addr, dut.core_mem_write, dbg_instr,
                   observed_priv_mode);
        end

        if (!linux_mode && saw_banner && saw_payload_text && saw_s_mode &&
            (dut.u_memory.memory_q[(MAGIC_ADDR - RAM_BASE) >> 3] ==
             MAGIC_VALUE)) begin
            if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P)
                $display("PASS: 3P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            else
                $display("PASS: 1P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            $finish;
        end

        if (linux_mode && saw_linux_panic) begin
            $display("PASS: Linux reached a kernel panic after OpenSBI handoff");
            $finish;
        end

        if (linux_mode && saw_linux_prompt &&
            !$test$plusargs("continue_after_linux_prompt")) begin
            $display("\nPASS: Linux reached interactive static Bash prompt as PID 1");
            $finish;
        end

        if (linux_mode && stop_at_linux_plic && saw_linux_plic) begin
            $display("\nPERF MILESTONE name=linux-plic cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                     cycle_count, observed_minstret, uart_byte_count, dbg_pc);
            $finish;
        end
    end

    initial begin
        rst_n = 1'b0;
        images_staged_q = 1'b0;
        banner_index = 0;
        payload_index = 0;
        linux_panic_index = 0;
        linux_prompt_index = 0;
        linux_plic_index = 0;
        linux_memory_index = 0;
        linux_devtmpfs_index = 0;
        linux_uart_index = 0;
        linux_initmem_index = 0;
        linux_init_index = 0;
        cycle_count = 0;
        progress_last_cycle = 0;
        progress_last_instret = 0;
        uart_byte_count = 0;
        linux_trap_count = 0;
        linux_same_trap_count = 0;
        linux_ptw_trace_count = 0;
        previous_trap_cause = 0;
        previous_trap_tval = 0;
        saw_banner = 1'b0;
        saw_payload_text = 1'b0;
        saw_linux_panic = 1'b0;
        saw_linux_prompt = 1'b0;
        saw_linux_plic = 1'b0;
        saw_linux_memory = 1'b0;
        saw_linux_devtmpfs = 1'b0;
        saw_linux_uart = 1'b0;
        saw_linux_initmem = 1'b0;
        saw_linux_init = 1'b0;
        saw_s_mode = 1'b0;
        stop_at_linux_plic = $test$plusargs("stop_at_linux_plic");
        delay_probe_fired = 1'b0;
        panic_probe_fired = 1'b0;
        dbcn_probe_fired = 1'b0;
        printk_probe_seen = 12'd0;
        payload_words = PAYLOAD_WORDS;
        instruction_trace_fd = 0;
        lsu_trace_fd = 0;
        icx_trace_fd = 0;
        l1d_lock_trace_count = 0;
        perf_summary_enabled = $test$plusargs("perf_summary");
        for (perf_init_index = 0; perf_init_index < 5;
             perf_init_index = perf_init_index + 1) begin
            perf_issue_width[perf_init_index] = 0;
            if (perf_init_index < 4) begin
                perf_decode_width[perf_init_index] = 0;
                perf_retire_width[perf_init_index] = 0;
            end
        end
        {
            perf_cycles, perf_issued, perf_decoded, perf_retired,
            perf_frontend_empty, perf_frontend_held,
            perf_fetch_request_wait, perf_l1i_busy_cycles,
            perf_dispatch_nonempty, perf_dispatch_no_issue,
            perf_dispatch_full, perf_retire_nonempty,
            perf_retire_no_progress, perf_retire_head_incomplete,
            perf_retire_completed_behind,
            perf_retire_head_block_load,
            perf_retire_head_block_store,
            perf_retire_head_block_branch,
            perf_retire_head_block_barrier,
            perf_retire_head_block_alu,
            perf_lsu_request_wait,
            perf_barrier_cycles, perf_barrier_entries,
            perf_barrier_frontend_block_cycles,
            perf_fence_retired, perf_fence_rr, perf_fence_rw,
            perf_fence_wr, perf_fence_ww, perf_fence_io,
            perf_fence_i_retired, perf_sfence_vma_retired,
            perf_satp_writes, perf_translation_barrier_cycles,
            perf_store_barrier_cycles, perf_fence_with_posted_stores,
            perf_control_flushes,
            perf_branch_allocations, perf_branch_predictions_taken,
            perf_branch_resolutions, perf_conditional_branches,
            perf_branches_taken, perf_direction_mispredicts,
            perf_target_mispredicts, perf_bp_fetch_stall_cycles
        } = '0;
        perf_barrier_active_q = 1'b0;
        {
            perf_itlb_demand_lookups, perf_itlb_demand_hits,
            perf_itlb_demand_misses, perf_itlb_demand_faults,
            perf_itlb_prefetch_lookups, perf_itlb_prefetch_hits,
            perf_itlb_prefetch_misses, perf_itlb_prefetch_faults,
            perf_dtlb_pipe_lookups, perf_dtlb_pipe_hits,
            perf_dtlb_pipe_misses, perf_dtlb_pipe_faults,
            perf_dtlb_serial_lookups, perf_dtlb_serial_hits,
            perf_dtlb_serial_misses, perf_dtlb_serial_faults,
            perf_tlb_invalidates, perf_itlb_fills, perf_dtlb_fills,
            perf_l2_tlb_lookups, perf_l2_tlb_hits,
            perf_l2_tlb_misses, perf_l2_tlb_fills,
            perf_l2_tlb_evictions, perf_l2_tlb_superpage_bypasses,
            perf_ptw_lsu_starts, perf_ptw_fetch_starts,
            perf_ptw_prefetch_starts, perf_ptw_responses,
            perf_ptw_faults, perf_ptw_pte_cache_hits,
            perf_ptw_icx_reads, perf_ptw_active_cycles
        } = '0;
        {
            perf_l1i_demand_requests, perf_l1i_prefetch_requests,
            perf_l1i_demand_responses, perf_l1i_prefetch_responses,
            perf_l1i_line_misses, perf_l1i_line_responses,
            perf_l1d_load_requests, perf_l1d_store_requests,
            perf_l1d_load_wait_cycles, perf_l1d_store_wait_cycles,
            perf_l1d_misses, perf_l1d_mshr_allocations,
            perf_l1d_mshr_merges, perf_l1d_mshr_responses,
            perf_l1d_mshr_full_cycles, perf_l1d_mshr_max,
            perf_l1d_store_allocations, perf_l1d_store_merges,
            perf_l1d_store_responses, perf_l1d_store_full_cycles,
            perf_l1d_store_max, perf_l1d_prefetch_issued,
            perf_l1d_prefetch_useful,
            perf_l1d_prefetch_on_time_useful,
            perf_l1d_prefetch_late_useful,
            perf_l1d_prefetch_late,
            perf_l1d_prefetch_late_queued,
            perf_l1d_prefetch_late_command,
            perf_l1d_prefetch_late_mshr,
            perf_l1d_prefetch_dropped, perf_l1d_prefetch_useless,
            perf_l1d_prefetch_max_depth,
            perf_l1d_store_poison_any_events,
            perf_l1d_store_poison_prefetch_events,
            perf_l1d_store_poison_prefetch_queue,
            perf_l1d_store_poison_prefetch_command,
            perf_l1d_store_poison_prefetch_mshr,
            perf_l1d_store_poison_prefetch_fill,
            perf_l1d_store_poison_demand_events,
            perf_l1d_store_poison_demand_wait_prefetch,
            perf_l1d_store_poison_demand_fill,
            perf_l1d_store_overlay_demand_mshr
        } = '0;
        {
            perf_icx_requests, perf_icx_icache_reads,
            perf_icx_dcache_reads, perf_icx_dcache_writes,
            perf_icx_request_wait_cycles, perf_icx_wdata_wait_cycles,
            perf_icx_responses, perf_icx_response_wait_cycles,
            perf_l2_hits, perf_l2_merges, perf_l2_allocations,
            perf_l2_bypasses, perf_l2_write_arounds,
            perf_l2_victim_hits, perf_l2_lookup_stall_cycles,
            perf_l2_command_full_cycles, perf_l2_mshr_full_cycles,
            perf_l2_mshr_max, perf_l2_command_max,
            perf_l2_response_max, perf_l2_bus_track_max,
            perf_l2_bus_reads, perf_l2_bus_writes,
            perf_l2_bus_wait_cycles, perf_l2_bus_responses,
            perf_mem_wide_reads, perf_mem_wide_writes,
            perf_mem_wide_wait_cycles, perf_mem_scalar_reads,
            perf_mem_scalar_writes, perf_mem_scalar_wait_cycles
        } = '0;

        if ($value$plusargs("instruction_trace=%s",
                            instruction_trace_path)) begin
            instruction_trace_fd = $fopen(instruction_trace_path, "w");
            if (instruction_trace_fd == 0)
                $fatal(1, "failed to open instruction trace %s",
                       instruction_trace_path);
        end
        if ($value$plusargs("lsu_trace=%s", lsu_trace_path)) begin
            lsu_trace_fd = $fopen(lsu_trace_path, "w");
            if (lsu_trace_fd == 0)
                $fatal(1, "failed to open LSU trace %s", lsu_trace_path);
        end
        if ($value$plusargs("icx_trace=%s", icx_trace_path)) begin
            icx_trace_fd = $fopen(icx_trace_path, "w");
            if (icx_trace_fd == 0)
                $fatal(1, "failed to open ICX trace %s", icx_trace_path);
        end

        if (!$value$plusargs("payload_words=%d", payload_words))
            payload_words = PAYLOAD_WORDS;

        if (!$value$plusargs("trampoline_memh=%s", trampoline_memh) ||
            !$value$plusargs("firmware_memh=%s", firmware_memh) ||
            !$value$plusargs("payload_memh=%s", payload_memh) ||
            !$value$plusargs("fdt_memh=%s", fdt_memh)) begin
            $fatal(1, "missing OpenSBI memory-fragment plusargs");
        end

`ifndef OPENRV64_VERILATOR_CHECKPOINT
        #1;
        load_images();
        wait (memory_images_ready);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
`endif
    end

`ifndef OPENRV64_VERILATOR_CHECKPOINT
    initial begin
        linux_mode = $test$plusargs("linux_mode");
        delay_probe = $test$plusargs("delay_probe");
        panic_probe = $test$plusargs("panic_probe");
        dbcn_probe = $test$plusargs("dbcn_probe");
        printk_probe = $test$plusargs("printk_probe");
        if (linux_mode)
            payload_text = "Linux version";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100000000;

        repeat (max_cycles) @(posedge clk);
        report_timeout();
    end
`else
    reg verilator_images_loaded_q;
    reg [2:0] verilator_reset_edges_q;

    initial begin
        verilator_images_loaded_q = 1'b0;
        verilator_reset_edges_q = 3'd0;
        linux_mode = $test$plusargs("linux_mode");
        delay_probe = $test$plusargs("delay_probe");
        panic_probe = $test$plusargs("panic_probe");
        dbcn_probe = $test$plusargs("dbcn_probe");
        printk_probe = $test$plusargs("printk_probe");
        if (linux_mode)
            payload_text = "Linux version";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100000000;
    end

    always @(posedge clk) begin
        if (!verilator_images_loaded_q) begin
            load_images();
            verilator_images_loaded_q <= 1'b1;
        end else if (!rst_n && memory_images_ready) begin
            verilator_reset_edges_q <= verilator_reset_edges_q + 1'b1;
        end

        if (core_rst_n && (cycle_count >= max_cycles))
            report_timeout();
    end

    always @(negedge clk) begin
        if (memory_images_ready &&
            (verilator_reset_edges_q >= 3'd4))
            rst_n <= 1'b1;
    end
`endif

endmodule
