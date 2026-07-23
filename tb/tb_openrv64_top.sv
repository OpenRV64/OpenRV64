`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-m.v"
`include "core/isa/rv64-zifencei.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module tb_openrv64_top;

    localparam logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0100;
    localparam int unsigned RESET_INSTR_INDEX = RESET_VECTOR >> 2;
    localparam int unsigned MEM_WORDS = 64;

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
    logic [63:0]  trace_cycle;
    logic [4:0]   trace_valid;
    logic [4:0]   trace_stall;
    logic [4:0]   trace_flush;
    logic [4:0]   trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0]   trace_events;
    logic [7:0]   trace_stall_causes;
    logic         trace_retire_valid;
    logic         trace_retire_arch;
    logic         trace_retire_exception;
    logic [4:0]   trace_retire_cause;
    logic [63:0]  trace_retire_next_pc;
    logic         trace_retire_rd_write;
    logic [4:0]   trace_retire_rd;
    logic [63:0]  trace_retire_wdata;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic        saw_jal_link_store;
    logic        saw_jalr_link_store;
    logic        saw_mul_store;
    logic        saw_fence_i_restart;
    logic        saw_pmp_trap;
    logic        saw_bp_stall;
    logic        saw_bp_branch_stall;
    logic        mem_addr_in_range;
    integer      trace_arch_count;
    integer      trace_exception_count;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[8:3]] :
                       64'h0000_0000_0000_0000;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(1'b1),
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
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    openrv64_cycle_trace u_cycle_trace (
        .clk(clk),
        .rst_n(rst_n),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
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
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB, rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD, imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input logic [20:0] imm;
        begin
            enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, `RV64_OPCODE_JAL};
        end
    endfunction

    function automatic logic [31:0] enc_jalr;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_jalr = {imm, rs1, `RV64_FUNCT3_JALR, rd, `RV64_OPCODE_JALR};
        end
    endfunction

    function automatic logic [31:0] enc_bne;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [12:0] imm;
        begin
            enc_bne = {imm[12], imm[10:5], rs2, rs1, `RV64_FUNCT3_BNE,
                       imm[4:1], imm[11], `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic logic [31:0] enc_mul;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        begin
            enc_mul = {`RV64_M_FUNCT7, rs2, rs1, `RV64_M_FUNCT3_MUL, rd, `RV64_OPCODE_OP};
        end
    endfunction

    function automatic logic [31:0] enc_csrrw;
        input logic [4:0] rd;
        input logic [`RV64_FUNCT12_WIDTH-1:0] csr;
        input logic [4:0] rs1;
        begin
            enc_csrrw = {csr, rs1, `RV64_ZICSR_FUNCT3_CSRRW,
                         rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    initial begin
        int i;

        for (i = 0; i < MEM_WORDS; i++) begin
            memory[i] = 64'h0000_0000_0000_0000;
        end

        put_instr(RESET_INSTR_INDEX + 0,  enc_jal(5'd4, 21'h00010));
        put_instr(RESET_INSTR_INDEX + 1,  `RV64_INSTR_EBREAK);
        put_instr(RESET_INSTR_INDEX + 2,  `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 3,  `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 4,
                  enc_addi(5'd5, `RV64_REG_X0, 12'h130));
        put_instr(RESET_INSTR_INDEX + 5,
                  enc_jalr(5'd6, 5'd5, 12'h000));
        put_instr(RESET_INSTR_INDEX + 6,  `RV64_INSTR_EBREAK);
        put_instr(RESET_INSTR_INDEX + 7,  `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 8,  `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 9,  `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 10, `RV64_INSTR_NOP);
        put_instr(RESET_INSTR_INDEX + 11, `RV64_INSTR_NOP);
        // Deliberately not taken.  The predictor stub must hold younger work
        // until execute resolves the condition, then resume without redirect.
        put_instr(RESET_INSTR_INDEX + 12,
                  enc_bne(`RV64_REG_X0, `RV64_REG_X0, 13'h008));
        put_instr(RESET_INSTR_INDEX + 13, 32'h0ff0_000f);
        put_instr(RESET_INSTR_INDEX + 14, `RV64_INSTR_FENCE_I);
        put_instr(RESET_INSTR_INDEX + 15,
                  enc_sd(5'd4, `RV64_REG_X0, 12'h080));
        put_instr(RESET_INSTR_INDEX + 16,
                  enc_sd(5'd6, `RV64_REG_X0, 12'h088));
        put_instr(RESET_INSTR_INDEX + 17,
                  enc_addi(5'd7, `RV64_REG_X0, 12'd6));
        put_instr(RESET_INSTR_INDEX + 18,
                  enc_addi(5'd8, `RV64_REG_X0, 12'd7));
        put_instr(RESET_INSTR_INDEX + 19,
                  enc_mul(5'd9, 5'd7, 5'd8));
        put_instr(RESET_INSTR_INDEX + 20,
                  enc_sd(5'd9, `RV64_REG_X0, 12'h090));
        put_instr(RESET_INSTR_INDEX + 21,
                  enc_addi(5'd10, `RV64_REG_X0, 12'h180));
        put_instr(RESET_INSTR_INDEX + 22,
                  enc_csrrw(`RV64_REG_X0, `RV64_CSR_MTVEC, 5'd10));
        put_instr(RESET_INSTR_INDEX + 23,
                  enc_addi(5'd10, `RV64_REG_X0, 12'h1ff));
        put_instr(RESET_INSTR_INDEX + 24,
                  enc_csrrw(`RV64_REG_X0, `RV64_CSR_PMPADDR0, 5'd10));
        put_instr(RESET_INSTR_INDEX + 25,
                  enc_addi(5'd10, `RV64_REG_X0, 12'h09d));
        put_instr(RESET_INSTR_INDEX + 26,
                  enc_csrrw(`RV64_REG_X0, `RV64_CSR_PMPCFG0, 5'd10));
        put_instr(RESET_INSTR_INDEX + 27,
                  enc_sd(5'd9, `RV64_REG_X0, 12'h098));
        put_instr(RESET_INSTR_INDEX + 28, `RV64_INSTR_EBREAK);
        put_instr(RESET_INSTR_INDEX + 32,
                  enc_jal(`RV64_REG_X0, 21'h000000));

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_jal_link_store <= 1'b0;
            saw_jalr_link_store <= 1'b0;
            saw_mul_store <= 1'b0;
            saw_fence_i_restart <= 1'b0;
            saw_pmp_trap <= 1'b0;
            saw_bp_stall <= 1'b0;
            saw_bp_branch_stall <= 1'b0;
            trace_arch_count <= 0;
            trace_exception_count <= 0;
        end else if (dut.u_core.hard_flush_trap_req &&
                     dut.u_core.exec_wb_cause ==
                     `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT) begin
            saw_pmp_trap <= 1'b1;
        end else if (dut.u_core.hard_flush_restart_req) begin
            saw_fence_i_restart <= 1'b1;
        end else if (mem_valid && mem_write) begin
            int lane;

            if (mem_addr == 64'h0000_0000_0000_0080) begin
                saw_jal_link_store <= 1'b1;
            end else if (mem_addr == 64'h0000_0000_0000_0088) begin
                saw_jalr_link_store <= 1'b1;
            end else if (mem_addr == 64'h0000_0000_0000_0090) begin
                saw_mul_store <= 1'b1;
            end

            for (lane = 0; lane < 8; lane++) begin
                if (mem_wstrb[lane]) begin
                    memory[mem_addr[8:3]][8*lane +: 8] <=
                        mem_wdata[8*lane +: 8];
                end
            end
        end

        if (rst_n) begin
            if (dut.u_core.bp_decode_stall) begin
                saw_bp_stall <= 1'b1;
            end

            if (dut.u_core.bp_decode_stall &&
                dut.u_core.dispatch_exec_valid &&
                dut.u_core.dispatch_exec_branch &&
                (dut.u_core.dispatch_exec_pc == 64'h130)) begin
                saw_bp_branch_stall <= 1'b1;

                if (dut.u_core.hard_flush_redirect_req) begin
                    $fatal(1, "not-taken branch incorrectly redirected");
                end
            end

            if (trace_retire_arch) begin
                trace_arch_count <= trace_arch_count + 1;
            end

            if (trace_retire_exception) begin
                trace_exception_count <= trace_exception_count + 1;
            end
        end
    end

    always @(negedge clk) begin
        integer trace_stage;

        if (rst_n) begin
            for (trace_stage = 0; trace_stage < 5; trace_stage++) begin
                if (trace_valid[trace_stage] &&
                    trace_ids[trace_stage*64 +: 64] == 64'd0) begin
                    $fatal(1, "valid trace stage %0d has UID zero", trace_stage);
                end
            end

            if (trace_retire_valid &&
                (!trace_valid[4] || trace_ids[4*64 +: 64] == 64'd0)) begin
                $fatal(1, "trace retirement lacks a valid WB UID");
            end

            if (dut.u_core.bp_decode_stall &&
                !dut.u_core.hard_flush_req &&
                (dut.u_core.fetch_pc_valid ||
                 dut.u_core.if_id_out_clear ||
                 dut.u_core.dispatch_decode_valid)) begin
                $fatal(1, "branch predictor stall did not hold the frontend");
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            if (!mem_write && mem_wstrb != 8'h00) begin
                $fatal(1, "unexpected read strobes: %02x", mem_wstrb);
            end

            if (mem_write) begin
                if (mem_wstrb != 8'hff) begin
                    $fatal(1, "unexpected write strobes: %02x", mem_wstrb);
                end

                case (mem_addr)
                    64'h0000_0000_0000_0080: begin
                        if (mem_wdata != 64'h0000_0000_0000_0104) begin
                            $fatal(1, "unexpected JAL link data: %016x", mem_wdata);
                        end
                    end

                    64'h0000_0000_0000_0088: begin
                        if (mem_wdata != 64'h0000_0000_0000_0118) begin
                            $fatal(1, "unexpected JALR link data: %016x", mem_wdata);
                        end
                    end

                    64'h0000_0000_0000_0090: begin
                        if (mem_wdata != 64'h0000_0000_0000_002a) begin
                            $fatal(1, "unexpected MUL data: %016x", mem_wdata);
                        end
                    end

                    default: begin
                        $fatal(1, "unexpected write address: %016x", mem_addr);
                    end
                endcase
            end

            if (mem_addr[2:0] != 3'b000) begin
                $fatal(1, "unaligned memory address: %016x", mem_addr);
            end

            if (mem_addr[63:3] >= MEM_WORDS) begin
                $fatal(1, "memory address out of range: %016x", mem_addr);
            end
        end

        if (rst_n && dbg_halted && !saw_pmp_trap) begin
            $fatal(1, "unexpected halt before PMP trap: pc=%016x", dbg_pc);
        end

        if (rst_n && saw_pmp_trap) begin
            #1;

            if (!saw_jal_link_store) begin
                $fatal(1, "JAL link store never reached memory bus");
            end

            if (!saw_jalr_link_store) begin
                $fatal(1, "JALR link store never reached memory bus");
            end

            if (!saw_mul_store) begin
                $fatal(1, "MUL result store never reached memory bus");
            end

            if (!saw_fence_i_restart) begin
                $fatal(1, "FENCE.I did not issue a frontend restart");
            end

            if (!saw_bp_stall) begin
                $fatal(1, "branch predictor stall was never observed");
            end

            if (!saw_bp_branch_stall) begin
                $fatal(1, "conditional-branch predictor stall was never observed");
            end

            if (dut.u_core.u_csrs.minstret_q != 64'd18) begin
                $fatal(1, "minstret mismatch: %0d",
                       dut.u_core.u_csrs.minstret_q);
            end

            if (trace_arch_count != 18 || trace_exception_count != 1) begin
                $fatal(1, "trace retire counts mismatch: arch=%0d exception=%0d",
                       trace_arch_count, trace_exception_count);
            end

            if (dut.u_core.u_csrs.mcycle_q <=
                dut.u_core.u_csrs.minstret_q) begin
                $fatal(1, "mcycle did not advance independently");
            end

            if (dut.u_core.u_csrs.mcause_q !=
                `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT) begin
                $fatal(1,
                       "PMP trap mcause mismatch: %016x cfg=%016x addr0=%016x",
                       dut.u_core.u_csrs.mcause_q,
                       dut.u_core.u_csrs.u_pmp.pmpcfg_q[63:0],
                       dut.u_core.u_csrs.u_pmp.pmpaddr_q[0]);
            end

            if (dut.u_core.u_csrs.mepc_q != 64'h16c ||
                dut.u_core.u_csrs.mtval_q != 64'h98) begin
                $fatal(1, "PMP trap context mismatch: mepc=%016x mtval=%016x",
                       dut.u_core.u_csrs.mepc_q,
                       dut.u_core.u_csrs.mtval_q);
            end

            if (memory[19] != 64'h0) begin
                $fatal(1, "PMP-denied store reached memory: %016x",
                       memory[19]);
            end

            if (memory[16] != 64'h0000_0000_0000_0104) begin
                $fatal(1, "JAL link store mismatch: %016x", memory[16]);
            end

            if (memory[17] != 64'h0000_0000_0000_0118) begin
                $fatal(1, "JALR link store mismatch: %016x", memory[17]);
            end

            if (memory[18] != 64'h0000_0000_0000_002a) begin
                $fatal(1, "MUL result store mismatch: %016x", memory[18]);
            end

            $display("PASS: FENCE.I restart and PMP trap context; jal_link=%016x jalr_link=%016x mul=%016x",
                     memory[16], memory[17], memory[18]);
            $finish;
        end
    end

    initial begin
        repeat (480) @(posedge clk);
        $fatal(1, "timeout waiting for halt");
    end

endmodule
