// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// One-request blocking 64-bit memory port onto the 256-bit native MIG UI.

`timescale 1ns/1ps

module openrv64_fpga_mig_scalar_bridge #(
    parameter logic [63:0] MEMORY_BYTES = 64'h0000_0000_1000_0000
) (
    input  logic         clk_i,
    input  logic         reset_i,
    input  logic         calib_complete_i,

    input  logic         req_valid_i,
    output logic         req_ready_o,
    input  logic         req_write_i,
    input  logic [63:0]  req_addr_i,
    input  logic [63:0]  req_wdata_i,
    input  logic [7:0]   req_wstrb_i,

    output logic         resp_valid_o,
    input  logic         resp_ready_i,
    output logic [63:0]  resp_rdata_o,
    output logic         resp_error_o,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    input  logic         app_rdy_i,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic         app_wdf_rdy_i,
    input  logic [255:0] app_rd_data_i,
    input  logic         app_rd_data_end_i,
    input  logic         app_rd_data_valid_i
);

    localparam logic [2:0] STATE_IDLE     = 3'd0;
    localparam logic [2:0] STATE_WRITE    = 3'd1;
    localparam logic [2:0] STATE_READ_CMD = 3'd2;
    localparam logic [2:0] STATE_READ_DATA = 3'd3;
    localparam logic [2:0] STATE_RESPONSE = 3'd4;

    logic [2:0] state_q;
    logic [63:0] addr_q;
    logic [63:0] wdata_q;
    logic [7:0] wstrb_q;
    logic command_sent_q;
    logic data_sent_q;
    logic [63:0] response_data_q;
    logic response_error_q;

    wire request_in_range = req_addr_i < MEMORY_BYTES;
    wire command_fire = app_en_o && app_rdy_i;
    wire data_fire = app_wdf_wren_o && app_wdf_rdy_i;
    wire write_complete = (command_sent_q || command_fire) &&
                          (data_sent_q || data_fire);

    integer byte_index;
    always_comb begin
        req_ready_o = (state_q == STATE_IDLE);
        resp_valid_o = (state_q == STATE_RESPONSE);
        resp_rdata_o = response_data_q;
        resp_error_o = response_error_q;

        app_addr_o = {addr_q[29:5], 3'b000};
        app_cmd_o = (state_q == STATE_WRITE) ? 3'b000 : 3'b001;
        app_en_o = ((state_q == STATE_WRITE) && !command_sent_q) ||
                   (state_q == STATE_READ_CMD);
        app_wdf_data_o = 256'd0;
        app_wdf_mask_o = 32'hffff_ffff;
        for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
            app_wdf_data_o[(addr_q[4:3] * 64) +
                           (byte_index * 8) +: 8] =
                wdata_q[(byte_index * 8) +: 8];
            app_wdf_mask_o[(addr_q[4:3] * 8) + byte_index] =
                ~wstrb_q[byte_index];
        end
        app_wdf_wren_o = (state_q == STATE_WRITE) && !data_sent_q;
        app_wdf_end_o = app_wdf_wren_o;
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= STATE_IDLE;
            addr_q <= 64'd0;
            wdata_q <= 64'd0;
            wstrb_q <= 8'd0;
            command_sent_q <= 1'b0;
            data_sent_q <= 1'b0;
            response_data_q <= 64'd0;
            response_error_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    command_sent_q <= 1'b0;
                    data_sent_q <= 1'b0;
                    if (req_valid_i) begin
                        addr_q <= req_addr_i;
                        wdata_q <= req_wdata_i;
                        wstrb_q <= req_wstrb_i;
                        response_data_q <= 64'd0;
                        response_error_q <= 1'b0;
                        if (!request_in_range || !calib_complete_i) begin
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else if (req_write_i) begin
                            state_q <= STATE_WRITE;
                        end else begin
                            state_q <= STATE_READ_CMD;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (write_complete) begin
                        command_sent_q <= 1'b0;
                        data_sent_q <= 1'b0;
                        state_q <= STATE_RESPONSE;
                    end else begin
                        if (command_fire)
                            command_sent_q <= 1'b1;
                        if (data_fire)
                            data_sent_q <= 1'b1;
                    end
                end

                STATE_READ_CMD: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (command_fire) begin
                        state_q <= STATE_READ_DATA;
                    end
                end

                STATE_READ_DATA: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (app_rd_data_valid_i) begin
                        case (addr_q[4:3])
                            2'd0: response_data_q <= app_rd_data_i[63:0];
                            2'd1: response_data_q <= app_rd_data_i[127:64];
                            2'd2: response_data_q <= app_rd_data_i[191:128];
                            default: response_data_q <= app_rd_data_i[255:192];
                        endcase
                        response_error_q <= !app_rd_data_end_i;
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (resp_ready_i)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule
