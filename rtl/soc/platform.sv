`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "core/exec/bp/defs.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Complete single-hart OpenRV64 platform integration.
//
// This is the board-independent SoC boundary: CPU, boot ROM, demonstration
// RAM, interrupt controllers, and the current MMIO peripherals all share one
// clock and one blocking memory bus.  Pad cells, a clock generator, and a
// larger board-specific memory controller belong outside this module.
module openrv64_platform #(
    parameter integer SOC_RESET_CYCLES = 4,
    parameter integer CORE_RESET_DELAY_CYCLES = 2,
    parameter integer GPIO_WIDTH = 32,
    parameter integer MEMORY_BYTES = `OPENRV64_SOC_MEMORY_SIZE,
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter int unsigned RETIRE_DEPTH = 16,
    parameter int unsigned PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter int unsigned STORE_QUEUE_DEPTH = 4,
    parameter bit ENABLE_ISSUE_WINDOW = 1'b0,
    parameter bit ENABLE_SPECULATION_WINDOW = 1'b0,
    parameter bit ENABLE_RV64M = 1'b0,
    parameter bit ENABLE_RV64A = 1'b1,
    parameter bit ENABLE_ZICCLSM = 1'b1,
    parameter bit ENABLE_FORWARDING = 1'b1,
    parameter bit ENABLE_LOAD_FORWARDING = 1'b0,
    parameter int unsigned L2_BYTES = 256 * 1024,
    parameter int unsigned L2_WAYS = 8,
    parameter int unsigned L2_MERGE_ENTRIES = 8,
    parameter int unsigned GENBUS_READ_BUFFER_DEPTH = 8,
    parameter int unsigned GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter int unsigned ICX_BUS_TYPE = 0,
    parameter int unsigned ICX_BUS_DATA_WIDTH = 256,
    parameter bit DDR3_ENABLE = 1'b0,
    parameter int unsigned DDR3_READ_QUEUE_DEPTH = 8,
    parameter int unsigned DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter int unsigned DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter bit DDR3_BANK_ROW_SWIZZLE = 1'b1,
    parameter int unsigned MEMORY_TIMING_MODEL = 0,
    // Board targets with physical memory controllers can move the scalar RAM
    // and native PTW ICX endpoint outside this board-independent platform.
    // The current external boundary is intentionally limited to the 1P path.
    parameter bit EXTERNAL_MEMORY_ENABLE = 1'b0,
    parameter bit L1D_PREFETCH_ENABLE = 1'b1,
    parameter int unsigned L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter int unsigned L1D_PREFETCH_QUEUE_LINES = 4,
    parameter int unsigned L1D_PREFETCH_OUTSTANDING = 4,
    parameter int unsigned L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter int unsigned L1D_PREFETCH_PAGE_GATING = 1,
    parameter int unsigned L1I_DEMAND_MSHRS = 4,
    parameter int unsigned L2_TLB_ENTRIES = 256,
    parameter int unsigned L2_TLB_WAYS = 4,
    parameter bit FETCH_CAROUSEL = 1'b1,
    parameter int unsigned FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter bit ENABLE_TRACE = 1'b0,
    parameter bit ENABLE_PREDECODE_TARGETS = 1'b1,
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_DEFAULT,
    parameter bit BP_RAS_ENABLE = 1'b1,
    parameter int unsigned BP_RAS_DEPTH = 8,
    parameter int unsigned BP_BIMODAL_ENTRIES = 32,
    parameter int unsigned BP_BIMODAL_COUNTER_BITS = 3,
    parameter int unsigned BP_BIMODAL_UPDATE_DEPTH = 4,
    parameter int unsigned BP_GSHARE_ENTRIES = 256,
    parameter int unsigned BP_GSHARE_COUNTER_BITS = 3,
    parameter int unsigned BP_BTB_ENTRIES = 256,
    parameter int unsigned BP_BTB_TAG_BITS = 16,
    parameter int unsigned BP_INFLIGHT_DEPTH = 16
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // mtime_tick_i is a one-cycle pulse synchronous to clk_i.  A board may
    // derive it from a clock divider or an always-on real-time clock domain.
    input  logic                  mtime_tick_i,

    input  logic                  uart_rx_i,
    output logic                  uart_tx_o,

    input  logic [GPIO_WIDTH-1:0] gpio_in_i,
    output logic [GPIO_WIDTH-1:0] gpio_out_o,

    // Bits 0..28 map to PLIC architectural source IDs 4..32.  Source IDs
    // 1..3 are reserved for UART, GPIO, and the general-purpose timer.
    input  logic [28:0]           external_irq_i,

    output logic                  ext_mem_valid_o,
    input  logic                  ext_mem_ready_i,
    output logic                  ext_mem_write_o,
    output logic [63:0]           ext_mem_addr_o,
    output logic [63:0]           ext_mem_wdata_o,
    output logic [7:0]            ext_mem_wstrb_o,
    input  logic [63:0]           ext_mem_rdata_i,

    output logic                  ext_icx_req_valid_o,
    input  logic                  ext_icx_req_ready_i,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                  ext_icx_req_hart_id_o,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                  ext_icx_req_txn_id_o,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                  ext_icx_req_source_id_o,
    output logic [`OPENRV64_ICX_OP_WIDTH-1:0] ext_icx_req_op_o,
    output logic                  ext_icx_req_lock_o,
    output logic [`OPENRV64_ICX_ORDER_WIDTH-1:0]
                                  ext_icx_req_order_o,
    output logic [`OPENRV64_ICX_KIND_WIDTH-1:0] ext_icx_req_kind_o,
    output logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] ext_icx_req_attr_o,
    output logic [2:0]            ext_icx_req_size_o,
    output logic [63:0]           ext_icx_req_addr_o,
    output logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                  ext_icx_req_burst_len_o,

    output logic                  ext_icx_wdata_valid_o,
    input  logic                  ext_icx_wdata_ready_i,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                  ext_icx_wdata_hart_id_o,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                  ext_icx_wdata_txn_id_o,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                  ext_icx_wdata_source_id_o,
    output logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                  ext_icx_wdata_beat_index_o,
    output logic                  ext_icx_wdata_last_o,
    output logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                  ext_icx_wdata_o,
    output logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
                                  ext_icx_wstrb_o,

    input  logic                  ext_icx_resp_valid_i,
    output logic                  ext_icx_resp_ready_o,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                  ext_icx_resp_hart_id_i,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                  ext_icx_resp_txn_id_i,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                  ext_icx_resp_source_id_i,
    input  logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                  ext_icx_resp_beat_index_i,
    input  logic                  ext_icx_resp_last_i,
    input  logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                  ext_icx_resp_rdata_i,
    input  logic                  ext_icx_resp_error_i,
    input  logic                  ext_icx_resp_sc_success_i,

    // Reset visibility is useful at the board boundary and in validation.
    output logic                  soc_rst_no,
    output logic                  core_rst_no,

    output logic [63:0]           dbg_pc,
    output logic [31:0]           dbg_instr,
    output logic                  dbg_halted,

    output logic [63:0]           trace_cycle,
    output logic [4:0]            trace_valid,
    output logic [4:0]            trace_stall,
    output logic [4:0]            trace_flush,
    output logic [4:0]            trace_advance,
    output logic [319:0]          trace_ids,
    output logic [319:0]          trace_pcs,
    output logic [159:0]          trace_instrs,
    output logic [7:0]            trace_events,
    output logic [7:0]            trace_stall_causes,
    output logic                  trace_retire_valid,
    output logic                  trace_retire_arch,
    output logic                  trace_retire_exception,
    output logic [4:0]            trace_retire_cause,
    output logic [63:0]           trace_retire_next_pc,
    output logic                  trace_retire_rd_write,
    output logic [4:0]            trace_retire_rd,
    output logic [63:0]           trace_retire_wdata
);

    logic core_mem_valid;
    logic core_mem_ready;
    logic core_mem_write;
    logic [63:0] core_mem_addr;
    logic [63:0] core_mem_wdata;
    logic [7:0] core_mem_wstrb;
    logic [63:0] core_mem_rdata;
    logic core_mem_error;

    logic platform_mem_valid;
    logic platform_mem_ready;
    logic platform_mem_write;
    logic [63:0] platform_mem_addr;
    logic [63:0] platform_mem_wdata;
    logic [7:0] platform_mem_wstrb;
    logic [63:0] platform_mem_rdata;
    logic platform_mem_error;

    logic icx_req_valid;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic icx_req_lock;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    logic [2:0] icx_req_size;
    logic [63:0] icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    logic icx_wdata_valid;
    logic icx_wdata_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    logic icx_wdata_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    logic icx_resp_valid;
    logic icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic icx_resp_error;
    logic icx_resp_sc_success;

    logic memory_icx_req_valid;
    logic memory_icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        memory_icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        memory_icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        memory_icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] memory_icx_req_op;
    logic memory_icx_req_lock;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] memory_icx_req_order;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] memory_icx_req_kind;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] memory_icx_req_attr;
    logic [2:0] memory_icx_req_size;
    logic [63:0] memory_icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        memory_icx_req_burst_len;
    logic memory_icx_wdata_valid;
    logic memory_icx_wdata_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        memory_icx_wdata_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        memory_icx_wdata_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        memory_icx_wdata_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        memory_icx_wdata_beat_index;
    logic memory_icx_wdata_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory_icx_wdata;
    logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] memory_icx_wstrb;
    logic memory_icx_resp_valid;
    logic memory_icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        memory_icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        memory_icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        memory_icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        memory_icx_resp_beat_index;
    logic memory_icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory_icx_resp_rdata;
    logic memory_icx_resp_error;
    logic memory_icx_resp_sc_success;

    logic rom_valid;
    logic rom_ready;
    logic rom_write;
    logic [63:0] rom_addr;
    logic [63:0] rom_wdata;
    logic [7:0] rom_wstrb;
    logic [63:0] rom_rdata;

    logic memory_valid;
    logic memory_ready;
    logic memory_write;
    logic [63:0] memory_addr;
    logic [63:0] memory_wdata;
    logic [7:0] memory_wstrb;
    logic [63:0] memory_rdata;
    logic memory_wide_valid;
    logic memory_wide_ready;
    logic memory_wide_write;
    logic [63:0] memory_wide_addr;
    logic [ICX_BUS_DATA_WIDTH-1:0] memory_wide_wdata;
    logic [ICX_BUS_DATA_WIDTH/8-1:0] memory_wide_wstrb;
    logic [ICX_BUS_DATA_WIDTH-1:0] memory_wide_rdata;
    logic memory_wide_error;

    logic clint_valid;
    logic clint_ready;
    logic clint_write;
    logic [63:0] clint_addr;
    logic [63:0] clint_wdata;
    logic [7:0] clint_wstrb;
    logic [63:0] clint_rdata;

    logic plic_valid;
    logic plic_ready;
    logic plic_write;
    logic [63:0] plic_addr;
    logic [63:0] plic_wdata;
    logic [7:0] plic_wstrb;
    logic [63:0] plic_rdata;

    logic uart_valid;
    logic uart_ready;
    logic uart_write;
    logic [63:0] uart_addr;
    logic [63:0] uart_wdata;
    logic [7:0] uart_wstrb;
    logic [63:0] uart_rdata;

    logic gpio_valid;
    logic gpio_ready;
    logic gpio_write;
    logic [63:0] gpio_addr;
    logic [63:0] gpio_wdata;
    logic [7:0] gpio_wstrb;
    logic [63:0] gpio_rdata;

    logic timer_valid;
    logic timer_ready;
    logic timer_write;
    logic [63:0] timer_addr;
    logic [63:0] timer_wdata;
    logic [7:0] timer_wstrb;
    logic [63:0] timer_rdata;

    logic [0:0] clint_msip;
    logic [0:0] clint_mtip;
    logic [63:0] clint_mtime;
    logic [0:0] plic_seip;
    logic uart_irq;
    logic gpio_irq;
    logic timer_irq;
    logic [31:0] plic_irq_sources;
    logic [28:0] external_irq_sync_1_q;
    logic [28:0] external_irq_sync_2_q;

    logic uart_dtr_n;
    logic uart_rts_n;
    logic uart_out1_n;
    logic uart_out2_n;

    openrv64_reset_sequencer #(
        .SOC_HOLD_CYCLES(SOC_RESET_CYCLES),
        .CORE_DELAY_CYCLES(CORE_RESET_DELAY_CYCLES)
    ) u_reset_sequencer (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .soc_rst_no(soc_rst_no),
        .core_rst_no(core_rst_no)
    );

    // External interrupt pins may be asynchronous to the SoC clock.  Their
    // level-sensitive PLIC representation makes a two-flop synchronizer the
    // correct platform boundary; pulse sources must stretch until observed.
    always_ff @(posedge clk_i or negedge soc_rst_no) begin
        if (!soc_rst_no) begin
            external_irq_sync_1_q <= 29'h0;
            external_irq_sync_2_q <= 29'h0;
        end else begin
            external_irq_sync_1_q <= external_irq_i;
            external_irq_sync_2_q <= external_irq_sync_1_q;
        end
    end

    always_comb begin
        plic_irq_sources = 32'h0;
        plic_irq_sources[`OPENRV64_SOC_PLIC_SOURCE_UART-1] = uart_irq;
        plic_irq_sources[`OPENRV64_SOC_PLIC_SOURCE_GPIO-1] = gpio_irq;
        plic_irq_sources[`OPENRV64_SOC_PLIC_SOURCE_TIMER-1] = timer_irq;
        plic_irq_sources[31:
            `OPENRV64_SOC_PLIC_SOURCE_EXTERNAL_BASE-1] =
                external_irq_sync_2_q;
    end

    openrv64_top #(
        .RESET_VECTOR(`OPENRV64_SOC_RESET_VECTOR),
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .BUS_CONFIG((BACKEND_CONFIG == `OPENRV64_BACKEND_3P) ?
                    `OPENRV64_BUS_AXI : `OPENRV64_BUS_GEN),
        .ENABLE_ISSUE_WINDOW(ENABLE_ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(ENABLE_SPECULATION_WINDOW),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .ENABLE_ZICCLSM(ENABLE_ZICCLSM),
        .L1D_CACHEABLE_BASE(`OPENRV64_SOC_MEMORY_BASE),
        .L1D_CACHEABLE_SIZE(MEMORY_BYTES),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .L1D_PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .L1D_PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .L1D_PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .L1D_PREFETCH_DEMAND_RESERVE(L1D_PREFETCH_DEMAND_RESERVE),
        .L1D_PREFETCH_PAGE_GATING(L1D_PREFETCH_PAGE_GATING),
        .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
        .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
        .L2_TLB_WAYS(L2_TLB_WAYS),
        .ENABLE_FETCH_CAROUSEL(FETCH_CAROUSEL),
        .ENABLE_FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
        .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
            FETCH_ALT_CONFIDENCE_GATE),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .ENABLE_TRACE(ENABLE_TRACE),
        .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(BP_RAS_ENABLE),
        .BP_RAS_DEPTH(BP_RAS_DEPTH),
        .BP_BIMODAL_ENTRIES(BP_BIMODAL_ENTRIES),
        .BP_BIMODAL_COUNTER_BITS(BP_BIMODAL_COUNTER_BITS),
        .BP_BIMODAL_UPDATE_DEPTH(BP_BIMODAL_UPDATE_DEPTH),
        .BP_GSHARE_ENTRIES(BP_GSHARE_ENTRIES),
        .BP_GSHARE_COUNTER_BITS(BP_GSHARE_COUNTER_BITS),
        .BP_BTB_ENTRIES(BP_BTB_ENTRIES),
        .BP_BTB_TAG_BITS(BP_BTB_TAG_BITS),
        .BP_INFLIGHT_DEPTH(BP_INFLIGHT_DEPTH)
    ) u_core (
        .clk(clk_i),
        .rst_n(core_rst_no),
        .mem_valid(core_mem_valid),
        .mem_ready(core_mem_ready),
        .mem_write(core_mem_write),
        .mem_addr(core_mem_addr),
        .mem_wdata(core_mem_wdata),
        .mem_wstrb(core_mem_wstrb),
        .mem_rdata(core_mem_rdata),
        .mem_error(core_mem_error),
        .m_axi_arready(1'b0),
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00), .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0), .m_axi_awready(1'b0),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0),
        .icx_req_valid(icx_req_valid),
        .icx_req_ready(icx_req_ready),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id),
        .icx_req_op(icx_req_op),
        .icx_req_lock(icx_req_lock),
        .icx_req_order(icx_req_order),
        .icx_req_kind(icx_req_kind),
        .icx_req_attr(icx_req_attr),
        .icx_req_size(icx_req_size),
        .icx_req_addr(icx_req_addr),
        .icx_req_burst_len(icx_req_burst_len),
        .icx_wdata_valid(icx_wdata_valid),
        .icx_wdata_ready(icx_wdata_ready),
        .icx_wdata_hart_id(icx_wdata_hart_id),
        .icx_wdata_txn_id(icx_wdata_txn_id),
        .icx_wdata_source_id(icx_wdata_source_id),
        .icx_wdata_beat_index(icx_wdata_beat_index),
        .icx_wdata_last(icx_wdata_last),
        .icx_wdata(icx_wdata),
        .icx_wstrb(icx_wstrb),
        .icx_resp_valid(icx_resp_valid),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id),
        .icx_resp_txn_id(icx_resp_txn_id),
        .icx_resp_source_id(icx_resp_source_id),
        .icx_resp_beat_index(icx_resp_beat_index),
        .icx_resp_last(icx_resp_last),
        .icx_resp_rdata(icx_resp_rdata),
        .icx_resp_error(icx_resp_error),
        .icx_resp_sc_success(icx_resp_sc_success),
        .irq_m_software(clint_msip[0]),
        .irq_m_timer(clint_mtip[0]),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(plic_seip[0]),
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
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin :
                g_icx_l2_platform
            openrv64_soc_icx_l2_bridge #(
                .L2_BYTES(L2_BYTES),
                .L2_WAYS(L2_WAYS),
                .L2_MERGE_ENTRIES(L2_MERGE_ENTRIES),
                .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
                .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
                .BUS_TYPE(ICX_BUS_TYPE),
                .BUS_DATA_WIDTH(ICX_BUS_DATA_WIDTH),
                .MEMORY_BYTES(MEMORY_BYTES),
                .DDR3_ENABLE(DDR3_ENABLE),
                .DDR3_READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
                .DDR3_WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
                .DDR3_COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
                .DDR3_BANK_ROW_SWIZZLE(DDR3_BANK_ROW_SWIZZLE),
                .MEMORY_TIMING_MODEL(MEMORY_TIMING_MODEL)
            ) u_icx_l2 (
                .clk_i(clk_i),
                .rst_ni(core_rst_no),
                .icx_req_valid_i(icx_req_valid),
                .icx_req_ready_o(icx_req_ready),
                .icx_req_hart_id_i(icx_req_hart_id),
                .icx_req_txn_id_i(icx_req_txn_id),
                .icx_req_source_id_i(icx_req_source_id),
                .icx_req_op_i(icx_req_op),
                .icx_req_lock_i(icx_req_lock),
                .icx_req_order_i(icx_req_order),
                .icx_req_kind_i(icx_req_kind),
                .icx_req_attr_i(icx_req_attr),
                .icx_req_size_i(icx_req_size),
                .icx_req_addr_i(icx_req_addr),
                .icx_req_burst_len_i(icx_req_burst_len),
                .icx_wdata_valid_i(icx_wdata_valid),
                .icx_wdata_ready_o(icx_wdata_ready),
                .icx_wdata_hart_id_i(icx_wdata_hart_id),
                .icx_wdata_txn_id_i(icx_wdata_txn_id),
                .icx_wdata_source_id_i(icx_wdata_source_id),
                .icx_wdata_beat_index_i(icx_wdata_beat_index),
                .icx_wdata_last_i(icx_wdata_last),
                .icx_wdata_i(icx_wdata),
                .icx_wstrb_i(icx_wstrb),
                .icx_resp_valid_o(icx_resp_valid),
                .icx_resp_ready_i(icx_resp_ready),
                .icx_resp_hart_id_o(icx_resp_hart_id),
                .icx_resp_txn_id_o(icx_resp_txn_id),
                .icx_resp_source_id_o(icx_resp_source_id),
                .icx_resp_beat_index_o(icx_resp_beat_index),
                .icx_resp_last_o(icx_resp_last),
                .icx_resp_rdata_o(icx_resp_rdata),
                .icx_resp_error_o(icx_resp_error),
                .icx_resp_sc_success_o(icx_resp_sc_success),
                .mem_valid_o(platform_mem_valid),
                .mem_ready_i(platform_mem_ready),
                .mem_write_o(platform_mem_write),
                .mem_addr_o(platform_mem_addr),
                .mem_wdata_o(platform_mem_wdata),
                .mem_wstrb_o(platform_mem_wstrb),
                .mem_rdata_i(platform_mem_rdata),
                .mem_error_i(platform_mem_error),
                .ram_valid_o(memory_wide_valid),
                .ram_ready_i(memory_wide_ready),
                .ram_write_o(memory_wide_write),
                .ram_addr_o(memory_wide_addr),
                .ram_wdata_o(memory_wide_wdata),
                .ram_wstrb_o(memory_wide_wstrb),
                .ram_rdata_i(memory_wide_rdata),
                .ram_error_i(memory_wide_error)
            );

            assign core_mem_ready = 1'b0;
            assign core_mem_rdata = 64'd0;
            assign core_mem_error = 1'b0;

            assign memory_icx_req_valid = 1'b0;
            assign memory_icx_req_hart_id = 0;
            assign memory_icx_req_txn_id = 0;
            assign memory_icx_req_source_id = 0;
            assign memory_icx_req_op = `OPENRV64_ICX_OP_READ;
            assign memory_icx_req_lock = 1'b0;
            assign memory_icx_req_order = `OPENRV64_ICX_ORDER_NONE;
            assign memory_icx_req_kind = `OPENRV64_ICX_KIND_LEGACY;
            assign memory_icx_req_attr = `OPENRV64_ICX_ATTR_NONE;
            assign memory_icx_req_size = 3'd0;
            assign memory_icx_req_addr = 64'd0;
            assign memory_icx_req_burst_len = 0;
            assign memory_icx_wdata_valid = 1'b0;
            assign memory_icx_wdata_hart_id = 0;
            assign memory_icx_wdata_txn_id = 0;
            assign memory_icx_wdata_source_id = 0;
            assign memory_icx_wdata_beat_index = 0;
            assign memory_icx_wdata_last = 1'b0;
            assign memory_icx_wdata = 0;
            assign memory_icx_wstrb = 0;
            assign memory_icx_resp_ready = 1'b0;
        end else begin : g_scalar_platform
            assign memory_wide_valid = 1'b0;
            assign memory_wide_write = 1'b0;
            assign memory_wide_addr = 64'd0;
            assign memory_wide_wdata = 0;
            assign memory_wide_wstrb = 0;

            assign platform_mem_valid = core_mem_valid && core_rst_no;
            assign platform_mem_write = core_mem_write;
            assign platform_mem_addr = core_mem_addr;
            assign platform_mem_wdata = core_mem_wdata;
            assign platform_mem_wstrb = core_mem_wstrb;
            assign core_mem_ready = platform_mem_ready;
            assign core_mem_rdata = platform_mem_rdata;
            assign core_mem_error = platform_mem_error;

            assign memory_icx_req_valid = icx_req_valid;
            assign icx_req_ready = memory_icx_req_ready;
            assign memory_icx_req_hart_id = icx_req_hart_id;
            assign memory_icx_req_txn_id = icx_req_txn_id;
            assign memory_icx_req_source_id = icx_req_source_id;
            assign memory_icx_req_op = icx_req_op;
            assign memory_icx_req_lock = icx_req_lock;
            assign memory_icx_req_order = icx_req_order;
            assign memory_icx_req_kind = icx_req_kind;
            assign memory_icx_req_attr = icx_req_attr;
            assign memory_icx_req_size = icx_req_size;
            assign memory_icx_req_addr = icx_req_addr;
            assign memory_icx_req_burst_len = icx_req_burst_len;
            assign memory_icx_wdata_valid = icx_wdata_valid;
            assign icx_wdata_ready = memory_icx_wdata_ready;
            assign memory_icx_wdata_hart_id = icx_wdata_hart_id;
            assign memory_icx_wdata_txn_id = icx_wdata_txn_id;
            assign memory_icx_wdata_source_id = icx_wdata_source_id;
            assign memory_icx_wdata_beat_index = icx_wdata_beat_index;
            assign memory_icx_wdata_last = icx_wdata_last;
            assign memory_icx_wdata = icx_wdata;
            assign memory_icx_wstrb = icx_wstrb;
            assign icx_resp_valid = memory_icx_resp_valid;
            assign memory_icx_resp_ready = icx_resp_ready;
            assign icx_resp_hart_id = memory_icx_resp_hart_id;
            assign icx_resp_txn_id = memory_icx_resp_txn_id;
            assign icx_resp_source_id = memory_icx_resp_source_id;
            assign icx_resp_beat_index = memory_icx_resp_beat_index;
            assign icx_resp_last = memory_icx_resp_last;
            assign icx_resp_rdata = memory_icx_resp_rdata;
            assign icx_resp_error = memory_icx_resp_error;
            assign icx_resp_sc_success = memory_icx_resp_sc_success;
        end
    endgenerate

    openrv64_soc_bus_decode #(
        .MEMORY_SIZE(MEMORY_BYTES)
    ) u_bus (
        .mem_valid_i(platform_mem_valid),
        .mem_ready_o(platform_mem_ready),
        .mem_write_i(platform_mem_write),
        .mem_addr_i(platform_mem_addr),
        .mem_wdata_i(platform_mem_wdata),
        .mem_wstrb_i(platform_mem_wstrb),
        .mem_rdata_o(platform_mem_rdata),
        .mem_error_o(platform_mem_error),
        .rom_valid_o(rom_valid),
        .rom_ready_i(rom_ready),
        .rom_write_o(rom_write),
        .rom_addr_o(rom_addr),
        .rom_wdata_o(rom_wdata),
        .rom_wstrb_o(rom_wstrb),
        .rom_rdata_i(rom_rdata),
        .memory_valid_o(memory_valid),
        .memory_ready_i(memory_ready),
        .memory_write_o(memory_write),
        .memory_addr_o(memory_addr),
        .memory_wdata_o(memory_wdata),
        .memory_wstrb_o(memory_wstrb),
        .memory_rdata_i(memory_rdata),
        .clint_valid_o(clint_valid),
        .clint_ready_i(clint_ready),
        .clint_write_o(clint_write),
        .clint_addr_o(clint_addr),
        .clint_wdata_o(clint_wdata),
        .clint_wstrb_o(clint_wstrb),
        .clint_rdata_i(clint_rdata),
        .plic_valid_o(plic_valid),
        .plic_ready_i(plic_ready),
        .plic_write_o(plic_write),
        .plic_addr_o(plic_addr),
        .plic_wdata_o(plic_wdata),
        .plic_wstrb_o(plic_wstrb),
        .plic_rdata_i(plic_rdata),
        .uart_valid_o(uart_valid),
        .uart_ready_i(uart_ready),
        .uart_write_o(uart_write),
        .uart_addr_o(uart_addr),
        .uart_wdata_o(uart_wdata),
        .uart_wstrb_o(uart_wstrb),
        .uart_rdata_i(uart_rdata),
        .gpio_valid_o(gpio_valid),
        .gpio_ready_i(gpio_ready),
        .gpio_write_o(gpio_write),
        .gpio_addr_o(gpio_addr),
        .gpio_wdata_o(gpio_wdata),
        .gpio_wstrb_o(gpio_wstrb),
        .gpio_rdata_i(gpio_rdata),
        .timer_valid_o(timer_valid),
        .timer_ready_i(timer_ready),
        .timer_write_o(timer_write),
        .timer_addr_o(timer_addr),
        .timer_wdata_o(timer_wdata),
        .timer_wstrb_o(timer_wstrb),
        .timer_rdata_i(timer_rdata)
    );

    openrv64_soc_rom u_rom (
        .mem_valid_i(rom_valid),
        .mem_ready_o(rom_ready),
        .mem_write_i(rom_write),
        .mem_addr_i(rom_addr),
        .mem_wdata_i(rom_wdata),
        .mem_wstrb_i(rom_wstrb),
        .mem_rdata_o(rom_rdata)
    );

    wire internal_memory_ready;
    wire [63:0] internal_memory_rdata;
    wire internal_memory_wide_ready;
    wire [ICX_BUS_DATA_WIDTH-1:0] internal_memory_wide_rdata;
    wire internal_memory_wide_error;
    wire internal_memory_icx_req_ready;
    wire internal_memory_icx_wdata_ready;
    wire internal_memory_icx_resp_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        internal_memory_icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        internal_memory_icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        internal_memory_icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        internal_memory_icx_resp_beat_index;
    wire internal_memory_icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        internal_memory_icx_resp_rdata;
    wire internal_memory_icx_resp_error;
    wire internal_memory_icx_resp_sc_success;

    initial begin
        if (EXTERNAL_MEMORY_ENABLE &&
            (BACKEND_CONFIG == `OPENRV64_BACKEND_3P))
            $fatal(1, "external platform memory currently supports only 1P");
    end

    assign ext_mem_valid_o =
        EXTERNAL_MEMORY_ENABLE ? memory_valid : 1'b0;
    assign ext_mem_write_o =
        EXTERNAL_MEMORY_ENABLE ? memory_write : 1'b0;
    assign ext_mem_addr_o =
        EXTERNAL_MEMORY_ENABLE ? memory_addr : 64'd0;
    assign ext_mem_wdata_o =
        EXTERNAL_MEMORY_ENABLE ? memory_wdata : 64'd0;
    assign ext_mem_wstrb_o =
        EXTERNAL_MEMORY_ENABLE ? memory_wstrb : 8'd0;
    assign memory_ready = EXTERNAL_MEMORY_ENABLE ?
        ext_mem_ready_i : internal_memory_ready;
    assign memory_rdata = EXTERNAL_MEMORY_ENABLE ?
        ext_mem_rdata_i : internal_memory_rdata;

    assign memory_wide_ready = EXTERNAL_MEMORY_ENABLE ?
        1'b0 : internal_memory_wide_ready;
    assign memory_wide_rdata = EXTERNAL_MEMORY_ENABLE ?
        0 : internal_memory_wide_rdata;
    assign memory_wide_error = EXTERNAL_MEMORY_ENABLE ?
        memory_wide_valid : internal_memory_wide_error;

    assign ext_icx_req_valid_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_valid : 1'b0;
    assign memory_icx_req_ready = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_req_ready_i : internal_memory_icx_req_ready;
    assign ext_icx_req_hart_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_hart_id : 0;
    assign ext_icx_req_txn_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_txn_id : 0;
    assign ext_icx_req_source_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_source_id : 0;
    assign ext_icx_req_op_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_op : `OPENRV64_ICX_OP_READ;
    assign ext_icx_req_lock_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_lock : 1'b0;
    assign ext_icx_req_order_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_order : `OPENRV64_ICX_ORDER_NONE;
    assign ext_icx_req_kind_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_kind : `OPENRV64_ICX_KIND_LEGACY;
    assign ext_icx_req_attr_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_attr : `OPENRV64_ICX_ATTR_NONE;
    assign ext_icx_req_size_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_size : 3'd0;
    assign ext_icx_req_addr_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_addr : 64'd0;
    assign ext_icx_req_burst_len_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_req_burst_len : 0;

    assign ext_icx_wdata_valid_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_valid : 1'b0;
    assign memory_icx_wdata_ready = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_wdata_ready_i : internal_memory_icx_wdata_ready;
    assign ext_icx_wdata_hart_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_hart_id : 0;
    assign ext_icx_wdata_txn_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_txn_id : 0;
    assign ext_icx_wdata_source_id_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_source_id : 0;
    assign ext_icx_wdata_beat_index_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_beat_index : 0;
    assign ext_icx_wdata_last_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata_last : 1'b0;
    assign ext_icx_wdata_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wdata : 0;
    assign ext_icx_wstrb_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_wstrb : 0;

    assign memory_icx_resp_valid = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_valid_i : internal_memory_icx_resp_valid;
    assign ext_icx_resp_ready_o = EXTERNAL_MEMORY_ENABLE ?
        memory_icx_resp_ready : 1'b0;
    assign memory_icx_resp_hart_id = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_hart_id_i : internal_memory_icx_resp_hart_id;
    assign memory_icx_resp_txn_id = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_txn_id_i : internal_memory_icx_resp_txn_id;
    assign memory_icx_resp_source_id = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_source_id_i : internal_memory_icx_resp_source_id;
    assign memory_icx_resp_beat_index = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_beat_index_i : internal_memory_icx_resp_beat_index;
    assign memory_icx_resp_last = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_last_i : internal_memory_icx_resp_last;
    assign memory_icx_resp_rdata = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_rdata_i : internal_memory_icx_resp_rdata;
    assign memory_icx_resp_error = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_error_i : internal_memory_icx_resp_error;
    assign memory_icx_resp_sc_success = EXTERNAL_MEMORY_ENABLE ?
        ext_icx_resp_sc_success_i : internal_memory_icx_resp_sc_success;

    // Keep this instance at the historical hierarchy path (`u_memory`) so
    // existing platform testbenches can initialize and inspect its RAM.
    // External-memory targets reduce it to one inert 64-byte line.
    openrv64_soc_memory #(
        .MEM_BYTES(EXTERNAL_MEMORY_ENABLE ? 64 : MEMORY_BYTES),
        .WIDE_DATA_WIDTH(ICX_BUS_DATA_WIDTH)
    ) u_memory (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .mem_valid_i(EXTERNAL_MEMORY_ENABLE ? 1'b0 : memory_valid),
        .mem_ready_o(internal_memory_ready),
        .mem_write_i(memory_write),
        .mem_addr_i(memory_addr),
        .mem_wdata_i(memory_wdata),
        .mem_wstrb_i(memory_wstrb),
        .mem_rdata_o(internal_memory_rdata),
        .wide_valid_i(EXTERNAL_MEMORY_ENABLE ? 1'b0 : memory_wide_valid),
        .wide_ready_o(internal_memory_wide_ready),
        .wide_write_i(memory_wide_write),
        .wide_addr_i(memory_wide_addr),
        .wide_wdata_i(memory_wide_wdata),
        .wide_wstrb_i(memory_wide_wstrb),
        .wide_rdata_o(internal_memory_wide_rdata),
        .wide_error_o(internal_memory_wide_error),
        .icx_req_valid_i(
            EXTERNAL_MEMORY_ENABLE ? 1'b0 : memory_icx_req_valid),
        .icx_req_ready_o(internal_memory_icx_req_ready),
        .icx_req_hart_id_i(memory_icx_req_hart_id),
        .icx_req_txn_id_i(memory_icx_req_txn_id),
        .icx_req_source_id_i(memory_icx_req_source_id),
        .icx_req_op_i(memory_icx_req_op),
        .icx_req_lock_i(memory_icx_req_lock),
        .icx_req_order_i(memory_icx_req_order),
        .icx_req_kind_i(memory_icx_req_kind),
        .icx_req_attr_i(memory_icx_req_attr),
        .icx_req_size_i(memory_icx_req_size),
        .icx_req_addr_i(memory_icx_req_addr),
        .icx_req_burst_len_i(memory_icx_req_burst_len),
        .icx_wdata_valid_i(
            EXTERNAL_MEMORY_ENABLE ? 1'b0 : memory_icx_wdata_valid),
        .icx_wdata_ready_o(internal_memory_icx_wdata_ready),
        .icx_wdata_hart_id_i(memory_icx_wdata_hart_id),
        .icx_wdata_txn_id_i(memory_icx_wdata_txn_id),
        .icx_wdata_source_id_i(memory_icx_wdata_source_id),
        .icx_wdata_beat_index_i(memory_icx_wdata_beat_index),
        .icx_wdata_last_i(memory_icx_wdata_last),
        .icx_wdata_i(memory_icx_wdata),
        .icx_wstrb_i(memory_icx_wstrb),
        .icx_resp_valid_o(internal_memory_icx_resp_valid),
        .icx_resp_ready_i(
            EXTERNAL_MEMORY_ENABLE ? 1'b0 : memory_icx_resp_ready),
        .icx_resp_hart_id_o(internal_memory_icx_resp_hart_id),
        .icx_resp_txn_id_o(internal_memory_icx_resp_txn_id),
        .icx_resp_source_id_o(internal_memory_icx_resp_source_id),
        .icx_resp_beat_index_o(internal_memory_icx_resp_beat_index),
        .icx_resp_last_o(internal_memory_icx_resp_last),
        .icx_resp_rdata_o(internal_memory_icx_resp_rdata),
        .icx_resp_error_o(internal_memory_icx_resp_error),
        .icx_resp_sc_success_o(internal_memory_icx_resp_sc_success)
    );

    openrv64_clint #(
        .NUM_HARTS(1)
    ) u_clint (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .mtime_tick_i(mtime_tick_i),
        .mem_valid_i(clint_valid),
        .mem_ready_o(clint_ready),
        .mem_write_i(clint_write),
        .mem_addr_i(clint_addr),
        .mem_wdata_i(clint_wdata),
        .mem_wstrb_i(clint_wstrb),
        .mem_rdata_o(clint_rdata),
        .msip_o(clint_msip),
        .mtip_o(clint_mtip),
        .mtime_o(clint_mtime)
    );

    openrv64_plic #(
        .NUM_HARTS(1),
        .NUM_SOURCES(32),
        .PRIORITY_WIDTH(3)
    ) u_plic (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .irq_sources_i(plic_irq_sources),
        .mem_valid_i(plic_valid),
        .mem_ready_o(plic_ready),
        .mem_write_i(plic_write),
        .mem_addr_i(plic_addr),
        .mem_wdata_i(plic_wdata),
        .mem_wstrb_i(plic_wstrb),
        .mem_rdata_o(plic_rdata),
        .seip_o(plic_seip)
    );

    openrv64_uart16550 u_uart (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .rx_i(uart_rx_i),
        .tx_o(uart_tx_o),
        .cts_ni(1'b1),
        .dsr_ni(1'b1),
        .ri_ni(1'b1),
        .dcd_ni(1'b1),
        .dtr_no(uart_dtr_n),
        .rts_no(uart_rts_n),
        .out1_no(uart_out1_n),
        .out2_no(uart_out2_n),
        .mem_valid_i(uart_valid),
        .mem_ready_o(uart_ready),
        .mem_write_i(uart_write),
        .mem_addr_i(uart_addr),
        .mem_wdata_i(uart_wdata),
        .mem_wstrb_i(uart_wstrb),
        .mem_rdata_o(uart_rdata),
        .irq_o(uart_irq)
    );

    openrv64_gpio #(
        .NUM_PINS(GPIO_WIDTH),
        .ENABLE_INTERRUPTS(1)
    ) u_gpio (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .gpio_in_i(gpio_in_i),
        .gpio_out_o(gpio_out_o),
        .irq_o(gpio_irq),
        .mem_valid_i(gpio_valid),
        .mem_ready_o(gpio_ready),
        .mem_write_i(gpio_write),
        .mem_addr_i(gpio_addr),
        .mem_wdata_i(gpio_wdata),
        .mem_wstrb_i(gpio_wstrb),
        .mem_rdata_o(gpio_rdata)
    );

    openrv64_timer #(
        .ENABLE_INTERRUPTS(1)
    ) u_timer (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .irq_o(timer_irq),
        .mem_valid_i(timer_valid),
        .mem_ready_o(timer_ready),
        .mem_write_i(timer_write),
        .mem_addr_i(timer_addr),
        .mem_wdata_i(timer_wdata),
        .mem_wstrb_i(timer_wstrb),
        .mem_rdata_o(timer_rdata)
    );

endmodule
