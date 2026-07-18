`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module tb_dispatch_3p;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer MW = `OPENRV64_RETIRE_META_WIDTH;
    localparam integer SW = 3;

    localparam integer I_SYSTEM = 10;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
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
    reg [3*64-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    wire [2:0] allocation_valid;
    wire [3*MW-1:0] allocation_meta;
    reg [2:0] pipe_ready;
    reg [1:0] forward_valid;
    reg [2*5-1:0] forward_rd_addr;
    wire [2:0] pipe_valid;
    wire [3*64-1:0] pipe_id;
    wire [3*SW-1:0] pipe_slot;
    wire [3*IW-1:0] pipe_payload;
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
        allocation_id = {64'd2, 64'd1, 64'd0};
        allocation_slot = {3'd2, 3'd1, 3'd0};
        pipe_ready = 3'b111;
        forward_valid = 2'b00;
        forward_rd_addr = 10'd0;
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

        // A full older MEM pipe blocks the complete prefix; the younger ALU
        // cannot bypass it even though EX0 and EX1 are idle.
        p0 = alu_packet(64'd14, 0, 0, 0);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd15, 0, 0, 5'd12);
        enqueue2(p0, p1, 2'b00, 2'b00);
        pipe_ready = 3'b011;
        #1;
        if (allocation_valid != 0 || pipe_valid != 0)
            fail("younger ALU bypassed a stalled older memory operation");
        pipe_ready = 3'b111;
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
        // can issue MEM, M, and hard EX0 together as one ordered prefix.
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
            fail("MEM/M/EX0 candidates did not issue three-wide");

        $display("PASS: queued 3p dispatch routing, hazards, and ordering");
        $finish;
    end
endmodule
