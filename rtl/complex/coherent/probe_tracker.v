`timescale 1ns/1ps
`include "complex/coherent/protocol/defs.v"

// One bounded invalidation transaction.  Requests to different harts are
// independent valid/ready lanes; completion is withheld until every target
// has accepted its probe and returned the matching acknowledgement.
//
// This intentionally permits only one active invalidation.  It establishes
// the probe/ACK correctness contract before the coherent L2 adds multiple
// per-line home transactions.
module openrv64_icx_probe_tracker #(
    parameter integer NUM_HARTS = 2
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         start_valid_i,
    output wire                         start_ready_o,
    input  wire [NUM_HARTS-1:0]         start_target_harts_i,
    input  wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               start_probe_id_i,
    input  wire [`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0]
                                               start_command_i,
    input  wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
                                               start_cache_mask_i,
    input  wire [63:0]                  start_line_addr_i,

    output wire [NUM_HARTS-1:0]         probe_valid_o,
    input  wire [NUM_HARTS-1:0]         probe_ready_i,
    output reg  [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_id_o,
    output reg  [NUM_HARTS*`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0]
                                               probe_command_o,
    output reg  [NUM_HARTS*`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_o,
    output reg  [NUM_HARTS*64-1:0]      probe_line_addr_o,

    input  wire [NUM_HARTS-1:0]         probe_ack_valid_i,
    output wire [NUM_HARTS-1:0]         probe_ack_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_ack_id_i,

    output wire                         busy_o,
    output wire                         done_valid_o,
    input  wire                         done_ready_i,
    output wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               done_probe_id_o,

    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o
);

    reg busy_q;
    reg busy_d;
    reg done_valid_q;
    reg done_valid_d;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] done_probe_id_q;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] done_probe_id_d;
    reg protocol_error_q;
    reg protocol_error_d;

    reg [NUM_HARTS-1:0] issue_pending_q;
    reg [NUM_HARTS-1:0] issue_pending_d;
    reg [NUM_HARTS-1:0] ack_pending_q;
    reg [NUM_HARTS-1:0] ack_pending_d;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] probe_id_q;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] probe_id_d;
    reg [`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0] command_q;
    reg [`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0] command_d;
    reg [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0] cache_mask_q;
    reg [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0] cache_mask_d;
    reg [63:0] line_addr_q;
    reg [63:0] line_addr_d;

    integer output_hart_index;
    integer state_hart_index;

    wire start_fire = start_valid_i && start_ready_o;

    assign start_ready_o = !busy_q && !done_valid_q;
    assign probe_valid_o = issue_pending_q;
    // Always consume ACK traffic.  An ACK without a matching accepted probe
    // is reported and discarded instead of remaining live long enough to be
    // mistaken for a later transaction.
    assign probe_ack_ready_o = {NUM_HARTS{1'b1}};
    assign busy_o = busy_q;
    assign done_valid_o = done_valid_q;
    assign done_probe_id_o = done_probe_id_q;
    assign protocol_error_o = protocol_error_q;

    always @* begin
        probe_id_o =
            {NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH{1'b0}};
        probe_command_o =
            {NUM_HARTS*`OPENRV64_ICX_PROBE_CMD_WIDTH{1'b0}};
        probe_cache_mask_o =
            {NUM_HARTS*`OPENRV64_ICX_PROBE_CACHE_WIDTH{1'b0}};
        probe_line_addr_o = {NUM_HARTS*64{1'b0}};
        for (output_hart_index = 0; output_hart_index < NUM_HARTS;
             output_hart_index = output_hart_index + 1) begin
            probe_id_o[
                output_hart_index*`OPENRV64_ICX_PROBE_ID_WIDTH +:
                `OPENRV64_ICX_PROBE_ID_WIDTH] = probe_id_q;
            probe_command_o[
                output_hart_index*`OPENRV64_ICX_PROBE_CMD_WIDTH +:
                `OPENRV64_ICX_PROBE_CMD_WIDTH] = command_q;
            probe_cache_mask_o[
                output_hart_index*`OPENRV64_ICX_PROBE_CACHE_WIDTH +:
                `OPENRV64_ICX_PROBE_CACHE_WIDTH] = cache_mask_q;
            probe_line_addr_o[output_hart_index*64 +: 64] = line_addr_q;
        end
    end

    always @* begin
        busy_d = busy_q;
        done_valid_d = done_valid_q;
        done_probe_id_d = done_probe_id_q;
        protocol_error_d = protocol_error_q;
        issue_pending_d = issue_pending_q;
        ack_pending_d = ack_pending_q;
        probe_id_d = probe_id_q;
        command_d = command_q;
        cache_mask_d = cache_mask_q;
        line_addr_d = line_addr_q;

        if (protocol_error_clear_i)
            protocol_error_d = 1'b0;
        if (done_valid_q && done_ready_i)
            done_valid_d = 1'b0;

        if (start_fire) begin
            busy_d = 1'b1;
            issue_pending_d = start_target_harts_i;
            ack_pending_d = {NUM_HARTS{1'b0}};
            probe_id_d = start_probe_id_i;
            command_d = start_command_i;
            cache_mask_d = start_cache_mask_i;
            line_addr_d = start_line_addr_i;
            if (|start_line_addr_i[5:0])
                protocol_error_d = 1'b1;
        end else if (busy_q) begin
            for (state_hart_index = 0; state_hart_index < NUM_HARTS;
                 state_hart_index = state_hart_index + 1) begin
                if (issue_pending_q[state_hart_index] &&
                    probe_ready_i[state_hart_index]) begin
                    issue_pending_d[state_hart_index] = 1'b0;
                    ack_pending_d[state_hart_index] = 1'b1;
                end

                if (probe_ack_valid_i[state_hart_index]) begin
                    if ((ack_pending_q[state_hart_index] ||
                         (issue_pending_q[state_hart_index] &&
                          probe_ready_i[state_hart_index])) &&
                        (probe_ack_id_i[
                            state_hart_index*
                            `OPENRV64_ICX_PROBE_ID_WIDTH +:
                            `OPENRV64_ICX_PROBE_ID_WIDTH] ==
                         probe_id_q)) begin
                        ack_pending_d[state_hart_index] = 1'b0;
                    end else begin
                        protocol_error_d = 1'b1;
                    end
                end
            end

            if ((issue_pending_d == {NUM_HARTS{1'b0}}) &&
                (ack_pending_d == {NUM_HARTS{1'b0}})) begin
                busy_d = 1'b0;
                done_valid_d = 1'b1;
                done_probe_id_d = probe_id_q;
            end
        end else if (|probe_ack_valid_i) begin
            protocol_error_d = 1'b1;
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy_q <= 1'b0;
            done_valid_q <= 1'b0;
            done_probe_id_q <=
                {`OPENRV64_ICX_PROBE_ID_WIDTH{1'b0}};
            protocol_error_q <= 1'b0;
            issue_pending_q <= {NUM_HARTS{1'b0}};
            ack_pending_q <= {NUM_HARTS{1'b0}};
            probe_id_q <= {`OPENRV64_ICX_PROBE_ID_WIDTH{1'b0}};
            command_q <= {`OPENRV64_ICX_PROBE_CMD_WIDTH{1'b0}};
            cache_mask_q <=
                {`OPENRV64_ICX_PROBE_CACHE_WIDTH{1'b0}};
            line_addr_q <= 64'd0;
        end else begin
            busy_q <= busy_d;
            done_valid_q <= done_valid_d;
            done_probe_id_q <= done_probe_id_d;
            protocol_error_q <= protocol_error_d;
            issue_pending_q <= issue_pending_d;
            ack_pending_q <= ack_pending_d;
            probe_id_q <= probe_id_d;
            command_q <= command_d;
            cache_mask_q <= cache_mask_d;
            line_addr_q <= line_addr_d;
        end
    end

    generate
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4)) begin : g_bad_harts
            initial
                $fatal(1, "probe tracker supports NUM_HARTS=2 or 4");
        end
    endgenerate

endmodule
