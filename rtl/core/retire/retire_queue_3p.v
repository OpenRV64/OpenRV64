`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

module openrv64_retire_queue_3p #(
    parameter integer DEPTH = 8,
    parameter integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH,
    parameter integer INDEX_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1),
    parameter integer ENABLE_EXTENSION_COMPLETION = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_younger_i,
    input  wire [ID_WIDTH-1:0]          squash_id_i,
    input  wire [INDEX_WIDTH-1:0]       squash_slot_i,

    input  wire [2:0]                   alloc_valid_i,
    output wire                         alloc_ready_o,
    output wire [2:0]                   alloc_accept_o,
    input  wire [2:0]                   alloc_complete_i,
    output wire [3*ID_WIDTH-1:0]        alloc_id_o,
    output wire [3*INDEX_WIDTH-1:0]     alloc_slot_o,

    input  wire [2:0]                   complete_valid_i,
    input  wire [3*ID_WIDTH-1:0]        complete_id_i,
    input  wire [3*INDEX_WIDTH-1:0]     complete_slot_i,
    output wire [2:0]                   complete_match_o,
    output wire [2:0]                   complete_accept_o,

    // Optional sparse extension-completion port.  It carries identity only;
    // extension data remains in extension-owned storage until retirement.
    input  wire                         extension_complete_valid_i,
    input  wire [ID_WIDTH-1:0]          extension_complete_id_i,
    input  wire [INDEX_WIDTH-1:0]       extension_complete_slot_i,
    output wire                         extension_complete_accept_o,

    output wire [2:0]                   retire_valid_o,
    input  wire [2:0]                   retire_accept_i,
    output wire [3*ID_WIDTH-1:0]        retire_id_o,
    output wire [3*INDEX_WIDTH-1:0]     retire_slot_o,
    output wire [DEPTH-1:0]             completed_entry_valid_o,

    output wire [COUNT_WIDTH-1:0]       occupancy_o,
    output wire [ID_WIDTH-1:0]          next_retire_id_o,
    output wire [INDEX_WIDTH-1:0]       next_retire_slot_o,
    output wire                         post_retire_valid_o,
    output wire [ID_WIDTH-1:0]          post_retire_id_o,
    output wire [INDEX_WIDTH-1:0]       post_retire_slot_o
);

    reg                                 valid_q [0:DEPTH-1];
    reg                                 complete_q [0:DEPTH-1];
    reg [ID_WIDTH-1:0]                  id_q [0:DEPTH-1];

    reg [INDEX_WIDTH-1:0]               head_q;
    reg [INDEX_WIDTH-1:0]               tail_q;
    reg [COUNT_WIDTH-1:0]               count_q;
    reg [ID_WIDTH-1:0]                  next_alloc_id_q;
    reg [ID_WIDTH-1:0]                  next_retire_id_q;

    wire [2:0] alloc_count =
        {2'd0, alloc_valid_i[0]} +
        {2'd0, alloc_valid_i[1]} +
        {2'd0, alloc_valid_i[2]};
    wire [COUNT_WIDTH-1:0] free_count = DEPTH - count_q;
    wire [2:0] alloc_fire = alloc_valid_i & {3{alloc_ready_o}};
    assign alloc_accept_o = alloc_fire;
    wire [2:0] alloc_fire_count =
        {2'd0, alloc_fire[0]} +
        {2'd0, alloc_fire[1]} +
        {2'd0, alloc_fire[2]};

    wire [INDEX_WIDTH-1:0] alloc_slot0 = index_add(tail_q, 2'd0);
    wire [INDEX_WIDTH-1:0] alloc_slot1 = index_add(tail_q, 2'd1);
    wire [INDEX_WIDTH-1:0] alloc_slot2 = index_add(tail_q, 2'd2);
    wire [ID_WIDTH-1:0] alloc_id0 = next_alloc_id_q;
    wire [ID_WIDTH-1:0] alloc_id1 = next_alloc_id_q + {{(ID_WIDTH-1){1'b0}}, 1'b1};
    wire [ID_WIDTH-1:0] alloc_id2 = next_alloc_id_q + {{(ID_WIDTH-2){1'b0}}, 2'd2};

    assign alloc_ready_o = ({2'd0, free_count} >= alloc_count);
    assign alloc_slot_o = {alloc_slot2, alloc_slot1, alloc_slot0};
    assign alloc_id_o = {alloc_id2, alloc_id1, alloc_id0};

    wire [INDEX_WIDTH-1:0] retire_slot0 = head_q;
    wire [INDEX_WIDTH-1:0] retire_slot1 = index_add(head_q, 2'd1);
    wire [INDEX_WIDTH-1:0] retire_slot2 = index_add(head_q, 2'd2);

    wire retire_valid0 = valid_q[retire_slot0] &&
                         complete_q[retire_slot0];
    wire retire_valid1 = retire_valid0 &&
                         valid_q[retire_slot1] &&
                         complete_q[retire_slot1];
    wire retire_valid2 = retire_valid1 &&
                         valid_q[retire_slot2] &&
                         complete_q[retire_slot2];
    wire [2:0] retire_fire = retire_valid_o & retire_accept_i;
    wire [2:0] retire_count =
        {2'd0, retire_fire[0]} +
        {2'd0, retire_fire[1]} +
        {2'd0, retire_fire[2]};

    assign retire_valid_o = {retire_valid2, retire_valid1, retire_valid0};
    assign retire_id_o = {
        retire_valid2 ? id_q[retire_slot2] : {ID_WIDTH{1'b0}},
        retire_valid1 ? id_q[retire_slot1] : {ID_WIDTH{1'b0}},
        retire_valid0 ? id_q[retire_slot0] : {ID_WIDTH{1'b0}}
    };
    assign retire_slot_o = {retire_slot2, retire_slot1, retire_slot0};

    assign occupancy_o = count_q;
    // Ring position, rather than consecutive numeric IDs, defines retirement
    // order.  A selective branch recovery deliberately leaves a gap in the
    // monotonically increasing ID stream so stale wrong-path completions can
    // never alias newly allocated work.
    assign next_retire_id_o = valid_q[head_q] ? id_q[head_q] : next_alloc_id_q;
    assign next_retire_slot_o = head_q;
    wire [INDEX_WIDTH-1:0] post_retire_slot =
        index_add(head_q, retire_count[1:0]);
    assign post_retire_valid_o = count_q > retire_count;
    assign post_retire_id_o = post_retire_valid_o ?
                              id_q[post_retire_slot] : next_alloc_id_q;
    assign post_retire_slot_o = post_retire_slot;

    genvar completed_entry;
    generate
        for (completed_entry = 0; completed_entry < DEPTH;
             completed_entry = completed_entry + 1) begin : g_completed_entry
            assign completed_entry_valid_o[completed_entry] =
                !flush_i && valid_q[completed_entry] &&
                complete_q[completed_entry];
        end
    endgenerate

    genvar complete_port;
    generate
        for (complete_port = 0; complete_port < 3;
             complete_port = complete_port + 1) begin : g_complete_accept
            wire [INDEX_WIDTH-1:0] completion_slot = complete_slot_i[
                complete_port*INDEX_WIDTH +: INDEX_WIDTH];
            wire [ID_WIDTH-1:0] completion_id = complete_id_i[
                complete_port*ID_WIDTH +: ID_WIDTH];
            assign complete_match_o[complete_port] =
                (!squash_younger_i ||
                 !id_is_younger(completion_id, squash_id_i)) &&
                valid_q[completion_slot] &&
                (id_q[completion_slot] == completion_id);
            assign complete_accept_o[complete_port] =
                complete_valid_i[complete_port] &&
                complete_match_o[complete_port];
        end
    endgenerate

    generate
        if (ENABLE_EXTENSION_COMPLETION != 0) begin : g_extension_complete
            assign extension_complete_accept_o =
                extension_complete_valid_i &&
                (!squash_younger_i ||
                 !id_is_younger(extension_complete_id_i, squash_id_i)) &&
                valid_q[extension_complete_slot_i] &&
                (id_q[extension_complete_slot_i] ==
                 extension_complete_id_i);
        end else begin : g_no_extension_complete
            assign extension_complete_accept_o = 1'b0;
        end
    endgenerate

    function [INDEX_WIDTH-1:0] index_add;
        input [INDEX_WIDTH-1:0] base;
        input [1:0] increment;
        integer sum;
        begin
            sum = base + increment;
            if (sum >= DEPTH) begin
                sum = sum - DEPTH;
            end
            index_add = sum[INDEX_WIDTH-1:0];
        end
    endfunction

    // True when candidate is later than reference in the modular ID space.
    // The live backend window is far smaller than half the 10-bit namespace,
    // so the sign bit of candidate-reference disambiguates wraparound.
    function id_is_younger;
        input [ID_WIDTH-1:0] candidate;
        input [ID_WIDTH-1:0] reference;
        reg [ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger =
                (distance != {ID_WIDTH{1'b0}}) && !distance[ID_WIDTH-1];
        end
    endfunction

    function [COUNT_WIDTH-1:0] prefix_count_through;
        input [INDEX_WIDTH-1:0] first;
        input [INDEX_WIDTH-1:0] last;
        integer distance;
        begin
            if (last >= first)
                distance = last - first + 1;
            else
                distance = DEPTH - first + last + 1;
            prefix_count_through = distance[COUNT_WIDTH-1:0];
        end
    endfunction

    // A selective recovery names the live branch slot.  Live queue entries
    // are contiguous in ring order, so the retained count is a slot distance;
    // it does not require a depth-wide ID/validity scan.
    wire [COUNT_WIDTH-1:0] squash_keep_count =
        prefix_count_through(head_q, squash_slot_i);

    integer entry_idx;
    integer port_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q <= {INDEX_WIDTH{1'b0}};
            tail_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            next_alloc_id_q <= {ID_WIDTH{1'b0}};
            next_retire_id_q <= {ID_WIDTH{1'b0}};

            for (entry_idx = 0; entry_idx < DEPTH; entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                complete_q[entry_idx] <= 1'b0;
            end
        end else if (flush_i) begin
            head_q <= {INDEX_WIDTH{1'b0}};
            tail_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            next_retire_id_q <= next_alloc_id_q;

            for (entry_idx = 0; entry_idx < DEPTH; entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                complete_q[entry_idx] <= 1'b0;
            end
        end else begin
            if (retire_count != 3'd0) begin
                head_q <= index_add(head_q, retire_count[1:0]);
                next_retire_id_q <= next_retire_id_q + retire_count;
            end

            if (!squash_younger_i && (alloc_fire_count != 3'd0)) begin
                tail_q <= index_add(tail_q, alloc_fire_count[1:0]);
                next_alloc_id_q <= next_alloc_id_q + alloc_fire_count;
            end

            if (squash_younger_i) begin
                tail_q <= index_add(squash_slot_i, 2'd1);
                count_q <= squash_keep_count - retire_count;
            end else begin
                count_q <= count_q + alloc_fire_count - retire_count;
            end

            if (retire_fire[0]) begin
                valid_q[retire_slot0] <= 1'b0;
                complete_q[retire_slot0] <= 1'b0;
            end
            if (retire_fire[1]) begin
                valid_q[retire_slot1] <= 1'b0;
                complete_q[retire_slot1] <= 1'b0;
            end
            if (retire_fire[2]) begin
                valid_q[retire_slot2] <= 1'b0;
                complete_q[retire_slot2] <= 1'b0;
            end

            for (port_idx = 0; port_idx < 3; port_idx = port_idx + 1) begin
                if (complete_accept_o[port_idx])
                    complete_q[complete_slot_i[
                        port_idx*INDEX_WIDTH +: INDEX_WIDTH]] <= 1'b1;
            end

            if (extension_complete_accept_o)
                complete_q[extension_complete_slot_i] <= 1'b1;

            if (!squash_younger_i && alloc_fire[0]) begin
                valid_q[alloc_slot0] <= 1'b1;
                complete_q[alloc_slot0] <= alloc_complete_i[0];
                id_q[alloc_slot0] <= alloc_id0;
            end
            if (!squash_younger_i && alloc_fire[1]) begin
                valid_q[alloc_slot1] <= 1'b1;
                complete_q[alloc_slot1] <= alloc_complete_i[1];
                id_q[alloc_slot1] <= alloc_id1;
            end
            if (!squash_younger_i && alloc_fire[2]) begin
                valid_q[alloc_slot2] <= 1'b1;
                complete_q[alloc_slot2] <= alloc_complete_i[2];
                id_q[alloc_slot2] <= alloc_id2;
            end

            if (squash_younger_i) begin
                for (entry_idx = 0; entry_idx < DEPTH;
                     entry_idx = entry_idx + 1) begin
                    if (valid_q[entry_idx] &&
                        id_is_younger(id_q[entry_idx], squash_id_i)) begin
                        valid_q[entry_idx] <= 1'b0;
                        complete_q[entry_idx] <= 1'b0;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH >= (1 << (ID_WIDTH - 1)))
            $fatal(1,
                   "retire depth must fit the modular ID half-range");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i) begin
            if ((alloc_valid_i != 3'b000) &&
                (alloc_valid_i != 3'b001) &&
                (alloc_valid_i != 3'b011) &&
                (alloc_valid_i != 3'b111)) begin
                $fatal(1, "retire queue allocations must form a contiguous prefix");
            end

            if ((retire_accept_i & ~retire_valid_o) != 3'b000) begin
                $fatal(1, "retire queue accepted an unavailable entry");
            end

            if ((retire_accept_i[1] && !retire_accept_i[0]) ||
                (retire_accept_i[2] && !retire_accept_i[1])) begin
                $fatal(1, "retire queue acceptance must form a contiguous prefix");
            end

            if (squash_younger_i && (alloc_fire != 3'b000))
                $fatal(1, "selective squash collided with retirement allocation");

            if (squash_younger_i &&
                (!valid_q[squash_slot_i] ||
                 (id_q[squash_slot_i] != squash_id_i)))
                $fatal(1, "selective squash did not name a live queue entry");
        end
    end
`endif

endmodule
