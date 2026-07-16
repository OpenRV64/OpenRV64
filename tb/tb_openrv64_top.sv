`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_openrv64_top;

    localparam logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000;
    localparam int unsigned MEM_WORDS = 16;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic        dbg_halted;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic [63:0] pending_addr_q;
    logic        pending_q;

    assign mem_ready = pending_q;
    assign mem_rdata = pending_q ? memory[pending_addr_q[6:3]] :
                                   64'h0000_0000_0000_0000;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        int i;

        for (i = 0; i < MEM_WORDS; i++) begin
            memory[i] = 64'h0000_0000_0000_0000;
        end

        // Four 32-bit RV64 instructions packed little-endian on a 64-bit bus:
        //   0x0000: nop
        //   0x0004: nop
        //   0x0008: nop
        //   0x000c: ebreak
        memory[0] = {`RV64_INSTR_NOP, `RV64_INSTR_NOP};
        memory[1] = {`RV64_INSTR_EBREAK, `RV64_INSTR_NOP};

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q      <= 1'b0;
            pending_addr_q <= 64'h0000_0000_0000_0000;
        end else if (pending_q) begin
            pending_q <= 1'b0;
        end else if (mem_valid) begin
            pending_q      <= 1'b1;
            pending_addr_q <= mem_addr;
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            if (mem_write) begin
                $fatal(1, "unexpected write request");
            end

            if (mem_wstrb != 8'h00) begin
                $fatal(1, "unexpected write strobes: %02x", mem_wstrb);
            end

            if (mem_addr[2:0] != 3'b000) begin
                $fatal(1, "unaligned memory address: %016x", mem_addr);
            end

            if (mem_addr[63:3] >= MEM_WORDS) begin
                $fatal(1, "memory address out of range: %016x", mem_addr);
            end
        end

        if (rst_n && dbg_halted) begin
            if (dbg_pc != 64'h0000_0000_0000_000c) begin
                $fatal(1, "halt pc mismatch: %016x", dbg_pc);
            end

            if (dbg_instr != `RV64_INSTR_EBREAK) begin
                $fatal(1, "halt instruction mismatch: %08x", dbg_instr);
            end

            $display("PASS: halted at pc=%016x instr=%08x", dbg_pc, dbg_instr);
            $finish;
        end
    end

    initial begin
        repeat (64) @(posedge clk);
        $fatal(1, "timeout waiting for halt");
    end

endmodule
