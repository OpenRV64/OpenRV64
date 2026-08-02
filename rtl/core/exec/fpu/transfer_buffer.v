`ifndef OPENRV64_FD_TRANSFER_BUFFER_V
`define OPENRV64_FD_TRANSFER_BUFFER_V
`timescale 1ns/1ps

`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// FPU-owned associative transfer buffer between the LSU and architectural FPR
// retirement path.  Entries are tagged with both instruction ID and physical
// retirement slot: the slot locates the macro-instruction, while the monotonic
// ID prevents a late LSU response from matching a reused slot.
//
// Loads reserve an entry before LSU issue, fill it on successful completion,
// and consume it at retirement.  Stores reserve an already-filled entry when
// fd_dispatch captures their FPR source, then consume it when the LSU accepts
// the store payload.
module openrv64_fd_transfer_buffer #(
    parameter integer DEPTH = 2,
    parameter integer RETIRE_SLOT_WIDTH = 4,
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,

    input  wire                         reserve_valid_i,
    output reg                          reserve_ready_o,
    input  wire                         reserve_is_load_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] reserve_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] reserve_slot_i,
    input  wire [`RV64_XLEN-1:0]        reserve_data_i,

    input  wire                         fill_valid_i,
    output reg                          fill_match_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] fill_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] fill_slot_i,
    input  wire [`RV64_XLEN-1:0]        fill_data_i,

    input  wire [3:0]                   consume_valid_i,
    input  wire [4*`OPENRV64_INSTR_ID_WIDTH-1:0] consume_id_i,
    input  wire [4*RETIRE_SLOT_WIDTH-1:0] consume_slot_i,

    output wire [DEPTH-1:0]             entry_valid_o,
    output wire [DEPTH-1:0]             entry_is_load_o,
    output wire [DEPTH-1:0]             entry_data_valid_o,
    output wire [DEPTH*`OPENRV64_INSTR_ID_WIDTH-1:0] entry_id_o,
    output wire [DEPTH*RETIRE_SLOT_WIDTH-1:0] entry_slot_o,
    output wire [DEPTH*`RV64_XLEN-1:0]  entry_data_o,
    output wire [COUNT_WIDTH-1:0]       count_o
);

    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;

    reg valid_q [0:DEPTH-1];
    reg is_load_q [0:DEPTH-1];
    reg data_valid_q [0:DEPTH-1];
    reg [ID_WIDTH-1:0] id_q [0:DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] slot_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] data_q [0:DEPTH-1];

    reg valid_d [0:DEPTH-1];
    reg is_load_d [0:DEPTH-1];
    reg data_valid_d [0:DEPTH-1];
    reg [ID_WIDTH-1:0] id_d [0:DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] slot_d [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] data_d [0:DEPTH-1];

    function automatic id_is_younger;
        input [ID_WIDTH-1:0] candidate;
        input [ID_WIDTH-1:0] reference;
        reg [ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger = (distance != {ID_WIDTH{1'b0}}) &&
                            !distance[ID_WIDTH-1];
        end
    endfunction

    integer next_entry_idx;
    integer next_consume_idx;
    integer ready_entry_idx;
    integer reserve_free_idx;
    reg reserve_duplicate;

    // Registered-capacity view kept separate from the state-update process so
    // LSU consume cannot feed combinationally back into reserve readiness.
    always_comb begin
        reserve_free_idx = -1;
        reserve_duplicate = 1'b0;
        for (ready_entry_idx = 0; ready_entry_idx < DEPTH;
             ready_entry_idx = ready_entry_idx + 1) begin
            if (!valid_q[ready_entry_idx] && (reserve_free_idx < 0))
                reserve_free_idx = ready_entry_idx;
            if (valid_q[ready_entry_idx] &&
                (id_q[ready_entry_idx] == reserve_id_i) &&
                (slot_q[ready_entry_idx] == reserve_slot_i))
                reserve_duplicate = 1'b1;
        end
        reserve_ready_o = (reserve_free_idx >= 0) && !reserve_duplicate &&
                          !flush_i && !squash_i;
    end

    always_comb begin
        for (next_entry_idx = 0; next_entry_idx < DEPTH;
             next_entry_idx = next_entry_idx + 1) begin
            valid_d[next_entry_idx] = valid_q[next_entry_idx];
            is_load_d[next_entry_idx] = is_load_q[next_entry_idx];
            data_valid_d[next_entry_idx] = data_valid_q[next_entry_idx];
            id_d[next_entry_idx] = id_q[next_entry_idx];
            slot_d[next_entry_idx] = slot_q[next_entry_idx];
            data_d[next_entry_idx] = data_q[next_entry_idx];
        end

        // Capacity is based on registered state.  A consume and replacement
        // therefore take two cycles when the buffer was full.  That deliberate
        // bubble breaks any ready/consume combinational loop at the LSU seam.
        // Selective recovery precedes response/consume handling.  A late
        // response for a removed entry consequently has no matching target.
        if (squash_i) begin
            for (next_entry_idx = 0; next_entry_idx < DEPTH;
                 next_entry_idx = next_entry_idx + 1) begin
                if (valid_d[next_entry_idx] &&
                    id_is_younger(id_d[next_entry_idx], squash_id_i)) begin
                    valid_d[next_entry_idx] = 1'b0;
                    data_valid_d[next_entry_idx] = 1'b0;
                end
            end
        end

        for (next_consume_idx = 0; next_consume_idx < 4;
             next_consume_idx = next_consume_idx + 1) begin
            for (next_entry_idx = 0; next_entry_idx < DEPTH;
                 next_entry_idx = next_entry_idx + 1) begin
                if (consume_valid_i[next_consume_idx] &&
                    valid_d[next_entry_idx] &&
                    (id_d[next_entry_idx] == consume_id_i[
                        next_consume_idx*ID_WIDTH +: ID_WIDTH]) &&
                    (slot_d[next_entry_idx] == consume_slot_i[
                        next_consume_idx*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH])) begin
                    valid_d[next_entry_idx] = 1'b0;
                    data_valid_d[next_entry_idx] = 1'b0;
                end
            end
        end

        fill_match_o = 1'b0;
        if (fill_valid_i) begin
            for (next_entry_idx = 0; next_entry_idx < DEPTH;
                 next_entry_idx = next_entry_idx + 1) begin
                if (!fill_match_o && valid_d[next_entry_idx] &&
                    is_load_d[next_entry_idx] &&
                    (id_d[next_entry_idx] == fill_id_i) &&
                    (slot_d[next_entry_idx] == fill_slot_i)) begin
                    fill_match_o = 1'b1;
                    data_valid_d[next_entry_idx] = 1'b1;
                    data_d[next_entry_idx] = fill_data_i;
                end
            end
        end

        if (reserve_valid_i && reserve_ready_o) begin
            valid_d[reserve_free_idx] = 1'b1;
            is_load_d[reserve_free_idx] = reserve_is_load_i;
            data_valid_d[reserve_free_idx] = !reserve_is_load_i;
            id_d[reserve_free_idx] = reserve_id_i;
            slot_d[reserve_free_idx] = reserve_slot_i;
            data_d[reserve_free_idx] = reserve_data_i;
        end
    end

    integer seq_entry_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (seq_entry_idx = 0; seq_entry_idx < DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                valid_q[seq_entry_idx] <= 1'b0;
                is_load_q[seq_entry_idx] <= 1'b0;
                data_valid_q[seq_entry_idx] <= 1'b0;
                id_q[seq_entry_idx] <= {ID_WIDTH{1'b0}};
                slot_q[seq_entry_idx] <= {RETIRE_SLOT_WIDTH{1'b0}};
                data_q[seq_entry_idx] <= {`RV64_XLEN{1'b0}};
            end
        end else if (flush_i) begin
            for (seq_entry_idx = 0; seq_entry_idx < DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                valid_q[seq_entry_idx] <= 1'b0;
                data_valid_q[seq_entry_idx] <= 1'b0;
            end
        end else begin
            for (seq_entry_idx = 0; seq_entry_idx < DEPTH;
                 seq_entry_idx = seq_entry_idx + 1) begin
                valid_q[seq_entry_idx] <= valid_d[seq_entry_idx];
                is_load_q[seq_entry_idx] <= is_load_d[seq_entry_idx];
                data_valid_q[seq_entry_idx] <= data_valid_d[seq_entry_idx];
                id_q[seq_entry_idx] <= id_d[seq_entry_idx];
                slot_q[seq_entry_idx] <= slot_d[seq_entry_idx];
                data_q[seq_entry_idx] <= data_d[seq_entry_idx];
            end
        end
    end

    genvar flatten_idx;
    generate
        for (flatten_idx = 0; flatten_idx < DEPTH;
             flatten_idx = flatten_idx + 1) begin : g_flatten
            assign entry_valid_o[flatten_idx] = valid_q[flatten_idx];
            assign entry_is_load_o[flatten_idx] = is_load_q[flatten_idx];
            assign entry_data_valid_o[flatten_idx] =
                data_valid_q[flatten_idx];
            assign entry_id_o[flatten_idx*ID_WIDTH +: ID_WIDTH] =
                id_q[flatten_idx];
            assign entry_slot_o[
                flatten_idx*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                slot_q[flatten_idx];
            assign entry_data_o[flatten_idx*`RV64_XLEN +: `RV64_XLEN] =
                data_q[flatten_idx];
        end
    endgenerate

    reg [COUNT_WIDTH-1:0] count_q;
    integer count_entry_idx;
    always_comb begin
        count_q = {COUNT_WIDTH{1'b0}};
        for (count_entry_idx = 0; count_entry_idx < DEPTH;
             count_entry_idx = count_entry_idx + 1)
            if (valid_q[count_entry_idx])
                count_q = count_q + 1'b1;
    end
    assign count_o = count_q;

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1)
            $fatal(1, "F/D transfer buffer depth must be positive");
    end
`endif

endmodule

`endif
