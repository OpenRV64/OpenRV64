`timescale 1ns/1ps

module tb_fpga_debug_exec;
    logic clk;
    logic rst_n;
    logic dbg_halted;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic saw_stub_fetch;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(1),
        .MEMORY_BYTES(1024 * 1024),
        .FPGA_DEBUG_ENABLE(1'b1),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(1'b1),
        .uart_tx_o(),
        .spi_card_present_i(1'b0),
        .spi_clk_o(),
        .spi_mosi_o(),
        .spi_miso_i(1'b1),
        .spi_cs_n_o(),
        .gpio_in_i(1'b0),
        .gpio_out_o(),
        .external_irq_i(29'd0),
        .debug_snapshot_read_index_i(9'd0),
        .debug_snapshot_read_req_toggle_i(1'b0),
        .debug_snapshot_read_ack_toggle_o(),
        .debug_snapshot_read_data_o(),
        .debug_snapshot_resume_toggle_i(1'b0),
        .debug_snapshot_trigger_ack_o(),
        .debug_snapshot_resume_pending_o(),
        .debug_trace_freeze_i(1'b0),
        .debug_stub_index_i(16'd0),
        .debug_stub_write_i(1'b0),
        .debug_stub_trace_read_i(1'b0),
        .debug_stub_wdata_i(64'd0),
        .debug_stub_req_toggle_i(1'b0),
        .debug_stub_ack_toggle_o(),
        .debug_stub_rdata_o(),
        .debug_uart_trace_index_i(11'd0),
        .debug_uart_trace_req_toggle_i(1'b0),
        .debug_uart_trace_ack_toggle_o(),
        .debug_uart_trace_rdata_o(),
        .debug_uart_trace_byte_count_o(),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [31:0] enc_lui(
        input logic [4:0] rd,
        input logic [19:0] immediate
    );
        enc_lui = {immediate, rd, 7'b0110111};
    endfunction

    function automatic logic [31:0] enc_addi(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [11:0] immediate
    );
        enc_addi = {immediate, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] enc_jalr(
        input logic [4:0] rd,
        input logic [4:0] rs1
    );
        enc_jalr = {12'd0, rs1, 3'b000, rd, 7'b1100111};
    endfunction

    function automatic logic [31:0] enc_slli31(
        input logic [4:0] rd,
        input logic [4:0] rs1
    );
        enc_slli31 = {6'b000000, 6'd31, rs1, 3'b001, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] enc_sd(
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [11:0] immediate
    );
        enc_sd = {immediate[11:5], rs2, rs1, 3'b011,
                  immediate[4:0], 7'b0100011};
    endfunction

    initial begin
        rst_n = 1'b0;
        saw_stub_fetch = 1'b0;

        // Boot ROM enters normal RAM at 0x80000000. The RAM program calls the
        // debug BRAM, then stores its return value at RAM byte offset 0x100.
        #1;
        dut.u_memory.memory_q[0] = {
            enc_jalr(5'd1, 5'd5), enc_lui(5'd5, 20'h0c304)};
        dut.u_memory.memory_q[1] = {
            enc_slli31(5'd6, 5'd6), enc_addi(5'd6, 5'd0, 12'd1)};
        dut.u_memory.memory_q[2] = {
            32'h0010_0073, enc_sd(5'd10, 5'd6, 12'h100)};

        // Stub: return 0x5a to the caller.
        dut.g_fpga_debug.u_stub_mem.stub_mem[0] = {
            enc_jalr(5'd0, 5'd1), enc_addi(5'd10, 5'd0, 12'h05a)};

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && dut.plic_valid && dut.plic_ready &&
            !dut.plic_write && dut.plic_addr == 64'h0030_4000)
            saw_stub_fetch <= 1'b1;

        if (rst_n && dbg_halted) begin
            #1;
            if (!saw_stub_fetch)
                $fatal(1, "core never fetched the debug stub mapping");
            if (dut.u_memory.memory_q[32] !== 64'h5a)
                $fatal(1, "debug stub return mismatch: %016x",
                       dut.u_memory.memory_q[32]);
            $display("PASS: 1P core executed the FPGA debug stub BRAM");
            $finish;
        end
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1, "FPGA debug exec timeout pc=%016x instr=%08x",
               dbg_pc, dbg_instr);
    end

endmodule
