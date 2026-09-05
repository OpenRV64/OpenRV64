`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module tb_dispatch_load_conflict_record;
    localparam integer DEPTH = 8;
    localparam integer SW = 4;
    localparam integer CW = 4;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer OW = `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH;
    localparam integer MW = `OPENRV64_DISPATCH_META_WIDTH;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer PW = `OPENRV64_PHYS_REG_ADDR_WIDTH;

    localparam integer I_REG_WRITE = 17;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;
    localparam integer I_MEM_READ = 16;
    localparam integer I_MEM_WRITE = 15;

    localparam [63:0] CONFLICT_PC = 64'h0000_0000_4000_1000;
    // Offset bit 7 changes hash signature bit 5 without changing the
    // five-bit direct-mapped index.
    localparam [63:0] SAME_INDEX_OTHER_PC =
        64'h0000_0000_4000_1080;

    reg clk;
    reg rst_n;
    reg flush;
    reg load_conflict_train_valid;
    reg [63:0] load_conflict_train_pc;
    reg [2:0] decode_valid;
    wire [2:0] decode_ready;
    reg [3*IW-1:0] decode_payload;
    reg [2:0] decode_uses_rs1;
    reg [2:0] decode_uses_rs2;
    reg [6*PW-1:0] rename_source_phys;
    reg [5:0] rename_source_ready;
    reg [5:0] rename_source_producer_valid;
    reg [6*IDW-1:0] rename_source_producer_id;
    reg [3*PW-1:0] rename_destination_phys;
    reg [3*IDW-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    wire [2:0] allocation_valid;
    reg [3:0] pipe_ready;
    wire [3:0] pipe_valid;
    wire [4*IDW-1:0] pipe_id;
    reg [2:0] completion_valid;
    reg [3*IDW-1:0] completion_id;
    reg [3*OW-1:0] completion_payload;
    wire [CW-1:0] queue_count;

    openrv64_dispatch_window_3p #(
        .PHYSICAL_RENAME(1),
        .PHYS_REG_ADDR_WIDTH(PW),
        .ENABLE_SPECULATION(1),
        .ENABLE_LOAD_CONFLICT_RECORD(1),
        .DEPTH(DEPTH),
        .RETIRE_SLOT_WIDTH(SW),
        .COUNT_WIDTH(CW)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_frontend_i(1'b0),
        .squash_inclusive_i(1'b0),
        .squash_id_i({IDW{1'b0}}),
        .translation_bypass_i(1'b0),
        .load_conflict_train_valid_i(load_conflict_train_valid),
        .load_conflict_train_pc_i(load_conflict_train_pc),
        .decode_valid_i(decode_valid),
        .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .prediction_update_valid_i(1'b0),
        .prediction_update_id_i({IDW{1'b0}}),
        .prediction_update_slot_i({SW{1'b0}}),
        .prediction_update_taken_i(1'b0),
        .gpr_read_addr_o(),
        .gpr_read_data_i({6*`RV64_XLEN{1'b0}}),
        .rename_source_phys_i(rename_source_phys),
        .rename_source_ready_i(rename_source_ready),
        .rename_source_producer_valid_i(rename_source_producer_valid),
        .rename_source_producer_id_i(rename_source_producer_id),
        .rename_destination_phys_i(rename_destination_phys),
        .physical_forward_valid_i(3'b000),
        .physical_writeback_valid_i(3'b000),
        .physical_writeback_tag_i({3*PW{1'b0}}),
        .physical_writeback_data_i({3*`RV64_XLEN{1'b0}}),
        .allocation_ready_i(1'b1),
        .allocation_id_i(allocation_id),
        .allocation_slot_i(allocation_slot),
        .allocation_valid_o(allocation_valid),
        .allocation_meta_o(),
        .pipe_ready_i(pipe_ready),
        .chain_producer_valid_i(2'b00),
        .chain_producer_id_i({2*IDW{1'b0}}),
        .chain_producer_phys_i({2*PW{1'b0}}),
        .pipe_candidate_valid_o(),
        .pipe_squashed_o(),
        .pipe_age_rank_o(),
        .pipe_valid_o(pipe_valid),
        .pipe_id_o(pipe_id),
        .pipe_slot_o(),
        .pipe_payload_o(),
        .pipe_uses_rs1_o(),
        .pipe_uses_rs2_o(),
        .pipe_src1_producer_valid_o(),
        .pipe_src1_producer_id_o(),
        .pipe_src2_producer_valid_o(),
        .pipe_src2_producer_id_o(),
        .pipe_src1_phys_o(),
        .pipe_src2_phys_o(),
        .pipe_destination_phys_o(),
        .completion_valid_i(completion_valid),
        .completion_id_i(completion_id),
        .completion_payload_i(completion_payload),
        .conditional_resolve_valid_i(1'b0),
        .conditional_resolve_id_i({IDW{1'b0}}),
        .conditional_resolve_slot_i({SW{1'b0}}),
        .retire_valid_i(3'b000),
        .retire_id_i({3*IDW{1'b0}}),
        .retire_slot_i({3*SW{1'b0}}),
        .retire_hard_i(3'b000),
        .next_retire_id_i({IDW{1'b0}}),
        .next_retire_slot_i({SW{1'b0}}),
        .barrier_active_o(),
        .raw_hazard_o(),
        .waw_hazard_o(),
        .read_port_hazard_o(),
        .write_busy_o(),
        .queue_count_o(queue_count)
    );

    always #5 clk = ~clk;

    function automatic [IW-1:0] memory_packet;
        input [63:0] trace_id;
        input [63:0] pc;
        input is_store;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[I_TRACE +: 64] = trace_id;
            packet[I_PC +: 64] = pc;
            packet[I_RS1 +: 5] = 5'd1;
            packet[I_IMM +: 64] = 64'd0;
            packet[I_ALU_EXT +: `RV64_ALU_EXT_WIDTH] =
                `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: `RV64_ALU_OP_WIDTH] =
                `RV64_ALU_OP_INVALID;
            if (is_store) begin
                packet[I_INSTR +: 32] = 32'h0020_b023;
                packet[I_RS2 +: 5] = 5'd2;
                packet[I_MEM_WRITE] = 1'b1;
            end else begin
                packet[I_INSTR +: 32] = 32'h0000_b183;
                packet[I_RD +: 5] = 5'd3;
                packet[I_REG_WRITE] = 1'b1;
                packet[I_MEM_READ] = 1'b1;
            end
            memory_packet = packet;
        end
    endfunction

    function automatic [OW-1:0] safe_completion;
        input [63:0] data;
        reg [OW-1:0] packet;
        begin
            packet = {OW{1'b0}};
            packet[`OPENRV64_COMPLETE_REG_WRITE_BIT] = 1'b1;
            packet[`OPENRV64_COMPLETE_RD_LSB +: 5] = 5'd1;
            packet[`OPENRV64_COMPLETE_DATA_LSB +: 64] = data;
            safe_completion = packet;
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

    task automatic clear_decode;
        begin
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
            rename_source_ready = 6'b111111;
            rename_source_producer_valid = 6'b000000;
            rename_source_producer_id = {6*IDW{1'b0}};
        end
    endtask

    task automatic admit_blocked_store_and_load;
        input [IDW-1:0] store_id;
        input [IDW-1:0] load_id;
        input [63:0] load_pc;
        begin
            allocation_id = {{IDW{1'b0}}, load_id, store_id};
            allocation_slot = {4'd0, 4'd1, 4'd0};
            decode_payload = {
                {IW{1'b0}},
                memory_packet(load_id, load_pc, 1'b0),
                memory_packet(store_id, load_pc - 64'd4, 1'b1)
            };
            decode_valid = 3'b011;
            decode_uses_rs1 = 3'b011;
            decode_uses_rs2 = 3'b001;
            // The older store waits for producer 90 on rs1.  Its data and the
            // younger load base are already available.
            rename_source_ready = 6'b111110;
            rename_source_producer_valid = 6'b000001;
            rename_source_producer_id = {6*IDW{1'b0}};
            rename_source_producer_id[0 +: IDW] = IDW'(90);
            #1;
            if (decode_ready[1:0] != 2'b11)
                fail("physical issue window rejected store/load pair");
            tick();
            clear_decode();
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        load_conflict_train_valid = 1'b0;
        load_conflict_train_pc = 64'd0;
        rename_source_phys = {6*PW{1'b0}};
        rename_destination_phys = {3*PW{1'b0}};
        allocation_id = {3*IDW{1'b0}};
        allocation_slot = {3*SW{1'b0}};
        pipe_ready = 4'b1111;
        completion_valid = 3'b000;
        completion_id = {3*IDW{1'b0}};
        completion_payload = {3*OW{1'b0}};
        clear_decode();

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // Cold: the younger load may speculate around an unresolved ordinary
        // store because this load PC has not collided before.
        admit_blocked_store_and_load(IDW'(10), IDW'(11), CONFLICT_PC);
        if (!pipe_valid[`OPENRV64_EXEC_PIPE_MEM0] ||
            (pipe_id[`OPENRV64_EXEC_PIPE_MEM0*IDW +: IDW] != IDW'(11)) ||
            pipe_valid[`OPENRV64_EXEC_PIPE_MEM1])
            fail("cold load did not speculate around unresolved store");
        tick();
        if (queue_count != CW'(1))
            fail("cold load issue did not leave only blocked store resident");

        // Model the backend's observed store/load collision and simultaneous
        // recovery.  The record is intentionally not flushed with the window.
        flush = 1'b1;
        load_conflict_train_valid = 1'b1;
        load_conflict_train_pc = CONFLICT_PC;
        tick();
        flush = 1'b0;
        load_conflict_train_valid = 1'b0;
        #1;
        if (queue_count != CW'(0))
            fail("flush did not clear physical issue window");
        if (dut.perf_load_conflict_record_train_q != 64'd1)
            fail("collision did not train load conflict record");

        // Learned: the same load PC must remain resident behind a new older
        // unresolved store.  No address or byte comparison is attempted here.
        admit_blocked_store_and_load(IDW'(20), IDW'(21), CONFLICT_PC);
        if (pipe_valid[`OPENRV64_EXEC_PIPE_MEM0] ||
            pipe_valid[`OPENRV64_EXEC_PIPE_MEM1])
            fail("recorded load crossed unresolved older store");
        if ((queue_count != CW'(2)) ||
            (dut.trace_load_conflict_record_hit_count != CW'(1)) ||
            (dut.trace_load_conflict_record_block_count != CW'(1)))
            fail("record hit/block attribution did not identify learned load");

        // Waking the older store lets it issue now; the recorded load follows
        // on the next scheduler cycle after the store leaves this window.
        completion_valid = 3'b001;
        completion_id[0 +: IDW] = IDW'(90);
        completion_payload[0 +: OW] = safe_completion(64'h8000_2000);
        #1;
        if (!pipe_valid[`OPENRV64_EXEC_PIPE_MEM1] ||
            (pipe_id[`OPENRV64_EXEC_PIPE_MEM1*IDW +: IDW] != IDW'(20)) ||
            pipe_valid[`OPENRV64_EXEC_PIPE_MEM0])
            fail("woken store did not issue ahead of recorded load");
        tick();
        completion_valid = 3'b000;
        completion_id = {3*IDW{1'b0}};
        completion_payload = {3*OW{1'b0}};
        #1;
        if (!pipe_valid[`OPENRV64_EXEC_PIPE_MEM0] ||
            (pipe_id[`OPENRV64_EXEC_PIPE_MEM0*IDW +: IDW] != IDW'(21)))
            fail("recorded load did not issue after older store left window");
        tick();

        // A different signature at the same direct-mapped index remains a
        // miss and therefore keeps the default speculative policy.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        admit_blocked_store_and_load(
            IDW'(30), IDW'(31), SAME_INDEX_OTHER_PC);
        if (!pipe_valid[`OPENRV64_EXEC_PIPE_MEM0] ||
            (pipe_id[`OPENRV64_EXEC_PIPE_MEM0*IDW +: IDW] != IDW'(31)) ||
            (dut.trace_load_conflict_record_hit_count != CW'(0)))
            fail("same-index different-signature load falsely hit record");

        $display("PASS: learned load conflict record blocks only matching load sites");
        $finish;
    end
endmodule
