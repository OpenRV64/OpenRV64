`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module tb_atomic_context;
    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam int unsigned MEM_WORDS = 96;

    logic clk, rst_n;
    logic mem_valid, mem_ready, mem_write;
    logic [63:0] mem_addr, mem_wdata, mem_rdata;
    logic [7:0] mem_wstrb;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic mem_addr_in_range;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[9:3]] : 64'd0;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64A(1'b1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_write(mem_write), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata), .mem_error(1'b0),
        .irq_m_software(1'b0), .irq_m_timer(1'b0),
        .irq_m_external(1'b0), .irq_s_software(1'b0),
        .irq_s_timer(1'b0), .irq_s_external(1'b0),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_halted(dbg_halted)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic put_instr;
        input int unsigned instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0]) memory[instr_index >> 1][63:32] = instr;
            else memory[instr_index >> 1][31:0] = instr;
        end
    endtask

    function automatic logic [31:0] enc_addi;
        input logic [4:0] rd, rs1;
        input logic [11:0] imm;
        begin
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2, rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD,
                      imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_ld;
        input logic [4:0] rd, rs1;
        input logic [11:0] imm;
        begin
            enc_ld = {imm, rs1, `RV64_FUNCT3_LD,
                      rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic logic [31:0] enc_amo_d;
        input logic [4:0] funct5, rd, rs1, rs2;
        begin
            enc_amo_d = {funct5, 2'b00, rs2, rs1,
                         `RV64_AMO_FUNCT3_D, rd, `RV64_OPCODE_AMO};
        end
    endfunction

    function automatic logic [31:0] enc_csr;
        input logic [11:0] csr;
        input logic [4:0] rs1;
        input logic [2:0] funct3;
        input logic [4:0] rd;
        begin
            enc_csr = {csr, rs1, funct3, rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) memory[i] = 64'd0;

        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(1, enc_addi(5'd2, `RV64_REG_X0, 12'd5));
        put_instr(2, enc_sd(5'd2, 5'd1, 12'd0));
        put_instr(3, enc_amo_d(`RV64_AMO_FUNCT5_LR, 5'd3, 5'd1, 5'd0));
        put_instr(4, enc_addi(5'd4, `RV64_REG_X0, 12'd7));
        put_instr(5, enc_amo_d(`RV64_AMO_FUNCT5_SC, 5'd5, 5'd1, 5'd4));
        put_instr(6, enc_amo_d(`RV64_AMO_FUNCT5_SC, 5'd6, 5'd1, 5'd2));
        put_instr(7, enc_amo_d(`RV64_AMO_FUNCT5_ADD, 5'd7, 5'd1, 5'd2));
        put_instr(8, enc_ld(5'd8, 5'd1, 12'd0));
        put_instr(9, `RV64_INSTR_WFI);
        put_instr(10, enc_addi(5'd9, `RV64_REG_X0, 12'h080));
        put_instr(11, enc_csr(`RV64_CSR_MTVEC, 5'd9,
                              `RV64_ZICSR_FUNCT3_CSRRW,
                              `RV64_REG_X0));
        put_instr(12, enc_addi(5'd1, 5'd1, 12'd3));
        put_instr(13, enc_amo_d(`RV64_AMO_FUNCT5_ADD,
                                5'd10, 5'd1, 5'd2));
        put_instr(14, `RV64_INSTR_EBREAK);

        put_instr(32, enc_csr(`RV64_CSR_MCAUSE, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd11));
        put_instr(33, enc_csr(`RV64_CSR_MTVAL, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd12));
        put_instr(34, `RV64_INSTR_EBREAK);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        integer lane;
        if (rst_n && mem_valid) begin
            if (!mem_addr_in_range) $fatal(1, "memory address out of range: %x", mem_addr);
            if (mem_write) begin
                for (lane = 0; lane < 8; lane++) begin
                    if (mem_wstrb[lane])
                        memory[mem_addr[9:3]][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
                end
            end else if (mem_wstrb != 8'h00) begin
                $fatal(1, "read request carried strobes: %02x", mem_wstrb);
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;
            if (dbg_pc != 64'h88 || dbg_instr != `RV64_INSTR_EBREAK)
                $fatal(1, "halt mismatch pc=%x instr=%x", dbg_pc, dbg_instr);
            if (dut.u_core.u_gpr.regs[3] != 64'd5 ||
                dut.u_core.u_gpr.regs[5] != 64'd0 ||
                dut.u_core.u_gpr.regs[6] != 64'd1 ||
                dut.u_core.u_gpr.regs[7] != 64'd7 ||
                dut.u_core.u_gpr.regs[8] != 64'd12 ||
                dut.u_core.u_gpr.regs[11] !=
                    `RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED ||
                dut.u_core.u_gpr.regs[12] != 64'h103 ||
                memory[32] != 64'd12) begin
                $fatal(1,
                    "atomic context x3=%x x5=%x x6=%x x7=%x x8=%x mcause=%x mtval=%x mem=%x",
                    dut.u_core.u_gpr.regs[3], dut.u_core.u_gpr.regs[5],
                    dut.u_core.u_gpr.regs[6], dut.u_core.u_gpr.regs[7],
                    dut.u_core.u_gpr.regs[8], dut.u_core.u_gpr.regs[11],
                    dut.u_core.u_gpr.regs[12], memory[32]);
            end
            $display("PASS: integrated LR/SC, AMO, WFI hint, and AMO fault context");
            $finish;
        end
    end

    initial begin
        repeat (1024) @(posedge clk);
        $fatal(1, "timeout waiting for atomic context");
    end
endmodule
