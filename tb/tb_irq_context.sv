`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"

module tb_irq_context;

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
    logic irq_m_external;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic mem_addr_in_range;
    logic irq_armed;
    logic saw_irq_take;
    integer irq_take_count;
    logic saw_irq_inhibit;
    logic saw_next_cycle_flush;

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
        .irq_m_external(irq_m_external),
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

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input logic [20:0] imm;
        begin
            enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12],
                       rd, `RV64_OPCODE_JAL};
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

        put_instr(0, enc_addi(5'd1, `RV64_REG_X0, 12'h080));
        put_instr(1, enc_csr(`RV64_CSR_MTVEC, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(2, enc_addi(5'd1, `RV64_REG_X0, 12'h001));
        put_instr(3, enc_slli(5'd1, 5'd1, 6'd11));
        put_instr(4, enc_csr(`RV64_CSR_MIE, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(5, enc_addi(5'd1, `RV64_REG_X0, 12'h008));
        put_instr(6, enc_csr(`RV64_CSR_MSTATUS, 5'd1,
                             `RV64_ZICSR_FUNCT3_CSRRW, `RV64_REG_X0));
        put_instr(7, enc_jal(`RV64_REG_X0, 21'h000024));

        // The JAL target must be the interrupt resume PC.
        put_instr(16, enc_jal(`RV64_REG_X0, 21'h000000));

        put_instr(32, enc_csr(`RV64_CSR_MEPC, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd2));
        put_instr(33, enc_sd(5'd2, `RV64_REG_X0, 12'h100));
        put_instr(34, enc_csr(`RV64_CSR_MCAUSE, `RV64_REG_X0,
                              `RV64_ZICSR_FUNCT3_CSRRS, 5'd3));
        put_instr(35, enc_sd(5'd3, `RV64_REG_X0, 12'h108));
        put_instr(36, `RV64_INSTR_EBREAK);

        irq_m_external = 1'b0;
        irq_armed = 1'b0;
        saw_irq_take = 1'b0;
        irq_take_count = 0;
        saw_irq_inhibit = 1'b0;
        saw_next_cycle_flush = 1'b0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(negedge clk) begin
        if (rst_n && !irq_armed && dut.u_core.exec_wb_valid &&
            dut.u_core.exec_wb_pc == 64'h1c) begin
            irq_m_external = 1'b1;
            irq_armed = 1'b1;
        end
    end

    // The interrupt decision cycle is an inhibit, not an asynchronous payload
    // flush.  Registered pipeline valid bits become clear only after the edge.
    always @(posedge clk) begin
        if (rst_n && dut.u_core.hard_flush_irq_req) begin
            saw_irq_inhibit = 1'b1;
            if (!dut.u_core.control_event_inhibit)
                $fatal(1, "IRQ decision did not assert issue inhibit");
            if (dut.u_core.dispatch_exec_issue_valid)
                $fatal(1, "IRQ decision allowed dispatch issue");
            if (dut.u_core.exec_mem_issue_valid)
                $fatal(1, "IRQ decision allowed LSU issue");

            // State updates from this edge must make the flushed stages empty
            // in the following cycle, not alter their pre-edge payloads.
            #1;
            if (dut.u_core.dispatch_exec_valid)
                $fatal(1, "ID/EX remained valid after IRQ flush edge");
            if (dut.u_core.exec_mem_valid)
                $fatal(1, "EX/MEM remained valid after IRQ flush edge");
            saw_next_cycle_flush = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            int lane;

            if (dut.u_core.hard_flush_irq_req) begin
                if (saw_irq_take)
                    $fatal(1,
                        "level interrupt retriggered while M-mode MIE was clear");
                saw_irq_take <= 1'b1;
                irq_take_count <= irq_take_count + 1;
            end

            if (mem_valid) begin
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
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && dbg_halted) begin
            #1;

            if (!irq_armed || !saw_irq_take || !saw_irq_inhibit ||
                !saw_next_cycle_flush) begin
                $fatal(1, "machine external interrupt was not taken");
            end
            if (irq_take_count != 1)
                $fatal(1, "machine external interrupt count mismatch: %0d",
                       irq_take_count);
            if (memory[32] != 64'h40) begin
                $fatal(1, "interrupt MEPC is not JAL target: %016x",
                       memory[32]);
            end
            if (memory[33] != 64'h8000_0000_0000_000b) begin
                $fatal(1, "machine external MCAUSE mismatch: %016x",
                       memory[33]);
            end

            $display("PASS: machine external interrupt uses retired architectural next PC");
            $finish;
        end
    end

    initial begin
        repeat (768) @(posedge clk);
        $fatal(1,
            "timeout waiting for interrupt handler pc=%016x instr=%08x irq_takes=%0d mstatus=%016x priv=%0d serial_inflight=%0d serial_retired=%0d wb_valid=%0d wb_pc=%016x",
            dbg_pc, dbg_instr, irq_take_count,
            dut.u_core.u_csrs.mstatus_q,
            dut.u_core.u_csrs.priv_mode_q,
            dut.u_core.debug_serial_inflight_q,
            dut.u_core.debug_serial_retired_q,
            dut.u_core.exec_wb_valid,
            dut.u_core.exec_wb_pc);
    end

endmodule
