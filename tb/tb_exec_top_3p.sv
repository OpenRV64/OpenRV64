`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module tb_exec_top_3p;

    localparam integer SLOT_WIDTH = 3;
    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer ISSUE_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer COMPLETE_WIDTH = `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH;

    localparam integer ISSUE_SFENCE_ALLOWED = 0;
    localparam integer ISSUE_SRET_ALLOWED = 1;
    localparam integer ISSUE_PRIV = 2;
    localparam integer ISSUE_INSTR_PAGE_FAULT = 4;
    localparam integer ISSUE_INSTR_ACCESS_FAULT = 5;
    localparam integer ISSUE_ECALL = 6;
    localparam integer ISSUE_EBREAK = 7;
    localparam integer ISSUE_ILLEGAL = 8;
    localparam integer ISSUE_FENCE = 9;
    localparam integer ISSUE_SYSTEM = 10;
    localparam integer ISSUE_WORD = 11;
    localparam integer ISSUE_PREDICTED = 12;
    localparam integer ISSUE_JUMP = 13;
    localparam integer ISSUE_BRANCH = 14;
    localparam integer ISSUE_MEM_WRITE = 15;
    localparam integer ISSUE_MEM_READ = 16;
    localparam integer ISSUE_REG_WRITE = 17;
    localparam integer ISSUE_BR_OP = 18;
    localparam integer ISSUE_LSU_OP = 22;
    localparam integer ISSUE_ALU_OP = 27;
    localparam integer ISSUE_ALU_EXT = 32;
    localparam integer ISSUE_RD = 35;
    localparam integer ISSUE_IMM = 40;
    localparam integer ISSUE_RS2_DATA = 104;
    localparam integer ISSUE_RS1_DATA = 168;
    localparam integer ISSUE_RS2 = 232;
    localparam integer ISSUE_RS1 = 237;
    localparam integer ISSUE_INSTR = 242;
    localparam integer ISSUE_PC = 274;
    localparam integer ISSUE_TRACE = 338;

    localparam integer COMPLETE_CSR_WDATA = 0;
    localparam integer COMPLETE_CSR_ADDR = 64;
    localparam integer COMPLETE_CSR_WRITE = 76;
    localparam integer COMPLETE_TVAL = 79;
    localparam integer COMPLETE_CAUSE = 143;
    localparam integer COMPLETE_EXCEPTION = 149;
    localparam integer COMPLETE_ILLEGAL = 152;
    localparam integer COMPLETE_REG_WRITE = 153;
    localparam integer COMPLETE_RD = 154;
    localparam integer COMPLETE_DATA = 169;
    localparam integer COMPLETE_INSTR = 233;
    localparam integer COMPLETE_NEXT_PC = 265;
    localparam integer COMPLETE_PC = 329;
    localparam integer COMPLETE_TRACE = 393;

    reg clk;
    reg rst_n;
    reg flush;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_ready;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_unsupported;
    reg [`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH-1:0] issue_id;
    reg [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0] issue_slot;
    reg [`OPENRV64_EXEC_PIPE_COUNT*ISSUE_WIDTH-1:0] issue_payload;
    reg branch_forward_valid;
    reg [ID_WIDTH-1:0] branch_forward_id;
    reg [`RV64_REG_ADDR_WIDTH-1:0] branch_forward_rd_addr;
    reg [`RV64_XLEN-1:0] branch_forward_data;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_src1_producer_valid;
    reg [`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH-1:0]
        issue_src1_producer_id;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_src2_producer_valid;
    reg [`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH-1:0]
        issue_src2_producer_id;
    reg ordered_head_valid;
    reg [ID_WIDTH-1:0] ordered_head_id;
    reg [SLOT_WIDTH-1:0] ordered_head_slot;
    wire [2:0] complete_valid;
    reg [2:0] complete_ready;
    wire [3*ID_WIDTH-1:0] complete_id;
    wire [3*SLOT_WIDTH-1:0] complete_slot;
    wire [3*COMPLETE_WIDTH-1:0] complete_payload;
    wire redirect_valid;
    wire [ID_WIDTH-1:0] redirect_id;
    wire [`RV64_XLEN-1:0] redirect_target;
    wire branch_resolved;
    wire branch_taken;
    wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    reg [`RV64_XLEN-1:0] csr_rdata;
    reg csr_valid;
    reg csr_writable;
    wire mem_valid;
    reg mem_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag;
    wire mem_xlate_only;
    wire mem_physical;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag;
    reg [`RV64_XLEN-1:0] mem_resp_paddr;
    reg mem_error;
    reg mem_page_fault;
    reg mem_access_allowed;
    wire mem_lock;
    wire mem_write;
    wire [`RV64_XLEN-1:0] mem_addr;
    wire [`RV64_XLEN-1:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire mem_access;
    wire [`RV64_XLEN-1:0] mem_effective_addr;
    wire [2:0] mem_size;
    reg [`RV64_XLEN-1:0] mem_rdata;
    wire mem_xlate_valid;
    reg mem_xlate_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_xlate_tag;
    wire mem_xlate_write;
    wire [`RV64_XLEN-1:0] mem_xlate_vaddr;
    reg mem_xlate_resp_valid;
    wire mem_xlate_resp_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_xlate_resp_tag;
    reg [`RV64_XLEN-1:0] mem_xlate_resp_paddr;
    wire mem1_valid;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem1_tag;
    wire mem1_lock;
    wire mem1_write;
    wire [`RV64_XLEN-1:0] mem1_addr;
    wire [`RV64_XLEN-1:0] mem1_wdata;
    wire [7:0] mem1_wstrb;
    wire mem1_access;
    wire [`RV64_XLEN-1:0] mem1_effective_addr;
    wire [2:0] mem1_size;

    openrv64_exec_top_3p #(
        .RETIRE_SLOT_WIDTH(SLOT_WIDTH),
        .ENABLE_RV64M(1),
        .ENABLE_POSTED_STORES(0),
        .CACHEABLE_BASE(64'h0),
        .CACHEABLE_SIZE({64{1'b1}})
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_younger_i(1'b0),
        .squash_id_i({ID_WIDTH{1'b0}}),
        .translation_bypass_i(1'b0),
        .issue_valid_i(issue_valid),
        .issue_ready_o(issue_ready),
        .issue_unsupported_o(issue_unsupported),
        .issue_id_i(issue_id),
        .issue_slot_i(issue_slot),
        .issue_payload_i(issue_payload),
        .branch_forward_valid_i(branch_forward_valid),
        .branch_forward_id_i(branch_forward_id),
        .branch_forward_rd_addr_i(branch_forward_rd_addr),
        .branch_forward_data_i(branch_forward_data),
        .issue_src1_producer_valid_i(issue_src1_producer_valid),
        .issue_src1_producer_id_i(issue_src1_producer_id),
        .issue_src2_producer_valid_i(issue_src2_producer_valid),
        .issue_src2_producer_id_i(issue_src2_producer_id),
        .ordered_head_valid_i(ordered_head_valid),
        .ordered_head_id_i(ordered_head_id),
        .ordered_head_slot_i(ordered_head_slot),
        .complete_valid_o(complete_valid),
        .complete_ready_i(complete_ready),
        .complete_id_o(complete_id),
        .complete_slot_o(complete_slot),
        .complete_payload_o(complete_payload),
        .redirect_valid_o(redirect_valid),
        .redirect_id_o(redirect_id),
        .redirect_target_o(redirect_target),
        .branch_resolved_o(branch_resolved),
        .branch_taken_o(branch_taken),
        .csr_addr_o(csr_addr),
        .csr_rdata_i(csr_rdata),
        .csr_valid_i(csr_valid),
        .csr_writable_i(csr_writable),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_tag_o(mem_tag),
        .mem_xlate_only_o(mem_xlate_only),
        .mem_physical_o(mem_physical),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_resp_paddr_i(mem_resp_paddr),
        .mem_xlate_valid_o(mem_xlate_valid),
        .mem_xlate_ready_i(mem_xlate_ready),
        .mem_xlate_tag_o(mem_xlate_tag),
        .mem_xlate_write_o(mem_xlate_write),
        .mem_xlate_vaddr_o(mem_xlate_vaddr),
        .mem_xlate_resp_valid_i(mem_xlate_resp_valid),
        .mem_xlate_resp_ready_o(mem_xlate_resp_ready),
        .mem_xlate_resp_tag_i(mem_xlate_resp_tag),
        .mem_xlate_resp_paddr_i(mem_xlate_resp_paddr),
        .mem_xlate_resp_access_fault_i(1'b0),
        .mem_xlate_resp_page_fault_i(1'b0),
        .mem_error_i(mem_error),
        .mem_page_fault_i(mem_page_fault),
        .mem_access_allowed_i(mem_access_allowed),
        .mem_lock_o(mem_lock),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_access_o(mem_access),
        .mem_effective_addr_o(mem_effective_addr),
        .mem_size_o(mem_size),
        .mem_rdata_i(mem_rdata),
        .mem1_valid_o(mem1_valid),
        .mem1_ready_i(1'b0),
        .mem1_tag_o(mem1_tag),
        .mem1_lock_o(mem1_lock),
        .mem1_write_o(mem1_write),
        .mem1_addr_o(mem1_addr),
        .mem1_wdata_o(mem1_wdata),
        .mem1_wstrb_o(mem1_wstrb),
        .mem1_access_o(mem1_access),
        .mem1_effective_addr_o(mem1_effective_addr),
        .mem1_size_o(mem1_size)
    );

    always #5 clk = ~clk;

    // Identity translation service used by this execution-only test.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_xlate_resp_valid <= 1'b0;
            mem_xlate_resp_tag <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            mem_xlate_resp_paddr <= {`RV64_XLEN{1'b0}};
        end else begin
            if (mem_xlate_resp_valid && mem_xlate_resp_ready)
                mem_xlate_resp_valid <= 1'b0;
            if (mem_xlate_valid && mem_xlate_ready) begin
                mem_xlate_resp_valid <= 1'b1;
                mem_xlate_resp_tag <= mem_xlate_tag;
                mem_xlate_resp_paddr <= mem_xlate_vaddr;
            end
        end
    end

    function automatic [ISSUE_WIDTH-1:0] packet_base;
        input [63:0] trace;
        input [`RV64_XLEN-1:0] pc;
        input [`RV64_INSTR_WIDTH-1:0] instr;
        reg [ISSUE_WIDTH-1:0] value;
        begin
            value = {ISSUE_WIDTH{1'b0}};
            value[ISSUE_TRACE +: 64] = trace;
            value[ISSUE_PC +: `RV64_XLEN] = pc;
            value[ISSUE_INSTR +: `RV64_INSTR_WIDTH] = instr;
            value[ISSUE_PRIV +: `RV64_PRIV_WIDTH] = `RV64_PRIV_M;
            value[ISSUE_SRET_ALLOWED] = 1'b1;
            value[ISSUE_SFENCE_ALLOWED] = 1'b1;
            packet_base = value;
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    reg [ISSUE_WIDTH-1:0] packet;
    integer wait_cycles;
    integer depth_index;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] saved_mem_tag;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        issue_valid = 4'b0000;
        issue_id = {`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH{1'b0}};
        issue_slot = {`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH{1'b0}};
        issue_payload =
            {`OPENRV64_EXEC_PIPE_COUNT*ISSUE_WIDTH{1'b0}};
        branch_forward_valid = 1'b0;
        branch_forward_id = ID_WIDTH'(0);
        branch_forward_rd_addr = {`RV64_REG_ADDR_WIDTH{1'b0}};
        branch_forward_data = {`RV64_XLEN{1'b0}};
        issue_src1_producer_valid =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        issue_src1_producer_id =
            {`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH{1'b0}};
        issue_src2_producer_valid =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        issue_src2_producer_id =
            {`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH{1'b0}};
        ordered_head_valid = 1'b0;
        ordered_head_id = ID_WIDTH'(0);
        ordered_head_slot = {SLOT_WIDTH{1'b0}};
        complete_ready = 3'b000;
        csr_rdata = 64'd0;
        csr_valid = 1'b1;
        csr_writable = 1'b1;
        mem_ready = 1'b1;
        mem_xlate_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        mem_resp_paddr = {`RV64_XLEN{1'b0}};
        mem_error = 1'b0;
        mem_page_fault = 1'b0;
        mem_access_allowed = 1'b1;
        mem_rdata = 64'h8877_6655_4433_2211;

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // EX0 base ALU does not require the ordered-head token.
        packet = packet_base(64'd100, 64'h1000, 32'h0050_8193);
        packet[ISSUE_RS1 +: 5] = 5'd1;
        packet[ISSUE_RS1_DATA +: 64] = 64'd7;
        packet[ISSUE_IMM +: 64] = 64'd5;
        packet[ISSUE_RD +: 5] = 5'd3;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(0);
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd0;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 base ALU was not ready");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[0]) fail("EX0 did not complete ADDI");
        if (complete_id[0*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(0))
            fail("EX0 completion ID mismatch");
        if (complete_payload[0*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd12)
            fail("EX0 ADDI result mismatch");
        if (!complete_payload[0*COMPLETE_WIDTH + COMPLETE_REG_WRITE])
            fail("EX0 lost register-write metadata");

        // Feed the just-produced x3 value through EX0's local result mux.  The
        // packet deliberately carries a stale architectural value for x3.
        packet = packet_base(64'd105, 64'h1004, 32'h0011_8213);
        packet[ISSUE_RS1 +: 5] = 5'd3;
        packet[ISSUE_RS1_DATA +: 64] = 64'd0;
        packet[ISSUE_IMM +: 64] = 64'd1;
        packet[ISSUE_RD +: 5] = 5'd4;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(5);
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd5;
        complete_ready = 3'b001;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 local RAW consumer was not ready");
        tick();
        issue_valid = 3'b000;
        complete_ready = 3'b000;
        #1;
        if (!complete_valid[0] ||
            (complete_payload[0*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd13))
            fail("EX0 local previous-result forwarding mismatch");
        complete_ready = 3'b001;
        tick();
        complete_ready = 3'b000;

        // If EX0 and EX1's local completion both name a branch source, EX0's
        // youngest-owner-qualified value wins.  The packet and local result
        // deliberately disagree with the foreign value.
        packet = packet_base(64'd109, 64'h1800, 32'h0000_02b3);
        packet[ISSUE_RS1_DATA +: 64] = 64'd11;
        packet[ISSUE_RS2_DATA +: 64] = 64'd0;
        packet[ISSUE_RD +: 5] = 5'd5;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(9);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd1;
        issue_valid = 3'b010;
        #1;
        if (!issue_ready[1])
            fail("EX1 did not accept local-forward producer");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[1] ||
            (complete_payload[
                1*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd11))
            fail("EX1 local-forward producer result mismatch");

        packet = packet_base(64'd110, 64'h1900, 32'h0022_8463);
        packet[ISSUE_RS1 +: 5] = 5'd5;
        packet[ISSUE_RS1_DATA +: 64] = 64'd0;
        packet[ISSUE_RS2_DATA +: 64] = 64'd22;
        packet[ISSUE_IMM +: 64] = 64'd8;
        packet[ISSUE_BR_OP +: 4] = `RV64_BR_OP_BEQ;
        packet[ISSUE_BRANCH] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(10);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd2;
        branch_forward_valid = 1'b1;
        branch_forward_id = ID_WIDTH'(8);
        branch_forward_rd_addr = 5'd5;
        branch_forward_data = 64'd22;
        issue_src1_producer_valid[1] = 1'b1;
        issue_src1_producer_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(8);
        complete_ready = 3'b010;
        issue_valid = 3'b010;
        #1;
        if (!issue_ready[1] || !branch_resolved || !branch_taken)
            fail("qualified EX0 branch value lost to EX1 local forwarding");
        tick();
        issue_valid = 3'b000;
        branch_forward_valid = 1'b0;
        issue_src1_producer_valid = 4'b0000;
        complete_ready = 3'b000;
        #1;
        if (!complete_valid[1])
            fail("foreign-priority EX1 branch did not complete");
        complete_ready = 3'b010;
        tick();
        complete_ready = 3'b000;

        // A completion for a younger WAW producer has the same architectural
        // rd but a different dynamic ID.  It must not replace the operand
        // captured for this older branch.
        packet = packet_base(64'd111, 64'h1a00, 32'h0062_8463);
        packet[ISSUE_RS1 +: 5] = 5'd5;
        packet[ISSUE_RS2 +: 5] = 5'd6;
        packet[ISSUE_RS1_DATA +: 64] = 64'd11;
        packet[ISSUE_RS2_DATA +: 64] = 64'd11;
        packet[ISSUE_IMM +: 64] = 64'd8;
        packet[ISSUE_BR_OP +: 4] = `RV64_BR_OP_BEQ;
        packet[ISSUE_BRANCH] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(11);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd3;
        branch_forward_valid = 1'b1;
        branch_forward_id = ID_WIDTH'(21);
        branch_forward_rd_addr = 5'd5;
        branch_forward_data = 64'd22;
        issue_src1_producer_valid[1] = 1'b1;
        issue_src1_producer_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(20);
        issue_valid = 4'b0010;
        #1;
        if (!issue_ready[1] || !branch_resolved || !branch_taken)
            fail("younger WAW completion corrupted branch operand");
        tick();
        issue_valid = 4'b0000;
        branch_forward_valid = 1'b0;
        issue_src1_producer_valid = 4'b0000;
        #1;
        if (!complete_valid[1])
            fail("producer-tag-qualified branch did not complete");
        complete_ready = 3'b010;
        tick();
        complete_ready = 3'b000;

        // A valid aligned conditional branch resolves on EX1 before
        // retirement and therefore does not require the ordered-head token.
        packet = packet_base(64'd101, 64'h2000, 32'h0020_8463);
        packet[ISSUE_RS1_DATA +: 64] = 64'h55;
        packet[ISSUE_RS2_DATA +: 64] = 64'h55;
        packet[ISSUE_IMM +: 64] = 64'd8;
        packet[ISSUE_BR_OP +: 4] = `RV64_BR_OP_BEQ;
        packet[ISSUE_BRANCH] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(1);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd1;
        issue_valid = 3'b010;
        ordered_head_valid = 1'b1;
        ordered_head_id = ID_WIDTH'(99);
        ordered_head_slot = 3'd1;
        #1;
        if (!issue_ready[1]) fail("EX1 early branch waited for order token");
        if (!branch_resolved || !branch_taken || !redirect_valid)
            fail("EX1 early branch did not resolve without head token");
        ordered_head_id = ID_WIDTH'(1);
        #1;
        if (!branch_resolved || !branch_taken || !redirect_valid)
            fail("EX1 branch resolution was not produced on issue");
        if ((redirect_id != ID_WIDTH'(1)) ||
            (redirect_target != 64'h2008))
            fail("EX1 branch redirect metadata mismatch");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[1]) fail("EX1 branch did not complete");
        complete_ready = 3'b010;
        tick();
        complete_ready = 3'b000;

        // Direct JAL has a known aligned target, so EX1 may resolve and buffer
        // its link result without waiting for architectural retirement.
        packet = packet_base(64'd107, 64'h2800, 32'h0080_00ef);
        packet[ISSUE_IMM +: 64] = 64'd8;
        packet[ISSUE_RD +: 5] = 5'd1;
        packet[ISSUE_BR_OP +: 4] = `RV64_BR_OP_JAL;
        packet[ISSUE_REG_WRITE] = 1'b1;
        packet[ISSUE_JUMP] = 1'b1;
        packet[ISSUE_PREDICTED] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(7);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd7;
        issue_valid = 3'b010;
        ordered_head_valid = 1'b1;
        ordered_head_id = ID_WIDTH'(99);
        ordered_head_slot = 3'd1;
        #1;
        if (!issue_ready[1]) fail("EX1 direct JAL waited for order token");
        if (!branch_resolved || !branch_taken || redirect_valid)
            fail("EX1 direct JAL prediction/resolve mismatch");
        if ((redirect_id != ID_WIDTH'(7)) ||
            (redirect_target != 64'h2808))
            fail("EX1 direct JAL resolution metadata mismatch");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[1] ||
            (complete_payload[1*COMPLETE_WIDTH + COMPLETE_DATA +: 64] !=
             64'h2804))
            fail("EX1 direct JAL link completion mismatch");
        complete_ready = 3'b010;
        tick();
        complete_ready = 3'b000;

        // Store translation begins before retirement, but no physical write
        // may launch until the exact instruction reaches ordered head.
        packet = packet_base(64'd102, 64'h3000, 32'h0020_b023);
        packet[ISSUE_RS1 +: 5] = 5'd1;
        packet[ISSUE_RS2 +: 5] = 5'd2;
        packet[ISSUE_RS1_DATA +: 64] = 64'h4000;
        packet[ISSUE_RS2_DATA +: 64] = 64'hdead_beef_cafe_f00d;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_SD;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[3*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(2);
        issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = 3'd2;
        ordered_head_id = ID_WIDTH'(1);
        ordered_head_slot = 3'd1;
        issue_valid = 4'b1000;
        #1;
        if (!issue_ready[3]) fail("MEM1 did not accept store");
        if (!mem_xlate_valid || !mem_xlate_write ||
            (mem_xlate_vaddr != 64'h4000))
            fail("store did not translate at LSQ admission");
        saved_mem_tag = mem_xlate_tag;
        tick();
        issue_valid = 3'b000;
        tick();
        tick();
        #1;
        if (mem_valid)
            fail("store escaped before ordered-head permission");
        ordered_head_id = ID_WIDTH'(2);
        ordered_head_slot = 3'd2;
        #1;
        if (!mem_valid || !mem_physical || !mem_write ||
            (mem_addr != 64'h4000) ||
            (mem_wdata != 64'hdead_beef_cafe_f00d) || (mem_wstrb != 8'hff))
            fail("ordered store request mismatch");
        saved_mem_tag = mem_tag;
        tick();
        // Once L1D accepts the posted request, the store may complete before
        // its later tagged response.  A coincident younger redirect must not
        // discard that irrevocable store completion.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        #1;
        if (!complete_valid[2])
            fail("accepted MEM store did not complete across flush");
        if (complete_payload[2*COMPLETE_WIDTH + COMPLETE_EXCEPTION])
            fail("MEM store raised an unexpected exception");
        complete_ready = 3'b100;
        tick();
        complete_ready = 3'b000;
        mem_resp_valid = 1'b1;
        mem_resp_tag = saved_mem_tag;
        #1;
        if (!mem_resp_ready)
            fail("posted MEM store response was blocked");
        tick();
        mem_resp_valid = 1'b0;
        #1;
        if (complete_valid[2])
            fail("posted MEM store response completed the store twice");

        // Fill the fixed-role physical LSU queues while the native request
        // port is stalled.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        mem_ready = 1'b0;

        // An atomic may share admission with a younger MEM0 load.  MEM0 must
        // then remain behind the ordered atomic instead of creating a
        // valid/ready dependency between the two issue lanes.
        ordered_head_valid = 1'b0;
        packet = packet_base(64'd118, 64'h4080,
                             {5'b00000, 2'b00, 5'd2, 5'd1,
                              3'b011, 5'd8, 7'b0101111});
        packet[ISSUE_RS1_DATA +: 64] = 64'h7800;
        packet[ISSUE_RS2_DATA +: 64] = 64'd1;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_AMOADD;
        packet[ISSUE_MEM_READ] = 1'b1;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[3*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(18);
        issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = 3'd0;
        packet = packet_base(64'd119, 64'h4084, 32'h0000_b283);
        packet[ISSUE_RS1_DATA +: 64] = 64'h7880;
        packet[ISSUE_RD +: 5] = 5'd5;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_LD;
        packet[ISSUE_MEM_READ] = 1'b1;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[2*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[2*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(19);
        issue_slot[2*SLOT_WIDTH +: SLOT_WIDTH] = 3'd1;
        issue_valid = 4'b1100;
        #1;
        if (!issue_ready[2] || !issue_ready[3])
            fail("MEM1 atomic and younger MEM0 load did not admit together");
        tick();
        issue_valid = 4'b0000;
        #1;
        if (mem_valid && mem_physical)
            fail("younger MEM0 load escaped ahead of unordered atomic");
        flush = 1'b1;
        tick();
        flush = 1'b0;
        ordered_head_valid = 1'b1;

        for (depth_index = 0;
             depth_index < `OPENRV64_LSU_OUTSTANDING/2;
             depth_index = depth_index + 1) begin
            packet = packet_base(64'd120 + depth_index,
                                 64'h4100 + depth_index * 4,
                                 32'h0000_b283);
            packet[ISSUE_RS1_DATA +: 64] =
                64'h8000 + depth_index * 8;
            packet[ISSUE_RD +: 5] = 5'd5;
            packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_LD;
            packet[ISSUE_MEM_READ] = 1'b1;
            packet[ISSUE_REG_WRITE] = 1'b1;
            issue_payload[2*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
            issue_id[2*ID_WIDTH +: ID_WIDTH] =
                ID_WIDTH'(20 + depth_index);
            issue_slot[2*SLOT_WIDTH +: SLOT_WIDTH] = depth_index;
            issue_valid = 4'b0100;
            #1;
            if (!issue_ready[2])
                fail("MEM0 did not accept all four load slots");
            tick();
            issue_valid = 4'b0000;
        end
        issue_valid = 4'b0100;
        #1;
        if (issue_ready[2])
            fail("MEM0 accepted a fifth load");
        issue_valid = 4'b0000;

        flush = 1'b1;
        tick();
        flush = 1'b0;
        ordered_head_valid = 1'b0;

        for (depth_index = 0;
             depth_index < `OPENRV64_LSU_OUTSTANDING/2;
             depth_index = depth_index + 1) begin
            packet = packet_base(64'd124 + depth_index,
                                 64'h4140 + depth_index * 4,
                                 32'h0020_b023);
            packet[ISSUE_RS1_DATA +: 64] =
                64'h8400 + depth_index * 8;
            packet[ISSUE_RS2_DATA +: 64] = 64'h100 + depth_index;
            packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_SD;
            packet[ISSUE_MEM_WRITE] = 1'b1;
            issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
            issue_id[3*ID_WIDTH +: ID_WIDTH] =
                ID_WIDTH'(24 + depth_index);
            issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = depth_index;
            issue_valid = 4'b1000;
            #1;
            if (!issue_ready[3])
                fail("MEM1 did not accept all four store slots");
            tick();
            issue_valid = 4'b0000;
        end
        issue_valid = 4'b1000;
        #1;
        if (issue_ready[3])
            fail("MEM1 accepted a fifth store");
        issue_valid = 4'b0000;

        packet = packet_base(64'd140, 64'h4200,
                             {5'b00000, 2'b00, 5'd2, 5'd1,
                              3'b011, 5'd8, 7'b0101111});
        packet[ISSUE_RS1_DATA +: 64] = 64'h9000;
        packet[ISSUE_RS2_DATA +: 64] = 64'd1;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_AMOADD;
        packet[ISSUE_MEM_READ] = 1'b1;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[3*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(28);
        issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = 3'd0;
        issue_valid = 4'b1000;
        #1;
        if (issue_ready[3])
            fail("MEM1 admitted atomic while its store queue was occupied");
        issue_valid = 4'b0000;
        flush = 1'b1;
        tick();
        flush = 1'b0;
        mem_ready = 1'b1;
        ordered_head_valid = 1'b1;

        // EX0 M keeps its own context while EX1 remains independent.
        packet = packet_base(64'd103, 64'h5000, 32'h0220_82b3);
        packet[ISSUE_RS1_DATA +: 64] = 64'd6;
        packet[ISSUE_RS2_DATA +: 64] = 64'd7;
        packet[ISSUE_RD +: 5] = 5'd5;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_M;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_MUL;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(3);
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd3;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 did not accept MUL");
        tick();
        issue_valid = 3'b000;

        packet = packet_base(64'd104, 64'h5004, 32'h0020_8333);
        packet[ISSUE_RS1_DATA +: 64] = 64'd11;
        packet[ISSUE_RS2_DATA +: 64] = 64'd22;
        packet[ISSUE_RD +: 5] = 5'd6;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(4);
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd4;
        issue_valid = 3'b010;
        #1;
        if (!issue_ready[1]) fail("EX1 was blocked by EX0 MUL");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[1]) fail("EX1 did not complete while EX0 was busy");
        if (complete_payload[1*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd33)
            fail("concurrent EX1 ADD result mismatch");
        complete_ready = 3'b010;
        tick();
        complete_ready = 3'b000;

        wait_cycles = 0;
        while (!complete_valid[0] && (wait_cycles < 24)) begin
            tick();
            wait_cycles = wait_cycles + 1;
        end
        if (!complete_valid[0]) fail("EX0 MUL timed out");
        if (complete_id[0*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(3))
            fail("EX0 MUL completion ID mismatch");
        if (complete_payload[0*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd42)
            fail("EX0 MUL result mismatch");

        // EX0's result remains local as well.  A base-ALU consumer can accept
        // the completed M value without waiting for architectural retirement.
        packet = packet_base(64'd106, 64'h5008, 32'h0022_8393);
        packet[ISSUE_RS1 +: 5] = 5'd5;
        packet[ISSUE_RS1_DATA +: 64] = 64'd0;
        packet[ISSUE_IMM +: 64] = 64'd2;
        packet[ISSUE_RD +: 5] = 5'd7;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(6);
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd6;
        complete_ready = 3'b001;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 local RAW consumer was not ready");
        tick();
        issue_valid = 3'b000;
        complete_ready = 3'b000;
        #1;
        if (!complete_valid[0] ||
            (complete_payload[0*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd44))
            fail("EX0 local previous-result forwarding mismatch");
        complete_ready = 3'b001;
        tick();
        complete_ready = 3'b000;
        flush = 1'b1;
        tick();
        flush = 1'b0;

        // MEM1 is a four-entry speculative store queue. Stores may allocate
        // before retirement, but none may produce a memory request until its
        // ID/slot is the ordered head. The fifth store must backpressure, and
        // a full architectural flush must discard all uncommitted entries.
        ordered_head_valid = 1'b0;
        for (wait_cycles = 0; wait_cycles < 4;
             wait_cycles = wait_cycles + 1) begin
            packet = packet_base(
                64'(120 + wait_cycles),
                64'h5800 + 64'(wait_cycles * 4),
                32'h0020_3023);
            packet[ISSUE_RS1_DATA +: 64] =
                64'h8000 + 64'(wait_cycles * 8);
            packet[ISSUE_RS2_DATA +: 64] = 64'(wait_cycles + 1);
            packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_SD;
            packet[ISSUE_MEM_WRITE] = 1'b1;
            issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
            issue_id[3*ID_WIDTH +: ID_WIDTH] =
                ID_WIDTH'(20 + wait_cycles);
            issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] =
                SLOT_WIDTH'(wait_cycles);
            issue_valid = 4'b1000;
            #1;
            if (!issue_ready[3])
                fail("four-entry store queue backpressured before full");
            if (mem_valid && mem_physical)
                fail("uncommitted queued store produced a physical request");
            tick();
        end
        packet = packet_base(64'd124, 64'h5810, 32'h0020_3023);
        packet[ISSUE_RS1_DATA +: 64] = 64'h8020;
        packet[ISSUE_RS2_DATA +: 64] = 64'd5;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_SD;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[3*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(24);
        issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = SLOT_WIDTH'(4);
        issue_valid = 4'b1000;
        #1;
        if (issue_ready[3])
            fail("fifth store entered a full four-entry store queue");
        issue_valid = 4'b0000;
        flush = 1'b1;
        tick();
        flush = 1'b0;
        ordered_head_valid = 1'b1;
        #1;
        if (!issue_ready[3])
            fail("architectural flush did not clear speculative stores");

        // Once an ordered AMO starts, a younger redirect cannot discard the
        // read response: the marked write phase still depends on that value.
        // The atomic therefore survives this flush.
        packet = packet_base(64'd108, 64'h6000,
                             {5'b00000, 2'b00, 5'd2, 5'd1,
                              3'b011, 5'd8, 7'b0101111});
        packet[ISSUE_RS1_DATA +: 64] = 64'h7000;
        packet[ISSUE_RS2_DATA +: 64] = 64'd2;
        packet[ISSUE_RD +: 5] = 5'd8;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_AMOADD;
        packet[ISSUE_MEM_READ] = 1'b1;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[3*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[3*ID_WIDTH +: ID_WIDTH] = ID_WIDTH'(8);
        issue_slot[3*SLOT_WIDTH +: SLOT_WIDTH] = 3'd0;
        ordered_head_id = ID_WIDTH'(8);
        ordered_head_slot = 3'd0;
        issue_valid = 4'b1000;
        #1;
        if (!issue_ready[3]) fail("MEM1 did not accept AMO");
        tick();
        issue_valid = 3'b000;
        while (!mem_valid) tick();
        if (!mem_lock || mem_write || (mem_addr != 64'h7000))
            fail("AMO read did not carry the internal phase marker");
        saved_mem_tag = mem_tag;
        tick();

        flush = 1'b1;
        tick();
        flush = 1'b0;
        mem_rdata = 64'd11;
        mem_resp_valid = 1'b1;
        mem_resp_tag = saved_mem_tag;
        tick();
        mem_resp_valid = 1'b0;
        while (!mem_valid) tick();
        if (!mem_lock || !mem_write || (mem_addr != 64'h7000) ||
            (mem_wdata != 64'd13) || (mem_wstrb != 8'hff))
            fail("flushed AMO did not reach its lock-releasing write");
        saved_mem_tag = mem_tag;
        tick();
        mem_resp_tag = saved_mem_tag;
        mem_resp_valid = 1'b1;
        tick();
        mem_resp_valid = 1'b0;
        while (!complete_valid[2]) tick();
        if (!complete_valid[2] ||
            (complete_payload[2*COMPLETE_WIDTH + COMPLETE_DATA +: 64] !=
             64'd11))
            fail("AMO completion after flush mismatch");

        $display("PASS: 3p local forwarding, four-entry load/store queues, store capacity/flush, EX1 ordering, EX0 M context, and irrevocable AMO");
        $finish;
    end

    wire unused_completion_fields = |{
        complete_payload[COMPLETE_CSR_WDATA +: 64],
        complete_payload[COMPLETE_CSR_ADDR +: 12],
        complete_payload[COMPLETE_CSR_WRITE],
        complete_payload[COMPLETE_TVAL +: 64],
        complete_payload[COMPLETE_CAUSE +: 5],
        complete_payload[COMPLETE_ILLEGAL],
        complete_payload[COMPLETE_RD +: 5],
        complete_payload[COMPLETE_INSTR +: 32],
        complete_payload[COMPLETE_NEXT_PC +: 64],
        complete_payload[COMPLETE_PC +: 64],
        complete_payload[COMPLETE_TRACE +: 64],
        issue_unsupported,
        mem1_valid, mem1_tag, mem1_lock, mem1_write, mem1_addr,
        mem1_wdata, mem1_wstrb, mem1_access, mem1_effective_addr,
        mem1_size,
        mem_xlate_only, mem_physical,
        csr_addr,
        mem_size
    };

endmodule
