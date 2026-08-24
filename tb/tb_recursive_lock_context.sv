`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

/*
 * Reproduce two single-hart recursive ticket-lock failures:
 *
 *   1. acquire the lock, then acquire it again directly;
 *   2. acquire the lock, take an illegal-instruction exception immediately,
 *      then acquire the same lock from the trap handler.
 *
 * A ticket lock is intentionally non-recursive. Both programs must allocate
 * ticket 1 while owner remains 0 and then retire the load/branch wait loop.
 * The testbench recognizes that bounded steady state and resets the core
 * between cases; the test programs themselves deliberately never complete.
 */
module tb_recursive_lock_context;
    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam int unsigned MEM_WORDS = 96;
    localparam logic [63:0] LOCK_ADDR = 64'h100;
    localparam logic [31:0] RECURSIVE_LOCKED_WORD = 32'h0002_0000;
    localparam logic [63:0] DIRECT_WAIT_PC = 64'h14;
    localparam logic [63:0] TRAP_WAIT_PC = 64'h88;

    logic clk;
    logic rst_n;
    wire mem_valid;
    wire mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire [63:0] mem_rdata;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire trace_retire_valid;
    wire trace_retire_arch;
    wire trace_retire_exception;
    wire [4:0] trace_retire_cause;
    wire [63:0] trace_retire_next_pc;
    logic [63:0] memory [0:MEM_WORDS-1];
    wire mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);

    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[9:3]] : 64'd0;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_RV64A(1'b1),
        .ENABLE_TRACE(1'b1)
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
        .icx_req_ready(1'b1),
        .icx_wdata_ready(1'b1),
        .icx_resp_valid(1'b0),
        .icx_resp_hart_id({`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}),
        .icx_resp_txn_id({`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}}),
        .icx_resp_source_id({`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}}),
        .icx_resp_beat_index({`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last(1'b0),
        .icx_resp_rdata({`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
        .icx_resp_error(1'b0),
        .icx_resp_sc_success(1'b0),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic put_instr;
        input int unsigned instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0])
                memory[instr_index >> 1][63:32] = instr;
            else
                memory[instr_index >> 1][31:0] = instr;
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

    function automatic logic [31:0] enc_lhu;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_lhu = {imm, rs1, `RV64_FUNCT3_LHU,
                       rd, `RV64_OPCODE_LOAD};
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

    function automatic logic [31:0] enc_csr;
        input logic [11:0] csr;
        input logic [4:0] rs1;
        input logic [2:0] funct3;
        input logic [4:0] rd;
        begin
            enc_csr = {csr, rs1, funct3, rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    function automatic logic [31:0] enc_amoadd_w_aq;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        begin
            enc_amoadd_w_aq = {
                `RV64_AMO_FUNCT5_ADD, 1'b1, 1'b0, rs2, rs1,
                `RV64_AMO_FUNCT3_W, rd, `RV64_OPCODE_AMO
            };
        end
    endfunction

    task automatic clear_memory;
        integer index;
        begin
            for (index = 0; index < MEM_WORDS; index = index + 1)
                memory[index] = 64'd0;
        end
    endtask

    task automatic load_direct_recursion;
        begin
            clear_memory();
            put_instr(0, enc_addi(5'd5, `RV64_REG_X0, LOCK_ADDR[11:0]));
            put_instr(1, enc_lui(5'd6, 20'h00010));
            put_instr(2, enc_amoadd_w_aq(5'd7, 5'd5, 5'd6));
            put_instr(3, enc_addi(5'd20, `RV64_REG_X0, 12'd1));
            put_instr(4, enc_amoadd_w_aq(5'd9, 5'd5, 5'd6));
            put_instr(5, enc_lhu(5'd10, 5'd5, 12'd0));
            put_instr(6, enc_beq(5'd10, `RV64_REG_X0, 13'h1ffc));
            put_instr(7, `RV64_INSTR_EBREAK);
        end
    endtask

    task automatic load_trap_recursion;
        begin
            clear_memory();
            put_instr(0, enc_addi(5'd5, `RV64_REG_X0, LOCK_ADDR[11:0]));
            put_instr(1, enc_lui(5'd6, 20'h00010));
            put_instr(2, enc_addi(5'd11, `RV64_REG_X0, 12'h080));
            put_instr(3, enc_csr(`RV64_CSR_MTVEC, 5'd11,
                                 `RV64_ZICSR_FUNCT3_CSRRW,
                                 `RV64_REG_X0));
            put_instr(4, enc_amoadd_w_aq(5'd7, 5'd5, 5'd6));
            put_instr(5, enc_addi(5'd20, `RV64_REG_X0, 12'd2));
            put_instr(6, 32'h0000_0000);
            put_instr(7, `RV64_INSTR_EBREAK);

            put_instr(32, enc_addi(5'd20, `RV64_REG_X0, 12'd3));
            put_instr(33, enc_amoadd_w_aq(5'd9, 5'd5, 5'd6));
            put_instr(34, enc_lhu(5'd10, 5'd5, 12'd0));
            put_instr(35, enc_beq(5'd10, `RV64_REG_X0, 13'h1ffc));
            put_instr(36, `RV64_INSTR_EBREAK);
        end
    endtask

    task automatic release_reset;
        begin
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic enter_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        integer lane;
        if (rst_n && mem_valid) begin
            if (!mem_addr_in_range)
                $fatal(1, "recursive-lock memory address out of range: %x",
                       mem_addr);
            if (mem_write)
                for (lane = 0; lane < 8; lane = lane + 1)
                    if (mem_wstrb[lane])
                        memory[mem_addr[9:3]][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
            // The 3P atomic sequencer carries the eventual RMW byte mask on
            // its read phase. mem_write remains the transaction qualifier, so
            // read strobes are deliberately ignored by this memory model.
        end
    end

    initial begin : run_cases
        integer cycles;
        integer wait_loop_retires;
        logic saw_illegal_trap;

        rst_n = 1'b0;
        load_direct_recursion();
        release_reset();

        wait_loop_retires = 0;
        for (cycles = 0;
             cycles < 1500 && wait_loop_retires < 8;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            if (dbg_halted)
                $fatal(1, "direct recursive acquisition reached EBREAK");
            if (trace_retire_valid && trace_retire_arch &&
                (trace_retire_next_pc == DIRECT_WAIT_PC))
                wait_loop_retires = wait_loop_retires + 1;
        end
        if (wait_loop_retires < 8 ||
            memory[LOCK_ADDR[9:3]][31:0] != RECURSIVE_LOCKED_WORD ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7] != 64'd0 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9] !=
                64'h0000_0000_0001_0000 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[20] != 64'd1)
            $fatal(1,
                "direct recursive state loops=%0d lock=%x first=%x second=%x marker=%x pc=%x",
                wait_loop_retires, memory[LOCK_ADDR[9:3]][31:0],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[20], dbg_pc);
        $display("PASS: direct recursive ticket acquisition blocks at owner=0 next=2");

        enter_reset();
        load_trap_recursion();
        release_reset();

        wait_loop_retires = 0;
        saw_illegal_trap = 1'b0;
        for (cycles = 0;
             cycles < 1500 && wait_loop_retires < 8;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            if (dbg_halted)
                $fatal(1, "trap recursive acquisition reached EBREAK");
            if (trace_retire_valid && trace_retire_exception &&
                (trace_retire_cause ==
                 `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR))
                saw_illegal_trap = 1'b1;
            if (trace_retire_valid && trace_retire_arch &&
                (trace_retire_next_pc == TRAP_WAIT_PC))
                wait_loop_retires = wait_loop_retires + 1;
        end
        if (!saw_illegal_trap || wait_loop_retires < 8 ||
            memory[LOCK_ADDR[9:3]][31:0] != RECURSIVE_LOCKED_WORD ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7] != 64'd0 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9] !=
                64'h0000_0000_0001_0000 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[20] != 64'd3 ||
            dut.g_backend_3p.u_core_3p.u_csrs.mcause_q !=
                `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR ||
            dut.g_backend_3p.u_core_3p.u_csrs.mepc_q != 64'h18 ||
            dut.g_backend_3p.u_core_3p.u_csrs.mtval_q != 64'd0)
            $fatal(1,
                "trap recursive state trap=%0d loops=%0d lock=%x first=%x second=%x marker=%x mcause=%x mepc=%x mtval=%x pc=%x",
                saw_illegal_trap, wait_loop_retires,
                memory[LOCK_ADDR[9:3]][31:0],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[20],
                dut.g_backend_3p.u_core_3p.u_csrs.mcause_q,
                dut.g_backend_3p.u_core_3p.u_csrs.mepc_q,
                dut.g_backend_3p.u_core_3p.u_csrs.mtval_q, dbg_pc);
        $display("PASS: exception handler recursively acquiring held ticket lock blocks at owner=0 next=2");
        $finish;
    end
endmodule
