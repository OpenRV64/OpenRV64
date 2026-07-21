`timescale 1ns/1ps

// WISHBONE Revision B.4 master.  It emits one Classic cycle at a time while
// honoring the B.4 pipelined STALL acceptance rule.  RTY terminates the
// attempt and is automatically reissued after a one-cycle bus-idle gap.
module openrv64_complex_wishbone_backend #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer ADDR_SHIFT = $clog2(DATA_WIDTH / 8),
    parameter integer MAX_RETRIES = 8
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire                      req_write_i,
    input  wire [63:0]               req_addr_i,
    input  wire [2:0]                req_size_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    input  wire                      req_cacheable_i,

    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [DATA_WIDTH-1:0]     resp_rdata_o,
    output wire                      resp_error_o,

    output wire                      wb_cyc_o,
    output wire                      wb_stb_o,
    output wire                      wb_we_o,
    output wire [ADDR_WIDTH-1:0]     wb_adr_o,
    output wire [DATA_WIDTH-1:0]     wb_dat_o,
    output wire [DATA_WIDTH/8-1:0]   wb_sel_o,
    output wire [2:0]                wb_cti_o,
    output wire [1:0]                wb_bte_o,
    output wire                      wb_lock_o,
    input  wire                      wb_stall_i,
    input  wire                      wb_ack_i,
    input  wire                      wb_err_i,
    input  wire                      wb_rty_i,
    input  wire [DATA_WIDTH-1:0]     wb_dat_i
);

    localparam [2:0] STATE_IDLE      = 3'd0;
    localparam [2:0] STATE_ISSUE     = 3'd1;
    localparam [2:0] STATE_WAIT      = 3'd2;
    localparam [2:0] STATE_RETRY_GAP = 3'd3;
    localparam [2:0] STATE_RESPONSE  = 3'd4;
    localparam integer RETRY_WIDTH =
        (MAX_RETRIES < 2) ? 1 : $clog2(MAX_RETRIES + 1);

    reg [2:0] state_q;
    reg request_write_q;
    reg [63:0] request_addr_q;
    reg [DATA_WIDTH-1:0] request_wdata_q;
    reg [DATA_WIDTH/8-1:0] request_wstrb_q;
    reg [DATA_WIDTH-1:0] response_data_q;
    reg response_error_q;
    reg [RETRY_WIDTH-1:0] retry_count_q;

    wire request_fire = req_valid_i && req_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;
    wire issue_accepted = (state_q == STATE_ISSUE) && !wb_stall_i;
    wire termination_conflict = (wb_ack_i && wb_err_i) ||
                                (wb_ack_i && wb_rty_i) ||
                                (wb_err_i && wb_rty_i);

    assign req_ready_o = (state_q == STATE_IDLE);
    assign resp_valid_o = (state_q == STATE_RESPONSE);
    assign resp_rdata_o = response_data_q;
    assign resp_error_o = response_error_q;

    assign wb_cyc_o = (state_q == STATE_ISSUE) || (state_q == STATE_WAIT);
    assign wb_stb_o = (state_q == STATE_ISSUE);
    assign wb_we_o = request_write_q;
    assign wb_adr_o = request_addr_q >> ADDR_SHIFT;
    assign wb_dat_o = request_wdata_q;
    assign wb_sel_o = request_wstrb_q;
    assign wb_cti_o = 3'b000;
    assign wb_bte_o = 2'b00;
    assign wb_lock_o = 1'b0;

    initial begin
        if ((ADDR_WIDTH < 1) || (ADDR_WIDTH > 64))
            $fatal(1, "WISHBONE address width must be from 1 through 64");
        if ((DATA_WIDTH < 32) || (DATA_WIDTH > 64) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "WISHBONE B.4 data width must be 32 or 64 bits");
        if ((ADDR_SHIFT < 0) || (ADDR_SHIFT > 63))
            $fatal(1, "WISHBONE address shift must be from 0 through 63");
        if (MAX_RETRIES < 0)
            $fatal(1, "WISHBONE retry limit cannot be negative");
    end

    task automatic finish_attempt;
        input normal_ack;
        input bus_error;
        input retry;
        begin
            if (termination_conflict) begin
                response_data_q <= {DATA_WIDTH{1'b0}};
                response_error_q <= 1'b1;
                state_q <= STATE_RESPONSE;
            end else if (normal_ack) begin
                response_data_q <= wb_dat_i;
                response_error_q <= 1'b0;
                state_q <= STATE_RESPONSE;
            end else if (bus_error) begin
                response_data_q <= {DATA_WIDTH{1'b0}};
                response_error_q <= 1'b1;
                state_q <= STATE_RESPONSE;
            end else if (retry) begin
                if ((MAX_RETRIES != 0) &&
                    (retry_count_q == RETRY_WIDTH'(MAX_RETRIES))) begin
                    response_data_q <= {DATA_WIDTH{1'b0}};
                    response_error_q <= 1'b1;
                    state_q <= STATE_RESPONSE;
                end else begin
                    retry_count_q <= retry_count_q + 1'b1;
                    state_q <= STATE_RETRY_GAP;
                end
            end
        end
    endtask

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            request_write_q <= 1'b0;
            request_addr_q <= 64'd0;
            request_wdata_q <= {DATA_WIDTH{1'b0}};
            request_wstrb_q <= {DATA_WIDTH/8{1'b0}};
            response_data_q <= {DATA_WIDTH{1'b0}};
            response_error_q <= 1'b0;
            retry_count_q <= {RETRY_WIDTH{1'b0}};
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    response_error_q <= 1'b0;
                    if (request_fire) begin
                        request_write_q <= req_write_i;
                        request_addr_q <= req_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        retry_count_q <= {RETRY_WIDTH{1'b0}};
                        state_q <= STATE_ISSUE;
                    end
                end

                STATE_ISSUE: begin
                    if (issue_accepted) begin
                        if (wb_ack_i || wb_err_i || wb_rty_i)
                            finish_attempt(wb_ack_i, wb_err_i, wb_rty_i);
                        else
                            state_q <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (wb_ack_i || wb_err_i || wb_rty_i)
                        finish_attempt(wb_ack_i, wb_err_i, wb_rty_i);
                end

                STATE_RETRY_GAP: state_q <= STATE_ISSUE;

                STATE_RESPONSE: begin
                    if (response_fire)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

    wire [2:0] unused_req_size = req_size_i;
    wire unused_req_cacheable = req_cacheable_i;

endmodule
