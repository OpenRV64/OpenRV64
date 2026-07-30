`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

/*
 * Four full three-pipe cores behind one coherent CCX home and shared L2.
 *
 * The normal four-hart workloads remain below the platform boundary and use a
 * bounded-latency 512-bit memory.  The OpenSBI modes additionally route L2
 * device bypasses to one shared CLINT, PLIC, and UART. +opensbi_held holds
 * harts 1-3 in reset; +opensbi_smp releases all four and checks that the
 * secondary harts retire the build-derived OpenSBI HSM WFI instruction.
 * Neither mode is a DDR timing test.
 *
 * Plusargs select the original private-root image, a shared Sv39 address
 * space, or a shared physical image running S-mode with satp Bare.
 * Shared-space workloads use mhartid-indexed private pages; the atomic
 * workload additionally contends on one common LR/SC word.  Those finite
 * workloads remain below the Linux/platform boundary.  The current coherence
 * home serializes global transactions in every mode.
 */
module tb_4h_3p #(
    parameter integer MEMORY_LATENCY = 8,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer L2_CACHE_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MSHRS = 8,
    parameter integer MEMORY_BYTES = 32'h0032_3000,
    parameter integer ENABLE_BOOT_ROM = 0,
    parameter logic [31:0] OPENSBI_FDT_BASE_LO = 32'h80f0_0000
);
    localparam integer NUM_HARTS = 4;
    localparam [63:0] PHYSICAL_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] VIRTUAL_BASE = 64'h0000_0000_4000_0000;
    localparam [63:0] PREFIX_STRIDE = 64'h0000_0000_0010_0000;
    localparam integer MEMORY_WORDS = MEMORY_BYTES / 64;
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
    localparam integer OPENSBI_TRAMPOLINE_WORDS = 32'h0001_0000 / 8;
    localparam integer OPENSBI_FIRMWARE_WORDS = 32'h0010_0000 / 8;
    localparam integer OPENSBI_PAYLOAD_WORDS = 32'h0001_0000 / 8;
    localparam integer OPENSBI_FDT_WORDS = 32'h0001_0000 / 8;

    logic clk;
    logic rst_n;
    wire [NUM_HARTS-1:0] hart_rst_n;
    wire [NUM_HARTS-1:0] clint_msip;
    wire [NUM_HARTS-1:0] clint_mtip;
    wire [NUM_HARTS-1:0] plic_seip;
    wire [63:0] clint_mtime;
    wire uart_irq;
    integer opensbi_held;
    integer opensbi_smp;
    integer opensbi_mode;
    logic [63:0] opensbi_hsm_wfi_pc;
    logic [NUM_HARTS-1:0] opensbi_hsm_wfi_seen;

    wire [NUM_HARTS-1:0] hart_req_valid;
    wire [NUM_HARTS-1:0] hart_req_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_req_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_req_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_req_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_OP_WIDTH-1:0] hart_req_op;
    wire [NUM_HARTS-1:0] hart_req_lock;
    wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0]
        hart_req_order;
    wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0]
        hart_req_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0]
        hart_req_attr;
    wire [NUM_HARTS*3-1:0] hart_req_size;
    wire [NUM_HARTS*64-1:0] hart_req_addr;
    wire [NUM_HARTS*`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        hart_req_burst_len;

    wire [NUM_HARTS-1:0] hart_wdata_valid;
    wire [NUM_HARTS-1:0] hart_wdata_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_wdata_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_wdata_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_wdata_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_wdata_beat_index;
    wire [NUM_HARTS-1:0] hart_wdata_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] hart_wdata;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] hart_wstrb;

    wire [NUM_HARTS-1:0] hart_resp_valid;
    wire [NUM_HARTS-1:0] hart_resp_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        hart_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        hart_resp_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        hart_resp_source_id;
    wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        hart_resp_beat_index;
    wire [NUM_HARTS-1:0] hart_resp_last;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        hart_resp_rdata;
    wire [NUM_HARTS-1:0] hart_resp_error;
    wire [NUM_HARTS-1:0] hart_resp_sc_success;

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;
    wire ccx_resp_valid;
    wire ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    wire ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_error;
    wire ccx_resp_sc_success;

    wire [NUM_HARTS-1:0] probe_valid;
    wire [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    wire [NUM_HARTS-1:0] probe_resp_valid;
    wire [NUM_HARTS-1:0] probe_resp_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_resp_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_RESP_WIDTH-1:0]
        probe_resp_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        probe_resp_data;
    wire [NUM_HARTS-1:0] probe_resp_error;
    wire [NUM_HARTS-1:0] l1d_invalidate_valid;
    wire [NUM_HARTS-1:0] l1d_invalidate_ready;
    wire [NUM_HARTS*64-1:0] l1d_invalidate_addr;
    wire [NUM_HARTS-1:0] coherent_reservation_clear;

    wire l2_req_valid;
    wire l2_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l2_req_op;
    wire l2_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l2_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l2_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l2_req_attr;
    wire [2:0] l2_req_size;
    wire [63:0] l2_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l2_req_burst_len;
    wire l2_wdata_valid;
    wire l2_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_wdata_beat_index;
    wire l2_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l2_wstrb;
    wire l2_resp_valid;
    wire l2_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l2_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l2_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l2_resp_beat_index;
    wire l2_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l2_resp_rdata;
    wire l2_resp_error;
    wire l2_resp_sc_success;

    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_req_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    logic bus_resp_valid;
    wire bus_resp_ready;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_resp_rdata;
    logic bus_resp_error;
    wire clint_selected;
    wire plic_selected;
    wire uart_selected;
    wire rom_selected;
    wire device_selected;
    wire [63:0] device_wdata;
    wire [7:0] device_wstrb;
    wire [63:0] clint_rdata;
    wire [63:0] plic_rdata;
    wire [63:0] uart_rdata;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] rom_rdata;
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

    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_WORDS-1];
    logic [63:0] image_words [0:OPENSBI_FIRMWARE_WORDS-1];
    logic memory_pending;
    logic memory_pending_write;
    logic [63:0] memory_pending_addr;
    integer memory_delay;
    integer memory_index;
    integer memory_byte;
    integer memory_reads;
    integer memory_writes;

    logic [63:0] done_pc;
    logic [63:0] mailbox_va;
    logic [63:0] result_va;
    logic [63:0] atomic_counter_va;
    logic [63:0] tlbi_reservation_va;
    logic [63:0] tlbi_target_va;
    logic [63:0] tlbi_old_pa;
    logic [63:0] tlbi_new_pa;
    logic done_pc_valid;
    logic mailbox_va_valid;
    logic result_va_valid;
    logic atomic_counter_va_valid;
    logic tlbi_reservation_va_valid;
    logic tlbi_target_va_valid;
    logic tlbi_old_pa_valid;
    logic tlbi_new_pa_valid;
    integer shared_satp;
    integer bare_mode;
    integer mailbox_stride;
    integer result_expected;
    integer atomic_expected;
    integer atomic_test;
    integer tlbi_test;
    integer atomic_debug;
    integer max_cycles;
    integer cycles;
    integer first_done_cycle;
    logic progress_before_first_done;

    logic done_seen [0:NUM_HARTS-1];
    logic mailbox_seen [0:NUM_HARTS-1];
    logic result_seen [0:NUM_HARTS-1];
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
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l2_write_hart;
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
    logic home_request_active;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] home_request_op;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] home_request_hart;
    logic protocol_error;
    logic probe_endpoint_protocol_error;
    logic opensbi_s_mode_seen;
    logic opensbi_banner_seen;
    logic opensbi_payload_seen;
    logic opensbi_magic_seen;
    integer opensbi_banner_index;
    integer opensbi_payload_index;
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
                rst_n &&
                ((opensbi_held == 0) || (reset_hart == 0));
        end
    endgenerate

    genvar hart;
    generate
        for (hart = 0; hart < NUM_HARTS; hart = hart + 1) begin : g_hart
            wire hart_done_retired =
                (u_core.backend_retire_arch[0] &&
                 (u_core.u_backend.queue_retire_result[
                      0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.backend_retire_arch[1] &&
                 (u_core.u_backend.queue_retire_result[
                      1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc)) ||
                (u_core.backend_retire_arch[2] &&
                 (u_core.u_backend.queue_retire_result[
                      2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                      RETIRE_RESULT_PC_LSB +: 64] == done_pc));

            openrv64_rv64_top_3p #(
                .RESET_VECTOR(
                    (ENABLE_BOOT_ROM != 0) ? ROM_BASE : PHYSICAL_BASE),
                .BUS_CONFIG(`OPENRV64_BUS_AXI),
                .HART_ID(`OPENRV64_CCX_HART_ID_WIDTH'(hart)),
                .ENABLE_RV64M(1),
                .ENABLE_ISSUE_WINDOW(1),
                .ENABLE_SPECULATION_WINDOW(1),
                .ENABLE_POSTED_STORES(1),
                .RETIRE_DEPTH(16),
                .PHYS_REG_COUNT(31),
                .ENABLE_L1I(1),
                .ENABLE_L1D(1),
                .ENABLE_L1D_COHERENCE_PROBES(1),
                .ENABLE_COHERENT_ATOMICS(1),
                .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
                .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
                .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
                .L1D_CACHEABLE_BASE(PHYSICAL_BASE),
                .L1D_CACHEABLE_SIZE(64'(MEMORY_BYTES))
            ) u_core (
                .clk(clk),
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
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
                .pair1024_resp_unpredicted_addr(64'd0),
                .pair1024_resp_unpredicted_data(
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
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
                .ccx_req_valid(hart_req_valid[hart]),
                .ccx_req_ready(hart_req_ready[hart]),
                .ccx_req_hart_id(
                    hart_req_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_req_txn_id(
                    hart_req_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_req_source_id(
                    hart_req_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_req_op(
                    hart_req_op[
                        hart*`OPENRV64_CCX_OP_WIDTH +:
                        `OPENRV64_CCX_OP_WIDTH]),
                .ccx_req_lock(hart_req_lock[hart]),
                .ccx_req_order(
                    hart_req_order[
                        hart*`OPENRV64_CCX_ORDER_WIDTH +:
                        `OPENRV64_CCX_ORDER_WIDTH]),
                .ccx_req_kind(
                    hart_req_kind[
                        hart*`OPENRV64_CCX_KIND_WIDTH +:
                        `OPENRV64_CCX_KIND_WIDTH]),
                .ccx_req_attr(
                    hart_req_attr[
                        hart*`OPENRV64_CCX_ATTR_WIDTH +:
                        `OPENRV64_CCX_ATTR_WIDTH]),
                .ccx_req_size(hart_req_size[hart*3 +: 3]),
                .ccx_req_addr(hart_req_addr[hart*64 +: 64]),
                .ccx_req_burst_len(
                    hart_req_burst_len[
                        hart*`OPENRV64_CCX_BURST_LEN_WIDTH +:
                        `OPENRV64_CCX_BURST_LEN_WIDTH]),
                .ccx_wdata_valid(hart_wdata_valid[hart]),
                .ccx_wdata_ready(hart_wdata_ready[hart]),
                .ccx_wdata_hart_id(
                    hart_wdata_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_wdata_txn_id(
                    hart_wdata_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_wdata_source_id(
                    hart_wdata_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_wdata_beat_index(
                    hart_wdata_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_wdata_last(hart_wdata_last[hart]),
                .ccx_wdata(
                    hart_wdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_wstrb(
                    hart_wstrb[
                        hart*`OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH]),
                .ccx_resp_valid(hart_resp_valid[hart]),
                .ccx_resp_ready(hart_resp_ready[hart]),
                .ccx_resp_hart_id(
                    hart_resp_hart_id[
                        hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                        `OPENRV64_CCX_HART_ID_WIDTH]),
                .ccx_resp_txn_id(
                    hart_resp_txn_id[
                        hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                        `OPENRV64_CCX_TXN_ID_WIDTH]),
                .ccx_resp_source_id(
                    hart_resp_source_id[
                        hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                        `OPENRV64_CCX_SOURCE_ID_WIDTH]),
                .ccx_resp_beat_index(
                    hart_resp_beat_index[
                        hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                        `OPENRV64_CCX_BEAT_INDEX_WIDTH]),
                .ccx_resp_last(hart_resp_last[hart]),
                .ccx_resp_rdata(
                    hart_resp_rdata[
                        hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                        `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .ccx_resp_error(hart_resp_error[hart]),
                .ccx_resp_sc_success(hart_resp_sc_success[hart]),
                .l1d_probe_valid_i(l1d_invalidate_valid[hart]),
                .l1d_probe_ready_o(l1d_invalidate_ready[hart]),
                .l1d_probe_addr_i(
                    l1d_invalidate_addr[hart*64 +: 64]),
                .coherent_reservation_clear_i(
                    coherent_reservation_clear[hart]),
                .irq_m_software(
                    (opensbi_mode || (tlbi_test != 0)) &&
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
                    tlbi_sfence_retired[hart] <= 0;
                end else begin
                    if ((atomic_debug != 0) && (cycles != 0) &&
                        ((cycles % 500) == 0))
                        $display(
                            "ATOMIC_HART_DEBUG cycle=%0d hart=%0d active=%b irrev=%b inflight=%b engine_state=%0d engine_op=%0d atomic_addr=%h local_res=%b l1_backend=%0d l1_array=%0d l1_res_req=%b l1_res_done=%b l1_req=%b/%b home_state=%0d home_active=%b home_op=%0d home_addr=%h home_src=%0d home_hart=%0d probe_target=%b mask=%b issue=%b ack=%b lane_vr=%b/%b resp_vr=%b/%b inv_vr=%b/%b l2_cmd=%0d l2_rsp=%0d l2_mshr=%b:%0d,%b:%0d bus=%b/%b/%b/%b mem=%b:%0d",
                            cycles, hart,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.active_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.irrevocable_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.req_inflight_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.state_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.op_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.addr_q,
                            u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_atomics.u_engine.reservation_valid_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.backend_state_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.u_l1d.u_l1.
                                g_cache.u_cache.state_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.request_reservation_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.coherent_lr_reservation_done_q,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.req_valid_i,
                            u_core.u_bus.g_ccx.u_bus.u_l1d.req_ready_o,
                            u_coherence_home.state_q,
                            home_request_active, home_request_op,
                            u_coherence_home.req_addr_q,
                            u_coherence_home.req_source_id_q,
                            u_coherence_home.req_hart_id_q,
                            u_coherence_home.probe_target_q,
                            u_coherence_home.probe_cache_mask_q,
                            u_coherence_home.u_probe_tracker.issue_pending_q,
                            u_coherence_home.u_probe_tracker.ack_pending_q,
                            probe_valid, probe_ready,
                            probe_resp_valid, probe_resp_ready,
                            l1d_invalidate_valid, l1d_invalidate_ready,
                            u_l2.cmd_count_q, u_l2.response_count_q,
                            u_l2.mshr_valid_q[0],
                            u_l2.mshr_state_q[0],
                            u_l2.mshr_valid_q[1],
                            u_l2.mshr_state_q[1],
                            bus_req_valid, bus_req_ready,
                            bus_resp_valid, bus_resp_ready,
                            memory_pending, memory_delay);
                    retired[hart] <= retired[hart] +
                        u_core.backend_retire_arch[0] +
                        u_core.backend_retire_arch[1] +
                        u_core.backend_retire_arch[2];
                    if ((tlbi_test != 0) &&
                        u_core.backend_sfence_vma)
                        tlbi_sfence_retired[hart] <=
                            tlbi_sfence_retired[hart] + 1;
                    if ((opensbi_smp != 0) && (hart != 0) &&
                        (|u_core.backend_retire_arch) &&
                        (u_core.backend_retire_pc ==
                         opensbi_hsm_wfi_pc) &&
                        (u_core.backend_retire_instr ==
                         `RV64_INSTR_WFI))
                        opensbi_hsm_wfi_seen[hart] <= 1'b1;
                    if (u_core.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq.
                        store_alloc_fire)
                        store_allocations[hart] <=
                            store_allocations[hart] + 1;
                    if (u_core.u_bus.g_ccx.u_bus.pipe_fast_request_fire &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_write_i)
                        fast_store_requests[hart] <=
                            fast_store_requests[hart] + 1;
                    if (u_core.u_bus.g_ccx.u_bus.pipe_fallback_candidate &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_ready_o &&
                        u_core.u_bus.g_ccx.u_bus.lsu_pipe_req_write_i)
                        fallback_store_requests[hart] <=
                            fallback_store_requests[hart] + 1;
                    if (hart_req_valid[hart] &&
                        hart_req_ready[hart]) begin
                        requests[hart] <= requests[hart] + 1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_CCX_SOURCE_ID_WIDTH] ==
                             `OPENRV64_CCX_SOURCE_PTW) &&
                            ((hart_req_addr[hart*64 +: 64] &
                              64'hffff_ffff_ffff_ffc0) ==
                             hart_root_pa(hart)))
                            root_seen[hart] <= 1'b1;
                        if ((hart_req_source_id[
                                 hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                                 `OPENRV64_CCX_SOURCE_ID_WIDTH] ==
                            `OPENRV64_CCX_SOURCE_ICACHE) &&
                            (hart_req_addr[hart*64 +: 64] >=
                             hart_image_base(hart) + 64'h1000) &&
                            (hart_req_addr[hart*64 +: 64] <
                             hart_image_base(hart) + 64'h20000))
                            supervisor_fetch_seen[hart] <= 1'b1;
                    end
                    if ((bare_mode != 0) &&
                        (u_core.csr_priv_mode == `RV64_PRIV_S) &&
                        (u_core.csr_satp_mode ==
                         `RV64_SATP_MODE_BARE))
                        satp_seen[hart] <= 1'b1;
                    else if ((u_core.csr_priv_mode == `RV64_PRIV_S) &&
                             (u_core.csr_satp_mode ==
                              `RV64_SATP_MODE_SV39)) begin
                        if ((u_core.csr_satp_root_ppn !=
                             (hart_root_pa(hart) >> 12)) ||
                            (u_core.csr_satp_asid != 0))
                            $fatal(1,
                                "hart %0d wrong SATP mode=%0d asid=%0d ppn=%h expected=%h",
                                hart, u_core.csr_satp_mode,
                                u_core.csr_satp_asid,
                                u_core.csr_satp_root_ppn,
                                (hart_root_pa(hart) >> 12));
                        satp_seen[hart] <= 1'b1;
                    end
                    if (done_pc_valid && hart_done_retired &&
                        !done_seen[hart]) begin
                        done_seen[hart] <= 1'b1;
                        done_cycle[hart] <= cycles;
                    end
                end
            end
        end
    endgenerate

    openrv64_ccx_line_crossbar #(
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
        .mem_req_valid_o(ccx_req_valid),
        .mem_req_ready_i(ccx_req_ready),
        .mem_req_hart_id_o(ccx_req_hart_id),
        .mem_req_txn_id_o(ccx_req_txn_id),
        .mem_req_source_id_o(ccx_req_source_id),
        .mem_req_op_o(ccx_req_op),
        .mem_req_lock_o(ccx_req_lock),
        .mem_req_order_o(ccx_req_order),
        .mem_req_kind_o(ccx_req_kind),
        .mem_req_attr_o(ccx_req_attr),
        .mem_req_size_o(ccx_req_size),
        .mem_req_addr_o(ccx_req_addr),
        .mem_req_burst_len_o(ccx_req_burst_len),
        .hart_wdata_valid_i(hart_wdata_valid),
        .hart_wdata_ready_o(hart_wdata_ready),
        .hart_wdata_hart_id_i(hart_wdata_hart_id),
        .hart_wdata_txn_id_i(hart_wdata_txn_id),
        .hart_wdata_source_id_i(hart_wdata_source_id),
        .hart_wdata_beat_index_i(hart_wdata_beat_index),
        .hart_wdata_last_i(hart_wdata_last),
        .hart_wdata_i(hart_wdata),
        .hart_wstrb_i(hart_wstrb),
        .mem_wdata_valid_o(ccx_wdata_valid),
        .mem_wdata_ready_i(ccx_wdata_ready),
        .mem_wdata_hart_id_o(ccx_wdata_hart_id),
        .mem_wdata_txn_id_o(ccx_wdata_txn_id),
        .mem_wdata_source_id_o(ccx_wdata_source_id),
        .mem_wdata_beat_index_o(ccx_wdata_beat_index),
        .mem_wdata_last_o(ccx_wdata_last),
        .mem_wdata_o(ccx_wdata),
        .mem_wstrb_o(ccx_wstrb),
        .mem_resp_valid_i(ccx_resp_valid),
        .mem_resp_ready_o(ccx_resp_ready),
        .mem_resp_hart_id_i(ccx_resp_hart_id),
        .mem_resp_txn_id_i(ccx_resp_txn_id),
        .mem_resp_source_id_i(ccx_resp_source_id),
        .mem_resp_beat_index_i(ccx_resp_beat_index),
        .mem_resp_last_i(ccx_resp_last),
        .mem_resp_rdata_i(ccx_resp_rdata),
        .mem_resp_error_i(ccx_resp_error),
        .mem_resp_sc_success_i(ccx_resp_sc_success),
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

    openrv64_ccx_coherent_protocol #(
        .NUM_HARTS(NUM_HARTS),
        .HART_ID_BASE(0),
        .DIRECTORY_ENTRIES(1024),
        .DIRECTORY_WAYS(4)
    ) u_coherence_home (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(ccx_req_valid),
        .req_ready_o(ccx_req_ready),
        .req_hart_id_i(ccx_req_hart_id),
        .req_txn_id_i(ccx_req_txn_id),
        .req_source_id_i(ccx_req_source_id),
        .req_op_i(ccx_req_op),
        .req_lock_i(ccx_req_lock),
        .req_order_i(ccx_req_order),
        .req_kind_i(ccx_req_kind),
        .req_attr_i(ccx_req_attr),
        .req_size_i(ccx_req_size),
        .req_addr_i(ccx_req_addr),
        .req_burst_len_i(ccx_req_burst_len),
        .wdata_valid_i(ccx_wdata_valid),
        .wdata_ready_o(ccx_wdata_ready),
        .wdata_hart_id_i(ccx_wdata_hart_id),
        .wdata_txn_id_i(ccx_wdata_txn_id),
        .wdata_source_id_i(ccx_wdata_source_id),
        .wdata_beat_index_i(ccx_wdata_beat_index),
        .wdata_last_i(ccx_wdata_last),
        .wdata_i(ccx_wdata),
        .wstrb_i(ccx_wstrb),
        .resp_valid_o(ccx_resp_valid),
        .resp_ready_i(ccx_resp_ready),
        .resp_hart_id_o(ccx_resp_hart_id),
        .resp_txn_id_o(ccx_resp_txn_id),
        .resp_source_id_o(ccx_resp_source_id),
        .resp_beat_index_o(ccx_resp_beat_index),
        .resp_last_o(ccx_resp_last),
        .resp_rdata_o(ccx_resp_rdata),
        .resp_error_o(ccx_resp_error),
        .resp_sc_success_o(ccx_resp_sc_success),
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
        .l2_req_valid_o(l2_req_valid),
        .l2_req_ready_i(l2_req_ready),
        .l2_req_hart_id_o(l2_req_hart_id),
        .l2_req_txn_id_o(l2_req_txn_id),
        .l2_req_source_id_o(l2_req_source_id),
        .l2_req_op_o(l2_req_op),
        .l2_req_lock_o(l2_req_lock),
        .l2_req_order_o(l2_req_order),
        .l2_req_kind_o(l2_req_kind),
        .l2_req_attr_o(l2_req_attr),
        .l2_req_size_o(l2_req_size),
        .l2_req_addr_o(l2_req_addr),
        .l2_req_burst_len_o(l2_req_burst_len),
        .l2_wdata_valid_o(l2_wdata_valid),
        .l2_wdata_ready_i(l2_wdata_ready),
        .l2_wdata_hart_id_o(l2_wdata_hart_id),
        .l2_wdata_txn_id_o(l2_wdata_txn_id),
        .l2_wdata_source_id_o(l2_wdata_source_id),
        .l2_wdata_beat_index_o(l2_wdata_beat_index),
        .l2_wdata_last_o(l2_wdata_last),
        .l2_wdata_o(l2_wdata),
        .l2_wstrb_o(l2_wstrb),
        .l2_resp_valid_i(l2_resp_valid),
        .l2_resp_ready_o(l2_resp_ready),
        .l2_resp_hart_id_i(l2_resp_hart_id),
        .l2_resp_txn_id_i(l2_resp_txn_id),
        .l2_resp_source_id_i(l2_resp_source_id),
        .l2_resp_beat_index_i(l2_resp_beat_index),
        .l2_resp_last_i(l2_resp_last),
        .l2_resp_rdata_i(l2_resp_rdata),
        .l2_resp_error_i(l2_resp_error),
        .l2_resp_sc_success_i(l2_resp_sc_success),
        .protocol_error_clear_i(1'b0),
        .protocol_error_o(protocol_error)
    );

    openrv64_ccx_l2_native #(
        .CACHE_BYTES(L2_CACHE_BYTES),
        .LINE_BYTES(64),
        .WAYS(L2_WAYS),
        .MSHR_ENTRIES(L2_MSHRS),
        .WAITERS_PER_MSHR(8),
        .COMMAND_ENTRIES(16),
        .RESPONSE_ENTRIES(16),
        .BUS_TRACK_ENTRIES(L2_MSHRS)
    ) u_l2 (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l2_req_valid),
        .req_ready_o(l2_req_ready),
        .req_hart_id_i(l2_req_hart_id),
        .req_txn_id_i(l2_req_txn_id),
        .req_source_id_i(l2_req_source_id),
        .req_op_i(l2_req_op),
        .req_lock_i(l2_req_lock),
        .req_order_i(l2_req_order),
        .req_kind_i(l2_req_kind),
        .req_attr_i(l2_req_attr),
        .req_size_i(l2_req_size),
        .req_addr_i(l2_req_addr),
        .req_burst_len_i(l2_req_burst_len),
        .wdata_valid_i(l2_wdata_valid),
        .wdata_ready_o(l2_wdata_ready),
        .wdata_hart_id_i(l2_wdata_hart_id),
        .wdata_txn_id_i(l2_wdata_txn_id),
        .wdata_source_id_i(l2_wdata_source_id),
        .wdata_beat_index_i(l2_wdata_beat_index),
        .wdata_last_i(l2_wdata_last),
        .wdata_i(l2_wdata),
        .wstrb_i(l2_wstrb),
        .resp_valid_o(l2_resp_valid),
        .resp_ready_i(l2_resp_ready),
        .resp_hart_id_o(l2_resp_hart_id),
        .resp_txn_id_o(l2_resp_txn_id),
        .resp_source_id_o(l2_resp_source_id),
        .resp_beat_index_o(l2_resp_beat_index),
        .resp_last_o(l2_resp_last),
        .resp_rdata_o(l2_resp_rdata),
        .resp_error_o(l2_resp_error),
        .resp_sc_success_o(l2_resp_sc_success),
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

    openrv64_ccx_4h_l1d_probe_cluster #(
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

    assign rom_selected =
        opensbi_mode && (ENABLE_BOOT_ROM != 0) &&
        (bus_req_addr >= ROM_BASE) &&
        (bus_req_addr < ROM_BASE + ROM_SIZE);
    assign clint_selected =
        (opensbi_mode || (tlbi_test != 0)) && !bus_req_cacheable &&
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

    assign bus_req_ready = !memory_pending && !bus_resp_valid;

    /*
     * The coherent home is globally blocking, so one accepted request owns
     * the response channel until completion.  Count architected LR/SC traffic
     * and distinguish failed SC responses from writes that reached L2.
     */
    integer atomic_hart;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            home_request_active <= 1'b0;
            home_request_op <= `OPENRV64_CCX_OP_READ;
            home_request_hart <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                lr_requests[atomic_hart] <= 0;
                sc_requests[atomic_hart] <= 0;
                sc_successes[atomic_hart] <= 0;
                sc_failures[atomic_hart] <= 0;
                atomic_line_probes[atomic_hart] <= 0;
                reservation_clears[atomic_hart] <= 0;
                tlbi_pte_fences[atomic_hart] <= 0;
                tlbi_old_reads[atomic_hart] <= 0;
                tlbi_new_reads[atomic_hart] <= 0;
                tlbi_reservation_probes[atomic_hart] <= 0;
            end
        end else begin
            for (atomic_hart = 0;
                 atomic_hart < NUM_HARTS;
                 atomic_hart = atomic_hart + 1) begin
                if (coherent_reservation_clear[atomic_hart])
                    reservation_clears[atomic_hart] <=
                        reservation_clears[atomic_hart] + 1;
                if ((atomic_test != 0) &&
                    atomic_counter_va_valid &&
                    probe_valid[atomic_hart] &&
                    probe_ready[atomic_hart] &&
                    (probe_command[
                         atomic_hart*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                         `OPENRV64_CCX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_CCX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_CCX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_CCX_PROBE_CACHE_D)) &&
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
                         atomic_hart*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                         `OPENRV64_CCX_PROBE_CMD_WIDTH] ==
                     `OPENRV64_CCX_PROBE_INV) &&
                    (|(probe_cache_mask[
                          atomic_hart*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                          `OPENRV64_CCX_PROBE_CACHE_WIDTH] &
                       `OPENRV64_CCX_PROBE_CACHE_D)) &&
                    (probe_line_addr[atomic_hart*64 +: 64] ==
                     (tlbi_reservation_pa() &
                      64'hffff_ffff_ffff_ffc0)))
                    tlbi_reservation_probes[atomic_hart] <=
                        tlbi_reservation_probes[atomic_hart] + 1;
            end
            if (ccx_req_valid && ccx_req_ready) begin
                if (home_request_active)
                    $fatal(1,
                        "coherence home accepted overlapping requests");
                home_request_active <= 1'b1;
                home_request_op <= ccx_req_op;
                home_request_hart <= ccx_req_hart_id;
                if (ccx_req_op == `OPENRV64_CCX_OP_LR)
                    lr_requests[ccx_req_hart_id] <=
                        lr_requests[ccx_req_hart_id] + 1;
                if (ccx_req_op == `OPENRV64_CCX_OP_SC)
                    sc_requests[ccx_req_hart_id] <=
                        sc_requests[ccx_req_hart_id] + 1;
                if ((tlbi_test != 0) &&
                    (ccx_req_hart_id < NUM_HARTS)) begin
                    if ((ccx_req_source_id ==
                         `OPENRV64_CCX_SOURCE_PTW) &&
                        (ccx_req_op == `OPENRV64_CCX_OP_FENCE))
                        tlbi_pte_fences[ccx_req_hart_id] <=
                            tlbi_pte_fences[ccx_req_hart_id] + 1;
                    if ((ccx_req_source_id ==
                         `OPENRV64_CCX_SOURCE_DCACHE) &&
                        ((ccx_req_op == `OPENRV64_CCX_OP_READ) ||
                         (ccx_req_op == `OPENRV64_CCX_OP_LR))) begin
                        if ((ccx_req_addr &
                             64'hffff_ffff_ffff_ffc0) ==
                            (tlbi_old_pa &
                             64'hffff_ffff_ffff_ffc0))
                            tlbi_old_reads[ccx_req_hart_id] <=
                                tlbi_old_reads[ccx_req_hart_id] + 1;
                        if ((ccx_req_addr &
                             64'hffff_ffff_ffff_ffc0) ==
                            (tlbi_new_pa &
                             64'hffff_ffff_ffff_ffc0))
                            tlbi_new_reads[ccx_req_hart_id] <=
                                tlbi_new_reads[ccx_req_hart_id] + 1;
                    end
                end
            end

            if (ccx_resp_valid && ccx_resp_ready) begin
                if (!home_request_active)
                    $fatal(1,
                        "coherence home produced response without request");
                if (ccx_resp_hart_id != home_request_hart)
                    $fatal(1,
                        "coherence home response changed hart request=%0d response=%0d",
                        home_request_hart, ccx_resp_hart_id);
                if (home_request_op == `OPENRV64_CCX_OP_SC) begin
                    if (ccx_resp_sc_success)
                        sc_successes[home_request_hart] <=
                            sc_successes[home_request_hart] + 1;
                    else
                        sc_failures[home_request_hart] <=
                            sc_failures[home_request_hart] + 1;
                end
                home_request_active <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memory_pending <= 1'b0;
            memory_pending_write <= 1'b0;
            memory_pending_addr <= 64'd0;
            memory_delay <= 0;
            bus_resp_valid <= 1'b0;
            bus_resp_rdata <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            bus_resp_error <= 1'b0;
            memory_reads <= 0;
            memory_writes <= 0;
        end else begin
            if (bus_resp_valid && bus_resp_ready)
                bus_resp_valid <= 1'b0;

            if (bus_req_valid && bus_req_ready) begin
                    bus_resp_error <= 1'b0;
                if (device_selected) begin
                    bus_resp_valid <= 1'b1;
                    if (rom_selected) begin
                        if ((bus_req_size != 3'd6) ||
                            (bus_req_addr[5:0] != 6'd0))
                            $fatal(1,
                                "malformed ROM line request addr=%h size=%0d",
                                bus_req_addr, bus_req_size);
                        bus_resp_rdata <= rom_rdata;
                    end
                    else if (clint_selected)
                        bus_resp_rdata <=
                            {448'd0, clint_rdata} <<
                            (bus_req_addr[5:3] * 64);
                    else if (plic_selected)
                        bus_resp_rdata <=
                            {448'd0, plic_rdata} <<
                            (bus_req_addr[5:3] * 64);
                    else
                        bus_resp_rdata <=
                            {448'd0, uart_rdata} <<
                            (bus_req_addr[5:3] * 64);
                end else begin
                    if ((bus_req_size != 3'd6) ||
                        (bus_req_addr[5:0] != 6'd0) ||
                        !bus_req_cacheable ||
                        (bus_req_addr < PHYSICAL_BASE) ||
                        (bus_req_addr >= PHYSICAL_BASE + MEMORY_BYTES))
                        $fatal(1,
                            "malformed/out-of-range L2 request addr=%h size=%0d cacheable=%0b",
                            bus_req_addr, bus_req_size,
                            bus_req_cacheable);
                    memory_pending <= 1'b1;
                    memory_pending_write <= bus_req_write;
                    memory_pending_addr <= bus_req_addr;
                    memory_delay <= MEMORY_LATENCY - 1;
                    if (bus_req_write) begin
                        memory_writes <= memory_writes + 1;
                        for (memory_byte = 0;
                             memory_byte <
                                 `OPENRV64_CCX_LINE_STRB_WIDTH;
                             memory_byte = memory_byte + 1)
                            if (bus_req_wstrb[memory_byte])
                                memory[memory_line(bus_req_addr)][
                                    memory_byte*8 +: 8] <=
                                    bus_req_wdata[memory_byte*8 +: 8];
                    end else begin
                        memory_reads <= memory_reads + 1;
                    end
                end
            end else if (memory_pending) begin
                if (memory_delay == 0) begin
                    memory_pending <= 1'b0;
                    bus_resp_valid <= 1'b1;
                    bus_resp_error <= 1'b0;
                    bus_resp_rdata <= memory_pending_write ?
                        {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}} :
                        memory[memory_line(memory_pending_addr)];
                end else begin
                    memory_delay <= memory_delay - 1;
                end
            end
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
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] observed_write_hart;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_write_active <= 1'b0;
            l2_write_addr <= 64'd0;
            l2_write_hart <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            atomic_last_value <= 0;
            atomic_final_seen <= 1'b0;
            opensbi_magic_seen <= 1'b0;
            for (mailbox_hart = 0;
                 mailbox_hart < NUM_HARTS;
                 mailbox_hart = mailbox_hart + 1) begin
                mailbox_seen[mailbox_hart] <= 1'b0;
                result_seen[mailbox_hart] <= 1'b0;
                atomic_l2_successes[mailbox_hart] <= 0;
            end
        end else begin
            if (l2_req_valid && l2_req_ready &&
                (l2_req_op == `OPENRV64_CCX_OP_WRITE)) begin
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
                      (l2_req_op == `OPENRV64_CCX_OP_WRITE)))
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

                for (mailbox_hart = 0;
                     mailbox_hart < NUM_HARTS;
                     mailbox_hart = mailbox_hart + 1) begin
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

    always #5 clk = ~clk;

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
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        opensbi_held = $test$plusargs("opensbi_held");
        opensbi_smp = $test$plusargs("opensbi_smp");
        opensbi_mode =
            (opensbi_held != 0) || (opensbi_smp != 0);
        opensbi_hsm_wfi_pc = 64'd0;
        done_pc = 64'd0;
        mailbox_va = 64'd0;
        result_va = 64'd0;
        atomic_counter_va = 64'd0;
        tlbi_reservation_va = 64'd0;
        tlbi_target_va = 64'd0;
        tlbi_old_pa = 64'd0;
        tlbi_new_pa = 64'd0;
        done_pc_valid = 1'b0;
        mailbox_va_valid = 1'b0;
        result_va_valid = 1'b0;
        atomic_counter_va_valid = 1'b0;
        tlbi_reservation_va_valid = 1'b0;
        tlbi_target_va_valid = 1'b0;
        tlbi_old_pa_valid = 1'b0;
        tlbi_new_pa_valid = 1'b0;
        shared_satp = 0;
        bare_mode = 0;
        mailbox_stride = 0;
        result_expected = 0;
        atomic_expected = 0;
        atomic_test = 0;
        tlbi_test = 0;
        atomic_debug = 0;
        max_cycles = 800000;
        cycles = 0;
        first_done_cycle = -1;
        progress_before_first_done = 1'b0;
        opensbi_s_mode_seen = 1'b0;
        opensbi_banner_seen = 1'b0;
        opensbi_payload_seen = 1'b0;
        opensbi_banner_index = 0;
        opensbi_payload_index = 0;
        opensbi_uart_bytes = 0;
        opensbi_trace_write = 0;
        opensbi_trace_count = 0;
        opensbi_hang_cycles = 0;

        for (memory_index = 0;
             memory_index < MEMORY_WORDS;
             memory_index = memory_index + 1)
            memory[memory_index] =
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};

        if (opensbi_mode) begin
            if ((opensbi_held != 0) && (opensbi_smp != 0))
                $fatal(1,
                    "+opensbi_held and +opensbi_smp are mutually exclusive");
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
            load_image_fragment(
                payload_memh_path,
                PHYSICAL_BASE + 64'h0020_0000,
                OPENSBI_PAYLOAD_WORDS);
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
                    "OpenSBI 4H held-reset load complete ROM=%h FDT=%h memory_bytes=%0d",
                    ROM_BASE, OPENSBI_FDT_BASE, MEMORY_BYTES);
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
        void'($value$plusargs("atomic_expected=%d", atomic_expected));
        void'($value$plusargs("atomic_test=%d", atomic_test));
        void'($value$plusargs("tlbi_test=%d", tlbi_test));
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
        if (!opensbi_mode && (atomic_test != 0) && (tlbi_test != 0))
            $fatal(1, "+atomic_test and +tlbi_test are mutually exclusive");
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

        repeat (12) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;

            if (opensbi_mode) begin
                if ((|g_hart[0].u_core.backend_retire_arch) ||
                    g_hart[0].u_core.backend_exception) begin
                    opensbi_trace_pc[opensbi_trace_write] <=
                        g_hart[0].u_core.backend_retire_pc;
                    opensbi_trace_instr[opensbi_trace_write] <=
                        g_hart[0].u_core.backend_retire_instr;
                    opensbi_trace_cause[opensbi_trace_write] <=
                        g_hart[0].u_core.backend_cause;
                    opensbi_trace_exception[opensbi_trace_write] <=
                        g_hart[0].u_core.backend_exception;
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
                        g_hart[0].u_core.u_csrs.mcause_q,
                        g_hart[0].u_core.u_csrs.mtval_q,
                        g_hart[0].u_core.u_csrs.mepc_q,
                        g_hart[0].u_core.u_csrs.mstatus_q,
                        g_hart[0].u_core.csr_priv_mode);
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

                if (g_hart[0].u_core.csr_priv_mode ==
                    `RV64_PRIV_S)
                    opensbi_s_mode_seen <= 1'b1;

                if (u_uart.write_thr) begin
                    opensbi_uart_bytes <=
                        opensbi_uart_bytes + 1;
                    $write("%c", device_wdata[7:0]);
                    $fflush();
                    match_opensbi_byte(device_wdata[7:0]);
                end

                if ((opensbi_held != 0) &&
                    ((|hart_req_valid[NUM_HARTS-1:1]) ||
                     (|hart_wdata_valid[NUM_HARTS-1:1])))
                    $fatal(1,
                        "held hart emitted CCX traffic req=%b wdata=%b",
                        hart_req_valid, hart_wdata_valid);

                if ((cycles != 0) &&
                    ((cycles % 1000000) == 0)) begin
                    $display(
                        "OPENSBI_4H_PROGRESS cycles=%0d pc=%016h,%016h,%016h,%016h priv=%0d,%0d,%0d,%0d hsm_wfi=%b sleep=%b banner=%0b payload=%0b magic=%0b uart_bytes=%0d",
                        cycles,
                        dbg_pc[0*64 +: 64],
                        dbg_pc[1*64 +: 64],
                        dbg_pc[2*64 +: 64],
                        dbg_pc[3*64 +: 64],
                        g_hart[0].u_core.csr_priv_mode,
                        g_hart[1].u_core.csr_priv_mode,
                        g_hart[2].u_core.csr_priv_mode,
                        g_hart[3].u_core.csr_priv_mode,
                        opensbi_hsm_wfi_seen,
                        hart_wfi_sleep,
                        opensbi_banner_seen,
                        opensbi_payload_seen,
                        opensbi_magic_seen,
                        opensbi_uart_bytes);
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

            if (protocol_error || probe_endpoint_protocol_error)
                $fatal(1,
                    "coherence protocol error home=%0b endpoint=%0b",
                    protocol_error, probe_endpoint_protocol_error);
            if (((opensbi_held != 0) && dbg_halted[0]) ||
                ((opensbi_held == 0) && (|dbg_halted)))
                $fatal(1,
                    "hart halted mask=%b pc=%h instr=%h",
                    dbg_halted, dbg_pc, dbg_instr);

            if (!opensbi_mode &&
                (first_done_cycle < 0) &&
                (done_seen[0] || done_seen[1] ||
                 done_seen[2] || done_seen[3])) begin
                first_done_cycle <= cycles;
                progress_before_first_done <=
                    (retired[0] > 0) && (retired[1] > 0) &&
                    (retired[2] > 0) && (retired[3] > 0);
            end

            if (!opensbi_mode &&
                done_seen[0] && done_seen[1] &&
                done_seen[2] && done_seen[3] &&
                mailbox_seen[0] && mailbox_seen[1] &&
                mailbox_seen[2] && mailbox_seen[3] &&
                (!result_va_valid ||
                 (result_seen[0] && result_seen[1] &&
                  result_seen[2] && result_seen[3])) &&
                ((atomic_test == 0) || atomic_final_seen)) begin
                if (!progress_before_first_done)
                    $fatal(1,
                        "a hart completed before all four made retirement progress");
                for (init_hart = 0;
                     init_hart < NUM_HARTS;
                     init_hart = init_hart + 1) begin
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
                    "  retired=%0d,%0d,%0d,%0d ccx_req=%0d,%0d,%0d,%0d",
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

            if ((opensbi_held != 0) &&
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
                $display(
                    "\nPASS: 4H coherent OpenSBI v1.9 on hart 0 with harts 1-3 held in reset; ROM handoff, banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
                $display(
                    "  cycles=%0d hart0_retired=%0d hart0_ccx_req=%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles, retired[0], requests[0],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
                $finish;
            end

            if ((opensbi_smp != 0) &&
                opensbi_banner_seen &&
                opensbi_payload_seen &&
                opensbi_s_mode_seen &&
                opensbi_magic_seen &&
                (&opensbi_hsm_wfi_seen[NUM_HARTS-1:1]) &&
                (&hart_wfi_sleep[NUM_HARTS-1:1])) begin
                if ((g_hart[1].u_core.csr_priv_mode !=
                     `RV64_PRIV_M) ||
                    (g_hart[2].u_core.csr_priv_mode !=
                     `RV64_PRIV_M) ||
                    (g_hart[3].u_core.csr_priv_mode !=
                     `RV64_PRIV_M))
                    $fatal(1,
                        "secondary hart left M-mode priv=%0d,%0d,%0d",
                        g_hart[1].u_core.csr_priv_mode,
                        g_hart[2].u_core.csr_priv_mode,
                        g_hart[3].u_core.csr_priv_mode);
                $display(
                    "\nPASS: 4H coherent OpenSBI v1.9; hart 0 completed the S-mode payload and harts 1-3 sleep at HSM WFI %016h",
                    opensbi_hsm_wfi_pc);
                $display(
                    "  cycles=%0d retired=%0d,%0d,%0d,%0d ccx_req=%0d,%0d,%0d,%0d uart_bytes=%0d memory_reads=%0d memory_writes=%0d",
                    cycles,
                    retired[0], retired[1],
                    retired[2], retired[3],
                    requests[0], requests[1],
                    requests[2], requests[3],
                    opensbi_uart_bytes, memory_reads,
                    memory_writes);
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
                    u_coherence_home.state_q);
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
                    g_hart[0].u_core.csr_priv_mode,
                    g_hart[1].u_core.csr_priv_mode,
                    g_hart[2].u_core.csr_priv_mode,
                    g_hart[3].u_core.csr_priv_mode,
                    u_coherence_home.state_q);
            if (cycles >= max_cycles) begin
                if (opensbi_mode)
                    $fatal(1,
                        "OpenSBI 4H timeout cycles=%0d pc=%h instr=%h priv=%0d,%0d,%0d,%0d hsm_wfi=%b banner=%0b payload=%0b s_mode=%0b magic=%0b req=%0d,%0d,%0d,%0d",
                        cycles, dbg_pc, dbg_instr,
                        g_hart[0].u_core.csr_priv_mode,
                        g_hart[1].u_core.csr_priv_mode,
                        g_hart[2].u_core.csr_priv_mode,
                        g_hart[3].u_core.csr_priv_mode,
                        opensbi_hsm_wfi_seen,
                        opensbi_banner_seen,
                        opensbi_payload_seen,
                        opensbi_s_mode_seen,
                        opensbi_magic_seen,
                        requests[0], requests[1],
                        requests[2], requests[3]);
                else
                    $fatal(1,
                        "timeout cycles=%0d done=%0b%0b%0b%0b mailbox=%0b%0b%0b%0b pc=%h",
                        cycles, done_seen[3], done_seen[2],
                        done_seen[1], done_seen[0],
                        mailbox_seen[3], mailbox_seen[2],
                        mailbox_seen[1], mailbox_seen[0], dbg_pc);
            end
        end
    end

endmodule
