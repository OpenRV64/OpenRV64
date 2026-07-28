`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

// Blocking 1P platform memory and PTW-line adapter for the MYIR MIG native UI.
//
// MIG exposes one 256-bit application beat for each DDR3 BL8 transaction.
// Its app_addr is a 32-bit-word address, so a 32-byte UI beat advances
// app_addr by eight. Commands are aligned to that beat; scalar accesses
// select one 64-bit lane locally. PTW CCX reads collect two adjacent UI
// beats into one 64-byte protocol line.
module openrv64_mig_native_memory #(
    parameter logic [63:0] MEM_BASE = `OPENRV64_SOC_MEMORY_BASE,
    parameter integer MEM_BYTES = 512 * 1024 * 1024
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic calib_complete_i,

    input  logic        mem_valid_i,
    output logic        mem_ready_o,
    input  logic        mem_write_i,
    input  logic [63:0] mem_addr_i,
    input  logic [63:0] mem_wdata_i,
    input  logic [7:0]  mem_wstrb_i,
    output logic [63:0] mem_rdata_o,

    input  logic                         ccx_req_valid_i,
    output logic                         ccx_req_ready_o,
    input  logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                                ccx_req_hart_id_i,
    input  logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                                ccx_req_txn_id_i,
    input  logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                                ccx_req_source_id_i,
    input  logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_i,
    input  logic                         ccx_req_lock_i,
    input  logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_i,
    input  logic [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_i,
    input  logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_i,
    input  logic [2:0]                   ccx_req_size_i,
    input  logic [63:0]                  ccx_req_addr_i,
    input  logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                                ccx_req_burst_len_i,

    input  logic                         ccx_wdata_valid_i,
    output logic                         ccx_wdata_ready_o,
    input  logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                                ccx_wdata_hart_id_i,
    input  logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                                ccx_wdata_txn_id_i,
    input  logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                                ccx_wdata_source_id_i,
    input  logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                                ccx_wdata_beat_index_i,
    input  logic                         ccx_wdata_last_i,
    input  logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                                ccx_wdata_i,
    input  logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                                ccx_wstrb_i,

    output logic                         ccx_resp_valid_o,
    input  logic                         ccx_resp_ready_i,
    output logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                                ccx_resp_hart_id_o,
    output logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                                ccx_resp_txn_id_o,
    output logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                                ccx_resp_source_id_o,
    output logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                                ccx_resp_beat_index_o,
    output logic                         ccx_resp_last_o,
    output logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                                ccx_resp_rdata_o,
    output logic                         ccx_resp_error_o,
    output logic                         ccx_resp_sc_success_o,

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

    localparam logic [3:0] STATE_IDLE             = 4'd0;
    localparam logic [3:0] STATE_SCALAR_READ_CMD  = 4'd1;
    localparam logic [3:0] STATE_SCALAR_READ_DATA = 4'd2;
    localparam logic [3:0] STATE_SCALAR_WRITE     = 4'd3;
    localparam logic [3:0] STATE_SCALAR_RESP      = 4'd4;
    localparam logic [3:0] STATE_CCX_READ0_CMD    = 4'd5;
    localparam logic [3:0] STATE_CCX_READ0_DATA   = 4'd6;
    localparam logic [3:0] STATE_CCX_READ1_CMD    = 4'd7;
    localparam logic [3:0] STATE_CCX_READ1_DATA   = 4'd8;
    localparam logic [3:0] STATE_CCX_RESP         = 4'd9;

    localparam logic [2:0] MIG_CMD_WRITE = 3'b000;
    localparam logic [2:0] MIG_CMD_READ  = 3'b001;

    logic [3:0] state_q;

    logic [63:0] scalar_addr_q;
    logic [63:0] scalar_wdata_q;
    logic [7:0]  scalar_wstrb_q;
    logic [63:0] scalar_rdata_q;
    logic        scalar_write_cmd_pending_q;
    logic        scalar_write_data_pending_q;

    logic [63:0] ccx_local_addr_q;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_hart_id_q;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_txn_id_q;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_source_id_q;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_rdata_q;
    logic ccx_error_q;

    wire scalar_request_in_range =
        (mem_addr_i < MEM_BYTES) && (mem_addr_i[2:0] == 3'b000);
    wire ccx_read_address_in_range =
        (ccx_req_addr_i >= MEM_BASE) &&
        (ccx_req_addr_i <= (MEM_BASE + MEM_BYTES - 64));
    wire ccx_read_geometry_valid =
        (ccx_req_op_i == `OPENRV64_CCX_OP_READ) &&
        !ccx_req_lock_i &&
        (ccx_req_size_i == 3'd6) &&
        (ccx_req_addr_i[5:0] == 6'b000000) &&
        (ccx_req_burst_len_i == 0) &&
        ccx_read_address_in_range;
    wire ccx_fence_valid =
        (ccx_req_op_i == `OPENRV64_CCX_OP_FENCE) &&
        !ccx_req_lock_i && (ccx_req_burst_len_i == 0);

    wire [1:0] scalar_lane = scalar_addr_q[4:3];

    integer scalar_byte;
    always_comb begin
        mem_ready_o = (state_q == STATE_SCALAR_RESP);
        mem_rdata_o = scalar_rdata_q;

        ccx_req_ready_o =
            rst_ni && calib_complete_i && (state_q == STATE_IDLE);
        // The 1P core's external CCX client is the PTW. It emits reads and
        // fences, never write-data beats.
        ccx_wdata_ready_o = 1'b0;
        ccx_resp_valid_o = (state_q == STATE_CCX_RESP);
        ccx_resp_hart_id_o = ccx_hart_id_q;
        ccx_resp_txn_id_o = ccx_txn_id_q;
        ccx_resp_source_id_o = ccx_source_id_q;
        ccx_resp_beat_index_o = 0;
        ccx_resp_last_o = 1'b1;
        ccx_resp_rdata_o = ccx_rdata_q;
        ccx_resp_error_o = ccx_error_q;
        ccx_resp_sc_success_o = 1'b0;

        app_addr_o = 28'd0;
        app_cmd_o = MIG_CMD_READ;
        app_en_o = 1'b0;
        app_wdf_data_o = 256'd0;
        app_wdf_end_o = 1'b0;
        app_wdf_mask_o = 32'hffff_ffff;
        app_wdf_wren_o = 1'b0;

        for (scalar_byte = 0; scalar_byte < 8;
             scalar_byte = scalar_byte + 1) begin
            app_wdf_data_o[
                scalar_lane * 64 + scalar_byte * 8 +: 8] =
                    scalar_wdata_q[scalar_byte * 8 +: 8];
            if (scalar_wstrb_q[scalar_byte])
                app_wdf_mask_o[scalar_lane * 8 + scalar_byte] = 1'b0;
        end

        case (state_q)
            STATE_SCALAR_READ_CMD: begin
                app_addr_o = {scalar_addr_q[29:5], 3'b000};
                app_cmd_o = MIG_CMD_READ;
                app_en_o = calib_complete_i;
            end
            STATE_SCALAR_WRITE: begin
                app_addr_o = {scalar_addr_q[29:5], 3'b000};
                app_cmd_o = MIG_CMD_WRITE;
                app_en_o =
                    calib_complete_i && scalar_write_cmd_pending_q;
                app_wdf_wren_o =
                    calib_complete_i && scalar_write_data_pending_q;
                app_wdf_end_o = app_wdf_wren_o;
            end
            STATE_CCX_READ0_CMD: begin
                app_addr_o = ccx_local_addr_q[29:2];
                app_cmd_o = MIG_CMD_READ;
                app_en_o = calib_complete_i;
            end
            STATE_CCX_READ1_CMD: begin
                app_addr_o = ccx_local_addr_q[29:2] + 28'd8;
                app_cmd_o = MIG_CMD_READ;
                app_en_o = calib_complete_i;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            scalar_addr_q <= 64'd0;
            scalar_wdata_q <= 64'd0;
            scalar_wstrb_q <= 8'd0;
            scalar_rdata_q <= 64'd0;
            scalar_write_cmd_pending_q <= 1'b0;
            scalar_write_data_pending_q <= 1'b0;
            ccx_local_addr_q <= 64'd0;
            ccx_hart_id_q <= 0;
            ccx_txn_id_q <= 0;
            ccx_source_id_q <= 0;
            ccx_rdata_q <= 0;
            ccx_error_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    scalar_write_cmd_pending_q <= 1'b0;
                    scalar_write_data_pending_q <= 1'b0;

                    if (calib_complete_i && ccx_req_valid_i) begin
                        ccx_hart_id_q <= ccx_req_hart_id_i;
                        ccx_txn_id_q <= ccx_req_txn_id_i;
                        ccx_source_id_q <= ccx_req_source_id_i;
                        ccx_rdata_q <= 0;
                        ccx_error_q <= 1'b0;

                        if (ccx_read_geometry_valid) begin
                            ccx_local_addr_q <=
                                ccx_req_addr_i - MEM_BASE;
                            state_q <= STATE_CCX_READ0_CMD;
                        end else begin
                            ccx_error_q <= !ccx_fence_valid;
                            state_q <= STATE_CCX_RESP;
                        end
                    end else if (calib_complete_i && mem_valid_i) begin
                        scalar_addr_q <= mem_addr_i;
                        scalar_wdata_q <= mem_wdata_i;
                        scalar_wstrb_q <= mem_wstrb_i;
                        scalar_rdata_q <= 64'd0;

                        if (!scalar_request_in_range) begin
                            state_q <= STATE_SCALAR_RESP;
                        end else if (mem_write_i) begin
                            scalar_write_cmd_pending_q <= 1'b1;
                            scalar_write_data_pending_q <= 1'b1;
                            state_q <= STATE_SCALAR_WRITE;
                        end else begin
                            state_q <= STATE_SCALAR_READ_CMD;
                        end
                    end
                end

                STATE_SCALAR_READ_CMD: begin
                    if (app_rdy_i)
                        state_q <= STATE_SCALAR_READ_DATA;
                end

                STATE_SCALAR_READ_DATA: begin
                    if (app_rd_data_valid_i) begin
                        scalar_rdata_q <=
                            app_rd_data_i[scalar_lane * 64 +: 64];
                        state_q <= STATE_SCALAR_RESP;
                    end
                end

                STATE_SCALAR_WRITE: begin
                    if (scalar_write_cmd_pending_q && app_rdy_i)
                        scalar_write_cmd_pending_q <= 1'b0;
                    if (scalar_write_data_pending_q && app_wdf_rdy_i)
                        scalar_write_data_pending_q <= 1'b0;

                    if ((!scalar_write_cmd_pending_q || app_rdy_i) &&
                        (!scalar_write_data_pending_q || app_wdf_rdy_i))
                        state_q <= STATE_SCALAR_RESP;
                end

                STATE_SCALAR_RESP: begin
                    state_q <= STATE_IDLE;
                end

                STATE_CCX_READ0_CMD: begin
                    if (app_rdy_i)
                        state_q <= STATE_CCX_READ0_DATA;
                end

                STATE_CCX_READ0_DATA: begin
                    if (app_rd_data_valid_i) begin
                        ccx_rdata_q[255:0] <= app_rd_data_i;
                        state_q <= STATE_CCX_READ1_CMD;
                    end
                end

                STATE_CCX_READ1_CMD: begin
                    if (app_rdy_i)
                        state_q <= STATE_CCX_READ1_DATA;
                end

                STATE_CCX_READ1_DATA: begin
                    if (app_rd_data_valid_i) begin
                        ccx_rdata_q[511:256] <= app_rd_data_i;
                        state_q <= STATE_CCX_RESP;
                    end
                end

                STATE_CCX_RESP: begin
                    if (ccx_resp_ready_i)
                        state_q <= STATE_IDLE;
                end

                default: begin
                    state_q <= STATE_IDLE;
                end
            endcase
        end
    end

    wire unused_inputs = |{
        ccx_req_order_i,
        ccx_req_kind_i,
        ccx_req_attr_i,
        ccx_wdata_valid_i,
        ccx_wdata_hart_id_i,
        ccx_wdata_txn_id_i,
        ccx_wdata_source_id_i,
        ccx_wdata_beat_index_i,
        ccx_wdata_last_i,
        ccx_wdata_i,
        ccx_wstrb_i,
        app_rd_data_end_i
    };

    initial begin
        if ((MEM_BYTES < 64) || ((MEM_BYTES % 64) != 0))
            $fatal(1, "MIG memory size must be a positive multiple of 64");
        if (MEM_BYTES > (512 * 1024 * 1024))
            $fatal(1, "MYIR MIG geometry is limited to 512 MiB");
    end

endmodule
