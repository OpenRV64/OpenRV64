`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

// SoC RAM shared by the scalar platform bus and the native CCX home port.
//
// Scalar requests use target-local byte offsets. Native CCX requests use
// physical addresses and return one complete 64-byte line. Both ports access
// memory_q so firmware/data writes and subsequent page-table walks observe one
// backing store. CCX is given priority only when an accepted command is ready
// to execute; a held scalar request is accepted after that one-cycle access.
module openrv64_soc_memory #(
    parameter integer MEM_BYTES = 256 * 1024 * 1024,
    parameter [63:0] MEM_BASE = `OPENRV64_SOC_MEMORY_BASE
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output wire [63:0] mem_rdata_o,

    input  wire                         ccx_req_valid_i,
    output wire                         ccx_req_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_i,
    input  wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_i,
    input  wire                         ccx_req_lock_i,
    input  wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_i,
    input  wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_i,
    input  wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_i,
    input  wire [2:0]                   ccx_req_size_i,
    input  wire [63:0]                  ccx_req_addr_i,
    input  wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_i,

    input  wire                         ccx_wdata_valid_i,
    output wire                         ccx_wdata_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_wdata_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_wdata_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_wdata_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_wdata_beat_index_i,
    input  wire                         ccx_wdata_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata_i,
    input  wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb_i,

    output wire                         ccx_resp_valid_o,
    input  wire                         ccx_resp_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_o,
    output wire                         ccx_resp_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_o,
    output wire                         ccx_resp_error_o,
    output wire                         ccx_resp_sc_success_o
);

    localparam integer WORD_COUNT = MEM_BYTES / 8;
    localparam integer WORD_INDEX_WIDTH = $clog2(WORD_COUNT);

    reg [63:0] memory_q [0:WORD_COUNT-1];
    reg scalar_pending_q;
    reg scalar_response_write_q;
    reg [63:0] scalar_read_data_q;

    reg ccx_cmd_pending_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_cmd_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_cmd_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_cmd_source_id_q;
    reg [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_cmd_op_q;
    reg ccx_cmd_lock_q;
    reg [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_cmd_order_q;
    reg [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_cmd_kind_q;
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_cmd_attr_q;
    reg [2:0] ccx_cmd_size_q;
    reg [63:0] ccx_cmd_addr_q;
    reg [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_cmd_burst_len_q;

    reg ccx_data_pending_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_data_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_data_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_data_source_id_q;
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_data_beat_index_q;
    reg ccx_data_last_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_data_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_strb_q;

    reg ccx_resp_valid_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata_q;
    reg ccx_resp_error_q;

    wire address_in_range = (mem_addr_i < MEM_BYTES);
    wire [WORD_INDEX_WIDTH-1:0] word_index =
        mem_addr_i[WORD_INDEX_WIDTH+2:3];
    wire ccx_address_in_range =
        (ccx_cmd_addr_q >= MEM_BASE) &&
        (ccx_cmd_addr_q < (MEM_BASE + MEM_BYTES));
    wire [63:0] ccx_local_addr = ccx_cmd_addr_q - MEM_BASE;
    wire [WORD_INDEX_WIDTH-1:0] ccx_word_index =
        ccx_local_addr[WORD_INDEX_WIDTH+2:3];
    wire [WORD_INDEX_WIDTH-1:0] ccx_line_word_index = {
        ccx_word_index[WORD_INDEX_WIDTH-1:3], 3'b000
    };
    wire ccx_command_is_write =
        (ccx_cmd_op_q == `OPENRV64_CCX_OP_WRITE);
    wire ccx_command_is_read =
        (ccx_cmd_op_q == `OPENRV64_CCX_OP_READ);
    wire ccx_command_is_fence =
        (ccx_cmd_op_q == `OPENRV64_CCX_OP_FENCE);
    wire ccx_execute =
        ccx_cmd_pending_q && !ccx_resp_valid_q &&
        (!ccx_command_is_write || ccx_data_pending_q);
    wire ccx_identity_error = ccx_command_is_write &&
        ((ccx_data_hart_id_q != ccx_cmd_hart_id_q) ||
         (ccx_data_txn_id_q != ccx_cmd_txn_id_q) ||
         (ccx_data_source_id_q != ccx_cmd_source_id_q));
    wire ccx_geometry_error =
        (ccx_cmd_burst_len_q != 0) ||
        ((ccx_cmd_size_q == 3'd6) && (ccx_cmd_addr_q[5:0] != 0)) ||
        (ccx_cmd_size_q > 3'd6) ||
        ccx_cmd_lock_q ||
        (ccx_command_is_write &&
         ((ccx_data_beat_index_q != 0) || !ccx_data_last_q));
    wire ccx_operation_error =
        !ccx_command_is_read && !ccx_command_is_write &&
        !ccx_command_is_fence;
    wire ccx_memory_error =
        !ccx_command_is_fence && !ccx_address_in_range;
    wire ccx_request_error = ccx_identity_error ||
                             ccx_geometry_error ||
                             ccx_operation_error ||
                             ccx_memory_error;

    integer init_index;
    integer byte_index;
    integer ccx_byte;

    initial begin
        if ((MEM_BYTES < `OPENRV64_CCX_LINE_BYTES) ||
            ((MEM_BYTES % `OPENRV64_CCX_LINE_BYTES) != 0))
            $fatal(1, "SoC RAM size must be a positive multiple of 64 bytes");
        for (init_index = 0; init_index < WORD_COUNT;
             init_index = init_index + 1) begin
            memory_q[init_index] = 64'h0000_0000_0000_0000;
        end
    end

    wire accept_scalar_request =
        mem_valid_i && !scalar_pending_q && !ccx_execute;

    assign mem_ready_o = scalar_pending_q;
    assign mem_rdata_o =
        (scalar_pending_q && !scalar_response_write_q) ?
        scalar_read_data_q : 64'h0000_0000_0000_0000;

    assign ccx_req_ready_o =
        rst_ni && !ccx_cmd_pending_q && !ccx_resp_valid_q;
    assign ccx_wdata_ready_o =
        rst_ni && !ccx_data_pending_q && !ccx_resp_valid_q;
    assign ccx_resp_valid_o = ccx_resp_valid_q;
    assign ccx_resp_hart_id_o = ccx_resp_hart_id_q;
    assign ccx_resp_txn_id_o = ccx_resp_txn_id_q;
    assign ccx_resp_source_id_o = ccx_resp_source_id_q;
    assign ccx_resp_beat_index_o =
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
    assign ccx_resp_last_o = 1'b1;
    assign ccx_resp_rdata_o = ccx_resp_rdata_q;
    assign ccx_resp_error_o = ccx_resp_error_q;
    assign ccx_resp_sc_success_o = 1'b0;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            scalar_pending_q <= 1'b0;
            scalar_response_write_q <= 1'b0;
            ccx_cmd_pending_q <= 1'b0;
            ccx_cmd_hart_id_q <= 0;
            ccx_cmd_txn_id_q <= 0;
            ccx_cmd_source_id_q <= 0;
            ccx_cmd_op_q <= `OPENRV64_CCX_OP_READ;
            ccx_cmd_lock_q <= 1'b0;
            ccx_cmd_order_q <= `OPENRV64_CCX_ORDER_NONE;
            ccx_cmd_kind_q <= `OPENRV64_CCX_KIND_LEGACY;
            ccx_cmd_attr_q <= `OPENRV64_CCX_ATTR_NONE;
            ccx_cmd_size_q <= 0;
            ccx_cmd_addr_q <= 0;
            ccx_cmd_burst_len_q <= 0;
            ccx_data_pending_q <= 1'b0;
            ccx_data_hart_id_q <= 0;
            ccx_data_txn_id_q <= 0;
            ccx_data_source_id_q <= 0;
            ccx_data_beat_index_q <= 0;
            ccx_data_last_q <= 1'b0;
            ccx_data_q <= 0;
            ccx_strb_q <= 0;
            ccx_resp_valid_q <= 1'b0;
            ccx_resp_hart_id_q <= 0;
            ccx_resp_txn_id_q <= 0;
            ccx_resp_source_id_q <= 0;
            ccx_resp_rdata_q <= 0;
            ccx_resp_error_q <= 1'b0;
        end else begin
            if (scalar_pending_q) begin
                scalar_pending_q <= 1'b0;
                scalar_response_write_q <= 1'b0;
            end else if (accept_scalar_request) begin
                scalar_pending_q <= 1'b1;
                scalar_response_write_q <= mem_write_i;
            end

            if (ccx_resp_valid_q && ccx_resp_ready_i)
                ccx_resp_valid_q <= 1'b0;

            if (ccx_req_valid_i && ccx_req_ready_o) begin
                ccx_cmd_pending_q <= 1'b1;
                ccx_cmd_hart_id_q <= ccx_req_hart_id_i;
                ccx_cmd_txn_id_q <= ccx_req_txn_id_i;
                ccx_cmd_source_id_q <= ccx_req_source_id_i;
                ccx_cmd_op_q <= ccx_req_op_i;
                ccx_cmd_lock_q <= ccx_req_lock_i;
                ccx_cmd_order_q <= ccx_req_order_i;
                ccx_cmd_kind_q <= ccx_req_kind_i;
                ccx_cmd_attr_q <= ccx_req_attr_i;
                ccx_cmd_size_q <= ccx_req_size_i;
                ccx_cmd_addr_q <= ccx_req_addr_i;
                ccx_cmd_burst_len_q <= ccx_req_burst_len_i;
            end

            if (ccx_wdata_valid_i && ccx_wdata_ready_o) begin
                ccx_data_pending_q <= 1'b1;
                ccx_data_hart_id_q <= ccx_wdata_hart_id_i;
                ccx_data_txn_id_q <= ccx_wdata_txn_id_i;
                ccx_data_source_id_q <= ccx_wdata_source_id_i;
                ccx_data_beat_index_q <= ccx_wdata_beat_index_i;
                ccx_data_last_q <= ccx_wdata_last_i;
                ccx_data_q <= ccx_wdata_i;
                ccx_strb_q <= ccx_wstrb_i;
            end

            if (ccx_execute) begin
                ccx_resp_valid_q <= 1'b1;
                ccx_resp_hart_id_q <= ccx_cmd_hart_id_q;
                ccx_resp_txn_id_q <= ccx_cmd_txn_id_q;
                ccx_resp_source_id_q <= ccx_cmd_source_id_q;
                if (!ccx_request_error && ccx_command_is_read)
                    ccx_resp_rdata_q <= {
                        memory_q[ccx_line_word_index + 7],
                        memory_q[ccx_line_word_index + 6],
                        memory_q[ccx_line_word_index + 5],
                        memory_q[ccx_line_word_index + 4],
                        memory_q[ccx_line_word_index + 3],
                        memory_q[ccx_line_word_index + 2],
                        memory_q[ccx_line_word_index + 1],
                        memory_q[ccx_line_word_index]
                    };
                else
                    ccx_resp_rdata_q <= 0;
                ccx_resp_error_q <= ccx_request_error;
                ccx_cmd_pending_q <= 1'b0;
                if (ccx_command_is_write)
                    ccx_data_pending_q <= 1'b0;
            end
        end
    end

    always @(posedge clk_i) begin
        if (accept_scalar_request && !mem_write_i) begin
            scalar_read_data_q <= address_in_range ?
                                  memory_q[word_index] :
                                  64'h0000_0000_0000_0000;
        end

        if (accept_scalar_request && mem_write_i && address_in_range) begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1) begin
                if (mem_wstrb_i[byte_index]) begin
                    memory_q[word_index][8*byte_index +: 8] <=
                        mem_wdata_i[8*byte_index +: 8];
                end
            end
        end

        if (ccx_execute && !ccx_request_error &&
            ccx_command_is_write) begin
            for (ccx_byte = 0;
                 ccx_byte < `OPENRV64_CCX_LINE_STRB_WIDTH;
                 ccx_byte = ccx_byte + 1) begin
                if (ccx_strb_q[ccx_byte])
                    memory_q[ccx_line_word_index + (ccx_byte / 8)]
                            [(ccx_byte % 8)*8 +: 8] <=
                        ccx_data_q[ccx_byte*8 +: 8];
            end
        end
    end

    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] unused_ccx_order =
        ccx_cmd_order_q;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] unused_ccx_kind =
        ccx_cmd_kind_q;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] unused_ccx_attr =
        ccx_cmd_attr_q;

endmodule
