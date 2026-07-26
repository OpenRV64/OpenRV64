`timescale 1ns/1ps

// Intentionally no include guard.  The fixed 2-hart and 4-hart control-plane
// wrappers include this template with different module names and widths.
module `OPENRV64_CCX_COHERENT_FIXED_MODULE #(
    parameter integer DIRECTORY_ENTRIES = 4096,
    parameter integer DIRECTORY_INDEX_WIDTH =
        (DIRECTORY_ENTRIES > 1) ? $clog2(DIRECTORY_ENTRIES) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         dir_read_entry_valid_i,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0] dir_read_index_i,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_read_i_sharers_o,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_read_d_sharers_o,

    input  wire                         dir_update_valid_i,
    output wire                         dir_update_ready_o,
    input  wire                         dir_update_clear_entry_i,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0] dir_update_index_i,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_update_add_i_sharers_i,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_update_add_d_sharers_i,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_update_clear_i_sharers_i,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               dir_update_clear_d_sharers_i,

    input  wire                         inv_valid_i,
    output wire                         inv_ready_o,
    input  wire [DIRECTORY_INDEX_WIDTH-1:0] inv_dir_index_i,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               inv_target_harts_i,
    input  wire [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] inv_probe_id_i,
    input  wire [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
                                               inv_cache_mask_i,
    input  wire [63:0]                  inv_line_addr_i,

    output wire                         inv_done_valid_o,
    input  wire                         inv_done_ready_i,
    output wire [DIRECTORY_INDEX_WIDTH-1:0] inv_done_dir_index_o,
    output wire [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
                                               inv_done_probe_id_o,

    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               probe_valid_o,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               probe_ready_i,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS*
                 `OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id_o,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS*
                 `OPENRV64_CCX_PROBE_CMD_WIDTH-1:0] probe_command_o,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS*
                 `OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0] probe_cache_mask_o,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS*64-1:0]
                                               probe_line_addr_o,

    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               probe_ack_valid_i,
    output wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS-1:0]
                                               probe_ack_ready_o,
    input  wire [`OPENRV64_CCX_COHERENT_FIXED_HARTS*
                 `OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_ack_id_i,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    openrv64_ccx_coherent_control #(
        .NUM_HARTS(`OPENRV64_CCX_COHERENT_FIXED_HARTS),
        .DIRECTORY_ENTRIES(DIRECTORY_ENTRIES),
        .DIRECTORY_INDEX_WIDTH(DIRECTORY_INDEX_WIDTH)
    ) u_control (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dir_read_entry_valid_i(dir_read_entry_valid_i),
        .dir_read_index_i(dir_read_index_i),
        .dir_read_i_sharers_o(dir_read_i_sharers_o),
        .dir_read_d_sharers_o(dir_read_d_sharers_o),
        .dir_update_valid_i(dir_update_valid_i),
        .dir_update_ready_o(dir_update_ready_o),
        .dir_update_clear_entry_i(dir_update_clear_entry_i),
        .dir_update_index_i(dir_update_index_i),
        .dir_update_add_i_sharers_i(dir_update_add_i_sharers_i),
        .dir_update_add_d_sharers_i(dir_update_add_d_sharers_i),
        .dir_update_clear_i_sharers_i(dir_update_clear_i_sharers_i),
        .dir_update_clear_d_sharers_i(dir_update_clear_d_sharers_i),
        .inv_valid_i(inv_valid_i),
        .inv_ready_o(inv_ready_o),
        .inv_dir_index_i(inv_dir_index_i),
        .inv_target_harts_i(inv_target_harts_i),
        .inv_probe_id_i(inv_probe_id_i),
        .inv_cache_mask_i(inv_cache_mask_i),
        .inv_line_addr_i(inv_line_addr_i),
        .inv_done_valid_o(inv_done_valid_o),
        .inv_done_ready_i(inv_done_ready_i),
        .inv_done_dir_index_o(inv_done_dir_index_o),
        .inv_done_probe_id_o(inv_done_probe_id_o),
        .probe_valid_o(probe_valid_o),
        .probe_ready_i(probe_ready_i),
        .probe_id_o(probe_id_o),
        .probe_command_o(probe_command_o),
        .probe_cache_mask_o(probe_cache_mask_o),
        .probe_line_addr_o(probe_line_addr_o),
        .probe_ack_valid_i(probe_ack_valid_i),
        .probe_ack_ready_o(probe_ack_ready_o),
        .probe_ack_id_i(probe_ack_id_i),
        .protocol_error_clear_i(protocol_error_clear_i),
        .protocol_error_o(protocol_error_o)
    );

endmodule
