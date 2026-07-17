`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module tb_priv_context;

    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam int unsigned MEM_WORDS = 64;

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
    logic saw_mret;
    logic saw_sret;
    logic saw_s_trap;
    logic saw_m_trap;
    logic [31:0] illegal_u_instr;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[8:3]] : 64'h0;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(1'b0)
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
        input int unsigned instr_index;
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

    function automatic logic [31:0] enc_slli;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [5:0] shamt;
        begin
            enc_slli = {`RV64_FUNCT6_SLLI, shamt, rs1,
                        `RV64_FUNCT3_SLL, rd, `RV64_OPCODE_OP_IMM};
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
        int i;

        for (i = 0; i < MEM_WORDS; i++) begin
            memory[i] = 64'h0;
        end

        // M-mode setup: permit all physical memory, delegate U ECALL to S,
        // then enter the supervisor bootstrap at 0x40.
        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'hfff));
        put_instr(1, enc_csr(`RV64_CSR_PMPADDR0, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(2, enc_addi(5'd1, `RV64_REG_X0, 12'h01f));
        put_instr(3, enc_csr(`RV64_CSR_PMPCFG0, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(4, enc_addi(5'd1, `RV64_REG_X0, 12'h080));
        put_instr(5, enc_csr(`RV64_CSR_STVEC, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(6, enc_addi(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(7, enc_csr(`RV64_CSR_MTVEC, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(8, enc_addi(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(9, enc_csr(`RV64_CSR_MEDELEG, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(10, enc_addi(5'd1, `RV64_REG_X0, 12'h040));
        put_instr(11, enc_csr(`RV64_CSR_MEPC, 5'd1,
                              `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(12, enc_addi(5'd1, `RV64_REG_X0, 12'h001));
        put_instr(13, enc_slli(5'd1, 5'd1, 6'd11));
        put_instr(14, enc_csr(`RV64_CSR_MSTATUS, 5'd1,
                              `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(15, `RV64_INSTR_MRET);

        // S-mode bootstrap enters U-mode at 0x60.
        put_instr(16, enc_addi(5'd1, `RV64_REG_X0, 12'h060));
        put_instr(17, enc_csr(`RV64_CSR_SEPC, 5'd1,
                              `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(18, `RV64_INSTR_SRET);
        put_instr(19, `RV64_INSTR_EBREAK);

        // U-mode makes a delegated environment call, then attempts an
        // M-mode CSR read. The latter must raise an illegal instruction.
        put_instr(24, enc_addi(5'd3, `RV64_REG_X0, 12'h055));
        put_instr(25, `RV64_INSTR_ECALL);
        illegal_u_instr = enc_csr(`RV64_CSR_MSTATUS, `RV64_REG_X0,
                                  `RV64_ZICSR_FUNCT3_CSRRS, 5'd4);
        put_instr(26, illegal_u_instr);
        put_instr(27, `RV64_INSTR_EBREAK);

        // S-mode handler records its context, skips ECALL, and returns to U.
        put_instr(32, enc_csr(`RV64_CSR_SEPC, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd5));
        put_instr(33, enc_sd(5'd5, `RV64_REG_X0, 12'h180));
        put_instr(34, enc_csr(`RV64_CSR_SCAUSE, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd6));
        put_instr(35, enc_sd(5'd6, `RV64_REG_X0, 12'h188));
        put_instr(36, enc_addi(5'd5, 5'd5, 12'd4));
        put_instr(37, enc_csr(`RV64_CSR_SEPC, 5'd5,
                              `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(38, `RV64_INSTR_SRET);
        put_instr(39, `RV64_INSTR_EBREAK);

        // M-mode handler records the illegal U instruction context and halts.
        put_instr(64, enc_csr(`RV64_CSR_MEPC, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd7));
        put_instr(65, enc_sd(5'd7, `RV64_REG_X0, 12'h190));
        put_instr(66, enc_csr(`RV64_CSR_MCAUSE, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd8));
        put_instr(67, enc_sd(5'd8, `RV64_REG_X0, 12'h198));
        put_instr(68, enc_csr(`RV64_CSR_MTVAL, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd9));
        put_instr(69, enc_sd(5'd9, `RV64_REG_X0, 12'h1a0));
        put_instr(70, `RV64_INSTR_EBREAK);

        saw_mret = 1'b0;
        saw_sret = 1'b0;
        saw_s_trap = 1'b0;
        saw_m_trap = 1'b0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.u_core.hard_flush_mret_req) begin
                saw_mret <= 1'b1;
            end
            if (dut.u_core.hard_flush_sret_req) begin
                saw_sret <= 1'b1;
            end
            if (dut.u_core.hard_flush_trap_req &&
                dut.u_core.csr_trap_to_s) begin
                saw_s_trap <= 1'b1;
            end
            if (dut.u_core.hard_flush_trap_req &&
                !dut.u_core.csr_trap_to_s) begin
                saw_m_trap <= 1'b1;
            end

            if (mem_valid) begin
                int lane;

                if (!mem_addr_in_range || mem_addr[2:0] != 3'b000) begin
                    $fatal(1, "invalid memory address: %016x", mem_addr);
                end

                if (mem_write) begin
                    if (mem_wstrb != 8'hff) begin
                        $fatal(1, "unexpected store strobes: %02x", mem_wstrb);
                    end
                    for (lane = 0; lane < 8; lane++) begin
                        if (mem_wstrb[lane]) begin
                            memory[mem_addr[8:3]][8*lane +: 8] <=
                                mem_wdata[8*lane +: 8];
                        end
                    end
                end else if (mem_wstrb != 8'h00) begin
                    $fatal(1, "unexpected fetch strobes: %02x", mem_wstrb);
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;

            if (!saw_mret || !saw_sret || !saw_s_trap || !saw_m_trap) begin
                $fatal(1, "missing privilege transition: mret=%0b sret=%0b s_trap=%0b m_trap=%0b",
                       saw_mret, saw_sret, saw_s_trap, saw_m_trap);
            end
            if (dut.u_core.u_csrs.priv_mode_q != `RV64_PRIV_M) begin
                $fatal(1, "final privilege is not M-mode");
            end
            if (dbg_pc != 64'h118 || dbg_instr != `RV64_INSTR_EBREAK) begin
                $fatal(1, "halt context mismatch: pc=%016x instr=%08x",
                       dbg_pc, dbg_instr);
            end
            if (memory[48] != 64'h64 || memory[49] != 64'd8) begin
                $fatal(1, "S trap context mismatch: sepc=%016x scause=%016x",
                       memory[48], memory[49]);
            end
            if (memory[50] != 64'h68 || memory[51] != 64'd2 ||
                memory[52] != {32'd0, illegal_u_instr}) begin
                $fatal(1, "M trap context mismatch: mepc=%016x mcause=%016x mtval=%016x",
                       memory[50], memory[51], memory[52]);
            end

            $display("PASS: M->S->U transitions, delegated U ECALL, SRET, and U CSR fault");
            $finish;
        end
    end

    initial begin
        repeat (1200) @(posedge clk);
        $fatal(1, "timeout waiting for privilege context flow");
    end

endmodule
