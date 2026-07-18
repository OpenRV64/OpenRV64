`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"

// Fixed three-pipe, 256-bit AXI core boundary.
//
// Unlike openrv64_top, this module has no backend or bus selector at its
// external boundary.  Elaboration always selects fetch_3w, the EX0/EX1/MEM
// backend, and the 256-bit AXI bus.  The legacy blocking requester is tied off
// inside this wrapper and is not part of the module interface.
module openrv64_top_3p #(
    parameter [63:0] RESET_VECTOR = `OPENRV64_SOC_RESET_VECTOR,
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_RV64A = 1,
    parameter ENABLE_TRACE = 0,
    parameter ENABLE_PREDECODE_TARGETS = 1,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_STALL
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_arid,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arqos,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_rid,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output wire [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_awid,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awqos,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [`OPENRV64_AXI_STRB_WIDTH-1:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0]   m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    input  wire        irq_m_software,
    input  wire        irq_m_timer,
    input  wire        irq_m_external,
    input  wire        irq_s_software,
    input  wire        irq_s_timer,
    input  wire        irq_s_external,

    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire        dbg_halted,

    output wire [63:0]  trace_cycle,
    output wire [4:0]   trace_valid,
    output wire [4:0]   trace_stall,
    output wire [4:0]   trace_flush,
    output wire [4:0]   trace_advance,
    output wire [319:0] trace_ids,
    output wire [319:0] trace_pcs,
    output wire [159:0] trace_instrs,
    output wire [7:0]   trace_events,
    output wire [7:0]   trace_stall_causes,
    output wire         trace_retire_valid,
    output wire         trace_retire_arch,
    output wire         trace_retire_exception,
    output wire [4:0]   trace_retire_cause,
    output wire [63:0]  trace_retire_next_pc,
    output wire         trace_retire_rd_write,
    output wire [4:0]   trace_retire_rd,
    output wire [63:0]  trace_retire_wdata
);

    wire        unused_mem_valid;
    wire        unused_mem_write;
    wire [63:0] unused_mem_addr;
    wire [63:0] unused_mem_wdata;
    wire [7:0]  unused_mem_wstrb;

    openrv64_rv64_top_3p #(
        .RESET_VECTOR(RESET_VECTOR),
        .BUS_CONFIG(`OPENRV64_BUS_AXI),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .ENABLE_TRACE(ENABLE_TRACE),
        .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
        .BP_TYPE(BP_TYPE)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .mem_valid(unused_mem_valid), .mem_ready(1'b0),
        .mem_write(unused_mem_write), .mem_addr(unused_mem_addr),
        .mem_wdata(unused_mem_wdata), .mem_wstrb(unused_mem_wstrb),
        .mem_rdata(64'd0), .mem_error(1'b0),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb_axi(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .irq_m_software(irq_m_software), .irq_m_timer(irq_m_timer),
        .irq_m_external(irq_m_external),
        .irq_s_software(irq_s_software), .irq_s_timer(irq_s_timer),
        .irq_s_external(irq_s_external),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle), .trace_valid(trace_valid),
        .trace_stall(trace_stall), .trace_flush(trace_flush),
        .trace_advance(trace_advance), .trace_ids(trace_ids),
        .trace_pcs(trace_pcs), .trace_instrs(trace_instrs),
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

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && (unused_mem_valid || unused_mem_write ||
                      (|unused_mem_addr) || (|unused_mem_wdata) ||
                      (|unused_mem_wstrb)))
            $fatal(1, "openrv64_top_3p: generic bus active in AXI geometry");
    end
`endif

endmodule
