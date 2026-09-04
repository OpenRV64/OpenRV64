`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module tb_dispatch_window_3p;
    localparam integer DEPTH = 16;
    localparam integer SW = 4;
    localparam integer CW = 5;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer OW = `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH;
    localparam integer MW = `OPENRV64_DISPATCH_META_WIDTH;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;

    localparam integer I_REG_WRITE = 17;
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
    localparam integer I_MEM_READ = 16;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_BRANCH = 14;
    localparam integer I_JUMP = 13;
    localparam integer I_PREDICTED = 12;
    localparam integer I_BR_OP = 18;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg squash_inclusive;
    reg [IDW-1:0] squash_id;
    reg translation_bypass;
    reg [2:0] decode_valid;
    wire [2:0] decode_ready;
    reg [3*IW-1:0] decode_payload;
    reg [2:0] decode_uses_rs1;
    reg [2:0] decode_uses_rs2;
    reg prediction_update_valid;
    reg [IDW-1:0] prediction_update_id;
    reg [SW-1:0] prediction_update_slot;
    reg prediction_update_taken;
    wire [6*5-1:0] gpr_read_addr;
    reg [6*64-1:0] gpr_read_data;
    reg allocation_ready;
    reg [3*IDW-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    wire [2:0] allocation_valid;
    wire [3*MW-1:0] allocation_meta;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_squashed;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SW-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IW-1:0] pipe_payload;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src1_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0] pipe_src1_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src2_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0] pipe_src2_producer_id;
    reg [2:0] completion_valid;
    reg [3*IDW-1:0] completion_id;
    reg [3*OW-1:0] completion_payload;
    reg conditional_resolve_valid;
    reg [IDW-1:0] conditional_resolve_id;
    reg [SW-1:0] conditional_resolve_slot;
    reg [2:0] retire_valid;
    reg [3*IDW-1:0] retire_id;
    reg [3*SW-1:0] retire_slot;
    reg [2:0] retire_hard;
    reg [IDW-1:0] next_retire_id;
    reg [SW-1:0] next_retire_slot;
    wire barrier_active;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;
    wire [31:0] write_busy;
    wire [CW-1:0] queue_count;

    openrv64_dispatch_window_3p #(
        .ENABLE_SPECULATION(1), .DEPTH(DEPTH),
        .CACHEABLE_BASE(64'h0000_0000_8000_0000),
        .CACHEABLE_SIZE(64'h0000_0000_0100_0000),
        .RETIRE_SLOT_WIDTH(SW), .COUNT_WIDTH(CW)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_frontend_i(squash),
        .squash_inclusive_i(squash_inclusive),
        .squash_id_i(squash_id),
        .translation_bypass_i(translation_bypass),
        .decode_valid_i(decode_valid), .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .prediction_update_valid_i(prediction_update_valid),
        .prediction_update_id_i(prediction_update_id),
        .prediction_update_slot_i(prediction_update_slot),
        .prediction_update_taken_i(prediction_update_taken),
        .gpr_read_addr_o(gpr_read_addr), .gpr_read_data_i(gpr_read_data),
        .physical_forward_valid_i(3'b000),
        .allocation_ready_i(allocation_ready),
        .allocation_id_i(allocation_id),
        .allocation_slot_i(allocation_slot),
        .allocation_valid_o(allocation_valid),
        .allocation_meta_o(allocation_meta),
        .pipe_ready_i(pipe_ready),
        .chain_producer_valid_i(2'b00),
        .chain_producer_id_i(
            {2*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .chain_producer_phys_i(
            {2*`OPENRV64_PHYS_REG_ADDR_WIDTH{1'b0}}),
        .pipe_valid_o(pipe_valid),
        .pipe_squashed_o(pipe_squashed),
        .pipe_id_o(pipe_id), .pipe_slot_o(pipe_slot),
        .pipe_payload_o(pipe_payload),
        .pipe_src1_producer_valid_o(pipe_src1_producer_valid),
        .pipe_src1_producer_id_o(pipe_src1_producer_id),
        .pipe_src2_producer_valid_o(pipe_src2_producer_valid),
        .pipe_src2_producer_id_o(pipe_src2_producer_id),
        .completion_valid_i(completion_valid),
        .completion_id_i(completion_id),
        .completion_payload_i(completion_payload),
        .conditional_resolve_valid_i(conditional_resolve_valid),
        .conditional_resolve_id_i(conditional_resolve_id),
        .conditional_resolve_slot_i(conditional_resolve_slot),
        .retire_valid_i(retire_valid), .retire_id_i(retire_id),
        .retire_slot_i(retire_slot), .retire_hard_i(retire_hard),
        .next_retire_id_i(next_retire_id),
        .next_retire_slot_i(next_retire_slot),
        .barrier_active_o(barrier_active), .raw_hazard_o(raw_hazard),
        .waw_hazard_o(waw_hazard),
        .read_port_hazard_o(read_port_hazard),
        .write_busy_o(write_busy), .queue_count_o(queue_count)
    );

    always #5 clk = ~clk;

    function automatic [IW-1:0] alu_packet;
        input [63:0] trace_id;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[I_TRACE +: 64] = trace_id;
            packet[I_PC +: 64] = 64'h8000_0000 + (trace_id << 2);
            packet[I_INSTR +: 32] = 32'h0000_0033;
            packet[I_RS1 +: 5] = rs1;
            packet[I_RS2 +: 5] = rs2;
            packet[I_RD +: 5] = rd;
            packet[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
            packet[I_REG_WRITE] = (rd != 0);
            alu_packet = packet;
        end
    endfunction

    function automatic [OW-1:0] reg_completion;
        input [4:0] rd;
        input [63:0] data;
        reg [OW-1:0] packet;
        begin
            packet = {OW{1'b0}};
            packet[`OPENRV64_COMPLETE_REG_WRITE_BIT] = (rd != 0);
            packet[`OPENRV64_COMPLETE_RD_LSB +: 5] = rd;
            packet[`OPENRV64_COMPLETE_DATA_LSB +: 64] = data;
            reg_completion = packet;
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic clear_inputs;
        begin
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
            prediction_update_valid = 1'b0;
            prediction_update_id = {IDW{1'b0}};
            prediction_update_slot = {SW{1'b0}};
            prediction_update_taken = 1'b0;
            completion_valid = 3'b000;
            completion_id = {3*IDW{1'b0}};
            completion_payload = {3*OW{1'b0}};
            conditional_resolve_valid = 1'b0;
            conditional_resolve_id = {IDW{1'b0}};
            conditional_resolve_slot = {SW{1'b0}};
            retire_valid = 3'b000;
            retire_id = {3*IDW{1'b0}};
            retire_slot = {3*SW{1'b0}};
            retire_hard = 3'b000;
        end
    endtask

    reg [IW-1:0] p0;
    reg [IW-1:0] p1;
    reg [IW-1:0] p2;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        squash_inclusive = 1'b0;
        squash_id = IDW'(0);
        translation_bypass = 1'b0;
        allocation_ready = 1'b1;
        allocation_id = {IDW'(3), IDW'(2), IDW'(1)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        pipe_ready = 4'b1111;
        gpr_read_data = {6*64{1'b0}};
        next_retire_id = IDW'(1);
        next_retire_slot = 4'd0;
        clear_inputs();

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // The dependent middle entry must not head-of-line block a younger,
        // independent ALU.  Both ready entries issue from the registered
        // post-decode window one cycle after admission.
        p0 = alu_packet(64'd1, 5'd1, 5'd0, 5'd5);
        p1 = alu_packet(64'd2, 5'd5, 5'd0, 5'd6);
        p2 = alu_packet(64'd3, 5'd2, 5'd0, 5'd7);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_valid = 3'b111;
        #1;
        if (allocation_valid != 3'b111)
            fail("window did not allocate all three decode lanes");
        tick();
        clear_inputs();
        #1;
        if (pipe_valid[1:0] != 2'b11 ||
            pipe_id[0*IDW +: IDW] != IDW'(1) ||
            pipe_id[1*IDW +: IDW] != IDW'(3))
            fail("oldest-ready scan did not issue around blocked entry");
        tick();
        if (queue_count != 5'd3 || !write_busy[5] ||
            !write_busy[6] || !write_busy[7])
            fail("issued entries did not remain owned until retirement");

        completion_valid = 3'b001;
        completion_id[0*IDW +: IDW] = IDW'(1);
        completion_payload[0*OW +: OW] = reg_completion(5'd5, 64'h2a);
        #1;
        if (!pipe_valid[0] || pipe_id[0*IDW +: IDW] != IDW'(2) ||
            pipe_payload[0*IW + I_RS1_DATA +: 64] != 64'h2a)
            fail("matching completion did not wake dependent entry");
        tick();
        clear_inputs();

        // A flush starts a fresh WAW test.  The consumer must follow the
        // youngest writer, not whichever writer happens to complete first.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(12), IDW'(11), IDW'(10)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(10);
        p0 = alu_packet(64'd10, 5'd1, 5'd0, 5'd10);
        p1 = alu_packet(64'd11, 5'd2, 5'd0, 5'd10);
        p2 = alu_packet(64'd12, 5'd10, 5'd0, 5'd11);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        if (pipe_valid[1:0] != 2'b11)
            fail("two WAW producers did not issue independently");
        tick();

        completion_valid = 3'b001;
        completion_id[0*IDW +: IDW] = IDW'(10);
        completion_payload[0*OW +: OW] = reg_completion(5'd10, 64'h10);
        #1;
        if (|pipe_valid)
            fail("consumer woke from stale older WAW completion");
        tick();
        completion_id[0*IDW +: IDW] = IDW'(11);
        completion_payload[0*OW +: OW] = reg_completion(5'd10, 64'h11);
        #1;
        if (!pipe_valid[0] || pipe_id[0*IDW +: IDW] != IDW'(12) ||
            pipe_payload[0*IW + I_RS1_DATA +: 64] != 64'h11)
            fail("consumer did not select youngest WAW producer value");
        if (!pipe_src1_producer_valid[0] ||
            pipe_src1_producer_id[0*IDW +: IDW] != IDW'(11) ||
            pipe_src2_producer_valid[0])
            fail("consumer issue lost its source producer tag");
        tick();
        clear_inputs();

        // Retire all three entries while immediately reusing slot 0 for a
        // younger writer.  The registered owner release must match by ID and
        // must not clear that replacement on the following cycle.
        allocation_id = {IDW'(0), IDW'(0), IDW'(13)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        p0 = alu_packet(64'd13, 5'd3, 5'd0, 5'd10);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        retire_valid = 3'b111;
        retire_id = {IDW'(12), IDW'(11), IDW'(10)};
        retire_slot = {4'd2, 4'd1, 4'd0};
        tick();
        clear_inputs();
        if (queue_count != 1 || !write_busy[10])
            fail("retirement did not reuse the released window slot");
        tick();
        if (!write_busy[10] || write_busy[11])
            fail("registered retirement cleared a younger WAW owner");

        // Selective recovery must reveal an older surviving WAW producer and
        // retain its completed value for instructions decoded after redirect.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(22), IDW'(21), IDW'(20)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(20);
        p0 = alu_packet(64'd20, 5'd1, 5'd0, 5'd10);
        p1 = alu_packet(64'd21, 5'd2, 5'd0, 5'd10);
        p2 = alu_packet(64'd22, 5'd3, 5'd0, 5'd12);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        pipe_ready = 4'b1111;
        squash_id = IDW'(20);
        squash = 1'b1;
        #1;
        if (|decode_ready || (pipe_valid != 4'b0011) ||
            (pipe_squashed != 4'b0010) ||
            (pipe_id[0 +: IDW] != IDW'(20)) ||
            (pipe_id[1*IDW +: IDW] != IDW'(21)))
            fail("redirect did not flag only the younger issue candidate");
        tick();
        squash = 1'b0;
        #1;
        if (queue_count != 3 || !write_busy[12] || |decode_ready ||
            (pipe_valid != 4'b0001) || (pipe_squashed != 4'b0001) ||
            (pipe_id[0 +: IDW] != IDW'(22)))
            fail("redirect edge did not hold state for recovery task");
        tick();
        if (queue_count != 1 || !write_busy[10] || write_busy[12])
            fail("deferred recovery did not rebuild surviving WAW owner");

        completion_valid = 3'b001;
        completion_id[0 +: IDW] = IDW'(20);
        completion_payload[0 +: OW] = reg_completion(5'd10, 64'h55);
        tick();
        clear_inputs();
        allocation_id = {IDW'(32), IDW'(31), IDW'(30)};
        allocation_slot = {4'd3, 4'd2, 4'd1};
        p0 = alu_packet(64'd30, 5'd10, 5'd0, 5'd11);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        #1;
        if (!allocation_valid[0] ||
            allocation_meta[I_RS1_DATA +: 64] != 64'h55)
            fail("post-recovery decode lost surviving producer value");
        tick();
        clear_inputs();

        // A load whose base is supplied by a producer completion may begin
        // translation behind a live branch even when its virtual address is
        // outside the old physical-looking aperture. PMA classification
        // belongs to the translated physical address in the LSQ, not this VA.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b1111;
        allocation_id = {IDW'(42), IDW'(41), IDW'(40)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(40);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd40, 5'd0, 5'd0, 5'd5);
        p1 = alu_packet(64'd41, 5'd0, 5'd0, 5'd0);
        p1[I_BRANCH] = 1'b1;
        p2 = alu_packet(64'd42, 5'd5, 5'd0, 5'd6);
        p2[I_MEM_READ] = 1'b1;
        p2[I_IMM +: 64] = 64'h20;
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b100;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        if ((pipe_valid[1:0] != 2'b11) || pipe_valid[2] ||
            (pipe_id[0 +: IDW] != IDW'(40)) ||
            (pipe_id[IDW +: IDW] != IDW'(41)))
            fail("branch/producer setup for speculative load failed");
        tick();

        completion_valid = 3'b001;
        completion_id[0 +: IDW] = IDW'(40);
        completion_payload[0 +: OW] =
            reg_completion(5'd5, 64'hffff_ffd6_0000_1000);
        #1;
        if (!pipe_valid[2] ||
            (pipe_id[2*IDW +: IDW] != IDW'(42)) ||
            (pipe_payload[2*IW + I_RS1_DATA +: 64] !=
             64'hffff_ffd6_0000_1000))
            fail("arbitrary-VA load did not reach translation past branch");
        tick();
        clear_inputs();

        // In Bare/M-mode the effective address is already physical. A device
        // load must therefore remain behind the unresolved branch instead of
        // entering the LSQ merely to rediscover that it is non-cacheable.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        translation_bypass = 1'b1;
        allocation_id = {IDW'(46), IDW'(45), IDW'(44)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(44);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd44, 5'd0, 5'd0, 5'd5);
        p1 = alu_packet(64'd45, 5'd0, 5'd0, 5'd0);
        p1[I_BRANCH] = 1'b1;
        p2 = alu_packet(64'd46, 5'd5, 5'd0, 5'd6);
        p2[I_MEM_READ] = 1'b1;
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b100;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        if ((pipe_valid[1:0] != 2'b11) || pipe_valid[2])
            fail("Bare-mode branch/device-load setup failed");
        tick();
        completion_valid = 3'b001;
        completion_id[0 +: IDW] = IDW'(44);
        completion_payload[0 +: OW] =
            reg_completion(5'd5, 64'h0000_0000_1000_0000);
        #1;
        if (pipe_valid[2])
            fail("Bare-mode device load passed unresolved branch");
        tick();
        clear_inputs();
        translation_bypass = 1'b0;

        // A non-speculative Bare-mode load remains behind an unresolved
        // conditional
        // branch, then becomes eligible on the cycle after EX1 publishes the
        // tagged resolve event.  Branches have no register-write completion,
        // so this specifically checks the control-resolution sideband.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        translation_bypass = 1'b1;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(0), IDW'(48), IDW'(47)};
        allocation_slot = {4'd0, 4'd1, 4'd0};
        next_retire_id = IDW'(47);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd47, 5'd0, 5'd0, 5'd0);
        p0[I_INSTR +: 32] = 32'h0000_0463;
        p0[I_IMM +: 64] = 64'd8;
        p0[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_BEQ;
        p0[I_BRANCH] = 1'b1;
        p1 = alu_packet(64'd48, 5'd0, 5'd0, 5'd6);
        p1[I_MEM_READ] = 1'b1;
        p1[I_IMM +: 64] = 64'h0000_0000_1000_0000;
        decode_payload = {{IW{1'b0}}, p1, p0};
        decode_uses_rs1 = 3'b010;
        decode_valid = 3'b011;
        tick();
        clear_inputs();
        pipe_ready = 4'b1111;
        #1;
        if (!pipe_valid[1] ||
            pipe_id[1*IDW +: IDW] != IDW'(47) || pipe_valid[2])
            fail("load was not gated by unresolved conditional branch");
        conditional_resolve_valid = 1'b1;
        conditional_resolve_id = IDW'(47);
        conditional_resolve_slot = 4'd0;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[2] ||
            pipe_id[2*IDW +: IDW] != IDW'(48))
            fail("resolved conditional branch did not release load");
        tick();
        clear_inputs();
        translation_bypass = 1'b0;

        // A legal aligned direct JAL has a deterministic target and must not
        // wait for the retirement head or prevent younger replayable ALU work
        // from issuing.  ID 49 represents older work outside this window; the
        // old persistent-hard policy would issue only ID 50 and deadlock 51/52.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(52), IDW'(51), IDW'(50)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(49);
        next_retire_slot = 4'd15;
        p0 = alu_packet(64'd50, 5'd1, 5'd0, 5'd5);
        p1 = alu_packet(64'd51, 5'd0, 5'd0, 5'd1);
        p1[I_INSTR +: 32] = 32'h0080_00ef;
        p1[I_IMM +: 64] = 64'd8;
        p1[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_JAL;
        p1[I_JUMP] = 1'b1;
        p1[I_PREDICTED] = 1'b1;
        p2 = alu_packet(64'd52, 5'd2, 5'd0, 5'd6);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b101;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        #1;
        if (pipe_valid[1:0] != 2'b11 ||
            pipe_id[0*IDW +: IDW] != IDW'(50) ||
            pipe_id[1*IDW +: IDW] != IDW'(51))
            fail("direct JAL did not issue before retirement head");
        tick();
        #1;
        if (!pipe_valid[0] ||
            pipe_id[0*IDW +: IDW] != IDW'(52))
            fail("direct JAL blocked younger replayable ALU");
        tick();
        clear_inputs();

        // A conditional branch waiting for a compare operand must not form a
        // data-execution frontier in speculation mode.  A younger conditional
        // branch must nevertheless wait, preventing nested wrong-path branch
        // resolution/training, while independent ALU work continues around it.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(0), IDW'(0), IDW'(60)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(60);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd60, 5'd1, 5'd0, 5'd5);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();

        allocation_id = {IDW'(63), IDW'(62), IDW'(61)};
        allocation_slot = {4'd3, 4'd2, 4'd1};
        p0 = alu_packet(64'd61, 5'd5, 5'd0, 5'd0);
        p0[I_INSTR +: 32] = 32'h0002_8463;
        p0[I_IMM +: 64] = 64'd8;
        p0[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_BEQ;
        p0[I_BRANCH] = 1'b1;
        p1 = alu_packet(64'd62, 5'd0, 5'd0, 5'd0);
        p1[I_INSTR +: 32] = 32'h0000_0463;
        p1[I_IMM +: 64] = 64'd8;
        p1[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_BEQ;
        p1[I_BRANCH] = 1'b1;
        p2 = alu_packet(64'd63, 5'd2, 5'd0, 5'd6);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        pipe_ready = 4'b1111;
        #1;
        if (pipe_valid[1:0] != 2'b11 ||
            pipe_id[0*IDW +: IDW] != IDW'(60) ||
            pipe_id[1*IDW +: IDW] != IDW'(63))
            fail("unready conditional branch blocked younger ALU");
        if ((pipe_valid[0] &&
             (pipe_id[0*IDW +: IDW] == IDW'(62))) ||
            (pipe_valid[1] &&
             (pipe_id[1*IDW +: IDW] == IDW'(62))))
            fail("younger conditional branch passed unresolved older branch");
        tick();

        completion_valid = 3'b001;
        completion_id[0 +: IDW] = IDW'(60);
        completion_payload[0 +: OW] = reg_completion(5'd5, 64'h1234);
        #1;
        if (!pipe_valid[1] ||
            pipe_id[1*IDW +: IDW] != IDW'(61) ||
            pipe_payload[1*IW + I_RS1_DATA +: 64] != 64'h1234)
            fail("released conditional branch did not wake and issue");
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[1] ||
            pipe_id[1*IDW +: IDW] != IDW'(62))
            fail("younger conditional branch did not issue after older resolve");
        squash_id = IDW'(62);
        squash = 1'b1;
        #1;
        if ((pipe_valid != 4'b0010) ||
            (pipe_id[1*IDW +: IDW] != IDW'(62)))
            fail("redirect cancelled its own EX1 issue handshake");
        tick();
        squash = 1'b0;
        clear_inputs();

        // Modular age ordering must treat ID 0 as younger than 1023.  Begin
        // recovery at ID 0, then preempt it on the cleanup cycle with the older
        // ID 1023.  Cleanup must restart rather than committing the younger
        // cut, and the bulk window state must remain held for that extra cycle.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(0), IDW'(1023), IDW'(1022)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(1022);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd1022, 5'd1, 5'd0, 5'd5);
        p1 = alu_packet(64'd1023, 5'd2, 5'd0, 5'd6);
        p2 = alu_packet(64'd1024, 5'd3, 5'd0, 5'd7);
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        pipe_ready = 4'b1111;
        squash_id = IDW'(0);
        squash = 1'b1;
        #1;
        if ((pipe_valid != 4'b0011) || (pipe_squashed != 4'b0000) ||
            (pipe_id[0*IDW +: IDW] != IDW'(1022)) ||
            (pipe_id[1*IDW +: IDW] != IDW'(1023)))
            fail("wraparound redirect did not issue only its older prefix");
        tick();
        squash_id = IDW'(1023);
        #1;
        if (queue_count != 3 || (pipe_valid != 4'b0001) ||
            (pipe_squashed != 4'b0001) ||
            (pipe_id[0 +: IDW] != IDW'(0)))
            fail("first recovery cut changed state before cleanup cycle");
        tick();
        squash = 1'b0;
        if (queue_count != 3)
            fail("older redirect did not preempt pending recovery");
        tick();
        if (queue_count != 2 || write_busy[7])
            fail("preempted recovery misordered modular IDs at wrap");

        // Memory replay is an inclusive cut: unlike a branch redirect, the
        // instruction naming the cut must not remain resident in the issue
        // window after the retire queue has discarded it.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(0), IDW'(0), IDW'(70)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(70);
        p0 = alu_packet(64'd70, 5'd1, 5'd0, 5'd8);
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        squash_id = IDW'(70);
        squash_inclusive = 1'b1;
        squash = 1'b1;
        tick();
        squash = 1'b0;
        squash_inclusive = 1'b0;
        tick();
        if (queue_count != 0 || write_busy[8])
            fail("inclusive recovery retained its cut instruction");

        // A single memory operation must obey the same fixed-lane contract as
        // strict dispatch before testing paired admission below.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b1111;
        allocation_id = {IDW'(0), IDW'(0), IDW'(70)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(70);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd70, 5'd1, 5'd0, 5'd5);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[2] || pipe_valid[3] ||
            pipe_id[2*IDW +: IDW] != IDW'(70))
            fail("issue-window load did not route exclusively to MEM0");

        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(0), IDW'(0), IDW'(71)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(71);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd71, 5'd1, 5'd2, 5'd0);
        p0[I_INSTR +: 32] = 32'h0020_b023;
        p0[I_MEM_WRITE] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[3] || pipe_valid[2] ||
            pipe_id[3*IDW +: IDW] != IDW'(71))
            fail("issue-window store did not route exclusively to MEM1");

        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(0), IDW'(0), IDW'(72)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(72);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd72, 5'd1, 5'd0, 5'd5);
        p0[I_INSTR +: 32] = 32'h1000_302f;
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[3] || pipe_valid[2] ||
            pipe_id[3*IDW +: IDW] != IDW'(72))
            fail("issue-window RV64A load did not route to MEM1");

        // The oldest two memory operations may issue together when they use
        // opposite fixed-role lanes.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b1111;
        allocation_id = {IDW'(0), IDW'(74), IDW'(73)};
        allocation_slot = {4'd0, 4'd1, 4'd0};
        next_retire_id = IDW'(73);
        next_retire_slot = 4'd0;
        p0 = alu_packet(64'd73, 5'd1, 5'd0, 5'd5);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd74, 5'd2, 5'd3, 5'd0);
        p1[I_INSTR +: 32] = 32'h0031_3023;
        p1[I_MEM_WRITE] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{IW{1'b0}}, p1, p0};
        decode_uses_rs1 = 3'b011;
        decode_uses_rs2 = 3'b010;
        decode_valid = 3'b011;
        tick();
        clear_inputs();
        #1;
        if (pipe_valid[3:2] != 2'b11 ||
            pipe_id[2*IDW +: IDW] != IDW'(73) ||
            pipe_id[3*IDW +: IDW] != IDW'(74))
            fail("oldest load/store pair did not dual issue");
        tick();
        #1;
        if (|pipe_valid[3:2])
            fail("dual-issued load/store pair was not marked issued");

        // Reverse program order is also legal.  The execution queues retain
        // the store-before-load ordering contract.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(0), IDW'(76), IDW'(75)};
        allocation_slot = {4'd0, 4'd1, 4'd0};
        next_retire_id = IDW'(75);
        p0 = alu_packet(64'd75, 5'd2, 5'd3, 5'd0);
        p0[I_INSTR +: 32] = 32'h0031_3023;
        p0[I_MEM_WRITE] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd76, 5'd1, 5'd0, 5'd5);
        p1[I_MEM_READ] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{IW{1'b0}}, p1, p0};
        decode_uses_rs1 = 3'b011;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b011;
        tick();
        clear_inputs();
        #1;
        if (pipe_valid[3:2] != 2'b11 ||
            pipe_id[3*IDW +: IDW] != IDW'(75) ||
            pipe_id[2*IDW +: IDW] != IDW'(76))
            fail("oldest store/load pair did not dual issue");
        tick();

        // A younger operation must not issue alone when the older operation's
        // lane is blocked.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0100;
        allocation_id = {IDW'(0), IDW'(78), IDW'(77)};
        allocation_slot = {4'd0, 4'd1, 4'd0};
        next_retire_id = IDW'(77);
        p0 = alu_packet(64'd77, 5'd2, 5'd3, 5'd0);
        p0[I_INSTR +: 32] = 32'h0031_3023;
        p0[I_MEM_WRITE] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd78, 5'd1, 5'd0, 5'd5);
        p1[I_MEM_READ] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{IW{1'b0}}, p1, p0};
        decode_uses_rs1 = 3'b011;
        decode_uses_rs2 = 3'b001;
        decode_valid = 3'b011;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[3] || pipe_valid[2])
            fail("younger load escaped blocked older store");
        tick();
        pipe_ready = 4'b1100;
        #1;
        if (pipe_valid[3:2] != 2'b11)
            fail("blocked store/load pair did not issue when both lanes freed");
        tick();
        #1;
        if (|pipe_valid[3:2])
            fail("released store/load pair was not marked issued");

        // Do not skip a same-lane second memory operation to pair a younger
        // opposite-lane operation.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b1111;
        allocation_id = {IDW'(81), IDW'(80), IDW'(79)};
        allocation_slot = {4'd2, 4'd1, 4'd0};
        next_retire_id = IDW'(79);
        p0 = alu_packet(64'd79, 5'd1, 5'd0, 5'd5);
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd80, 5'd2, 5'd0, 5'd6);
        p1[I_MEM_READ] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p2 = alu_packet(64'd81, 5'd3, 5'd4, 5'd0);
        p2[I_INSTR +: 32] = 32'h0041_b023;
        p2[I_MEM_WRITE] = 1'b1;
        p2[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {p2, p1, p0};
        decode_uses_rs1 = 3'b111;
        decode_uses_rs2 = 3'b100;
        decode_valid = 3'b111;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[2] || pipe_valid[3] ||
            pipe_id[2*IDW +: IDW] != IDW'(79))
            fail("memory selector skipped same-lane second load");
        tick();
        #1;
        if (pipe_valid[3:2] != 2'b11 ||
            pipe_id[2*IDW +: IDW] != IDW'(80) ||
            pipe_id[3*IDW +: IDW] != IDW'(81))
            fail("second load/store pair did not issue after oldest load");

        // RV64A uses MEM1 even for a read-only LR and may be admitted beside
        // a younger MEM0 load.  Execution still holds the younger request
        // until the atomic reaches ordered retirement head.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(0), IDW'(83), IDW'(82)};
        allocation_slot = {4'd0, 4'd1, 4'd0};
        next_retire_id = IDW'(82);
        p0 = alu_packet(64'd82, 5'd1, 5'd0, 5'd5);
        p0[I_INSTR +: 32] = 32'h1000_302f;
        p0[I_MEM_READ] = 1'b1;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        p1 = alu_packet(64'd83, 5'd2, 5'd0, 5'd6);
        p1[I_MEM_READ] = 1'b1;
        p1[I_ALU_OP +: 5] = `RV64_ALU_OP_INVALID;
        decode_payload = {{IW{1'b0}}, p1, p0};
        decode_uses_rs1 = 3'b011;
        decode_valid = 3'b011;
        tick();
        clear_inputs();
        #1;
        if (pipe_valid[3:2] != 2'b11 ||
            pipe_id[3*IDW +: IDW] != IDW'(82) ||
            pipe_id[2*IDW +: IDW] != IDW'(83))
            fail("LR/load pair did not dual issue to MEM1/MEM0");

        // Zbb shares EX0's long-operation issue slot with RV64M.  It must not
        // be steered to the otherwise interchangeable EX1 base-ALU lane.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        allocation_id = {IDW'(0), IDW'(0), IDW'(90)};
        allocation_slot = {4'd0, 4'd0, 4'd0};
        next_retire_id = IDW'(90);
        p0 = alu_packet(64'd90, 5'd1, 5'd0, 5'd5);
        p0[I_ALU_EXT +: 3] = `RV64_ALU_EXT_ZBB;
        p0[I_ALU_OP +: 5] = `RV64_ALU_OP_ZBB_CPOP;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[0] || |pipe_valid[3:1] ||
            pipe_id[0*IDW +: IDW] != IDW'(90))
            fail("Zbb instruction was not fixed to EX0");

        // BP9 dispatches the branch with a provisional not-taken bit.  Its
        // synchronous response must inhibit that exact branch for one issue
        // cycle, patch the resident payload, and leave it eligible on the
        // following cycle with the final prediction.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        pipe_ready = 4'b0000;
        allocation_id = {IDW'(0), IDW'(0), IDW'(90)};
        allocation_slot = {4'd0, 4'd0, 4'd3};
        next_retire_id = IDW'(90);
        next_retire_slot = 4'd3;
        p0 = alu_packet(64'd90, 5'd0, 5'd0, 5'd0);
        p0[I_INSTR +: 32] = 32'h0000_0463;
        p0[I_IMM +: 64] = 64'd8;
        p0[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_BEQ;
        p0[I_BRANCH] = 1'b1;
        decode_payload = {{2*IW{1'b0}}, p0};
        decode_valid = 3'b001;
        tick();
        clear_inputs();
        pipe_ready = 4'b1111;
        prediction_update_valid = 1'b1;
        prediction_update_id = IDW'(90);
        prediction_update_slot = 4'd3;
        prediction_update_taken = 1'b1;
        #1;
        if (|pipe_valid)
            fail("branch issued before synchronous prediction update");
        tick();
        clear_inputs();
        #1;
        if (!pipe_valid[1] ||
            (pipe_id[IDW +: IDW] != IDW'(90)) ||
            !pipe_payload[IW + I_PREDICTED])
            fail("updated branch did not issue with final prediction");
        tick();
        clear_inputs();

        $display("PASS: dispatch window issue, fixed EX0 Zbb, dual ordered MEM roles, producer tags, selective recovery, and prediction update");
        $finish;
    end
endmodule
