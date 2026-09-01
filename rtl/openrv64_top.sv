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
    parameter int unsigned RETIRE_DEPTH = 16,
    parameter int unsigned ISSUE_WINDOW_DEPTH = RETIRE_DEPTH,
    parameter int unsigned PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter int unsigned PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter int unsigned RENAME_MODE = `OPENRV64_RENAME_IDENTITY,
    parameter int unsigned STORE_QUEUE_DEPTH = 4,
    parameter bit ENABLE_ISSUE_WINDOW = 1'b0,
    parameter bit ENABLE_SPECULATION_WINDOW = 1'b0,
    parameter logic [2:0] COMPLETION_FORWARD_MASK_3P = 3'b000,
    parameter logic [2:0] BRANCH_COMPLETION_FORWARD_MASK_3P = 3'b001,
    parameter bit ENABLE_FULL_FORWARDING_3P = 1'b0,
    parameter bit RELAX_WAW_3P = 1'b1,
    parameter bit RELAX_HAZARDS_3P = 1'b0,
    parameter bit ENABLE_ZICCLSM = 1'b1,
    parameter bit ENABLE_RV64M = 1'b0,
    parameter bit ENABLE_RV64ZBB = 1'b1,
    parameter bit ENABLE_RV64A = 1'b1,
    parameter int unsigned HPM_COUNTERS = 8,
    parameter int unsigned PMP_ACTIVE_ENTRIES = 8,
    parameter bit ENABLE_FORWARDING = 1'b1,
    parameter bit ENABLE_LOAD_FORWARDING = 1'b0,
    parameter bit PIPE_1P_MEM_4_STAGE = 1'b0,
    parameter bit PIPE_1P_DECODE_QUEUE = 1'b0,
    parameter bit BANKED_GPR = 1'b1,
    parameter bit FPGA_GPR_LUTRAM = 1'b0,
    parameter bit BANKED_GPR_3P = 1'b0,
    parameter bit FPGA_GPR_LUTRAM_3P = 1'b0,
    parameter bit DEBUG_SERIALIZE_ALL_1P = 1'b0,
    parameter bit ENABLE_L1I = 1'b1,
    parameter bit ENABLE_L1D = 1'b1,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L1D_CACHE_BYTES = 16 * 1024,
    parameter logic [63:0] L1D_CACHEABLE_BASE =
        `OPENRV64_SOC_MEMORY_BASE,
    parameter logic [63:0] L1D_CACHEABLE_SIZE =
        (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) ?
            `OPENRV64_SOC_DRAM_PMA_SIZE : `OPENRV64_SOC_MEMORY_SIZE,
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
    parameter int unsigned L1D_PREFETCH_PAGE_GATING = 1,
    parameter int unsigned L1I_FILL_BUFFER_LINES = 8,
    parameter int unsigned L1I_DEMAND_MSHRS = 4,
    parameter int unsigned GENBUS_TLB_ENTRIES = 16,
    parameter int unsigned L2_TLB_ENTRIES = 256,
    parameter int unsigned L2_TLB_WAYS = 4,
    parameter int unsigned PTW_PTE_CACHE_ENTRIES = 64,
    parameter int unsigned PTW_ICX_TIMEOUT_CYCLES = 65536,
    parameter logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID = '0,
    parameter bit ENABLE_MAGIC_MEMORY = 1'b0,
    parameter bit ENABLE_TRACE = 1'b0,
    parameter bit ENABLE_PREDECODE_TARGETS = 1'b1,
    parameter bit ENABLE_FETCH_CAROUSEL = 1'b1,
    parameter int unsigned ENABLE_FETCH_ALT_LOOKASIDE = 3,
    parameter integer ENABLE_FETCH_ALT_CONFIDENCE_GATE = 1,
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

    output logic        icx_req_valid,
    input  logic        icx_req_ready,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id,
    output logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op,
    output logic        icx_req_lock,
    output logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order,
    output logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind,
    output logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr,
    output logic [2:0]  icx_req_size,
    output logic [63:0] icx_req_addr,
    output logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len,
    output logic        icx_wdata_valid,
    input  logic        icx_wdata_ready,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id,
    output logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index,
    output logic        icx_wdata_last,
    output logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata,
    output logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb,
    input  logic        icx_resp_valid,
    output logic        icx_resp_ready,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id,
    input  logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index,
    input  logic        icx_resp_last,
    input  logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata,
    input  logic        icx_resp_error,
    input  logic        icx_resp_sc_success,

    input  logic        irq_m_software,
    input  logic        irq_m_timer,
    input  logic        irq_m_external,
    input  logic        irq_s_software,
    input  logic        irq_s_timer,
    input  logic        irq_s_external,

    output logic [63:0] dbg_pc,
    output logic [31:0] dbg_instr,
    output logic [63:0] dbg_rs1_data,
    output logic [63:0] dbg_rs2_data,
    output logic        dbg_halted,
    output logic        wfi_sleep,

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
    output logic [63:0]  trace_retire_wdata,
    output logic         trace_fetch_valid,
    output logic [63:0]  trace_fetch_pc,
    output logic [63:0]  trace_fetch_data,
    output logic         trace_load_valid,
    output logic [63:0]  trace_load_pc,
    output logic [63:0]  trace_load_addr,
    output logic [4:0]   trace_load_rd,
    output logic [63:0]  trace_load_data,
    output logic         trace_store_valid,
    output logic [63:0]  trace_store_pc,
    output logic [63:0]  trace_store_addr,
    output logic [63:0]  trace_store_data,
    output logic [7:0]   trace_store_wstrb
);

    wire use_3p = (BACKEND_CONFIG == `OPENRV64_BACKEND_3P);

    wire legacy_mem_valid;
    wire legacy_mem_write;
    wire [63:0] legacy_mem_addr;
    wire [63:0] legacy_mem_wdata;
    wire [7:0] legacy_mem_wstrb;
    wire legacy_icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] legacy_icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] legacy_icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] legacy_icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] legacy_icx_req_op;
    wire legacy_icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] legacy_icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] legacy_icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] legacy_icx_req_attr;
    wire [2:0] legacy_icx_req_size;
    wire [63:0] legacy_icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] legacy_icx_req_burst_len;
    wire legacy_icx_wdata_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] legacy_icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] legacy_icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] legacy_icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        legacy_icx_wdata_beat_index;
    wire legacy_icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] legacy_icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] legacy_icx_wstrb;
    wire legacy_icx_resp_ready;
    wire [63:0] legacy_dbg_pc;
    wire [31:0] legacy_dbg_instr;
    wire [63:0] legacy_dbg_rs1_data;
    wire [63:0] legacy_dbg_rs2_data;
    wire legacy_dbg_halted;
    wire legacy_wfi_sleep;
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
    wire legacy_trace_fetch_valid;
    wire [63:0] legacy_trace_fetch_pc;
    wire [63:0] legacy_trace_fetch_data;
    wire legacy_trace_load_valid;
    wire [63:0] legacy_trace_load_pc;
    wire [63:0] legacy_trace_load_addr;
    wire [4:0] legacy_trace_load_rd;
    wire [63:0] legacy_trace_load_data;
    wire legacy_trace_store_valid;
    wire [63:0] legacy_trace_store_pc;
    wire [63:0] legacy_trace_store_addr;
    wire [63:0] legacy_trace_store_data;
    wire [7:0] legacy_trace_store_wstrb;

    wire three_mem_valid;
    wire three_mem_write;
    wire [63:0] three_mem_addr;
    wire [63:0] three_mem_wdata;
    wire [7:0] three_mem_wstrb;
    wire [63:0] three_dbg_pc;
    wire [31:0] three_dbg_instr;
    wire [63:0] three_dbg_rs1_data;
    wire [63:0] three_dbg_rs2_data;
    wire three_dbg_halted;
    wire three_wfi_sleep;
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
    wire three_icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] three_icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] three_icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] three_icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] three_icx_req_op;
    wire three_icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] three_icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] three_icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] three_icx_req_attr;
    wire [2:0] three_icx_req_size;
    wire [63:0] three_icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] three_icx_req_burst_len;
    wire three_icx_wdata_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] three_icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] three_icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] three_icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] three_icx_wdata_beat_index;
    wire three_icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] three_icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] three_icx_wstrb;
    wire three_icx_resp_ready;

    openrv64_rv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_1P),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .HPM_COUNTERS(HPM_COUNTERS),
        .PMP_ACTIVE_ENTRIES(PMP_ACTIVE_ENTRIES),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .PIPE_1P_MEM_4_STAGE(PIPE_1P_MEM_4_STAGE),
        .PIPE_1P_DECODE_QUEUE(PIPE_1P_DECODE_QUEUE),
        .BANKED_GPR(BANKED_GPR),
        .FPGA_GPR_LUTRAM(FPGA_GPR_LUTRAM),
        .DEBUG_SERIALIZE_ALL_1P(DEBUG_SERIALIZE_ALL_1P),
        .TLB_ENTRIES(GENBUS_TLB_ENTRIES),
        .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .PTW_ICX_TIMEOUT_CYCLES(PTW_ICX_TIMEOUT_CYCLES),
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
        .icx_req_valid(legacy_icx_req_valid),
        .icx_req_ready(!use_3p && icx_req_ready),
        .icx_req_hart_id(legacy_icx_req_hart_id),
        .icx_req_txn_id(legacy_icx_req_txn_id),
        .icx_req_source_id(legacy_icx_req_source_id),
        .icx_req_op(legacy_icx_req_op),
        .icx_req_lock(legacy_icx_req_lock),
        .icx_req_order(legacy_icx_req_order),
        .icx_req_kind(legacy_icx_req_kind),
        .icx_req_attr(legacy_icx_req_attr),
        .icx_req_size(legacy_icx_req_size),
        .icx_req_addr(legacy_icx_req_addr),
        .icx_req_burst_len(legacy_icx_req_burst_len),
        .icx_wdata_valid(legacy_icx_wdata_valid),
        .icx_wdata_ready(!use_3p && icx_wdata_ready),
        .icx_wdata_hart_id(legacy_icx_wdata_hart_id),
        .icx_wdata_txn_id(legacy_icx_wdata_txn_id),
        .icx_wdata_source_id(legacy_icx_wdata_source_id),
        .icx_wdata_beat_index(legacy_icx_wdata_beat_index),
        .icx_wdata_last(legacy_icx_wdata_last),
        .icx_wdata(legacy_icx_wdata),
        .icx_wstrb(legacy_icx_wstrb),
        .icx_resp_valid(!use_3p && icx_resp_valid),
        .icx_resp_ready(legacy_icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id),
        .icx_resp_txn_id(icx_resp_txn_id),
        .icx_resp_source_id(icx_resp_source_id),
        .icx_resp_beat_index(icx_resp_beat_index),
        .icx_resp_last(icx_resp_last),
        .icx_resp_rdata(icx_resp_rdata),
        .icx_resp_error(icx_resp_error),
        .icx_resp_sc_success(icx_resp_sc_success),
        .irq_m_software(use_3p ? 1'b0 : irq_m_software),
        .irq_m_timer(use_3p ? 1'b0 : irq_m_timer),
        .irq_m_external(use_3p ? 1'b0 : irq_m_external),
        .irq_s_software(use_3p ? 1'b0 : irq_s_software),
        .irq_s_timer(use_3p ? 1'b0 : irq_s_timer),
        .irq_s_external(use_3p ? 1'b0 : irq_s_external),
        .dbg_pc(legacy_dbg_pc), .dbg_instr(legacy_dbg_instr),
        .dbg_rs1_data(legacy_dbg_rs1_data),
        .dbg_rs2_data(legacy_dbg_rs2_data),
        .dbg_halted(legacy_dbg_halted),
        .wfi_sleep_o(legacy_wfi_sleep),
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
        .trace_retire_wdata(legacy_trace_retire_wdata),
        .trace_fetch_valid(legacy_trace_fetch_valid),
        .trace_fetch_pc(legacy_trace_fetch_pc),
        .trace_fetch_data(legacy_trace_fetch_data),
        .trace_load_valid(legacy_trace_load_valid),
        .trace_load_pc(legacy_trace_load_pc),
        .trace_load_addr(legacy_trace_load_addr),
        .trace_load_rd(legacy_trace_load_rd),
        .trace_load_data(legacy_trace_load_data),
        .trace_store_valid(legacy_trace_store_valid),
        .trace_store_pc(legacy_trace_store_pc),
        .trace_store_addr(legacy_trace_store_addr),
        .trace_store_data(legacy_trace_store_data),
        .trace_store_wstrb(legacy_trace_store_wstrb)
    );

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_backend_3p
            assign three_dbg_rs1_data = 64'd0;
            assign three_dbg_rs2_data = 64'd0;
            openrv64_rv64_top_3p #(
                .RESET_VECTOR(RESET_VECTOR), .ENABLE_RV64M(ENABLE_RV64M),
                .ENABLE_RV64ZBB(ENABLE_RV64ZBB),
                .HPM_COUNTERS(HPM_COUNTERS),
                .PMP_ACTIVE_ENTRIES(PMP_ACTIVE_ENTRIES),
                .BUS_CONFIG(BUS_CONFIG),
                .ENABLE_ZICCLSM(ENABLE_ZICCLSM),
                .STORE_FORWARD_BASE(`OPENRV64_SOC_MEMORY_BASE),
                .STORE_FORWARD_SIZE(`OPENRV64_SOC_MEMORY_SIZE),
                .ENABLE_RV64A(ENABLE_RV64A), .ENABLE_L1I(ENABLE_L1I),
                .ENABLE_L1D(ENABLE_L1D),
                .ENABLE_L1D_COHERENCE_PROBES(1'b0),
                .ENABLE_COHERENT_ATOMICS(1'b0),
                .BANKED_GPR(BANKED_GPR_3P),
                .FPGA_GPR_LUTRAM(FPGA_GPR_LUTRAM_3P),
                .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
                .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
                .L1D_CACHEABLE_BASE(L1D_CACHEABLE_BASE),
                .L1D_CACHEABLE_SIZE(L1D_CACHEABLE_SIZE),
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
                .L1D_PREFETCH_PAGE_GATING(
                    L1D_PREFETCH_PAGE_GATING),
                .L1I_FILL_BUFFER_LINES(L1I_FILL_BUFFER_LINES),
                .L1I_DEMAND_MSHRS(L1I_DEMAND_MSHRS),
                .L2_TLB_ENTRIES(L2_TLB_ENTRIES),
                .L2_TLB_WAYS(L2_TLB_WAYS),
                .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
                .PTW_ICX_TIMEOUT_CYCLES(PTW_ICX_TIMEOUT_CYCLES),
                .HART_ID(HART_ID),
                .ENABLE_ISSUE_WINDOW(ENABLE_ISSUE_WINDOW),
                .ENABLE_SPECULATION_WINDOW(
                    ENABLE_SPECULATION_WINDOW),
                .COMPLETION_FORWARD_MASK(
                    COMPLETION_FORWARD_MASK_3P),
                .BRANCH_COMPLETION_FORWARD_MASK(
                    BRANCH_COMPLETION_FORWARD_MASK_3P),
                .ENABLE_FULL_FORWARDING(ENABLE_FULL_FORWARDING_3P),
                .RELAX_WAW(RELAX_WAW_3P),
                .RELAX_HAZARDS(RELAX_HAZARDS_3P),
                .RETIRE_DEPTH(RETIRE_DEPTH),
                .ISSUE_WINDOW_DEPTH(ISSUE_WINDOW_DEPTH),
                .PHYS_REG_COUNT(PHYS_REG_COUNT),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
                .RENAME_MODE(RENAME_MODE),
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
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
                .pair1024_resp_unpredicted_addr(64'd0),
                .pair1024_resp_unpredicted_data(
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
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
                .icx_req_valid(three_icx_req_valid),
                .icx_req_ready(icx_req_ready),
                .icx_req_hart_id(three_icx_req_hart_id),
                .icx_req_txn_id(three_icx_req_txn_id),
                .icx_req_source_id(three_icx_req_source_id),
                .icx_req_op(three_icx_req_op),
                .icx_req_lock(three_icx_req_lock),
                .icx_req_order(three_icx_req_order),
                .icx_req_kind(three_icx_req_kind),
                .icx_req_attr(three_icx_req_attr),
                .icx_req_size(three_icx_req_size),
                .icx_req_addr(three_icx_req_addr),
                .icx_req_burst_len(three_icx_req_burst_len),
                .icx_wdata_valid(three_icx_wdata_valid),
                .icx_wdata_ready(icx_wdata_ready),
                .icx_wdata_hart_id(three_icx_wdata_hart_id),
                .icx_wdata_txn_id(three_icx_wdata_txn_id),
                .icx_wdata_source_id(three_icx_wdata_source_id),
                .icx_wdata_beat_index(three_icx_wdata_beat_index),
                .icx_wdata_last(three_icx_wdata_last),
                .icx_wdata(three_icx_wdata),
                .icx_wstrb(three_icx_wstrb),
                .icx_resp_valid(icx_resp_valid),
                .icx_resp_ready(three_icx_resp_ready),
                .icx_resp_hart_id(icx_resp_hart_id),
                .icx_resp_txn_id(icx_resp_txn_id),
                .icx_resp_source_id(icx_resp_source_id),
                .icx_resp_beat_index(icx_resp_beat_index),
                .icx_resp_last(icx_resp_last),
                .icx_resp_rdata(icx_resp_rdata),
                .icx_resp_error(icx_resp_error),
                .icx_resp_sc_success(icx_resp_sc_success),
                .l1d_probe_valid_i(1'b0),
                .l1d_probe_ready_o(),
                .l1d_probe_addr_i(64'd0),
                .coherent_reservation_clear_i(1'b0),
                .irq_m_software(irq_m_software),
                .irq_m_timer(irq_m_timer),
                .irq_m_external(irq_m_external),
                .irq_s_software(irq_s_software),
                .irq_s_timer(irq_s_timer),
                .irq_s_external(irq_s_external), .dbg_pc(three_dbg_pc),
                .dbg_instr(three_dbg_instr), .dbg_halted(three_dbg_halted),
                .wfi_sleep_o(three_wfi_sleep),
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
            assign three_wfi_sleep = 1'b0;
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
            assign three_dbg_rs1_data = 64'd0;
            assign three_dbg_rs2_data = 64'd0;
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
            assign three_icx_req_valid = 1'b0;
            assign three_icx_req_hart_id = '0;
            assign three_icx_req_txn_id = '0;
            assign three_icx_req_source_id = '0;
            assign three_icx_req_op = '0;
            assign three_icx_req_lock = 1'b0;
            assign three_icx_req_order = '0;
            assign three_icx_req_kind = '0;
            assign three_icx_req_attr = '0;
            assign three_icx_req_size = '0;
            assign three_icx_req_addr = '0;
            assign three_icx_req_burst_len = '0;
            assign three_icx_wdata_valid = 1'b0;
            assign three_icx_wdata_hart_id = '0;
            assign three_icx_wdata_txn_id = '0;
            assign three_icx_wdata_source_id = '0;
            assign three_icx_wdata_beat_index = '0;
            assign three_icx_wdata_last = 1'b0;
            assign three_icx_wdata = '0;
            assign three_icx_wstrb = '0;
            assign three_icx_resp_ready = 1'b0;
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
    assign icx_req_valid = use_3p ? three_icx_req_valid :
                                      legacy_icx_req_valid;
    assign icx_req_hart_id = use_3p ? three_icx_req_hart_id :
                                        legacy_icx_req_hart_id;
    assign icx_req_txn_id = use_3p ? three_icx_req_txn_id :
                                       legacy_icx_req_txn_id;
    assign icx_req_source_id = use_3p ? three_icx_req_source_id :
                                          legacy_icx_req_source_id;
    assign icx_req_op = use_3p ? three_icx_req_op : legacy_icx_req_op;
    assign icx_req_lock = use_3p ? three_icx_req_lock :
                                   legacy_icx_req_lock;
    assign icx_req_order = use_3p ? three_icx_req_order :
                                    legacy_icx_req_order;
    assign icx_req_kind = use_3p ? three_icx_req_kind :
                                   legacy_icx_req_kind;
    assign icx_req_attr = use_3p ? three_icx_req_attr :
                                   legacy_icx_req_attr;
    assign icx_req_size = use_3p ? three_icx_req_size :
                                   legacy_icx_req_size;
    assign icx_req_addr = use_3p ? three_icx_req_addr :
                                   legacy_icx_req_addr;
    assign icx_req_burst_len = use_3p ? three_icx_req_burst_len :
                                        legacy_icx_req_burst_len;
    assign icx_wdata_valid = use_3p ? three_icx_wdata_valid :
                                       legacy_icx_wdata_valid;
    assign icx_wdata_hart_id = use_3p ? three_icx_wdata_hart_id :
                                          legacy_icx_wdata_hart_id;
    assign icx_wdata_txn_id = use_3p ? three_icx_wdata_txn_id :
                                         legacy_icx_wdata_txn_id;
    assign icx_wdata_source_id = use_3p ? three_icx_wdata_source_id :
                                            legacy_icx_wdata_source_id;
    assign icx_wdata_beat_index = use_3p ? three_icx_wdata_beat_index :
                                             legacy_icx_wdata_beat_index;
    assign icx_wdata_last = use_3p ? three_icx_wdata_last :
                                     legacy_icx_wdata_last;
    assign icx_wdata = use_3p ? three_icx_wdata : legacy_icx_wdata;
    assign icx_wstrb = use_3p ? three_icx_wstrb : legacy_icx_wstrb;
    assign icx_resp_ready = use_3p ? three_icx_resp_ready :
                                     legacy_icx_resp_ready;
    assign dbg_pc = use_3p ? three_dbg_pc : legacy_dbg_pc;
    assign dbg_instr = use_3p ? three_dbg_instr : legacy_dbg_instr;
    assign dbg_rs1_data = use_3p ? three_dbg_rs1_data : legacy_dbg_rs1_data;
    assign dbg_rs2_data = use_3p ? three_dbg_rs2_data : legacy_dbg_rs2_data;
    assign dbg_halted = use_3p ? three_dbg_halted : legacy_dbg_halted;
    assign wfi_sleep = use_3p ? three_wfi_sleep : legacy_wfi_sleep;
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
    assign trace_fetch_valid = use_3p ? 1'b0 : legacy_trace_fetch_valid;
    assign trace_fetch_pc = use_3p ? 64'd0 : legacy_trace_fetch_pc;
    assign trace_fetch_data = use_3p ? 64'd0 : legacy_trace_fetch_data;
    assign trace_load_valid = use_3p ? 1'b0 : legacy_trace_load_valid;
    assign trace_load_pc = use_3p ? 64'd0 : legacy_trace_load_pc;
    assign trace_load_addr = use_3p ? 64'd0 : legacy_trace_load_addr;
    assign trace_load_rd = use_3p ? 5'd0 : legacy_trace_load_rd;
    assign trace_load_data = use_3p ? 64'd0 : legacy_trace_load_data;
    assign trace_store_valid = use_3p ? 1'b0 : legacy_trace_store_valid;
    assign trace_store_pc = use_3p ? 64'd0 : legacy_trace_store_pc;
    assign trace_store_addr = use_3p ? 64'd0 : legacy_trace_store_addr;
    assign trace_store_data = use_3p ? 64'd0 : legacy_trace_store_data;
    assign trace_store_wstrb = use_3p ? 8'd0 : legacy_trace_store_wstrb;

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
