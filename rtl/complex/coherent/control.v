`timescale 1ns/1ps
`include "complex/coherent/protocol/defs.v"

// Shared coherence-control foundation for the fixed 2-hart and 4-hart
// complexes.  It owns sharer metadata and commits directory invalidation only
// after all selected private-cache endpoints acknowledge the probe.
//
// The future coherent L2 is responsible for same-line serialization.  It may
// not add a new sharer to an entry while an invalidation for that entry is
// active.
module openrv64_icx_coherent_control #(
    parameter integer NUM_HARTS = 2,
    parameter integer DIRECTORY_ENTRIES = 4096,
    parameter integer DIRECTORY_INDEX_WIDTH =
        (DIRECTORY_ENTRIES > 1) ? $clog2(DIRECTORY_ENTRIES) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         dir_read_entry_valid_i,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0]
                                               dir_read_index_i,
    output wire [NUM_HARTS-1:0]         dir_read_i_sharers_o,
    output wire [NUM_HARTS-1:0]         dir_read_d_sharers_o,

    input  wire                         dir_update_valid_i,
    output wire                         dir_update_ready_o,
    input  wire                         dir_update_clear_entry_i,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0]
                                               dir_update_index_i,
    input  wire [NUM_HARTS-1:0]         dir_update_add_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         dir_update_add_d_sharers_i,
    input  wire [NUM_HARTS-1:0]         dir_update_clear_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         dir_update_clear_d_sharers_i,

    input  wire                         inv_valid_i,
    output wire                         inv_ready_o,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0] inv_dir_index_i,
    input  wire [NUM_HARTS-1:0]         inv_target_harts_i,
    input  wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               inv_probe_id_i,
    input  wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
                                               inv_cache_mask_i,
    input  wire [63:0]                  inv_line_addr_i,

    output wire                         inv_done_valid_o,
    input  wire                         inv_done_ready_i,
    output wire [DIRECTORY_INDEX_WIDTH-1:0]
                                               inv_done_dir_index_o,
    output wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               inv_done_probe_id_o,

    output wire [NUM_HARTS-1:0]         probe_valid_o,
    input  wire [NUM_HARTS-1:0]         probe_ready_i,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_id_o,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0]
                                               probe_command_o,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_o,
    output wire [NUM_HARTS*64-1:0]      probe_line_addr_o,

    input  wire [NUM_HARTS-1:0]         probe_ack_valid_i,
    output wire [NUM_HARTS-1:0]         probe_ack_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_ack_id_i,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    reg [DIRECTORY_INDEX_WIDTH-1:0] inv_dir_index_q;
    reg [NUM_HARTS-1:0] inv_target_harts_q;
    reg [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0] inv_cache_mask_q;
    reg completion_valid_q;
    reg [DIRECTORY_INDEX_WIDTH-1:0] completion_dir_index_q;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] completion_probe_id_q;

    wire tracker_start_ready;
    wire tracker_done_valid;
    wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
        tracker_done_probe_id;
    wire metadata_commit =
        tracker_done_valid && !completion_valid_q;
    wire external_dir_update =
        dir_update_valid_i && dir_update_ready_o;
    wire directory_write_valid =
        metadata_commit || external_dir_update;
    wire directory_write_clear_entry =
        metadata_commit ? 1'b0 : dir_update_clear_entry_i;
    wire [DIRECTORY_INDEX_WIDTH-1:0] directory_write_index =
        metadata_commit ? inv_dir_index_q : dir_update_index_i;
    wire [NUM_HARTS-1:0] directory_write_add_i =
        metadata_commit ? {NUM_HARTS{1'b0}} :
                          dir_update_add_i_sharers_i;
    wire [NUM_HARTS-1:0] directory_write_add_d =
        metadata_commit ? {NUM_HARTS{1'b0}} :
                          dir_update_add_d_sharers_i;
    wire [NUM_HARTS-1:0] directory_write_clear_i =
        metadata_commit &&
        inv_cache_mask_q[`OPENRV64_ICX_PROBE_CACHE_WIDTH-2] ?
            inv_target_harts_q :
            (metadata_commit ? {NUM_HARTS{1'b0}} :
                               dir_update_clear_i_sharers_i);
    wire [NUM_HARTS-1:0] directory_write_clear_d =
        metadata_commit &&
        inv_cache_mask_q[`OPENRV64_ICX_PROBE_CACHE_WIDTH-1] ?
            inv_target_harts_q :
            (metadata_commit ? {NUM_HARTS{1'b0}} :
                               dir_update_clear_d_sharers_i);

    assign dir_update_ready_o = !metadata_commit;
    assign inv_ready_o = tracker_start_ready && !completion_valid_q;
    assign inv_done_valid_o = completion_valid_q;
    assign inv_done_dir_index_o = completion_dir_index_q;
    assign inv_done_probe_id_o = completion_probe_id_q;

    openrv64_icx_coherent_directory #(
        .NUM_HARTS(NUM_HARTS),
        .ENTRIES(DIRECTORY_ENTRIES),
        .INDEX_WIDTH(DIRECTORY_INDEX_WIDTH)
    ) u_directory (
        .clk_i(clk_i),
        .read_entry_valid_i(dir_read_entry_valid_i),
        .read_index_i(dir_read_index_i),
        .read_i_sharers_o(dir_read_i_sharers_o),
        .read_d_sharers_o(dir_read_d_sharers_o),
        .write_valid_i(directory_write_valid),
        .write_clear_entry_i(directory_write_clear_entry),
        .write_index_i(directory_write_index),
        .write_add_i_sharers_i(directory_write_add_i),
        .write_add_d_sharers_i(directory_write_add_d),
        .write_clear_i_sharers_i(directory_write_clear_i),
        .write_clear_d_sharers_i(directory_write_clear_d)
    );

    openrv64_icx_probe_tracker #(
        .NUM_HARTS(NUM_HARTS)
    ) u_probe_tracker (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .start_valid_i(inv_valid_i && !completion_valid_q),
        .start_ready_o(tracker_start_ready),
        .start_target_harts_i(inv_target_harts_i),
        .start_probe_id_i(inv_probe_id_i),
        .start_command_i(`OPENRV64_ICX_PROBE_INV),
        .start_cache_mask_i(inv_cache_mask_i),
        .start_line_addr_i(inv_line_addr_i),
        .probe_valid_o(probe_valid_o),
        .probe_ready_i(probe_ready_i),
        .probe_id_o(probe_id_o),
        .probe_command_o(probe_command_o),
        .probe_cache_mask_o(probe_cache_mask_o),
        .probe_line_addr_o(probe_line_addr_o),
        .probe_ack_valid_i(probe_ack_valid_i),
        .probe_ack_ready_o(probe_ack_ready_o),
        .probe_ack_id_i(probe_ack_id_i),
        .busy_o(),
        .done_valid_o(tracker_done_valid),
        .done_ready_i(metadata_commit),
        .done_probe_id_o(tracker_done_probe_id),
        .protocol_error_clear_i(protocol_error_clear_i),
        .protocol_error_o(protocol_error_o)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            inv_dir_index_q <= {DIRECTORY_INDEX_WIDTH{1'b0}};
            inv_target_harts_q <= {NUM_HARTS{1'b0}};
            inv_cache_mask_q <=
                {`OPENRV64_ICX_PROBE_CACHE_WIDTH{1'b0}};
            completion_valid_q <= 1'b0;
            completion_dir_index_q <=
                {DIRECTORY_INDEX_WIDTH{1'b0}};
            completion_probe_id_q <=
                {`OPENRV64_ICX_PROBE_ID_WIDTH{1'b0}};
        end else begin
            if (inv_valid_i && inv_ready_o) begin
                inv_dir_index_q <= inv_dir_index_i;
                inv_target_harts_q <= inv_target_harts_i;
                inv_cache_mask_q <= inv_cache_mask_i;
            end

            if (completion_valid_q && inv_done_ready_i)
                completion_valid_q <= 1'b0;

            if (metadata_commit) begin
                completion_valid_q <= 1'b1;
                completion_dir_index_q <= inv_dir_index_q;
                completion_probe_id_q <= tracker_done_probe_id;
            end
        end
    end

endmodule
