`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"

module tb_trap_context;

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

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[8:3]] : 64'h0;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(1'b0),
        .PIPE_1P_DECODE_QUEUE(1'b1)
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

        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'h040));
        put_instr(1, enc_csr(`RV64_CSR_MTVEC, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(2, `RV64_INSTR_ECALL);
        put_instr(3, `RV64_INSTR_EBREAK);

        put_instr(16, enc_csr(`RV64_CSR_MEPC, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd2));
        put_instr(17, enc_csr(`RV64_CSR_MCAUSE, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd3));
        put_instr(18, enc_sd(5'd2, `RV64_REG_X0, 12'h080));
        put_instr(19, enc_sd(5'd3, `RV64_REG_X0, 12'h088));
        put_instr(20, enc_addi(5'd2, 5'd2, 12'd4));
        put_instr(21, enc_csr(`RV64_CSR_MEPC, 5'd2,
                              `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(22, `RV64_INSTR_MRET);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            int lane;

            if (mem_addr[2:0] != 3'b000 || !mem_addr_in_range) begin
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

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;

            if (dbg_pc != 64'h0000_0000_0000_000c ||
                dbg_instr != `RV64_INSTR_EBREAK) begin
                $fatal(1, "halt context mismatch: pc=%016x instr=%08x",
                       dbg_pc, dbg_instr);
            end

            if (memory[16] != 64'h0000_0000_0000_0008) begin
                $fatal(1, "mepc save mismatch: %016x", memory[16]);
            end

            if (memory[17] != 64'h0000_0000_0000_000b) begin
                $fatal(1, "mcause save mismatch: %016x", memory[17]);
            end

            $display("PASS: ECALL context save, handler CSR access, and MRET");
            $finish;
        end
    end

    initial begin
        repeat (768) @(posedge clk);
        $fatal(1, "timeout waiting for trap handler return");
    end

endmodule
