`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module tb_ptw_context;

    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam int unsigned MEM_WORDS = 2048;

    logic clk;
    logic rst_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic mem_addr_in_range;
    logic saw_ptw_read;
    logic saw_translated_fetch;
    logic saw_sfence;
    logic saw_load_page_fault;
    logic [63:0] load_page_fault_tval;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[13:3]] : 64'd0;
    assign mem_error = mem_valid && !mem_addr_in_range;

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
        .mem_error(mem_error),
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
        input logic [63:0] byte_addr;
        input logic [31:0] instr;
        begin
            if (byte_addr[2]) begin
                memory[byte_addr[13:3]][63:32] = instr;
            end else begin
                memory[byte_addr[13:3]][31:0] = instr;
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

    function automatic logic [31:0] enc_lui;
        input logic [4:0] rd;
        input logic [19:0] imm;
        begin
            enc_lui = {imm, rd, `RV64_OPCODE_LUI};
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

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD,
                      imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_csrrw;
        input logic [11:0] csr;
        input logic [4:0] rs1;
        begin
            enc_csrrw = {csr, rs1, `RV64_ZICSR_FUNCT3_CSRRW,
                         `RV64_REG_X0, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    integer lane;
    always @(posedge clk) begin
        if (rst_n && mem_valid && mem_ready && mem_write &&
            mem_addr_in_range) begin
            for (lane = 0; lane < 8; lane = lane + 1) begin
                if (mem_wstrb[lane]) begin
                    memory[mem_addr[13:3]][lane * 8 +: 8] <=
                        mem_wdata[lane * 8 +: 8];
                end
            end
        end

        if (rst_n && mem_valid && !mem_write &&
            (mem_addr == 64'h0000_0000_0000_1008)) begin
            saw_ptw_read <= 1'b1;
        end
        if (rst_n && mem_valid && !mem_write &&
            (mem_addr == 64'h0000_0000_0000_2000)) begin
            saw_translated_fetch <= 1'b1;
        end
        if (rst_n && dut.u_core.retire_sfence_vma) begin
            saw_sfence <= 1'b1;
        end
        if (rst_n && dut.u_core.trap_enter &&
            !dut.u_core.trap_interrupt &&
            (dut.u_core.trap_cause ==
             `RV64_EXCEPT_CAUSE_LOAD_PAGE_FAULT)) begin
            saw_load_page_fault <= 1'b1;
            load_page_fault_tval <= dut.u_core.trap_tval;
        end
    end

    initial begin
        integer i;
        integer cycles;

        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            memory[i] = 64'd0;
        end

        // M-mode establishes a physical PMP window, installs satp, and enters
        // S-mode at virtual 0x40002000.
        put_instr(64'h0000, enc_ld(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(64'h0004, enc_csrrw(`RV64_CSR_PMPADDR0, 5'd1));
        put_instr(64'h0008, enc_addi(5'd2, `RV64_REG_X0, 12'h00f));
        put_instr(64'h000c, enc_csrrw(`RV64_CSR_PMPCFG0, 5'd2));
        put_instr(64'h0010, enc_ld(5'd3, `RV64_REG_X0, 12'h108));
        put_instr(64'h0014, enc_csrrw(`RV64_CSR_SATP, 5'd3));
        put_instr(64'h0018, enc_lui(5'd4, 20'h40002));
        put_instr(64'h001c, enc_csrrw(`RV64_CSR_MEPC, 5'd4));
        put_instr(64'h0020, enc_addi(5'd5, `RV64_REG_X0, 12'h400));
        put_instr(64'h0024, enc_csrrw(`RV64_CSR_MTVEC, 5'd5));
        put_instr(64'h0028, enc_ld(5'd6, `RV64_REG_X0, 12'h110));
        put_instr(64'h002c, enc_csrrw(`RV64_CSR_MSTATUS, 5'd6));
        put_instr(64'h0030, `RV64_INSTR_MRET);
        put_instr(64'h0034, `RV64_INSTR_EBREAK);

        // Machine trap handler.
        put_instr(64'h0400, `RV64_INSTR_EBREAK);

        // The Sv39 root entry is a 1 GiB R/W/X leaf mapping VPN[2]=1 to
        // physical address zero. A and D are already set (Svade policy).
        memory[64'h1008 >> 3] = 64'h0000_0000_0000_00cf;

        // Supervisor program: translated fetch, translated store, full TLB
        // shootdown, then an unmapped load that raises a page fault.
        put_instr(64'h2000, enc_addi(5'd7, `RV64_REG_X0, 12'd42));
        put_instr(64'h2004, enc_lui(5'd8, 20'h40003));
        put_instr(64'h2008, enc_sd(5'd7, 5'd8, 12'd0));
        put_instr(64'h200c, `RV64_INSTR_SFENCE_VMA_MATCH);
        put_instr(64'h2010, enc_ld(5'd9, `RV64_REG_X0, 12'd0));
        put_instr(64'h2014, `RV64_INSTR_EBREAK);

        memory[64'h100 >> 3] = 64'h0000_0000_0000_1000;
        memory[64'h108 >> 3] = 64'h8000_0000_0000_0001;
        memory[64'h110 >> 3] = 64'h0000_0000_0000_0800;

        saw_ptw_read = 1'b0;
        saw_translated_fetch = 1'b0;
        saw_sfence = 1'b0;
        saw_load_page_fault = 1'b0;
        load_page_fault_tval = 64'hffff_ffff_ffff_ffff;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        cycles = 0;
        while (!dbg_halted && cycles < 600) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;

        if (!dbg_halted) begin
            $fatal(1, "Sv39 context program timed out at pc=%016x instr=%08x",
                   dbg_pc, dbg_instr);
        end
        if (!saw_ptw_read || !saw_translated_fetch || !saw_sfence) begin
            $fatal(1, "missing PTW/fetch/SFENCE observations: %0b/%0b/%0b",
                   saw_ptw_read, saw_translated_fetch, saw_sfence);
        end
        if (memory[64'h3000 >> 3] != 64'd42) begin
            $fatal(1, "translated supervisor store mismatch: %016x",
                   memory[64'h3000 >> 3]);
        end
        if (!saw_load_page_fault || load_page_fault_tval != 64'd0) begin
            $fatal(1, "load page-fault context mismatch: seen=%0b tval=%016x",
                   saw_load_page_fault, load_page_fault_tval);
        end

        $display("PASS: satp, Sv39 PTW, physical PMP, SFENCE.VMA, and page-fault context");
        $finish;
    end

endmodule
