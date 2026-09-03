`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "core/isa/rv64-i.v"

module tb_top_3p_tomasulo_pmp;
    localparam integer PMP_ENTRIES = 8;

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
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire icx_resp_ready;

    reg [63:0] memory [0:127];
    reg pending_q;
    reg pending_write_q;
    reg [63:0] pending_addr_q;
    reg [63:0] pending_wdata_q;
    reg [7:0] pending_wstrb_q;
    reg icx_resp_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id_q;
    integer byte_index;
    integer initialize_index;
    integer instruction_index;
    integer pmp_entry;
    integer cycles;
    integer pmp_preflush_count;
    integer pmp_accept_count;
    integer pmp_flush_count;
    reg pmp_accept_prev_q;

    openrv64_top #(
        .RESET_VECTOR(64'd0),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .RETIRE_DEPTH(64),
        .ISSUE_WINDOW_DEPTH(32),
        .PHYS_REG_COUNT(63),
        .RENAME_MODE(`OPENRV64_RENAME_TOMASULO),
        .ENABLE_ISSUE_WINDOW(1),
        .ENABLE_SPECULATION_WINDOW(1),
        .COMPLETION_FORWARD_MASK_3P(3'b111),
        .BRANCH_COMPLETION_FORWARD_MASK_3P(3'b000),
        .RELAX_WAW_3P(1),
        .ENABLE_RV64M(1),
        .ENABLE_RV64ZBB(1),
        .BANKED_GPR_3P(1),
        .FPGA_GPR_LUTRAM_3P(0),
        .ENABLE_L1I(0),
        .ENABLE_L1D(0)
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
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0),
        .m_axi_awready(1'b0),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .icx_req_valid(icx_req_valid),
        .icx_req_ready(1'b1),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id),
        .icx_wdata_ready(1'b1),
        .icx_resp_valid(icx_resp_valid_q),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id_q),
        .icx_resp_txn_id(icx_resp_txn_id_q),
        .icx_resp_source_id(icx_resp_source_id_q),
        .icx_resp_beat_index(
            {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last(1'b1),
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
        .dbg_halted(dbg_halted)
    );

    always #5 clk = ~clk;

    always @* begin
        mem_ready = pending_q;
        mem_rdata = pending_q ? memory[pending_addr_q[9:3]] : 64'd0;
        mem_error = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q <= 1'b0;
            pending_write_q <= 1'b0;
            pending_addr_q <= 64'd0;
            pending_wdata_q <= 64'd0;
            pending_wstrb_q <= 8'd0;
        end else if (pending_q) begin
            if (pending_write_q)
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1)
                    if (pending_wstrb_q[byte_index])
                        memory[pending_addr_q[9:3]][byte_index*8 +: 8] <=
                            pending_wdata_q[byte_index*8 +: 8];
            pending_q <= 1'b0;
        end else if (mem_valid) begin
            pending_q <= 1'b1;
            pending_write_q <= mem_write;
            pending_addr_q <= mem_addr;
            pending_wdata_q <= mem_wdata;
            pending_wstrb_q <= mem_wstrb;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_resp_valid_q <= 1'b0;
            icx_resp_hart_id_q <= '0;
            icx_resp_txn_id_q <= '0;
            icx_resp_source_id_q <= '0;
        end else begin
            if (icx_resp_valid_q && icx_resp_ready)
                icx_resp_valid_q <= 1'b0;
            if (icx_req_valid) begin
                icx_resp_valid_q <= 1'b1;
                icx_resp_hart_id_q <= icx_req_hart_id;
                icx_resp_txn_id_q <= icx_req_txn_id;
                icx_resp_source_id_q <= icx_req_source_id;
            end
        end
    end

    function automatic [31:0] encode_i;
        input [11:0] immediate;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_i = {immediate, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_s;
        input [11:0] immediate;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            encode_s = {immediate[11:5], rs2, rs1, funct3,
                        immediate[4:0], opcode};
        end
    endfunction

    function automatic [31:0] encode_csr;
        input [11:0] csr;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        begin
            encode_csr = {csr, rs1, funct3, rd, `RV64_OPCODE_SYSTEM};
        end
    endfunction

    task automatic put_instruction;
        input integer index;
        input [31:0] instruction;
        begin
            if (index[0])
                memory[index >> 1][63:32] = instruction;
            else
                memory[index >> 1][31:0] = instruction;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: Tomasulo 3P PMP: %0s", message);
            $display("pc=%h instr=%h dq=%0d rq=%0d barrier=%b csr=%b/%h ready=%b",
                     dbg_pc, dbg_instr,
                     dut.g_backend_3p.u_core_3p.backend_dispatch_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_retire_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_barrier,
                     dut.g_backend_3p.u_core_3p.backend_csr_write,
                     dut.g_backend_3p.u_core_3p.backend_csr_write_addr,
                     dut.g_backend_3p.u_core_3p.csr_write_ready);
            $fatal(1);
        end
    endtask

    // Each PMP write is a two-sided full-flush barrier.  The first presentation
    // is suppressed at the endpoint and restarts at the PMP instruction.  Its
    // replay performs the write; the delayed update pulse then coincides with
    // retirement and restarts after it.  This also catches the original bug
    // where endpoint acceptance flushed before CSRRW's destination committed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pmp_preflush_count <= 0;
            pmp_accept_count <= 0;
            pmp_flush_count <= 0;
            pmp_accept_prev_q <= 1'b0;
        end else begin
            pmp_accept_prev_q <=
                dut.g_backend_3p.u_core_3p.backend_pmp_update_accept;

            if (dut.g_backend_3p.u_core_3p.backend_csr_write &&
                ((dut.g_backend_3p.u_core_3p.backend_csr_write_addr ==
                  `RV64_CSR_PMPCFG0) ||
                 (dut.g_backend_3p.u_core_3p.backend_csr_write_addr ==
                  `RV64_CSR_PMPCFG2) ||
                 ((dut.g_backend_3p.u_core_3p.backend_csr_write_addr >=
                   `RV64_CSR_PMPADDR0) &&
                  (dut.g_backend_3p.u_core_3p.backend_csr_write_addr <=
                   `RV64_CSR_PMPADDR15)))) begin
                if (!dut.g_backend_3p.u_core_3p.backend_barrier)
                    fail("PMP write ran without the pre-write hard barrier");
                if (dut.g_backend_3p.u_core_3p.u_backend.pipe_id[
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] !==
                    dut.g_backend_3p.u_core_3p.u_backend.next_retire_id)
                    fail("PMP write ran before reaching the ROB head");
            end

            if (dut.g_backend_3p.u_core_3p.backend_pmp_preflush) begin
                pmp_preflush_count <= pmp_preflush_count + 1;
                if (dut.g_backend_3p.u_core_3p.
                        backend_csr_write_to_endpoint)
                    fail("suppressed PMP presentation reached the endpoint");
                if (!dut.g_backend_3p.u_core_3p.control_flush)
                    fail("PMP pre-write event did not cause a full flush");
                if (dut.g_backend_3p.u_core_3p.control_restart_target !==
                    dut.g_backend_3p.u_core_3p.backend_retire_pc)
                    fail("PMP pre-write flush did not replay the instruction");
            end

            if (dut.g_backend_3p.u_core_3p.backend_pmp_update_accept) begin
                pmp_accept_count <= pmp_accept_count + 1;
                if (!dut.g_backend_3p.u_core_3p.
                        backend_pmp_preflush_authorized)
                    fail("PMP write reached endpoint without a pre-flush");
            end

            if (dut.g_backend_3p.u_core_3p.backend_pmp_update) begin
                pmp_flush_count <= pmp_flush_count + 1;
                if (!pmp_accept_prev_q)
                    fail("PMP post-write flush lacked a prior accepted write");
                if (!dut.g_backend_3p.u_core_3p.control_flush)
                    fail("PMP update did not cause a post-write full flush");
                if (!dut.g_backend_3p.u_core_3p.backend_retire_arch[0])
                    fail("PMP post-write flush did not coincide with retire");
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        pending_q = 1'b0;
        pmp_preflush_count = 0;
        pmp_accept_count = 0;
        pmp_flush_count = 0;
        pmp_accept_prev_q = 1'b0;
        instruction_index = 0;
        for (initialize_index = 0; initialize_index < 128;
             initialize_index = initialize_index + 1)
            memory[initialize_index] = 64'h0000_0013_0000_0013;

        // x11 = one implemented PMP address bit above the 4 KiB grain.
        put_instruction(instruction_index,
            encode_i(12'd1, 0, 3'b000, 11, `RV64_OPCODE_OP_IMM));
        instruction_index = instruction_index + 1;
        put_instruction(instruction_index,
            encode_i(12'd10, 11, 3'b001, 11, `RV64_OPCODE_OP_IMM));
        instruction_index = instruction_index + 1;

        // Match OpenSBI's probe shape: read old, write probe value, then swap
        // the old value back while consuming the probe readback in rd.
        for (pmp_entry = 0; pmp_entry < PMP_ENTRIES;
             pmp_entry = pmp_entry + 1) begin
            put_instruction(instruction_index,
                encode_csr(`RV64_CSR_PMPADDR0 + pmp_entry,
                           0, 3'b010, 28));
            instruction_index = instruction_index + 1;
            put_instruction(instruction_index,
                encode_csr(`RV64_CSR_PMPADDR0 + pmp_entry,
                           11, 3'b001, 0));
            instruction_index = instruction_index + 1;
            put_instruction(instruction_index,
                encode_csr(`RV64_CSR_PMPADDR0 + pmp_entry,
                           28, 3'b001, 13));
            instruction_index = instruction_index + 1;
            put_instruction(instruction_index,
                encode_s(12'h200 + pmp_entry*8, 13, 0, 3'b011,
                         `RV64_OPCODE_STORE));
            instruction_index = instruction_index + 1;
        end
        put_instruction(instruction_index, 32'h0010_0073);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        for (cycles = 0; cycles < 5000 && !dbg_halted;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
        end
        if (!dbg_halted)
            fail("did not reach EBREAK");
        repeat (40) @(posedge clk);

        for (pmp_entry = 0; pmp_entry < PMP_ENTRIES;
             pmp_entry = pmp_entry + 1) begin
            if (memory[64 + pmp_entry] !== 64'h0000_0000_0000_0400) begin
                $display("PMP entry %0d returned %016h",
                         pmp_entry, memory[64 + pmp_entry]);
                fail("probe readback was not ordered after its write");
            end
            if (dut.g_backend_3p.u_core_3p.u_csrs.u_pmp.pmpaddr_q[
                    pmp_entry] !== 37'd0)
                fail("probe did not restore the PMP entry");
        end

        if (pmp_accept_count != 2*PMP_ENTRIES)
            fail("did not accept both PMP writes for every probed entry");
        if (pmp_preflush_count != pmp_accept_count)
            fail("PMP pre-write flushes and writes were not one-to-one");
        if (pmp_flush_count != pmp_accept_count)
            fail("PMP writes and post-retirement flushes were not one-to-one");

        $display("PASS: Tomasulo 3P PMP writes have pre-write and post-retirement full flushes with ordered probe visibility");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_top_3p_tomasulo_pmp: timeout");
    end
endmodule
