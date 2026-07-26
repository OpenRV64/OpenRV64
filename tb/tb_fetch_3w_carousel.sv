`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_3w_carousel;
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
    logic resp_stash;
    logic resp_demand;
    logic ras_fetch_valid;
    logic [63:0] ras_fetch_addr;
    logic [2:0] prefetch_age_valid;
    logic [191:0] prefetch_age_addr;
    wire [2:0] decode_valid;
    logic [2:0] decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    wire [191:0] trace_id;
    wire [63:0] stream_pc;
    wire [2:0] line_count;

    integer request_count;
    integer alias_request_base;
    integer fal_request_base;
    integer ingress_test_index;
    reg [63:0] request_addr [0:31];
    reg request_stash [0:31];
    reg request_demand [0:31];

    openrv64_fetch_3w #(
        .ENABLE_CAROUSEL(1),
        .ENABLE_TRACE(1),
        .ENABLE_ALT_LOOKASIDE(3)
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
        .resp_stash_i(resp_stash), .resp_demand_i(resp_demand),
        .branch_pair_valid_i(1'b0),
        .branch_predicted_addr_i(64'd0),
        .branch_unpredicted_addr_i(64'd0),
        .ras_fetch_valid_i(ras_fetch_valid),
        .ras_fetch_addr_i(ras_fetch_addr),
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
        .alt_restart_eligible_i(1'b0),
        .decode_valid_o(decode_valid), .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus), .trace_id_i(64'd0),
        .trace_id_o(trace_id), .stream_pc_o(stream_pc),
        .line_count_o(line_count), .alt_restart_hit_o()
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
        integer index;
        begin
            make_line = 256'd0;
            for (index = 0; index < 8; index = index + 1)
                make_line[index*32 +: 32] = base + index;
        end
    endfunction

    function automatic integer ingress_slot(input [63:0] addr);
        integer index;
        begin
            ingress_slot = -1;
            for (index = 0; index < 4; index = index + 1) begin
                if (dut.ingress_valid_q[index] &&
                    (dut.ingress_addr_q[index][63:5] == addr[63:5]))
                    ingress_slot = index;
            end
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic return_line(input [63:0] addr, input integer base);
        begin
            resp_addr = addr;
            resp_data = make_line(base);
            resp_stash = 1'b0;
            resp_demand = 1'b1;
            resp_valid = 1'b1;
            tick();
            resp_valid = 1'b0;
            resp_demand = 1'b0;
        end
    endtask

    task automatic return_qualified(
        input [63:0] addr,
        input integer base,
        input logic stash,
        input logic demand
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
        resp_stash = 1'b0;
        resp_demand = 1'b0;
        ras_fetch_valid = 1'b0;
        ras_fetch_addr = 64'd0;
        prefetch_age_valid = 3'b000;
        prefetch_age_addr = 192'd0;
        decode_ready = 3'b000;
        request_count = 0;

        repeat (3) tick();
        rst_n = 1'b1;
        restart_pc = 64'h18;
        invalidate = 1'b1;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        invalidate = 1'b0;

        while (request_count < 4) tick();
        if ((request_addr[0] != 64'h00) ||
            (request_addr[1] != 64'h20) ||
            (request_addr[2] != 64'h40) ||
            (request_addr[3] != 64'h60))
            $fatal(1, "carousel did not launch four sequential blocks");
        if (line_count != 4)
            $fatal(1, "carousel did not retain four pending slots");
        repeat (3) tick();
        if (request_count != 4)
            $fatal(1, "carousel requested beyond its four-block window");

        // Tagged responses may complete independently.
        return_line(64'h40, 32'h110);
        return_line(64'h00, 32'h100);
        return_line(64'h60, 32'h118);
        return_line(64'h20, 32'h108);
        if (decode_valid != 3'b111 || stream_pc != 64'h18)
            $fatal(1, "carousel did not decode across a block boundary");

        // Advancing consumption rolls the cursor forward by one block.
        decode_ready = 3'b111;
        tick();
        while (request_count < 5) tick();
        if (request_addr[4] != 64'h80)
            $fatal(1, "carousel cursor did not roll forward");

        // A RAS redirect replaces the old stream on the redirect edge.
        decode_ready = 3'b000;
        restart_pc = 64'h310;
        ras_fetch_addr = 64'h310;
        ras_fetch_valid = 1'b1;
        restart = 1'b1;
        #1;
        if (!cancel || cancel_stash || !req_valid || !req_stash ||
            !req_demand || (req_addr != 64'h300))
            $fatal(1, "carousel RAS replacement request mismatch");
        tick();
        restart = 1'b0;
        ras_fetch_valid = 1'b0;
        if (!dut.ras_line_pending_q ||
            (dut.ras_line_addr_q != 64'h300) ||
            dut.carousel_pending_valid_q[0])
            $fatal(1, "RAS request did not use its dedicated slot");

        // A normal demand may reuse the same carousel index without stealing
        // ownership of the outstanding RAS response.
        alias_request_base = request_count;
        dut.consume_pc_q = 64'h320;
        dut.next_req_addr_q = 64'h380;
        while (request_count == alias_request_base) tick();
        if ((request_addr[alias_request_base] != 64'h380) ||
            !dut.carousel_pending_valid_q[0] ||
            (dut.carousel_pending_addr_q[0] != 64'h380))
            $fatal(1, "carousel did not remain independent of RAS slot");
        return_qualified(64'h300, 32'h180, 1'b1, 1'b1);
        if (dut.ras_line_pending_q ||
            (dut.ras_line_addr_q != 64'h300) ||
            (ingress_slot(64'h300) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h300)] != 2'd1) ||
            !dut.carousel_pending_valid_q[0] ||
            (dut.carousel_pending_addr_q[0] != 64'h380))
            $fatal(1, "RAS response did not enter ingress independently");
        dut.consume_pc_q = 64'h310;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h310)
            $fatal(1, "ingress RAS target did not reach decode");
        tick();
        if (!dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h300) ||
            !dut.carousel_pending_valid_q[0] ||
            (dut.carousel_pending_addr_q[0] != 64'h380) ||
            (ingress_slot(64'h300) >= 0) ||
            (decode_valid != 3'b111))
            $fatal(1, "demanded RAS ingress line was not promoted");
        return_line(64'h380, 32'h1c0);
        if (!dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h300) ||
            dut.carousel_pending_valid_q[0] ||
            (ingress_slot(64'h380) < 0))
            $fatal(1, "late response did not remain in ingress");

        // Back-to-back branch contexts may each retain their own completed
        // 32-byte FAL half. These are not two sides of one branch.
        // The request owner remains scalar because fills are serialized, but
        // neither resident line has a fixed FAL slot.
        dut.consume_pc_q = 64'h700;
        dut.next_req_addr_q = 64'h1000;
        dut.pair_predicted_valid_q = 1'b0;
        dut.pair_unpredicted_valid_q = 1'b1;
        dut.pair_unpredicted_addr_q = 64'h500;
        fal_request_base = request_count;
        while (request_count == fal_request_base) tick();
        if ((request_addr[fal_request_base] != 64'h500) ||
            !request_stash[fal_request_base] ||
            request_demand[fal_request_base] ||
            !dut.fal_line_pending_q ||
            (dut.fal_line_addr_q != 64'h500))
            $fatal(1, "first back-to-back FAL request mismatch");
        return_qualified(64'h500, 32'h200, 1'b1, 1'b0);
        if (dut.fal_line_pending_q ||
            (ingress_slot(64'h500) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h500)] != 2'd2))
            $fatal(1, "first branch FAL did not enter ingress");

        dut.pair_unpredicted_valid_q = 1'b1;
        dut.pair_unpredicted_addr_q = 64'h520;
        fal_request_base = request_count;
        while (request_count == fal_request_base) tick();
        if ((request_addr[fal_request_base] != 64'h520) ||
            !request_stash[fal_request_base] ||
            request_demand[fal_request_base] ||
            !dut.fal_line_pending_q ||
            (ingress_slot(64'h500) < 0))
            $fatal(1, "second back-to-back FAL request lost first line");
        return_qualified(64'h520, 32'h220, 1'b1, 1'b0);
        if (dut.fal_line_pending_q ||
            (ingress_slot(64'h500) < 0) ||
            (ingress_slot(64'h520) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h500)] != 2'd2) ||
            (dut.ingress_origin_q[ingress_slot(64'h520)] != 2'd2))
            $fatal(1,
                "two back-to-back branch FAL halves not resident");

        restart_pc = 64'h510;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h510)
            $fatal(1, "first FAL ingress line did not serve redirect");
        tick();
        if (!dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h500) ||
            (ingress_slot(64'h500) >= 0) ||
            (ingress_slot(64'h520) < 0))
            $fatal(1, "first FAL promotion disturbed second context");
        dut.consume_pc_q = 64'h500;
        dut.next_req_addr_q = 64'h520;
        tick();
        if (!dut.line_valid_q[1] ||
            (dut.line_addr_q[1] != 64'h520) ||
            (ingress_slot(64'h520) >= 0) ||
            (dut.next_req_addr_q != 64'h540))
            $fatal(1,
                "second branch FAL was not promoted at demand cursor");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h520;
        tick();
        prefetch_age_valid = 3'b000;
        dut.consume_pc_q = 64'h528;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h528)
            $fatal(1, "aged FAL demand did not survive in carousel");

        // When a queued FAL line is also selected as the active demand, keep
        // both ownership tags. FAL retirement aging may release the
        // speculative owner, but must not remove the durable demand owner.
        dut.consume_pc_q = 64'h600;
        dut.next_req_addr_q = 64'h620;
        dut.line_valid_q[1] = 1'b0;
        dut.carousel_pending_valid_q[1] = 1'b0;
        dut.pair_unpredicted_valid_q = 1'b1;
        dut.pair_unpredicted_addr_q = 64'h620;
        fal_request_base = request_count;
        while (request_count == fal_request_base) tick();
        if ((request_addr[fal_request_base] != 64'h620) ||
            !request_stash[fal_request_base] ||
            !request_demand[fal_request_base] ||
            !dut.fal_line_pending_q ||
            !dut.carousel_pending_valid_q[1] ||
            (dut.carousel_pending_addr_q[1] != 64'h620))
            $fatal(1, "demanded FAL did not retain dual ownership");
        stall = 1'b1;
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h620;
        tick();
        prefetch_age_valid = 3'b000;
        if (dut.fal_line_pending_q ||
            !dut.carousel_pending_valid_q[1])
            $fatal(1, "FAL age removed durable demand ownership");
        return_qualified(64'h620, 32'h260, 1'b1, 1'b1);
        stall = 1'b0;
        if (dut.carousel_pending_valid_q[1] ||
            (ingress_slot(64'h620) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h620)] != 2'd0))
            $fatal(1, "aged demanded FAL response was not recovered");

        // A duplicate speculative FAL completion for an already demanded
        // line may refresh its data, but must not downgrade its ownership.
        // Otherwise the duplicate branch context can age out the only copy.
        dut.fal_line_pending_q = 1'b1;
        dut.fal_line_addr_q = 64'h620;
        return_qualified(64'h620, 32'h2a0, 1'b1, 1'b0);
        if ((ingress_slot(64'h620) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h620)] != 2'd0))
            $fatal(1, "duplicate FAL downgraded demanded ingress line");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h620;
        tick();
        prefetch_age_valid = 3'b000;
        if ((ingress_slot(64'h620) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h620)] != 2'd0))
            $fatal(1, "duplicate FAL age removed demanded ingress line");

        // If the same completion satisfies live FAL and demand owners, demand
        // provenance must win even when this is a new ingress allocation.
        dut.carousel_pending_valid_q[2] = 1'b1;
        dut.carousel_pending_addr_q[2] = 64'h640;
        dut.fal_line_pending_q = 1'b1;
        dut.fal_line_addr_q = 64'h640;
        return_qualified(64'h640, 32'h2e0, 1'b1, 1'b1);
        if (dut.carousel_pending_valid_q[2] ||
            dut.fal_line_pending_q ||
            (ingress_slot(64'h640) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h640)] != 2'd0))
            $fatal(1, "simultaneous FAL and demand response lost demand");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h640;
        tick();
        prefetch_age_valid = 3'b000;
        if ((ingress_slot(64'h640) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h640)] != 2'd0))
            $fatal(1, "simultaneous-owner demand was FAL-aged");

        // A matching response releases its old pending owner, but an
        // out-of-window line must not replace a useful same-index demand on
        // the edge where the cursor consumes that demand.
        dut.consume_pc_q = 64'h840;
        dut.next_req_addr_q = 64'h880;
        dut.line_valid_q[0] = 1'b1;
        dut.line_addr_q[0] = 64'h880;
        dut.line_data_q[0] = make_line(32'h300);
        dut.line_sector_valid_q[0] = 2'b11;
        dut.carousel_pending_valid_q[0] = 1'b1;
        dut.carousel_pending_addr_q[0] = 64'h800;
        return_line(64'h800, 32'h340);
        if (!dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h880) ||
            dut.carousel_pending_valid_q[0] ||
            (dut.next_req_addr_q != 64'h8a0) ||
            (ingress_slot(64'h800) < 0))
            $fatal(1,
                "late alias response bypassed ingress or overwrote demand");

        // If the demanded alias is not resident, retain the cursor until the
        // older same-slot owner completes instead of rebinding its tag.
        dut.line_valid_q[0] = 1'b0;
        dut.carousel_pending_valid_q[0] = 1'b1;
        dut.carousel_pending_addr_q[0] = 64'h800;
        dut.next_req_addr_q = 64'h880;
        fal_request_base = request_count;
        repeat (2) tick();
        if ((request_count != fal_request_base) ||
            (dut.next_req_addr_q != 64'h880))
            $fatal(1, "busy carousel slot did not hold demand cursor");
        return_line(64'h800, 32'h380);
        while (request_count == fal_request_base) tick();
        if ((request_addr[fal_request_base] != 64'h880) ||
            !request_demand[fal_request_base])
            $fatal(1, "released carousel slot did not issue held demand");

        // A speculative completion must not evict any of four ingress lines
        // covering the active demand window. With no safe victim, drop it.
        dut.consume_pc_q = 64'h900;
        dut.next_req_addr_q = 64'ha00;
        dut.line_valid_q[0] = 1'b1;
        dut.line_addr_q[0] = 64'h900;
        dut.line_data_q[0] = make_line(32'h3f0);
        dut.line_sector_valid_q[0] = 2'b11;
        for (ingress_test_index = 0; ingress_test_index < 4;
             ingress_test_index = ingress_test_index + 1) begin
            dut.ingress_valid_q[ingress_test_index] = 1'b1;
            dut.ingress_addr_q[ingress_test_index] =
                64'h900 + ingress_test_index * 32;
            dut.ingress_data_q[ingress_test_index] =
                make_line(32'h400 + ingress_test_index * 8);
            dut.ingress_origin_q[ingress_test_index] = 2'd0;
        end
        dut.fal_line_pending_q = 1'b1;
        dut.fal_line_addr_q = 64'ha00;
        return_qualified(64'ha00, 32'h440, 1'b1, 1'b0);
        if (ingress_slot(64'ha00) >= 0)
            $fatal(1, "speculative response evicted active ingress line");
        for (ingress_test_index = 0; ingress_test_index < 4;
             ingress_test_index = ingress_test_index + 1) begin
            if (!dut.ingress_valid_q[ingress_test_index] ||
                (dut.ingress_addr_q[ingress_test_index] !=
                    (64'h900 + ingress_test_index * 32)))
                $fatal(1, "active ingress protection lost demand line");
        end

        // A stash-only FAL may be aged downstream without a response.  Its
        // pending tag must not suppress a later same-line demand.
        dut.fal_line_pending_q = 1'b1;
        dut.fal_line_addr_q = 64'h600;
        restart_pc = 64'h610;
        ras_fetch_addr = 64'h610;
        ras_fetch_valid = 1'b1;
        restart = 1'b1;
        #1;
        if (!req_valid || !req_stash || !req_demand ||
            (req_addr != 64'h600))
            $fatal(1, "pending FAL suppressed same-line RAS demand");
        tick();
        restart = 1'b0;
        ras_fetch_valid = 1'b0;
        if (!dut.ras_line_pending_q || !dut.fal_line_pending_q)
            $fatal(1, "same-line RAS and FAL ownership was not independent");
        return_qualified(64'h600, 32'h240, 1'b1, 1'b1);
        if (dut.ras_line_pending_q || !dut.fal_line_pending_q ||
            (ingress_slot(64'h600) < 0) ||
            (dut.ingress_origin_q[ingress_slot(64'h600)] != 2'd1))
            $fatal(1, "RAS demand response consumed FAL ownership");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h600;
        tick();
        prefetch_age_valid = 3'b000;
        if (dut.fal_line_pending_q ||
            !((ingress_slot(64'h600) >= 0) ||
              (dut.line_valid_q[0] &&
               (dut.line_addr_q[0] == 64'h600))))
            $fatal(1, "FAL age damaged independent RAS ingress ownership");
        return_qualified(64'h600, 32'h280, 1'b1, 1'b1);
        tick();
        if (!dut.line_valid_q[0] || (dut.line_addr_q[0] != 64'h600))
            $fatal(1, "useful late forced demand was not promoted");

        $display("PASS: 4-demand + 4-ingress fetch banks and aging");
        $finish;
    end
endmodule
