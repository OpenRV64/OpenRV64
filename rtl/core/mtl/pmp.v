`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Registered, shared PMP service for MTL clients.
//
// Requests are accepted in fixed priority order.  The selected request is
// registered before it reaches the architectural PMP checker, and the verdict
// is registered again before it returns to a client.  Consequently no client
// ready/launch path contains the PMP compare tree.
//
// A response remains stable until its owner accepts it.  update_i restarts an
// active check so a result sampled on the PMP programming edge is never used.
module openrv64_mtl_pmp #(
    parameter integer XLATE_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer FETCH_TAG_WIDTH = 2
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         update_i,

    input  wire                         lsu_req_valid_i,
    output wire                         lsu_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        lsu_req_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_req_priv_i,
    input  wire [2:0]                   lsu_req_size_i,
    input  wire                         lsu_req_write_i,
    input  wire                         lsu_req_exec_i,
    output wire                         lsu_resp_valid_o,
    input  wire                         lsu_resp_ready_i,
    output wire                         lsu_resp_allow_o,

    input  wire                         ptw_req_valid_i,
    output wire                         ptw_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        ptw_req_addr_i,
    output wire                         ptw_resp_valid_o,
    input  wire                         ptw_resp_ready_i,
    output wire                         ptw_resp_allow_o,

    input  wire                         xlate_req_valid_i,
    output wire                         xlate_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        xlate_req_paddr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  xlate_req_priv_i,
    input  wire [2:0]                   xlate_req_size_i,
    input  wire                         xlate_req_write_i,
    input  wire [XLATE_TAG_WIDTH-1:0]   xlate_req_tag_i,
    output wire                         xlate_resp_valid_o,
    input  wire                         xlate_resp_ready_i,
    output wire                         xlate_resp_allow_o,
    output wire [`RV64_XLEN-1:0]        xlate_resp_paddr_o,
    output wire [XLATE_TAG_WIDTH-1:0]   xlate_resp_tag_o,

    input  wire                         fetch_req_valid_i,
    output wire                         fetch_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        fetch_req_vaddr_i,
    input  wire [`RV64_XLEN-1:0]        fetch_req_paddr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  fetch_req_priv_i,
    input  wire [2:0]                   fetch_req_size_i,
    input  wire [FETCH_TAG_WIDTH-1:0]   fetch_req_tag_i,
    output wire                         fetch_resp_valid_o,
    input  wire                         fetch_resp_ready_i,
    output wire                         fetch_resp_allow_o,
    output wire [`RV64_XLEN-1:0]        fetch_resp_vaddr_o,
    output wire [`RV64_XLEN-1:0]        fetch_resp_paddr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  fetch_resp_priv_o,
    output wire [FETCH_TAG_WIDTH-1:0]   fetch_resp_tag_o,

    input  wire                         prefetch_req_valid_i,
    output wire                         prefetch_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        prefetch_req_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  prefetch_req_priv_i,
    output wire                         prefetch_resp_valid_o,
    input  wire                         prefetch_resp_ready_i,
    output wire                         prefetch_resp_allow_o,

    output wire                         check_valid_o,
    output wire [`RV64_XLEN-1:0]        check_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  check_priv_o,
    output wire [2:0]                   check_size_o,
    output wire                         check_write_o,
    output wire                         check_exec_o,
    input  wire                         check_allow_i
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_CHECK = 2'd1;
    localparam [1:0] STATE_RESP = 2'd2;

    localparam [2:0] OWNER_LSU = 3'd0;
    localparam [2:0] OWNER_PTW = 3'd1;
    localparam [2:0] OWNER_XLATE = 3'd2;
    localparam [2:0] OWNER_FETCH = 3'd3;
    localparam [2:0] OWNER_PREFETCH = 3'd4;

    reg [1:0] state_q;
    reg [2:0] owner_q;
    reg [`RV64_XLEN-1:0] addr_q;
    reg [`RV64_PRIV_WIDTH-1:0] priv_q;
    reg [2:0] size_q;
    reg write_q;
    reg exec_q;
    reg allow_q;
    reg [XLATE_TAG_WIDTH-1:0] xlate_tag_q;
    reg [`RV64_XLEN-1:0] fetch_vaddr_q;
    reg [FETCH_TAG_WIDTH-1:0] fetch_tag_q;

    wire can_accept = (state_q == STATE_IDLE) && !update_i;
    wire take_lsu = can_accept && lsu_req_valid_i;
    wire take_ptw = can_accept && !lsu_req_valid_i && ptw_req_valid_i;
    wire take_xlate = can_accept && !lsu_req_valid_i &&
        !ptw_req_valid_i && xlate_req_valid_i;
    wire take_fetch = can_accept && !lsu_req_valid_i &&
        !ptw_req_valid_i && !xlate_req_valid_i && fetch_req_valid_i;
    wire take_prefetch = can_accept && !lsu_req_valid_i &&
        !ptw_req_valid_i && !xlate_req_valid_i && !fetch_req_valid_i &&
        prefetch_req_valid_i;

    assign lsu_req_ready_o = take_lsu;
    assign ptw_req_ready_o = take_ptw;
    assign xlate_req_ready_o = take_xlate;
    assign fetch_req_ready_o = take_fetch;
    assign prefetch_req_ready_o = take_prefetch;

    wire response_valid = (state_q == STATE_RESP) && !update_i;
    assign lsu_resp_valid_o = response_valid && (owner_q == OWNER_LSU);
    assign ptw_resp_valid_o = response_valid && (owner_q == OWNER_PTW);
    assign xlate_resp_valid_o = response_valid &&
        (owner_q == OWNER_XLATE);
    assign fetch_resp_valid_o = response_valid &&
        (owner_q == OWNER_FETCH);
    assign prefetch_resp_valid_o = response_valid &&
        (owner_q == OWNER_PREFETCH);

    assign lsu_resp_allow_o = allow_q;
    assign ptw_resp_allow_o = allow_q;
    assign xlate_resp_allow_o = allow_q;
    assign fetch_resp_allow_o = allow_q;
    assign prefetch_resp_allow_o = allow_q;
    assign xlate_resp_paddr_o = addr_q;
    assign xlate_resp_tag_o = xlate_tag_q;
    assign fetch_resp_vaddr_o = fetch_vaddr_q;
    assign fetch_resp_paddr_o = addr_q;
    assign fetch_resp_priv_o = priv_q;
    assign fetch_resp_tag_o = fetch_tag_q;

    wire response_ready =
        ((owner_q == OWNER_LSU) && lsu_resp_ready_i) ||
        ((owner_q == OWNER_PTW) && ptw_resp_ready_i) ||
        ((owner_q == OWNER_XLATE) && xlate_resp_ready_i) ||
        ((owner_q == OWNER_FETCH) && fetch_resp_ready_i) ||
        ((owner_q == OWNER_PREFETCH) && prefetch_resp_ready_i);

    assign check_valid_o = state_q == STATE_CHECK;
    assign check_addr_o = addr_q;
    assign check_priv_o = priv_q;
    assign check_size_o = size_q;
    assign check_write_o = write_q;
    assign check_exec_o = exec_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            owner_q <= OWNER_LSU;
            addr_q <= {`RV64_XLEN{1'b0}};
            priv_q <= `RV64_PRIV_M;
            size_q <= 3'd0;
            write_q <= 1'b0;
            exec_q <= 1'b0;
            allow_q <= 1'b0;
            xlate_tag_q <= {XLATE_TAG_WIDTH{1'b0}};
            fetch_vaddr_q <= {`RV64_XLEN{1'b0}};
            fetch_tag_q <= {FETCH_TAG_WIDTH{1'b0}};
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (take_lsu) begin
                        owner_q <= OWNER_LSU;
                        addr_q <= lsu_req_addr_i;
                        priv_q <= lsu_req_priv_i;
                        size_q <= lsu_req_size_i;
                        write_q <= lsu_req_write_i;
                        exec_q <= lsu_req_exec_i;
                        state_q <= STATE_CHECK;
                    end else if (take_ptw) begin
                        owner_q <= OWNER_PTW;
                        addr_q <= ptw_req_addr_i;
                        priv_q <= `RV64_PRIV_S;
                        size_q <= 3'd3;
                        write_q <= 1'b0;
                        exec_q <= 1'b0;
                        state_q <= STATE_CHECK;
                    end else if (take_xlate) begin
                        owner_q <= OWNER_XLATE;
                        addr_q <= xlate_req_paddr_i;
                        priv_q <= xlate_req_priv_i;
                        size_q <= xlate_req_size_i;
                        write_q <= xlate_req_write_i;
                        exec_q <= 1'b0;
                        xlate_tag_q <= xlate_req_tag_i;
                        state_q <= STATE_CHECK;
                    end else if (take_fetch) begin
                        owner_q <= OWNER_FETCH;
                        addr_q <= fetch_req_paddr_i;
                        priv_q <= fetch_req_priv_i;
                        size_q <= fetch_req_size_i;
                        write_q <= 1'b0;
                        exec_q <= 1'b1;
                        fetch_vaddr_q <= fetch_req_vaddr_i;
                        fetch_tag_q <= fetch_req_tag_i;
                        state_q <= STATE_CHECK;
                    end else if (take_prefetch) begin
                        owner_q <= OWNER_PREFETCH;
                        addr_q <= prefetch_req_addr_i;
                        priv_q <= prefetch_req_priv_i;
                        size_q <= 3'd5;
                        write_q <= 1'b0;
                        exec_q <= 1'b1;
                        state_q <= STATE_CHECK;
                    end
                end

                STATE_CHECK: begin
                    if (!update_i) begin
                        allow_q <= check_allow_i;
                        state_q <= STATE_RESP;
                    end
                end

                STATE_RESP: begin
                    if (update_i)
                        state_q <= STATE_CHECK;
                    else if (response_ready)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n &&
            ((lsu_req_ready_o &&
              (ptw_req_ready_o || xlate_req_ready_o || fetch_req_ready_o ||
               prefetch_req_ready_o)) ||
             (ptw_req_ready_o &&
              (xlate_req_ready_o || fetch_req_ready_o ||
               prefetch_req_ready_o)) ||
             (xlate_req_ready_o &&
              (fetch_req_ready_o || prefetch_req_ready_o)) ||
             (fetch_req_ready_o && prefetch_req_ready_o)))
            $fatal(1, "MTL PMP accepted multiple clients");
    end
`endif
endmodule
