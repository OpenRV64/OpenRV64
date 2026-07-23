`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_3w_sector;
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
    logic resp_access_fault;
    logic resp_page_fault;
    logic resp_stash;
    logic resp_demand;
    logic branch_pair_valid;
    logic [63:0] branch_predicted_addr;
    logic [63:0] branch_unpredicted_addr;
    logic [2:0] prefetch_age_valid;
    logic [191:0] prefetch_age_addr;
    wire [2:0] decode_valid;
    logic [2:0] decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    wire [191:0] trace_id;
    wire [63:0] stream_pc;
    wire [1:0] line_count;
    wire alt_restart_hit;

    integer request_count;
    reg [63:0] request_addr [0:31];
    reg request_stash [0:31];
    reg request_demand [0:31];

    openrv64_fetch_3w #(
        .ENABLE_TRACE(0),
        .ENABLE_ALT_LOOKASIDE(3),
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
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .resp_stash_i(resp_stash), .resp_demand_i(resp_demand),
        .branch_pair_valid_i(branch_pair_valid),
        .branch_predicted_addr_i(branch_predicted_addr),
        .branch_unpredicted_addr_i(branch_unpredicted_addr),
        .pair512_req_valid_o(), .pair512_req_ready_i(1'b0),
        .pair512_req_predicted_addr_o(),
        .pair512_req_unpredicted_addr_o(),
        .pair512_resp_valid_i(1'b0),
        .pair512_resp_predicted_addr_i(64'd0),
        .pair512_resp_predicted_data_i(256'd0),
        .pair512_resp_unpredicted_addr_i(64'd0),
        .pair512_resp_unpredicted_data_i(256'd0),
        .pair1024_req_valid_o(), .pair1024_req_ready_i(1'b0),
        .pair1024_req_predicted_addr_o(),
        .pair1024_req_unpredicted_addr_o(),
        .pair1024_resp_valid_i(1'b0),
        .pair1024_resp_predicted_addr_i(64'd0),
        .pair1024_resp_predicted_data_i(512'd0),
        .pair1024_resp_unpredicted_addr_i(64'd0),
        .pair1024_resp_unpredicted_data_i(512'd0),
        .prefetch_age_valid_i(prefetch_age_valid),
        .prefetch_age_addr_i(prefetch_age_addr),
        .alt_restart_eligible_i(1'b1),
        .decode_valid_o(decode_valid), .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus), .trace_id_i(64'd0),
        .trace_id_o(trace_id), .stream_pc_o(stream_pc),
        .line_count_o(line_count),
        .alt_restart_hit_o(alt_restart_hit)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n && req_valid && req_ready) begin
            request_addr[request_count] <= req_addr;
            request_stash[request_count] <= req_stash;
            request_demand[request_count] <= req_demand;
            request_count <= request_count + 1;
        end
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
            bus = decode_bus[lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
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

    task automatic return_line(
        input [63:0] addr,
        input integer base,
        input stash,
        input demand
    );
        begin
            resp_addr = addr;
            resp_data = make_line(base);
            resp_stash = stash;
            resp_demand = demand;
            resp_valid = 1'b1;
            tick();
            resp_valid = 1'b0;
            resp_stash = 1'b0;
            resp_demand = 1'b0;
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
        resp_access_fault = 1'b0;
        resp_page_fault = 1'b0;
        resp_stash = 1'b0;
        resp_demand = 1'b0;
        branch_pair_valid = 1'b0;
        branch_predicted_addr = 64'd0;
        branch_unpredicted_addr = 64'd0;
        prefetch_age_valid = 3'b000;
        prefetch_age_addr = 192'd0;
        decode_ready = 3'b000;
        request_count = 0;

        repeat (3) tick();
        rst_n = 1'b1;
        restart_pc = 64'h100;
        restart = 1'b1;
        invalidate = 1'b1;
        tick();
        restart = 1'b0;
        invalidate = 1'b0;

        while (request_count < 1) tick();
        if (request_addr[0] != 64'h100 || request_stash[0] ||
            !request_demand[0])
            $fatal(1, "sector test initial demand mismatch");
        return_line(64'h100, 32'h100, 1'b0, 1'b1);
        while (request_count < 2) tick();
        if (request_addr[1] != 64'h120 || request_stash[1] ||
            !request_demand[1])
            $fatal(1, "sector test lookahead demand mismatch");
        return_line(64'h120, 32'h108, 1'b0, 1'b1);

        // The predicted side is already fetch-resident.  Only the alternate
        // block may consume an additional request.
        branch_predicted_addr = 64'h110;
        branch_unpredicted_addr = 64'h184;
        branch_pair_valid = 1'b1;
        tick();
        branch_pair_valid = 1'b0;
        while (request_count < 3) tick();
        if (request_addr[2] != 64'h180 || !request_stash[2] ||
            request_demand[2])
            $fatal(1,
                   "sector mode did not issue exactly the alternate request");
        return_line(64'h180, 32'h200, 1'b1, 1'b0);
        repeat (2) tick();
        if (request_count != 3)
            $fatal(1, "sector mode redundantly fetched the predicted side");

        // A sector hit supplies the redirect immediately but still requests
        // the complete 256-bit block through the standard demand path.
        restart_pc = 64'h184;
        restart = 1'b1;
        #1;
        if (!alt_restart_hit)
            $fatal(1, "alternate 128-bit sector did not hit");
        tick();
        restart = 1'b0;
        while (request_count < 4) tick();
        if (request_addr[3] != 64'h180 || request_stash[3] ||
            !request_demand[3])
            $fatal(1, "sector hit did not trigger a full demand load");
        if (decode_valid != 3'b111 ||
            lane_instr(0) != 32'h201 ||
            lane_instr(1) != 32'h202 ||
            lane_instr(2) != 32'h203)
            $fatal(1, "sector preview did not feed the first bundle");
        return_line(64'h180, 32'h200, 1'b0, 1'b1);

        // When both a new architectural target and an alternate are absent,
        // the target demand must be accepted first.
        branch_predicted_addr = 64'h310;
        branch_unpredicted_addr = 64'h384;
        restart_pc = 64'h310;
        branch_pair_valid = 1'b1;
        restart = 1'b1;
        tick();
        branch_pair_valid = 1'b0;
        restart = 1'b0;
        while (request_count < 5) tick();
        if (request_addr[4] != 64'h300 || request_stash[4] ||
            !request_demand[4])
            $fatal(1, "background alternate outranked architectural demand");

        $display("PASS: 128-bit paired sector lookaside");
        $finish;
    end
endmodule
