`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Registered, shared PMP service for MTL clients.
//
// Requests are accepted in fixed priority order.  The selected request is
// registered before it reaches the architectural PMP checker, and the verdict
// is registered again before it returns to a client.  The two stages are
// elastic, so the service can accept and complete one request per cycle while
// neither stage is backpressured.  Consequently no client ready/launch path
// contains the PMP compare tree.
//
// A response remains stable until its owner accepts it.  update_i suppresses
// response/request handshakes and replays every in-flight request through the
// checker so a result sampled against the old PMP state is never used.
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
    input  wire [`RV64_XLEN-1:0]        xlate_req_vaddr_i,
    input  wire [XLATE_TAG_WIDTH-1:0]   xlate_req_tag_i,
    output wire                         xlate_resp_valid_o,
    input  wire                         xlate_resp_ready_i,
    output wire                         xlate_resp_allow_o,
    output wire                         xlate_resp_write_o,
    output wire [`RV64_XLEN-1:0]        xlate_resp_vaddr_o,
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
    localparam [2:0] OWNER_LSU = 3'd0;
    localparam [2:0] OWNER_PTW = 3'd1;
    localparam [2:0] OWNER_XLATE = 3'd2;
    localparam [2:0] OWNER_FETCH = 3'd3;
    localparam [2:0] OWNER_PREFETCH = 3'd4;

    localparam integer PAYLOAD_OWNER_LSB = 0;
    localparam integer PAYLOAD_ADDR_LSB = PAYLOAD_OWNER_LSB + 3;
    localparam integer PAYLOAD_PRIV_LSB =
        PAYLOAD_ADDR_LSB + `RV64_XLEN;
    localparam integer PAYLOAD_SIZE_LSB =
        PAYLOAD_PRIV_LSB + `RV64_PRIV_WIDTH;
    localparam integer PAYLOAD_WRITE = PAYLOAD_SIZE_LSB + 3;
    localparam integer PAYLOAD_EXEC = PAYLOAD_WRITE + 1;
    localparam integer PAYLOAD_XLATE_TAG_LSB = PAYLOAD_EXEC + 1;
    localparam integer PAYLOAD_FETCH_VADDR_LSB =
        PAYLOAD_XLATE_TAG_LSB + XLATE_TAG_WIDTH;
    localparam integer PAYLOAD_FETCH_TAG_LSB =
        PAYLOAD_FETCH_VADDR_LSB + `RV64_XLEN;
    localparam integer PAYLOAD_WIDTH =
        PAYLOAD_FETCH_TAG_LSB + FETCH_TAG_WIDTH;

    reg check_valid_q;
    reg [PAYLOAD_WIDTH-1:0] check_payload_q;
    reg response_valid_q;
    reg [PAYLOAD_WIDTH-1:0] response_payload_q;
    reg response_allow_q;

    // An update can find both elastic stages occupied.  The response is older
    // and must be rechecked first, so the younger check-stage payload waits in
    // this replay slot.  Normal operation never allocates the slot.
    reg replay_valid_q;
    reg [PAYLOAD_WIDTH-1:0] replay_payload_q;

    wire [2:0] response_owner = response_payload_q[
        PAYLOAD_OWNER_LSB +: 3];
    wire response_ready =
        ((response_owner == OWNER_LSU) && lsu_resp_ready_i) ||
        ((response_owner == OWNER_PTW) && ptw_resp_ready_i) ||
        ((response_owner == OWNER_XLATE) && xlate_resp_ready_i) ||
        ((response_owner == OWNER_FETCH) && fetch_resp_ready_i) ||
        ((response_owner == OWNER_PREFETCH) && prefetch_resp_ready_i);
    wire response_slot_ready = !response_valid_q || response_ready;
    wire check_slot_ready = !check_valid_q || response_slot_ready;
    wire can_accept = check_slot_ready && !replay_valid_q && !update_i;
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

    wire take_request = take_lsu || take_ptw || take_xlate || take_fetch ||
                        take_prefetch;
    reg [PAYLOAD_WIDTH-1:0] request_payload_r;
    always @* begin
        request_payload_r = {PAYLOAD_WIDTH{1'b0}};
        if (take_lsu) begin
            request_payload_r[PAYLOAD_OWNER_LSB +: 3] = OWNER_LSU;
            request_payload_r[PAYLOAD_ADDR_LSB +: `RV64_XLEN] =
                lsu_req_addr_i;
            request_payload_r[PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH] =
                lsu_req_priv_i;
            request_payload_r[PAYLOAD_SIZE_LSB +: 3] = lsu_req_size_i;
            request_payload_r[PAYLOAD_WRITE] = lsu_req_write_i;
            request_payload_r[PAYLOAD_EXEC] = lsu_req_exec_i;
        end else if (take_ptw) begin
            request_payload_r[PAYLOAD_OWNER_LSB +: 3] = OWNER_PTW;
            request_payload_r[PAYLOAD_ADDR_LSB +: `RV64_XLEN] =
                ptw_req_addr_i;
            request_payload_r[PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH] =
                `RV64_PRIV_S;
            request_payload_r[PAYLOAD_SIZE_LSB +: 3] = 3'd3;
        end else if (take_xlate) begin
            request_payload_r[PAYLOAD_OWNER_LSB +: 3] = OWNER_XLATE;
            request_payload_r[PAYLOAD_ADDR_LSB +: `RV64_XLEN] =
                xlate_req_paddr_i;
            request_payload_r[PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH] =
                xlate_req_priv_i;
            request_payload_r[PAYLOAD_SIZE_LSB +: 3] = xlate_req_size_i;
            request_payload_r[PAYLOAD_WRITE] = xlate_req_write_i;
            request_payload_r[
                PAYLOAD_FETCH_VADDR_LSB +: `RV64_XLEN] =
                xlate_req_vaddr_i;
            request_payload_r[
                PAYLOAD_XLATE_TAG_LSB +: XLATE_TAG_WIDTH] =
                xlate_req_tag_i;
        end else if (take_fetch) begin
            request_payload_r[PAYLOAD_OWNER_LSB +: 3] = OWNER_FETCH;
            request_payload_r[PAYLOAD_ADDR_LSB +: `RV64_XLEN] =
                fetch_req_paddr_i;
            request_payload_r[PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH] =
                fetch_req_priv_i;
            request_payload_r[PAYLOAD_SIZE_LSB +: 3] = fetch_req_size_i;
            request_payload_r[PAYLOAD_EXEC] = 1'b1;
            request_payload_r[
                PAYLOAD_FETCH_VADDR_LSB +: `RV64_XLEN] =
                fetch_req_vaddr_i;
            request_payload_r[
                PAYLOAD_FETCH_TAG_LSB +: FETCH_TAG_WIDTH] =
                fetch_req_tag_i;
        end else if (take_prefetch) begin
            request_payload_r[PAYLOAD_OWNER_LSB +: 3] = OWNER_PREFETCH;
            request_payload_r[PAYLOAD_ADDR_LSB +: `RV64_XLEN] =
                prefetch_req_addr_i;
            request_payload_r[PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH] =
                prefetch_req_priv_i;
            request_payload_r[PAYLOAD_SIZE_LSB +: 3] = 3'd5;
            request_payload_r[PAYLOAD_EXEC] = 1'b1;
        end
    end

    wire response_valid = response_valid_q && !update_i;
    assign lsu_resp_valid_o = response_valid &&
        (response_owner == OWNER_LSU);
    assign ptw_resp_valid_o = response_valid &&
        (response_owner == OWNER_PTW);
    assign xlate_resp_valid_o = response_valid &&
        (response_owner == OWNER_XLATE);
    assign fetch_resp_valid_o = response_valid &&
        (response_owner == OWNER_FETCH);
    assign prefetch_resp_valid_o = response_valid &&
        (response_owner == OWNER_PREFETCH);

    assign lsu_resp_allow_o = response_allow_q;
    assign ptw_resp_allow_o = response_allow_q;
    assign xlate_resp_allow_o = response_allow_q;
    assign xlate_resp_write_o = response_payload_q[PAYLOAD_WRITE];
    assign xlate_resp_vaddr_o = response_payload_q[
        PAYLOAD_FETCH_VADDR_LSB +: `RV64_XLEN];
    assign fetch_resp_allow_o = response_allow_q;
    assign prefetch_resp_allow_o = response_allow_q;
    assign xlate_resp_paddr_o = response_payload_q[
        PAYLOAD_ADDR_LSB +: `RV64_XLEN];
    assign xlate_resp_tag_o = response_payload_q[
        PAYLOAD_XLATE_TAG_LSB +: XLATE_TAG_WIDTH];
    assign fetch_resp_vaddr_o = response_payload_q[
        PAYLOAD_FETCH_VADDR_LSB +: `RV64_XLEN];
    assign fetch_resp_paddr_o = response_payload_q[
        PAYLOAD_ADDR_LSB +: `RV64_XLEN];
    assign fetch_resp_priv_o = response_payload_q[
        PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH];
    assign fetch_resp_tag_o = response_payload_q[
        PAYLOAD_FETCH_TAG_LSB +: FETCH_TAG_WIDTH];

    assign check_valid_o = check_valid_q;
    assign check_addr_o = check_payload_q[
        PAYLOAD_ADDR_LSB +: `RV64_XLEN];
    assign check_priv_o = check_payload_q[
        PAYLOAD_PRIV_LSB +: `RV64_PRIV_WIDTH];
    assign check_size_o = check_payload_q[PAYLOAD_SIZE_LSB +: 3];
    assign check_write_o = check_payload_q[PAYLOAD_WRITE];
    assign check_exec_o = check_payload_q[PAYLOAD_EXEC];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            check_valid_q <= 1'b0;
            check_payload_q <= {PAYLOAD_WIDTH{1'b0}};
            response_valid_q <= 1'b0;
            response_payload_q <= {PAYLOAD_WIDTH{1'b0}};
            response_allow_q <= 1'b0;
            replay_valid_q <= 1'b0;
            replay_payload_q <= {PAYLOAD_WIDTH{1'b0}};
        end else if (update_i) begin
            // The response payload is older than the check payload.  Recheck
            // it first and retain the younger payload in the replay slot.
            // Handshakes are suppressed combinationally throughout this edge.
            if (response_valid_q) begin
                if (check_valid_q) begin
                    replay_valid_q <= 1'b1;
                    replay_payload_q <= check_payload_q;
                end
                check_valid_q <= 1'b1;
                check_payload_q <= response_payload_q;
                response_valid_q <= 1'b0;
            end
        end else begin
            if (response_slot_ready) begin
                response_valid_q <= check_valid_q;
                if (check_valid_q) begin
                    response_payload_q <= check_payload_q;
                    response_allow_q <= check_allow_i;
                end
            end

            if (check_slot_ready) begin
                if (replay_valid_q) begin
                    check_valid_q <= 1'b1;
                    check_payload_q <= replay_payload_q;
                    replay_valid_q <= 1'b0;
                end else begin
                    check_valid_q <= take_request;
                    if (take_request)
                        check_payload_q <= request_payload_r;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && update_i && response_valid_q && check_valid_q &&
            replay_valid_q)
            $fatal(1, "MTL PMP update replay capacity exceeded");
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
