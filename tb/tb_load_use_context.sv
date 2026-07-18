`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_load_use_context;

    localparam integer MEM_WORDS = 64;

    logic clk;
    logic rst_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic mem_addr_in_range;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && !mem_write && mem_addr_in_range) ?
                       memory[mem_addr[8:3]] : 64'h0;

    openrv64_top #(
        .RESET_VECTOR(64'h0),
        .ENABLE_FORWARDING(1'b1),
        .ENABLE_LOAD_FORWARDING(1'b0)
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
        .mem_error(1'b0),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic put_instr;
        input integer instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0]) begin
                memory[instr_index >> 1][63:32] = instr;
            end else begin
                memory[instr_index >> 1][31:0] = instr;
            end
        end
    endtask

    function automatic logic [31:0] enc_addi;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_ld;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_ld = {imm, rs1, `RV64_FUNCT3_LD,
                      rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic logic [31:0] enc_lw;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_lw = {imm, rs1, `RV64_FUNCT3_LW,
                      rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic logic [31:0] enc_add;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        begin
            enc_add = {7'b0000000, rs2, rs1, `RV64_FUNCT3_ADD_SUB,
                       rd, `RV64_OPCODE_OP};
        end
    endfunction

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD,
                      imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_beq;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [12:0] imm;
        begin
            enc_beq = {imm[12], imm[10:5], rs2, rs1,
                       `RV64_FUNCT3_BEQ, imm[4:1], imm[11],
                       `RV64_OPCODE_BRANCH};
        end
    endfunction

    initial begin
        integer index;

        for (index = 0; index < MEM_WORDS; index = index + 1) begin
            memory[index] = 64'h0;
        end

        // Each load is followed immediately by a different consumer class.
        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(1, enc_ld(5'd5, 5'd1, 12'd0));
        put_instr(2, enc_addi(5'd5, 5'd5, 12'd1));       // ALU
        put_instr(3, enc_ld(5'd6, 5'd1, 12'd8));
        put_instr(4, enc_beq(5'd6, 5'd5, 13'd8));        // branch
        put_instr(5, enc_addi(5'd10, `RV64_REG_X0, 12'd1));
        put_instr(6, enc_ld(5'd7, 5'd1, 12'd16));
        put_instr(7, enc_sd(5'd7, 5'd1, 12'd32));        // store data
        put_instr(8, enc_ld(5'd8, 5'd1, 12'd24));
        put_instr(9, enc_ld(5'd9, 5'd8, 12'd0));         // LSU address
        // Reproduce GCC's jump-table dependency: the load uses and replaces
        // its base register, then the ALU immediately consumes that result.
        put_instr(10, enc_addi(5'd17, `RV64_REG_X0, 12'h140));
        put_instr(11, enc_addi(5'd15, `RV64_REG_X0, 12'd0));
        put_instr(12, enc_add(5'd15, 5'd15, 5'd17));
        put_instr(13, enc_lw(5'd15, 5'd15, 12'd0));
        put_instr(14, enc_add(5'd15, 5'd15, 5'd17));
        put_instr(15, `RV64_INSTR_EBREAK);

        memory[32] = 64'd41;
        memory[33] = 64'd42;
        memory[34] = 64'hdead_beef_0123_4567;
        memory[35] = 64'h0000_0000_0000_0130;
        memory[38] = 64'h1234_5678_9abc_def0;
        memory[40] = 64'h0000_0000_ffff_ff10;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        integer lane;

        if (rst_n && mem_valid) begin
            if (!mem_addr_in_range) begin
                $fatal(1, "load-use test address out of range: %016x", mem_addr);
            end
            if (mem_write) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (mem_wstrb[lane]) begin
                        memory[mem_addr[8:3]][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;
            if ((dbg_pc != 64'h3c) || (dbg_instr != `RV64_INSTR_EBREAK)) begin
                $fatal(1, "load-use halt mismatch pc=%016x instr=%08x",
                       dbg_pc, dbg_instr);
            end
            if ((dut.u_core.u_gpr.regs[5] != 64'd42) ||
                (dut.u_core.u_gpr.regs[6] != 64'd42) ||
                (dut.u_core.u_gpr.regs[10] != 64'd0) ||
                (memory[36] != 64'hdead_beef_0123_4567) ||
                (dut.u_core.u_gpr.regs[9] != 64'h1234_5678_9abc_def0) ||
                (dut.u_core.u_gpr.regs[15] != 64'h0000_0000_0000_0050)) begin
                $fatal(1,
                       "load-use results x5=%x x6=%x x10=%x store=%x x9=%x x15=%x",
                       dut.u_core.u_gpr.regs[5], dut.u_core.u_gpr.regs[6],
                       dut.u_core.u_gpr.regs[10], memory[36],
                       dut.u_core.u_gpr.regs[9], dut.u_core.u_gpr.regs[15]);
            end
            $display("PASS: load writeback interlocks ALU, branch, store, and LSU consumers");
            $finish;
        end
    end

    initial begin
        repeat (1024) @(posedge clk);
        $fatal(1, "timeout waiting for load-use context");
    end

endmodule
