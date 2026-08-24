`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"

module tb_wfi_context;
    localparam integer MEM_WORDS = 32;

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
    wire wfi_sleep;

    logic irq_m_software;
    logic irq_m_timer;
    logic irq_m_external;
    logic irq_s_software;
    logic irq_s_timer;
    logic irq_s_external;

    logic [63:0] memory [0:MEM_WORDS-1];
    integer test_index;
    integer wait_cycles;
    logic [63:0] count_before;

    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_addr[63:3] < MEM_WORDS) ?
                       memory[mem_addr[7:3]] : 64'd0;

    openrv64_top #(
        .RESET_VECTOR(64'd0),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_TRACE(1'b0)
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
        .irq_m_software(irq_m_software),
        .irq_m_timer(irq_m_timer),
        .irq_m_external(irq_m_external),
        .irq_s_software(irq_s_software),
        .irq_s_timer(irq_s_timer),
        .irq_s_external(irq_s_external),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .wfi_sleep(wfi_sleep)
    );

    always #5 clk = ~clk;

    task automatic put_instr;
        input integer instr_index;
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

    function automatic logic [31:0] enc_csrrw;
        input logic [11:0] csr;
        input logic [4:0] rs1;
        begin
            enc_csrrw = {csr, rs1, `RV64_ZICSR_FUNCT3_CSRRW,
                         `RV64_REG_X0, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    function automatic logic [31:0] enc_csrrs;
        input logic [11:0] csr;
        input logic [4:0] rd;
        begin
            enc_csrrs = {csr, `RV64_REG_X0,
                         `RV64_ZICSR_FUNCT3_CSRRS,
                         rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input logic signed [20:0] offset;
        begin
            enc_jal = {
                offset[20],
                offset[10:1],
                offset[11],
                offset[19:12],
                rd,
                `RV64_OPCODE_JAL
            };
        end
    endfunction

    task automatic clear_irqs;
        begin
            irq_m_software = 1'b0;
            irq_m_timer = 1'b0;
            irq_m_external = 1'b0;
            irq_s_software = 1'b0;
            irq_s_timer = 1'b0;
            irq_s_external = 1'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic wait_for_sleep;
        begin
            wait_cycles = 0;
            while (!wfi_sleep && (wait_cycles < 300)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!wfi_sleep)
                $fatal(1, "WFI did not enter sleep pc=%h instr=%h",
                       dbg_pc, dbg_instr);
            if ((dbg_pc != 64'd8) ||
                (dbg_instr != `RV64_INSTR_WFI))
                $fatal(1,
                    "WFI sleep debug state pc=%h instr=%h",
                    dbg_pc, dbg_instr);
        end
    endtask

    task automatic drive_irq;
        input integer irq_index;
        input logic value;
        begin
            case (irq_index)
                0: irq_m_software = value;
                1: irq_m_timer = value;
                2: irq_m_external = value;
                3: irq_s_software = value;
                4: irq_s_timer = value;
                5: irq_s_external = value;
                default: $fatal(1, "invalid IRQ index %0d", irq_index);
            endcase
        end
    endtask

    task automatic wake_once;
        input integer irq_index;
        begin
            wait_for_sleep();
            if (dut.g_backend_3p.u_core_3p.u_csrs
                    .mstatus_q[`RV64_MSTATUS_MIE_BIT] ||
                dut.g_backend_3p.u_core_3p.u_csrs
                    .mstatus_q[`RV64_MSTATUS_SIE_BIT])
                $fatal(1, "global interrupt enable unexpectedly set");

            count_before =
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2];
            @(negedge clk);
            drive_irq(irq_index, 1'b1);

            wait_cycles = 0;
            while (wfi_sleep && (wait_cycles < 10)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (wfi_sleep)
                $fatal(1, "IRQ %0d did not wake WFI", irq_index);

            @(negedge clk);
            drive_irq(irq_index, 1'b0);

            wait_cycles = 0;
            while ((dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !=
                    (count_before + 64'd1)) &&
                   (wait_cycles < 300)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !=
                (count_before + 64'd1))
                $fatal(1, "IRQ %0d woke but PC+4 did not retire",
                       irq_index);
        end
    endtask

    task automatic wake_probe_hit_once;
        begin
            wait_for_sleep();
            count_before =
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2];
            @(negedge clk);
            force dut.g_backend_3p.u_core_3p.l1d_probe_hit = 1'b1;
            @(posedge clk);
            #1;
            if (wfi_sleep)
                $fatal(1, "successful L1D probe did not wake WFI");
            @(negedge clk);
            release dut.g_backend_3p.u_core_3p.l1d_probe_hit;

            wait_cycles = 0;
            while ((dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !=
                    (count_before + 64'd1)) &&
                   (wait_cycles < 300)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !=
                (count_before + 64'd1))
                $fatal(1,
                    "successful L1D probe woke but PC+4 did not retire");
        end
    endtask

    initial begin
        for (test_index = 0; test_index < MEM_WORDS;
             test_index = test_index + 1)
            memory[test_index] = 64'd0;
        clk = 1'b0;
        rst_n = 1'b0;
        clear_irqs();

        // No individual enables: raw interrupt inputs must not wake WFI.
        put_instr(0, enc_csrrw(`RV64_CSR_MIE, `RV64_REG_X0));
        put_instr(1, `RV64_INSTR_WFI);
        put_instr(2, `RV64_INSTR_EBREAK);
        apply_reset();

        wait_cycles = 0;
        while (!wfi_sleep && (wait_cycles < 300)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (!wfi_sleep)
            $fatal(1, "disabled-interrupt WFI did not sleep");
        @(negedge clk);
        irq_m_software = 1'b1;
        irq_m_timer = 1'b1;
        irq_m_external = 1'b1;
        irq_s_software = 1'b1;
        irq_s_timer = 1'b1;
        irq_s_external = 1'b1;
        repeat (12) begin
            @(posedge clk);
            #1;
            if (!wfi_sleep)
                $fatal(1,
                    "individually disabled interrupt woke WFI");
            if (dut.g_backend_3p.u_core_3p.backend_clock_enable_q)
                $fatal(1, "3P backend clock remained enabled in WFI");
        end
        @(negedge clk);
        clear_irqs();

        // Enable every implemented interrupt while keeping global MIE/SIE
        // clear. Each source must wake to PC+4 without taking a trap.
        rst_n = 1'b0;
        for (test_index = 0; test_index < MEM_WORDS;
             test_index = test_index + 1)
            memory[test_index] = 64'd0;
        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'hfff));
        put_instr(1, enc_csrrw(`RV64_CSR_MIE, 5'd1));
        put_instr(2, `RV64_INSTR_WFI);
        put_instr(3, enc_addi(5'd2, 5'd2, 12'd1));
        put_instr(4, enc_jal(`RV64_REG_X0, -21'sd8));
        put_instr(5, `RV64_INSTR_EBREAK);
        apply_reset();

        // An enabled interrupt that is already pending when WFI retires must
        // prevent sleep even though global MIE remains clear.
        irq_m_software = 1'b1;
        wait_cycles = 0;
        while ((dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !=
                64'd1) &&
               (wait_cycles < 300)) begin
            @(posedge clk);
            #1;
            if (wfi_sleep)
                $fatal(1, "pending enabled interrupt allowed WFI sleep");
            wait_cycles = wait_cycles + 1;
        end
        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] != 64'd1)
            $fatal(1, "pending enabled interrupt did not resume at PC+4");
        @(negedge clk);
        irq_m_software = 1'b0;

        for (test_index = 0; test_index < 6;
             test_index = test_index + 1)
            wake_once(test_index);
        wake_probe_hit_once();

        wait_for_sleep();
        if (dbg_halted)
            $fatal(1, "WFI test unexpectedly halted");

        // With global delivery enabled, the wake source must trap before the
        // instruction at WFI+4 retires, and xEPC must name WFI+4.
        rst_n = 1'b0;
        clear_irqs();
        for (test_index = 0; test_index < MEM_WORDS;
             test_index = test_index + 1)
            memory[test_index] = 64'd0;
        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'h080));
        put_instr(1, enc_csrrw(`RV64_CSR_MTVEC, 5'd1));
        put_instr(2, enc_csrrw(`RV64_CSR_MIE, 5'd1));
        put_instr(3, enc_addi(5'd1, `RV64_REG_X0, 12'h008));
        put_instr(4, enc_csrrw(`RV64_CSR_MSTATUS, 5'd1));
        put_instr(5, `RV64_INSTR_WFI);
        put_instr(6, enc_addi(5'd3, 5'd3, 12'd1));
        put_instr(7, `RV64_INSTR_EBREAK);
        put_instr(32, enc_csrrs(`RV64_CSR_MEPC, 5'd4));
        put_instr(33, enc_csrrs(`RV64_CSR_MCAUSE, 5'd5));
        put_instr(34, `RV64_INSTR_EBREAK);
        apply_reset();

        wait_cycles = 0;
        while (!wfi_sleep && (wait_cycles < 300)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (!wfi_sleep || (dbg_pc != 64'd20))
            $fatal(1, "trap-phase WFI did not sleep pc=%h", dbg_pc);
        @(negedge clk);
        irq_m_timer = 1'b1;
        @(negedge clk);
        irq_m_timer = 1'b0;
        wait_cycles = 0;
        while (!dbg_halted && (wait_cycles < 300)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (!dbg_halted)
            $fatal(1, "WFI interrupt handler did not halt");
        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[3] != 64'd0 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[4] != 64'd24 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5] !=
                64'h8000_0000_0000_0007)
            $fatal(1,
                "WFI trap boundary x3=%h mepc=%h mcause=%h",
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[3],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[4],
                dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5]);
        $display(
            "PASS: WFI entry race, IRQ/probe wake, clock gating, and interrupt trap at WFI+4");
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "WFI context timeout");
    end
endmodule
