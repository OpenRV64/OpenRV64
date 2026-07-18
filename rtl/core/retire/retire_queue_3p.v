`timescale 1ns/1ps

module openrv64_retire_queue_3p #(
    parameter integer DEPTH = 8,
    parameter integer ID_WIDTH = 64,
    parameter integer META_WIDTH = 1,
    parameter integer RESULT_WIDTH = 1,
    parameter integer INDEX_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   alloc_valid_i,
    output wire                         alloc_ready_o,
    input  wire [3*META_WIDTH-1:0]      alloc_meta_i,
    output wire [3*ID_WIDTH-1:0]        alloc_id_o,
    output wire [3*INDEX_WIDTH-1:0]     alloc_slot_o,

    input  wire [2:0]                   complete_valid_i,
    input  wire [3*ID_WIDTH-1:0]        complete_id_i,
    input  wire [3*INDEX_WIDTH-1:0]     complete_slot_i,
    input  wire [3*RESULT_WIDTH-1:0]    complete_result_i,

    output wire [2:0]                   retire_valid_o,
    input  wire [2:0]                   retire_accept_i,
    output wire [3*ID_WIDTH-1:0]        retire_id_o,
    output wire [3*META_WIDTH-1:0]      retire_meta_o,
    output wire [3*RESULT_WIDTH-1:0]    retire_result_o,

    output wire [COUNT_WIDTH-1:0]       occupancy_o,
    output wire [ID_WIDTH-1:0]          next_retire_id_o,
    output wire [INDEX_WIDTH-1:0]       next_retire_slot_o
);

    reg                                 valid_q [0:DEPTH-1];
    reg                                 complete_q [0:DEPTH-1];
    reg [ID_WIDTH-1:0]                  id_q [0:DEPTH-1];
    reg [META_WIDTH-1:0]                meta_q [0:DEPTH-1];
    reg [RESULT_WIDTH-1:0]              result_q [0:DEPTH-1];

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
                         complete_q[retire_slot0] &&
                         (id_q[retire_slot0] == next_retire_id_q);
    wire retire_valid1 = retire_valid0 &&
                         valid_q[retire_slot1] &&
                         complete_q[retire_slot1] &&
                         (id_q[retire_slot1] ==
                          (next_retire_id_q + {{(ID_WIDTH-1){1'b0}}, 1'b1}));
    wire retire_valid2 = retire_valid1 &&
                         valid_q[retire_slot2] &&
                         complete_q[retire_slot2] &&
                         (id_q[retire_slot2] ==
                          (next_retire_id_q + {{(ID_WIDTH-2){1'b0}}, 2'd2}));
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
    assign retire_meta_o = {
        retire_valid2 ? meta_q[retire_slot2] : {META_WIDTH{1'b0}},
        retire_valid1 ? meta_q[retire_slot1] : {META_WIDTH{1'b0}},
        retire_valid0 ? meta_q[retire_slot0] : {META_WIDTH{1'b0}}
    };
    assign retire_result_o = {
        retire_valid2 ? result_q[retire_slot2] : {RESULT_WIDTH{1'b0}},
        retire_valid1 ? result_q[retire_slot1] : {RESULT_WIDTH{1'b0}},
        retire_valid0 ? result_q[retire_slot0] : {RESULT_WIDTH{1'b0}}
    };
    assign occupancy_o = count_q;
    assign next_retire_id_o = next_retire_id_q;
    assign next_retire_slot_o = head_q;

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

    integer entry_idx;
    integer port_idx;
    reg [INDEX_WIDTH-1:0] completion_slot;
    reg [ID_WIDTH-1:0] completion_id;

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
                id_q[entry_idx] <= {ID_WIDTH{1'b0}};
                meta_q[entry_idx] <= {META_WIDTH{1'b0}};
                result_q[entry_idx] <= {RESULT_WIDTH{1'b0}};
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

            if (alloc_fire_count != 3'd0) begin
                tail_q <= index_add(tail_q, alloc_fire_count[1:0]);
                next_alloc_id_q <= next_alloc_id_q + alloc_fire_count;
            end

            count_q <= count_q + alloc_fire_count - retire_count;

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
                completion_slot = complete_slot_i[port_idx*INDEX_WIDTH +: INDEX_WIDTH];
                completion_id = complete_id_i[port_idx*ID_WIDTH +: ID_WIDTH];

                if (complete_valid_i[port_idx] &&
                    valid_q[completion_slot] &&
                    (id_q[completion_slot] == completion_id)) begin
                    complete_q[completion_slot] <= 1'b1;
                    result_q[completion_slot] <=
                        complete_result_i[port_idx*RESULT_WIDTH +: RESULT_WIDTH];
                end
            end

            if (alloc_fire[0]) begin
                valid_q[alloc_slot0] <= 1'b1;
                complete_q[alloc_slot0] <= 1'b0;
                id_q[alloc_slot0] <= alloc_id0;
                meta_q[alloc_slot0] <= alloc_meta_i[0 +: META_WIDTH];
                result_q[alloc_slot0] <= {RESULT_WIDTH{1'b0}};
            end
            if (alloc_fire[1]) begin
                valid_q[alloc_slot1] <= 1'b1;
                complete_q[alloc_slot1] <= 1'b0;
                id_q[alloc_slot1] <= alloc_id1;
                meta_q[alloc_slot1] <= alloc_meta_i[META_WIDTH +: META_WIDTH];
                result_q[alloc_slot1] <= {RESULT_WIDTH{1'b0}};
            end
            if (alloc_fire[2]) begin
                valid_q[alloc_slot2] <= 1'b1;
                complete_q[alloc_slot2] <= 1'b0;
                id_q[alloc_slot2] <= alloc_id2;
                meta_q[alloc_slot2] <= alloc_meta_i[2*META_WIDTH +: META_WIDTH];
                result_q[alloc_slot2] <= {RESULT_WIDTH{1'b0}};
            end
        end
    end

`ifndef SYNTHESIS
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
        end
    end
`endif

endmodule
