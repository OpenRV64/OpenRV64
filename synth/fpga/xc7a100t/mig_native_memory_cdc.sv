`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// One-outstanding-request clock-domain bridge around the MYIR MIG adapter.
//
// The core cannot meet the 100 MHz MIG UI clock. Request payloads are held
// stable in the source domain until the corresponding response returns.
// Toggle synchronizers transfer ownership; the multi-bit payloads therefore
// have at least two destination clocks to settle before they are sampled.
module openrv64_mig_native_memory_cdc #(
    parameter logic [63:0] MEM_BASE = 64'h0000_0000_8000_0000,
    parameter integer MEM_BYTES = 512 * 1024 * 1024
) (
    input  logic core_clk_i,
    input  logic core_rst_ni,
    input  logic ui_clk_i,
    input  logic ui_rst_ni,
    input  logic calib_complete_i,

    input  logic        mem_valid_i,
    output logic        mem_ready_o,
    input  logic        mem_write_i,
    input  logic [63:0] mem_addr_i,
    input  logic [63:0] mem_wdata_i,
    input  logic [7:0]  mem_wstrb_i,
    output logic [63:0] mem_rdata_o,

    input  logic                         icx_req_valid_i,
    output logic                         icx_req_ready_o,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                                icx_req_hart_id_i,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                                icx_req_txn_id_i,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                                icx_req_source_id_i,
    input  logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_i,
    input  logic                         icx_req_lock_i,
    input  logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_i,
    input  logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_i,
    input  logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_i,
    input  logic [2:0]                   icx_req_size_i,
    input  logic [63:0]                  icx_req_addr_i,
    input  logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                                icx_req_burst_len_i,

    input  logic                         icx_wdata_valid_i,
    output logic                         icx_wdata_ready_o,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                                icx_wdata_hart_id_i,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                                icx_wdata_txn_id_i,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                                icx_wdata_source_id_i,
    input  logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                                icx_wdata_beat_index_i,
    input  logic                         icx_wdata_last_i,
    input  logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                                icx_wdata_i,
    input  logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
                                                icx_wstrb_i,

    output logic                         icx_resp_valid_o,
    input  logic                         icx_resp_ready_i,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                                icx_resp_hart_id_o,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                                icx_resp_txn_id_o,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                                icx_resp_source_id_o,
    output logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                                icx_resp_beat_index_o,
    output logic                         icx_resp_last_o,
    output logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                                icx_resp_rdata_o,
    output logic                         icx_resp_error_o,
    output logic                         icx_resp_sc_success_o,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic [255:0] app_rd_data_i,
    input  logic         app_rd_data_end_i,
    input  logic         app_rd_data_valid_i,
    input  logic         app_rdy_i,
    input  logic         app_wdf_rdy_i
);

    localparam logic [1:0] CORE_IDLE = 2'd0;
    localparam logic [1:0] CORE_WAIT = 2'd1;
    localparam logic [1:0] CORE_RESP = 2'd2;

    logic [1:0] mem_core_state_q;
    logic mem_req_toggle_core_q;
    logic mem_req_write_core_q;
    logic [63:0] mem_req_addr_core_q;
    logic [63:0] mem_req_wdata_core_q;
    logic [7:0] mem_req_wstrb_core_q;
    logic [63:0] mem_resp_rdata_ui_q;
    logic mem_resp_toggle_ui_q;
    logic mem_resp_seen_core_q;

    (* ASYNC_REG = "TRUE" *)
    logic [1:0] mem_req_sync_ui_q;
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] mem_resp_sync_core_q;
    logic mem_req_seen_ui_q;

    logic adapter_mem_ready;
    logic [63:0] adapter_mem_rdata;
    wire adapter_mem_valid =
        mem_req_sync_ui_q[1] != mem_req_seen_ui_q;

    always_comb begin
        mem_ready_o = (mem_core_state_q == CORE_RESP);
    end

    always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
        if (!core_rst_ni) begin
            mem_core_state_q <= CORE_IDLE;
            mem_req_toggle_core_q <= 1'b0;
            mem_req_write_core_q <= 1'b0;
            mem_req_addr_core_q <= 64'd0;
            mem_req_wdata_core_q <= 64'd0;
            mem_req_wstrb_core_q <= 8'd0;
            mem_resp_sync_core_q <= 2'b00;
            mem_resp_seen_core_q <= 1'b0;
            mem_rdata_o <= 64'd0;
        end else begin
            mem_resp_sync_core_q <= {
                mem_resp_sync_core_q[0], mem_resp_toggle_ui_q
            };

            case (mem_core_state_q)
                CORE_IDLE: begin
                    if (mem_valid_i) begin
                        mem_req_write_core_q <= mem_write_i;
                        mem_req_addr_core_q <= mem_addr_i;
                        mem_req_wdata_core_q <= mem_wdata_i;
                        mem_req_wstrb_core_q <= mem_wstrb_i;
                        mem_req_toggle_core_q <=
                            !mem_req_toggle_core_q;
                        mem_core_state_q <= CORE_WAIT;
                    end
                end
                CORE_WAIT: begin
                    if (mem_resp_sync_core_q[1] !=
                        mem_resp_seen_core_q) begin
                        mem_rdata_o <= mem_resp_rdata_ui_q;
                        mem_resp_seen_core_q <=
                            mem_resp_sync_core_q[1];
                        mem_core_state_q <= CORE_RESP;
                    end
                end
                CORE_RESP: begin
                    // The source observes ready during this cycle. Waiting
                    // one more edge before recapture avoids accepting the
                    // just-completed payload a second time.
                    mem_core_state_q <= CORE_IDLE;
                end
                default: mem_core_state_q <= CORE_IDLE;
            endcase
        end
    end

    always_ff @(posedge ui_clk_i or negedge ui_rst_ni) begin
        if (!ui_rst_ni) begin
            mem_req_sync_ui_q <= 2'b00;
            mem_req_seen_ui_q <= 1'b0;
            mem_resp_rdata_ui_q <= 64'd0;
            mem_resp_toggle_ui_q <= 1'b0;
        end else begin
            mem_req_sync_ui_q <= {
                mem_req_sync_ui_q[0], mem_req_toggle_core_q
            };

            if (adapter_mem_valid && adapter_mem_ready) begin
                mem_req_seen_ui_q <= mem_req_sync_ui_q[1];
                mem_resp_rdata_ui_q <= adapter_mem_rdata;
                mem_resp_toggle_ui_q <= !mem_resp_toggle_ui_q;
            end
        end
    end

    logic [1:0] icx_core_state_q;
    logic icx_req_toggle_core_q;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_req_hart_id_core_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_req_txn_id_core_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_req_source_id_core_q;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_core_q;
    logic icx_req_lock_core_q;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_core_q;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_core_q;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_core_q;
    logic [2:0] icx_req_size_core_q;
    logic [63:0] icx_req_addr_core_q;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        icx_req_burst_len_core_q;

    (* ASYNC_REG = "TRUE" *)
    logic [1:0] icx_req_sync_ui_q;
    logic icx_req_seen_ui_q;
    logic icx_resp_toggle_ui_q;
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] icx_resp_sync_core_q;
    logic icx_resp_seen_core_q;

    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_resp_hart_id_ui_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_resp_txn_id_ui_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_resp_source_id_ui_q;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        icx_resp_beat_index_ui_q;
    logic icx_resp_last_ui_q;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        icx_resp_rdata_ui_q;
    logic icx_resp_error_ui_q;
    logic icx_resp_sc_success_ui_q;

    logic adapter_icx_req_ready;
    logic adapter_icx_resp_valid;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        adapter_icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        adapter_icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        adapter_icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        adapter_icx_resp_beat_index;
    logic adapter_icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        adapter_icx_resp_rdata;
    logic adapter_icx_resp_error;
    logic adapter_icx_resp_sc_success;

    wire adapter_icx_req_valid =
        icx_req_sync_ui_q[1] != icx_req_seen_ui_q;

    always_comb begin
        icx_req_ready_o =
            core_rst_ni && (icx_core_state_q == CORE_IDLE);
        icx_wdata_ready_o = 1'b0;
        icx_resp_valid_o = (icx_core_state_q == CORE_RESP);
    end

    always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
        if (!core_rst_ni) begin
            icx_core_state_q <= CORE_IDLE;
            icx_req_toggle_core_q <= 1'b0;
            icx_req_hart_id_core_q <= '0;
            icx_req_txn_id_core_q <= '0;
            icx_req_source_id_core_q <= '0;
            icx_req_op_core_q <= '0;
            icx_req_lock_core_q <= 1'b0;
            icx_req_order_core_q <= '0;
            icx_req_kind_core_q <= '0;
            icx_req_attr_core_q <= '0;
            icx_req_size_core_q <= 3'd0;
            icx_req_addr_core_q <= 64'd0;
            icx_req_burst_len_core_q <= '0;
            icx_resp_sync_core_q <= 2'b00;
            icx_resp_seen_core_q <= 1'b0;
            icx_resp_hart_id_o <= '0;
            icx_resp_txn_id_o <= '0;
            icx_resp_source_id_o <= '0;
            icx_resp_beat_index_o <= '0;
            icx_resp_last_o <= 1'b0;
            icx_resp_rdata_o <= '0;
            icx_resp_error_o <= 1'b0;
            icx_resp_sc_success_o <= 1'b0;
        end else begin
            icx_resp_sync_core_q <= {
                icx_resp_sync_core_q[0], icx_resp_toggle_ui_q
            };

            case (icx_core_state_q)
                CORE_IDLE: begin
                    if (icx_req_valid_i) begin
                        icx_req_hart_id_core_q <= icx_req_hart_id_i;
                        icx_req_txn_id_core_q <= icx_req_txn_id_i;
                        icx_req_source_id_core_q <=
                            icx_req_source_id_i;
                        icx_req_op_core_q <= icx_req_op_i;
                        icx_req_lock_core_q <= icx_req_lock_i;
                        icx_req_order_core_q <= icx_req_order_i;
                        icx_req_kind_core_q <= icx_req_kind_i;
                        icx_req_attr_core_q <= icx_req_attr_i;
                        icx_req_size_core_q <= icx_req_size_i;
                        icx_req_addr_core_q <= icx_req_addr_i;
                        icx_req_burst_len_core_q <=
                            icx_req_burst_len_i;
                        icx_req_toggle_core_q <=
                            !icx_req_toggle_core_q;
                        icx_core_state_q <= CORE_WAIT;
                    end
                end
                CORE_WAIT: begin
                    if (icx_resp_sync_core_q[1] !=
                        icx_resp_seen_core_q) begin
                        icx_resp_seen_core_q <=
                            icx_resp_sync_core_q[1];
                        icx_resp_hart_id_o <=
                            icx_resp_hart_id_ui_q;
                        icx_resp_txn_id_o <=
                            icx_resp_txn_id_ui_q;
                        icx_resp_source_id_o <=
                            icx_resp_source_id_ui_q;
                        icx_resp_beat_index_o <=
                            icx_resp_beat_index_ui_q;
                        icx_resp_last_o <= icx_resp_last_ui_q;
                        icx_resp_rdata_o <= icx_resp_rdata_ui_q;
                        icx_resp_error_o <= icx_resp_error_ui_q;
                        icx_resp_sc_success_o <=
                            icx_resp_sc_success_ui_q;
                        icx_core_state_q <= CORE_RESP;
                    end
                end
                CORE_RESP: begin
                    if (icx_resp_ready_i)
                        icx_core_state_q <= CORE_IDLE;
                end
                default: icx_core_state_q <= CORE_IDLE;
            endcase
        end
    end

    always_ff @(posedge ui_clk_i or negedge ui_rst_ni) begin
        if (!ui_rst_ni) begin
            icx_req_sync_ui_q <= 2'b00;
            icx_req_seen_ui_q <= 1'b0;
            icx_resp_toggle_ui_q <= 1'b0;
            icx_resp_hart_id_ui_q <= '0;
            icx_resp_txn_id_ui_q <= '0;
            icx_resp_source_id_ui_q <= '0;
            icx_resp_beat_index_ui_q <= '0;
            icx_resp_last_ui_q <= 1'b0;
            icx_resp_rdata_ui_q <= '0;
            icx_resp_error_ui_q <= 1'b0;
            icx_resp_sc_success_ui_q <= 1'b0;
        end else begin
            icx_req_sync_ui_q <= {
                icx_req_sync_ui_q[0], icx_req_toggle_core_q
            };

            if (adapter_icx_req_valid && adapter_icx_req_ready)
                icx_req_seen_ui_q <= icx_req_sync_ui_q[1];

            if (adapter_icx_resp_valid) begin
                icx_resp_hart_id_ui_q <=
                    adapter_icx_resp_hart_id;
                icx_resp_txn_id_ui_q <= adapter_icx_resp_txn_id;
                icx_resp_source_id_ui_q <=
                    adapter_icx_resp_source_id;
                icx_resp_beat_index_ui_q <=
                    adapter_icx_resp_beat_index;
                icx_resp_last_ui_q <= adapter_icx_resp_last;
                icx_resp_rdata_ui_q <= adapter_icx_resp_rdata;
                icx_resp_error_ui_q <= adapter_icx_resp_error;
                icx_resp_sc_success_ui_q <=
                    adapter_icx_resp_sc_success;
                icx_resp_toggle_ui_q <= !icx_resp_toggle_ui_q;
            end
        end
    end

    openrv64_mig_native_memory #(
        .MEM_BASE(MEM_BASE),
        .MEM_BYTES(MEM_BYTES)
    ) u_native_adapter (
        .clk_i(ui_clk_i),
        .rst_ni(ui_rst_ni),
        .calib_complete_i(calib_complete_i),
        .mem_valid_i(adapter_mem_valid),
        .mem_ready_o(adapter_mem_ready),
        .mem_write_i(mem_req_write_core_q),
        .mem_addr_i(mem_req_addr_core_q),
        .mem_wdata_i(mem_req_wdata_core_q),
        .mem_wstrb_i(mem_req_wstrb_core_q),
        .mem_rdata_o(adapter_mem_rdata),
        .icx_req_valid_i(adapter_icx_req_valid),
        .icx_req_ready_o(adapter_icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id_core_q),
        .icx_req_txn_id_i(icx_req_txn_id_core_q),
        .icx_req_source_id_i(icx_req_source_id_core_q),
        .icx_req_op_i(icx_req_op_core_q),
        .icx_req_lock_i(icx_req_lock_core_q),
        .icx_req_order_i(icx_req_order_core_q),
        .icx_req_kind_i(icx_req_kind_core_q),
        .icx_req_attr_i(icx_req_attr_core_q),
        .icx_req_size_i(icx_req_size_core_q),
        .icx_req_addr_i(icx_req_addr_core_q),
        .icx_req_burst_len_i(icx_req_burst_len_core_q),
        .icx_wdata_valid_i(1'b0),
        .icx_wdata_ready_o(),
        .icx_wdata_hart_id_i('0),
        .icx_wdata_txn_id_i('0),
        .icx_wdata_source_id_i('0),
        .icx_wdata_beat_index_i('0),
        .icx_wdata_last_i(1'b0),
        .icx_wdata_i('0),
        .icx_wstrb_i('0),
        .icx_resp_valid_o(adapter_icx_resp_valid),
        .icx_resp_ready_i(1'b1),
        .icx_resp_hart_id_o(adapter_icx_resp_hart_id),
        .icx_resp_txn_id_o(adapter_icx_resp_txn_id),
        .icx_resp_source_id_o(adapter_icx_resp_source_id),
        .icx_resp_beat_index_o(adapter_icx_resp_beat_index),
        .icx_resp_last_o(adapter_icx_resp_last),
        .icx_resp_rdata_o(adapter_icx_resp_rdata),
        .icx_resp_error_o(adapter_icx_resp_error),
        .icx_resp_sc_success_o(adapter_icx_resp_sc_success),
        .app_addr_o(app_addr_o),
        .app_cmd_o(app_cmd_o),
        .app_en_o(app_en_o),
        .app_wdf_data_o(app_wdf_data_o),
        .app_wdf_end_o(app_wdf_end_o),
        .app_wdf_mask_o(app_wdf_mask_o),
        .app_wdf_wren_o(app_wdf_wren_o),
        .app_rd_data_i(app_rd_data_i),
        .app_rd_data_end_i(app_rd_data_end_i),
        .app_rd_data_valid_i(app_rd_data_valid_i),
        .app_rdy_i(app_rdy_i),
        .app_wdf_rdy_i(app_wdf_rdy_i)
    );

    wire unused_icx_wdata = |{
        icx_wdata_valid_i,
        icx_wdata_hart_id_i,
        icx_wdata_txn_id_i,
        icx_wdata_source_id_i,
        icx_wdata_beat_index_i,
        icx_wdata_last_i,
        icx_wdata_i,
        icx_wstrb_i
    };

endmodule
