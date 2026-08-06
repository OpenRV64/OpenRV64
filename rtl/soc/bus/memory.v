`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

// SoC RAM shared by the scalar platform bus and the native ICX home port.
//
// Scalar requests use target-local byte offsets. Native ICX requests use
// physical addresses and return one complete 64-byte line. Both ports access
// memory_q so firmware/data writes and subsequent page-table walks observe one
// backing store. ICX is given priority only when an accepted command is ready
// to execute; a held scalar request is accepted after that one-cycle access.
module openrv64_soc_memory #(
    parameter integer MEM_BYTES = 256 * 1024 * 1024,
    parameter [63:0] MEM_BASE = `OPENRV64_SOC_MEMORY_BASE,
    parameter integer WIDE_DATA_WIDTH = 256
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

    input  wire                         wide_valid_i,
    output wire                         wide_ready_o,
    input  wire                         wide_write_i,
    input  wire [63:0]                  wide_addr_i,
    input  wire [WIDE_DATA_WIDTH-1:0]   wide_wdata_i,
    input  wire [WIDE_DATA_WIDTH/8-1:0] wide_wstrb_i,
    output wire [WIDE_DATA_WIDTH-1:0]   wide_rdata_o,
    output wire                         wide_error_o,

    input  wire                         icx_req_valid_i,
    output wire                         icx_req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_req_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_req_source_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_i,
    input  wire                         icx_req_lock_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_i,
    input  wire [2:0]                   icx_req_size_i,
    input  wire [63:0]                  icx_req_addr_i,
    input  wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                        icx_req_burst_len_i,

    input  wire                         icx_wdata_valid_i,
    output wire                         icx_wdata_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_wdata_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_wdata_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_wdata_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                        icx_wdata_beat_index_i,
    input  wire                         icx_wdata_last_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata_i,
    input  wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb_i,

    output wire                         icx_resp_valid_o,
    input  wire                         icx_resp_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_resp_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_resp_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_resp_source_id_o,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                        icx_resp_beat_index_o,
    output wire                         icx_resp_last_o,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                        icx_resp_rdata_o,
    output wire                         icx_resp_error_o,
    output wire                         icx_resp_sc_success_o
);

    localparam integer WORD_COUNT = MEM_BYTES / 8;
    localparam integer WORD_INDEX_WIDTH = $clog2(WORD_COUNT);
    localparam integer WIDE_BYTES = WIDE_DATA_WIDTH / 8;
    localparam integer WIDE_WORDS = WIDE_DATA_WIDTH / 64;

    reg [63:0] memory_q [0:WORD_COUNT-1];
    reg scalar_pending_q;
    reg scalar_response_write_q;
    reg [63:0] scalar_read_data_q;
    reg wide_pending_q;
    reg wide_response_write_q;
    reg [WIDE_DATA_WIDTH-1:0] wide_read_data_q;
    reg wide_error_q;

    reg icx_cmd_pending_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_cmd_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_cmd_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_cmd_source_id_q;
    reg [`OPENRV64_ICX_OP_WIDTH-1:0] icx_cmd_op_q;
    reg icx_cmd_lock_q;
    reg [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_cmd_order_q;
    reg [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_cmd_kind_q;
    reg [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_cmd_attr_q;
    reg [2:0] icx_cmd_size_q;
    reg [63:0] icx_cmd_addr_q;
    reg [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_cmd_burst_len_q;

    reg icx_data_pending_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_data_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_data_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_data_source_id_q;
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_data_beat_index_q;
    reg icx_data_last_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_data_q;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_strb_q;

    reg icx_resp_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata_q;
    reg icx_resp_error_q;

    wire address_in_range = (mem_addr_i < MEM_BYTES);
    wire [WORD_INDEX_WIDTH-1:0] word_index =
        mem_addr_i[WORD_INDEX_WIDTH+2:3];
    wire wide_address_in_range =
        (wide_addr_i >= MEM_BASE) &&
        (wide_addr_i < (MEM_BASE + MEM_BYTES)) &&
        (((wide_addr_i - MEM_BASE) & ~(WIDE_BYTES - 1)) <=
         (MEM_BYTES - WIDE_BYTES));
    wire [63:0] wide_local_addr = wide_addr_i - MEM_BASE;
    wire [63:0] wide_aligned_local_addr =
        wide_local_addr & ~(WIDE_BYTES - 1);
    wire [WORD_INDEX_WIDTH-1:0] wide_word_index =
        wide_aligned_local_addr[WORD_INDEX_WIDTH+2:3];
    wire icx_address_in_range =
        (icx_cmd_addr_q >= MEM_BASE) &&
        (icx_cmd_addr_q < (MEM_BASE + MEM_BYTES));
    wire [63:0] icx_local_addr = icx_cmd_addr_q - MEM_BASE;
    wire [WORD_INDEX_WIDTH-1:0] icx_word_index =
        icx_local_addr[WORD_INDEX_WIDTH+2:3];
    wire [WORD_INDEX_WIDTH-1:0] icx_line_word_index = {
        icx_word_index[WORD_INDEX_WIDTH-1:3], 3'b000
    };
    wire icx_command_is_write =
        (icx_cmd_op_q == `OPENRV64_ICX_OP_WRITE);
    wire icx_command_is_read =
        (icx_cmd_op_q == `OPENRV64_ICX_OP_READ);
    wire icx_command_is_fence =
        (icx_cmd_op_q == `OPENRV64_ICX_OP_FENCE);
    wire icx_execute =
        icx_cmd_pending_q && !icx_resp_valid_q &&
        !wide_pending_q &&
        (!icx_command_is_write || icx_data_pending_q);
    wire icx_identity_error = icx_command_is_write &&
        ((icx_data_hart_id_q != icx_cmd_hart_id_q) ||
         (icx_data_txn_id_q != icx_cmd_txn_id_q) ||
         (icx_data_source_id_q != icx_cmd_source_id_q));
    wire icx_geometry_error =
        (icx_cmd_burst_len_q != 0) ||
        ((icx_cmd_size_q == 3'd6) && (icx_cmd_addr_q[5:0] != 0)) ||
        (icx_cmd_size_q > 3'd6) ||
        icx_cmd_lock_q ||
        (icx_command_is_write &&
         ((icx_data_beat_index_q != 0) || !icx_data_last_q));
    wire icx_operation_error =
        !icx_command_is_read && !icx_command_is_write &&
        !icx_command_is_fence;
    wire icx_memory_error =
        !icx_command_is_fence && !icx_address_in_range;
    wire icx_request_error = icx_identity_error ||
                             icx_geometry_error ||
                             icx_operation_error ||
                             icx_memory_error;

    integer init_index;
    integer byte_index;
    integer wide_byte;
    integer wide_word;
    integer icx_byte;

    initial begin
        if ((MEM_BYTES < `OPENRV64_ICX_LINE_BYTES) ||
            ((MEM_BYTES % `OPENRV64_ICX_LINE_BYTES) != 0))
            $fatal(1, "SoC RAM size must be a positive multiple of 64 bytes");
        if ((WIDE_DATA_WIDTH < 64) || (WIDE_DATA_WIDTH > 512) ||
            ((WIDE_DATA_WIDTH % 64) != 0) ||
            ((WIDE_DATA_WIDTH & (WIDE_DATA_WIDTH - 1)) != 0))
            $fatal(1, "SoC RAM wide port must be 64 through 512 bits");
        if ((MEM_BYTES % WIDE_BYTES) != 0)
            $fatal(1, "SoC RAM size must align to the wide port");
        for (init_index = 0; init_index < WORD_COUNT;
             init_index = init_index + 1) begin
            memory_q[init_index] = 64'h0000_0000_0000_0000;
        end
    end

    wire accept_scalar_request =
        mem_valid_i && !scalar_pending_q && !wide_pending_q &&
        !wide_valid_i && !icx_execute;
    wire accept_wide_request =
        wide_valid_i && !wide_pending_q && !scalar_pending_q &&
        !icx_execute;

    assign mem_ready_o = scalar_pending_q;
    assign mem_rdata_o =
        (scalar_pending_q && !scalar_response_write_q) ?
        scalar_read_data_q : 64'h0000_0000_0000_0000;
    assign wide_ready_o = wide_pending_q;
    assign wide_rdata_o =
        (wide_pending_q && !wide_response_write_q) ?
        wide_read_data_q : {WIDE_DATA_WIDTH{1'b0}};
    assign wide_error_o = wide_pending_q && wide_error_q;

    assign icx_req_ready_o =
        rst_ni && !icx_cmd_pending_q && !icx_resp_valid_q;
    assign icx_wdata_ready_o =
        rst_ni && !icx_data_pending_q && !icx_resp_valid_q;
    assign icx_resp_valid_o = icx_resp_valid_q;
    assign icx_resp_hart_id_o = icx_resp_hart_id_q;
    assign icx_resp_txn_id_o = icx_resp_txn_id_q;
    assign icx_resp_source_id_o = icx_resp_source_id_q;
    assign icx_resp_beat_index_o =
        {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}};
    assign icx_resp_last_o = 1'b1;
    assign icx_resp_rdata_o = icx_resp_rdata_q;
    assign icx_resp_error_o = icx_resp_error_q;
    assign icx_resp_sc_success_o = 1'b0;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            scalar_pending_q <= 1'b0;
            scalar_response_write_q <= 1'b0;
            wide_pending_q <= 1'b0;
            wide_response_write_q <= 1'b0;
            wide_read_data_q <= 0;
            wide_error_q <= 1'b0;
            icx_cmd_pending_q <= 1'b0;
            icx_cmd_hart_id_q <= 0;
            icx_cmd_txn_id_q <= 0;
            icx_cmd_source_id_q <= 0;
            icx_cmd_op_q <= `OPENRV64_ICX_OP_READ;
            icx_cmd_lock_q <= 1'b0;
            icx_cmd_order_q <= `OPENRV64_ICX_ORDER_NONE;
            icx_cmd_kind_q <= `OPENRV64_ICX_KIND_LEGACY;
            icx_cmd_attr_q <= `OPENRV64_ICX_ATTR_NONE;
            icx_cmd_size_q <= 0;
            icx_cmd_addr_q <= 0;
            icx_cmd_burst_len_q <= 0;
            icx_data_pending_q <= 1'b0;
            icx_data_hart_id_q <= 0;
            icx_data_txn_id_q <= 0;
            icx_data_source_id_q <= 0;
            icx_data_beat_index_q <= 0;
            icx_data_last_q <= 1'b0;
            icx_data_q <= 0;
            icx_strb_q <= 0;
            icx_resp_valid_q <= 1'b0;
            icx_resp_hart_id_q <= 0;
            icx_resp_txn_id_q <= 0;
            icx_resp_source_id_q <= 0;
            icx_resp_rdata_q <= 0;
            icx_resp_error_q <= 1'b0;
        end else begin
            if (scalar_pending_q) begin
                scalar_pending_q <= 1'b0;
                scalar_response_write_q <= 1'b0;
            end else if (accept_scalar_request) begin
                scalar_pending_q <= 1'b1;
                scalar_response_write_q <= mem_write_i;
            end

            if (wide_pending_q) begin
                wide_pending_q <= 1'b0;
                wide_response_write_q <= 1'b0;
                wide_error_q <= 1'b0;
            end else if (accept_wide_request) begin
                wide_pending_q <= 1'b1;
                wide_response_write_q <= wide_write_i;
                wide_error_q <= !wide_address_in_range;
            end

            if (icx_resp_valid_q && icx_resp_ready_i)
                icx_resp_valid_q <= 1'b0;

            if (icx_req_valid_i && icx_req_ready_o) begin
                icx_cmd_pending_q <= 1'b1;
                icx_cmd_hart_id_q <= icx_req_hart_id_i;
                icx_cmd_txn_id_q <= icx_req_txn_id_i;
                icx_cmd_source_id_q <= icx_req_source_id_i;
                icx_cmd_op_q <= icx_req_op_i;
                icx_cmd_lock_q <= icx_req_lock_i;
                icx_cmd_order_q <= icx_req_order_i;
                icx_cmd_kind_q <= icx_req_kind_i;
                icx_cmd_attr_q <= icx_req_attr_i;
                icx_cmd_size_q <= icx_req_size_i;
                icx_cmd_addr_q <= icx_req_addr_i;
                icx_cmd_burst_len_q <= icx_req_burst_len_i;
            end

            if (icx_wdata_valid_i && icx_wdata_ready_o) begin
                icx_data_pending_q <= 1'b1;
                icx_data_hart_id_q <= icx_wdata_hart_id_i;
                icx_data_txn_id_q <= icx_wdata_txn_id_i;
                icx_data_source_id_q <= icx_wdata_source_id_i;
                icx_data_beat_index_q <= icx_wdata_beat_index_i;
                icx_data_last_q <= icx_wdata_last_i;
                icx_data_q <= icx_wdata_i;
                icx_strb_q <= icx_wstrb_i;
            end

            if (icx_execute) begin
                icx_resp_valid_q <= 1'b1;
                icx_resp_hart_id_q <= icx_cmd_hart_id_q;
                icx_resp_txn_id_q <= icx_cmd_txn_id_q;
                icx_resp_source_id_q <= icx_cmd_source_id_q;
                if (!icx_request_error && icx_command_is_read)
                    icx_resp_rdata_q <= {
                        memory_q[icx_line_word_index + 7],
                        memory_q[icx_line_word_index + 6],
                        memory_q[icx_line_word_index + 5],
                        memory_q[icx_line_word_index + 4],
                        memory_q[icx_line_word_index + 3],
                        memory_q[icx_line_word_index + 2],
                        memory_q[icx_line_word_index + 1],
                        memory_q[icx_line_word_index]
                    };
                else
                    icx_resp_rdata_q <= 0;
                icx_resp_error_q <= icx_request_error;
                icx_cmd_pending_q <= 1'b0;
                if (icx_command_is_write)
                    icx_data_pending_q <= 1'b0;
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

        if (accept_wide_request && !wide_write_i) begin
            wide_read_data_q <= 0;
            if (wide_address_in_range) begin
                for (wide_word = 0; wide_word < WIDE_WORDS;
                     wide_word = wide_word + 1)
                    wide_read_data_q[wide_word*64 +: 64] <=
                        memory_q[wide_word_index + wide_word];
            end
        end

        if (accept_wide_request && wide_write_i &&
            wide_address_in_range) begin
            for (wide_byte = 0; wide_byte < WIDE_BYTES;
                 wide_byte = wide_byte + 1) begin
                if (wide_wstrb_i[wide_byte])
                    memory_q[wide_word_index + (wide_byte / 8)]
                            [(wide_byte % 8)*8 +: 8] <=
                        wide_wdata_i[wide_byte*8 +: 8];
            end
        end

        if (icx_execute && !icx_request_error &&
            icx_command_is_write) begin
            for (icx_byte = 0;
                 icx_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
                 icx_byte = icx_byte + 1) begin
                if (icx_strb_q[icx_byte])
                    memory_q[icx_line_word_index + (icx_byte / 8)]
                            [(icx_byte % 8)*8 +: 8] <=
                        icx_data_q[icx_byte*8 +: 8];
            end
        end
    end

    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] unused_icx_order =
        icx_cmd_order_q;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] unused_icx_kind =
        icx_cmd_kind_q;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] unused_icx_attr =
        icx_cmd_attr_q;

endmodule
