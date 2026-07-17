`timescale 1ns/1ps
`include "soc/bus/mem_map.v"

module tb_soc_bus_decode;

    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic        mem_error;

    logic        rom_valid;
    logic        rom_ready;
    logic        rom_write;
    logic [63:0] rom_addr;
    logic [63:0] rom_wdata;
    logic [7:0]  rom_wstrb;
    logic [63:0] rom_rdata;

    logic        memory_valid;
    logic        memory_ready;
    logic        memory_write;
    logic [63:0] memory_addr;
    logic [63:0] memory_wdata;
    logic [7:0]  memory_wstrb;
    logic [63:0] memory_rdata;

    logic        clint_valid;
    logic        clint_ready;
    logic        clint_write;
    logic [63:0] clint_addr;
    logic [63:0] clint_wdata;
    logic [7:0]  clint_wstrb;
    logic [63:0] clint_rdata;

    logic        plic_valid;
    logic        plic_ready;
    logic        plic_write;
    logic [63:0] plic_addr;
    logic [63:0] plic_wdata;
    logic [7:0]  plic_wstrb;
    logic [63:0] plic_rdata;

    logic        uart_valid;
    logic        uart_ready;
    logic        uart_write;
    logic [63:0] uart_addr;
    logic [63:0] uart_wdata;
    logic [7:0]  uart_wstrb;
    logic [63:0] uart_rdata;

    logic        gpio_valid;
    logic        gpio_ready;
    logic        gpio_write;
    logic [63:0] gpio_addr;
    logic [63:0] gpio_wdata;
    logic [7:0]  gpio_wstrb;
    logic [63:0] gpio_rdata;

    logic        timer_valid;
    logic        timer_ready;
    logic        timer_write;
    logic [63:0] timer_addr;
    logic [63:0] timer_wdata;
    logic [7:0]  timer_wstrb;
    logic [63:0] timer_rdata;

    openrv64_soc_bus_decode dut (
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .mem_error_o(mem_error),
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

    task automatic expect_route;
        input logic [63:0] address;
        input logic [6:0] expected_valids;
        input logic [63:0] expected_target_address;
        input logic [63:0] expected_read_data;
        input [8*56-1:0] label;
        logic [63:0] actual_target_address;
        begin
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = 64'h1122_3344_5566_7788;
            mem_wstrb = 8'ha5;
            #1;

            if ({memory_valid, rom_valid, timer_valid, gpio_valid,
                 uart_valid, plic_valid, clint_valid} !==
                expected_valids) begin
                $fatal(1, "%0s: routes=%07b, expected %07b",
                       label,
                       {memory_valid, rom_valid, timer_valid, gpio_valid,
                        uart_valid, plic_valid, clint_valid},
                       expected_valids);
            end

            case (expected_valids)
                7'b0000001: actual_target_address = clint_addr;
                7'b0000010: actual_target_address = plic_addr;
                7'b0000100: actual_target_address = uart_addr;
                7'b0001000: actual_target_address = gpio_addr;
                7'b0010000: actual_target_address = timer_addr;
                7'b0100000: actual_target_address = rom_addr;
                7'b1000000: actual_target_address = memory_addr;
                default: actual_target_address = 64'hx;
            endcase
            if (actual_target_address !== expected_target_address) begin
                $fatal(1, "%0s: target address=%016x, expected %016x",
                       label, actual_target_address, expected_target_address);
            end

            if (!mem_ready || mem_error ||
                mem_rdata !== expected_read_data) begin
                $fatal(1, "%0s: ready/data=%b/%016x, expected 1/%016x",
                       label, mem_ready, mem_rdata, expected_read_data);
            end

            if (!memory_write || !rom_write || !clint_write || !plic_write ||
                !uart_write || !gpio_write || !timer_write ||
                memory_wdata !== mem_wdata ||
                rom_wdata !== mem_wdata ||
                clint_wdata !== mem_wdata || plic_wdata !== mem_wdata ||
                uart_wdata !== mem_wdata || gpio_wdata !== mem_wdata ||
                timer_wdata !== mem_wdata ||
                memory_wstrb !== mem_wstrb ||
                rom_wstrb !== mem_wstrb ||
                clint_wstrb !== mem_wstrb || plic_wstrb !== mem_wstrb ||
                uart_wstrb !== mem_wstrb || gpio_wstrb !== mem_wstrb ||
                timer_wstrb !== mem_wstrb) begin
                $fatal(1, "%0s: request payload was not routed intact", label);
            end

            mem_valid = 1'b0;
            #1;
            if ({memory_valid, rom_valid, timer_valid, gpio_valid,
                 uart_valid, plic_valid, clint_valid} !== 7'b0000000 ||
                mem_ready || mem_error || mem_rdata !== 64'h0) begin
                $fatal(1, "%0s: inactive upstream request leaked downstream",
                       label);
            end
        end
    endtask

    task automatic expect_decode_error;
        input logic [63:0] address;
        input [8*56-1:0] label;
        begin
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            #1;
            if ({memory_valid, rom_valid, timer_valid, gpio_valid,
                 uart_valid, plic_valid, clint_valid} !== 7'b0000000) begin
                $fatal(1, "%0s: unmapped request reached a target", label);
            end
            if (!mem_ready || !mem_error || mem_rdata !== 64'h0) begin
                $fatal(1,
                       "%0s: error response ready/error/data=%b/%b/%016x",
                       label, mem_ready, mem_error, mem_rdata);
            end
            mem_valid = 1'b0;
            #1;
            if (mem_ready || mem_error || mem_rdata !== 64'h0) begin
                $fatal(1, "%0s: decode error persisted after valid", label);
            end
        end
    endtask

    initial begin
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        rom_ready = 1'b1;
        rom_rdata = 64'hb0b0_b0b0_b0b0_b0b0;
        memory_ready = 1'b1;
        memory_rdata = 64'h8181_8181_8181_8181;
        clint_ready = 1'b1;
        clint_rdata = 64'hc1c1_c1c1_c1c1_c1c1;
        plic_ready = 1'b1;
        plic_rdata = 64'h9191_9191_9191_9191;
        uart_ready = 1'b1;
        uart_rdata = 64'ha1a1_a1a1_a1a1_a1a1;
        gpio_ready = 1'b1;
        gpio_rdata = 64'h6161_6161_6161_6161;
        timer_ready = 1'b1;
        timer_rdata = 64'h7171_7171_7171_7171;
        #1;
        if (mem_ready || mem_error || mem_rdata !== 64'h0) begin
            $fatal(1, "inactive decoder produced a response");
        end

        expect_route(`OPENRV64_SOC_ROM_BASE,
                     7'b0100000, 64'h0, rom_rdata,
                     "ROM lower boundary");
        expect_route(`OPENRV64_SOC_ROM_BASE +
                     `OPENRV64_SOC_ROM_SIZE - 64'd1,
                     7'b0100000, `OPENRV64_SOC_ROM_SIZE - 64'd1,
                     rom_rdata, "ROM upper boundary");

        expect_route(`OPENRV64_SOC_MEMORY_BASE,
                     7'b1000000, 64'h0, memory_rdata,
                     "memory lower boundary");
        expect_route(`OPENRV64_SOC_MEMORY_BASE +
                     `OPENRV64_SOC_MEMORY_SIZE - 64'd1,
                     7'b1000000, `OPENRV64_SOC_MEMORY_SIZE - 64'd1,
                     memory_rdata, "memory upper boundary");

        expect_route(`OPENRV64_SOC_CLINT_BASE + 64'h4008,
                     7'b0000001, 64'h4008, clint_rdata,
                     "CLINT local address translation");
        expect_route(`OPENRV64_SOC_CLINT_BASE +
                     `OPENRV64_SOC_CLINT_SIZE - 64'd1,
                     7'b0000001, `OPENRV64_SOC_CLINT_SIZE - 64'd1,
                     clint_rdata, "CLINT upper boundary");

        expect_route(`OPENRV64_SOC_PLIC_BASE + 64'h20_0004,
                     7'b0000010, 64'h20_0004, plic_rdata,
                     "PLIC local address translation");
        expect_route(`OPENRV64_SOC_PLIC_BASE +
                     `OPENRV64_SOC_PLIC_SIZE - 64'd1,
                     7'b0000010, `OPENRV64_SOC_PLIC_SIZE - 64'd1,
                     plic_rdata, "PLIC upper boundary");

        expect_route(`OPENRV64_SOC_UART_BASE,
                     7'b0000100, 64'h0, uart_rdata,
                     "UART lower boundary");
        expect_route(`OPENRV64_SOC_UART_BASE +
                     `OPENRV64_SOC_UART_SIZE - 64'd1,
                     7'b0000100, `OPENRV64_SOC_UART_SIZE - 64'd1, uart_rdata,
                     "UART upper boundary");

        expect_route(`OPENRV64_SOC_GPIO_BASE + 64'h28,
                     7'b0001000, 64'h28, gpio_rdata,
                     "GPIO local address translation");
        expect_route(`OPENRV64_SOC_GPIO_BASE +
                     `OPENRV64_SOC_GPIO_SIZE - 64'd1,
                     7'b0001000, `OPENRV64_SOC_GPIO_SIZE - 64'd1,
                     gpio_rdata, "GPIO upper boundary");

        expect_route(`OPENRV64_SOC_TIMER_BASE + 64'h20,
                     7'b0010000, 64'h20, timer_rdata,
                     "timer local address translation");
        expect_route(`OPENRV64_SOC_TIMER_BASE +
                     `OPENRV64_SOC_TIMER_SIZE - 64'd1,
                     7'b0010000, `OPENRV64_SOC_TIMER_SIZE - 64'd1,
                     timer_rdata, "timer upper boundary");

        expect_decode_error(64'h0000_0000_0000_0000,
                            "unmapped low address");
        expect_decode_error(`OPENRV64_SOC_ROM_BASE - 64'd1,
                            "address before ROM window");
        expect_decode_error(`OPENRV64_SOC_ROM_BASE +
                            `OPENRV64_SOC_ROM_SIZE,
                            "address after ROM window");
        expect_decode_error(`OPENRV64_SOC_MEMORY_BASE - 64'd1,
                            "address before memory window");
        expect_decode_error(`OPENRV64_SOC_MEMORY_BASE +
                            `OPENRV64_SOC_MEMORY_SIZE,
                            "address after memory window");
        expect_decode_error(`OPENRV64_SOC_UART_BASE +
                            `OPENRV64_SOC_UART_SIZE,
                            "address after UART window");

        // Only the selected target may control upstream backpressure.
        mem_valid = 1'b1;
        mem_write = 1'b0;
        mem_addr = `OPENRV64_SOC_PLIC_BASE;
        plic_ready = 1'b0;
        #1;
        if (mem_ready || !plic_valid || mem_rdata !== plic_rdata) begin
            $fatal(1, "PLIC backpressure was not propagated");
        end
        plic_ready = 1'b1;
        #1;
        if (!mem_ready) begin
            $fatal(1, "PLIC response did not release upstream request");
        end

        mem_addr = `OPENRV64_SOC_UART_BASE;
        uart_ready = 1'b0;
        #1;
        if (mem_ready || mem_error || !uart_valid || plic_valid ||
            memory_valid) begin
            $fatal(1, "unselected ready inputs leaked into UART response");
        end

        mem_addr = `OPENRV64_SOC_TIMER_BASE;
        uart_ready = 1'b1;
        timer_ready = 1'b0;
        #1;
        if (mem_ready || mem_error || !timer_valid || uart_valid ||
            gpio_valid) begin
            $fatal(1, "timer backpressure or one-hot routing failed");
        end

        $display("tb_soc_bus_decode: PASS");
        $finish;
    end

endmodule
