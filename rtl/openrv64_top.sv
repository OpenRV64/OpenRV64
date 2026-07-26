`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "core/exec/bp/defs.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module openrv64_top #(
    parameter logic [63:0] RESET_VECTOR = `OPENRV64_SOC_RESET_VECTOR,
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter logic [`OPENRV64_BUS_CONFIG_WIDTH-1:0] BUS_CONFIG =
        `OPENRV64_BUS_GEN,
    parameter int unsigned RETIRE_DEPTH = 8,
    parameter int unsigned PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter int unsigned PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter int unsigned STORE_QUEUE_DEPTH = 4,
    parameter bit ENABLE_ISSUE_WINDOW = 1'b0,
    parameter bit ENABLE_SPECULATION_WINDOW = 1'b0,
    parameter bit ENABLE_RV64M = 1'b0,
    parameter bit ENABLE_RV64A = 1'b1,
    parameter bit ENABLE_FORWARDING = 1'b1,
    parameter bit ENABLE_LOAD_FORWARDING = 1'b0,
    parameter bit ENABLE_L1I = 1'b1,
    parameter bit ENABLE_L1D = 1'b1,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1D_CACHE_BYTES = 16 * 1024,
    parameter logic [63:0] L1D_CACHEABLE_BASE =
        `OPENRV64_SOC_MEMORY_BASE,
    parameter logic [63:0] L1D_CACHEABLE_SIZE =
        `OPENRV64_SOC_MEMORY_SIZE,
    parameter int unsigned L1D_FILL_BUFFER_LINES = 8,
    parameter int unsigned L1D_DEMAND_MSHRS = 3,
    parameter int unsigned L1D_STORE_BUFFER_LINES = 8,
    parameter bit L1D_PREFETCH_ENABLE = 1'b1,
    parameter int unsigned L1D_PREFETCH_MAX_STRIDE_LINES = 64,
    parameter int unsigned L1D_PREFETCH_STREAMS = 2,
    parameter int unsigned L1D_PREFETCH_DISTANCE = 1,
    parameter bit L1D_PREFETCH_ADAPTIVE_ENABLE = 1'b1,
    parameter int unsigned L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter int unsigned L1D_PREFETCH_QUEUE_LINES = 4,
    parameter int unsigned L1D_PREFETCH_OUTSTANDING = 4,
    parameter int unsigned L1D_PREFETCH_DEMAND_RESERVE = 2,
    parameter int unsigned L1I_FILL_BUFFER_LINES = 8,
    parameter int unsigned L1I_DEMAND_MSHRS = 4,
    parameter int unsigned L2_TLB_ENTRIES = 256,
    parameter int unsigned L2_TLB_WAYS = 4,
    parameter int unsigned PTW_PTE_CACHE_ENTRIES = 64,
    parameter int unsigned PTW_CCX_TIMEOUT_CYCLES = 65536,
    parameter logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID = '0,
    parameter bit ENABLE_MAGIC_MEMORY = 1'b0,
    parameter bit ENABLE_TRACE = 1'b0,
    parameter bit ENABLE_PREDECODE_TARGETS = 1'b1,
    parameter bit ENABLE_FETCH_CAROUSEL = 1'b1,
    parameter int unsigned ENABLE_FETCH_ALT_LOOKASIDE = 3,
    parameter integer ENABLE_FETCH_ALT_CONFIDENCE_GATE = 0,
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
    input  logic        clk,
    input  logic        rst_n,

    // Simple blocking memory bus. The core holds mem_valid and all request
    // fields stable through a mem_ready completion. mem_error marks an access
    // fault on that completion.
    output logic        mem_valid,
    input  logic        mem_ready,
    output logic        mem_write,
    output logic [63:0] mem_addr,
    output logic [63:0] mem_wdata,
    output logic [7:0]  mem_wstrb,
    input  logic [63:0] mem_rdata,
    input  logic        mem_error,

    // 256-bit AXI4 master.  This interface is active only for the 3-pipe
    // backend with BUS_CONFIG=OPENRV64_BUS_AXI; the generic bus remains
    // available above for the legacy configuration.
    output logic [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_arid,
    output logic [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arlock,
    output logic [3:0]  m_axi_arcache,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arqos,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_rid,
    input  logic [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    output logic [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_awid,
    output logic [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awlock,
    output logic [3:0]  m_axi_awcache,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awqos,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [`OPENRV64_AXI_STRB_WIDTH-1:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    output logic        ccx_req_valid,
    input  logic        ccx_req_ready,
    output logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id,
    output logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id,
    output logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id,
    output logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op,
    output logic        ccx_req_lock,
    output logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order,
    output logic [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind,
    output logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr,
    output logic [2:0]  ccx_req_size,
    output logic [63:0] ccx_req_addr,
    output logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len,
    output logic        ccx_wdata_valid,
    input  logic        ccx_wdata_ready,
    output logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id,
    output logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id,
    output logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id,
    output logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index,
    output logic        ccx_wdata_last,
    output logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata,
    output logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb,
    input  logic        ccx_resp_valid,
    output logic        ccx_resp_ready,
    input  logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id,
    input  logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id,
    input  logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id,
    input  logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index,
    input  logic        ccx_resp_last,
    input  logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata,
    input  logic        ccx_resp_error,
    input  logic        ccx_resp_sc_success,

    input  logic        irq_m_software,
    input  logic        irq_m_timer,
    input  logic        irq_m_external,
    input  logic        irq_s_software,
    input  logic        irq_s_timer,
    input  logic        irq_s_external,

    output logic [63:0] dbg_pc,
    output logic [31:0] dbg_instr,
    output logic        dbg_halted,

    // Optional, synthesizable cycle trace. Packed stage order is
    // 0=IF, 1=ID, 2=EX, 3=MEM, 4=WB (least to most significant slice).
    output logic [63:0]  trace_cycle,
    output logic [4:0]   trace_valid,
    output logic [4:0]   trace_stall,
    output logic [4:0]   trace_flush,
    output logic [4:0]   trace_advance,
    output logic [319:0] trace_ids,
    output logic [319:0] trace_pcs,
    output logic [159:0] trace_instrs,
    output logic [7:0]   trace_events,
    output logic [7:0]   trace_stall_causes,
    output logic         trace_retire_valid,
    output logic         trace_retire_arch,
    output logic         trace_retire_exception,
    output logic [4:0]   trace_retire_cause,
    output logic [63:0]  trace_retire_next_pc,
    output logic         trace_retire_rd_write,
    output logic [4:0]   trace_retire_rd,
    output logic [63:0]  trace_retire_wdata
);

    wire use_3p = (BACKEND_CONFIG == `OPENRV64_BACKEND_3P);

    wire legacy_mem_valid;
    wire legacy_mem_write;
    wire [63:0] legacy_mem_addr;
    wire [63:0] legacy_mem_wdata;
    wire [7:0] legacy_mem_wstrb;
    wire legacy_ccx_req_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] legacy_ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] legacy_ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] legacy_ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] legacy_ccx_req_op;
    wire legacy_ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] legacy_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] legacy_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] legacy_ccx_req_attr;
    wire [2:0] legacy_ccx_req_size;
    wire [63:0] legacy_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] legacy_ccx_req_burst_len;
    wire legacy_ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] legacy_ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] legacy_ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] legacy_ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        legacy_ccx_wdata_beat_index;
    wire legacy_ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] legacy_ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] legacy_ccx_wstrb;
    wire legacy_ccx_resp_ready;
    wire [63:0] legacy_dbg_pc;
    wire [31:0] legacy_dbg_instr;
    wire legacy_dbg_halted;
    wire [63:0] legacy_trace_cycle;
    wire [4:0] legacy_trace_valid;
    wire [4:0] legacy_trace_stall;
    wire [4:0] legacy_trace_flush;
    wire [4:0] legacy_trace_advance;
    wire [319:0] legacy_trace_ids;
    wire [319:0] legacy_trace_pcs;
    wire [159:0] legacy_trace_instrs;
    wire [7:0] legacy_trace_events;
    wire [7:0] legacy_trace_stall_causes;
    wire legacy_trace_retire_valid;
    wire legacy_trace_retire_arch;
    wire legacy_trace_retire_exception;
    wire [4:0] legacy_trace_retire_cause;
    wire [63:0] legacy_trace_retire_next_pc;
    wire legacy_trace_retire_rd_write;
    wire [4:0] legacy_trace_retire_rd;
    wire [63:0] legacy_trace_retire_wdata;

    wire three_mem_valid;
    wire three_mem_write;
    wire [63:0] three_mem_addr;
    wire [63:0] three_mem_wdata;
    wire [7:0] three_mem_wstrb;
    wire [63:0] three_dbg_pc;
    wire [31:0] three_dbg_instr;
    wire three_dbg_halted;
    wire [63:0] three_trace_cycle;
    wire [4:0] three_trace_valid;
    wire [4:0] three_trace_stall;
    wire [4:0] three_trace_flush;
    wire [4:0] three_trace_advance;
    wire [319:0] three_trace_ids;
    wire [319:0] three_trace_pcs;
    wire [159:0] three_trace_instrs;
    wire [7:0] three_trace_events;
    wire [7:0] three_trace_stall_causes;
    wire three_trace_retire_valid;
    wire three_trace_retire_arch;
    wire three_trace_retire_exception;
    wire [4:0] three_trace_retire_cause;
    wire [63:0] three_trace_retire_next_pc;
    wire three_trace_retire_rd_write;
    wire [4:0] three_trace_retire_rd;
    wire [63:0] three_trace_retire_wdata;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] three_axi_arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] three_axi_araddr;
    wire [7:0] three_axi_arlen;
    wire [2:0] three_axi_arsize;
    wire [1:0] three_axi_arburst;
    wire three_axi_arlock;
    wire [3:0] three_axi_arcache;
    wire [2:0] three_axi_arprot;
    wire [3:0] three_axi_arqos;
    wire three_axi_arvalid;
    wire three_axi_rready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] three_axi_awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] three_axi_awaddr;
    wire [7:0] three_axi_awlen;
    wire [2:0] three_axi_awsize;
    wire [1:0] three_axi_awburst;
    wire three_axi_awlock;
    wire [3:0] three_axi_awcache;
    wire [2:0] three_axi_awprot;
    wire [3:0] three_axi_awqos;
    wire three_axi_awvalid;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] three_axi_wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] three_axi_wstrb;
    wire three_axi_wlast;
    wire three_axi_wvalid;
    wire three_axi_bready;
    wire three_ccx_req_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] three_ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] three_ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] three_ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] three_ccx_req_op;
    wire three_ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] three_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] three_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] three_ccx_req_attr;
    wire [2:0] three_ccx_req_size;
    wire [63:0] three_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] three_ccx_req_burst_len;
    wire three_ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] three_ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] three_ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] three_ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] three_ccx_wdata_beat_index;
    wire three_ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] three_ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] three_ccx_wstrb;
    wire three_ccx_resp_ready;

    openrv64_rv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_1P),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .PTW_CCX_TIMEOUT_CYCLES(PTW_CCX_TIMEOUT_CYCLES),
        .HART_ID(HART_ID),
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
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(legacy_mem_valid),
        .mem_ready(use_3p ? 1'b0 : mem_ready),
        .mem_write(legacy_mem_write),
        .mem_addr(legacy_mem_addr),
        .mem_wdata(legacy_mem_wdata),
        .mem_wstrb(legacy_mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_error(mem_error),
        .ccx_req_valid(legacy_ccx_req_valid),
        .ccx_req_ready(!use_3p && ccx_req_ready),
        .ccx_req_hart_id(legacy_ccx_req_hart_id),
        .ccx_req_txn_id(legacy_ccx_req_txn_id),
        .ccx_req_source_id(legacy_ccx_req_source_id),
        .ccx_req_op(legacy_ccx_req_op),
        .ccx_req_lock(legacy_ccx_req_lock),
        .ccx_req_order(legacy_ccx_req_order),
        .ccx_req_kind(legacy_ccx_req_kind),
        .ccx_req_attr(legacy_ccx_req_attr),
        .ccx_req_size(legacy_ccx_req_size),
        .ccx_req_addr(legacy_ccx_req_addr),
        .ccx_req_burst_len(legacy_ccx_req_burst_len),
        .ccx_wdata_valid(legacy_ccx_wdata_valid),
        .ccx_wdata_ready(!use_3p && ccx_wdata_ready),
        .ccx_wdata_hart_id(legacy_ccx_wdata_hart_id),
        .ccx_wdata_txn_id(legacy_ccx_wdata_txn_id),
        .ccx_wdata_source_id(legacy_ccx_wdata_source_id),
        .ccx_wdata_beat_index(legacy_ccx_wdata_beat_index),
        .ccx_wdata_last(legacy_ccx_wdata_last),
        .ccx_wdata(legacy_ccx_wdata),
        .ccx_wstrb(legacy_ccx_wstrb),
        .ccx_resp_valid(!use_3p && ccx_resp_valid),
        .ccx_resp_ready(legacy_ccx_resp_ready),
        .ccx_resp_hart_id(ccx_resp_hart_id),
        .ccx_resp_txn_id(ccx_resp_txn_id),
        .ccx_resp_source_id(ccx_resp_source_id),
        .ccx_resp_beat_index(ccx_resp_beat_index),
        .ccx_resp_last(ccx_resp_last),
        .ccx_resp_rdata(ccx_resp_rdata),
        .ccx_resp_error(ccx_resp_error),
        .ccx_resp_sc_success(ccx_resp_sc_success),
        .irq_m_software(use_3p ? 1'b0 : irq_m_software),
        .irq_m_timer(use_3p ? 1'b0 : irq_m_timer),
        .irq_m_external(use_3p ? 1'b0 : irq_m_external),
        .irq_s_software(use_3p ? 1'b0 : irq_s_software),
        .irq_s_timer(use_3p ? 1'b0 : irq_s_timer),
        .irq_s_external(use_3p ? 1'b0 : irq_s_external),
        .dbg_pc(legacy_dbg_pc), .dbg_instr(legacy_dbg_instr),
        .dbg_halted(legacy_dbg_halted),
        .trace_cycle(legacy_trace_cycle), .trace_valid(legacy_trace_valid),
        .trace_stall(legacy_trace_stall), .trace_flush(legacy_trace_flush),
        .trace_advance(legacy_trace_advance), .trace_ids(legacy_trace_ids),
        .trace_pcs(legacy_trace_pcs), .trace_instrs(legacy_trace_instrs),
        .trace_events(legacy_trace_events),
        .trace_stall_causes(legacy_trace_stall_causes),
        .trace_retire_valid(legacy_trace_retire_valid),
        .trace_retire_arch(legacy_trace_retire_arch),
        .trace_retire_exception(legacy_trace_retire_exception),
        .trace_retire_cause(legacy_trace_retire_cause),
        .trace_retire_next_pc(legacy_trace_retire_next_pc),
        .trace_retire_rd_write(legacy_trace_retire_rd_write),
        .trace_retire_rd(legacy_trace_retire_rd),
        .trace_retire_wdata(legacy_trace_retire_wdata)
    );

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_backend_3p
            openrv64_rv64_top_3p #(
                .RESET_VECTOR(RESET_VECTOR), .ENABLE_RV64M(ENABLE_RV64M),
                .BUS_CONFIG(BUS_CONFIG),
                .STORE_FORWARD_BASE(`OPENRV64_SOC_MEMORY_BASE),
                .STORE_FORWARD_SIZE(`OPENRV64_SOC_MEMORY_SIZE),
                .ENABLE_RV64A(ENABLE_RV64A), .ENABLE_L1I(ENABLE_L1I),
                .ENABLE_L1D(ENABLE_L1D),
                .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
                .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
                .L1D_CACHEABLE_BASE(L1D_CACHEABLE_BASE),
                .L1D_CACHEABLE_SIZE(L1D_CACHEABLE_SIZE),
                .SPEC_LOAD_BASE(L1D_CACHEABLE_BASE),
                .SPEC_LOAD_SIZE(L1D_CACHEABLE_SIZE),
                .L1D_FILL_BUFFER_LINES(L1D_FILL_BUFFER_LINES),
                .L1D_DEMAND_MSHRS(L1D_DEMAND_MSHRS),
                .L1D_STORE_BUFFER_LINES(L1D_STORE_BUFFER_LINES),
                .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
                .L1D_PREFETCH_MAX_STRIDE_LINES(
                    L1D_PREFETCH_MAX_STRIDE_LINES),
                .L1D_PREFETCH_STREAMS(L1D_PREFETCH_STREAMS),
                .L1D_PREFETCH_DISTANCE(L1D_PREFETCH_DISTANCE),
                .L1D_PREFETCH_ADAPTIVE_ENABLE(
                    L1D_PREFETCH_ADAPTIVE_ENABLE),
                .L1D_PREFETCH_MAX_DISTANCE(
                    L1D_PREFETCH_MAX_DISTANCE),
                .L1D_PREFETCH_QUEUE_LINES(
                    L1D_PREFETCH_QUEUE_LINES),
                .L1D_PREFETCH_OUTSTANDING(
                    L1D_PREFETCH_OUTSTANDING),
                .L1D_PREFETCH_DEMAND_RESERVE(
                    L1D_PREFETCH_DEMAND_RESERVE),
                .L1I_FILL_BUFFER_LINES(L1I_FILL_BUFFER_LINES),
                .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
                .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
                .L2_TLB_WAYS(L2_TLB_WAYS),
                .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
                .PTW_CCX_TIMEOUT_CYCLES(PTW_CCX_TIMEOUT_CYCLES),
                .HART_ID(HART_ID),
                .ENABLE_ISSUE_WINDOW(ENABLE_ISSUE_WINDOW),
                .ENABLE_SPECULATION_WINDOW(
                    ENABLE_SPECULATION_WINDOW),
                .RETIRE_DEPTH(RETIRE_DEPTH),
                .PHYS_REG_COUNT(PHYS_REG_COUNT),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
                .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
                .ENABLE_MAGIC_MEMORY(ENABLE_MAGIC_MEMORY),
                .ENABLE_TRACE(ENABLE_TRACE),
                .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
                .ENABLE_FETCH_CAROUSEL(ENABLE_FETCH_CAROUSEL),
                .ENABLE_FETCH_ALT_LOOKASIDE(
                    ENABLE_FETCH_ALT_LOOKASIDE),
                .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
                    ENABLE_FETCH_ALT_CONFIDENCE_GATE),
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
            ) u_core_3p (
                .clk(clk), .rst_n(rst_n), .mem_valid(three_mem_valid),
                .mem_ready(mem_ready), .mem_write(three_mem_write),
                .mem_addr(three_mem_addr), .mem_wdata(three_mem_wdata),
                .mem_wstrb(three_mem_wstrb), .mem_rdata(mem_rdata),
                .mem_error(mem_error),
                .pair512_req_valid(), .pair512_req_ready(1'b0),
                .pair512_req_predicted_addr(),
                .pair512_req_unpredicted_addr(),
                .pair512_resp_valid(1'b0),
                .pair512_resp_predicted_addr(64'd0),
                .pair512_resp_predicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair512_resp_unpredicted_addr(64'd0),
                .pair512_resp_unpredicted_data(
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
                .pair1024_req_valid(), .pair1024_req_ready(1'b0),
                .pair1024_req_predicted_addr(),
                .pair1024_req_unpredicted_addr(),
                .pair1024_resp_valid(1'b0),
                .pair1024_resp_predicted_addr(64'd0),
                .pair1024_resp_predicted_data(
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
                .pair1024_resp_unpredicted_addr(64'd0),
                .pair1024_resp_unpredicted_data(
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
                .m_axi_arid(three_axi_arid),
                .m_axi_araddr(three_axi_araddr),
                .m_axi_arlen(three_axi_arlen),
                .m_axi_arsize(three_axi_arsize),
                .m_axi_arburst(three_axi_arburst),
                .m_axi_arlock(three_axi_arlock),
                .m_axi_arcache(three_axi_arcache),
                .m_axi_arprot(three_axi_arprot),
                .m_axi_arqos(three_axi_arqos),
                .m_axi_arvalid(three_axi_arvalid),
                .m_axi_arready(m_axi_arready),
                .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
                .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
                .m_axi_rvalid(m_axi_rvalid),
                .m_axi_rready(three_axi_rready),
                .m_axi_awid(three_axi_awid),
                .m_axi_awaddr(three_axi_awaddr),
                .m_axi_awlen(three_axi_awlen),
                .m_axi_awsize(three_axi_awsize),
                .m_axi_awburst(three_axi_awburst),
                .m_axi_awlock(three_axi_awlock),
                .m_axi_awcache(three_axi_awcache),
                .m_axi_awprot(three_axi_awprot),
                .m_axi_awqos(three_axi_awqos),
                .m_axi_awvalid(three_axi_awvalid),
                .m_axi_awready(m_axi_awready),
                .m_axi_wdata(three_axi_wdata),
                .m_axi_wstrb_axi(three_axi_wstrb),
                .m_axi_wlast(three_axi_wlast),
                .m_axi_wvalid(three_axi_wvalid),
                .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid),
                .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
                .m_axi_bready(three_axi_bready),
                .ccx_req_valid(three_ccx_req_valid),
                .ccx_req_ready(ccx_req_ready),
                .ccx_req_hart_id(three_ccx_req_hart_id),
                .ccx_req_txn_id(three_ccx_req_txn_id),
                .ccx_req_source_id(three_ccx_req_source_id),
                .ccx_req_op(three_ccx_req_op),
                .ccx_req_lock(three_ccx_req_lock),
                .ccx_req_order(three_ccx_req_order),
                .ccx_req_kind(three_ccx_req_kind),
                .ccx_req_attr(three_ccx_req_attr),
                .ccx_req_size(three_ccx_req_size),
                .ccx_req_addr(three_ccx_req_addr),
                .ccx_req_burst_len(three_ccx_req_burst_len),
                .ccx_wdata_valid(three_ccx_wdata_valid),
                .ccx_wdata_ready(ccx_wdata_ready),
                .ccx_wdata_hart_id(three_ccx_wdata_hart_id),
                .ccx_wdata_txn_id(three_ccx_wdata_txn_id),
                .ccx_wdata_source_id(three_ccx_wdata_source_id),
                .ccx_wdata_beat_index(three_ccx_wdata_beat_index),
                .ccx_wdata_last(three_ccx_wdata_last),
                .ccx_wdata(three_ccx_wdata),
                .ccx_wstrb(three_ccx_wstrb),
                .ccx_resp_valid(ccx_resp_valid),
                .ccx_resp_ready(three_ccx_resp_ready),
                .ccx_resp_hart_id(ccx_resp_hart_id),
                .ccx_resp_txn_id(ccx_resp_txn_id),
                .ccx_resp_source_id(ccx_resp_source_id),
                .ccx_resp_beat_index(ccx_resp_beat_index),
                .ccx_resp_last(ccx_resp_last),
                .ccx_resp_rdata(ccx_resp_rdata),
                .ccx_resp_error(ccx_resp_error),
                .ccx_resp_sc_success(ccx_resp_sc_success),
                .irq_m_software(irq_m_software),
                .irq_m_timer(irq_m_timer),
                .irq_m_external(irq_m_external),
                .irq_s_software(irq_s_software),
                .irq_s_timer(irq_s_timer),
                .irq_s_external(irq_s_external), .dbg_pc(three_dbg_pc),
                .dbg_instr(three_dbg_instr), .dbg_halted(three_dbg_halted),
                .trace_cycle(three_trace_cycle),
                .trace_valid(three_trace_valid),
                .trace_stall(three_trace_stall),
                .trace_flush(three_trace_flush),
                .trace_advance(three_trace_advance),
                .trace_ids(three_trace_ids), .trace_pcs(three_trace_pcs),
                .trace_instrs(three_trace_instrs),
                .trace_events(three_trace_events),
                .trace_stall_causes(three_trace_stall_causes),
                .trace_retire_valid(three_trace_retire_valid),
                .trace_retire_arch(three_trace_retire_arch),
                .trace_retire_exception(three_trace_retire_exception),
                .trace_retire_cause(three_trace_retire_cause),
                .trace_retire_next_pc(three_trace_retire_next_pc),
                .trace_retire_rd_write(three_trace_retire_rd_write),
                .trace_retire_rd(three_trace_retire_rd),
                .trace_retire_wdata(three_trace_retire_wdata)
            );
        end else begin : g_no_backend_3p
            assign three_mem_valid = 1'b0;
            assign three_mem_write = 1'b0;
            assign three_mem_addr = 64'd0;
            assign three_mem_wdata = 64'd0;
            assign three_mem_wstrb = 8'd0;
            assign three_dbg_pc = 64'd0;
            assign three_dbg_instr = 32'd0;
            assign three_dbg_halted = 1'b0;
            assign three_trace_cycle = 64'd0;
            assign three_trace_valid = 5'd0;
            assign three_trace_stall = 5'd0;
            assign three_trace_flush = 5'd0;
            assign three_trace_advance = 5'd0;
            assign three_trace_ids = 320'd0;
            assign three_trace_pcs = 320'd0;
            assign three_trace_instrs = 160'd0;
            assign three_trace_events = 8'd0;
            assign three_trace_stall_causes = 8'd0;
            assign three_trace_retire_valid = 1'b0;
            assign three_trace_retire_arch = 1'b0;
            assign three_trace_retire_exception = 1'b0;
            assign three_trace_retire_cause = 5'd0;
            assign three_trace_retire_next_pc = 64'd0;
            assign three_trace_retire_rd_write = 1'b0;
            assign three_trace_retire_rd = 5'd0;
            assign three_trace_retire_wdata = 64'd0;
            assign three_axi_arid = '0;
            assign three_axi_araddr = '0;
            assign three_axi_arlen = '0;
            assign three_axi_arsize = '0;
            assign three_axi_arburst = '0;
            assign three_axi_arlock = 1'b0;
            assign three_axi_arcache = '0;
            assign three_axi_arprot = '0;
            assign three_axi_arqos = '0;
            assign three_axi_arvalid = 1'b0;
            assign three_axi_rready = 1'b0;
            assign three_axi_awid = '0;
            assign three_axi_awaddr = '0;
            assign three_axi_awlen = '0;
            assign three_axi_awsize = '0;
            assign three_axi_awburst = '0;
            assign three_axi_awlock = 1'b0;
            assign three_axi_awcache = '0;
            assign three_axi_awprot = '0;
            assign three_axi_awqos = '0;
            assign three_axi_awvalid = 1'b0;
            assign three_axi_wdata = '0;
            assign three_axi_wstrb = '0;
            assign three_axi_wlast = 1'b0;
            assign three_axi_wvalid = 1'b0;
            assign three_axi_bready = 1'b0;
            assign three_ccx_req_valid = 1'b0;
            assign three_ccx_req_hart_id = '0;
            assign three_ccx_req_txn_id = '0;
            assign three_ccx_req_source_id = '0;
            assign three_ccx_req_op = '0;
            assign three_ccx_req_lock = 1'b0;
            assign three_ccx_req_order = '0;
            assign three_ccx_req_kind = '0;
            assign three_ccx_req_attr = '0;
            assign three_ccx_req_size = '0;
            assign three_ccx_req_addr = '0;
            assign three_ccx_req_burst_len = '0;
            assign three_ccx_wdata_valid = 1'b0;
            assign three_ccx_wdata_hart_id = '0;
            assign three_ccx_wdata_txn_id = '0;
            assign three_ccx_wdata_source_id = '0;
            assign three_ccx_wdata_beat_index = '0;
            assign three_ccx_wdata_last = 1'b0;
            assign three_ccx_wdata = '0;
            assign three_ccx_wstrb = '0;
            assign three_ccx_resp_ready = 1'b0;
        end
    endgenerate

    assign mem_valid = use_3p ? three_mem_valid : legacy_mem_valid;
    assign mem_write = use_3p ? three_mem_write : legacy_mem_write;
    assign mem_addr = use_3p ? three_mem_addr : legacy_mem_addr;
    assign mem_wdata = use_3p ? three_mem_wdata : legacy_mem_wdata;
    assign mem_wstrb = use_3p ? three_mem_wstrb : legacy_mem_wstrb;
    assign m_axi_arid = three_axi_arid;
    assign m_axi_araddr = three_axi_araddr;
    assign m_axi_arlen = three_axi_arlen;
    assign m_axi_arsize = three_axi_arsize;
    assign m_axi_arburst = three_axi_arburst;
    assign m_axi_arlock = three_axi_arlock;
    assign m_axi_arcache = three_axi_arcache;
    assign m_axi_arprot = three_axi_arprot;
    assign m_axi_arqos = three_axi_arqos;
    assign m_axi_arvalid = three_axi_arvalid;
    assign m_axi_rready = three_axi_rready;
    assign m_axi_awid = three_axi_awid;
    assign m_axi_awaddr = three_axi_awaddr;
    assign m_axi_awlen = three_axi_awlen;
    assign m_axi_awsize = three_axi_awsize;
    assign m_axi_awburst = three_axi_awburst;
    assign m_axi_awlock = three_axi_awlock;
    assign m_axi_awcache = three_axi_awcache;
    assign m_axi_awprot = three_axi_awprot;
    assign m_axi_awqos = three_axi_awqos;
    assign m_axi_awvalid = three_axi_awvalid;
    assign m_axi_wdata = three_axi_wdata;
    assign m_axi_wstrb = three_axi_wstrb;
    assign m_axi_wlast = three_axi_wlast;
    assign m_axi_wvalid = three_axi_wvalid;
    assign m_axi_bready = three_axi_bready;
    assign ccx_req_valid = use_3p ? three_ccx_req_valid :
                                      legacy_ccx_req_valid;
    assign ccx_req_hart_id = use_3p ? three_ccx_req_hart_id :
                                        legacy_ccx_req_hart_id;
    assign ccx_req_txn_id = use_3p ? three_ccx_req_txn_id :
                                       legacy_ccx_req_txn_id;
    assign ccx_req_source_id = use_3p ? three_ccx_req_source_id :
                                          legacy_ccx_req_source_id;
    assign ccx_req_op = use_3p ? three_ccx_req_op : legacy_ccx_req_op;
    assign ccx_req_lock = use_3p ? three_ccx_req_lock :
                                   legacy_ccx_req_lock;
    assign ccx_req_order = use_3p ? three_ccx_req_order :
                                    legacy_ccx_req_order;
    assign ccx_req_kind = use_3p ? three_ccx_req_kind :
                                   legacy_ccx_req_kind;
    assign ccx_req_attr = use_3p ? three_ccx_req_attr :
                                   legacy_ccx_req_attr;
    assign ccx_req_size = use_3p ? three_ccx_req_size :
                                   legacy_ccx_req_size;
    assign ccx_req_addr = use_3p ? three_ccx_req_addr :
                                   legacy_ccx_req_addr;
    assign ccx_req_burst_len = use_3p ? three_ccx_req_burst_len :
                                        legacy_ccx_req_burst_len;
    assign ccx_wdata_valid = use_3p ? three_ccx_wdata_valid :
                                       legacy_ccx_wdata_valid;
    assign ccx_wdata_hart_id = use_3p ? three_ccx_wdata_hart_id :
                                          legacy_ccx_wdata_hart_id;
    assign ccx_wdata_txn_id = use_3p ? three_ccx_wdata_txn_id :
                                         legacy_ccx_wdata_txn_id;
    assign ccx_wdata_source_id = use_3p ? three_ccx_wdata_source_id :
                                            legacy_ccx_wdata_source_id;
    assign ccx_wdata_beat_index = use_3p ? three_ccx_wdata_beat_index :
                                             legacy_ccx_wdata_beat_index;
    assign ccx_wdata_last = use_3p ? three_ccx_wdata_last :
                                     legacy_ccx_wdata_last;
    assign ccx_wdata = use_3p ? three_ccx_wdata : legacy_ccx_wdata;
    assign ccx_wstrb = use_3p ? three_ccx_wstrb : legacy_ccx_wstrb;
    assign ccx_resp_ready = use_3p ? three_ccx_resp_ready :
                                     legacy_ccx_resp_ready;
    assign dbg_pc = use_3p ? three_dbg_pc : legacy_dbg_pc;
    assign dbg_instr = use_3p ? three_dbg_instr : legacy_dbg_instr;
    assign dbg_halted = use_3p ? three_dbg_halted : legacy_dbg_halted;
    assign trace_cycle = use_3p ? three_trace_cycle : legacy_trace_cycle;
    assign trace_valid = use_3p ? three_trace_valid : legacy_trace_valid;
    assign trace_stall = use_3p ? three_trace_stall : legacy_trace_stall;
    assign trace_flush = use_3p ? three_trace_flush : legacy_trace_flush;
    assign trace_advance = use_3p ? three_trace_advance : legacy_trace_advance;
    assign trace_ids = use_3p ? three_trace_ids : legacy_trace_ids;
    assign trace_pcs = use_3p ? three_trace_pcs : legacy_trace_pcs;
    assign trace_instrs = use_3p ? three_trace_instrs : legacy_trace_instrs;
    assign trace_events = use_3p ? three_trace_events : legacy_trace_events;
    assign trace_stall_causes = use_3p ? three_trace_stall_causes :
                                        legacy_trace_stall_causes;
    assign trace_retire_valid = use_3p ? three_trace_retire_valid :
                                        legacy_trace_retire_valid;
    assign trace_retire_arch = use_3p ? three_trace_retire_arch :
                                       legacy_trace_retire_arch;
    assign trace_retire_exception = use_3p ? three_trace_retire_exception :
                                            legacy_trace_retire_exception;
    assign trace_retire_cause = use_3p ? three_trace_retire_cause :
                                        legacy_trace_retire_cause;
    assign trace_retire_next_pc = use_3p ? three_trace_retire_next_pc :
                                          legacy_trace_retire_next_pc;
    assign trace_retire_rd_write = use_3p ? three_trace_retire_rd_write :
                                           legacy_trace_retire_rd_write;
    assign trace_retire_rd = use_3p ? three_trace_retire_rd :
                                     legacy_trace_retire_rd;
    assign trace_retire_wdata = use_3p ? three_trace_retire_wdata :
                                        legacy_trace_retire_wdata;

`ifndef SYNTHESIS
    initial begin
        if ((BACKEND_CONFIG != `OPENRV64_BACKEND_1P) &&
            (BACKEND_CONFIG != `OPENRV64_BACKEND_3P))
            $fatal(1, "openrv64_top: selected backend is not implemented");
        if ((BUS_CONFIG == `OPENRV64_BUS_AXI) &&
            (BACKEND_CONFIG != `OPENRV64_BACKEND_3P))
            $fatal(1, "openrv64_top: AXI bus requires the 3-pipe backend");
    end
`endif

endmodule
