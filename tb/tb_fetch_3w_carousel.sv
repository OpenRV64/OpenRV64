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
        if (!dut.ras_line_valid_q || dut.ras_line_pending_q ||
            (dut.ras_line_addr_q != 64'h300) ||
            !dut.carousel_pending_valid_q[0] ||
            (dut.carousel_pending_addr_q[0] != 64'h380))
            $fatal(1, "late RAS response disturbed carousel ownership");
        dut.consume_pc_q = 64'h310;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h310)
            $fatal(1, "carousel RAS target did not reach decode");
        tick();
        if (!dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h300) ||
            dut.carousel_pending_valid_q[0] ||
            dut.ras_line_valid_q ||
            (decode_valid != 3'b111))
            $fatal(1, "demanded RAS line was not promoted to carousel");
        return_line(64'h380, 32'h1c0);

        // A FAL request owns the sixth block and does not consume a carousel
        // pending tag.
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
            $fatal(1, "FAL request did not use its dedicated slot");
        return_qualified(64'h500, 32'h200, 1'b1, 1'b0);
        if (!dut.fal_line_valid_q || dut.fal_line_pending_q ||
            (dut.fal_line_addr_q != 64'h500))
            $fatal(1, "FAL response did not fill its dedicated slot");
        restart_pc = 64'h510;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h510)
            $fatal(1, "FAL slot did not serve redirected fetch");
        dut.pair_unpredicted_valid_q = 1'b1;
        dut.pair_unpredicted_addr_q = 64'h520;
        fal_request_base = request_count;
        tick();
        if ((request_count != fal_request_base + 1) ||
            (request_addr[fal_request_base] != 64'h520) ||
            !request_stash[fal_request_base] ||
            request_demand[fal_request_base] ||
            !dut.line_valid_q[0] ||
            (dut.line_addr_q[0] != 64'h500) ||
            !dut.fal_line_pending_q ||
            (dut.fal_line_addr_q != 64'h520) ||
            (decode_valid != 3'b111))
            $fatal(1,
                "FAL reallocation lost demanded line instead of promoting it");
        return_qualified(64'h520, 32'h220, 1'b1, 1'b0);
        if (!dut.fal_line_valid_q || dut.fal_line_pending_q)
            $fatal(1, "replacement FAL response did not become resident");
        dut.consume_pc_q = 64'h500;
        dut.next_req_addr_q = 64'h520;
        tick();
        if (!dut.line_valid_q[1] ||
            (dut.line_addr_q[1] != 64'h520) ||
            dut.fal_line_valid_q ||
            (dut.next_req_addr_q != 64'h540))
            $fatal(1,
                "future FAL demand was not promoted at carousel cursor");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h520;
        tick();
        prefetch_age_valid = 3'b000;
        dut.consume_pc_q = 64'h528;
        #1;
        if (decode_valid != 3'b111 || stream_pc != 64'h528)
            $fatal(1, "aged FAL demand did not survive in carousel");

        // A stash-only FAL may be aged downstream without a response.  Its
        // pending tag must not suppress a later same-line demand.
        dut.fal_line_valid_q = 1'b0;
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
        if (!dut.ras_line_valid_q || dut.ras_line_pending_q ||
            !dut.fal_line_pending_q)
            $fatal(1, "RAS demand response consumed FAL ownership");
        prefetch_age_valid = 3'b001;
        prefetch_age_addr[63:0] = 64'h600;
        tick();
        prefetch_age_valid = 3'b000;
        if (dut.fal_line_valid_q || dut.fal_line_pending_q)
            $fatal(1, "retirement age did not release FAL slot");
        dut.ras_line_valid_q = 1'b0;
        return_qualified(64'h600, 32'h280, 1'b1, 1'b1);
        if (!dut.line_valid_q[0] || (dut.line_addr_q[0] != 64'h600))
            $fatal(1, "useful late forced demand did not fill carousel");

        $display("PASS: 4-demand + RAS + FAL fetch structure and aging");
        $finish;
    end
endmodule
