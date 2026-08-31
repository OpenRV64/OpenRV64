`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/exec/bp/defs.v"

module tb_load_use_context #(
    parameter bit DEBUG_SERIALIZE_ALL_1P = 1'b0,
    parameter bit BANKED_GPR = 1'b1
);

`ifdef OPENRV64_LOAD_USE_NETLIST
    // Vivado's standalone functional model presents this checkpoint's fetch
    // and debug PCs relative to its configured reset window.  The linked FPGA
    // design still runs with the architectural RESET_VECTOR supplied to the
    // core during Yosys elaboration.
    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam logic [63:0] MEMORY_IMAGE_BASE = 64'h0;
`else
    localparam logic [63:0] RESET_VECTOR = 64'h0;
    localparam logic [63:0] MEMORY_IMAGE_BASE = RESET_VECTOR;
`endif
    localparam integer MEM_WORDS = 1024;
    localparam integer PROGRAM_BASE_INDEX = 8;
    localparam logic [63:0] PROGRAM_BASE_PC = 64'h20;
    localparam logic [63:0] DATA_MEMORY_BASE = 64'h8000_0000;

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
    logic [63:0] dbg_rs1_data;
    logic [63:0] dbg_rs2_data;
    logic dbg_halted;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic trace_retire_valid;
    logic [63:0] trace_retire_next_pc;
    logic trace_retire_rd_write;
    logic [4:0] trace_retire_rd;
    logic [63:0] trace_retire_wdata;
    logic saw_strcmp_branch_q;
    logic saw_strcmp_sub_q;
    logic saw_strcmp_debug_operands_q;
    logic [63:0] strcmp_sub_result_q;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic mem_addr_in_range;
    logic mem_fast_instruction;
    logic [$clog2(MEM_WORDS)-1:0] mem_array_index;
    logic mem_pending_q;
    logic [1:0] mem_wait_q;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS) ||
        ((mem_addr >= DATA_MEMORY_BASE) &&
         (mem_addr < (DATA_MEMORY_BASE + MEM_WORDS * 8)));
    assign mem_array_index = (mem_addr >= DATA_MEMORY_BASE) ?
        ((mem_addr - DATA_MEMORY_BASE) >> 3) : (mem_addr >> 3);
    // Match the FPGA's non-zero scalar-memory response latency.  The core
    // must keep the request stable while this counter runs; the scoreboard
    // must keep the load destination owned until writeback.
    assign mem_fast_instruction = mem_addr < 64'h100;
    assign mem_ready = mem_valid &&
        (mem_fast_instruction ||
         (mem_pending_q && (mem_wait_q == 2'd0)));
    assign mem_rdata = (mem_valid && !mem_write && mem_addr_in_range) ?
                       memory[mem_array_index] : 64'h0;

`ifdef OPENRV64_LOAD_USE_NETLIST
    openrv64_fpga_core dut (
`else
    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_FORWARDING(1'b1),
        .ENABLE_LOAD_FORWARDING(1'b0),
        .PIPE_1P_MEM_4_STAGE(1'b1),
        .PIPE_1P_DECODE_QUEUE(1'b1),
        .BANKED_GPR(BANKED_GPR),
        .FPGA_GPR_LUTRAM(!BANKED_GPR),
        .DEBUG_SERIALIZE_ALL_1P(DEBUG_SERIALIZE_ALL_1P),
        .ENABLE_TRACE(1'b1),
        .L1D_CACHEABLE_BASE(DATA_MEMORY_BASE),
        .L1D_CACHEABLE_SIZE(MEM_WORDS * 8),
        .BP_TYPE(`OPENRV64_BP_BIMODAL),
        .BP_RAS_ENABLE(1'b0),
        .BP_BIMODAL_ENTRIES(32)
    ) dut (
`endif
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
        .dbg_rs1_data(dbg_rs1_data),
        .dbg_rs2_data(dbg_rs2_data),
        .dbg_halted(dbg_halted),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

`ifndef OPENRV64_LOAD_USE_NETLIST
    generate
        if (DEBUG_SERIALIZE_ALL_1P) begin : g_check_debug_serialization
            always @(posedge clk) begin
                if (rst_n && dut.u_core.debug_serial_inflight_q &&
                    dut.u_core.instruction_issue_fire)
                    $fatal(1,
                           "serialized 1P mode issued while an instruction was in flight");
            end
        end
    endgenerate
`endif

    task automatic put_instr;
        input integer instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0]) begin
                memory[(MEMORY_IMAGE_BASE >> 3) +
                       (instr_index >> 1)][63:32] =
                    instr;
            end else begin
                memory[(MEMORY_IMAGE_BASE >> 3) +
                       (instr_index >> 1)][31:0] =
                    instr;
            end
        end
    endtask

`ifndef OPENRV64_LOAD_USE_NETLIST
    task automatic expect_gpr;
        input logic [4:0] addr;
        input logic [63:0] expected;
        begin
            #1;
            if (dut.u_core.u_gpr.regs[addr] !== expected)
                $fatal(1, "load-use x%0d mismatch got=%016x expected=%016x",
                       addr, dut.u_core.u_gpr.regs[addr], expected);
        end
    endtask
`endif

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
            enc_slli = {6'b000000, shamt, rs1, `RV64_FUNCT3_SLL,
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

    function automatic logic [31:0] enc_lbu;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_lbu = {imm, rs1, `RV64_FUNCT3_LBU,
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

    function automatic logic [31:0] enc_sub;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        begin
            enc_sub = {7'b0100000, rs2, rs1, `RV64_FUNCT3_ADD_SUB,
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

    function automatic logic [31:0] enc_bne;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [12:0] imm;
        begin
            enc_bne = {imm[12], imm[10:5], rs2, rs1,
                       `RV64_FUNCT3_BNE, imm[4:1], imm[11],
                       `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input logic [20:0] imm;
        begin
            enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12],
                       rd, `RV64_OPCODE_JAL};
        end
    endfunction

    function automatic logic [31:0] enc_jalr;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_jalr = {imm, rs1, `RV64_FUNCT3_JALR,
                        rd, `RV64_OPCODE_JALR};
        end
    endfunction

    initial begin
        integer index;

        for (index = 0; index < MEM_WORDS; index = index + 1) begin
            memory[index] = 64'h0;
        end

        // Exercise the exact missed FPGA control shape before the dependency
        // cases: a negative direct JAL in the upper word of a fetch beat.  A
        // dropped redirect reaches either poison EBREAK; the target path sets
        // x30 and rejoins at the normal program base.
        put_instr(0, enc_jal(`RV64_REG_X0, 21'd20));
        put_instr(1, `RV64_INSTR_EBREAK);
        put_instr(2, enc_addi(5'd30, `RV64_REG_X0, 12'd1));
        put_instr(3, enc_jal(`RV64_REG_X0, 21'd20));
        put_instr(4, `RV64_INSTR_EBREAK);
        put_instr(5, enc_jal(`RV64_REG_X0, 21'h1ffff4)); // -12
        put_instr(6, `RV64_INSTR_EBREAK);
        put_instr(7, `RV64_INSTR_NOP);

        // Each load is followed immediately by a different consumer class.
        put_instr(PROGRAM_BASE_INDEX + 0,
                  enc_addi(5'd1, `RV64_REG_X0, 12'h100));
        put_instr(PROGRAM_BASE_INDEX + 1, enc_ld(5'd5, 5'd1, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 2,
                  enc_addi(5'd5, 5'd5, 12'd1));           // ALU
        put_instr(PROGRAM_BASE_INDEX + 3, enc_ld(5'd6, 5'd1, 12'd8));
        put_instr(PROGRAM_BASE_INDEX + 4,
                  enc_beq(5'd6, 5'd5, 13'd8));            // branch
        put_instr(PROGRAM_BASE_INDEX + 5,
                  enc_addi(5'd10, `RV64_REG_X0, 12'd1));
        put_instr(PROGRAM_BASE_INDEX + 6, enc_ld(5'd7, 5'd1, 12'd16));
        put_instr(PROGRAM_BASE_INDEX + 7,
                  enc_sd(5'd7, 5'd1, 12'd32));            // store data
        put_instr(PROGRAM_BASE_INDEX + 8, enc_ld(5'd8, 5'd1, 12'd24));
        put_instr(PROGRAM_BASE_INDEX + 9,
                  enc_ld(5'd9, 5'd8, 12'd0));             // LSU address
        // Reproduce GCC's jump-table dependency: the load uses and replaces
        // its base register, then the ALU immediately consumes that result.
        put_instr(PROGRAM_BASE_INDEX + 10,
                  enc_addi(5'd17, `RV64_REG_X0, 12'h140));
        put_instr(PROGRAM_BASE_INDEX + 11,
                  enc_addi(5'd15, `RV64_REG_X0, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 12,
                  enc_add(5'd15, 5'd15, 5'd17));
        put_instr(PROGRAM_BASE_INDEX + 13,
                  enc_lw(5'd15, 5'd15, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 14,
                  enc_add(5'd15, 5'd15, 5'd17));
        // Reproduce the failing Linux call boundary.  strcmp reads two bytes,
        // branches to a SUB result, and immediately returns.  The caller then
        // consumes a0.  Redirect squash must not release the older SUB's a0
        // reservation before its writeback.
        put_instr(PROGRAM_BASE_INDEX + 15,
                  enc_addi(5'd20, `RV64_REG_X0, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 16,
                  enc_addi(5'd10, `RV64_REG_X0, 12'd1));
        put_instr(PROGRAM_BASE_INDEX + 17,
                  enc_slli(5'd10, 5'd10, 6'd31));
        put_instr(PROGRAM_BASE_INDEX + 18,
                  enc_addi(5'd11, 5'd10, 12'h1c0));
        put_instr(PROGRAM_BASE_INDEX + 19,
                  enc_addi(5'd10, 5'd10, 12'h180));
        put_instr(PROGRAM_BASE_INDEX + 20, enc_jal(5'd1, 21'd20));
        put_instr(PROGRAM_BASE_INDEX + 21,
                  enc_bne(5'd10, `RV64_REG_X0, 13'd12));
        put_instr(PROGRAM_BASE_INDEX + 22,
                  enc_addi(5'd20, `RV64_REG_X0, 12'd1));
        put_instr(PROGRAM_BASE_INDEX + 23,
                  enc_jal(`RV64_REG_X0, 21'd4));
        put_instr(PROGRAM_BASE_INDEX + 24, `RV64_INSTR_EBREAK);
        put_instr(PROGRAM_BASE_INDEX + 25,
                  enc_lbu(5'd5, 5'd10, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 26,
                  enc_lbu(5'd6, 5'd11, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 27,
                  enc_addi(5'd10, 5'd10, 12'd1));
        put_instr(PROGRAM_BASE_INDEX + 28,
                  enc_addi(5'd11, 5'd11, 12'd1));
        put_instr(PROGRAM_BASE_INDEX + 29,
                  enc_bne(5'd5, 5'd6, 13'd8));
        put_instr(PROGRAM_BASE_INDEX + 30,
                  enc_addi(5'd10, `RV64_REG_X0, 12'd0));
        put_instr(PROGRAM_BASE_INDEX + 31,
                  enc_sub(5'd10, 5'd5, 5'd6));
        put_instr(PROGRAM_BASE_INDEX + 32,
                  enc_jalr(`RV64_REG_X0, 5'd1, 12'd0));

        memory[32] = 64'd41;
        memory[33] = 64'd42;
        memory[34] = 64'hdead_beef_0123_4567;
        memory[35] = 64'h0000_0000_0000_0130;
        memory[38] = 64'h1234_5678_9abc_def0;
        memory[40] = 64'h0000_0000_ffff_ff10;
        memory[48] = 64'h0000_0000_0000_0023;
        memory[56] = 64'h0000_0000_0000_006e;

        rst_n = 1'b0;
        mem_pending_q = 1'b0;
        mem_wait_q = 2'd0;
        saw_strcmp_branch_q = 1'b0;
        saw_strcmp_sub_q = 1'b0;
        strcmp_sub_result_q = 64'd0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        integer lane;

        if (!rst_n) begin
            mem_pending_q <= 1'b0;
            mem_wait_q <= 2'd0;
        end else if (!mem_pending_q) begin
            if (mem_valid && !mem_fast_instruction) begin
                mem_pending_q <= 1'b1;
                mem_wait_q <= 2'd3;
            end
        end else if (!mem_valid || mem_ready) begin
            mem_pending_q <= 1'b0;
            mem_wait_q <= 2'd0;
        end else if (mem_wait_q != 2'd0) begin
            mem_wait_q <= mem_wait_q - 1'b1;
        end

        if (rst_n && mem_valid) begin
            if (!mem_addr_in_range) begin
                $fatal(1, "load-use test address out of range: %016x", mem_addr);
            end
            if (mem_write) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (mem_wstrb[lane]) begin
                        memory[mem_array_index][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            saw_strcmp_branch_q <= 1'b0;
            saw_strcmp_sub_q <= 1'b0;
            saw_strcmp_debug_operands_q <= 1'b0;
            strcmp_sub_result_q <= 64'd0;
        end else begin
            if (DEBUG_SERIALIZE_ALL_1P && trace_retire_valid)
                $display("SERIAL_RETIRE pc=%016x instr=%08x rd_write=%b rd=%0d wdata=%016x",
                         trace_pcs[319:256], trace_instrs[159:128],
                         trace_retire_rd_write, trace_retire_rd,
                         trace_retire_wdata);
            if (dbg_pc == (RESET_VECTOR + PROGRAM_BASE_PC + 64'h7c)) begin
                if ((dbg_rs1_data != 64'h23) ||
                    (dbg_rs2_data != 64'h6e))
                    $fatal(1,
                           "strcmp debug operands mismatch rs1=%016x rs2=%016x",
                           dbg_rs1_data, dbg_rs2_data);
                saw_strcmp_debug_operands_q <= 1'b1;
            end

            if (trace_retire_valid &&
                (trace_pcs[319:256] ==
                 (RESET_VECTOR + PROGRAM_BASE_PC + 64'h74))) begin
                if (trace_retire_next_pc !=
                    (RESET_VECTOR + PROGRAM_BASE_PC + 64'h7c))
                    $fatal(1,
                           "strcmp BNE did not take mismatch target next_pc=%016x",
                           trace_retire_next_pc);
                saw_strcmp_branch_q <= 1'b1;
            end

            if (trace_retire_valid &&
                (trace_pcs[319:256] ==
                 (RESET_VECTOR + PROGRAM_BASE_PC + 64'h7c))) begin
                if (!trace_retire_rd_write || (trace_retire_rd != 5'd10))
                    $fatal(1,
                           "strcmp SUB retirement metadata mismatch write=%b rd=%0d",
                           trace_retire_rd_write, trace_retire_rd);
                saw_strcmp_sub_q <= 1'b1;
                strcmp_sub_result_q <= trace_retire_wdata;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;
            if ((dbg_pc != (RESET_VECTOR + PROGRAM_BASE_PC + 64'h60)) ||
                (dbg_instr != `RV64_INSTR_EBREAK)) begin
                $fatal(1, "load-use halt mismatch pc=%016x instr=%08x",
                       dbg_pc, dbg_instr);
            end
            if (!saw_strcmp_branch_q)
                $fatal(1, "strcmp mismatch branch did not retire");
            if (!saw_strcmp_sub_q)
                $fatal(1, "strcmp mismatch SUB did not retire");
            if (!saw_strcmp_debug_operands_q)
                $fatal(1, "strcmp debug operands were not observed");
            if (strcmp_sub_result_q != 64'hffff_ffff_ffff_ffb5)
                $fatal(1,
                       "strcmp SUB result mismatch got=%016x expected=ffffffffffffffb5",
                       strcmp_sub_result_q);
`ifndef OPENRV64_LOAD_USE_NETLIST
            expect_gpr(5'd5, 64'h23);
            expect_gpr(5'd6, 64'h6e);
            expect_gpr(5'd9, 64'h1234_5678_9abc_def0);
            expect_gpr(5'd15, 64'h0000_0000_0000_0050);
            expect_gpr(5'd20, 64'd0);
            expect_gpr(5'd10, 64'hffff_ffff_ffff_ffb5);
            expect_gpr(5'd30, 64'd1);
`endif
            if (memory[36] != 64'hdead_beef_0123_4567)
                $fatal(1, "load-use store mismatch got=%016x", memory[36]);
            $display("PASS: delayed FPGA load writeback interlocks ALU, branch, store, LSU, and strcmp consumers");
            $finish;
        end
    end

    initial begin
        repeat (8192) @(posedge clk);
        $fatal(1,
               "timeout waiting for load-use context pc=%016x instr=%08x mem_valid=%b mem_ready=%b mem_addr=%016x",
               dbg_pc, dbg_instr, mem_valid, mem_ready, mem_addr);
    end

endmodule
