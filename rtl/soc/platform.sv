`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "core/exec/bp/defs.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"

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
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter bit ENABLE_RV64M = 1'b0,
    parameter bit ENABLE_RV64A = 1'b1,
    parameter bit ENABLE_FORWARDING = 1'b1,
    parameter bit ENABLE_LOAD_FORWARDING = 1'b0,
    parameter bit ENABLE_TRACE = 1'b0,
    parameter bit ENABLE_PREDECODE_TARGETS = 1'b1,
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_STALL
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
    logic [0:0] plic_meip;
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
        .BUS_CONFIG(`OPENRV64_BUS_GEN),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .ENABLE_TRACE(ENABLE_TRACE),
        .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS),
        .BP_TYPE(BP_TYPE)
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
        .irq_m_software(clint_msip[0]),
        .irq_m_timer(clint_mtip[0]),
        .irq_m_external(plic_meip[0]),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
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

    openrv64_soc_bus_decode u_bus (
        .mem_valid_i(core_mem_valid && core_rst_no),
        .mem_ready_o(core_mem_ready),
        .mem_write_i(core_mem_write),
        .mem_addr_i(core_mem_addr),
        .mem_wdata_i(core_mem_wdata),
        .mem_wstrb_i(core_mem_wstrb),
        .mem_rdata_o(core_mem_rdata),
        .mem_error_o(core_mem_error),
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

    openrv64_soc_memory u_memory (
        .clk_i(clk_i),
        .rst_ni(soc_rst_no),
        .mem_valid_i(memory_valid),
        .mem_ready_o(memory_ready),
        .mem_write_i(memory_write),
        .mem_addr_i(memory_addr),
        .mem_wdata_i(memory_wdata),
        .mem_wstrb_i(memory_wstrb),
        .mem_rdata_o(memory_rdata)
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
        .meip_o(plic_meip)
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
