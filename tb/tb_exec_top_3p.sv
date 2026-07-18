`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module tb_exec_top_3p;

    localparam integer SLOT_WIDTH = 3;
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
    reg [2:0] issue_valid;
    wire [2:0] issue_ready;
    wire [2:0] issue_unsupported;
    reg [3*64-1:0] issue_id;
    reg [3*SLOT_WIDTH-1:0] issue_slot;
    reg [3*ISSUE_WIDTH-1:0] issue_payload;
    reg ordered_head_valid;
    reg [63:0] ordered_head_id;
    reg [SLOT_WIDTH-1:0] ordered_head_slot;
    wire [2:0] complete_valid;
    reg [2:0] complete_ready;
    wire [3*64-1:0] complete_id;
    wire [3*SLOT_WIDTH-1:0] complete_slot;
    wire [3*COMPLETE_WIDTH-1:0] complete_payload;
    wire redirect_valid;
    wire [63:0] redirect_id;
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
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag;
    reg mem_error;
    reg mem_page_fault;
    reg mem_access_allowed;
    wire mem_write;
    wire [`RV64_XLEN-1:0] mem_addr;
    wire [`RV64_XLEN-1:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire mem_access;
    wire [`RV64_XLEN-1:0] mem_effective_addr;
    wire [2:0] mem_size;
    reg [`RV64_XLEN-1:0] mem_rdata;

    openrv64_exec_top_3p #(
        .RETIRE_SLOT_WIDTH(SLOT_WIDTH),
        .ENABLE_RV64M(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .issue_valid_i(issue_valid),
        .issue_ready_o(issue_ready),
        .issue_unsupported_o(issue_unsupported),
        .issue_id_i(issue_id),
        .issue_slot_i(issue_slot),
        .issue_payload_i(issue_payload),
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
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_error_i(mem_error),
        .mem_page_fault_i(mem_page_fault),
        .mem_access_allowed_i(mem_access_allowed),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_access_o(mem_access),
        .mem_effective_addr_o(mem_effective_addr),
        .mem_size_o(mem_size),
        .mem_rdata_i(mem_rdata)
    );

    always #5 clk = ~clk;

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

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        issue_valid = 3'b000;
        issue_id = 192'd0;
        issue_slot = 9'd0;
        issue_payload = {3*ISSUE_WIDTH{1'b0}};
        ordered_head_valid = 1'b0;
        ordered_head_id = 64'd0;
        ordered_head_slot = {SLOT_WIDTH{1'b0}};
        complete_ready = 3'b000;
        csr_rdata = 64'd0;
        csr_valid = 1'b1;
        csr_writable = 1'b1;
        mem_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
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
        issue_id[0*64 +: 64] = 64'd0;
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd0;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 base ALU was not ready");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[0]) fail("EX0 did not complete ADDI");
        if (complete_id[0*64 +: 64] != 64'd0)
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
        issue_id[0*64 +: 64] = 64'd5;
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

        // A branch is hard ordered and cannot issue under the wrong token.
        packet = packet_base(64'd101, 64'h2000, 32'h0020_8463);
        packet[ISSUE_RS1_DATA +: 64] = 64'h55;
        packet[ISSUE_RS2_DATA +: 64] = 64'h55;
        packet[ISSUE_IMM +: 64] = 64'd8;
        packet[ISSUE_BR_OP +: 4] = `RV64_BR_OP_BEQ;
        packet[ISSUE_BRANCH] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*64 +: 64] = 64'd1;
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd1;
        issue_valid = 3'b001;
        ordered_head_valid = 1'b1;
        ordered_head_id = 64'd99;
        ordered_head_slot = 3'd1;
        #1;
        if (issue_ready[0]) fail("EX0 issued branch under wrong order token");
        ordered_head_id = 64'd1;
        #1;
        if (!issue_ready[0]) fail("EX0 branch did not accept head token");
        if (!branch_resolved || !branch_taken || !redirect_valid)
            fail("EX0 branch resolution was not produced on issue");
        if ((redirect_id != 64'd1) || (redirect_target != 64'h2008))
            fail("EX0 branch redirect metadata mismatch");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[0]) fail("EX0 branch did not complete");
        complete_ready = 3'b001;
        tick();
        complete_ready = 3'b000;

        // A store may occupy MEM and compute its address, but the request is
        // invisible until the exact instruction reaches ordered head.
        packet = packet_base(64'd102, 64'h3000, 32'h0020_b023);
        packet[ISSUE_RS1 +: 5] = 5'd1;
        packet[ISSUE_RS2 +: 5] = 5'd2;
        packet[ISSUE_RS1_DATA +: 64] = 64'h4000;
        packet[ISSUE_RS2_DATA +: 64] = 64'hdead_beef_cafe_f00d;
        packet[ISSUE_LSU_OP +: 5] = `RV64_LSU_OP_SD;
        packet[ISSUE_MEM_WRITE] = 1'b1;
        issue_payload[2*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[2*64 +: 64] = 64'd2;
        issue_slot[2*SLOT_WIDTH +: SLOT_WIDTH] = 3'd2;
        ordered_head_id = 64'd1;
        ordered_head_slot = 3'd1;
        issue_valid = 3'b100;
        #1;
        if (!issue_ready[2]) fail("MEM did not accept store");
        tick();
        issue_valid = 3'b000;
        #1;
        if (mem_valid) fail("store escaped before ordered-head permission");
        if (!mem_access || (mem_effective_addr != 64'h4000))
            fail("MEM did not expose store address for protection checks");
        ordered_head_id = 64'd2;
        ordered_head_slot = 3'd2;
        #1;
        if (!mem_valid || !mem_write || (mem_addr != 64'h4000) ||
            (mem_wdata != 64'hdead_beef_cafe_f00d) || (mem_wstrb != 8'hff))
            fail("ordered store request mismatch");
        tick();
        mem_resp_valid = 1'b1;
        mem_resp_tag = 2'd0;
        tick();
        mem_resp_valid = 1'b0;
        #1;
        if (!complete_valid[2]) fail("MEM store did not complete");
        if (complete_payload[2*COMPLETE_WIDTH + COMPLETE_EXCEPTION])
            fail("MEM store raised an unexpected exception");
        complete_ready = 3'b100;
        tick();
        complete_ready = 3'b000;

        // EX1 M keeps its own context while EX0 remains independent.
        packet = packet_base(64'd103, 64'h5000, 32'h0220_82b3);
        packet[ISSUE_RS1_DATA +: 64] = 64'd6;
        packet[ISSUE_RS2_DATA +: 64] = 64'd7;
        packet[ISSUE_RD +: 5] = 5'd5;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_M;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_MUL;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*64 +: 64] = 64'd3;
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd3;
        issue_valid = 3'b010;
        #1;
        if (!issue_ready[1]) fail("EX1 did not accept MUL");
        tick();
        issue_valid = 3'b000;

        packet = packet_base(64'd104, 64'h5004, 32'h0020_8333);
        packet[ISSUE_RS1_DATA +: 64] = 64'd11;
        packet[ISSUE_RS2_DATA +: 64] = 64'd22;
        packet[ISSUE_RD +: 5] = 5'd6;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[0*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[0*64 +: 64] = 64'd4;
        issue_slot[0*SLOT_WIDTH +: SLOT_WIDTH] = 3'd4;
        issue_valid = 3'b001;
        #1;
        if (!issue_ready[0]) fail("EX0 was blocked by EX1 MUL");
        tick();
        issue_valid = 3'b000;
        #1;
        if (!complete_valid[0]) fail("EX0 did not complete while EX1 was busy");
        if (complete_payload[0*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd33)
            fail("concurrent EX0 ADD result mismatch");
        complete_ready = 3'b001;
        tick();
        complete_ready = 3'b000;

        wait_cycles = 0;
        while (!complete_valid[1] && (wait_cycles < 24)) begin
            tick();
            wait_cycles = wait_cycles + 1;
        end
        if (!complete_valid[1]) fail("EX1 MUL timed out");
        if (complete_id[1*64 +: 64] != 64'd3)
            fail("EX1 MUL completion ID mismatch");
        if (complete_payload[1*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd42)
            fail("EX1 MUL result mismatch");

        // EX1's result remains local as well.  A base-ALU consumer can accept
        // the completed M value without waiting for architectural retirement.
        packet = packet_base(64'd106, 64'h5008, 32'h0022_8393);
        packet[ISSUE_RS1 +: 5] = 5'd5;
        packet[ISSUE_RS1_DATA +: 64] = 64'd0;
        packet[ISSUE_IMM +: 64] = 64'd2;
        packet[ISSUE_RD +: 5] = 5'd7;
        packet[ISSUE_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
        packet[ISSUE_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
        packet[ISSUE_REG_WRITE] = 1'b1;
        issue_payload[1*ISSUE_WIDTH +: ISSUE_WIDTH] = packet;
        issue_id[1*64 +: 64] = 64'd6;
        issue_slot[1*SLOT_WIDTH +: SLOT_WIDTH] = 3'd6;
        complete_ready = 3'b010;
        issue_valid = 3'b010;
        #1;
        if (!issue_ready[1]) fail("EX1 local RAW consumer was not ready");
        tick();
        issue_valid = 3'b000;
        complete_ready = 3'b000;
        #1;
        if (!complete_valid[1] ||
            (complete_payload[1*COMPLETE_WIDTH + COMPLETE_DATA +: 64] != 64'd44))
            fail("EX1 local previous-result forwarding mismatch");

        $display("PASS: 3p local forwarding, EX0 ordering, EX1 M context, and MEM gating");
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
        csr_addr,
        mem_size
    };

endmodule
