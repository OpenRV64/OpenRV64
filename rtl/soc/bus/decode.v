`timescale 1ns/1ps
`include "soc/bus/mem_map.v"

// Address decoder and response mux for the OpenRV64 blocking memory bus.
//
// Targets receive target-local byte offsets. Requests outside every defined
// window complete with mem_error_o asserted and are not sent downstream.
module openrv64_soc_bus_decode #(
    parameter [63:0] MEMORY_SIZE = `OPENRV64_SOC_MEMORY_SIZE
) (
    // Upstream core/initiator bus.
    input  wire        mem_valid_i,
    output reg         mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output reg  [63:0] mem_rdata_o,
    output reg         mem_error_o,

    // Target-local boot ROM bus.
    output wire        rom_valid_o,
    input  wire        rom_ready_i,
    output wire        rom_write_o,
    output wire [63:0] rom_addr_o,
    output wire [63:0] rom_wdata_o,
    output wire [7:0]  rom_wstrb_o,
    input  wire [63:0] rom_rdata_i,

    // Target-local memory bus.
    output wire        memory_valid_o,
    input  wire        memory_ready_i,
    output wire        memory_write_o,
    output wire [63:0] memory_addr_o,
    output wire [63:0] memory_wdata_o,
    output wire [7:0]  memory_wstrb_o,
    input  wire [63:0] memory_rdata_i,

    // Target-local CLINT bus.
    output wire        clint_valid_o,
    input  wire        clint_ready_i,
    output wire        clint_write_o,
    output wire [63:0] clint_addr_o,
    output wire [63:0] clint_wdata_o,
    output wire [7:0]  clint_wstrb_o,
    input  wire [63:0] clint_rdata_i,

    // Target-local PLIC bus.
    output wire        plic_valid_o,
    input  wire        plic_ready_i,
    output wire        plic_write_o,
    output wire [63:0] plic_addr_o,
    output wire [63:0] plic_wdata_o,
    output wire [7:0]  plic_wstrb_o,
    input  wire [63:0] plic_rdata_i,

    // Target-local UART bus.
    output wire        uart_valid_o,
    input  wire        uart_ready_i,
    output wire        uart_write_o,
    output wire [63:0] uart_addr_o,
    output wire [63:0] uart_wdata_o,
    output wire [7:0]  uart_wstrb_o,
    input  wire [63:0] uart_rdata_i,

    // Target-local GPIO bus.
    output wire        gpio_valid_o,
    input  wire        gpio_ready_i,
    output wire        gpio_write_o,
    output wire [63:0] gpio_addr_o,
    output wire [63:0] gpio_wdata_o,
    output wire [7:0]  gpio_wstrb_o,
    input  wire [63:0] gpio_rdata_i,

    // Target-local general-purpose timer bus.
    output wire        timer_valid_o,
    input  wire        timer_ready_i,
    output wire        timer_write_o,
    output wire [63:0] timer_addr_o,
    output wire [63:0] timer_wdata_o,
    output wire [7:0]  timer_wstrb_o,
    input  wire [63:0] timer_rdata_i,

    // Target-local SPI boot-storage bus.
    output wire        spi_valid_o,
    input  wire        spi_ready_i,
    output wire        spi_write_o,
    output wire [63:0] spi_addr_o,
    output wire [63:0] spi_wdata_o,
    output wire [7:0]  spi_wstrb_o,
    input  wire [63:0] spi_rdata_i
);

    wire rom_selected =
        (mem_addr_i >= `OPENRV64_SOC_ROM_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_ROM_BASE +
                       `OPENRV64_SOC_ROM_SIZE));
    wire memory_selected =
        (mem_addr_i >= `OPENRV64_SOC_MEMORY_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_MEMORY_BASE +
                       MEMORY_SIZE));
    wire clint_selected =
        (mem_addr_i >= `OPENRV64_SOC_CLINT_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_CLINT_BASE +
                       `OPENRV64_SOC_CLINT_SIZE));
    wire plic_selected =
        (mem_addr_i >= `OPENRV64_SOC_PLIC_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_PLIC_BASE +
                       `OPENRV64_SOC_PLIC_SIZE));
    wire uart_selected =
        (mem_addr_i >= `OPENRV64_SOC_UART_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_UART_BASE +
                       `OPENRV64_SOC_UART_SIZE));
    wire gpio_selected =
        (mem_addr_i >= `OPENRV64_SOC_GPIO_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_GPIO_BASE +
                       `OPENRV64_SOC_GPIO_SIZE));
    wire timer_selected =
        (mem_addr_i >= `OPENRV64_SOC_TIMER_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_TIMER_BASE +
                       `OPENRV64_SOC_TIMER_SIZE));
    wire spi_selected =
        (mem_addr_i >= `OPENRV64_SOC_SPI_BASE) &&
        (mem_addr_i < (`OPENRV64_SOC_SPI_BASE +
                       `OPENRV64_SOC_SPI_SIZE));
    wire decode_failed = !(rom_selected || memory_selected || clint_selected ||
                           plic_selected || uart_selected ||
                           gpio_selected || timer_selected || spi_selected);

    assign rom_valid_o = mem_valid_i && rom_selected;
    assign rom_write_o = mem_write_i;
    assign rom_addr_o = mem_addr_i - `OPENRV64_SOC_ROM_BASE;
    assign rom_wdata_o = mem_wdata_i;
    assign rom_wstrb_o = mem_wstrb_i;

    assign memory_valid_o = mem_valid_i && memory_selected;
    assign memory_write_o = mem_write_i;
    assign memory_addr_o = mem_addr_i - `OPENRV64_SOC_MEMORY_BASE;
    assign memory_wdata_o = mem_wdata_i;
    assign memory_wstrb_o = mem_wstrb_i;

    assign clint_valid_o = mem_valid_i && clint_selected;
    assign clint_write_o = mem_write_i;
    assign clint_addr_o = mem_addr_i - `OPENRV64_SOC_CLINT_BASE;
    assign clint_wdata_o = mem_wdata_i;
    assign clint_wstrb_o = mem_wstrb_i;

    assign plic_valid_o = mem_valid_i && plic_selected;
    assign plic_write_o = mem_write_i;
    assign plic_addr_o = mem_addr_i - `OPENRV64_SOC_PLIC_BASE;
    assign plic_wdata_o = mem_wdata_i;
    assign plic_wstrb_o = mem_wstrb_i;

    assign uart_valid_o = mem_valid_i && uart_selected;
    assign uart_write_o = mem_write_i;
    assign uart_addr_o = mem_addr_i - `OPENRV64_SOC_UART_BASE;
    assign uart_wdata_o = mem_wdata_i;
    assign uart_wstrb_o = mem_wstrb_i;

    assign gpio_valid_o = mem_valid_i && gpio_selected;
    assign gpio_write_o = mem_write_i;
    assign gpio_addr_o = mem_addr_i - `OPENRV64_SOC_GPIO_BASE;
    assign gpio_wdata_o = mem_wdata_i;
    assign gpio_wstrb_o = mem_wstrb_i;

    assign timer_valid_o = mem_valid_i && timer_selected;
    assign timer_write_o = mem_write_i;
    assign timer_addr_o = mem_addr_i - `OPENRV64_SOC_TIMER_BASE;
    assign timer_wdata_o = mem_wdata_i;
    assign timer_wstrb_o = mem_wstrb_i;

    assign spi_valid_o = mem_valid_i && spi_selected;
    assign spi_write_o = mem_write_i;
    assign spi_addr_o = mem_addr_i - `OPENRV64_SOC_SPI_BASE;
    assign spi_wdata_o = mem_wdata_i;
    assign spi_wstrb_o = mem_wstrb_i;

    // The request address is held stable until ready, so it is also the
    // stable response-mux select for the complete transaction.
    always @* begin
        mem_ready_o = 1'b0;
        mem_rdata_o = 64'h0000_0000_0000_0000;
        mem_error_o = 1'b0;

        if (mem_valid_i) begin
            if (rom_selected) begin
                mem_ready_o = rom_ready_i;
                mem_rdata_o = rom_rdata_i;
            end else if (memory_selected) begin
                mem_ready_o = memory_ready_i;
                mem_rdata_o = memory_rdata_i;
            end else if (clint_selected) begin
                mem_ready_o = clint_ready_i;
                mem_rdata_o = clint_rdata_i;
            end else if (plic_selected) begin
                mem_ready_o = plic_ready_i;
                mem_rdata_o = plic_rdata_i;
            end else if (uart_selected) begin
                mem_ready_o = uart_ready_i;
                mem_rdata_o = uart_rdata_i;
            end else if (gpio_selected) begin
                mem_ready_o = gpio_ready_i;
                mem_rdata_o = gpio_rdata_i;
            end else if (timer_selected) begin
                mem_ready_o = timer_ready_i;
                mem_rdata_o = timer_rdata_i;
            end else if (spi_selected) begin
                mem_ready_o = spi_ready_i;
                mem_rdata_o = spi_rdata_i;
            end else if (decode_failed) begin
                // A decode error is itself a completed response. Returning
                // ready prevents an unmapped access from hanging the bus.
                mem_ready_o = 1'b1;
                mem_error_o = 1'b1;
            end
        end
    end

endmodule
