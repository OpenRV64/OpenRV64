`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module tb_zicclsm_context;
    localparam [63:0] RESET_VECTOR = 64'h0;
    localparam integer MEM_WORDS = 256;
    localparam [63:0] HANDLER_ADDR = 64'h100;
    localparam [63:0] DATA_BASE = 64'h400;
    localparam [63:0] LOG_BASE = 64'h600;
    localparam integer DATA_RESPONSE_DELAY = 10;
    localparam integer FETCH_RESPONSE_DELAY = 1;

    reg clk;
    reg rst_n;
    wire mem_valid;
    reg mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    reg [63:0] mem_rdata;
    reg mem_error;
    reg irq_m_external;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;

    reg [63:0] memory [0:MEM_WORDS-1];
    reg pending;
    reg pending_write;
    reg [63:0] pending_addr;
    reg [63:0] pending_wdata;
    reg [7:0] pending_wstrb;
    integer pending_delay;
    integer cycle_count;
    integer lane;

    reg saw_branch_flush_active;
    reg saw_branch_flush_outstanding;
    reg saw_replay_clear;
    reg saw_replay_reaccept;
    reg irq_asserted_while_active;
    reg saw_irq_take;
    reg fault_injected;
    reg fault_request_seen;

    wire misaligned_active =
        dut.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p.u_exec
            .u_lsu.misaligned_active;
    wire misaligned_access_sent =
        dut.g_backend_3p.u_core_3p.u_backend.u_exec.g_3p.u_exec
            .u_lsu.g_zicclsm.u_misaligned.access_sent_q;
    wire redirect_flush =
        dut.g_backend_3p.u_core_3p.control_redirect;
    wire interrupt_flush =
        dut.g_backend_3p.u_core_3p.backend_irq;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_ZICCLSM(1'b1),
        .ENABLE_RV64M(1'b0),
        .ENABLE_L1I(1'b0),
        .ENABLE_L1D(1'b0),
        .L1D_CACHEABLE_BASE(64'h0),
        .L1D_CACHEABLE_SIZE(MEM_WORDS * 8),
        .L1D_PREFETCH_ENABLE(1'b0),
        .ENABLE_TRACE(1'b1),
        .BP_TYPE(`OPENRV64_BP_ALWAYS_DECLINE)
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
        .ccx_req_ready(1'b1),
        .ccx_wdata_ready(1'b1),
        .ccx_resp_valid(1'b0),
        .ccx_resp_hart_id('0),
        .ccx_resp_txn_id('0),
        .ccx_resp_source_id('0),
        .ccx_resp_beat_index('0),
        .ccx_resp_last(1'b0),
        .ccx_resp_rdata('0),
        .ccx_resp_error(1'b0),
        .ccx_resp_sc_success(1'b0),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(irq_m_external),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    always #5 clk = ~clk;

    task automatic put_instr;
        input integer instr_index;
        input [31:0] instr;
        begin
            if (instr_index[0])
                memory[instr_index >> 1][63:32] = instr;
            else
                memory[instr_index >> 1][31:0] = instr;
        end
    endtask

    function automatic [31:0] enc_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic [31:0] enc_slli;
        input [4:0] rd;
        input [4:0] rs1;
        input [5:0] shamt;
        begin
            enc_slli = {6'b000000, shamt, rs1, `RV64_FUNCT3_SLL,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic [31:0] enc_add;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            enc_add = {7'b0000000, rs2, rs1,
                       `RV64_FUNCT3_ADD_SUB, rd, `RV64_OPCODE_OP};
        end
    endfunction

    function automatic [31:0] enc_ld;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            enc_ld = {imm, rs1, `RV64_FUNCT3_LD,
                      rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic [31:0] enc_sd;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD,
                      imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic [31:0] enc_branch;
        input [2:0] funct3;
        input [4:0] rs1;
        input [4:0] rs2;
        input [12:0] imm;
        begin
            enc_branch = {imm[12], imm[10:5], rs2, rs1,
                          funct3, imm[4:1], imm[11],
                          `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic [31:0] enc_csr;
        input [11:0] csr;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        begin
            enc_csr = {csr, rs1, funct3, rd,
                       `RV64_OPCODE_SYSTEM};
        end
    endfunction

    always @* begin
        mem_ready = pending && (pending_delay == 0);
        mem_rdata = pending ?
                    memory[pending_addr[10:3]] : 64'd0;
        mem_error = pending && (pending_delay == 0) &&
                    !pending_write && (pending_addr == 64'h424) &&
                    !fault_injected;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            pending_write <= 1'b0;
            pending_addr <= 64'd0;
            pending_wdata <= 64'd0;
            pending_wstrb <= 8'd0;
            pending_delay <= 0;
            fault_injected <= 1'b0;
            fault_request_seen <= 1'b0;
        end else begin
            if (pending) begin
                if (pending_delay > 0) begin
                    pending_delay <= pending_delay - 1;
                end else begin
                    if (mem_error) begin
                        fault_injected <= 1'b1;
                    end else if (pending_write) begin
                        for (lane = 0; lane < 8; lane = lane + 1)
                            if (pending_wstrb[lane])
                                memory[pending_addr[10:3]][8*lane +: 8] <=
                                    pending_wdata[8*lane +: 8];
                    end
                    pending <= 1'b0;
                end
            end else if (mem_valid) begin
                if (mem_addr[63:11] != 0)
                    $fatal(1, "Zicclsm context address out of range: %h",
                           mem_addr);
                pending <= 1'b1;
                pending_write <= mem_write;
                pending_addr <= mem_addr;
                pending_wdata <= mem_wdata;
                pending_wstrb <= mem_wstrb;
                pending_delay <=
                    (mem_addr >= DATA_BASE) ?
                    DATA_RESPONSE_DELAY : FETCH_RESPONSE_DELAY;
                if (!mem_write && (mem_addr == 64'h424))
                    fault_request_seen <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_branch_flush_active <= 1'b0;
            saw_branch_flush_outstanding <= 1'b0;
            saw_replay_clear <= 1'b0;
            saw_replay_reaccept <= 1'b0;
            irq_asserted_while_active <= 1'b0;
            saw_irq_take <= 1'b0;
        end else begin
            if (redirect_flush && misaligned_active) begin
                saw_branch_flush_active <= 1'b1;
                if (misaligned_access_sent)
                    saw_branch_flush_outstanding <= 1'b1;
            end
            if (saw_branch_flush_outstanding && misaligned_active &&
                !misaligned_access_sent)
                saw_replay_clear <= 1'b1;
            if (saw_replay_clear && misaligned_active &&
                misaligned_access_sent)
                saw_replay_reaccept <= 1'b1;
            if (interrupt_flush) begin
                saw_irq_take <= 1'b1;
                if (misaligned_active)
                    $fatal(1,
                        "interrupt entered before misaligned instruction completed");
            end
            if (irq_m_external && misaligned_active)
                irq_asserted_while_active <= 1'b1;
        end
    end

    // Arm the external interrupt only after the deliberately redirecting
    // branch has flushed an active misaligned load. The request is asserted
    // during a later active component and held until architectural interrupt
    // entry acknowledges it.
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_m_external <= 1'b0;
        end else if (saw_irq_take) begin
            irq_m_external <= 1'b0;
        end else if (saw_branch_flush_active && misaligned_active &&
                     !irq_asserted_while_active) begin
            irq_m_external <= 1'b1;
        end
    end

    initial begin
        integer index;

        clk = 1'b0;
        rst_n = 1'b0;
        irq_m_external = 1'b0;
        pending = 1'b0;
        cycle_count = 0;
        saw_branch_flush_active = 1'b0;
        saw_branch_flush_outstanding = 1'b0;
        saw_replay_clear = 1'b0;
        saw_replay_reaccept = 1'b0;
        irq_asserted_while_active = 1'b0;
        saw_irq_take = 1'b0;
        fault_injected = 1'b0;
        fault_request_seen = 1'b0;

        for (index = 0; index < MEM_WORDS; index = index + 1)
            memory[index] = 64'd0;

        // Main program. The generic-bus 3P frontend does not speculate
        // conditional branches, so the taken BEQ redirects while the older
        // misaligned load is delayed. Its target is the fall-through PC to
        // preserve a simple architectural stream while still forcing replay.
        put_instr(0, enc_addi(5'd1, 5'd0, HANDLER_ADDR[11:0]));
        put_instr(1, enc_csr(`RV64_CSR_MTVEC, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, 5'd0));
        put_instr(2, enc_addi(5'd1, 5'd0, 12'h001));
        put_instr(3, enc_slli(5'd1, 5'd1, 6'd11));
        put_instr(4, enc_csr(`RV64_CSR_MIE, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, 5'd0));
        put_instr(5, enc_addi(5'd1, 5'd0, 12'h008));
        put_instr(6, enc_csr(`RV64_CSR_MSTATUS, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, 5'd0));
        put_instr(7, enc_addi(5'd20, 5'd0, 12'd0));
        put_instr(8, enc_addi(5'd10, 5'd0, 12'h403));
        put_instr(9, enc_ld(5'd5, 5'd10, 12'd0));
        // The branch depends on this ALU result, delaying resolution until
        // the first load component is outstanding.
        put_instr(10, enc_addi(5'd21, 5'd0, 12'd0));
        put_instr(11, enc_branch(`RV64_FUNCT3_BEQ,
                                 5'd21, 5'd0, 13'd4));
        put_instr(12, enc_addi(5'd6, 5'd5, 12'd1));
        put_instr(13, enc_sd(5'd6, 5'd10, 12'd2));
        put_instr(14, enc_ld(5'd7, 5'd10, 12'd32));
        put_instr(15, enc_addi(5'd8, 5'd0, 12'h055));
        put_instr(16, enc_ld(5'd9, 5'd10, 12'd48));
        put_instr(17, enc_sd(5'd9, 5'd10, 12'd64));
        put_instr(18, `RV64_INSTR_EBREAK);

        // Trap/interrupt handler. x20 selects a 32-byte log record. Interrupt
        // MEPC is preserved; synchronous-fault MEPC advances by one insn.
        put_instr(64, enc_csr(`RV64_CSR_MCAUSE, 5'd0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd2));
        put_instr(65, enc_csr(`RV64_CSR_MEPC, 5'd0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd3));
        put_instr(66, enc_csr(`RV64_CSR_MTVAL, 5'd0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd4));
        put_instr(67, enc_addi(5'd11, 5'd0, LOG_BASE[11:0]));
        put_instr(68, enc_slli(5'd12, 5'd20, 6'd5));
        put_instr(69, enc_add(5'd11, 5'd11, 5'd12));
        put_instr(70, enc_sd(5'd2, 5'd11, 12'd0));
        put_instr(71, enc_sd(5'd3, 5'd11, 12'd8));
        put_instr(72, enc_sd(5'd4, 5'd11, 12'd16));
        put_instr(73, enc_addi(5'd20, 5'd20, 12'd1));
        put_instr(74, enc_branch(`RV64_FUNCT3_BLT,
                                 5'd2, 5'd0, 13'd12));
        put_instr(75, enc_addi(5'd3, 5'd3, 12'd4));
        put_instr(76, enc_csr(`RV64_CSR_MEPC, 5'd3,
                              `RV64_ZICSR_FUNCT3_CSRRW, 5'd0));
        put_instr(77, `RV64_INSTR_MRET);

        memory[DATA_BASE/8] = 64'h7766_5544_3322_1100;
        memory[DATA_BASE/8 + 1] = 64'hffee_ddcc_bbaa_9988;
        memory[DATA_BASE/8 + 4] = 64'h1716_1514_1312_1110;
        memory[DATA_BASE/8 + 5] = 64'h1f1e_1d1c_1b1a_1918;
        memory[DATA_BASE/8 + 6] = 64'h2726_2524_2322_2120;
        memory[DATA_BASE/8 + 7] = 64'h2f2e_2d2c_2b2a_2928;
        memory[DATA_BASE/8 + 8] = 64'heeee_eeee_eeee_eeee;
        memory[DATA_BASE/8 + 9] = 64'hdddd_dddd_dddd_dddd;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        while (!dbg_halted && (cycle_count < 10000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        if (!dbg_halted)
            $fatal(1, "Zicclsm context did not halt");

        // Let the posted final store and handler logs drain.
        repeat (200) @(posedge clk);
        #1;

        if (!saw_branch_flush_active ||
            !saw_branch_flush_outstanding ||
            !saw_replay_clear || !saw_replay_reaccept)
            $fatal(1,
                "branch redirect did not replay an outstanding misaligned load");
        if (!irq_asserted_while_active || !saw_irq_take)
            $fatal(1,
                "external interrupt was not requested during Zicclsm activity");
        if (!fault_request_seen || !fault_injected)
            $fatal(1, "later-component access fault was not injected");
        if (memory[LOG_BASE/8] != 64'h8000_0000_0000_000b)
            $fatal(1, "interrupt mcause mismatch: %h",
                   memory[LOG_BASE/8]);
        if ((memory[LOG_BASE/8 + 1][1:0] != 2'b00) ||
            (memory[LOG_BASE/8 + 1] < 64'h2c) ||
            (memory[LOG_BASE/8 + 1] > 64'h38))
            $fatal(1, "interrupt mepc mismatch: %h",
                   memory[LOG_BASE/8 + 1]);
        if (memory[LOG_BASE/8 + 2] != 64'd0)
            $fatal(1, "interrupt mtval mismatch: %h",
                   memory[LOG_BASE/8 + 2]);
        if (memory[LOG_BASE/8 + 4] !=
            `RV64_EXCEPT_CAUSE_LOAD_ACCESS_FAULT)
            $fatal(1, "load access-fault mcause mismatch: %h",
                   memory[LOG_BASE/8 + 4]);
        if (memory[LOG_BASE/8 + 5] != 64'h38)
            $fatal(1, "load access-fault mepc mismatch: %h",
                   memory[LOG_BASE/8 + 5]);
        if (memory[LOG_BASE/8 + 6] != 64'h424)
            $fatal(1, "load access-fault mtval mismatch: %h",
                   memory[LOG_BASE/8 + 6]);
        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8] != 64'h55)
            $fatal(1, "post-fault execution did not resume");
        if ((memory[64'h440 >> 3] != 64'h2726_2524_23ee_eeee) ||
            (memory[64'h448 >> 3] != 64'hdddd_dddddd2a_2928))
            $fatal(1,
                "post-trap misaligned store mismatch: %h %h",
                memory[64'h440 >> 3], memory[64'h448 >> 3]);

        $display("PASS: 3P Zicclsm branch replay, deferred interrupt, access-fault trap context, and post-trap continuation");
        $finish;
    end
endmodule
