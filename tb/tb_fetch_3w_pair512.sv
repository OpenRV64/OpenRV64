`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_3w_pair512;
    logic clk;
    logic rst_n;
    logic restart;
    logic [63:0] restart_pc;
    logic invalidate;
    logic stall;
    logic flush;
    wire cancel;
    wire cancel_stash;
    wire req_valid;
    logic req_ready;
    wire [63:0] req_addr;
    wire req_stash;
    wire req_demand;
    logic resp_valid;
    wire resp_ready;
    logic [63:0] resp_addr;
    logic [255:0] resp_data;
    logic branch_pair_valid;
    logic [63:0] branch_predicted_addr;
    logic [63:0] branch_unpredicted_addr;
    wire pair512_req_valid;
    logic pair512_req_ready;
    wire [63:0] pair512_req_predicted_addr;
    wire [63:0] pair512_req_unpredicted_addr;
    logic pair512_resp_valid;
    logic [63:0] pair512_resp_predicted_addr;
    logic [255:0] pair512_resp_predicted_data;
    logic [63:0] pair512_resp_unpredicted_addr;
    logic [255:0] pair512_resp_unpredicted_data;
    wire [2:0] decode_valid;
    logic [2:0] decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    wire [191:0] trace_id;
    wire [63:0] stream_pc;
    wire [1:0] line_count;
    wire alt_restart_hit;
    integer ordinary_stash_requests;

    openrv64_fetch_3w #(
        .ENABLE_TRACE(0),
        .ENABLE_ALT_LOOKASIDE(4),
        .BRANCH_PAIR_STACK_DEPTH(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .restart_i(restart),
        .restart_pc_i(restart_pc), .invalidate_i(invalidate),
        .stall_i(stall), .flush_i(flush), .cancel_o(cancel),
        .cancel_stash_o(cancel_stash),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_addr_o(req_addr), .req_stash_o(req_stash),
        .req_demand_o(req_demand),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_addr_i(resp_addr), .resp_data_i(resp_data),
        .resp_access_fault_i(1'b0), .resp_page_fault_i(1'b0),
        .resp_stash_i(1'b0), .resp_demand_i(1'b1),
        .branch_pair_valid_i(branch_pair_valid),
        .branch_predicted_addr_i(branch_predicted_addr),
        .branch_unpredicted_addr_i(branch_unpredicted_addr),
        .ras_fetch_valid_i(1'b0), .ras_fetch_addr_i(64'd0),
        .pair512_req_valid_o(pair512_req_valid),
        .pair512_req_ready_i(pair512_req_ready),
        .pair512_req_predicted_addr_o(
            pair512_req_predicted_addr),
        .pair512_req_unpredicted_addr_o(
            pair512_req_unpredicted_addr),
        .pair512_resp_valid_i(pair512_resp_valid),
        .pair512_resp_predicted_addr_i(
            pair512_resp_predicted_addr),
        .pair512_resp_predicted_data_i(
            pair512_resp_predicted_data),
        .pair512_resp_unpredicted_addr_i(
            pair512_resp_unpredicted_addr),
        .pair512_resp_unpredicted_data_i(
            pair512_resp_unpredicted_data),
        .pair1024_req_valid_o(), .pair1024_req_ready_i(1'b0),
        .pair1024_req_predicted_addr_o(),
        .pair1024_req_unpredicted_addr_o(),
        .pair1024_resp_valid_i(1'b0),
        .pair1024_resp_predicted_addr_i(64'd0),
        .pair1024_resp_predicted_data_i(512'd0),
        .pair1024_resp_unpredicted_addr_i(64'd0),
        .pair1024_resp_unpredicted_data_i(512'd0),
        .prefetch_age_valid_i(3'b000),
        .prefetch_age_addr_i(192'd0),
        .alt_restart_eligible_i(1'b1),
        .decode_valid_o(decode_valid), .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus), .trace_id_i(64'd0),
        .trace_id_o(trace_id), .stream_pc_o(stream_pc),
        .line_count_o(line_count),
        .alt_restart_hit_o(alt_restart_hit)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n && req_valid && req_ready && req_stash)
            ordinary_stash_requests <= ordinary_stash_requests + 1;
    end

    function automatic [255:0] make_line(input integer base);
        integer word_index;
        begin
            make_line = 256'd0;
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                make_line[word_index*32 +: 32] = base + word_index;
        end
    endfunction

    function automatic [31:0] lane_instr(input integer lane);
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus;
        begin
            bus = decode_bus[
                lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                `RV64_FETCH_DECODE_BUS_WIDTH];
            lane_instr = bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check_redirect(
        input [63:0] pc,
        input [31:0] instruction0,
        input [31:0] instruction1,
        input [31:0] instruction2
    );
        begin
            restart_pc = pc;
            restart = 1'b1;
            #1;
            if (!alt_restart_hit)
                $fatal(1, "pair512 redirect did not hit pc=%h", pc);
            tick();
            restart = 1'b0;
            if (decode_valid != 3'b111 ||
                lane_instr(0) != instruction0 ||
                lane_instr(1) != instruction1 ||
                lane_instr(2) != instruction2)
                $fatal(1,
                    "pair512 preview did not cross 128-bit boundary");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        restart = 1'b0;
        restart_pc = 64'd0;
        invalidate = 1'b0;
        stall = 1'b0;
        flush = 1'b0;
        req_ready = 1'b1;
        resp_valid = 1'b0;
        resp_addr = 64'd0;
        resp_data = 256'd0;
        branch_pair_valid = 1'b0;
        branch_predicted_addr = 64'h202c;
        branch_unpredicted_addr = 64'h30a8;
        pair512_req_ready = 1'b1;
        pair512_resp_valid = 1'b0;
        pair512_resp_predicted_addr = 64'd0;
        pair512_resp_predicted_data = 256'd0;
        pair512_resp_unpredicted_addr = 64'd0;
        pair512_resp_unpredicted_data = 256'd0;
        decode_ready = 3'b000;
        ordinary_stash_requests = 0;

        repeat (3) tick();
        rst_n = 1'b1;

        branch_pair_valid = 1'b1;
        #1;
        if (!pair512_req_valid ||
            pair512_req_predicted_addr != 64'h2020 ||
            pair512_req_unpredicted_addr != 64'h30a0)
            $fatal(1, "pair512 request did not carry both blocks");
        tick();
        branch_pair_valid = 1'b0;

        pair512_resp_predicted_addr = 64'h2020;
        pair512_resp_predicted_data = make_line(32'h200);
        pair512_resp_unpredicted_addr = 64'h30a0;
        pair512_resp_unpredicted_data = make_line(32'h300);
        pair512_resp_valid = 1'b1;
        tick();
        pair512_resp_valid = 1'b0;

        check_redirect(64'h30a8, 32'h302, 32'h303, 32'h304);
        check_redirect(64'h202c, 32'h203, 32'h204, 32'h205);

        branch_pair_valid = 1'b1;
        #1;
        if (pair512_req_valid)
            $fatal(1, "pair512 repeated a resident tight-loop pair");
        tick();
        branch_pair_valid = 1'b0;
        if (ordinary_stash_requests != 0)
            $fatal(1, "pair512 mode used the ordinary 256-bit stash path");

        $display("PASS: fetch_3w 512-bit pair return stores 2x256 bits");
        $finish;
    end
endmodule
