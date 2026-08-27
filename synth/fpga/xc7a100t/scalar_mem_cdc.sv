// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Single-entry request/response mailbox between the slow CPU clock and MIG UI.

`timescale 1ns/1ps

module openrv64_fpga_scalar_mem_cdc (
    input  logic        core_clk_i,
    input  logic        core_reset_i,
    input  logic        core_mem_valid_i,
    output logic        core_mem_ready_o,
    input  logic        core_mem_write_i,
    input  logic [63:0] core_mem_addr_i,
    input  logic [63:0] core_mem_wdata_i,
    input  logic [7:0]  core_mem_wstrb_i,
    output logic [63:0] core_mem_rdata_o,
    output logic        core_mem_error_o,

    input  logic        ui_clk_i,
    input  logic        ui_reset_i,
    output logic        ui_req_valid_o,
    input  logic        ui_req_ready_i,
    output logic        ui_req_write_o,
    output logic [63:0] ui_req_addr_o,
    output logic [63:0] ui_req_wdata_o,
    output logic [7:0]  ui_req_wstrb_o,
    input  logic        ui_resp_valid_i,
    output logic        ui_resp_ready_o,
    input  logic [63:0] ui_resp_rdata_i,
    input  logic        ui_resp_error_i
);

    localparam logic [1:0] CORE_IDLE = 2'd0;
    localparam logic [1:0] CORE_WAIT = 2'd1;
    localparam logic [1:0] CORE_ACK  = 2'd2;

    logic [1:0] core_state_q;
    logic request_toggle_core_q;
    logic request_write_core_q;
    logic [63:0] request_addr_core_q;
    logic [63:0] request_wdata_core_q;
    logic [7:0] request_wstrb_core_q;
    logic [63:0] response_rdata_ui_q;
    logic response_error_ui_q;
    logic response_toggle_ui_q;

    (* ASYNC_REG = "TRUE" *) logic request_toggle_ui_meta_q;
    (* ASYNC_REG = "TRUE" *) logic request_toggle_ui_sync_q;
    (* ASYNC_REG = "TRUE" *) logic response_toggle_core_meta_q;
    (* ASYNC_REG = "TRUE" *) logic response_toggle_core_sync_q;

    logic request_seen_ui_q;
    logic request_pending_ui_q;
    logic request_pending_toggle_ui_q;
    logic request_write_ui_q;
    logic [63:0] request_addr_ui_q;
    logic [63:0] request_wdata_ui_q;
    logic [7:0] request_wstrb_ui_q;
    logic [63:0] response_rdata_core_q;
    logic response_error_core_q;

    assign core_mem_ready_o = (core_state_q == CORE_ACK);
    assign core_mem_rdata_o = response_rdata_core_q;
    assign core_mem_error_o = response_error_core_q;

    // Capture the held multi-bit payload into the UI domain one cycle after
    // the synchronized request toggle is observed.  The bridge only sees
    // these UI-clocked registers, never the live cross-domain payload.  The
    // source remains in CORE_WAIT until the response returns, so the payload
    // is stable throughout both toggle synchronization and this capture.
    assign ui_req_valid_o = request_pending_ui_q;
    assign ui_req_write_o = request_write_ui_q;
    assign ui_req_addr_o = request_addr_ui_q;
    assign ui_req_wdata_o = request_wdata_ui_q;
    assign ui_req_wstrb_o = request_wstrb_ui_q;
    assign ui_resp_ready_o =
        (response_toggle_ui_q != request_seen_ui_q);

    always_ff @(posedge core_clk_i) begin
        if (core_reset_i) begin
            response_toggle_core_meta_q <= 1'b0;
            response_toggle_core_sync_q <= 1'b0;
        end else begin
            response_toggle_core_meta_q <= response_toggle_ui_q;
            response_toggle_core_sync_q <= response_toggle_core_meta_q;
        end
    end

    always_ff @(posedge core_clk_i) begin
        if (core_reset_i) begin
            core_state_q <= CORE_IDLE;
            request_toggle_core_q <= 1'b0;
            request_write_core_q <= 1'b0;
            request_addr_core_q <= 64'd0;
            request_wdata_core_q <= 64'd0;
            request_wstrb_core_q <= 8'd0;
            response_rdata_core_q <= 64'd0;
            response_error_core_q <= 1'b0;
        end else begin
            case (core_state_q)
                CORE_IDLE: begin
                    if (core_mem_valid_i) begin
                        request_write_core_q <= core_mem_write_i;
                        request_addr_core_q <= core_mem_addr_i;
                        request_wdata_core_q <= core_mem_wdata_i;
                        request_wstrb_core_q <= core_mem_wstrb_i;
                        request_toggle_core_q <= ~request_toggle_core_q;
                        core_state_q <= CORE_WAIT;
                    end
                end

                CORE_WAIT: begin
                    if (response_toggle_core_sync_q ==
                        request_toggle_core_q) begin
                        response_rdata_core_q <= response_rdata_ui_q;
                        response_error_core_q <= response_error_ui_q;
                        core_state_q <= CORE_ACK;
                    end
                end

                default: core_state_q <= CORE_IDLE;
            endcase
        end
    end

    always_ff @(posedge ui_clk_i) begin
        if (ui_reset_i) begin
            request_toggle_ui_meta_q <= 1'b0;
            request_toggle_ui_sync_q <= 1'b0;
        end else begin
            request_toggle_ui_meta_q <= request_toggle_core_q;
            request_toggle_ui_sync_q <= request_toggle_ui_meta_q;
        end
    end

    always_ff @(posedge ui_clk_i) begin
        if (ui_reset_i) begin
            request_seen_ui_q <= 1'b0;
            request_pending_ui_q <= 1'b0;
            request_pending_toggle_ui_q <= 1'b0;
            request_write_ui_q <= 1'b0;
            request_addr_ui_q <= 64'd0;
            request_wdata_ui_q <= 64'd0;
            request_wstrb_ui_q <= 8'd0;
            response_toggle_ui_q <= 1'b0;
            response_rdata_ui_q <= 64'd0;
            response_error_ui_q <= 1'b0;
        end else begin
            if (!request_pending_ui_q &&
                (request_toggle_ui_sync_q != request_seen_ui_q)) begin
                request_pending_ui_q <= 1'b1;
                request_pending_toggle_ui_q <= request_toggle_ui_sync_q;
                request_write_ui_q <= request_write_core_q;
                request_addr_ui_q <= request_addr_core_q;
                request_wdata_ui_q <= request_wdata_core_q;
                request_wstrb_ui_q <= request_wstrb_core_q;
            end

            if (ui_req_valid_o && ui_req_ready_i) begin
                request_pending_ui_q <= 1'b0;
                request_seen_ui_q <= request_pending_toggle_ui_q;
            end

            if (ui_resp_valid_i && ui_resp_ready_o) begin
                response_rdata_ui_q <= ui_resp_rdata_i;
                response_error_ui_q <= ui_resp_error_i;
                response_toggle_ui_q <= request_seen_ui_q;
            end
        end
    end

endmodule
