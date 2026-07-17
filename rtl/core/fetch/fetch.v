`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"
`include "core/arith/prefix-addsub.v"

module openrv64_fetch (
    input  wire                             clk,
    input  wire                             rst_n,
    // flush_i invalidates resident lines (reset-like/fence/context change).
    // redirect_i only discards the unread stream so a later PC lookup can
    // replay an already resident line.
    input  wire                             flush_i,
    input  wire                             redirect_i,
    input  wire                             redirect_replay_i,
    input  wire [`RV64_XLEN-1:0]            redirect_pc_i,
    output wire                             redirect_replay_o,

    output wire                             pc_ready_o,
    input  wire                             pc_valid_i,
    input  wire [`RV64_XLEN-1:0]            pc_i,

    output wire                             mem_valid_o,
    output wire                             mem_next_valid_o,
    input  wire                             mem_ready_i,
    output wire                             mem_write_o,
    output wire [`RV64_XLEN-1:0]            mem_addr_o,
    output wire [`RV64_XLEN-1:0]            mem_exec_addr_o,
    output wire [`RV64_XLEN-1:0]            mem_wdata_o,
    output wire [7:0]                       mem_wstrb_o,
    input  wire [`RV64_XLEN-1:0]            mem_rdata_i,
    input  wire                             mem_fault_i,
    input  wire                             mem_page_fault_i,

    output wire                             decode_valid_o,
    input  wire                             decode_ready_i,
    output wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    output wire [`RV64_XLEN-1:0]            decode_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0]     decode_instr_o,
    output wire                             decode_fault_o,
    output wire                             decode_page_fault_o,
    input  wire [63:0]                      trace_id_i,
    output wire [63:0]                      trace_id_o
);

    localparam integer BUFFER_COUNT = 8;
    localparam integer BUFFER_INDEX_WIDTH = 3;

    // Eight 8-byte line buffers provide a 16-instruction skid window.  They
    // are organized as two sets (line-address bit 3) with four ways each, so
    // lookup needs four wide tag comparisons rather than an eight-way CAM.
    // Line contents and tags remain resident after consumption;
    // buffer_count_q is only the unread-stream state.  A replay still gets
    // fresh dynamic trace IDs.
    reg [`RV64_INSTR_WIDTH-1:0] buffer_instr0_q [0:BUFFER_COUNT-1];
    reg [`RV64_INSTR_WIDTH-1:0] buffer_instr1_q [0:BUFFER_COUNT-1];
    reg [`RV64_XLEN-1:0]        buffer_target0_q [0:BUFFER_COUNT-1];
    reg [`RV64_XLEN-1:0]        buffer_target1_q [0:BUFFER_COUNT-1];
    reg                         buffer_target_valid0_q [0:BUFFER_COUNT-1];
    reg                         buffer_target_valid1_q [0:BUFFER_COUNT-1];
    reg                         buffer_target_conditional0_q [0:BUFFER_COUNT-1];
    reg                         buffer_target_conditional1_q [0:BUFFER_COUNT-1];
    reg [`RV64_XLEN-1:4]        buffer_line_tag_q [0:BUFFER_COUNT-1];
    reg [63:0]                  buffer_trace0_q [0:BUFFER_COUNT-1];
    reg [63:0]                  buffer_trace1_q [0:BUFFER_COUNT-1];
    reg                         buffer_fault_q [0:BUFFER_COUNT-1];
    reg                         buffer_page_fault_q [0:BUFFER_COUNT-1];
    reg                         buffer_resident_q [0:BUFFER_COUNT-1];
    reg [1:0]                   buffer_count_q [0:BUFFER_COUNT-1];

    reg [BUFFER_INDEX_WIDTH-1:0] read_bank_q;
    reg read_slot_q;
    reg [BUFFER_INDEX_WIDTH-1:0] write_bank_q;

    reg                         req_active_q;
    reg [BUFFER_INDEX_WIDTH-1:0] req_bank_q;
    reg [`RV64_XLEN-1:0]        req_pc_q;
    reg [`RV64_XLEN-1:0]        req_addr_q;
    reg [63:0]                  req_trace_id_q;

    // Direct-control predecode is deliberately one cycle behind line fill.
    // It is not on the memory response path and never blocks a cold decode;
    // a cold first encounter falls back to the normal decoder in the core.
    reg                         predecode_pending_q;
    reg [BUFFER_INDEX_WIDTH-1:0] predecode_bank_q;

    function automatic direct_control_valid;
        input [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            direct_control_valid = 1'b0;
            case (`RV64_OPCODE(instr))
                `RV64_OPCODE_JAL: begin
                    direct_control_valid = 1'b1;
                end
                `RV64_OPCODE_BRANCH: begin
                    case (`RV64_FUNCT3(instr))
                        `RV64_FUNCT3_BEQ,
                        `RV64_FUNCT3_BNE,
                        `RV64_FUNCT3_BLT,
                        `RV64_FUNCT3_BGE,
                        `RV64_FUNCT3_BLTU,
                        `RV64_FUNCT3_BGEU:
                            direct_control_valid = 1'b1;
                        default: begin
                        end
                    endcase
                end
                default: begin
                end
            endcase
        end
    endfunction

    wire [`RV64_INSTR_WIDTH-1:0] predecode_instr0 =
        buffer_instr0_q[predecode_bank_q];
    wire [`RV64_INSTR_WIDTH-1:0] predecode_instr1 =
        buffer_instr1_q[predecode_bank_q];
    wire [`RV64_XLEN-1:0] predecode_pc0 = {
        buffer_line_tag_q[predecode_bank_q], predecode_bank_q[0], 3'b000
    };
    wire [`RV64_XLEN-1:0] predecode_pc1 = {
        buffer_line_tag_q[predecode_bank_q], predecode_bank_q[0], 1'b1, 2'b00
    };
    wire predecode_valid0 = direct_control_valid(predecode_instr0);
    wire predecode_valid1 = direct_control_valid(predecode_instr1);
    wire predecode_conditional0 =
        (`RV64_OPCODE(predecode_instr0) == `RV64_OPCODE_BRANCH);
    wire predecode_conditional1 =
        (`RV64_OPCODE(predecode_instr1) == `RV64_OPCODE_BRANCH);
    wire [`RV64_XLEN-1:0] predecode_imm0 =
        (`RV64_OPCODE(predecode_instr0) == `RV64_OPCODE_JAL) ?
        `RV64_IMM_J(predecode_instr0) : `RV64_IMM_B(predecode_instr0);
    wire [`RV64_XLEN-1:0] predecode_imm1 =
        (`RV64_OPCODE(predecode_instr1) == `RV64_OPCODE_JAL) ?
        `RV64_IMM_J(predecode_instr1) : `RV64_IMM_B(predecode_instr1);
    wire [`RV64_XLEN-1:0] predecode_target0;
    wire [`RV64_XLEN-1:0] predecode_target1;

    // Separate target adders keep both slots out of a shared-input mux.  This
    // work happens after fill and is stored for every resident replay.
    openrv64_prefix_addsub u_predecode_target0 (
        .a_i(predecode_pc0),
        .b_i(predecode_imm0),
        .sub_i(1'b0),
        .result_o(predecode_target0)
    );

    openrv64_prefix_addsub u_predecode_target1 (
        .a_i(predecode_pc1),
        .b_i(predecode_imm1),
        .sub_i(1'b0),
        .result_o(predecode_target1)
    );

    reg                         lookup_hit_r;
    reg [BUFFER_INDEX_WIDTH-1:0] lookup_bank_r;

    wire [`RV64_XLEN-1:0] lookup_pc = redirect_replay_i ?
        redirect_pc_i : pc_i;
    wire [`RV64_XLEN-1:0] pc_line_addr =
        {pc_i[`RV64_XLEN-1:3], 3'b000};

    // Bank bit zero is the set index.  The upper two bank bits select one of
    // four ways, keeping sequential lines in circular-FIFO order because
    // consecutive line addresses alternate sets.
    wire [BUFFER_INDEX_WIDTH-1:0] lookup_bank0 = {2'd0, lookup_pc[3]};
    wire [BUFFER_INDEX_WIDTH-1:0] lookup_bank1 = {2'd1, lookup_pc[3]};
    wire [BUFFER_INDEX_WIDTH-1:0] lookup_bank2 = {2'd2, lookup_pc[3]};
    wire [BUFFER_INDEX_WIDTH-1:0] lookup_bank3 = {2'd3, lookup_pc[3]};
    wire lookup_hit0 = buffer_resident_q[lookup_bank0] &&
                       (buffer_line_tag_q[lookup_bank0] ==
                        lookup_pc[`RV64_XLEN-1:4]);
    wire lookup_hit1 = buffer_resident_q[lookup_bank1] &&
                       (buffer_line_tag_q[lookup_bank1] ==
                        lookup_pc[`RV64_XLEN-1:4]);
    wire lookup_hit2 = buffer_resident_q[lookup_bank2] &&
                       (buffer_line_tag_q[lookup_bank2] ==
                        lookup_pc[`RV64_XLEN-1:4]);
    wire lookup_hit3 = buffer_resident_q[lookup_bank3] &&
                       (buffer_line_tag_q[lookup_bank3] ==
                        lookup_pc[`RV64_XLEN-1:4]);
    wire [BUFFER_COUNT-1:0] queue_valid = {
        (buffer_count_q[7] != 2'd0),
        (buffer_count_q[6] != 2'd0),
        (buffer_count_q[5] != 2'd0),
        (buffer_count_q[4] != 2'd0),
        (buffer_count_q[3] != 2'd0),
        (buffer_count_q[2] != 2'd0),
        (buffer_count_q[1] != 2'd0),
        (buffer_count_q[0] != 2'd0)
    };
    wire queue_empty = ~|queue_valid;

    always @* begin
        lookup_hit_r = 1'b1;
        if (lookup_hit0) begin
            lookup_bank_r = lookup_bank0;
        end else if (lookup_hit1) begin
            lookup_bank_r = lookup_bank1;
        end else if (lookup_hit2) begin
            lookup_bank_r = lookup_bank2;
        end else if (lookup_hit3) begin
            lookup_bank_r = lookup_bank3;
        end else begin
            lookup_hit_r = 1'b0;
            lookup_bank_r = {BUFFER_INDEX_WIDTH{1'b0}};
        end
    end

    wire buffered_decode_valid = !redirect_i &&
                                 (buffer_count_q[read_bank_q] != 2'd0);
    wire buffered_decode_fire = buffered_decode_valid && decode_ready_i;
    wire read_bank_will_empty = buffered_decode_fire &&
                                (buffer_count_q[read_bank_q] == 2'd1);

    // A completed request advances the write side around the eight-bank ring.
    // Permit the next PC to be accepted on that same edge when the next bank
    // is empty (or is consuming its final slot on this edge).
    wire [BUFFER_INDEX_WIDTH-1:0] req_successor_bank =
        req_bank_q + {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1};
    wire [BUFFER_INDEX_WIDTH-1:0] next_req_bank =
        req_active_q ? req_successor_bank : write_bank_q;
    wire stream_empty = queue_empty && !req_active_q;
    wire [BUFFER_INDEX_WIDTH-1:0] stream_start_bank =
        {write_bank_q[BUFFER_INDEX_WIDTH-1:1], pc_i[3]};
    wire [BUFFER_INDEX_WIDTH-1:0] miss_bank =
        stream_empty ? stream_start_bank : next_req_bank;
    wire miss_bank_empty =
        (buffer_count_q[miss_bank] == 2'd0) ||
        (read_bank_will_empty && (read_bank_q == miss_bank));
    wire req_complete = req_active_q && mem_ready_i;

    // A resident hit can start a new stream at any bank when no request or
    // unread line precedes it.  Once a stream is active, hits must occur at
    // the FIFO tail; a resident line elsewhere is safely treated as a miss
    // and copied into the tail bank by memory.
    wire lookup_starts_stream = lookup_hit_r && queue_empty &&
                                !req_active_q;
    wire lookup_hits_tail = lookup_hit_r &&
                            (lookup_bank_r == next_req_bank) &&
                            miss_bank_empty &&
                            (!req_active_q || req_complete);
    wire lookup_reusable = lookup_starts_stream || lookup_hits_tail;
    wire request_can_start = miss_bank_empty &&
                             (!req_active_q || req_complete);

    assign pc_ready_o = !flush_i && !redirect_i &&
                        (lookup_reusable || request_can_start);

    wire pc_accept = pc_valid_i && pc_ready_o;
    wire pc_accept_hit = pc_accept && lookup_reusable;
    wire pc_accept_miss = pc_accept && !lookup_reusable;
    wire redirect_replay_valid = redirect_i && redirect_replay_i &&
                                 lookup_hit_r;
    wire stream_replay_valid = pc_accept_hit && lookup_starts_stream;
    wire replay_valid = redirect_replay_valid || stream_replay_valid;
    wire [`RV64_XLEN-1:0] replay_pc = redirect_replay_valid ?
        redirect_pc_i : pc_i;
    wire replay_slot = replay_pc[2];
    wire redirect_replay_fire = redirect_replay_valid && decode_ready_i;
    wire stream_replay_fire = stream_replay_valid && decode_ready_i;

    assign redirect_replay_o = redirect_replay_fire;

    // Only a memory miss accepted on the current fetch completion edge may
    // use the core-bus successor sideband.  A resident hit must not launch a
    // ghost external request.
    assign mem_next_valid_o = req_complete && pc_accept_miss;

    assign mem_valid_o = req_active_q;
    assign mem_write_o = 1'b0;
    assign mem_addr_o = req_addr_q;
    assign mem_exec_addr_o = req_pc_q;
    assign mem_wdata_o = {`RV64_XLEN{1'b0}};
    assign mem_wstrb_o = 8'h00;

    assign decode_valid_o = !flush_i &&
                            (replay_valid || buffered_decode_valid);
    wire [`RV64_XLEN-1:0] read_line_addr = {
        buffer_line_tag_q[read_bank_q], read_bank_q[0], 3'b000
    };
    assign decode_pc_o = replay_valid ? replay_pc :
                         read_line_addr +
                         (read_slot_q ? 64'd4 : 64'd0);
    assign decode_instr_o = replay_valid ?
                            (replay_slot ?
                             buffer_instr1_q[lookup_bank_r] :
                             buffer_instr0_q[lookup_bank_r]) :
                            (read_slot_q ? buffer_instr1_q[read_bank_q] :
                                           buffer_instr0_q[read_bank_q]);
    wire [`RV64_XLEN-1:0] decode_predecode_target = replay_valid ?
        (replay_slot ? buffer_target1_q[lookup_bank_r] :
                       buffer_target0_q[lookup_bank_r]) :
        (read_slot_q ? buffer_target1_q[read_bank_q] :
                       buffer_target0_q[read_bank_q]);
    wire decode_predecode_valid = replay_valid ?
        (replay_slot ? buffer_target_valid1_q[lookup_bank_r] :
                       buffer_target_valid0_q[lookup_bank_r]) :
        (read_slot_q ? buffer_target_valid1_q[read_bank_q] :
                       buffer_target_valid0_q[read_bank_q]);
    wire decode_predecode_conditional = replay_valid ?
        (replay_slot ? buffer_target_conditional1_q[lookup_bank_r] :
                       buffer_target_conditional0_q[lookup_bank_r]) :
        (read_slot_q ? buffer_target_conditional1_q[read_bank_q] :
                       buffer_target_conditional0_q[read_bank_q]);
    assign decode_fault_o = replay_valid ?
                            buffer_fault_q[lookup_bank_r] :
                            buffer_fault_q[read_bank_q];
    assign decode_page_fault_o = replay_valid ?
                                 buffer_page_fault_q[lookup_bank_r] :
                                 buffer_page_fault_q[read_bank_q];
    assign trace_id_o = replay_valid ? trace_id_i :
                        buffered_decode_valid ?
                        (read_slot_q ? buffer_trace1_q[read_bank_q] :
                                       buffer_trace0_q[read_bank_q]) :
                        req_trace_id_q;
    assign decode_bus_o = {
        decode_predecode_conditional,
        decode_predecode_valid,
        decode_predecode_target,
        decode_page_fault_o, decode_fault_o,
        decode_pc_o, decode_instr_o
    };

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            read_slot_q <= 1'b0;
            write_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_active_q <= 1'b0;
            req_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_pc_q <= {`RV64_XLEN{1'b0}};
            req_addr_q <= {`RV64_XLEN{1'b0}};
            req_trace_id_q <= 64'd0;

            for (i = 0; i < BUFFER_COUNT; i = i + 1) begin
                buffer_instr0_q[i] <= `RV64_INSTR_NOP;
                buffer_instr1_q[i] <= `RV64_INSTR_NOP;
                buffer_line_tag_q[i] <= {(`RV64_XLEN-4){1'b0}};
                buffer_trace0_q[i] <= 64'd0;
                buffer_trace1_q[i] <= 64'd0;
                buffer_fault_q[i] <= 1'b0;
                buffer_page_fault_q[i] <= 1'b0;
                buffer_resident_q[i] <= 1'b0;
                buffer_count_q[i] <= 2'd0;
            end
        end else if (flush_i) begin
            read_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            read_slot_q <= 1'b0;
            write_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_active_q <= 1'b0;
            req_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_pc_q <= {`RV64_XLEN{1'b0}};
            req_addr_q <= {`RV64_XLEN{1'b0}};
            req_trace_id_q <= 64'd0;

            for (i = 0; i < BUFFER_COUNT; i = i + 1) begin
                buffer_instr0_q[i] <= `RV64_INSTR_NOP;
                buffer_instr1_q[i] <= `RV64_INSTR_NOP;
                buffer_line_tag_q[i] <= {(`RV64_XLEN-4){1'b0}};
                buffer_trace0_q[i] <= 64'd0;
                buffer_trace1_q[i] <= 64'd0;
                buffer_fault_q[i] <= 1'b0;
                buffer_page_fault_q[i] <= 1'b0;
                buffer_resident_q[i] <= 1'b0;
                buffer_count_q[i] <= 2'd0;
            end
        end else if (redirect_i) begin
            // Wrong-path unread state and an in-flight request are discarded,
            // but resident instruction lines remain available for PC replay.
            // A predicted target hit is simultaneously handed to IF/ID; only
            // the unconsumed upper slot (if any) remains queued afterward.
            read_bank_q <= redirect_replay_valid ? lookup_bank_r :
                           {BUFFER_INDEX_WIDTH{1'b0}};
            read_slot_q <= redirect_replay_valid ?
                           (redirect_pc_i[2] ^ redirect_replay_fire) :
                           1'b0;
            write_bank_q <= redirect_replay_valid ?
                            lookup_bank_r +
                            {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1} :
                            {BUFFER_INDEX_WIDTH{1'b0}};
            req_active_q <= 1'b0;
            req_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_pc_q <= {`RV64_XLEN{1'b0}};
            req_addr_q <= {`RV64_XLEN{1'b0}};
            req_trace_id_q <= 64'd0;

            for (i = 0; i < BUFFER_COUNT; i = i + 1) begin
                buffer_count_q[i] <= 2'd0;
            end

            if (redirect_replay_valid) begin
                buffer_trace0_q[lookup_bank_r] <= redirect_pc_i[2] ?
                                                  64'd0 : trace_id_i;
                buffer_trace1_q[lookup_bank_r] <= redirect_pc_i[2] ?
                                                  trace_id_i :
                                                  trace_id_i + 64'd1;

                if (!redirect_replay_fire) begin
                    buffer_count_q[lookup_bank_r] <=
                        redirect_pc_i[2] ? 2'd1 : 2'd2;
                end else if (!redirect_pc_i[2]) begin
                    buffer_count_q[lookup_bank_r] <= 2'd1;
                end
            end
        end else begin
            if (buffered_decode_fire) begin
                if (buffer_count_q[read_bank_q] == 2'd1) begin
                    buffer_count_q[read_bank_q] <= 2'd0;
                    read_slot_q <= 1'b0;
                    read_bank_q <= read_bank_q +
                                   {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end else begin
                    buffer_count_q[read_bank_q] <=
                        buffer_count_q[read_bank_q] - 2'd1;
                    read_slot_q <= 1'b1;
                end
            end

            if (req_complete) begin
                buffer_instr0_q[req_bank_q] <=
                    (mem_fault_i || mem_page_fault_i) ?
                    `RV64_INSTR_NOP :
                    mem_rdata_i[31:0];
                buffer_instr1_q[req_bank_q] <=
                    (mem_fault_i || mem_page_fault_i) ?
                    `RV64_INSTR_NOP : mem_rdata_i[63:32];
                buffer_line_tag_q[req_bank_q] <=
                    req_addr_q[`RV64_XLEN-1:4];
                buffer_trace0_q[req_bank_q] <= req_pc_q[2] ? 64'd0 :
                                               req_trace_id_q;
                buffer_trace1_q[req_bank_q] <= req_pc_q[2] ?
                                               req_trace_id_q :
                                               req_trace_id_q + 64'd1;
                buffer_fault_q[req_bank_q] <= mem_fault_i;
                buffer_page_fault_q[req_bank_q] <= mem_page_fault_i;
                buffer_resident_q[req_bank_q] <= 1'b1;
                buffer_count_q[req_bank_q] <= req_pc_q[2] ? 2'd1 : 2'd2;
                write_bank_q <= req_successor_bank;

                if (pc_accept_miss) begin
                    req_active_q <= 1'b1;
                    req_bank_q <= req_successor_bank;
                    req_pc_q <= pc_i;
                    req_addr_q <= pc_line_addr;
                    req_trace_id_q <= trace_id_i;
                    buffer_resident_q[req_successor_bank] <= 1'b0;
                end else begin
                    req_active_q <= 1'b0;
                end
            end else if (!req_active_q && pc_accept_miss) begin
                req_active_q <= 1'b1;
                req_bank_q <= miss_bank;
                req_pc_q <= pc_i;
                req_addr_q <= pc_line_addr;
                req_trace_id_q <= trace_id_i;
                buffer_resident_q[miss_bank] <= 1'b0;

                if (queue_empty) begin
                    read_bank_q <= miss_bank;
                    read_slot_q <= pc_i[2];
                end
            end

            if (pc_accept_hit) begin
                if (stream_replay_fire) begin
                    buffer_count_q[lookup_bank_r] <= pc_i[2] ? 2'd0 : 2'd1;
                end else begin
                    buffer_count_q[lookup_bank_r] <= pc_i[2] ? 2'd1 : 2'd2;
                end
                buffer_trace0_q[lookup_bank_r] <= pc_i[2] ? 64'd0 :
                                                  trace_id_i;
                buffer_trace1_q[lookup_bank_r] <= pc_i[2] ?
                                                  trace_id_i :
                                                  trace_id_i + 64'd1;
                write_bank_q <= lookup_bank_r +
                                {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1};

                if (lookup_starts_stream) begin
                    read_bank_q <= lookup_bank_r;
                    read_slot_q <= stream_replay_fire ? 1'b1 : pc_i[2];
                end
            end
        end
    end

    integer predecode_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            predecode_pending_q <= 1'b0;
            predecode_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            for (predecode_index = 0;
                 predecode_index < BUFFER_COUNT;
                 predecode_index = predecode_index + 1) begin
                buffer_target0_q[predecode_index] <= {`RV64_XLEN{1'b0}};
                buffer_target1_q[predecode_index] <= {`RV64_XLEN{1'b0}};
                buffer_target_valid0_q[predecode_index] <= 1'b0;
                buffer_target_valid1_q[predecode_index] <= 1'b0;
                buffer_target_conditional0_q[predecode_index] <= 1'b0;
                buffer_target_conditional1_q[predecode_index] <= 1'b0;
            end
        end else if (flush_i) begin
            predecode_pending_q <= 1'b0;
            predecode_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            for (predecode_index = 0;
                 predecode_index < BUFFER_COUNT;
                 predecode_index = predecode_index + 1) begin
                buffer_target0_q[predecode_index] <= {`RV64_XLEN{1'b0}};
                buffer_target1_q[predecode_index] <= {`RV64_XLEN{1'b0}};
                buffer_target_valid0_q[predecode_index] <= 1'b0;
                buffer_target_valid1_q[predecode_index] <= 1'b0;
                buffer_target_conditional0_q[predecode_index] <= 1'b0;
                buffer_target_conditional1_q[predecode_index] <= 1'b0;
            end
        end else begin
            if (predecode_pending_q) begin
                buffer_target0_q[predecode_bank_q] <= predecode_target0;
                buffer_target1_q[predecode_bank_q] <= predecode_target1;
                buffer_target_valid0_q[predecode_bank_q] <=
                    predecode_valid0;
                buffer_target_valid1_q[predecode_bank_q] <=
                    predecode_valid1;
                buffer_target_conditional0_q[predecode_bank_q] <=
                    predecode_valid0 && predecode_conditional0;
                buffer_target_conditional1_q[predecode_bank_q] <=
                    predecode_valid1 && predecode_conditional1;
            end

            if (req_complete) begin
                // The bank has just been overwritten.  Clear stale metadata
                // now, then generate the new metadata from its stored line on
                // the following cycle.
                buffer_target0_q[req_bank_q] <= {`RV64_XLEN{1'b0}};
                buffer_target1_q[req_bank_q] <= {`RV64_XLEN{1'b0}};
                buffer_target_valid0_q[req_bank_q] <= 1'b0;
                buffer_target_valid1_q[req_bank_q] <= 1'b0;
                buffer_target_conditional0_q[req_bank_q] <= 1'b0;
                buffer_target_conditional1_q[req_bank_q] <= 1'b0;
                predecode_pending_q <= !(mem_fault_i || mem_page_fault_i);
                predecode_bank_q <= req_bank_q;
            end else if (predecode_pending_q) begin
                predecode_pending_q <= 1'b0;
            end
        end
    end

endmodule
