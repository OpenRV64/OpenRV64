// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Blocking arbitration between the one-pipe scalar memory port and the PTW's
// native ICX line port. A PTW line read is deliberately serialized into eight
// 64-bit reads so the existing scalar CDC and MIG bridge remain the only DDR
// transaction path.

`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module openrv64_fpga_scalar_icx_arbiter #(
    parameter logic [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000,
    parameter logic [63:0] MEMORY_BYTES = 64'h0000_0000_1000_0000
) (
    input  logic clk_i,
    input  logic reset_i,

    input  logic        core_mem_valid_i,
    output logic        core_mem_ready_o,
    input  logic        core_mem_write_i,
    input  logic [63:0] core_mem_addr_i,
    input  logic [63:0] core_mem_wdata_i,
    input  logic [7:0]  core_mem_wstrb_i,
    output logic [63:0] core_mem_rdata_o,
    output logic        core_mem_error_o,

    input  logic icx_req_valid_i,
    output logic icx_req_ready_o,
    input  logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_req_hart_id_i,
    input  logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_req_txn_id_i,
    input  logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_req_source_id_i,
    input  logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_i,
    input  logic icx_req_lock_i,
    input  logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_i,
    input  logic [2:0] icx_req_size_i,
    input  logic [63:0] icx_req_addr_i,
    input  logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        icx_req_burst_len_i,

    output logic icx_resp_valid_o,
    input  logic icx_resp_ready_i,
    output logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        icx_resp_hart_id_o,
    output logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        icx_resp_txn_id_o,
    output logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        icx_resp_source_id_o,
    output logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        icx_resp_beat_index_o,
    output logic icx_resp_last_o,
    output logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        icx_resp_rdata_o,
    output logic icx_resp_error_o,
    output logic icx_resp_sc_success_o,

    output logic        mem_valid_o,
    input  logic        mem_ready_i,
    output logic        mem_write_o,
    output logic [63:0] mem_addr_o,
    output logic [63:0] mem_wdata_o,
    output logic [7:0]  mem_wstrb_o,
    input  logic [63:0] mem_rdata_i,
    input  logic        mem_error_i
);

    localparam logic [1:0] STATE_IDLE = 2'd0;
    localparam logic [1:0] STATE_CORE = 2'd1;
    localparam logic [1:0] STATE_PTW_READ = 2'd2;
    localparam logic [1:0] STATE_PTW_RESP = 2'd3;

    logic [1:0] state_q;
    logic [2:0] ptw_word_q;
    logic [21:0] ptw_line_index_q;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] ptw_line_data_q;
    logic ptw_response_error_q;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        ptw_response_hart_id_q;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        ptw_response_txn_id_q;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        ptw_response_source_id_q;

    wire request_is_read =
        icx_req_op_i == `OPENRV64_ICX_OP_READ;
    wire request_is_fence =
        icx_req_op_i == `OPENRV64_ICX_OP_FENCE;
    wire request_identity_error =
        (icx_req_source_id_i != `OPENRV64_ICX_SOURCE_PTW) ||
        (request_is_read &&
         (icx_req_kind_i != `OPENRV64_ICX_KIND_PTE));
    wire request_geometry_error =
        icx_req_lock_i || (icx_req_burst_len_i != 0) ||
        (request_is_read &&
         ((icx_req_size_i != 3'd6) || (icx_req_addr_i[5:0] != 0)));
    wire request_operation_error = !request_is_read && !request_is_fence;
    wire request_address_error = request_is_read &&
        ((icx_req_addr_i < MEMORY_BASE) ||
         (icx_req_addr_i >
          (MEMORY_BASE + MEMORY_BYTES - `OPENRV64_ICX_LINE_BYTES)));
    wire request_error = request_identity_error ||
                         request_geometry_error ||
                         request_operation_error ||
                         request_address_error;

    always_comb begin
        core_mem_ready_o = (state_q == STATE_CORE) && mem_ready_i;
        core_mem_rdata_o = (state_q == STATE_CORE) ? mem_rdata_i : 64'd0;
        core_mem_error_o = (state_q == STATE_CORE) && mem_error_i;

        // Core priority makes a fence wait behind an already-present scalar
        // request. The active 1P core otherwise cannot issue scalar traffic
        // while its PTW is walking.
        icx_req_ready_o = (state_q == STATE_IDLE) && !core_mem_valid_i;

        icx_resp_valid_o = (state_q == STATE_PTW_RESP);
        icx_resp_hart_id_o = ptw_response_hart_id_q;
        icx_resp_txn_id_o = ptw_response_txn_id_q;
        icx_resp_source_id_o = ptw_response_source_id_q;
        icx_resp_beat_index_o = '0;
        icx_resp_last_o = 1'b1;
        icx_resp_rdata_o = ptw_line_data_q;
        icx_resp_error_o = ptw_response_error_q;
        icx_resp_sc_success_o = 1'b0;

        mem_valid_o = 1'b0;
        mem_write_o = 1'b0;
        mem_addr_o = 64'd0;
        mem_wdata_o = 64'd0;
        mem_wstrb_o = 8'd0;
        if (state_q == STATE_CORE) begin
            mem_valid_o = core_mem_valid_i;
            mem_write_o = core_mem_write_i;
            mem_addr_o = core_mem_addr_i;
            mem_wdata_o = core_mem_wdata_i;
            mem_wstrb_o = core_mem_wstrb_i;
        end else if (state_q == STATE_PTW_READ) begin
            mem_valid_o = 1'b1;
            mem_addr_o = {36'd0, ptw_line_index_q, ptw_word_q, 3'b000};
        end
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= STATE_IDLE;
            ptw_word_q <= 3'd0;
            ptw_line_index_q <= '0;
            ptw_response_error_q <= 1'b0;
            ptw_response_hart_id_q <= '0;
            ptw_response_txn_id_q <= '0;
            ptw_response_source_id_q <= '0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (core_mem_valid_i) begin
                        state_q <= STATE_CORE;
                    end else if (icx_req_valid_i) begin
                        ptw_response_hart_id_q <= icx_req_hart_id_i;
                        ptw_response_txn_id_q <= icx_req_txn_id_i;
                        ptw_response_source_id_q <= icx_req_source_id_i;
                        ptw_response_error_q <= request_error;
                        ptw_word_q <= 3'd0;
                        if (request_error || request_is_fence) begin
                            state_q <= STATE_PTW_RESP;
                        end else begin
                            ptw_line_index_q <=
                                (icx_req_addr_i - MEMORY_BASE) >> 6;
                            state_q <= STATE_PTW_READ;
                        end
                    end
                end

                STATE_CORE: begin
                    if (mem_ready_i)
                        state_q <= STATE_IDLE;
                end

                STATE_PTW_READ: begin
                    if (mem_ready_i) begin
                        // Static lane enables are intentional. A variable
                        // part-select here expands into a large mux/control
                        // network in Yosys and can make the XC7A100T
                        // unplaceable. Every successful line read overwrites
                        // all eight lanes before the response is exposed.
                        case (ptw_word_q)
                            3'd0: ptw_line_data_q[63:0] <= mem_rdata_i;
                            3'd1: ptw_line_data_q[127:64] <= mem_rdata_i;
                            3'd2: ptw_line_data_q[191:128] <= mem_rdata_i;
                            3'd3: ptw_line_data_q[255:192] <= mem_rdata_i;
                            3'd4: ptw_line_data_q[319:256] <= mem_rdata_i;
                            3'd5: ptw_line_data_q[383:320] <= mem_rdata_i;
                            3'd6: ptw_line_data_q[447:384] <= mem_rdata_i;
                            default: ptw_line_data_q[511:448] <= mem_rdata_i;
                        endcase
                        ptw_response_error_q <=
                            ptw_response_error_q || mem_error_i;
                        if (ptw_word_q == 3'd7) begin
                            state_q <= STATE_PTW_RESP;
                        end else begin
                            ptw_word_q <= ptw_word_q + 3'd1;
                        end
                    end
                end

                STATE_PTW_RESP: begin
                    if (icx_resp_ready_i)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule
