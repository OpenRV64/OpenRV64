`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module tb_mtl_pmp;
    reg clk;
    reg rst_n;
    reg update;

    reg lsu_valid;
    wire lsu_ready;
    reg [63:0] lsu_addr;
    reg [`RV64_PRIV_WIDTH-1:0] lsu_priv;
    reg [2:0] lsu_size;
    reg lsu_write;
    wire lsu_resp_valid;
    reg lsu_resp_ready;
    wire lsu_resp_allow;

    reg ptw_valid;
    wire ptw_ready;
    reg [63:0] ptw_addr;
    wire ptw_resp_valid;
    wire ptw_resp_allow;

    reg xlate_valid;
    wire xlate_ready;
    reg [63:0] xlate_paddr;
    reg [`RV64_PRIV_WIDTH-1:0] xlate_priv;
    reg [2:0] xlate_size;
    reg xlate_write;
    reg [63:0] xlate_vaddr;
    reg [2:0] xlate_tag;
    wire xlate_resp_valid;
    wire xlate_resp_allow;
    wire xlate_resp_write;
    wire [63:0] xlate_resp_vaddr;
    wire [63:0] xlate_resp_paddr;
    wire [2:0] xlate_resp_tag;
    reg xlate_resp_ready;

    reg fetch_valid;
    wire fetch_ready;
    reg [63:0] fetch_vaddr;
    reg [63:0] fetch_paddr;
    reg [`RV64_PRIV_WIDTH-1:0] fetch_priv;
    reg [2:0] fetch_size;
    reg [1:0] fetch_tag;
    wire fetch_resp_valid;
    wire fetch_resp_allow;
    wire [63:0] fetch_resp_vaddr;
    wire [63:0] fetch_resp_paddr;
    wire [`RV64_PRIV_WIDTH-1:0] fetch_resp_priv;
    wire [1:0] fetch_resp_tag;

    reg prefetch_valid;
    wire prefetch_ready;
    reg [63:0] prefetch_addr;
    reg [`RV64_PRIV_WIDTH-1:0] prefetch_priv;
    wire prefetch_resp_valid;
    wire prefetch_resp_allow;

    wire check_valid;
    wire [63:0] check_addr;
    wire [`RV64_PRIV_WIDTH-1:0] check_priv;
    wire [2:0] check_size;
    wire check_write;
    wire check_exec;
    reg allow_invert;
    wire check_allow = check_addr[12] ^ allow_invert;

    openrv64_mtl_pmp #(
        .XLATE_TAG_WIDTH(3),
        .FETCH_TAG_WIDTH(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .update_i(update),
        .lsu_req_valid_i(lsu_valid), .lsu_req_ready_o(lsu_ready),
        .lsu_req_addr_i(lsu_addr), .lsu_req_priv_i(lsu_priv),
        .lsu_req_size_i(lsu_size), .lsu_req_write_i(lsu_write),
        .lsu_req_exec_i(1'b0), .lsu_resp_valid_o(lsu_resp_valid),
        .lsu_resp_ready_i(lsu_resp_ready),
        .lsu_resp_allow_o(lsu_resp_allow),
        .ptw_req_valid_i(ptw_valid), .ptw_req_ready_o(ptw_ready),
        .ptw_req_addr_i(ptw_addr), .ptw_resp_valid_o(ptw_resp_valid),
        .ptw_resp_ready_i(1'b1), .ptw_resp_allow_o(ptw_resp_allow),
        .xlate_req_valid_i(xlate_valid),
        .xlate_req_ready_o(xlate_ready),
        .xlate_req_paddr_i(xlate_paddr),
        .xlate_req_priv_i(xlate_priv), .xlate_req_size_i(xlate_size),
        .xlate_req_write_i(xlate_write),
        .xlate_req_vaddr_i(xlate_vaddr),
        .xlate_req_tag_i(xlate_tag),
        .xlate_resp_valid_o(xlate_resp_valid),
        .xlate_resp_ready_i(xlate_resp_ready),
        .xlate_resp_allow_o(xlate_resp_allow),
        .xlate_resp_write_o(xlate_resp_write),
        .xlate_resp_vaddr_o(xlate_resp_vaddr),
        .xlate_resp_paddr_o(xlate_resp_paddr),
        .xlate_resp_tag_o(xlate_resp_tag),
        .fetch_req_valid_i(fetch_valid),
        .fetch_req_ready_o(fetch_ready),
        .fetch_req_vaddr_i(fetch_vaddr),
        .fetch_req_paddr_i(fetch_paddr),
        .fetch_req_priv_i(fetch_priv), .fetch_req_size_i(fetch_size),
        .fetch_req_tag_i(fetch_tag),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(1'b1),
        .fetch_resp_allow_o(fetch_resp_allow),
        .fetch_resp_vaddr_o(fetch_resp_vaddr),
        .fetch_resp_paddr_o(fetch_resp_paddr),
        .fetch_resp_priv_o(fetch_resp_priv),
        .fetch_resp_tag_o(fetch_resp_tag),
        .prefetch_req_valid_i(prefetch_valid),
        .prefetch_req_ready_o(prefetch_ready),
        .prefetch_req_addr_i(prefetch_addr),
        .prefetch_req_priv_i(prefetch_priv),
        .prefetch_resp_valid_o(prefetch_resp_valid),
        .prefetch_resp_ready_i(1'b1),
        .prefetch_resp_allow_o(prefetch_resp_allow),
        .check_valid_o(check_valid), .check_addr_o(check_addr),
        .check_priv_o(check_priv), .check_size_o(check_size),
        .check_write_o(check_write), .check_exec_o(check_exec),
        .check_allow_i(check_allow)
    );

    always #5 clk = ~clk;

    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            if (!condition)
                $fatal(1, "%s", message);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        update = 1'b0;
        lsu_valid = 1'b0;
        lsu_addr = 64'h1000;
        lsu_priv = `RV64_PRIV_S;
        lsu_size = 3'd3;
        lsu_write = 1'b1;
        lsu_resp_ready = 1'b0;
        ptw_valid = 1'b0;
        ptw_addr = 64'h5000;
        xlate_valid = 1'b0;
        xlate_paddr = 64'h3000;
        xlate_priv = `RV64_PRIV_U;
        xlate_size = 3'd2;
        xlate_write = 1'b0;
        xlate_vaddr = 64'hffff_ffff_4000_0120;
        xlate_tag = 3'd5;
        xlate_resp_ready = 1'b1;
        fetch_valid = 1'b0;
        fetch_vaddr = 64'hffff_ffff_8000_0000;
        fetch_paddr = 64'h2000;
        fetch_priv = `RV64_PRIV_S;
        fetch_size = 3'd6;
        fetch_tag = 2'd2;
        prefetch_valid = 1'b0;
        prefetch_addr = 64'h4000;
        prefetch_priv = `RV64_PRIV_S;
        allow_invert = 1'b0;

        repeat (2) step();
        rst_n = 1'b1;
        step();

        // LSU wins fixed priority, but the lower-priority fetch may enter the
        // check stage on the following cycle while LSU advances to response.
        lsu_valid = 1'b1;
        fetch_valid = 1'b1;
        #1;
        check(lsu_ready && !fetch_ready, "LSU did not win PMP priority");
        step();
        lsu_valid = 1'b0;
        #1;
        check(check_valid, "registered LSU check did not start");
        check(check_addr == 64'h1000 && check_write && !check_exec,
               "LSU check metadata changed");
        check(fetch_ready,
              "elastic PMP check stage did not accept the pending fetch");
        step();
        fetch_valid = 1'b0;
        check(lsu_resp_valid && lsu_resp_allow,
               "registered LSU verdict missing");
        check(check_valid && check_exec && (check_addr == 64'h2000),
              "fetch did not overlap the LSU response stage");
        step();
        check(lsu_resp_valid && check_valid,
              "elastic stages changed under LSU response backpressure");
        lsu_resp_ready = 1'b1;
        step();
        check(!lsu_resp_valid, "accepted LSU response did not retire");
        check(fetch_resp_valid && !fetch_resp_allow,
               "fetch deny verdict missing");
        check((fetch_resp_vaddr == 64'hffff_ffff_8000_0000) &&
               (fetch_resp_paddr == 64'h2000) &&
               (fetch_resp_tag == 2'd2),
               "fetch response metadata was not retained");
        step();
        check(!fetch_resp_valid, "accepted fetch response did not retire");

        // Two tagged translation checks are accepted and completed in
        // consecutive cycles.
        xlate_valid = 1'b1;
        xlate_paddr = 64'h3000;
        xlate_tag = 3'd5;
        #1;
        check(xlate_ready, "first xlate request was not accepted");
        step();
        check(check_valid && (check_addr == 64'h3000),
              "first xlate check did not use captured paddr");
        xlate_paddr = 64'h2000;
        xlate_tag = 3'd6;
        #1;
        check(xlate_ready,
              "PMP pipeline did not accept a consecutive xlate request");
        step();
        xlate_valid = 1'b0;
        check(xlate_resp_valid && xlate_resp_allow &&
               (xlate_resp_tag == 3'd5) &&
               (xlate_resp_paddr == 64'h3000) &&
               !xlate_resp_write &&
               (xlate_resp_vaddr == 64'hffff_ffff_4000_0120),
              "first pipelined xlate verdict was not retained");
        check(check_valid && (check_addr == 64'h2000),
              "second xlate check did not follow consecutively");
        step();
        check(xlate_resp_valid && !xlate_resp_allow &&
              (xlate_resp_tag == 3'd6) &&
              (xlate_resp_paddr == 64'h2000),
              "second pipelined xlate verdict was not retained");
        step();

        // A programming event with both stages occupied suppresses the stale
        // response and rechecks both requests in age order.  Change the
        // checker result on the update edge to detect stale verdict leakage.
        xlate_resp_ready = 1'b0;
        xlate_valid = 1'b1;
        xlate_paddr = 64'h1000;
        xlate_tag = 3'd1;
        #1;
        check(xlate_ready, "update test first request was not accepted");
        step();
        xlate_paddr = 64'h2000;
        xlate_tag = 3'd2;
        #1;
        check(xlate_ready, "update test second request was not accepted");
        step();
        xlate_valid = 1'b0;
        check(xlate_resp_valid && xlate_resp_allow &&
              (xlate_resp_tag == 3'd1),
              "update test did not fill both pipeline stages");
        allow_invert = 1'b1;
        update = 1'b1;
        #1;
        check(!xlate_resp_valid,
              "PMP update exposed a response from the old configuration");
        step();
        check(check_valid && (check_addr == 64'h1000) &&
              !xlate_resp_valid,
              "PMP update did not restart the older response first");
        update = 1'b0;
        step();
        check(xlate_resp_valid && !xlate_resp_allow &&
              (xlate_resp_tag == 3'd1),
              "older xlate retained its stale pre-update verdict");
        check(check_valid && (check_addr == 64'h2000),
              "younger xlate was lost during PMP update replay");
        xlate_resp_ready = 1'b1;
        step();
        check(xlate_resp_valid && xlate_resp_allow &&
              (xlate_resp_tag == 3'd2),
              "younger xlate retained its stale pre-update verdict");
        step();

        allow_invert = 1'b0;
        ptw_valid = 1'b1;
        #1;
        check(ptw_ready, "PTW request was not accepted");
        step();
        ptw_valid = 1'b0;
        check(check_valid && (check_addr == 64'h5000),
              "PTW check metadata changed");
        step();
        check(ptw_resp_valid && ptw_resp_allow,
              "PTW verdict missing from PMP pipeline");
        step();

        $display("PASS: pipelined MTL PMP arbitration and tagged responses");
        $finish;
    end
endmodule
