`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

module tb_dispatch_3p;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer MW = `OPENRV64_RETIRE_META_WIDTH;
    localparam integer SW = 3;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;

    localparam integer I_SYSTEM = 10;
    localparam integer I_PREDICTED_TAKEN = 12;
    localparam integer I_BRANCH = 14;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_BR_OP = 18;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2_DATA = 104;
    localparam integer I_RS1_DATA = 168;
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
    wire [6*5-1:0] gpr_read_addr;
    reg [6*64-1:0] gpr_read_data;
    reg allocation_ready;
    reg [3*IDW-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    wire [2:0] allocation_valid;
    wire [3*MW-1:0] allocation_meta;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    reg [1:0] forward_valid;
    reg [2*5-1:0] forward_rd_addr;
    reg [2:0] completion_forward_valid;
    reg [3*5-1:0] completion_forward_rd_addr;
    reg [3*64-1:0] completion_forward_data;
    reg [2:0] branch_completion_forward_valid;
    reg [31:0] forward_map_valid;
    reg [32*64-1:0] forward_map_data;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SW-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IW-1:0] pipe_payload;
    reg [2:0] retire_valid;
    reg [2:0] retire_uses_rs1;
    reg [2:0] retire_uses_rs2;
    reg [3*5-1:0] retire_rs1_addr;
    reg [3*5-1:0] retire_rs2_addr;
    reg [2:0] retire_reg_write;
    reg [3*5-1:0] retire_rd_addr;
    reg [2:0] retire_hard;
    wire barrier_active;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;
    wire [31:0] write_busy;
    wire [2:0] queue_count;

    openrv64_dispatch_3p dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_frontend_i(squash),
        .decode_valid_i(decode_valid), .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .gpr_read_addr_o(gpr_read_addr), .gpr_read_data_i(gpr_read_data),
        .allocation_ready_i(allocation_ready),
        .allocation_id_i(allocation_id),
        .allocation_slot_i(allocation_slot),
        .allocation_valid_o(allocation_valid),
        .allocation_meta_o(allocation_meta),
        .pipe_ready_i(pipe_ready),
        .forward_valid_i(forward_valid),
        .forward_rd_addr_i(forward_rd_addr),
        .completion_forward_valid_i(completion_forward_valid),
        .completion_forward_rd_addr_i(completion_forward_rd_addr),
        .completion_forward_data_i(completion_forward_data),
        .branch_completion_forward_valid_i(
            branch_completion_forward_valid),
        .forward_map_valid_i(forward_map_valid),
        .forward_map_data_i(forward_map_data),
        .pipe_valid_o(pipe_valid),
        .pipe_id_o(pipe_id), .pipe_slot_o(pipe_slot),
        .pipe_payload_o(pipe_payload),
        .retire_valid_i(retire_valid),
        .retire_uses_rs1_i(retire_uses_rs1),
        .retire_uses_rs2_i(retire_uses_rs2),
        .retire_rs1_addr_i(retire_rs1_addr),
        .retire_rs2_addr_i(retire_rs2_addr),
        .retire_reg_write_i(retire_reg_write),
        .retire_rd_addr_i(retire_rd_addr),
        .retire_hard_i(retire_hard),
        .barrier_active_o(barrier_active),
        .raw_hazard_o(raw_hazard), .waw_hazard_o(waw_hazard),
        .read_port_hazard_o(read_port_hazard),
        .write_busy_o(write_busy), .queue_count_o(queue_count)
    );

    always #5 clk = ~clk;

    function automatic [IW-1:0] alu_packet;
        input [63:0] id;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        reg [IW-1:0] p;
        begin
            p = {IW{1'b0}};
            p[I_TRACE +: 64] = id;
            p[I_PC +: 64] = 64'h1000 + (id << 2);
            p[I_INSTR +: 32] = 32'h0000_0033;
            p[I_RS1 +: 5] = rs1;
            p[I_RS2 +: 5] = rs2;
            p[I_RD +: 5] = rd;
            p[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            p[I_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
            p[I_REG_WRITE] = (rd != 0);
            alu_packet = p;
        end
    endfunction

    function automatic [IW-1:0] branch_packet;
        input [63:0] id;
        input [`RV64_BR_OP_WIDTH-1:0] branch_op;
        input predicted_taken;
        input [4:0] rs1;
        input [4:0] rs2;
        reg [IW-1:0] p;
        begin
            p = alu_packet(id, rs1, rs2, 5'd0);
            p[I_INSTR +: 32] = 32'h0000_0063;
            p[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
            p[I_BRANCH] = 1'b1;
            p[I_PREDICTED_TAKEN] = predicted_taken;
            p[I_BR_OP +: `RV64_BR_OP_WIDTH] = branch_op;
            p[I_IMM +: 64] = 64'd8;
            branch_packet = p;
        end
    endfunction

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic fail;
        input [8*100-1:0] msg;
        begin $display("FAIL: %0s", msg); $fatal(1); end
    endtask

    task automatic enqueue2;
        input [IW-1:0] p0;
        input [IW-1:0] p1;
        input [1:0] uses1;
        input [1:0] uses2;
        begin
            decode_payload = {{IW{1'b0}}, p1, p0};
            decode_uses_rs1 = {1'b0, uses1};
            decode_uses_rs2 = {1'b0, uses2};
            decode_valid = 3'b011;
            #1;
            if (decode_ready[1:0] != 2'b11)
                fail("dispatch did not accept two decode lanes");
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
        end
    endtask

    reg [IW-1:0] p0;
    reg [IW-1:0] p1;
    reg [IW-1:0] issued0;
    reg [IW-1:0] issued1;

    initial begin
        clk = 0;
        rst_n = 0;
        flush = 0;
        squash = 0;
        decode_valid = 0;
        decode_payload = 0;
        decode_uses_rs1 = 0;
        decode_uses_rs2 = 0;
        gpr_read_data = 0;
        allocation_ready = 1;
        allocation_id = {IDW'(2), IDW'(1), IDW'(0)};
        allocation_slot = {3'd2, 3'd1, 3'd0};
        pipe_ready = 4'b1111;
        forward_valid = 2'b00;
        forward_rd_addr = 10'd0;
        completion_forward_valid = 3'b000;
        completion_forward_rd_addr = 15'd0;
        completion_forward_data = {3*64{1'b0}};
        branch_completion_forward_valid = 3'b000;
        forward_map_valid = 32'd0;
        forward_map_data = {32*64{1'b0}};
        retire_valid = 0;
        retire_uses_rs1 = 0;
        retire_uses_rs2 = 0;
        retire_rs1_addr = 0;
        retire_rs2_addr = 0;
        retire_reg_write = 0;
        retire_rd_addr = 0;
        retire_hard = 0;

        repeat (3) tick();
        rst_n = 1;
        tick();

        // Two independent base ALUs use both execution pipes.  Values from
        // all six physical read selectors are captured into issue packets.
        p0 = alu_packet(64'd10, 5'd1, 5'd2, 5'd8);
        p1 = alu_packet(64'd11, 5'd3, 5'd4, 5'd9);
        enqueue2(p0, p1, 2'b11, 2'b11);
        gpr_read_data[0*64 +: 64] = 64'h11;
        gpr_read_data[1*64 +: 64] = 64'h22;
        gpr_read_data[2*64 +: 64] = 64'h33;
        gpr_read_data[3*64 +: 64] = 64'h44;
        #1;
        if (gpr_read_addr[0*5 +: 5] != 5'd1 ||
            gpr_read_addr[1*5 +: 5] != 5'd2 ||
            gpr_read_addr[2*5 +: 5] != 5'd3 ||
            gpr_read_addr[3*5 +: 5] != 5'd4)
            fail("six-port selector addresses are mispacked");
        if (allocation_valid != 3'b011 || pipe_valid[1:0] != 2'b11)
            fail("two independent ALUs did not issue together");
        issued0 = pipe_payload[0*IW +: IW];
        issued1 = pipe_payload[1*IW +: IW];
        if (issued0[I_RS1_DATA +: 64] != 64'h11 ||
            issued0[I_RS2_DATA +: 64] != 64'h22 ||
            issued1[I_RS1_DATA +: 64] != 64'h33 ||
            issued1[I_RS2_DATA +: 64] != 64'h44)
            fail("issue did not capture GPR values");
        tick();
        if (queue_count != 0 || !write_busy[8] || !write_busy[9])
            fail("issue did not drain queue or claim destinations");

        // Release both owners, then construct a same-bundle RAW.  Only the
        // writer may issue; the dependent candidate and all younger work stop.
        retire_valid = 3'b011;
        retire_reg_write = 3'b011;
        retire_rd_addr = {5'd0, 5'd9, 5'd8};
        tick();
        retire_valid = 0;
        retire_reg_write = 0;
        p0 = alu_packet(64'd12, 5'd1, 5'd2, 5'd10);
        p1 = alu_packet(64'd13, 5'd10, 5'd4, 5'd11);
        enqueue2(p0, p1, 2'b11, 2'b11);
        #1;
        if (allocation_valid != 3'b001 || !raw_hazard[1])
            fail("same-bundle RAW did not terminate the issue prefix");
        tick();
        #1;
        if (queue_count != 1 || allocation_valid != 0)
            fail("dependent instruction bypassed its outstanding writer");

        // Completion metadata for EX1 forces the blocked generic ALU back to
        // EX1.  Dispatch sees no result data; the real value remains in EX1.
        forward_valid = 2'b10;
        forward_rd_addr[1*5 +: 5] = 5'd10;
        #1;
        if (allocation_valid != 3'b001 || pipe_valid != 3'b010)
            fail("same-pipe completion did not force and release RAW consumer");
        tick();
        forward_valid = 2'b00;
        forward_rd_addr = 10'd0;

        // The older producer may retire independently after its consumer has
        // captured the local forwarded value.
        retire_valid = 3'b001;
        retire_reg_write = 3'b001;
        retire_rd_addr = {10'd0, 5'd10};
        tick();
        retire_valid = 0;
        retire_reg_write = 0;

        // A live completion entry may release a cross-pipe dependency and
        // supplies its 64-bit value during dispatch operand capture.  It is
        // deliberately valid for this cycle only; no queue history is used.
        p0 = alu_packet(64'd22, 5'd1, 5'd2, 5'd20);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        tick();
        p0 = alu_packet(64'd23, 5'd20, 5'd0, 5'd21);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        #1;
        if (allocation_valid != 0 || !raw_hazard[0])
            fail("cross-pipe consumer was not initially RAW blocked");
        completion_forward_valid = 3'b100;
        completion_forward_rd_addr[2*5 +: 5] = 5'd20;
        completion_forward_data[2*64 +: 64] =
            64'hcafe_f00d_dead_beef;
        #1;
        if (allocation_valid != 3'b001)
            fail("live completion did not release cross-pipe consumer");
        if (pipe_payload[0*IW + I_RS1_DATA +: 64] !=
            64'hcafe_f00d_dead_beef)
            fail("live completion data was not captured by consumer");
        tick();
        completion_forward_valid = 3'b000;
        completion_forward_rd_addr = 15'd0;
        completion_forward_data = {3*64{1'b0}};
        flush = 1'b1;
        tick();
        flush = 1'b0;

        // A full older MEM pipe blocks the complete prefix; the younger ALU
        // cannot bypass it even though EX0 and EX1 are idle.
        p0 = alu_packet(64'd14, 0, 0, 0);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd15, 0, 0, 5'd12);
        enqueue2(p0, p1, 2'b00, 2'b00);
        pipe_ready = 4'b1011;
        #1;
        if (allocation_valid != 0 || pipe_valid != 0)
            fail("younger ALU bypassed a stalled older memory operation");
        pipe_ready = 4'b1111;
        #1;
        if (allocation_valid != 3'b011)
            fail("prefix did not resume when MEM became ready");
        tick();

        // A hard operation is the last allocation and holds the barrier until
        // that exact retirement class is released.
        p0 = alu_packet(64'd16, 0, 0, 0);
        p0[I_SYSTEM] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd17, 0, 0, 5'd13);
        enqueue2(p0, p1, 2'b00, 2'b00);
        #1;
        if (allocation_valid != 3'b001)
            fail("hard operation did not terminate allocation group");
        tick();
        if (!barrier_active) fail("hard-order barrier was not retained");
        if (allocation_valid != 0) fail("younger instruction crossed hard barrier");
        retire_valid = 3'b001;
        retire_hard = 3'b001;
        tick();
        retire_valid = 0;
        retire_hard = 0;
        #1;
        if (barrier_active || allocation_valid != 3'b001)
            fail("hard-order retirement did not reopen dispatch");
        tick();

        // Accumulate a three-entry window and prove that the physical geometry
        // can issue MEM, M, and hard EX1 together as one ordered prefix.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_ready = 1'b0;
        p0 = alu_packet(64'd18, 0, 0, 0);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd19, 0, 0, 0);
        p1[I_ALU_EXT +: 3] = `RV64_ALU_EXT_M;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_MUL;
        enqueue2(p0, p1, 2'b00, 2'b00);
        p0 = alu_packet(64'd20, 0, 0, 0);
        p0[I_SYSTEM] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd21, 0, 0, 0);
        enqueue2(p0, p1, 2'b00, 2'b00);
        allocation_ready = 1'b1;
        #1;
        if (allocation_valid != 3'b111 || pipe_valid != 3'b111)
            fail("MEM/M/EX1 candidates did not issue three-wide");

        // Equality-branch pairing is not the free-branch experiment: BEQ
        // still claims EX1 and remains hard retirement metadata.  A matching
        // prediction lets an independent ALU claim EX0 on the same edge.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = branch_packet(64'd30, `RV64_BR_OP_BEQ, 1'b1, 5'd1, 5'd2);
        p1 = alu_packet(64'd31, 5'd3, 5'd4, 5'd22);
        enqueue2(p0, p1, 2'b11, 2'b11);
        gpr_read_data[0*64 +: 64] = 64'h55;
        gpr_read_data[1*64 +: 64] = 64'h55;
        gpr_read_data[2*64 +: 64] = 64'h11;
        gpr_read_data[3*64 +: 64] = 64'h22;
        #1;
        if ((allocation_valid != 3'b011) || (pipe_valid != 3'b011))
            fail("correctly predicted BEQ did not pair with younger ALU");
        if ((pipe_payload[0*IW + I_TRACE +: 64] != 64'd31) ||
            (pipe_payload[1*IW + I_TRACE +: 64] != 64'd30))
            fail("branch pair did not allocate non-branch to EX0 first");
        if (!allocation_meta[MW-1])
            fail("paired BEQ lost hard retirement classification");

        // BNE uses the same contained comparator path.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = branch_packet(64'd32, `RV64_BR_OP_BNE, 1'b1, 5'd1, 5'd2);
        p1 = alu_packet(64'd33, 5'd3, 5'd4, 5'd23);
        enqueue2(p0, p1, 2'b11, 2'b11);
        gpr_read_data[0*64 +: 64] = 64'h55;
        gpr_read_data[1*64 +: 64] = 64'h66;
        #1;
        if ((allocation_valid != 3'b011) || (pipe_valid != 3'b011))
            fail("correctly predicted BNE did not pair with younger ALU");

        // A direction mismatch retains the normal barrier.  No younger
        // wrong-path instruction is allocated or issued.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = branch_packet(64'd34, `RV64_BR_OP_BEQ, 1'b0, 5'd1, 5'd2);
        p1 = alu_packet(64'd35, 5'd3, 5'd4, 5'd24);
        enqueue2(p0, p1, 2'b11, 2'b11);
        gpr_read_data[0*64 +: 64] = 64'h77;
        gpr_read_data[1*64 +: 64] = 64'h77;
        #1;
        if ((allocation_valid != 3'b001) || (pipe_valid != 3'b010))
            fail("mispredicted BEQ allowed younger wrong-path issue");

        // The exemption does not weaken RAW enforcement.  A BNE waiting on an
        // older writer blocks itself and the complete younger prefix until a
        // producer-ID-qualified branch completion arrives.  The MEM result is
        // deliberately nonzero while the stale GPR value is zero, proving the
        // pairing comparator consumes the forwarded operand.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = alu_packet(64'd36, 5'd0, 5'd0, 5'd25);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        tick();
        p0 = branch_packet(64'd37, `RV64_BR_OP_BNE, 1'b1, 5'd25, 5'd0);
        p1 = alu_packet(64'd38, 5'd3, 5'd4, 5'd26);
        enqueue2(p0, p1, 2'b01, 2'b00);
        gpr_read_data[0*64 +: 64] = 64'd0;
        gpr_read_data[1*64 +: 64] = 64'd0;
        #1;
        if ((allocation_valid != 3'b000) || !raw_hazard[0])
            fail("RAW-blocked BNE leaked younger issue through pairing");
        branch_completion_forward_valid = 3'b100;
        completion_forward_rd_addr[2*5 +: 5] = 5'd25;
        completion_forward_data[2*64 +: 64] =
            64'hfeed_face_cafe_beef;
        // Model a stale untagged value from an older same-rd writer.  The
        // producer-qualified branch result must have final mux priority.
        forward_map_valid[25] = 1'b1;
        forward_map_data[25*64 +: 64] = 64'd0;
        #1;
        if ((allocation_valid != 3'b011) || (pipe_valid != 3'b011))
            fail("MEM-to-branch forwarding did not release and pair BNE");
        if (pipe_payload[1*IW + I_RS1_DATA +: 64] !=
            64'hfeed_face_cafe_beef)
            fail("MEM-to-branch value did not reach branch comparator");
        tick();
        branch_completion_forward_valid = 3'b000;
        completion_forward_rd_addr = 15'd0;
        completion_forward_data = {3*64{1'b0}};
        forward_map_valid = 32'd0;
        forward_map_data = {32*64{1'b0}};

        // Branch-only validity is contained: the same live source cannot
        // release an ordinary ALU consumer.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = alu_packet(64'd39, 5'd0, 5'd0, 5'd27);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        tick();
        p0 = alu_packet(64'd40, 5'd27, 5'd0, 5'd28);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        branch_completion_forward_valid = 3'b010;
        completion_forward_rd_addr[1*5 +: 5] = 5'd27;
        completion_forward_data[1*64 +: 64] = 64'h1234;
        #1;
        if ((allocation_valid != 3'b000) || !raw_hazard[0])
            fail("branch-only bypass incorrectly released ALU consumer");

        // The EX0 source does release a conditional branch and supplies the
        // value used by its direction check.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        branch_completion_forward_valid = 3'b000;
        completion_forward_rd_addr = 15'd0;
        completion_forward_data = {3*64{1'b0}};
        p0 = alu_packet(64'd41, 5'd0, 5'd0, 5'd29);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        tick();
        p0 = branch_packet(64'd42, `RV64_BR_OP_BEQ, 1'b1, 5'd29, 5'd0);
        p1 = alu_packet(64'd43, 5'd3, 5'd4, 5'd30);
        enqueue2(p0, p1, 2'b01, 2'b00);
        gpr_read_data[0*64 +: 64] = 64'hdead;
        branch_completion_forward_valid = 3'b001;
        completion_forward_rd_addr[0*5 +: 5] = 5'd29;
        completion_forward_data[0*64 +: 64] = 64'd0;
        #1;
        if ((allocation_valid != 3'b011) || (pipe_valid != 3'b011))
            fail("EX0-to-EX1 branch forwarding did not release and pair BEQ");
        if (pipe_payload[1*IW + I_RS1_DATA +: 64] != 64'd0)
            fail("EX0-to-EX1 branch value did not reach branch comparator");

        // A branch may also consume EX1's local previous-cycle result.  That
        // value is applied inside EX1 and is not visible to dispatch's
        // equality-pairing comparator.  Even when stale GPR data happens to
        // agree with the prediction, the younger candidate must stay behind
        // the branch.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        branch_completion_forward_valid = 3'b000;
        completion_forward_rd_addr = 15'd0;
        completion_forward_data = {3*64{1'b0}};
        forward_valid = 2'b00;
        forward_rd_addr = 10'd0;
        p0 = alu_packet(64'd44, 5'd0, 5'd0, 5'd29);
        p1 = alu_packet(64'd45, 5'd0, 5'd0, 5'd30);
        enqueue2(p0, p1, 2'b00, 2'b00);
        tick();
        p0 = branch_packet(64'd46, `RV64_BR_OP_BNE, 1'b1, 5'd29, 5'd30);
        p1 = alu_packet(64'd47, 5'd3, 5'd4, 5'd31);
        enqueue2(p0, p1, 2'b11, 2'b01);
        gpr_read_data[0*64 +: 64] = 64'd0;
        gpr_read_data[1*64 +: 64] = 64'd44;
        branch_completion_forward_valid = 3'b001;
        completion_forward_rd_addr[0*5 +: 5] = 5'd29;
        completion_forward_data[0*64 +: 64] = 64'd45;
        forward_valid = 2'b10;
        forward_rd_addr[1*5 +: 5] = 5'd30;
        #1;
        if ((allocation_valid != 3'b001) || (pipe_valid != 3'b010))
            fail("local-forward-dependent branch admitted younger pairing");

        // The two memory pipes have fixed roles: ordinary loads use MEM0,
        // while stores and RV64A use MEM1.
        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = alu_packet(64'd48, 5'd0, 5'd0, 5'd1);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd49, 5'd0, 5'd0, 5'd2);
        p1[I_MEM_WRITE] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        enqueue2(p0, p1, 2'b00, 2'b00);
        #1;
        if ((allocation_valid != 3'b011) ||
            (pipe_valid != 4'b1100))
            fail("load/store prefix did not route to MEM0/MEM1");

        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = alu_packet(64'd50, 5'd0, 5'd0, 5'd1);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd51, 5'd0, 5'd0, 5'd2);
        p1[I_MEM_READ] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        enqueue2(p0, p1, 2'b00, 2'b00);
        #1;
        if ((allocation_valid != 3'b001) ||
            (pipe_valid != 4'b0100))
            fail("two loads incorrectly occupied both memory pipes");

        tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        p0 = alu_packet(64'd52, 5'd0, 5'd0, 5'd1);
        p0[I_INSTR +: 32] = 32'h1000_302f;
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b001;
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        #1;
        if ((allocation_valid != 3'b001) ||
            (pipe_valid != 4'b1000))
            fail("read-only RV64A operation did not route to MEM1");

        $display("PASS: queued 3p dispatch routing, split MEM roles, hazards, branch forwarding, pairing, and ordering");
        $finish;
    end
endmodule
