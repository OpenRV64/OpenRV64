// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Destructive, bounded memory test for the Xilinx 7-series MIG native UI.

`timescale 1ns/1ps

module openrv64_fpga_ddr3_memtest #(
    parameter integer ADDR_WIDTH     = 28,
    parameter logic [ADDR_WIDTH-1:0] LAST_ADDR = 28'h7ff_fff8,
    parameter integer TIMEOUT_CYCLES = 100_000_000
) (
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  logic                  calib_complete_i,

    output logic [ADDR_WIDTH-1:0] app_addr_o,
    output logic [2:0]            app_cmd_o,
    output logic                  app_en_o,
    input  logic                  app_rdy_i,
    output logic [255:0]          app_wdf_data_o,
    output logic                  app_wdf_end_o,
    output logic [31:0]           app_wdf_mask_o,
    output logic                  app_wdf_wren_o,
    input  logic                  app_wdf_rdy_i,
    input  logic [255:0]          app_rd_data_i,
    input  logic                  app_rd_data_end_i,
    input  logic                  app_rd_data_valid_i,

    output logic [2:0]            status_o,
    output logic [ADDR_WIDTH-1:0] fail_addr_o,
    output logic [2:0]            fail_lane_o,
    output logic [31:0]           fail_expected_o,
    output logic [31:0]           fail_actual_o,
    output logic [2:0]            fail_reason_o
);

    localparam logic [2:0] STATUS_WAIT = 3'd0;
    localparam logic [2:0] STATUS_P0W  = 3'd1;
    localparam logic [2:0] STATUS_P0R  = 3'd2;
    localparam logic [2:0] STATUS_P1W  = 3'd3;
    localparam logic [2:0] STATUS_P1R  = 3'd4;
    localparam logic [2:0] STATUS_PASS = 3'd5;
    localparam logic [2:0] STATUS_FAIL = 3'd6;

    localparam logic [2:0] FAIL_COMPARE       = 3'd1;
    localparam logic [2:0] FAIL_READ_END      = 3'd2;
    localparam logic [2:0] FAIL_UNEXPECTED_RD = 3'd3;
    localparam logic [2:0] FAIL_CALIB_LOST    = 3'd4;
    localparam logic [2:0] FAIL_TIMEOUT       = 3'd5;

    localparam integer TIMEOUT_COUNT_W =
        (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam logic [TIMEOUT_COUNT_W-1:0] TIMEOUT_LIMIT =
        TIMEOUT_CYCLES[TIMEOUT_COUNT_W-1:0] - 1'b1;

    typedef enum logic [2:0] {
        ST_WAIT,
        ST_WRITE,
        ST_READ_CMD,
        ST_READ_DATA,
        ST_PASS,
        ST_FAIL
    } state_t;

    state_t state_q;
    logic [ADDR_WIDTH-1:0] address_q;
    logic phase_q;
    logic write_cmd_done_q;
    logic write_data_done_q;
    logic [TIMEOUT_COUNT_W-1:0] timeout_count_q;

    function automatic logic [255:0] test_pattern(
        input logic [ADDR_WIDTH-1:0] address,
        input logic                  invert
    );
        integer lane;
        logic [31:0] address_word;
        logic [31:0] lane_word;
        begin
            address_word = {{(32-ADDR_WIDTH){1'b0}}, address};
            for (lane = 0; lane < 8; lane = lane + 1) begin
                lane_word = address_word ^
                    (32'h9e37_79b9 ^ (32'h1111_1111 * lane));
                test_pattern[(lane * 32) +: 32] =
                    invert ? ~lane_word : lane_word;
            end
        end
    endfunction

    function automatic logic [2:0] first_bad_lane(
        input logic [255:0] expected,
        input logic [255:0] actual
    );
        integer lane;
        logic found;
        begin
            first_bad_lane = 3'd0;
            found = 1'b0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                if (!found &&
                    (expected[(lane * 32) +: 32] !=
                     actual[(lane * 32) +: 32])) begin
                    first_bad_lane = lane[2:0];
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [31:0] selected_word(
        input logic [255:0] data,
        input logic [2:0]   lane
    );
        begin
            case (lane)
                3'd0: selected_word = data[31:0];
                3'd1: selected_word = data[63:32];
                3'd2: selected_word = data[95:64];
                3'd3: selected_word = data[127:96];
                3'd4: selected_word = data[159:128];
                3'd5: selected_word = data[191:160];
                3'd6: selected_word = data[223:192];
                default: selected_word = data[255:224];
            endcase
        end
    endfunction

    wire [255:0] expected_data = test_pattern(address_q, phase_q);
    wire write_cmd_accept =
        (state_q == ST_WRITE) && !write_cmd_done_q && app_rdy_i;
    wire write_data_accept =
        (state_q == ST_WRITE) && !write_data_done_q && app_wdf_rdy_i;
    wire write_complete =
        (write_cmd_done_q || write_cmd_accept) &&
        (write_data_done_q || write_data_accept);
    wire read_cmd_accept = (state_q == ST_READ_CMD) && app_rdy_i;
    wire transaction_progress =
        write_cmd_accept || write_data_accept || read_cmd_accept ||
        ((state_q == ST_READ_DATA) && app_rd_data_valid_i);
    wire timeout_hit =
        ((state_q == ST_WRITE) || (state_q == ST_READ_CMD) ||
         (state_q == ST_READ_DATA)) &&
        !transaction_progress &&
        (timeout_count_q == TIMEOUT_LIMIT);

    always_comb begin
        app_addr_o     = address_q;
        app_cmd_o      = 3'b000;
        app_en_o       = 1'b0;
        app_wdf_data_o = expected_data;
        app_wdf_end_o  = 1'b1;
        app_wdf_mask_o = 32'h0000_0000;
        app_wdf_wren_o = 1'b0;

        case (state_q)
            ST_WRITE: begin
                app_cmd_o      = 3'b000;
                app_en_o       = !write_cmd_done_q;
                app_wdf_wren_o = !write_data_done_q;
            end
            ST_READ_CMD: begin
                app_cmd_o = 3'b001;
                app_en_o  = 1'b1;
            end
            default: begin
            end
        endcase

        case (state_q)
            ST_WAIT: status_o = STATUS_WAIT;
            ST_WRITE: status_o = phase_q ? STATUS_P1W : STATUS_P0W;
            ST_READ_CMD,
            ST_READ_DATA: status_o = phase_q ? STATUS_P1R : STATUS_P0R;
            ST_PASS: status_o = STATUS_PASS;
            default: status_o = STATUS_FAIL;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q             <= ST_WAIT;
            address_q           <= '0;
            phase_q             <= 1'b0;
            write_cmd_done_q    <= 1'b0;
            write_data_done_q   <= 1'b0;
            timeout_count_q     <= '0;
            fail_addr_o         <= '0;
            fail_lane_o         <= 3'd0;
            fail_expected_o     <= 32'h0000_0000;
            fail_actual_o       <= 32'h0000_0000;
            fail_reason_o       <= 3'd0;
        end else if ((state_q != ST_WAIT) &&
                     (state_q != ST_PASS) &&
                     (state_q != ST_FAIL) &&
                     !calib_complete_i) begin
            state_q         <= ST_FAIL;
            fail_addr_o     <= address_q;
            fail_reason_o   <= FAIL_CALIB_LOST;
            timeout_count_q <= '0;
        end else if (app_rd_data_valid_i && (state_q != ST_READ_DATA)) begin
            state_q         <= ST_FAIL;
            fail_addr_o     <= address_q;
            fail_actual_o   <= app_rd_data_i[31:0];
            fail_reason_o   <= FAIL_UNEXPECTED_RD;
            timeout_count_q <= '0;
        end else if (timeout_hit) begin
            state_q         <= ST_FAIL;
            fail_addr_o     <= address_q;
            fail_reason_o   <= FAIL_TIMEOUT;
            timeout_count_q <= '0;
        end else begin
            if (((state_q == ST_WRITE) || (state_q == ST_READ_CMD) ||
                 (state_q == ST_READ_DATA)) && !transaction_progress) begin
                timeout_count_q <= timeout_count_q + 1'b1;
            end else begin
                timeout_count_q <= '0;
            end

            case (state_q)
                ST_WAIT: begin
                    if (calib_complete_i) begin
                        state_q           <= ST_WRITE;
                        address_q         <= '0;
                        phase_q           <= 1'b0;
                        write_cmd_done_q  <= 1'b0;
                        write_data_done_q <= 1'b0;
                    end
                end

                ST_WRITE: begin
                    if (write_complete) begin
                        write_cmd_done_q  <= 1'b0;
                        write_data_done_q <= 1'b0;
                        if (address_q == LAST_ADDR) begin
                            address_q <= '0;
                            state_q   <= ST_READ_CMD;
                        end else begin
                            address_q <= address_q + 8;
                        end
                    end else begin
                        if (write_cmd_accept)
                            write_cmd_done_q <= 1'b1;
                        if (write_data_accept)
                            write_data_done_q <= 1'b1;
                    end
                end

                ST_READ_CMD: begin
                    if (read_cmd_accept)
                        state_q <= ST_READ_DATA;
                end

                ST_READ_DATA: begin
                    if (app_rd_data_valid_i) begin
                        if (!app_rd_data_end_i) begin
                            state_q         <= ST_FAIL;
                            fail_addr_o     <= address_q;
                            fail_expected_o <= expected_data[31:0];
                            fail_actual_o   <= app_rd_data_i[31:0];
                            fail_reason_o   <= FAIL_READ_END;
                        end else if (app_rd_data_i != expected_data) begin
                            state_q         <= ST_FAIL;
                            fail_addr_o     <= address_q;
                            fail_lane_o     <= first_bad_lane(
                                expected_data, app_rd_data_i);
                            fail_expected_o <= selected_word(
                                expected_data,
                                first_bad_lane(expected_data, app_rd_data_i));
                            fail_actual_o   <= selected_word(
                                app_rd_data_i,
                                first_bad_lane(expected_data, app_rd_data_i));
                            fail_reason_o   <= FAIL_COMPARE;
                        end else if (address_q == LAST_ADDR) begin
                            if (phase_q) begin
                                state_q <= ST_PASS;
                            end else begin
                                phase_q   <= 1'b1;
                                address_q <= '0;
                                state_q   <= ST_WRITE;
                            end
                        end else begin
                            address_q <= address_q + 8;
                            state_q   <= ST_READ_CMD;
                        end
                    end
                end

                default: begin
                    state_q <= state_q;
                end
            endcase
        end
    end

endmodule
