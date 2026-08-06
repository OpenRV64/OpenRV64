`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

// Target-local openrv64_soc_memory implementation retained to satisfy the
// platform's inactive internal-memory instance. EXTERNAL_MEMORY_ENABLE ties
// every request input off and reduces MEM_BYTES to 64, so Vivado removes this
// storage from the MYIR design. Real scalar and PTW traffic uses MIG instead.
module openrv64_soc_memory #(
    parameter integer MEM_BYTES = 4 * 1024,
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

    (* ram_style = "block" *)
    logic [63:0] memory_q [0:WORD_COUNT-1];

    logic        scalar_pending_q;
    logic [63:0] scalar_read_data_q;

    wire scalar_accept = rst_ni && mem_valid_i && !scalar_pending_q;
    wire scalar_address_in_range = mem_addr_i < MEM_BYTES;
    wire [WORD_INDEX_WIDTH-1:0] scalar_word_index =
        mem_addr_i[WORD_INDEX_WIDTH+2:3];

    integer byte_index;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            scalar_pending_q <= 1'b0;
        else
            scalar_pending_q <= scalar_accept;
    end

    always_ff @(posedge clk_i) begin
        if (scalar_accept && scalar_address_in_range) begin
            if (mem_write_i) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (mem_wstrb_i[byte_index])
                        memory_q[scalar_word_index]
                                [byte_index*8 +: 8] <=
                            mem_wdata_i[byte_index*8 +: 8];
                end
            end else begin
                scalar_read_data_q <= memory_q[scalar_word_index];
            end
        end else if (scalar_accept) begin
            scalar_read_data_q <= 64'h0000_0000_0000_0000;
        end
    end

    assign mem_ready_o = scalar_pending_q;
    assign mem_rdata_o = scalar_read_data_q;

    assign wide_ready_o = 1'b0;
    assign wide_rdata_o = {WIDE_DATA_WIDTH{1'b0}};
    assign wide_error_o = wide_valid_i;

    assign icx_req_ready_o = 1'b0;
    assign icx_wdata_ready_o = 1'b0;
    assign icx_resp_valid_o = 1'b0;
    assign icx_resp_hart_id_o = 0;
    assign icx_resp_txn_id_o = 0;
    assign icx_resp_source_id_o = 0;
    assign icx_resp_beat_index_o = 0;
    assign icx_resp_last_o = 1'b0;
    assign icx_resp_rdata_o = 0;
    assign icx_resp_error_o = 1'b0;
    assign icx_resp_sc_success_o = 1'b0;

    wire unused_non_scalar = |{
        MEM_BASE,
        wide_write_i,
        wide_addr_i,
        wide_wdata_i,
        wide_wstrb_i,
        icx_req_valid_i,
        icx_req_hart_id_i,
        icx_req_txn_id_i,
        icx_req_source_id_i,
        icx_req_op_i,
        icx_req_lock_i,
        icx_req_order_i,
        icx_req_kind_i,
        icx_req_attr_i,
        icx_req_size_i,
        icx_req_addr_i,
        icx_req_burst_len_i,
        icx_wdata_valid_i,
        icx_wdata_hart_id_i,
        icx_wdata_txn_id_i,
        icx_wdata_source_id_i,
        icx_wdata_beat_index_i,
        icx_wdata_last_i,
        icx_wdata_i,
        icx_wstrb_i,
        icx_resp_ready_i
    };

    initial begin
        if ((MEM_BYTES < 8) || ((MEM_BYTES % 8) != 0))
            $fatal(1, "XC7 fallback RAM must be a positive multiple of 8");
    end

endmodule
