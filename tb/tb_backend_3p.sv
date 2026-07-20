`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"

module tb_backend_3p #(
    parameter integer RELAX_HAZARDS = 0
);
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer SW = 3;
    localparam integer I_PRIV = 2;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_LSU_OP = 22;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg [2:0] decode_valid;
    wire [2:0] decode_ready;
    reg [3*IW-1:0] decode_payload;
    reg [2:0] decode_uses_rs1;
    reg [2:0] decode_uses_rs2;
    wire [11:0] csr_addr;
    reg [63:0] csr_rdata;
    reg csr_valid;
    reg csr_writable;
    wire csr_write;
    wire [11:0] csr_write_addr;
    wire [63:0] csr_wdata;
    wire mem_valid;
    reg mem_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag;
    reg mem_error;
    reg mem_page_fault;
    reg mem_access_allowed;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire mem_access;
    wire [63:0] mem_effective_addr;
    wire [2:0] mem_size;
    reg [63:0] mem_rdata;
    reg irq_pending;
    reg [4:0] irq_cause;
    wire redirect_valid;
    wire [63:0] redirect_id;
    wire [63:0] redirect_target;
    wire branch_resolved;
    wire branch_taken;
    wire [2:0] retire_arch;
    wire [1:0] retire_count;
    wire exception;
    wire halt;
    wire irq;
    wire mret;
    wire sret;
    wire fence_i;
    wire sfence_vma;
    wire [4:0] cause;
    wire [63:0] retire_pc;
    wire [63:0] retire_next_pc;
    wire [63:0] retire_tval;
    wire [63:0] retire_trace_id;
    wire [31:0] retire_instr;
    wire [4:0] retire_rd;
    wire [63:0] retire_wdata;
    wire [2:0] issue_valid;
    wire [2:0] complete_valid;
    wire [31:0] write_busy;
    wire barrier_active;
    wire [3:0] retire_occupancy;
    wire [2:0] dispatch_occupancy;

    openrv64_backend_3p #(
        .ENABLE_FULL_FORWARDING(1),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .ENABLE_POSTED_STORES(1),
        .STORE_FORWARD_BASE(64'h0),
        .STORE_FORWARD_SIZE(64'h1000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_frontend_i(squash),
        .decode_valid_i(decode_valid), .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .csr_addr_o(csr_addr), .csr_rdata_i(csr_rdata),
        .csr_valid_i(csr_valid), .csr_writable_i(csr_writable),
        .csr_write_o(csr_write), .csr_write_addr_o(csr_write_addr),
        .csr_wdata_o(csr_wdata),
        .mem_valid_o(mem_valid), .mem_ready_i(mem_ready),
        .mem_tag_o(mem_tag), .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready), .mem_resp_tag_i(mem_resp_tag),
        .mem_error_i(mem_error), .mem_page_fault_i(mem_page_fault),
        .mem_access_allowed_i(mem_access_allowed),
        .mem_write_o(mem_write), .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata), .mem_wstrb_o(mem_wstrb),
        .mem_access_o(mem_access),
        .mem_effective_addr_o(mem_effective_addr), .mem_size_o(mem_size),
        .mem_rdata_i(mem_rdata), .irq_pending_i(irq_pending),
        .irq_cause_i(irq_cause), .redirect_valid_o(redirect_valid),
        .redirect_id_o(redirect_id), .redirect_target_o(redirect_target),
        .branch_resolved_o(branch_resolved), .branch_taken_o(branch_taken),
        .retire_arch_o(retire_arch), .retire_count_o(retire_count),
        .exception_o(exception), .halt_o(halt), .irq_o(irq),
        .mret_o(mret), .sret_o(sret), .fence_i_o(fence_i),
        .sfence_vma_o(sfence_vma), .cause_o(cause),
        .retire_pc_o(retire_pc), .retire_next_pc_o(retire_next_pc),
        .retire_tval_o(retire_tval), .retire_trace_id_o(retire_trace_id),
        .retire_instr_o(retire_instr), .retire_rd_o(retire_rd),
        .retire_wdata_o(retire_wdata), .issue_valid_o(issue_valid),
        .complete_valid_o(complete_valid), .write_busy_o(write_busy),
        .barrier_active_o(barrier_active),
        .retire_occupancy_o(retire_occupancy),
        .dispatch_occupancy_o(dispatch_occupancy)
    );

    always #5 clk = ~clk;

    function automatic [IW-1:0] base_packet;
        input [63:0] trace;
        input [63:0] pc;
        input [31:0] instr;
        reg [IW-1:0] p;
        begin
            p = 0;
            p[I_TRACE +: 64] = trace;
            p[I_PC +: 64] = pc;
            p[I_INSTR +: 32] = instr;
            p[I_PRIV +: 2] = `RV64_PRIV_M;
            base_packet = p;
        end
    endfunction

    function automatic [IW-1:0] addi_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rd;
        input [63:0] imm;
        reg [IW-1:0] p;
        begin
            p = base_packet(trace, 64'h1000 + (trace << 2), 32'h0000_0013);
            p[I_RS1 +: 5] = rs1;
            p[I_RD +: 5] = rd;
            p[I_IMM +: 64] = imm;
            p[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            p[I_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
            p[I_REG_WRITE] = 1'b1;
            addi_packet = p;
        end
    endfunction

    function automatic [IW-1:0] load_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rd;
        input [63:0] imm;
        reg [IW-1:0] p;
        begin
            p = base_packet(trace, 64'h1000 + (trace << 2), 32'h0000_3003);
            p[I_RS1 +: 5] = rs1;
            p[I_RD +: 5] = rd;
            p[I_IMM +: 64] = imm;
            p[I_LSU_OP +: 5] = `RV64_LSU_OP_LD;
            p[I_MEM_READ] = 1'b1;
            p[I_REG_WRITE] = 1'b1;
            load_packet = p;
        end
    endfunction

    function automatic [IW-1:0] store_word_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rs2;
        input [63:0] imm;
        reg [IW-1:0] p;
        begin
            p = base_packet(trace, 64'h1000 + (trace << 2), 32'h0000_2023);
            p[I_RS1 +: 5] = rs1;
            p[I_RS2 +: 5] = rs2;
            p[I_IMM +: 64] = imm;
            p[I_LSU_OP +: 5] = `RV64_LSU_OP_SW;
            p[I_MEM_WRITE] = 1'b1;
            store_word_packet = p;
        end
    endfunction

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic fail;
        input [8*100-1:0] msg;
        begin $display("FAIL: %0s", msg); $fatal(1); end
    endtask

    task automatic send2;
        input [IW-1:0] p0;
        input [IW-1:0] p1;
        input [1:0] uses1;
        input [1:0] uses2;
        begin
            while (decode_ready[1:0] != 2'b11) tick();
            decode_payload = {{IW{1'b0}}, p1, p0};
            decode_uses_rs1 = {1'b0, uses1};
            decode_uses_rs2 = {1'b0, uses2};
            decode_valid = 3'b011;
            tick();
            decode_valid = 0;
            decode_payload = 0;
        end
    endtask

    reg [IW-1:0] p0;
    reg [IW-1:0] p1;
    integer cycles;
    reg saw_two_retire;
    reg saw_dependent_retire;
    reg saw_store_wait;
    reg saw_local_forward_issue;
    reg saw_local_forward_retire;
    reg saw_general_forward_issue;
    reg saw_general_forward_retire;
    reg saw_ordered_waw_store;
    reg saw_posted_store_retire;
    reg saw_nonoverlap_load_retire;
    reg saw_store_forward_retire;
    reg saw_aggressive_waw_issue;
    reg saw_branch_owner_accept;
    reg saw_branch_stale_reject;
    integer branch_monitor_lane;
    reg [4:0] branch_monitor_rd;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] old_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] dependent_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] posted_store_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] younger_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] aggressive_load_tag;

    // Observe the real backend qualifier, not a dispatch-only assumption.
    // The two x15 WAW producers below normally complete together on EX0/EX1:
    // only the completion whose live retirement slot owns x15 may reach a
    // branch.
    always @(negedge clk) begin
        if (rst_n) begin
            for (branch_monitor_lane = 0; branch_monitor_lane < 3;
                 branch_monitor_lane = branch_monitor_lane + 1) begin
                branch_monitor_rd = dut.completion_forward_rd_addr[
                    branch_monitor_lane*5 +: 5];
                if (dut.completion_forward_valid_raw[branch_monitor_lane] &&
                    (branch_monitor_rd == 5'd15) &&
                    dut.youngest_owner_valid_q[branch_monitor_rd]) begin
                    if (dut.complete_slot[
                            branch_monitor_lane*SW +: SW] ==
                        dut.youngest_owner_slot_q[
                            branch_monitor_rd*SW +: SW]) begin
                        if (dut.branch_completion_forward_valid[
                                branch_monitor_lane])
                            saw_branch_owner_accept = 1'b1;
                    end else if (!dut.branch_completion_forward_valid[
                                     branch_monitor_lane]) begin
                        saw_branch_stale_reject = 1'b1;
                    end
                end
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        flush = 0;
        squash = 0;
        decode_valid = 0;
        decode_payload = 0;
        decode_uses_rs1 = 0;
        decode_uses_rs2 = 0;
        csr_rdata = 0;
        csr_valid = 1;
        csr_writable = 1;
        mem_ready = 0;
        mem_resp_valid = 0;
        mem_resp_tag = 0;
        mem_error = 0;
        mem_page_fault = 0;
        mem_access_allowed = 1;
        mem_rdata = 0;
        irq_pending = 0;
        irq_cause = 0;
        saw_two_retire = 0;
        saw_dependent_retire = 0;
        saw_store_wait = 0;
        saw_local_forward_issue = 0;
        saw_local_forward_retire = 0;
        saw_general_forward_issue = 0;
        saw_general_forward_retire = 0;
        saw_ordered_waw_store = 0;
        saw_posted_store_retire = 0;
        saw_nonoverlap_load_retire = 0;
        saw_store_forward_retire = 0;
        saw_aggressive_waw_issue = 0;
        saw_branch_owner_accept = 0;
        saw_branch_stale_reject = 0;

        repeat (3) tick();
        rst_n = 1;
        tick();

        // Independent writes issue together and retire together.
        send2(addi_packet(1, 0, 5, 11),
              addi_packet(2, 0, 6, 22), 2'b00, 2'b00);
        // Queue a consumer while both destination owners are outstanding.
        p0 = addi_packet(3, 5, 7, 3);
        p0[I_RS2 +: 5] = 5'd6;
        p0[I_INSTR +: 32] = 32'h0062_83b3;
        p0[I_IMM +: 64] = 0;
        decode_payload[0 +: IW] = p0;
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b001;
        tick();
        decode_valid = 0;

        for (cycles = 0; cycles < 30; cycles = cycles + 1) begin
            #1;
            if (retire_count == 2) saw_two_retire = 1;
            if (retire_arch[0] && retire_rd == 7 && retire_wdata == 33)
                saw_dependent_retire = 1;
            tick();
        end
        if (!saw_two_retire) fail("independent ALUs never retired two-wide");
        if (!saw_dependent_retire)
            fail("dependent result did not read committed/bypassed operands");
        if (write_busy != 0 || retire_occupancy != 0)
            fail("ownership or retire queue leaked after ALU group");

        // Keep retirement blocked behind an unresolved load while two younger
        // writers to x15 both complete.  RELAX_HAZARDS must select the second
        // writer by allocation ID and issue x16=x15+1 before the load returns.
        // The conservative mode runs the same sequence but may wait.
        while (decode_ready != 3'b111) tick();
        decode_payload = {
            addi_packet(202, 0, 15, 2),
            addi_packet(201, 0, 15, 44),
            load_packet(200, 0, 20, 64'h180)
        };
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b111;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        decode_uses_rs1 = 0;
        mem_ready = 1'b1;
        for (cycles = 0; cycles < 20 &&
             !(mem_valid && !mem_write && mem_addr == 64'h180);
             cycles = cycles + 1) tick();
        if (!mem_valid || mem_write || mem_addr != 64'h180)
            fail("aggressive-hazard head load was not launched");
        aggressive_load_tag = mem_tag;
        tick();
        mem_ready = 1'b0;

        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, addi_packet(203, 15, 16, 1)};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        decode_uses_rs1 = 0;
        for (cycles = 0; cycles < 20 && !saw_aggressive_waw_issue;
             cycles = cycles + 1) begin
            #1;
            if ((issue_valid[0] &&
                 dut.pipe_payload[0*IW + I_RD +: 5] == 5'd16) ||
                (issue_valid[1] &&
                 dut.pipe_payload[1*IW + I_RD +: 5] == 5'd16))
                saw_aggressive_waw_issue = 1'b1;
            tick();
        end
        if ((RELAX_HAZARDS != 0) && !saw_aggressive_waw_issue)
            fail("youngest completed WAW producer did not release consumer");

        mem_resp_valid = 1'b1;
        mem_resp_tag = aggressive_load_tag;
        mem_rdata = 64'h99;
        tick();
        mem_resp_valid = 1'b0;
        for (cycles = 0; cycles < 40 && retire_occupancy != 0;
             cycles = cycles + 1) tick();
        if (retire_occupancy != 0 || write_busy != 0)
            fail("aggressive WAW sequence leaked backend state");
        if (dut.u_gpr.regs[16] != 64'd3)
            fail("aggressive WAW consumer selected the wrong producer");
        if (!saw_branch_owner_accept)
            fail("youngest WAW completion was not branch-forward qualified");
        if (!saw_branch_stale_reject)
            fail("older WAW completion was not rejected from branch bypass");

        // Two WAW producers may retire beside their consumer.  The rd-only
        // completion map must not override the GPR bank's youngest-lane
        // ordered-retirement bypass with the older producer's value.
        send2(addi_packet(100, 0, 15, 44),
              addi_packet(101, 0, 15, 2), 2'b00, 2'b00);
        while (!decode_ready[0]) tick();
        decode_payload = {
            {2*IW{1'b0}}, store_word_packet(102, 0, 15, 4)};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        decode_uses_rs1 = 0;
        decode_uses_rs2 = 0;
        mem_ready = 1'b1;
        for (cycles = 0; cycles < 30 && !saw_ordered_waw_store;
             cycles = cycles + 1) begin
            #1;
            if (mem_valid && mem_ready && mem_write) begin
                if (mem_addr != 64'd4 ||
                    mem_wdata != 64'h0000_0002_0000_0000 ||
                    mem_wstrb != 8'hf0)
                    fail("WAW consumer store did not use youngest retiring value");
                posted_store_tag = mem_tag;
                saw_ordered_waw_store = 1'b1;
            end
            tick();
        end
        if (!saw_ordered_waw_store)
            fail("WAW consumer store request was not launched");
        mem_ready = 1'b0;
        mem_resp_tag = posted_store_tag;
        mem_resp_valid = 1'b1;
        tick();
        mem_resp_valid = 1'b0;
        for (cycles = 0; cycles < 20 && retire_occupancy != 0;
             cycles = cycles + 1) tick();
        if (retire_occupancy != 0 || write_busy != 0)
            fail("WAW forwarding regression leaked retirement state");

        // Put a consumer into dispatch one cycle behind its producer.  It must
        // issue on the same physical ALU while that pipe exposes its local
        // completion, and it must retire the forwarded value rather than the
        // stale GPR value captured in its packet.
        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, addi_packet(6, 0, 9, 40)};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, addi_packet(7, 9, 10, 2)};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        decode_uses_rs1 = 0;

        for (cycles = 0; cycles < 12; cycles = cycles + 1) begin
            #1;
            if ((dut.local_forward_valid[0] && issue_valid[0]) ||
                (dut.local_forward_valid[1] && issue_valid[1]))
                saw_local_forward_issue = 1;
            if (retire_arch[0] && retire_rd == 10 && retire_wdata == 42)
                saw_local_forward_retire = 1;
            tick();
        end
        if (!saw_local_forward_issue)
            fail("dependent ALU did not issue from a local completion");
        if (!saw_local_forward_retire)
            fail("integrated local-forward result did not retire correctly");
        if (write_busy != 0 || retire_occupancy != 0)
            fail("forwarded ALU pair leaked ownership or retirement state");

        // Keep an older load unresolved, complete x11 behind it, and issue a
        // younger dependent load through MEM.  This requires both persistence
        // beyond the one-cycle ALU bypass and an EX-to-MEM data path.
        mem_ready = 1'b1;
        send2(load_packet(8, 0, 20, 64'h100),
              addi_packet(9, 0, 11, 64), 2'b01, 2'b00);
        for (cycles = 0; cycles < 20 &&
             !(mem_valid && mem_addr == 64'h100);
             cycles = cycles + 1) tick();
        if (!mem_valid || mem_addr != 64'h100)
            fail("older load request was not launched");
        old_load_tag = mem_tag;
        tick();

        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, load_packet(10, 11, 12, 8)};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        decode_uses_rs1 = 0;

        for (cycles = 0; cycles < 20 &&
             !(mem_valid && mem_addr == 64'd72);
             cycles = cycles + 1) begin
            #1;
            if (issue_valid[2] && dut.full_forward_valid[11])
                saw_general_forward_issue = 1'b1;
            tick();
        end
        if (!mem_valid || mem_addr != 64'd72)
            fail("general forwarding did not issue EX-to-MEM dependent load");
        if (!saw_general_forward_issue)
            fail("dependent MEM issue did not coincide with completion map");
        dependent_load_tag = mem_tag;
        tick();
        mem_ready = 1'b0;

        // Return the younger request first.  It may complete out of order,
        // but cannot retire before the older load and x11 producer.
        mem_resp_valid = 1'b1;
        mem_resp_tag = dependent_load_tag;
        mem_rdata = 64'h55;
        tick();
        mem_resp_valid = 1'b0;
        tick();
        mem_resp_valid = 1'b1;
        mem_resp_tag = old_load_tag;
        mem_rdata = 64'haa;
        tick();
        mem_resp_valid = 1'b0;

        for (cycles = 0; cycles < 30; cycles = cycles + 1) begin
            #1;
            if (retire_arch[0] && retire_rd == 12 &&
                retire_wdata == 64'h55)
                saw_general_forward_retire = 1'b1;
            tick();
        end
        if (!saw_general_forward_retire)
            fail("EX-to-MEM forwarded load did not retire correct data");
        if (write_busy != 0 || retire_occupancy != 0)
            fail("general forwarding sequence leaked backend state");

        // An older ALU and younger store may allocate together, but the MEM
        // lane must withhold the store request until the ALU retires and the
        // store's ID/slot is the ordered head.
        p0 = addi_packet(4, 0, 8, 1);
        p1 = base_packet(5, 64'h2004, 32'h0080_3023);
        p1[I_RS1 +: 5] = 0;
        p1[I_RS2 +: 5] = 11;
        p1[I_IMM +: 64] = 64'h80;
        p1[I_LSU_OP +: 5] = `RV64_LSU_OP_SD;
        p1[I_MEM_WRITE] = 1;
        send2(p0, p1, 2'b00, 2'b10);
        #1;
        if (issue_valid[2] && mem_valid)
            fail("store produced a bus request at allocation");
        for (cycles = 0; cycles < 20 && !mem_valid; cycles = cycles + 1) begin
            if ((retire_occupancy >= 2) && !retire_arch[0])
                saw_store_wait = 1;
            tick();
        end
        if (!saw_store_wait) fail("test did not observe store behind older work");
        if (!mem_valid || !mem_write || mem_addr != 64'h80)
            fail("ordered-head store request was not produced correctly");
        posted_store_tag = mem_tag;
        mem_ready = 1;
        tick();
        mem_ready = 0;
        for (cycles = 0; cycles < 10; cycles = cycles + 1) begin
            if (retire_occupancy == 0)
                saw_posted_store_retire = 1'b1;
            tick();
        end
        if (!saw_posted_store_retire)
            fail("posted store did not retire before its response");

        // The retained B response must not serialize an independent younger
        // load.  This is the minimum useful posted-store interlock: only an
        // overlapping load or a second store waits for the response.
        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, load_packet(11, 0, 13, 64'h100)};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        mem_ready = 1'b1;
        for (cycles = 0; cycles < 20 &&
             !(mem_valid && !mem_write && mem_addr == 64'h100);
             cycles = cycles + 1) tick();
        if (!mem_valid || mem_write || mem_addr != 64'h100)
            fail("non-overlapping load remained behind posted store");
        younger_load_tag = mem_tag;
        if (younger_load_tag == posted_store_tag)
            fail("younger load reused live posted-store tag");
        tick();
        mem_ready = 1'b0;
        mem_resp_valid = 1'b1;
        mem_resp_tag = younger_load_tag;
        mem_rdata = 64'h1234;
        tick();
        mem_resp_valid = 1'b0;
        for (cycles = 0; cycles < 20; cycles = cycles + 1) begin
            #1;
            if (retire_arch[0] && retire_rd == 13 &&
                retire_wdata == 64'h1234)
                saw_nonoverlap_load_retire = 1'b1;
            tick();
        end
        if (!saw_nonoverlap_load_retire)
            fail("non-overlapping load did not complete before store response");

        // A fully covered same-address load completes locally from the
        // retained store data and must not consume an AXI read request.
        while (!decode_ready[0]) tick();
        decode_payload = {{2*IW{1'b0}}, load_packet(12, 0, 14, 64'h80)};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = 0;
        mem_ready = 1'b1;
        for (cycles = 0; cycles < 20; cycles = cycles + 1) begin
            #1;
            if (mem_valid)
                fail("store-forwarded load issued an AXI request");
            if (retire_arch[0] && retire_rd == 14 &&
                retire_wdata == 64'd64)
                saw_store_forward_retire = 1'b1;
            tick();
        end
        mem_ready = 1'b0;
        if (!saw_store_forward_retire)
            fail("same-address load did not retire forwarded store data");

        // A younger redirect must not discard the committed store's response
        // tag or the metadata needed to report a delayed failure.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        mem_resp_valid = 1;
        mem_resp_tag = posted_store_tag;
        mem_error = 1'b1;
        tick();
        mem_resp_valid = 0;
        mem_error = 1'b0;
        if (!exception)
            fail("posted store response fault did not raise async abort");
        if (cause != `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT)
            fail("posted store async abort reported the wrong cause");
        if (retire_tval != 64'h80)
            fail("posted store async abort lost the store address");
        if (retire_trace_id != 64'd5 || retire_instr != 32'h0080_3023)
            fail("posted store async abort lost diagnostic metadata");
        if (retire_arch != 0)
            fail("normal retirement overlapped posted store async abort");
        tick();
        if (exception)
            fail("posted store async abort was not a one-cycle event");
        for (cycles = 0; cycles < 20 && retire_occupancy != 0;
             cycles = cycles + 1) tick();
        if (retire_occupancy != 0) fail("store did not complete and retire");

        $display("PASS: integrated 3p forwarding, posted-store load bypass/data forwarding, async abort, issue, and retirement");
        $finish;
    end
endmodule
