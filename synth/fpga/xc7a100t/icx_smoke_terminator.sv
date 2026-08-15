// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Minimal one-pipe FPGA ICX endpoint. It completes PTW fence transactions so
// SATP/SFENCE barriers can retire in bare mode. Any memory request returns an
// error; Sv39 requires a real ICX-to-DDR path and is intentionally out of this
// OpenSBI-only smoke target.

`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module openrv64_fpga_icx_smoke_terminator (
    input  logic clk_i,
    input  logic reset_i,

    input  logic req_valid_i,
    output logic req_ready_o,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] req_txn_id_i,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] req_source_id_i,
    input  logic [`OPENRV64_ICX_OP_WIDTH-1:0] req_op_i,

    output logic resp_valid_o,
    input  logic resp_ready_i,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] resp_txn_id_o,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] resp_source_id_o,
    output logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] resp_beat_index_o,
    output logic resp_last_o,
    output logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] resp_rdata_o,
    output logic resp_error_o,
    output logic resp_sc_success_o
);

    logic response_valid_q;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] response_hart_id_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] response_txn_id_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] response_source_id_q;
    logic response_error_q;

    assign req_ready_o = !response_valid_q;
    assign resp_valid_o = response_valid_q;
    assign resp_hart_id_o = response_hart_id_q;
    assign resp_txn_id_o = response_txn_id_q;
    assign resp_source_id_o = response_source_id_q;
    assign resp_beat_index_o = '0;
    assign resp_last_o = 1'b1;
    assign resp_rdata_o = '0;
    assign resp_error_o = response_error_q;
    assign resp_sc_success_o = 1'b0;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            response_valid_q <= 1'b0;
            response_hart_id_q <= '0;
            response_txn_id_q <= '0;
            response_source_id_q <= '0;
            response_error_q <= 1'b0;
        end else begin
            if (response_valid_q && resp_ready_i)
                response_valid_q <= 1'b0;

            if (req_valid_i && req_ready_o) begin
                response_valid_q <= 1'b1;
                response_hart_id_q <= req_hart_id_i;
                response_txn_id_q <= req_txn_id_i;
                response_source_id_q <= req_source_id_i;
                response_error_q <= (req_op_i != `OPENRV64_ICX_OP_FENCE);
            end
        end
    end

endmodule
