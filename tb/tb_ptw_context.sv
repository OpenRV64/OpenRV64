`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"
`include "complex/protocol/defs.v"

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
    logic saw_ptw_shootdown;
    logic saw_satp_restart;
    logic saw_satp_shootdown;
    logic saw_satp_barrier_busy;
    logic saw_satp_barrier_release;
    logic satp_barrier_active;
    integer satp_barrier_cycles;
    logic saw_translated_fetch;
    logic saw_sfence;
    logic saw_load_page_fault;
    logic [63:0] load_page_fault_tval;
    logic block_ptw;
    logic saw_instr_access_fault;
    logic [63:0] instr_access_fault_tval;
    logic icx_req_valid;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    logic [2:0] icx_req_size;
    logic [63:0] icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    logic icx_resp_valid;
    logic icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic [2:0] fence_response_delay;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[13:3]] : 64'd0;
    assign mem_error = mem_valid && !mem_addr_in_range;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(1'b0),
        .PTW_ICX_TIMEOUT_CYCLES(8)
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
        .m_axi_arready(1'b0),
        .m_axi_rid('0),
        .m_axi_rdata('0),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0),
        .m_axi_awready(1'b0),
        .m_axi_wready(1'b0),
        .m_axi_bid('0),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .icx_req_valid(icx_req_valid),
        .icx_req_ready(icx_req_ready),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id),
        .icx_req_op(icx_req_op),
        .icx_req_order(icx_req_order),
        .icx_req_kind(icx_req_kind),
        .icx_req_size(icx_req_size),
        .icx_req_addr(icx_req_addr),
        .icx_req_burst_len(icx_req_burst_len),
        .icx_wdata_ready(1'b1),
        .icx_resp_valid(icx_resp_valid),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id),
        .icx_resp_txn_id(icx_resp_txn_id),
        .icx_resp_source_id(icx_resp_source_id),
        .icx_resp_beat_index('0),
        .icx_resp_last(1'b1),
        .icx_resp_rdata(icx_resp_rdata),
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
    // The timeout phase blocks page-table reads, not maintenance traffic.
    // SATP retirement now issues a ICX fence before the first translated
    // fetch, and that fence must remain serviceable.
    assign icx_req_ready = !icx_resp_valid && (fence_response_delay == 0) &&
        (!block_ptw || (icx_req_op == `OPENRV64_ICX_OP_FENCE));

    always @(posedge clk) begin
        if (!rst_n) begin
            icx_resp_valid <= 1'b0;
            icx_resp_hart_id <= '0;
            icx_resp_txn_id <= '0;
            icx_resp_source_id <= '0;
            icx_resp_rdata <= '0;
            fence_response_delay <= 3'd0;
            satp_barrier_active <= 1'b0;
            satp_barrier_cycles <= 0;
        end else begin
            if (icx_resp_valid && icx_resp_ready)
                icx_resp_valid <= 1'b0;
            if (fence_response_delay != 0) begin
                fence_response_delay <= fence_response_delay - 1'b1;
                if (fence_response_delay == 1)
                    icx_resp_valid <= 1'b1;
            end
            if (icx_req_valid && icx_req_ready) begin
                if (icx_req_source_id != `OPENRV64_ICX_SOURCE_PTW ||
                    icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                    icx_req_burst_len != '0)
                    $fatal(1, "invalid PTW ICX request");
                if ((icx_req_op == `OPENRV64_ICX_OP_READ) &&
                    (icx_req_size != 3'd6))
                    $fatal(1, "invalid PTW line read");
                if ((icx_req_op == `OPENRV64_ICX_OP_FENCE) &&
                    (icx_req_size != 3'd0))
                    $fatal(1, "invalid PTW shootdown request");
                if ((icx_req_op == `OPENRV64_ICX_OP_FENCE) &&
                    (icx_req_order != `OPENRV64_ICX_ORDER_ACQ_REL))
                    $fatal(1, "PTW shootdown is not an ACQ_REL fence");
                if ((icx_req_op != `OPENRV64_ICX_OP_READ) &&
                    (icx_req_op != `OPENRV64_ICX_OP_FENCE))
                    $fatal(1, "unexpected PTW operation");
                icx_resp_hart_id <= icx_req_hart_id;
                icx_resp_txn_id <= icx_req_txn_id;
                icx_resp_source_id <= icx_req_source_id;
                if (icx_req_op == `OPENRV64_ICX_OP_READ) begin
                    icx_resp_valid <= 1'b1;
                    for (lane = 0; lane < 8; lane = lane + 1)
                        icx_resp_rdata[lane * 64 +: 64] <=
                            memory[icx_req_addr[13:3] + lane];
                end else begin
                    icx_resp_rdata <= '0;
                    // Hold the fence response long enough to prove that a
                    // Bare-mode fetch cannot escape after the SATP write.
                    fence_response_delay <= 3'd4;
                    saw_ptw_shootdown <= 1'b1;
                    if (!saw_sfence)
                        saw_satp_shootdown <= 1'b1;
                end
            end
        end

        if (rst_n && mem_valid && mem_ready && mem_write &&
            mem_addr_in_range) begin
            for (lane = 0; lane < 8; lane = lane + 1) begin
                if (mem_wstrb[lane]) begin
                    memory[mem_addr[13:3]][lane * 8 +: 8] <=
                        mem_wdata[lane * 8 +: 8];
                end
            end
        end

        if (rst_n && icx_req_valid && icx_req_ready &&
            (icx_req_addr == 64'h0000_0000_0000_1000)) begin
            saw_ptw_read <= 1'b1;
        end
        if (rst_n && mem_valid && !mem_write &&
            (mem_addr == 64'h0000_0000_0000_1008))
            $fatal(1, "PTW PTE read leaked onto scalar memory bus");
        if (rst_n && mem_valid && !mem_write &&
            (mem_addr == 64'h0000_0000_0000_2000)) begin
            saw_translated_fetch <= 1'b1;
        end
        if (rst_n && dut.u_core.retire_sfence_vma) begin
            saw_sfence <= 1'b1;
        end
        if (rst_n && dut.u_core.retire_satp_write) begin
            if (!dut.u_core.hard_flush_restart_req)
                $fatal(1, "retiring satp write did not restart frontend");
            if (!dut.u_core.translation_barrier_busy)
                $fatal(1, "satp retirement did not start translation barrier");
            saw_satp_restart <= 1'b1;
            satp_barrier_active <= 1'b1;
        end
        if (rst_n && satp_barrier_active) begin
            if (dut.u_core.translation_barrier_busy) begin
                saw_satp_barrier_busy <= 1'b1;
                satp_barrier_cycles <= satp_barrier_cycles + 1;
                if (dut.u_core.fetch_pc_valid)
                    $fatal(1, "fetch escaped before SATP fence completion");
                if (dut.u_core.exec_mem_valid && dut.u_core.exec_mem_ready)
                    $fatal(1, "LSU escaped before SATP fence completion");
            end else begin
                saw_satp_barrier_release <= 1'b1;
                satp_barrier_active <= 1'b0;
            end
        end
        if (rst_n && dut.u_core.trap_enter &&
            !dut.u_core.trap_interrupt &&
            (dut.u_core.trap_cause ==
             `RV64_EXCEPT_CAUSE_LOAD_PAGE_FAULT)) begin
            saw_load_page_fault <= 1'b1;
            load_page_fault_tval <= dut.u_core.trap_tval;
        end
        if (rst_n && dut.u_core.trap_enter &&
            !dut.u_core.trap_interrupt &&
            (dut.u_core.trap_cause ==
             `RV64_EXCEPT_CAUSE_INSTR_ACCESS_FAULT)) begin
            saw_instr_access_fault <= 1'b1;
            instr_access_fault_tval <= dut.u_core.trap_tval;
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
        put_instr(64'h0008, enc_addi(5'd2, `RV64_REG_X0, 12'h01f));
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

        // A 16 KiB NAPOT region covers physical 0x0000-0x3fff.
        memory[64'h100 >> 3] = 64'h0000_0000_0000_07ff;
        memory[64'h108 >> 3] = 64'h8000_0000_0000_0001;
        memory[64'h110 >> 3] = 64'h0000_0000_0000_0800;

        saw_ptw_read = 1'b0;
        saw_ptw_shootdown = 1'b0;
        saw_satp_restart = 1'b0;
        saw_satp_shootdown = 1'b0;
        saw_satp_barrier_busy = 1'b0;
        saw_satp_barrier_release = 1'b0;
        satp_barrier_active = 1'b0;
        satp_barrier_cycles = 0;
        saw_translated_fetch = 1'b0;
        saw_sfence = 1'b0;
        saw_load_page_fault = 1'b0;
        load_page_fault_tval = 64'hffff_ffff_ffff_ffff;
        block_ptw = 1'b0;
        saw_instr_access_fault = 1'b0;
        instr_access_fault_tval = 64'hffff_ffff_ffff_ffff;
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
        if (!saw_ptw_read || !saw_ptw_shootdown ||
            !saw_satp_restart || !saw_satp_shootdown ||
            !saw_satp_barrier_busy || !saw_satp_barrier_release ||
            !saw_translated_fetch || !saw_sfence) begin
            $fatal(1,
                   "missing PTW/shootdown/satp-restart/satp-shootdown/barrier-busy/barrier-release/fetch/SFENCE observations: %0b/%0b/%0b/%0b/%0b/%0b/%0b/%0b",
                   saw_ptw_read, saw_ptw_shootdown,
                   saw_satp_restart, saw_satp_shootdown,
                   saw_satp_barrier_busy, saw_satp_barrier_release,
                   saw_translated_fetch, saw_sfence);
        end
        if (satp_barrier_cycles < 4)
            $fatal(1, "SATP barrier released before delayed fence response");
        if (memory[64'h3000 >> 3] != 64'd42) begin
            $fatal(1, "translated supervisor store mismatch: %016x",
                   memory[64'h3000 >> 3]);
        end
        if (!saw_load_page_fault || load_page_fault_tval != 64'd0) begin
            $fatal(1, "load page-fault context mismatch: seen=%0b tval=%016x",
                   saw_load_page_fault, load_page_fault_tval);
        end

        // Repeat the handoff with a ICX endpoint that never accepts the first
        // PTE request.  The watchdog must turn the blocked instruction walk
        // into a precise instruction access fault at the original virtual PC.
        @(negedge clk);
        rst_n = 1'b0;
        block_ptw = 1'b1;
        saw_instr_access_fault = 1'b0;
        instr_access_fault_tval = 64'hffff_ffff_ffff_ffff;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        cycles = 0;
        while (!dbg_halted && cycles < 260) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        if (!dbg_halted)
            $fatal(1, "PTW timeout context did not reach trap handler");
        if (!saw_instr_access_fault ||
            instr_access_fault_tval != 64'h0000_0000_4000_2000) begin
            $fatal(1,
                   "instruction access-fault context mismatch: seen=%0b tval=%016x",
                   saw_instr_access_fault, instr_access_fault_tval);
        end

        $display("PASS: satp, Sv39 PTW, physical PMP, SFENCE.VMA, page-fault, and timeout access-fault context");
        $finish;
    end

endmodule
