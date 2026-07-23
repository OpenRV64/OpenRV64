`timescale 1ns/1ps

// Five-port, deterministic single-turn mesh router.
//
// n/e/w/s name the neighboring tile.  For example, w_flit_i arrives from
// the west and normally leaves through e_flit_o.  The up port is the local
// injection/ejection seam.  It is a 512-bit ready/valid flit link by default;
// it is not, by itself, an AXI4 interface.
//
// Every flit carries a source-route sideband:
//
//   route[HOP_COUNT_WIDTH-1:0]                 x hops remaining
//   route[2*HOP_COUNT_WIDTH-1:HOP_COUNT_WIDTH] y hops remaining
//   route[2*HOP_COUNT_WIDTH]                   1: west, 0: east
//   route[2*HOP_COUNT_WIDTH+1]                 1: south, 0: north
//
// X is always consumed before Y.  A horizontal flit therefore travels
// straight until x_hops reaches zero, may turn once into its selected Y
// direction, travels straight in Y, and ejects up when both counts are zero.
// Each successful planar transition decrements the corresponding count.
// Vertical-to-horizontal turns and planar U-turns are rejected.
//
// The datapath is combinational and has no internal flit buffer.  Independent
// outputs can transfer in the same cycle.  Each output has a round-robin
// arbiter, and a stalled grant is locked so valid/data/route remain stable
// under backpressure.  As with any ready/valid link, the source must retain a
// valid flit until it is accepted.
module openrv64_mesh_router_tile #(
    parameter integer FLIT_WIDTH = 512,
    parameter integer HOP_COUNT_WIDTH = 8
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire                         n_valid_i,
    output wire                         n_ready_o,
    input  wire [FLIT_WIDTH-1:0]        n_flit_i,
    input  wire [2*HOP_COUNT_WIDTH+1:0] n_route_i,
    output wire                         n_valid_o,
    input  wire                         n_ready_i,
    output wire [FLIT_WIDTH-1:0]        n_flit_o,
    output wire [2*HOP_COUNT_WIDTH+1:0] n_route_o,

    input  wire                         e_valid_i,
    output wire                         e_ready_o,
    input  wire [FLIT_WIDTH-1:0]        e_flit_i,
    input  wire [2*HOP_COUNT_WIDTH+1:0] e_route_i,
    output wire                         e_valid_o,
    input  wire                         e_ready_i,
    output wire [FLIT_WIDTH-1:0]        e_flit_o,
    output wire [2*HOP_COUNT_WIDTH+1:0] e_route_o,

    input  wire                         w_valid_i,
    output wire                         w_ready_o,
    input  wire [FLIT_WIDTH-1:0]        w_flit_i,
    input  wire [2*HOP_COUNT_WIDTH+1:0] w_route_i,
    output wire                         w_valid_o,
    input  wire                         w_ready_i,
    output wire [FLIT_WIDTH-1:0]        w_flit_o,
    output wire [2*HOP_COUNT_WIDTH+1:0] w_route_o,

    input  wire                         s_valid_i,
    output wire                         s_ready_o,
    input  wire [FLIT_WIDTH-1:0]        s_flit_i,
    input  wire [2*HOP_COUNT_WIDTH+1:0] s_route_i,
    output wire                         s_valid_o,
    input  wire                         s_ready_i,
    output wire [FLIT_WIDTH-1:0]        s_flit_o,
    output wire [2*HOP_COUNT_WIDTH+1:0] s_route_o,

    input  wire                         up_valid_i,
    output wire                         up_ready_o,
    input  wire [FLIT_WIDTH-1:0]        up_flit_i,
    input  wire [2*HOP_COUNT_WIDTH+1:0] up_route_i,
    output wire                         up_valid_o,
    input  wire                         up_ready_i,
    output wire [FLIT_WIDTH-1:0]        up_flit_o,
    output wire [2*HOP_COUNT_WIDTH+1:0] up_route_o,

    // One bit per input, ordered {up, south, west, east, north}.  An
    // asserted bit means a valid flit requested a forbidden transition.
    output wire [4:0]                   route_error_o
);

    localparam integer PORT_COUNT = 5;
    localparam integer ROUTE_WIDTH = 2 * HOP_COUNT_WIDTH + 2;
    localparam integer X_WEST_BIT = 2 * HOP_COUNT_WIDTH;
    localparam integer Y_SOUTH_BIT = 2 * HOP_COUNT_WIDTH + 1;

    localparam [2:0] PORT_N = 3'd0;
    localparam [2:0] PORT_E = 3'd1;
    localparam [2:0] PORT_W = 3'd2;
    localparam [2:0] PORT_S = 3'd3;
    localparam [2:0] PORT_UP = 3'd4;

    wire [PORT_COUNT-1:0] input_valid = {
        up_valid_i, s_valid_i, w_valid_i, e_valid_i, n_valid_i
    };
    wire [PORT_COUNT*FLIT_WIDTH-1:0] input_flit = {
        up_flit_i, s_flit_i, w_flit_i, e_flit_i, n_flit_i
    };
    wire [PORT_COUNT*ROUTE_WIDTH-1:0] input_route = {
        up_route_i, s_route_i, w_route_i, e_route_i, n_route_i
    };
    wire [PORT_COUNT-1:0] output_ready = {
        up_ready_i, s_ready_i, w_ready_i, e_ready_i, n_ready_i
    };

    reg [PORT_COUNT-1:0] input_ready;
    reg [PORT_COUNT-1:0] output_valid;
    reg [PORT_COUNT*FLIT_WIDTH-1:0] output_flit;
    reg [PORT_COUNT*ROUTE_WIDTH-1:0] output_route;
    reg [PORT_COUNT-1:0] route_error;

    reg [PORT_COUNT-1:0] requests [0:PORT_COUNT-1];
    reg [2:0] route_target [0:PORT_COUNT-1];
    reg route_legal [0:PORT_COUNT-1];
    reg [PORT_COUNT-1:0] grant_valid;
    reg [2:0] grant_select [0:PORT_COUNT-1];

    reg [2:0] round_robin_q [0:PORT_COUNT-1];
    reg [PORT_COUNT-1:0] hold_q;
    reg [2:0] hold_select_q [0:PORT_COUNT-1];

    integer input_index;
    integer output_index;
    integer scan_index;
    integer candidate_index;
    integer state_index;

    function [2:0] target_of;
        input [ROUTE_WIDTH-1:0] route;
        reg [HOP_COUNT_WIDTH-1:0] x_hops;
        reg [HOP_COUNT_WIDTH-1:0] y_hops;
        begin
            x_hops = route[HOP_COUNT_WIDTH-1:0];
            y_hops = route[2*HOP_COUNT_WIDTH-1:HOP_COUNT_WIDTH];
            if (x_hops != {HOP_COUNT_WIDTH{1'b0}})
                target_of = route[X_WEST_BIT] ? PORT_W : PORT_E;
            else if (y_hops != {HOP_COUNT_WIDTH{1'b0}})
                target_of = route[Y_SOUTH_BIT] ? PORT_S : PORT_N;
            else
                target_of = PORT_UP;
        end
    endfunction

    function legal_transition;
        input [2:0] source;
        input [2:0] target;
        begin
            case (source)
                // Vertical traffic can only continue or eject.
                PORT_N:
                    legal_transition =
                        (target == PORT_S) || (target == PORT_UP);
                PORT_S:
                    legal_transition =
                        (target == PORT_N) || (target == PORT_UP);

                // Horizontal traffic can continue, make its one Y turn, or
                // eject.  Returning to its source side is a U-turn.
                PORT_E:
                    legal_transition = target != PORT_E;
                PORT_W:
                    legal_transition = target != PORT_W;

                // A locally injected flit may start in either dimension.  A
                // zero-hop route is also allowed to loop to local ejection.
                PORT_UP:
                    legal_transition = target <= PORT_UP;
                default:
                    legal_transition = 1'b0;
            endcase
        end
    endfunction

    function [ROUTE_WIDTH-1:0] advanced_route;
        input [ROUTE_WIDTH-1:0] route;
        input [2:0] target;
        reg [ROUTE_WIDTH-1:0] result;
        reg [HOP_COUNT_WIDTH-1:0] x_hops;
        reg [HOP_COUNT_WIDTH-1:0] y_hops;
        begin
            result = route;
            x_hops = route[HOP_COUNT_WIDTH-1:0];
            y_hops = route[2*HOP_COUNT_WIDTH-1:HOP_COUNT_WIDTH];
            if ((target == PORT_E) || (target == PORT_W)) begin
                if (x_hops != {HOP_COUNT_WIDTH{1'b0}})
                    result[HOP_COUNT_WIDTH-1:0] = x_hops - 1'b1;
            end else if ((target == PORT_N) || (target == PORT_S)) begin
                if (y_hops != {HOP_COUNT_WIDTH{1'b0}})
                    result[2*HOP_COUNT_WIDTH-1:HOP_COUNT_WIDTH] =
                        y_hops - 1'b1;
            end
            advanced_route = result;
        end
    endfunction

    function [2:0] next_port;
        input [2:0] current_port;
        begin
            if (current_port == PORT_UP)
                next_port = PORT_N;
            else
                next_port = current_port + 1'b1;
        end
    endfunction

    initial begin
        if (FLIT_WIDTH < 1)
            $fatal(1, "mesh router FLIT_WIDTH must be positive");
        if (HOP_COUNT_WIDTH < 1)
            $fatal(1, "mesh router HOP_COUNT_WIDTH must be positive");
    end

    // Decode exactly one requested output for each valid input.
    always @* begin
        route_error = {PORT_COUNT{1'b0}};
        for (output_index = 0; output_index < PORT_COUNT;
             output_index = output_index + 1)
            requests[output_index] = {PORT_COUNT{1'b0}};

        for (input_index = 0; input_index < PORT_COUNT;
             input_index = input_index + 1) begin
            route_target[input_index] = target_of(input_route[
                input_index*ROUTE_WIDTH +: ROUTE_WIDTH]);
            route_legal[input_index] = legal_transition(
                input_index[2:0], route_target[input_index]);
            if (input_valid[input_index]) begin
                if (route_legal[input_index])
                    requests[route_target[input_index]][input_index] = 1'b1;
                else
                    route_error[input_index] = 1'b1;
            end
        end
    end

    // Per-output round-robin selection.  A grant held by backpressure takes
    // precedence over newly arriving contenders.
    always @* begin
        grant_valid = {PORT_COUNT{1'b0}};
        candidate_index = 0;
        for (output_index = 0; output_index < PORT_COUNT;
             output_index = output_index + 1) begin
            grant_select[output_index] = round_robin_q[output_index];
            if (hold_q[output_index]) begin
                grant_select[output_index] = hold_select_q[output_index];
                grant_valid[output_index] = requests[output_index][
                    hold_select_q[output_index]];
            end else begin
                for (scan_index = 0; scan_index < PORT_COUNT;
                     scan_index = scan_index + 1) begin
                    candidate_index = {
                        29'd0, round_robin_q[output_index]
                    };
                    candidate_index = candidate_index + scan_index;
                    if (candidate_index >= PORT_COUNT)
                        candidate_index = candidate_index - PORT_COUNT;
                    if (!grant_valid[output_index] &&
                        requests[output_index][candidate_index]) begin
                        grant_valid[output_index] = 1'b1;
                        grant_select[output_index] = candidate_index[2:0];
                    end
                end
            end
        end
    end

    // Crossbar and ready propagation.  Since every legal input requests only
    // one output, an input cannot be granted twice in one cycle.
    always @* begin
        input_ready = {PORT_COUNT{1'b0}};
        output_valid = {PORT_COUNT{1'b0}};
        output_flit = {PORT_COUNT*FLIT_WIDTH{1'b0}};
        output_route = {PORT_COUNT*ROUTE_WIDTH{1'b0}};

        for (output_index = 0; output_index < PORT_COUNT;
             output_index = output_index + 1) begin
            if (grant_valid[output_index]) begin
                output_valid[output_index] = 1'b1;
                output_flit[output_index*FLIT_WIDTH +: FLIT_WIDTH] =
                    input_flit[
                        grant_select[output_index]*FLIT_WIDTH +: FLIT_WIDTH];
                output_route[output_index*ROUTE_WIDTH +: ROUTE_WIDTH] =
                    advanced_route(input_route[
                        grant_select[output_index]*ROUTE_WIDTH +: ROUTE_WIDTH],
                        output_index[2:0]);
                input_ready[grant_select[output_index]] =
                    output_ready[output_index];
            end
        end
    end

    // Lock a stalled grant and advance fairness only on an actual transfer.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hold_q <= {PORT_COUNT{1'b0}};
            for (state_index = 0; state_index < PORT_COUNT;
                 state_index = state_index + 1) begin
                round_robin_q[state_index] <= PORT_N;
                hold_select_q[state_index] <= PORT_N;
            end
        end else begin
            for (state_index = 0; state_index < PORT_COUNT;
                 state_index = state_index + 1) begin
                if (hold_q[state_index]) begin
                    // Dropping valid while stalled violates ready/valid, but
                    // releasing the lock prevents a bad source from wedging
                    // the output permanently.
                    if (!requests[state_index][hold_select_q[state_index]]) begin
                        hold_q[state_index] <= 1'b0;
                    end else if (output_ready[state_index]) begin
                        hold_q[state_index] <= 1'b0;
                        round_robin_q[state_index] <=
                            next_port(hold_select_q[state_index]);
                    end
                end else if (grant_valid[state_index]) begin
                    if (output_ready[state_index]) begin
                        round_robin_q[state_index] <=
                            next_port(grant_select[state_index]);
                    end else begin
                        hold_q[state_index] <= 1'b1;
                        hold_select_q[state_index] <=
                            grant_select[state_index];
                    end
                end
            end
        end
    end

    assign n_ready_o = input_ready[PORT_N];
    assign e_ready_o = input_ready[PORT_E];
    assign w_ready_o = input_ready[PORT_W];
    assign s_ready_o = input_ready[PORT_S];
    assign up_ready_o = input_ready[PORT_UP];

    assign n_valid_o = output_valid[PORT_N];
    assign e_valid_o = output_valid[PORT_E];
    assign w_valid_o = output_valid[PORT_W];
    assign s_valid_o = output_valid[PORT_S];
    assign up_valid_o = output_valid[PORT_UP];

    assign n_flit_o = output_flit[PORT_N*FLIT_WIDTH +: FLIT_WIDTH];
    assign e_flit_o = output_flit[PORT_E*FLIT_WIDTH +: FLIT_WIDTH];
    assign w_flit_o = output_flit[PORT_W*FLIT_WIDTH +: FLIT_WIDTH];
    assign s_flit_o = output_flit[PORT_S*FLIT_WIDTH +: FLIT_WIDTH];
    assign up_flit_o = output_flit[PORT_UP*FLIT_WIDTH +: FLIT_WIDTH];

    assign n_route_o = output_route[PORT_N*ROUTE_WIDTH +: ROUTE_WIDTH];
    assign e_route_o = output_route[PORT_E*ROUTE_WIDTH +: ROUTE_WIDTH];
    assign w_route_o = output_route[PORT_W*ROUTE_WIDTH +: ROUTE_WIDTH];
    assign s_route_o = output_route[PORT_S*ROUTE_WIDTH +: ROUTE_WIDTH];
    assign up_route_o = output_route[PORT_UP*ROUTE_WIDTH +: ROUTE_WIDTH];

    assign route_error_o = route_error;

endmodule
