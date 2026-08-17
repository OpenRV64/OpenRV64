`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"

module tb_platform;

    localparam logic [63:0] INTERRUPT_BIT = 64'h8000_0000_0000_0000;
    localparam integer HANDLER_OFFSET = 'h200;

    logic clk;
    logic rst_n;
    logic mtime_tick;
    logic uart_rx;
    logic uart_tx;
    logic [31:0] gpio_in;
    logic [31:0] gpio_out;
    logic [28:0] external_irq;
    logic soc_rst_n;
    logic core_rst_n;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] trace_cycle;
    logic [4:0] trace_valid;
    logic [4:0] trace_stall;
    logic [4:0] trace_flush;
    logic [4:0] trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0] trace_events;
    logic [7:0] trace_stall_causes;
    logic trace_retire_valid;
    logic trace_retire_arch;
    logic trace_retire_exception;
    logic [4:0] trace_retire_cause;
    logic [63:0] trace_retire_next_pc;
    logic trace_retire_rd_write;
    logic [4:0] trace_retire_rd;
    logic [63:0] trace_retire_wdata;

    logic saw_soc_release;
    logic saw_core_release;
    logic saw_rom_fetch;
    logic saw_ram_fetch;
    logic saw_clint_access;
    logic saw_plic_access;
    logic saw_uart_access;
    logic saw_gpio_access;
    logic saw_timer_access;
    logic saw_irq_take;
    logic gpio_edge_issued;
    integer plic_claim_reads;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(32),
        .MEMORY_BYTES(16 * 1024 * 1024),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(mtime_tick),
        .uart_rx_i(uart_rx),
        .uart_tx_o(uart_tx),
        .spi_card_present_i(1'b0),
        .spi_clk_o(),
        .spi_mosi_o(),
        .spi_miso_i(1'b1),
        .spi_cs_n_o(),
        .gpio_in_i(gpio_in),
        .gpio_out_o(gpio_out),
        .external_irq_i(external_irq),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n),
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

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] enc_lui;
        input logic [4:0] rd;
        input logic [19:0] immediate;
        begin
            enc_lui = {immediate, rd, `RV64_OPCODE_LUI};
        end
    endfunction

    function automatic logic [31:0] enc_addi;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] immediate;
        begin
            enc_addi = {immediate, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_andi;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] immediate;
        begin
            enc_andi = {immediate, rs1, `RV64_FUNCT3_AND,
                        rd, `RV64_OPCODE_OP_IMM};
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

    function automatic logic [31:0] enc_load;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] immediate;
        input logic [2:0] funct3;
        begin
            enc_load = {immediate, rs1, funct3, rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic logic [31:0] enc_store;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] immediate;
        input logic [2:0] funct3;
        begin
            enc_store = {immediate[11:5], rs2, rs1, funct3,
                         immediate[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_csr;
        input logic [4:0] rd;
        input logic [11:0] csr;
        input logic [4:0] rs1;
        input logic [2:0] funct3;
        begin
            enc_csr = {csr, rs1, funct3, rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    function automatic logic [31:0] enc_branch;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [2:0] funct3;
        input integer byte_offset;
        logic signed [12:0] immediate;
        begin
            immediate = byte_offset;
            enc_branch = {immediate[12], immediate[10:5], rs2, rs1,
                          funct3, immediate[4:1], immediate[11],
                          `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input integer byte_offset;
        logic signed [20:0] immediate;
        begin
            immediate = byte_offset;
            enc_jal = {immediate[20], immediate[10:1], immediate[11],
                       immediate[19:12], rd, `RV64_OPCODE_JAL};
        end
    endfunction

    task automatic put_instr;
        input integer byte_offset;
        input logic [31:0] instruction;
        integer word_index;
        begin
            word_index = byte_offset >> 3;
            if (byte_offset[2]) begin
                dut.u_memory.memory_q[word_index][63:32] = instruction;
            end else begin
                dut.u_memory.memory_q[word_index][31:0] = instruction;
            end
        end
    endtask

    function automatic logic [63:0] ram_word;
        input integer byte_offset;
        begin
            ram_word = dut.u_memory.memory_q[byte_offset >> 3];
        end
    endfunction

    initial begin : firmware_image
        integer pc;
        integer poll_pc;
        integer loop_pc;
        integer branch_sw_pc;
        integer branch_timer_pc;
        integer branch_external_pc;
        integer software_pc;
        integer timer_pc;
        integer external_pc;
        integer branch_first_claim_pc;
        integer first_claim_pc;
        integer clear_select_pc;
        integer branch_clear_timer_pc;
        integer clear_timer_pc;
        integer complete_pc;
        integer jump_common_sw_pc;
        integer jump_common_timer_pc;
        integer jump_clear_select_pc;
        integer jump_complete_gpio_pc;
        integer common_pc;
        integer branch_mret_pc;
        integer mret_pc;

        rst_n = 1'b0;
        mtime_tick = 1'b1;
        uart_rx = 1'b1;
        gpio_in = 32'h0;
        external_irq = 29'h0;
        gpio_edge_issued = 1'b0;

        // Wait until the synthesizable RAM's own initialization block has
        // completed, then install a small self-checking platform program.
        #1;
        pc = 0;

        // x1 is RAM base on entry from the three-instruction boot ROM.
        put_instr(pc, enc_addi(5'd24, 5'd0, 12'h000)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd25, 5'd0, 12'h000)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h055)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd1, 12'h338,
                                `RV64_FUNCT3_SD)); pc = pc + 4;

        put_instr(pc, enc_addi(5'd2, 5'd1, HANDLER_OFFSET[11:0]));
        pc = pc + 4;
        put_instr(pc, enc_csr(5'd0, `RV64_CSR_MTVEC, 5'd2,
                              `RV64_ZICSR_FUNCT3_CSRRW)); pc = pc + 4;

        // Materialize all global MMIO bases and frequently used subregions.
        put_instr(pc, enc_lui(5'd9, 20'h10000)); pc = pc + 4;  // UART
        put_instr(pc, enc_lui(5'd10, 20'h02000)); pc = pc + 4; // CLINT
        put_instr(pc, enc_lui(5'd11, 20'h0c000)); pc = pc + 4; // PLIC
        put_instr(pc, enc_lui(5'd12, 20'h10010)); pc = pc + 4; // GPIO
        put_instr(pc, enc_lui(5'd16, 20'h10020)); pc = pc + 4; // timer
        put_instr(pc, enc_lui(5'd13, 20'h00200)); pc = pc + 4;
        put_instr(pc, enc_add(5'd13, 5'd11, 5'd13)); pc = pc + 4;
        put_instr(pc, enc_lui(5'd14, 20'h00002)); pc = pc + 4;
        put_instr(pc, enc_add(5'd14, 5'd11, 5'd14)); pc = pc + 4;
        put_instr(pc, enc_lui(5'd19, 20'h00001)); pc = pc + 4;
        put_instr(pc, enc_add(5'd19, 5'd11, 5'd19)); pc = pc + 4;
        put_instr(pc, enc_lui(5'd18, 20'h00004)); pc = pc + 4;
        put_instr(pc, enc_add(5'd18, 5'd10, 5'd18)); pc = pc + 4;
        put_instr(pc, enc_lui(5'd17, 20'h0000c)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd17, 5'd17, 12'hff8)); pc = pc + 4;
        put_instr(pc, enc_add(5'd17, 5'd10, 5'd17)); pc = pc + 4;

        // Smoke the non-interrupt MMIO datapaths: UART scratch and GPIO out.
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h05a)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd9, 12'h007,
                                `RV64_FUNCT3_SB)); pc = pc + 4;
        put_instr(pc, enc_load(5'd21, 5'd9, 12'h007,
                               `RV64_FUNCT3_LBU)); pc = pc + 4;
        put_instr(pc, enc_store(5'd21, 5'd1, 12'h328,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h0a5)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd12, 12'h008,
                                `RV64_FUNCT3_SD)); pc = pc + 4;

        // GPIO pin zero is a latched rising-edge source (PLIC ID 2).
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd12, 12'h010,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd12, 12'h018,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd12, 12'h020,
                                `RV64_FUNCT3_SD)); pc = pc + 4;

        // PLIC ID 3 (timer) outranks ID 2 (GPIO); both are enabled.
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h003)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd11, 12'h008,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h005)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd11, 12'h00c,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h00c)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd14, 12'h000,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h004)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd13, 12'h000,
                                `RV64_FUNCT3_SW)); pc = pc + 4;

        // Start the platform timer.  The testbench raises GPIO only once the
        // timer has expired, then software waits for both PLIC pending bits.
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h018)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd16, 12'h010,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h005)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd16, 12'h000,
                                `RV64_FUNCT3_SD)); pc = pc + 4;

        poll_pc = pc;
        put_instr(pc, enc_load(5'd20, 5'd19, 12'h000,
                               `RV64_FUNCT3_LW)); pc = pc + 4;
        put_instr(pc, enc_andi(5'd20, 5'd20, 12'h00c)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd21, 5'd0, 12'h00c)); pc = pc + 4;
        put_instr(pc, enc_branch(5'd20, 5'd21, `RV64_FUNCT3_BNE,
                                 poll_pc - pc)); pc = pc + 4;

        // Arm CLINT timer and software interrupts, then enable MSIP, MTIP, and
        // the PLIC's supervisor-external interrupt together.  SEIP remains
        // undelegated in this M-mode test program, so it traps through mtvec.
        put_instr(pc, enc_load(5'd20, 5'd17, 12'h000,
                               `RV64_FUNCT3_LD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd20, 12'h0c8)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd18, 12'h000,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd20, 5'd0, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_store(5'd20, 5'd10, 12'h000,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd15, 5'd0, 12'h288)); pc = pc + 4;
        put_instr(pc, enc_csr(5'd0, `RV64_CSR_MIE, 5'd15,
                              `RV64_ZICSR_FUNCT3_CSRRW)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd15, 5'd0, 12'h008)); pc = pc + 4;
        put_instr(pc, enc_csr(5'd0, `RV64_CSR_MSTATUS, 5'd15,
                              `RV64_ZICSR_FUNCT3_CSRRS)); pc = pc + 4;
        loop_pc = pc;
        put_instr(pc, enc_jal(5'd0, loop_pc - pc)); pc = pc + 4;

        if (pc > HANDLER_OFFSET) begin
            $fatal(1, "platform firmware overlaps interrupt handler");
        end

        // Interrupt handler: record each architectural cause, clear its
        // source through MMIO, claim/complete PLIC requests, then halt after
        // software, timer, and two external deliveries have all arrived.
        pc = HANDLER_OFFSET;
        put_instr(pc, enc_csr(5'd20, `RV64_CSR_MCAUSE, 5'd0,
                              `RV64_ZICSR_FUNCT3_CSRRS)); pc = pc + 4;
        put_instr(pc, enc_andi(5'd21, 5'd20, 12'h00f)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd22, 5'd0, 12'h003)); pc = pc + 4;
        branch_sw_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, enc_addi(5'd22, 5'd0, 12'h007)); pc = pc + 4;
        branch_timer_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, enc_addi(5'd22, 5'd0, 12'h009)); pc = pc + 4;
        branch_external_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, `RV64_INSTR_EBREAK); pc = pc + 4;

        software_pc = pc;
        put_instr(pc, enc_store(5'd20, 5'd1, 12'h300,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_store(5'd0, 5'd10, 12'h000,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        jump_common_sw_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;

        timer_pc = pc;
        put_instr(pc, enc_store(5'd20, 5'd1, 12'h308,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd22, 5'd0, 12'hfff)); pc = pc + 4;
        put_instr(pc, enc_store(5'd22, 5'd18, 12'h000,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        jump_common_timer_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;

        external_pc = pc;
        put_instr(pc, enc_store(5'd20, 5'd1, 12'h310,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_load(5'd22, 5'd13, 12'h004,
                               `RV64_FUNCT3_LW)); pc = pc + 4;
        branch_first_claim_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, enc_store(5'd22, 5'd1, 12'h320,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        jump_clear_select_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        first_claim_pc = pc;
        put_instr(pc, enc_store(5'd22, 5'd1, 12'h318,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        clear_select_pc = pc;
        put_instr(pc, enc_addi(5'd25, 5'd25, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd21, 5'd0, 12'h003)); pc = pc + 4;
        branch_clear_timer_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, enc_addi(5'd21, 5'd0, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_store(5'd21, 5'd12, 12'h028,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        jump_complete_gpio_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        clear_timer_pc = pc;
        put_instr(pc, enc_addi(5'd21, 5'd0, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_store(5'd21, 5'd16, 12'h020,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_store(5'd0, 5'd13, 12'h000,
                                `RV64_FUNCT3_SW)); pc = pc + 4;
        complete_pc = pc;
        put_instr(pc, enc_store(5'd22, 5'd13, 12'h004,
                                `RV64_FUNCT3_SW)); pc = pc + 4;

        common_pc = pc;
        put_instr(pc, enc_addi(5'd24, 5'd24, 12'h001)); pc = pc + 4;
        put_instr(pc, enc_store(5'd24, 5'd1, 12'h330,
                                `RV64_FUNCT3_SD)); pc = pc + 4;
        put_instr(pc, enc_addi(5'd21, 5'd0, 12'h004)); pc = pc + 4;
        branch_mret_pc = pc;
        put_instr(pc, 32'h0); pc = pc + 4;
        put_instr(pc, `RV64_INSTR_EBREAK); pc = pc + 4;
        mret_pc = pc;
        put_instr(pc, `RV64_INSTR_MRET); pc = pc + 4;

        // Resolve forward branches and jumps after all handler labels exist.
        put_instr(branch_sw_pc,
                  enc_branch(5'd21, 5'd22, `RV64_FUNCT3_BEQ,
                             software_pc - branch_sw_pc));
        put_instr(branch_timer_pc,
                  enc_branch(5'd21, 5'd22, `RV64_FUNCT3_BEQ,
                             timer_pc - branch_timer_pc));
        put_instr(branch_external_pc,
                  enc_branch(5'd21, 5'd22, `RV64_FUNCT3_BEQ,
                             external_pc - branch_external_pc));
        put_instr(jump_common_sw_pc,
                  enc_jal(5'd0, common_pc - jump_common_sw_pc));
        put_instr(jump_common_timer_pc,
                  enc_jal(5'd0, common_pc - jump_common_timer_pc));
        put_instr(branch_first_claim_pc,
                  enc_branch(5'd25, 5'd0, `RV64_FUNCT3_BEQ,
                             first_claim_pc - branch_first_claim_pc));
        put_instr(jump_clear_select_pc,
                  enc_jal(5'd0, clear_select_pc - jump_clear_select_pc));
        put_instr(branch_clear_timer_pc,
                  enc_branch(5'd22, 5'd21, `RV64_FUNCT3_BEQ,
                             clear_timer_pc - branch_clear_timer_pc));
        put_instr(jump_complete_gpio_pc,
                  enc_jal(5'd0, complete_pc - jump_complete_gpio_pc));
        put_instr(branch_mret_pc,
                  enc_branch(5'd24, 5'd21, `RV64_FUNCT3_BNE,
                             mret_pc - branch_mret_pc));

        repeat (3) @(posedge clk);
        @(negedge clk);
        #2 rst_n = 1'b1;

        // Make the GPIO edge coincide with an already asserted timer source
        // so both requests are pending before CPU IRQ enable.
        wait (dut.timer_irq);
        @(negedge clk);
        gpio_in[0] = 1'b1;
        gpio_edge_issued = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_soc_release <= 1'b0;
            saw_core_release <= 1'b0;
            saw_rom_fetch <= 1'b0;
            saw_ram_fetch <= 1'b0;
            saw_clint_access <= 1'b0;
            saw_plic_access <= 1'b0;
            saw_uart_access <= 1'b0;
            saw_gpio_access <= 1'b0;
            saw_timer_access <= 1'b0;
            saw_irq_take <= 1'b0;
            plic_claim_reads <= 0;
        end else begin
            if (soc_rst_n) begin
                saw_soc_release <= 1'b1;
            end
            if (core_rst_n) begin
                if (!soc_rst_n || !saw_soc_release) begin
                    $fatal(1, "core reset released before a settled platform reset");
                end
                saw_core_release <= 1'b1;
            end

            if (!core_rst_n && dut.core_mem_valid) begin
                $fatal(1, "core issued a bus request while held in reset");
            end

            if (dut.rom_valid && !dut.rom_write && dut.rom_addr == 64'h0) begin
                saw_rom_fetch <= 1'b1;
            end
            if (dut.memory_valid && !dut.memory_write &&
                dut.memory_addr == 64'h0) begin
                saw_ram_fetch <= 1'b1;
            end
            if (dut.clint_valid) saw_clint_access <= 1'b1;
            if (dut.plic_valid) begin
                saw_plic_access <= 1'b1;
                if (dut.plic_ready && !dut.plic_write &&
                    dut.plic_addr == 64'h0000_0000_0020_0004) begin
                    if (plic_claim_reads == 0) begin
                        if (dut.u_plic.threshold_q[2:0] !== 3'd4 ||
                            dut.u_plic.selected_id[31:0] !== 32'd3) begin
                            $fatal(1,
                                "first PLIC claim did not enforce threshold/priority");
                        end
                    end else if (plic_claim_reads == 1) begin
                        if (dut.u_plic.threshold_q[2:0] !== 3'd0 ||
                            dut.u_plic.selected_id[31:0] !== 32'd2) begin
                            $fatal(1,
                                "second PLIC claim did not follow threshold lowering");
                        end
                    end else begin
                        $fatal(1, "unexpected extra PLIC claim read");
                    end
                    plic_claim_reads <= plic_claim_reads + 1;
                end
            end
            if (dut.uart_valid) saw_uart_access <= 1'b1;
            if (dut.gpio_valid) saw_gpio_access <= 1'b1;
            if (dut.timer_valid) saw_timer_access <= 1'b1;

            if (dut.core_mem_valid && dut.core_mem_ready &&
                dut.core_mem_error) begin
                $fatal(1, "platform firmware hit decode error at %016x",
                       dut.core_mem_addr);
            end

            if (dut.u_core.u_core.hard_flush_irq_req) begin
                saw_irq_take <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (core_rst_n && dbg_halted) begin
            #1;
            if (!saw_soc_release || !saw_core_release) begin
                $fatal(1, "reset sequence was not observed");
            end
            if (!saw_rom_fetch || !saw_ram_fetch) begin
                $fatal(1, "ROM-to-RAM boot path missing: rom=%b ram=%b",
                       saw_rom_fetch, saw_ram_fetch);
            end
            if (!saw_clint_access || !saw_plic_access || !saw_uart_access ||
                !saw_gpio_access || !saw_timer_access) begin
                $fatal(1,
                    "incomplete MMIO coverage clint=%b plic=%b uart=%b gpio=%b timer=%b",
                    saw_clint_access, saw_plic_access, saw_uart_access,
                    saw_gpio_access, saw_timer_access);
            end
            if (!saw_irq_take || !gpio_edge_issued) begin
                $fatal(1, "interrupt delivery was not exercised");
            end

            if (ram_word('h338) !== 64'h55) begin
                $fatal(1, "RAM boot marker mismatch: %016x", ram_word('h338));
            end
            if (ram_word('h328) !== 64'h5a) begin
                $fatal(1, "UART scratch readback mismatch: %016x",
                       ram_word('h328));
            end
            if (gpio_out !== 32'h0000_00a5) begin
                $fatal(1, "GPIO output mismatch: %08x", gpio_out);
            end
            if (ram_word('h300) !== (INTERRUPT_BIT | 64'd3)) begin
                $fatal(1, "MSIP cause mismatch: %016x", ram_word('h300));
            end
            if (ram_word('h308) !== (INTERRUPT_BIT | 64'd7)) begin
                $fatal(1, "MTIP cause mismatch: %016x", ram_word('h308));
            end
            if (ram_word('h310) !== (INTERRUPT_BIT | 64'd9)) begin
                $fatal(1, "SEIP cause mismatch: %016x", ram_word('h310));
            end
            if (ram_word('h318) !== 64'd3 || ram_word('h320) !== 64'd2) begin
                $fatal(1, "PLIC claim order mismatch: first=%0d second=%0d",
                       ram_word('h318), ram_word('h320));
            end
            if (plic_claim_reads != 2) begin
                $fatal(1, "PLIC claim read count mismatch: %0d",
                       plic_claim_reads);
            end
            if (ram_word('h330) !== 64'd4) begin
                $fatal(1, "interrupt completion count mismatch: %0d",
                       ram_word('h330));
            end
            if (dut.clint_msip !== 1'b0 || dut.clint_mtip !== 1'b0 ||
                dut.plic_seip !== 1'b0 || dut.gpio_irq !== 1'b0 ||
                dut.timer_irq !== 1'b0) begin
                $fatal(1,
                    "interrupt source not quiescent msip=%b mtip=%b seip=%b gpio=%b timer=%b",
                    dut.clint_msip, dut.clint_mtip, dut.plic_seip,
                    dut.gpio_irq, dut.timer_irq);
            end

            $display("PASS: platform reset, ROM/RAM boot, MMIO, CLINT, and PLIC end-to-end");
            $finish;
        end
    end

    initial begin
        repeat (12000) @(posedge clk);
        $fatal(1,
            "platform timeout pc=%016x halted=%b count=%0d msip=%b mtip=%b seip=%b ifvalid=%b idvalid=%b exvalid=%b wbvalid=%b mstatus=%016x mie=%016x",
            dbg_pc, dbg_halted, ram_word('h330),
            dut.clint_msip, dut.clint_mtip, dut.plic_seip,
            dut.u_core.u_core.fetch_decode_valid,
            dut.u_core.u_core.if_id_out_valid,
            dut.u_core.u_core.dispatch_exec_valid,
            dut.u_core.u_core.exec_wb_valid,
            dut.u_core.u_core.u_csrs.mstatus_q,
            dut.u_core.u_core.u_csrs.mie_q);
    end

endmodule
