`timescale 1ns/1ps

module tb_mesh_router_tile;

    localparam integer FLIT_WIDTH = 512;
    localparam integer HOP_COUNT_WIDTH = 4;
    localparam integer ROUTE_WIDTH = 2 * HOP_COUNT_WIDTH + 2;

    logic clk;
    logic rst_n;

    logic n_valid_i;
    wire n_ready_o;
    logic [FLIT_WIDTH-1:0] n_flit_i;
    logic [ROUTE_WIDTH-1:0] n_route_i;
    wire n_valid_o;
    logic n_ready_i;
    wire [FLIT_WIDTH-1:0] n_flit_o;
    wire [ROUTE_WIDTH-1:0] n_route_o;

    logic e_valid_i;
    wire e_ready_o;
    logic [FLIT_WIDTH-1:0] e_flit_i;
    logic [ROUTE_WIDTH-1:0] e_route_i;
    wire e_valid_o;
    logic e_ready_i;
    wire [FLIT_WIDTH-1:0] e_flit_o;
    wire [ROUTE_WIDTH-1:0] e_route_o;

    logic w_valid_i;
    wire w_ready_o;
    logic [FLIT_WIDTH-1:0] w_flit_i;
    logic [ROUTE_WIDTH-1:0] w_route_i;
    wire w_valid_o;
    logic w_ready_i;
    wire [FLIT_WIDTH-1:0] w_flit_o;
    wire [ROUTE_WIDTH-1:0] w_route_o;

    logic s_valid_i;
    wire s_ready_o;
    logic [FLIT_WIDTH-1:0] s_flit_i;
    logic [ROUTE_WIDTH-1:0] s_route_i;
    wire s_valid_o;
    logic s_ready_i;
    wire [FLIT_WIDTH-1:0] s_flit_o;
    wire [ROUTE_WIDTH-1:0] s_route_o;

    logic up_valid_i;
    wire up_ready_o;
    logic [FLIT_WIDTH-1:0] up_flit_i;
    logic [ROUTE_WIDTH-1:0] up_route_i;
    wire up_valid_o;
    logic up_ready_i;
    wire [FLIT_WIDTH-1:0] up_flit_o;
    wire [ROUTE_WIDTH-1:0] up_route_o;

    wire [4:0] route_error;

    openrv64_mesh_router_tile #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .HOP_COUNT_WIDTH(HOP_COUNT_WIDTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .n_valid_i(n_valid_i),
        .n_ready_o(n_ready_o),
        .n_flit_i(n_flit_i),
        .n_route_i(n_route_i),
        .n_valid_o(n_valid_o),
        .n_ready_i(n_ready_i),
        .n_flit_o(n_flit_o),
        .n_route_o(n_route_o),
        .e_valid_i(e_valid_i),
        .e_ready_o(e_ready_o),
        .e_flit_i(e_flit_i),
        .e_route_i(e_route_i),
        .e_valid_o(e_valid_o),
        .e_ready_i(e_ready_i),
        .e_flit_o(e_flit_o),
        .e_route_o(e_route_o),
        .w_valid_i(w_valid_i),
        .w_ready_o(w_ready_o),
        .w_flit_i(w_flit_i),
        .w_route_i(w_route_i),
        .w_valid_o(w_valid_o),
        .w_ready_i(w_ready_i),
        .w_flit_o(w_flit_o),
        .w_route_o(w_route_o),
        .s_valid_i(s_valid_i),
        .s_ready_o(s_ready_o),
        .s_flit_i(s_flit_i),
        .s_route_i(s_route_i),
        .s_valid_o(s_valid_o),
        .s_ready_i(s_ready_i),
        .s_flit_o(s_flit_o),
        .s_route_o(s_route_o),
        .up_valid_i(up_valid_i),
        .up_ready_o(up_ready_o),
        .up_flit_i(up_flit_i),
        .up_route_i(up_route_i),
        .up_valid_o(up_valid_o),
        .up_ready_i(up_ready_i),
        .up_flit_o(up_flit_o),
        .up_route_o(up_route_o),
        .route_error_o(route_error)
    );

    function automatic [ROUTE_WIDTH-1:0] route;
        input [HOP_COUNT_WIDTH-1:0] x_hops;
        input [HOP_COUNT_WIDTH-1:0] y_hops;
        input logic x_west;
        input logic y_south;
        begin
            route = {y_south, x_west, y_hops, x_hops};
        end
    endfunction

    task automatic clear_inputs;
        begin
            n_valid_i = 1'b0;
            e_valid_i = 1'b0;
            w_valid_i = 1'b0;
            s_valid_i = 1'b0;
            up_valid_i = 1'b0;
            n_flit_i = {FLIT_WIDTH{1'b0}};
            e_flit_i = {FLIT_WIDTH{1'b0}};
            w_flit_i = {FLIT_WIDTH{1'b0}};
            s_flit_i = {FLIT_WIDTH{1'b0}};
            up_flit_i = {FLIT_WIDTH{1'b0}};
            n_route_i = {ROUTE_WIDTH{1'b0}};
            e_route_i = {ROUTE_WIDTH{1'b0}};
            w_route_i = {ROUTE_WIDTH{1'b0}};
            s_route_i = {ROUTE_WIDTH{1'b0}};
            up_route_i = {ROUTE_WIDTH{1'b0}};
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        clear_inputs();
        n_ready_i = 1'b1;
        e_ready_i = 1'b1;
        w_ready_i = 1'b1;
        s_ready_i = 1'b1;
        up_ready_i = 1'b1;
        rst_n = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Local injection starts east and decrements X on the transition.
        up_valid_i = 1'b1;
        up_flit_i = 512'h11;
        up_route_i = route(4'd2, 4'd1, 1'b0, 1'b0);
        #1;
        if (!e_valid_o || !up_ready_o || (e_flit_o !== 512'h11) ||
            (e_route_o !== route(4'd1, 4'd1, 1'b0, 1'b0)))
            $fatal(1, "local-to-east route/decrement failed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        // At X=0, a west-arriving flit makes its only turn toward north.
        w_valid_i = 1'b1;
        w_flit_i = 512'h22;
        w_route_i = route(4'd0, 4'd2, 1'b0, 1'b0);
        #1;
        if (!n_valid_o || !w_ready_o || (n_flit_o !== 512'h22) ||
            (n_route_o !== route(4'd0, 4'd1, 1'b0, 1'b0)))
            $fatal(1, "west-to-north turn failed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        // The same single turn may select south.
        e_valid_i = 1'b1;
        e_flit_i = 512'h33;
        e_route_i = route(4'd0, 4'd3, 1'b1, 1'b1);
        #1;
        if (!s_valid_o || !e_ready_o || (s_flit_o !== 512'h33) ||
            (s_route_o !== route(4'd0, 4'd2, 1'b1, 1'b1)))
            $fatal(1, "east-to-south turn failed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        // Vertical flits continue straight, and independent outputs fire in
        // the same cycle.
        n_valid_i = 1'b1;
        n_flit_i = 512'h44;
        n_route_i = route(4'd0, 4'd2, 1'b0, 1'b1);
        s_valid_i = 1'b1;
        s_flit_i = 512'h55;
        s_route_i = route(4'd0, 4'd2, 1'b0, 1'b0);
        #1;
        if (!s_valid_o || !n_ready_o || (s_flit_o !== 512'h44) ||
            (s_route_o !== route(4'd0, 4'd1, 1'b0, 1'b1)))
            $fatal(1, "north-to-south straight route failed");
        if (!n_valid_o || !s_ready_o || (n_flit_o !== 512'h55) ||
            (n_route_o !== route(4'd0, 4'd1, 1'b0, 1'b0)))
            $fatal(1, "south-to-north straight route failed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        // Zero remaining hops ejects through the local upstream link.
        w_valid_i = 1'b1;
        w_flit_i = 512'h66;
        w_route_i = route(4'd0, 4'd0, 1'b0, 1'b0);
        #1;
        if (!up_valid_o || !w_ready_o || (up_flit_o !== 512'h66))
            $fatal(1, "local ejection failed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        // A vertical-to-horizontal turn is outside XY routing and stalls with
        // an explicit route error.
        n_valid_i = 1'b1;
        n_flit_i = 512'h77;
        n_route_i = route(4'd1, 4'd0, 1'b0, 1'b0);
        #1;
        if (!route_error[0] || n_ready_o ||
            (|{n_valid_o, e_valid_o, w_valid_o, s_valid_o, up_valid_o}))
            $fatal(1, "vertical-to-horizontal route was not rejected");
        @(negedge clk);
        clear_inputs();

        // A planar U-turn is rejected as malformed routing metadata.
        w_valid_i = 1'b1;
        w_flit_i = 512'h88;
        w_route_i = route(4'd1, 4'd0, 1'b1, 1'b0);
        #1;
        if (!route_error[2] || w_ready_o || w_valid_o)
            $fatal(1, "planar U-turn was not rejected");
        @(negedge clk);
        clear_inputs();

        // West and local injection contend for east.  West wins the current
        // round-robin position, remains stable through backpressure, then the
        // local flit advances on the following cycle.
        e_ready_i = 1'b0;
        w_valid_i = 1'b1;
        w_flit_i = 512'h99;
        w_route_i = route(4'd2, 4'd0, 1'b0, 1'b0);
        up_valid_i = 1'b1;
        up_flit_i = 512'haa;
        up_route_i = route(4'd1, 4'd0, 1'b0, 1'b0);
        #1;
        if (!e_valid_o || (e_flit_o !== 512'h99) ||
            e_ready_o || up_ready_o)
            $fatal(1, "east contention selection failed");
        @(posedge clk);
        @(negedge clk);
        #1;
        if (!e_valid_o || (e_flit_o !== 512'h99) ||
            (e_route_o !== route(4'd1, 4'd0, 1'b0, 1'b0)))
            $fatal(1, "stalled output was not stable");

        e_ready_i = 1'b1;
        #1;
        if (!e_valid_o || !w_ready_o || (e_flit_o !== 512'h99))
            $fatal(1, "held west flit did not resume");
        @(posedge clk);
        @(negedge clk);
        w_valid_i = 1'b0;
        #1;
        if (!e_valid_o || !up_ready_o || (e_flit_o !== 512'haa) ||
            (e_route_o !== route(4'd0, 4'd0, 1'b0, 1'b0)))
            $fatal(1, "round-robin contender did not advance");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        $display("tb_mesh_router_tile: PASS");
        $finish;
    end

endmodule
