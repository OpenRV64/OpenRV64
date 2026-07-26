`timescale 1ns/1ps

// I-cache and D-cache sharer metadata associated with coherent L2 entries.
//
// The L2 owns entry validity.  Directory storage is deliberately not reset:
// an invalid L2 entry gates its stale metadata, and allocation must use
// write_clear_entry_i before exposing the entry as valid.  This avoids
// requiring a resettable 4-KiB register array for the default four-hart L2.
module openrv64_ccx_coherent_directory #(
    parameter integer NUM_HARTS = 2,
    parameter integer ENTRIES = 4096,
    parameter integer INDEX_WIDTH =
        (ENTRIES > 1) ? $clog2(ENTRIES) : 1
) (
    input  wire                         clk_i,

    input  wire                         read_entry_valid_i,
    input  wire [INDEX_WIDTH-1:0]       read_index_i,
    output wire [NUM_HARTS-1:0]         read_i_sharers_o,
    output wire [NUM_HARTS-1:0]         read_d_sharers_o,

    input  wire                         write_valid_i,
    input  wire                         write_clear_entry_i,
    input  wire [INDEX_WIDTH-1:0]       write_index_i,
    input  wire [NUM_HARTS-1:0]         write_add_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_add_d_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_d_sharers_i
);

    reg [NUM_HARTS-1:0] i_sharers_q [0:ENTRIES-1];
    reg [NUM_HARTS-1:0] d_sharers_q [0:ENTRIES-1];

    assign read_i_sharers_o = read_entry_valid_i ?
        i_sharers_q[read_index_i] : {NUM_HARTS{1'b0}};
    assign read_d_sharers_o = read_entry_valid_i ?
        d_sharers_q[read_index_i] : {NUM_HARTS{1'b0}};

    always @(posedge clk_i) begin
        if (write_valid_i) begin
            if (write_clear_entry_i) begin
                i_sharers_q[write_index_i] <=
                    write_add_i_sharers_i &
                    ~write_clear_i_sharers_i;
                d_sharers_q[write_index_i] <=
                    write_add_d_sharers_i &
                    ~write_clear_d_sharers_i;
            end else begin
                i_sharers_q[write_index_i] <=
                    (i_sharers_q[write_index_i] |
                     write_add_i_sharers_i) &
                    ~write_clear_i_sharers_i;
                d_sharers_q[write_index_i] <=
                    (d_sharers_q[write_index_i] |
                     write_add_d_sharers_i) &
                    ~write_clear_d_sharers_i;
            end
        end
    end

    generate
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4)) begin : g_bad_harts
            initial
                $fatal(1,
                       "coherent directory supports NUM_HARTS=2 or 4");
        end
        if (ENTRIES < 1) begin : g_bad_entries
            initial
                $fatal(1, "coherent directory requires at least one entry");
        end
    endgenerate

endmodule
