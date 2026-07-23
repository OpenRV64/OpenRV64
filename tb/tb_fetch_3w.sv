`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_3w;
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
    integer restart_request_base;
    integer replay_request_base;
    integer lookaside_request_base;
    reg [63:0] request_addr [0:15];
    reg request_stash [0:15];
    reg request_demand [0:15];

    openrv64_fetch_3w #(
        .ENABLE_TRACE(1),
        .ENABLE_ALT_LOOKASIDE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .restart_i(restart),
        .restart_pc_i(restart_pc), .invalidate_i(invalidate),
        .stall_i(stall), .flush_i(flush), .cancel_o(cancel),
        .cancel_stash_o(cancel_stash),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_addr_o(req_addr), .req_stash_o(req_stash),
        .req_demand_o(req_demand),
        .resp_valid_i(resp_valid),
        .resp_ready_o(resp_ready), .resp_addr_i(resp_addr),
        .resp_data_i(resp_data),
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .resp_stash_i(resp_stash),
        .resp_demand_i(resp_demand),
        .branch_pair_valid_i(branch_pair_valid),
        .branch_predicted_addr_i(branch_predicted_addr),
        .branch_unpredicted_addr_i(branch_unpredicted_addr),
        .prefetch_age_valid_i(prefetch_age_valid),
        .prefetch_age_addr_i(prefetch_age_addr),
        .alt_restart_eligible_i(1'b1),
        .decode_valid_o(decode_valid), .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus), .trace_id_i(64'd100),
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

    function automatic [31:0] lane_instr(input integer lane);
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus;
        begin
            bus = decode_bus[lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                             `RV64_FETCH_DECODE_BUS_WIDTH];
            lane_instr = bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
        end
    endfunction

    function automatic [63:0] lane_pc(input integer lane);
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus;
        begin
            bus = decode_bus[lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                             `RV64_FETCH_DECODE_BUS_WIDTH];
            lane_pc = bus[`RV64_FETCH_DECODE_BUS_PC_BITS];
        end
    endfunction

    function automatic [255:0] make_line(input integer base);
        integer word_index;
        begin
            make_line = 256'd0;
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                make_line[word_index*32 +: 32] = base + word_index;
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
            resp_valid = 1;
            tick();
            resp_valid = 0;
            resp_stash = 0;
            resp_demand = 0;
        end
    endtask

    task automatic expect_bundle(
        input [63:0] pc0,
        input [31:0] instr0,
        input [31:0] instr1,
        input [31:0] instr2
    );
        integer cycles;
        begin
            cycles = 0;
            while (decode_valid != 3'b111 && cycles < 20) begin
                tick();
                cycles = cycles + 1;
            end
            if (decode_valid != 3'b111 || lane_pc(0) != pc0 ||
                lane_pc(1) != pc0 + 4 || lane_pc(2) != pc0 + 8 ||
                lane_instr(0) != instr0 || lane_instr(1) != instr1 ||
                lane_instr(2) != instr2)
                $fatal(1, "bundle mismatch pc=%h valid=%b insn=%h/%h/%h",
                    lane_pc(0), decode_valid, lane_instr(0), lane_instr(1),
                    lane_instr(2));
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        restart = 0;
        restart_pc = 0;
        invalidate = 0;
        stall = 0;
        flush = 0;
        req_ready = 1;
        resp_valid = 0;
        resp_addr = 0;
        resp_data = 0;
        resp_access_fault = 0;
        resp_page_fault = 0;
        resp_stash = 0;
        resp_demand = 0;
        branch_pair_valid = 0;
        branch_predicted_addr = 0;
        branch_unpredicted_addr = 0;
        prefetch_age_valid = 0;
        prefetch_age_addr = 0;
        decode_ready = 0;
        request_count = 0;
        repeat (3) tick();
        rst_n = 1;
        restart_pc = 64'h18;
        invalidate = 1;
        restart = 1;
        tick();
        if (!cancel) $fatal(1, "restart must cancel old bus requests");
        restart = 0;
        invalidate = 0;

        // Fetch issues only the current line and cannot launch another until
        // that response returns.  Once current is present it asks for exactly
        // one following line so a three-wide bundle can cross the boundary.
        while (request_count < 1) tick();
        if (request_addr[0] != 64'h0 || line_count != 1)
            $fatal(1, "fetch_3w current-line request mismatch");
        repeat (3) tick();
        if (request_count != 1)
            $fatal(1, "fetch_3w issued more than one request at a time");
        return_line(64'h0, 32'h100, 1'b0, 1'b1);
        while (request_count < 2) tick();
        if (request_addr[1] != 64'h20 || line_count != 2)
            $fatal(1, "fetch_3w did not request exactly one line ahead");
        repeat (3) tick();
        if (request_count != 2)
            $fatal(1, "fetch_3w requested beyond its one-line lookahead");
        return_line(64'h20, 32'h108, 1'b0, 1'b1);
        expect_bundle(64'h18, 32'h106, 32'h107, 32'h108);
        if (trace_id[63:0] != 100 || trace_id[127:64] != 101 ||
            trace_id[191:128] != 102)
            $fatal(1, "three-wide trace IDs are not consecutive");

        decode_ready = 3'b111;
        tick();
        expect_bundle(64'h24, 32'h109, 32'h10a, 32'h10b);

        // A non-ready second lane means only lane zero is consumed.
        decode_ready = 3'b001;
        tick();
        if (stream_pc != 64'h28)
            $fatal(1, "partial decode acceptance advanced by more than one");
        expect_bundle(64'h28, 32'h10a, 32'h10b, 32'h10c);

        // Redirects discard the fetch-side bridge registers.  The target is
        // requested again and is expected to hit in L1I in the integrated
        // design; fetch itself owns no loop-residency policy.
        decode_ready = 0;
        replay_request_base = request_count;
        restart_pc = 64'h18;
        restart = 1;
        tick();
        restart = 0;
        if (stream_pc != 64'h18)
            $fatal(1, "resident redirect did not restore target PC");
        while (request_count < replay_request_base + 1) tick();
        if (request_addr[replay_request_base] != 64'h0)
            $fatal(1, "redirect did not request its target line");
        return_line(64'h0, 32'h100, 1'b0, 1'b1);
        while (request_count < replay_request_base + 2) tick();
        if (request_addr[replay_request_base + 1] != 64'h20)
            $fatal(1, "redirect did not restore one-line lookahead");
        return_line(64'h20, 32'h108, 1'b0, 1'b1);
        expect_bundle(64'h18, 32'h106, 32'h107, 32'h108);

        // A branch launches ordinary 256-bit requests in predicted then
        // unpredicted order.  The predicted response also satisfies the
        // redirected architectural demand; both responses enter the stash.
        lookaside_request_base = request_count;
        branch_predicted_addr = 64'h110;
        branch_unpredicted_addr = 64'h188;
        branch_pair_valid = 1'b1;
        restart_pc = 64'h110;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        branch_pair_valid = 1'b0;
        while (request_count < lookaside_request_base + 2) tick();
        if ((request_addr[lookaside_request_base] != 64'h100) ||
            !request_stash[lookaside_request_base] ||
            !request_demand[lookaside_request_base] ||
            (request_addr[lookaside_request_base + 1] != 64'h180) ||
            !request_stash[lookaside_request_base + 1] ||
            request_demand[lookaside_request_base + 1])
            $fatal(1,
                   "branch pair was not predicted-then-unpredicted");
        return_line(64'h100, 32'h140, 1'b1, 1'b1);
        expect_bundle(64'h110, 32'h144, 32'h145, 32'h146);
        return_line(64'h180, 32'h160, 1'b1, 1'b0);

        // Repeated loop branches do not reissue a half-line while both
        // aligned addresses remain present in the fetch-path stash.
        branch_pair_valid = 1'b1;
        tick();
        branch_pair_valid = 1'b0;
        if (dut.pair_predicted_valid_q ||
            dut.pair_unpredicted_valid_q)
            $fatal(1, "resident branch pair was redundantly queued");

        restart_pc = 64'h188;
        restart = 1'b1;
        #1;
        if (!alt_restart_hit)
            $fatal(1, "alternate-path redirect did not hit lookaside");
        if (cancel_stash)
            $fatal(1, "ordinary redirect canceled stash requests");
        tick();
        restart = 1'b0;
        if (line_count != 1)
            $fatal(1, "256-bit alternate path did not seed one block");
        expect_bundle(64'h188, 32'h162, 32'h163, 32'h164);

        // Retirement aging removes the unused path from the fetch lookaside,
        // matching the L1I policy rather than leaving stale alternate data.
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h180;
        tick();
        prefetch_age_valid = 3'b000;
        lookaside_request_base = request_count;
        restart = 1'b1;
        #1;
        if (alt_restart_hit)
            $fatal(1, "retirement aging retained alternate-path line");
        tick();
        restart = 1'b0;
        while (request_count < lookaside_request_base + 1) tick();
        if ((request_addr[lookaside_request_base] != 64'h180) ||
            request_stash[lookaside_request_base])
            $fatal(1, "aged alternate path did not fall back to L1I");

        // Both branch sides in one 256-bit block coalesce to one qualified
        // request rather than fetching the same block twice.
        lookaside_request_base = request_count;
        branch_predicted_addr = 64'h248;
        branch_unpredicted_addr = 64'h25c;
        branch_pair_valid = 1'b1;
        restart_pc = 64'h248;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        branch_pair_valid = 1'b0;
        while (request_count < lookaside_request_base + 1) tick();
        repeat (2) tick();
        if ((request_count != lookaside_request_base + 1) ||
            (request_addr[lookaside_request_base] != 64'h240) ||
            !request_stash[lookaside_request_base] ||
            !request_demand[lookaside_request_base])
            $fatal(1, "same-block branch pair did not coalesce");

        // A context-changing restart follows the same one-at-a-time contract.
        restart_request_base = request_count;
        restart_pc = 64'h84;
        invalidate = 1;
        restart = 1;
        #1;
        if (!cancel_stash)
            $fatal(1, "invalidating restart preserved stash requests");
        tick();
        restart = 0;
        invalidate = 0;
        if (stream_pc != 64'h84 || line_count != 0)
            $fatal(1, "invalidating restart did not reset fetch bridge lines");
        while (request_count < restart_request_base + 1) tick();
        repeat (3) tick();
        if (request_count != restart_request_base + 1 ||
            request_addr[restart_request_base] != 64'h80)
            $fatal(1, "restart request alignment mismatch");
        return_line(64'h80, 32'h120, 1'b0, 1'b1);
        while (request_count < restart_request_base + 2) tick();
        if (request_addr[restart_request_base + 1] != 64'ha0)
            $fatal(1, "restart lookahead alignment mismatch");

        $display("PASS: 3-wide current-line fetch with one-line lookahead");
        $finish;
    end
endmodule
