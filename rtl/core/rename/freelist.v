`ifndef OPENRV64_RENAME_FREELIST_V
`define OPENRV64_RENAME_FREELIST_V

`timescale 1ns/1ps

// Physical-register free list: a circular array of tags with two cursors.
// Retirement pushes the mapping that died with each retiring instruction at
// the tail; rename pops fresh destination tags at the head.  The pop side is
// group-shaped for three-wide rename: pop_tag_o exposes the oldest
// POP_PORTS entries as a stable peek so a held candidate group can be
// renamed before it fires, and pop_req_i consumes a contiguous prefix of
// them on the fire edge.
//
// Under the identity bring-up configuration nothing pops and retirement
// pushes repeat forever, so a full list drops pushes (counted in
// simulation).  Under a real renamer, tag conservation means a push can
// never find the list full; set STRICT_CONSERVATION when tomasulo
// allocation goes live to make overflow fatal.  Checkpoint/rollback cursor
// state arrives with the rename recovery work.
module openrv64_rename_freelist #(
    parameter integer TAG_WIDTH = 5,
    parameter integer DEPTH = 64,
    parameter integer PUSH_PORTS = 2,
    parameter integer POP_PORTS = 3,
    parameter integer INIT_BASE = 0,
    parameter integer INIT_COUNT = 0,
    parameter integer STRICT_CONSERVATION = 0,
    parameter integer PTR_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire                            clk,
    input  wire                            rst_n,

    input  wire [PUSH_PORTS-1:0]           push_valid_i,
    input  wire [PUSH_PORTS*TAG_WIDTH-1:0] push_tag_i,

    input  wire [POP_PORTS-1:0]            pop_req_i,
    output wire [POP_PORTS-1:0]            pop_valid_o,
    output wire [POP_PORTS*TAG_WIDTH-1:0]  pop_tag_o,

    output wire [COUNT_WIDTH-1:0]          count_o
);

    reg [TAG_WIDTH-1:0] tags_q [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] head_q;
    reg [PTR_WIDTH-1:0] tail_q;
    reg [COUNT_WIDTH-1:0] count_q;

    assign count_o = count_q;

    genvar pop_port;
    generate
        for (pop_port = 0; pop_port < POP_PORTS;
             pop_port = pop_port + 1) begin : g_pop
            assign pop_valid_o[pop_port] =
                (count_q > pop_port[COUNT_WIDTH-1:0]);
            assign pop_tag_o[pop_port*TAG_WIDTH +: TAG_WIDTH] =
                tags_q[PTR_WIDTH'(head_q + pop_port)];
        end
    endgenerate

    wire [POP_PORTS-1:0] pop_fire = pop_req_i & pop_valid_o;

    integer push_port;
    integer pop_scan;
    integer accepted_count;
    integer popped_count;
    reg [COUNT_WIDTH-1:0] occupancy_after;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q <= {PTR_WIDTH{1'b0}};
            tail_q <= INIT_COUNT[PTR_WIDTH-1:0];
            count_q <= INIT_COUNT[COUNT_WIDTH-1:0];
        end else begin
            popped_count = 0;
            for (pop_scan = 0; pop_scan < POP_PORTS;
                 pop_scan = pop_scan + 1) begin
                if (pop_fire[pop_scan])
                    popped_count = popped_count + 1;
            end

            accepted_count = 0;
            occupancy_after =
                count_q - popped_count[COUNT_WIDTH-1:0];

            for (push_port = 0; push_port < PUSH_PORTS;
                 push_port = push_port + 1) begin
                if (push_valid_i[push_port] &&
                    (occupancy_after < DEPTH[COUNT_WIDTH-1:0])) begin
                    tags_q[PTR_WIDTH'(tail_q + accepted_count)] <=
                        push_tag_i[push_port*TAG_WIDTH +: TAG_WIDTH];
                    accepted_count = accepted_count + 1;
                    occupancy_after = occupancy_after + 1'b1;
                end
            end

            head_q <= PTR_WIDTH'(head_q + popped_count);
            tail_q <= PTR_WIDTH'(tail_q + accepted_count);
            count_q <= occupancy_after;
        end
    end

    genvar init_entry;
    generate
        for (init_entry = 0; init_entry < DEPTH;
             init_entry = init_entry + 1) begin : g_init
            if (init_entry < INIT_COUNT) begin : g_preload
                initial tags_q[init_entry] =
                    TAG_WIDTH'(INIT_BASE + init_entry);
            end
        end
    endgenerate

`ifndef SYNTHESIS
    integer dropped_push_count = 0;
    integer drop_scan;
    integer drop_pop_count;
    reg [COUNT_WIDTH-1:0] drop_occupancy;
    always @(posedge clk) begin
        if (rst_n) begin
            drop_pop_count = 0;
            for (drop_scan = 0; drop_scan < POP_PORTS;
                 drop_scan = drop_scan + 1) begin
                if (pop_fire[drop_scan])
                    drop_pop_count = drop_pop_count + 1;

                if (pop_req_i[drop_scan] && !pop_valid_o[drop_scan])
                    $fatal(1,
                           "freelist: pop requested beyond available tags");
                if ((drop_scan > 0) && pop_req_i[drop_scan] &&
                    !pop_req_i[drop_scan-1])
                    $fatal(1,
                           "freelist: pop requests must be a contiguous prefix");
            end

            drop_occupancy = count_q - drop_pop_count[COUNT_WIDTH-1:0];
            for (drop_scan = 0; drop_scan < PUSH_PORTS;
                 drop_scan = drop_scan + 1) begin
                if (push_valid_i[drop_scan]) begin
                    if (drop_occupancy < DEPTH[COUNT_WIDTH-1:0]) begin
                        drop_occupancy = drop_occupancy + 1'b1;
                    end else begin
                        dropped_push_count = dropped_push_count + 1;
                        if (STRICT_CONSERVATION != 0)
                            $fatal(1,
                                   "freelist: push overflowed a full list");
                    end
                end
            end
        end
    end

    initial begin
        if ((DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "freelist: DEPTH must be a power of two");
        if (INIT_COUNT > DEPTH)
            $fatal(1, "freelist: INIT_COUNT exceeds DEPTH");
        if (PUSH_PORTS < 1)
            $fatal(1, "freelist: PUSH_PORTS must be at least one");
        if (POP_PORTS < 1)
            $fatal(1, "freelist: POP_PORTS must be at least one");
        if (POP_PORTS > DEPTH)
            $fatal(1, "freelist: POP_PORTS exceeds DEPTH");
    end
`endif

endmodule

`endif
