`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Physical native-ICX transport for one hart.  Virtual addressing, PMP/PMA,
// faults, and architectural barriers belong to MTL.  This block only
// arbitrates complete physical commands from L1I, L1D, and the PTW, forwards
// L1D write data, and routes response flow control by source ID.
module openrv64_core_icx_bus (
    input  wire clk,
    input  wire rst_n,

    input  wire l1i_req_valid_i,
    output wire l1i_req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l1i_req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l1i_req_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] l1i_req_source_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] l1i_req_op_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] l1i_req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0] l1i_req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] l1i_req_attr_i,
    input  wire [2:0] l1i_req_size_i,
    input  wire [63:0] l1i_req_addr_i,
    input  wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        l1i_req_burst_len_i,

    input  wire l1d_req_valid_i,
    output wire l1d_req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l1d_req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l1d_req_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] l1d_req_source_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] l1d_req_op_i,
    input  wire l1d_req_lock_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] l1d_req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0] l1d_req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] l1d_req_attr_i,
    input  wire [2:0] l1d_req_size_i,
    input  wire [63:0] l1d_req_addr_i,
    input  wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        l1d_req_burst_len_i,

    input  wire ptw_req_valid_i,
    output wire ptw_req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ptw_req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ptw_req_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ptw_req_source_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] ptw_req_op_i,
    input  wire ptw_req_lock_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] ptw_req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0] ptw_req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] ptw_req_attr_i,
    input  wire [2:0] ptw_req_size_i,
    input  wire [63:0] ptw_req_addr_i,
    input  wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        ptw_req_burst_len_i,

    input  wire l1d_wdata_valid_i,
    output wire l1d_wdata_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] l1d_wdata_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] l1d_wdata_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        l1d_wdata_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        l1d_wdata_beat_index_i,
    input  wire l1d_wdata_last_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1d_wdata_i,
    input  wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] l1d_wstrb_i,

    output wire l1i_resp_valid_o,
    input  wire l1i_resp_ready_i,
    output wire l1d_resp_valid_o,
    input  wire l1d_resp_ready_i,
    output wire ptw_resp_valid_o,
    input  wire ptw_resp_ready_i,

    output wire icx_req_valid_o,
    input  wire icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_o,
    output wire icx_req_lock_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_o,
    output wire [2:0] icx_req_size_o,
    output wire [63:0] icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        icx_req_burst_len_o,

    output wire icx_wdata_valid_o,
    input  wire icx_wdata_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_wdata_source_id_o,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        icx_wdata_beat_index_o,
    output wire icx_wdata_last_o,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata_o,
    output wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb_o,

    input  wire icx_resp_valid_i,
    output wire icx_resp_ready_o,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id_i,

    output wire debug_grant_valid_o,
    output wire [1:0] debug_grant_client_o,
    output wire [1:0] debug_last_client_o
);

    localparam [1:0] CLIENT_ICACHE = 2'd0;
    localparam [1:0] CLIENT_DCACHE = 2'd1;
    localparam [1:0] CLIENT_PTE = 2'd2;

    reg grant_valid_q;
    reg [1:0] grant_client_q;
    reg [1:0] last_client_q;
    reg next_valid_r;
    reg [1:0] next_client_r;

    always @* begin
        next_valid_r = 1'b0;
        next_client_r = CLIENT_ICACHE;
        case (last_client_q)
            CLIENT_ICACHE: begin
                if (l1d_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_DCACHE;
                end else if (ptw_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_PTE;
                end else if (l1i_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_ICACHE;
                end
            end
            CLIENT_DCACHE: begin
                if (ptw_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_PTE;
                end else if (l1i_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_ICACHE;
                end else if (l1d_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_DCACHE;
                end
            end
            default: begin
                if (l1i_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_ICACHE;
                end else if (l1d_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_DCACHE;
                end else if (ptw_req_valid_i) begin
                    next_valid_r = 1'b1;
                    next_client_r = CLIENT_PTE;
                end
            end
        endcase
    end

    wire selected_l1d = grant_client_q == CLIENT_DCACHE;
    wire selected_ptw = grant_client_q == CLIENT_PTE;
    wire selected_valid = selected_l1d ? l1d_req_valid_i :
        selected_ptw ? ptw_req_valid_i : l1i_req_valid_i;

    assign icx_req_valid_o = grant_valid_q && selected_valid;
    assign icx_req_hart_id_o = selected_l1d ? l1d_req_hart_id_i :
        selected_ptw ? ptw_req_hart_id_i : l1i_req_hart_id_i;
    assign icx_req_txn_id_o = selected_l1d ? l1d_req_txn_id_i :
        selected_ptw ? ptw_req_txn_id_i : l1i_req_txn_id_i;
    assign icx_req_source_id_o = selected_l1d ? l1d_req_source_id_i :
        selected_ptw ? ptw_req_source_id_i : l1i_req_source_id_i;
    assign icx_req_op_o = selected_l1d ? l1d_req_op_i :
        selected_ptw ? ptw_req_op_i : l1i_req_op_i;
    assign icx_req_lock_o = selected_l1d ? l1d_req_lock_i :
        selected_ptw ? ptw_req_lock_i : 1'b0;
    assign icx_req_order_o = selected_l1d ? l1d_req_order_i :
        selected_ptw ? ptw_req_order_i : l1i_req_order_i;
    assign icx_req_kind_o = selected_l1d ? l1d_req_kind_i :
        selected_ptw ? ptw_req_kind_i : l1i_req_kind_i;
    assign icx_req_attr_o = selected_l1d ? l1d_req_attr_i :
        selected_ptw ? ptw_req_attr_i : l1i_req_attr_i;
    assign icx_req_size_o = selected_l1d ? l1d_req_size_i :
        selected_ptw ? ptw_req_size_i : l1i_req_size_i;
    assign icx_req_addr_o = selected_l1d ? l1d_req_addr_i :
        selected_ptw ? ptw_req_addr_i : l1i_req_addr_i;
    assign icx_req_burst_len_o = selected_l1d ? l1d_req_burst_len_i :
        selected_ptw ? ptw_req_burst_len_i : l1i_req_burst_len_i;

    assign l1d_req_ready_o = grant_valid_q && selected_l1d &&
                             icx_req_ready_i;
    assign l1i_req_ready_o = grant_valid_q && !selected_l1d &&
                             !selected_ptw && icx_req_ready_i;
    assign ptw_req_ready_o = grant_valid_q && selected_ptw &&
                             icx_req_ready_i;

    // Only L1D emits write-data beats in the current protocol.
    assign icx_wdata_valid_o = l1d_wdata_valid_i;
    assign l1d_wdata_ready_o = icx_wdata_ready_i;
    assign icx_wdata_hart_id_o = l1d_wdata_hart_id_i;
    assign icx_wdata_txn_id_o = l1d_wdata_txn_id_i;
    assign icx_wdata_source_id_o = l1d_wdata_source_id_i;
    assign icx_wdata_beat_index_o = l1d_wdata_beat_index_i;
    assign icx_wdata_last_o = l1d_wdata_last_i;
    assign icx_wdata_o = l1d_wdata_i;
    assign icx_wstrb_o = l1d_wstrb_i;

    assign l1d_resp_valid_o = icx_resp_valid_i &&
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_DCACHE);
    assign l1i_resp_valid_o = icx_resp_valid_i &&
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_ICACHE);
    assign ptw_resp_valid_o = icx_resp_valid_i &&
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_PTW);
    assign icx_resp_ready_o =
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_DCACHE) ?
            l1d_resp_ready_i :
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_ICACHE) ?
            l1i_resp_ready_i :
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_PTW) ?
            ptw_resp_ready_i : 1'b0;

    assign debug_grant_valid_o = grant_valid_q;
    assign debug_grant_client_o = grant_client_q;
    assign debug_last_client_o = last_client_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_valid_q <= 1'b0;
            grant_client_q <= CLIENT_ICACHE;
            last_client_q <= CLIENT_PTE;
        end else begin
            if (grant_valid_q) begin
                if (icx_req_valid_o && icx_req_ready_i) begin
                    grant_valid_q <= 1'b0;
                    last_client_q <= grant_client_q;
                end else if (!selected_valid) begin
                    grant_valid_q <= next_valid_r;
                    if (next_valid_r)
                        grant_client_q <= next_client_r;
                end
            end else if (next_valid_r) begin
                grant_valid_q <= 1'b1;
                grant_client_q <= next_client_r;
            end
        end
    end

endmodule
