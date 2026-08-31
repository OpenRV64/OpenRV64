`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module tb_dispatch_3p_banked;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer MW = `OPENRV64_DISPATCH_META_WIDTH;
    localparam integer SW = 3;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;

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

    wire [4*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr;
    wire [3:0] gpr_read_req;
    wire [3:0] gpr_read_ack;
    wire [3:0] gpr_read_valid;
    wire [4*`RV64_XLEN-1:0] gpr_read_data;

    reg allocation_ready;
    reg [3*IDW-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    wire [2:0] allocation_valid;
    wire [3*MW-1:0] allocation_meta;

    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SW-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IW-1:0] pipe_payload;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src1_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0]
        pipe_src1_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src2_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*IDW-1:0]
        pipe_src2_producer_id;

    reg [2:0] retire_valid;
    reg [2:0] retire_uses_rs1;
    reg [2:0] retire_uses_rs2;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr;
    reg [2:0] retire_reg_write;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr;
    reg [2:0] retire_hard;

    wire barrier_active;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;
    wire [31:0] write_busy;
    wire [2:0] queue_count;

    reg [2*`RV64_REG_ADDR_WIDTH-1:0] file_write_addr;
    reg [2*`RV64_XLEN-1:0] file_write_data;
    reg [1:0] file_write_req;
    wire [1:0] file_write_ack;
    wire [1:0] file_write_valid;

    openrv64_dispatch_3p_banked #(
        .QUEUE_DEPTH(6),
        .RETIRE_SLOT_WIDTH(SW),
        .COUNT_WIDTH(3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_frontend_i(squash),
        .decode_valid_i(decode_valid),
        .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .gpr_read_addr_o(gpr_read_addr),
        .gpr_read_req_o(gpr_read_req),
        .gpr_read_ack_i(gpr_read_ack),
        .gpr_read_valid_i(gpr_read_valid),
        .gpr_read_data_i(gpr_read_data),
        .allocation_ready_i(allocation_ready),
        .allocation_id_i(allocation_id),
        .allocation_slot_i(allocation_slot),
        .allocation_valid_o(allocation_valid),
        .allocation_meta_o(allocation_meta),
        .pipe_ready_i(pipe_ready),
        .pipe_valid_o(pipe_valid),
        .pipe_id_o(pipe_id),
        .pipe_slot_o(pipe_slot),
        .pipe_payload_o(pipe_payload),
        .pipe_src1_producer_valid_o(pipe_src1_producer_valid),
        .pipe_src1_producer_id_o(pipe_src1_producer_id),
        .pipe_src2_producer_valid_o(pipe_src2_producer_valid),
        .pipe_src2_producer_id_o(pipe_src2_producer_id),
        .retire_valid_i(retire_valid),
        .retire_uses_rs1_i(retire_uses_rs1),
        .retire_uses_rs2_i(retire_uses_rs2),
        .retire_rs1_addr_i(retire_rs1_addr),
        .retire_rs2_addr_i(retire_rs2_addr),
        .retire_reg_write_i(retire_reg_write),
        .retire_rd_addr_i(retire_rd_addr),
        .retire_hard_i(retire_hard),
        .barrier_active_o(barrier_active),
        .raw_hazard_o(raw_hazard),
        .waw_hazard_o(waw_hazard),
        .read_port_hazard_o(read_port_hazard),
        .write_busy_o(write_busy),
        .queue_count_o(queue_count)
    );

    cmn_reg_file #(
        .REG_WIDTH(`RV64_XLEN),
        .REG_COUNT(32),
        .READ_PORTS(4),
        .WRITE_PORTS(2),
        .READ_PORTS_PER_BANK(2),
        .BANK_SIZE(16),
        .NUM_BANKS(2)
    ) u_gpr (
        .clk(clk),
        .rst_n(rst_n),
        .rp_addr_i(gpr_read_addr),
        .rp_data_o(gpr_read_data),
        .rp_req_i(gpr_read_req),
        .rp_ack_o(gpr_read_ack),
        .rp_valid_o(gpr_read_valid),
        .wp_addr_i(file_write_addr),
        .wp_data_i(file_write_data),
        .wp_req_i(file_write_req),
        .wp_ack_o(file_write_ack),
        .wp_valid_o(file_write_valid),
        .quiescent_o()
    );

    always #5 clk = ~clk;

    function automatic [`RV64_XLEN-1:0] initial_value;
        input [`RV64_REG_ADDR_WIDTH-1:0] address;
        begin
            initial_value = 64'h1000_0000_0000_0000 | address;
        end
    endfunction

    function automatic integer valid_count;
        input [3:0] mask;
        integer bit_index;
        begin
            valid_count = 0;
            for (bit_index = 0; bit_index < 4;
                 bit_index = bit_index + 1)
                valid_count = valid_count + mask[bit_index];
        end
    endfunction

    function automatic [IW-1:0] alu_packet;
        input [63:0] trace_id;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[I_TRACE +: 64] = trace_id;
            packet[I_PC +: 64] = 64'h1000 + (trace_id << 2);
            packet[I_INSTR +: 32] = 32'h0000_0033;
            packet[I_RS1 +: `RV64_REG_ADDR_WIDTH] = rs1;
            packet[I_RS2 +: `RV64_REG_ADDR_WIDTH] = rs2;
            packet[I_RD +: `RV64_REG_ADDR_WIDTH] = rd;
            packet[I_ALU_EXT +: `RV64_ALU_EXT_WIDTH] =
                `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: `RV64_ALU_OP_WIDTH] = `RV64_ALU_OP_ADD;
            packet[I_REG_WRITE] = (rd != `RV64_REG_X0);
            alu_packet = packet;
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

    task automatic write_register;
        input [`RV64_REG_ADDR_WIDTH-1:0] address;
        input [`RV64_XLEN-1:0] data;
        integer wait_cycles;
        begin
            file_write_addr[0 +: `RV64_REG_ADDR_WIDTH] = address;
            file_write_data[0 +: `RV64_XLEN] = data;
            file_write_req[0] = 1'b1;
            wait_cycles = 0;
            while (!file_write_ack[0] && (wait_cycles < 8)) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!file_write_ack[0])
                fail("register-file preload timed out");
            file_write_req[0] = 1'b0;
            tick();
        end
    endtask

    task automatic enqueue1;
        input [IW-1:0] packet0;
        input uses1;
        input uses2;
        begin
            decode_payload = {{2*IW{1'b0}}, packet0};
            decode_uses_rs1 = {2'b00, uses1};
            decode_uses_rs2 = {2'b00, uses2};
            decode_valid = 3'b001;
            #1;
            if (!decode_ready[0])
                fail("dispatch did not accept one decode lane");
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
        end
    endtask

    task automatic enqueue2;
        input [IW-1:0] packet0;
        input [IW-1:0] packet1;
        input [1:0] uses1;
        input [1:0] uses2;
        begin
            decode_payload = {{IW{1'b0}}, packet1, packet0};
            decode_uses_rs1 = {1'b0, uses1};
            decode_uses_rs2 = {1'b0, uses2};
            decode_valid = 3'b011;
            #1;
            if (decode_ready[1:0] != 2'b11)
                fail("dispatch did not accept two decode lanes");
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
        end
    endtask

    task automatic enqueue3;
        input [IW-1:0] packet0;
        input [IW-1:0] packet1;
        input [IW-1:0] packet2;
        begin
            decode_payload = {packet2, packet1, packet0};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b111;
            #1;
            if (decode_ready != 3'b111)
                fail("dispatch did not accept three decode lanes");
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
        end
    endtask

    reg [IW-1:0] p0;
    reg [IW-1:0] p1;
    reg [IW-1:0] p2;
    integer address;
    integer cycles;
    integer response_count;
    integer response_cycles;
    integer response_peak;
    integer responses_this_cycle;
    reg [`RV64_XLEN-1:0] held_rs1;
    reg [`RV64_XLEN-1:0] held_rs2;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        allocation_ready = 1'b1;
        allocation_id = {IDW'(2), IDW'(1), IDW'(0)};
        allocation_slot = {3'd2, 3'd1, 3'd0};
        pipe_ready = {`OPENRV64_EXEC_PIPE_COUNT{1'b1}};
        retire_valid = 3'b000;
        retire_uses_rs1 = 3'b000;
        retire_uses_rs2 = 3'b000;
        retire_rs1_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        retire_rs2_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        retire_reg_write = 3'b000;
        retire_rd_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        retire_hard = 3'b000;
        file_write_addr = {2*`RV64_REG_ADDR_WIDTH{1'b0}};
        file_write_data = {2*`RV64_XLEN{1'b0}};
        file_write_req = 2'b00;

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        for (address = 1; address <= 18; address = address + 1)
            write_register(address[`RV64_REG_ADDR_WIDTH-1:0],
                           initial_value(
                               address[`RV64_REG_ADDR_WIDTH-1:0]));

        // Decode guarantees that an unused source is encoded as x0.  A packet
        // with no sources therefore issues without consuming a read port.
        p0 = alu_packet(64'd1, `RV64_REG_X0, `RV64_REG_X0,
                        `RV64_REG_X0);
        enqueue1(p0, 1'b0, 1'b0);
        #1;
        if ((gpr_read_req != 4'b0000) ||
            (allocation_valid != 3'b001))
            fail("source-free packet did not issue without GPR reads");
        tick();

        // An immediate/unary-style packet reads rs1 and carries x0 in the
        // unused rs2 field.  Only the real source may request the file.
        p0 = alu_packet(64'd2, 5'd1, `RV64_REG_X0, `RV64_REG_X0);
        enqueue1(p0, 1'b1, 1'b0);
        #1;
        if (gpr_read_addr[1*5 +: 5] != `RV64_REG_X0)
            fail("unused rs2 did not retain the decode x0 contract");
        if (gpr_read_req[1] != 1'b0)
            fail("unused rs2 consumed a logical read port");
        cycles = 0;
        while ((allocation_valid == 3'b000) && (cycles < 8)) begin
            tick();
            cycles = cycles + 1;
        end
        if (allocation_valid != 3'b001)
            fail("single-source packet never issued");
        if (pipe_payload[0*IW + I_RS1_DATA +: 64] != initial_value(5'd1))
            fail("single-source packet received the wrong value");
        tick();

        // Two reads per bank fit in one address phase.  Both independent
        // instructions issue together after the shared data phase.
        p0 = alu_packet(64'd10, 5'd1, 5'd2, `RV64_REG_X0);
        p1 = alu_packet(64'd11, 5'd3, 5'd4, `RV64_REG_X0);
        enqueue2(p0, p1, 2'b11, 2'b11);
        response_count = 0;
        response_cycles = 0;
        response_peak = 0;
        cycles = 0;
        while ((allocation_valid == 3'b000) && (cycles < 12)) begin
            tick();
            responses_this_cycle = valid_count(gpr_read_valid);
            response_count = response_count + responses_this_cycle;
            if (responses_this_cycle != 0)
                response_cycles = response_cycles + 1;
            if (responses_this_cycle > response_peak)
                response_peak = responses_this_cycle;
            cycles = cycles + 1;
        end
        if ((response_count != 4) || (response_cycles != 1) ||
            (response_peak != 4))
            fail("2R banks did not complete four distributed reads together");
        if ((allocation_valid != 3'b011) ||
            (pipe_valid[1:0] != 2'b11))
            fail("two banked-read candidates did not issue together");
        if ((pipe_payload[0*IW + I_RS1_DATA +: 64] != initial_value(5'd1)) ||
            (pipe_payload[0*IW + I_RS2_DATA +: 64] != initial_value(5'd2)) ||
            (pipe_payload[1*IW + I_RS1_DATA +: 64] != initial_value(5'd3)) ||
            (pipe_payload[1*IW + I_RS2_DATA +: 64] != initial_value(5'd4)))
            fail("two-wide issue captured incorrect banked operands");
        tick();

        // Four requests to one bank consume two slots per cycle.  No candidate
        // is allowed to issue with only a partial operand set.
        p0 = alu_packet(64'd20, 5'd5, 5'd7, `RV64_REG_X0);
        p1 = alu_packet(64'd21, 5'd9, 5'd11, `RV64_REG_X0);
        enqueue2(p0, p1, 2'b11, 2'b11);
        response_count = 0;
        response_cycles = 0;
        response_peak = 0;
        cycles = 0;
        while ((allocation_valid == 3'b000) && (cycles < 16)) begin
            tick();
            responses_this_cycle = valid_count(gpr_read_valid);
            response_count = response_count + responses_this_cycle;
            if (responses_this_cycle != 0)
                response_cycles = response_cycles + 1;
            if (responses_this_cycle > response_peak)
                response_peak = responses_this_cycle;
            if ((response_count < 4) && (allocation_valid != 3'b000))
                fail("same-bank group issued with partial operands");
            cycles = cycles + 1;
        end
        if ((response_count != 4) || (response_cycles != 2) ||
            (response_peak != 2))
            fail("same-bank reads did not use two slots per cycle");
        if (allocation_valid != 3'b011)
            fail("same-bank group never issued after all responses");
        tick();

        // Once captured, operand data remains stable while execution applies
        // backpressure.  Later writes to the physical file cannot change it.
        pipe_ready = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        held_rs1 = initial_value(5'd12);
        held_rs2 = initial_value(5'd13);
        p0 = alu_packet(64'd30, 5'd12, 5'd13, `RV64_REG_X0);
        enqueue1(p0, 1'b1, 1'b1);
        cycles = 0;
        while ((dut.read_done_q[1:0] != 2'b11) && (cycles < 12)) begin
            tick();
            cycles = cycles + 1;
        end
        if (dut.read_done_q[1:0] != 2'b11)
            fail("dispatch did not retain completed operand reads");
        if (allocation_valid != 3'b000)
            fail("candidate issued through execution backpressure");
        write_register(5'd12, 64'hdead_dead_dead_0012);
        write_register(5'd13, 64'hdead_dead_dead_0013);
        pipe_ready = {`OPENRV64_EXEC_PIPE_COUNT{1'b1}};
        #1;
        if (allocation_valid != 3'b001)
            fail("held candidate did not issue when execution reopened");
        if ((pipe_payload[0*IW + I_RS1_DATA +: 64] != held_rs1) ||
            (pipe_payload[0*IW + I_RS2_DATA +: 64] != held_rs2))
            fail("held operand data changed after register-file writes");
        tick();

        // An outstanding architectural writer suppresses the read request.
        // After retirement releases ownership, the consumer reads the value
        // written by the retiring producer.
        p0 = alu_packet(64'd40, `RV64_REG_X0, `RV64_REG_X0, 5'd14);
        enqueue1(p0, 1'b0, 1'b0);
        #1;
        if (allocation_valid != 3'b001)
            fail("producer did not issue");
        tick();
        if (!write_busy[14])
            fail("producer did not claim its destination");
        p0 = alu_packet(64'd41, 5'd14, `RV64_REG_X0,
                        `RV64_REG_X0);
        enqueue1(p0, 1'b1, 1'b0);
        #1;
        if (gpr_read_req[0] || (allocation_valid != 3'b000))
            fail("consumer read an outstanding destination");
        write_register(5'd14, 64'hcafe_f00d_0000_0014);
        retire_valid = 3'b001;
        retire_reg_write = 3'b001;
        retire_rd_addr[0 +: `RV64_REG_ADDR_WIDTH] = 5'd14;
        tick();
        retire_valid = 3'b000;
        retire_reg_write = 3'b000;
        retire_rd_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        cycles = 0;
        while ((allocation_valid == 3'b000) && (cycles < 10)) begin
            tick();
            cycles = cycles + 1;
        end
        if (allocation_valid != 3'b001)
            fail("consumer did not resume after producer retirement");
        if (pipe_payload[0*IW + I_RS1_DATA +: 64] !=
            64'hcafe_f00d_0000_0014)
            fail("consumer did not receive the retired producer value");
        tick();

        // Flush discards queued candidates and a partial two-slot response
        // from four reads oversubscribing one bank.
        p0 = alu_packet(64'd50, 5'd15, 5'd17, `RV64_REG_X0);
        p1 = alu_packet(64'd51, 5'd19, 5'd21, `RV64_REG_X0);
        enqueue2(p0, p1, 2'b11, 2'b11);
        tick();
        if ((valid_count(gpr_read_valid) != 2) ||
            (allocation_valid != 3'b000))
            fail("flush test did not establish a partial response");
        flush = 1'b1;
        tick();
        flush = 1'b0;
        #1;
        if ((queue_count != 0) || (dut.read_done_q != 4'b0000) ||
            (allocation_valid != 3'b000))
            fail("flush retained queued or partial read state");
        p0 = alu_packet(64'd52, 5'd16, 5'd18, `RV64_REG_X0);
        enqueue1(p0, 1'b1, 1'b1);
        cycles = 0;
        while ((allocation_valid == 3'b000) && (cycles < 12)) begin
            tick();
            cycles = cycles + 1;
        end
        if (allocation_valid != 3'b001)
            fail("post-flush candidate never issued");
        if ((pipe_payload[0*IW + I_RS1_DATA +: 64] !=
             initial_value(5'd16)) ||
            (pipe_payload[0*IW + I_RS2_DATA +: 64] !=
             initial_value(5'd18)))
            fail("post-flush candidate consumed stale operands");
        tick();

        // Decode remains three-wide, but the banked issue boundary is two-wide.
        allocation_ready = 1'b0;
        p0 = alu_packet(64'd60, `RV64_REG_X0, `RV64_REG_X0,
                        `RV64_REG_X0);
        p1 = alu_packet(64'd61, `RV64_REG_X0, `RV64_REG_X0,
                        `RV64_REG_X0);
        p2 = alu_packet(64'd62, `RV64_REG_X0, `RV64_REG_X0,
                        `RV64_REG_X0);
        enqueue3(p0, p1, p2);
        if (queue_count != 3)
            fail("three-wide decode group was not queued");
        allocation_ready = 1'b1;
        #1;
        if ((allocation_valid != 3'b011) ||
            (pipe_valid[1:0] != 2'b11))
            fail("banked dispatch did not cap the first issue group at two");
        tick();
        if ((queue_count != 1) || (allocation_valid != 3'b001))
            fail("third decode lane did not remain for the next issue cycle");
        tick();
        if (queue_count != 0)
            fail("final queued lane did not drain");

        if (|{barrier_active, raw_hazard, waw_hazard, read_port_hazard,
              pipe_src1_producer_valid, pipe_src1_producer_id,
              pipe_src2_producer_valid, pipe_src2_producer_id})
            fail("unexpected conservative-dispatch diagnostic remained set");

        $display("PASS: banked 3p dispatch held reads, bank arbitration, busy operands, flush, x0, and two-wide issue");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_dispatch_3p_banked: timeout");
    end

endmodule
