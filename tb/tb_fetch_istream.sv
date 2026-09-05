`timescale 1ns/1ps

module tb_fetch_istream;
    logic clk;
    logic rst_n;
    logic restart;
    logic [63:0] restart_pc;
    logic redirect;
    logic [63:0] redirect_pc;
    logic invalidate;
    logic flush;
    logic stall;
    wire cancel;

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

    wire btb_lookup_valid;
    logic btb_lookup_ready;
    wire [63:0] btb_lookup_pc;
    wire [31:0] btb_lookup_request_id;
    logic btb_response_valid;
    logic [31:0] btb_response_request_id;
    logic btb_response_hit;
    logic [63:0] btb_response_control_pc;
    logic [63:0] btb_response_control_end_pc;
    logic [63:0] btb_response_successor_pc;
    logic btb_response_taken;
    logic [31:0] btb_response_prediction_token;

    wire istream_valid;
    wire [95:0] istream_data;
    wire [5:0] istream_halfword_valid;
    wire [5:0] istream_access_fault;
    wire [5:0] istream_page_fault;
    logic istream_advance_half;
    logic [3:0] istream_consume_halfwords;
    wire [63:0] stream_pc;
    wire istream_prediction_valid;
    wire [63:0] istream_control_pc;
    wire [63:0] istream_control_end_pc;
    wire [63:0] istream_prediction_successor;
    wire istream_prediction_taken;
    wire [31:0] istream_prediction_token;
    logic istream_prediction_accept;
    wire [15:0] stream_generation;
    wire [2:0] ftq_count;
    wire predicted_transfer_valid;
    wire predicted_reject_valid;
    wire [63:0] predicted_transfer_source_pc;
    wire [63:0] predicted_transfer_target_pc;
    wire [31:0] predicted_transfer_token;

    integer request_count;
    reg [63:0] request_addr_log [0:31];
    reg request_stash_log [0:31];

    openrv64_fetch_istream #(
        .BLOCK_DEPTH(8),
        .PENDING_DEPTH(4),
        .FTQ_DEPTH(4),
        .LOOKAHEAD_BLOCKS(2),
        .PREDICT_LOOKAHEAD_SECTORS(4)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .restart_i(restart), .restart_pc_i(restart_pc),
        .redirect_i(redirect), .redirect_pc_i(redirect_pc),
        .invalidate_i(invalidate), .flush_i(flush), .stall_i(stall),
        .cancel_o(cancel),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_addr_o(req_addr), .req_stash_o(req_stash),
        .req_demand_o(req_demand),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_addr_i(resp_addr), .resp_data_i(resp_data),
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .btb_lookup_valid_o(btb_lookup_valid),
        .btb_lookup_ready_i(btb_lookup_ready),
        .btb_lookup_pc_o(btb_lookup_pc),
        .btb_lookup_request_id_o(btb_lookup_request_id),
        .btb_response_valid_i(btb_response_valid),
        .btb_response_request_id_i(btb_response_request_id),
        .btb_response_hit_i(btb_response_hit),
        .btb_response_control_pc_i(btb_response_control_pc),
        .btb_response_control_end_pc_i(btb_response_control_end_pc),
        .btb_response_successor_pc_i(btb_response_successor_pc),
        .btb_response_taken_i(btb_response_taken),
        .btb_response_prediction_token_i(
            btb_response_prediction_token),
        .btb_response_ready_o(),
        .istream_valid_o(istream_valid),
        .istream_data_o(istream_data),
        .istream_halfword_valid_o(istream_halfword_valid),
        .istream_access_fault_o(istream_access_fault),
        .istream_page_fault_o(istream_page_fault),
        .istream_advance_half_i(istream_advance_half),
        .istream_consume_halfwords_i(istream_consume_halfwords),
        .stream_pc_o(stream_pc),
        .istream_prediction_valid_o(istream_prediction_valid),
        .istream_control_pc_o(istream_control_pc),
        .istream_control_end_pc_o(istream_control_end_pc),
        .istream_prediction_successor_o(istream_prediction_successor),
        .istream_prediction_taken_o(istream_prediction_taken),
        .istream_prediction_token_o(istream_prediction_token),
        .istream_prediction_accept_i(istream_prediction_accept),
        .stream_generation_o(stream_generation),
        .ftq_count_o(ftq_count),
        .predicted_transfer_valid_o(predicted_transfer_valid),
        .predicted_reject_valid_o(predicted_reject_valid),
        .predicted_transfer_source_pc_o(
            predicted_transfer_source_pc),
        .predicted_transfer_target_pc_o(
            predicted_transfer_target_pc),
        .predicted_transfer_token_o(predicted_transfer_token)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n && req_valid && req_ready) begin
            request_addr_log[request_count] <= req_addr;
            request_stash_log[request_count] <= req_stash;
            request_count <= request_count + 1;
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    function automatic [255:0] compressed_fill;
        integer halfword;
        begin
            compressed_fill = 256'd0;
            for (halfword = 0; halfword < 16; halfword = halfword + 1)
                compressed_fill[halfword*16 +: 16] = 16'h0001;
        end
    endfunction

    function automatic [255:0] source_block;
        reg [255:0] data;
        begin
            data = compressed_fill();
            data[2*8 +: 32] = 32'h00000013;
            data[10*8 +: 32] = 32'h00000063;
            // Lower half of a 32-bit instruction at the block boundary.
            data[30*8 +: 16] = 16'h0013;
            source_block = data;
        end
    endfunction

    function automatic [255:0] following_block;
        reg [255:0] data;
        begin
            data = compressed_fill();
            // Upper half of the instruction beginning at 0x1e.
            data[0 +: 16] = 16'h0000;
            following_block = data;
        end
    endfunction

    function automatic [255:0] target_block;
        reg [255:0] data;
        begin
            data = compressed_fill();
            data[4*8 +: 32] = 32'h00000013;
            target_block = data;
        end
    endfunction

    task automatic wait_request(input [63:0] addr, input expected_stash);
        integer timeout;
        integer index;
        reg found;
        begin
            found = 1'b0;
            timeout = 0;
            while (!found && (timeout < 80)) begin
                for (index = 0; index < request_count; index = index + 1) begin
                    if ((request_addr_log[index] == addr) &&
                        (request_stash_log[index] == expected_stash))
                        found = 1'b1;
                end
                if (!found) tick();
                timeout = timeout + 1;
            end
            if (!found)
                $fatal(1, "missing request addr=%h stash=%b",
                       addr, expected_stash);
        end
    endtask

    task automatic return_block(
        input [63:0] addr,
        input [255:0] data
    );
        begin
            resp_addr = addr;
            resp_data = data;
            resp_access_fault = 1'b0;
            resp_page_fault = 1'b0;
            resp_valid = 1'b1;
            tick();
            resp_valid = 1'b0;
        end
    endtask

    task automatic return_access_fault(input [63:0] addr);
        begin
            resp_addr = addr;
            resp_data = 256'd0;
            resp_access_fault = 1'b1;
            resp_page_fault = 1'b0;
            resp_valid = 1'b1;
            tick();
            resp_valid = 1'b0;
            resp_access_fault = 1'b0;
        end
    endtask

    task automatic wait_stream_pc(input [63:0] pc);
        integer timeout;
        begin
            timeout = 0;
            while ((!istream_valid || (stream_pc != pc)) &&
                   (timeout < 80)) begin
                tick();
                timeout = timeout + 1;
            end
            if (!istream_valid || (stream_pc != pc))
                $fatal(1, "stream did not reach pc=%h, current=%h valid=%b",
                       pc, stream_pc, istream_valid);
        end
    endtask

    initial begin
        reg [15:0] partial_halfword;
        integer stale_lookup_timeout;
        reg [31:0] chained_lookup_request_id;

        clk = 1'b0;
        rst_n = 1'b0;
        restart = 1'b0;
        restart_pc = 64'd0;
        redirect = 1'b0;
        redirect_pc = 64'd0;
        invalidate = 1'b0;
        flush = 1'b0;
        stall = 1'b0;
        req_ready = 1'b1;
        resp_valid = 1'b0;
        resp_addr = 64'd0;
        resp_data = 256'd0;
        resp_access_fault = 1'b0;
        resp_page_fault = 1'b0;
        // Hold the predictor request until the test has observed the initial
        // instruction-block request; both interfaces otherwise fire together.
        btb_lookup_ready = 1'b0;
        btb_response_valid = 1'b0;
        btb_response_request_id = 32'd0;
        btb_response_hit = 1'b0;
        btb_response_control_pc = 64'd0;
        btb_response_control_end_pc = 64'd0;
        btb_response_successor_pc = 64'd0;
        btb_response_taken = 1'b0;
        btb_response_prediction_token = 32'd0;
        istream_advance_half = 1'b0;
        istream_consume_halfwords = 4'd0;
        istream_prediction_accept = 1'b1;
        request_count = 0;
        partial_halfword = 16'd0;

        repeat (3) tick();
        rst_n = 1'b1;
        restart = 1'b1;
        restart_pc = 64'h0;
        invalidate = 1'b1;
        tick();
        restart = 1'b0;
        invalidate = 1'b0;

        wait_request(64'h0, 1'b0);
        while (!btb_lookup_valid || (btb_lookup_pc != 64'h0)) tick();
        btb_response_request_id = btb_lookup_request_id;
        btb_lookup_ready = 1'b1;
        tick();
        btb_response_valid = 1'b1;
        btb_response_hit = 1'b0;
        #1;
        if (!btb_lookup_valid || (btb_lookup_pc != 64'h10) ||
            (btb_lookup_request_id == btb_response_request_id))
            $fatal(1,
                "BTB miss did not pipeline the next-sector lookup");
        tick();
        btb_response_valid = 1'b0;

        // A hit closing the sole FTQ entry may launch its successor directly.
        btb_lookup_ready = 1'b0;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        wait_request(64'h0, 1'b0);
        while (!btb_lookup_valid || (btb_lookup_pc != 64'h0)) tick();
        btb_response_request_id = btb_lookup_request_id;
        btb_lookup_ready = 1'b1;
        tick();
        btb_response_valid = 1'b1;
        btb_response_hit = 1'b1;
        btb_response_control_pc = 64'h0a;
        btb_response_control_end_pc = 64'h0e;
        btb_response_successor_pc = 64'h100;
        btb_response_taken = 1'b1;
        btb_response_prediction_token = 32'h55;
        #1;
        if (!btb_lookup_valid || (btb_lookup_pc != 64'h100) ||
            (btb_lookup_request_id == btb_response_request_id))
            $fatal(1,
                "sole-entry BTB hit did not pipeline the successor lookup");
        tick();
        btb_response_valid = 1'b0;

        if (ftq_count != 2)
            $fatal(1, "BTB hit did not append a successor segment");
        return_block(64'h0, source_block());
        if (!istream_valid || (stream_pc != 64'h0))
            $fatal(1, "returning instruction block missed presentation bypass");
        wait_request(64'h100, 1'b1);
        return_block(64'h100, target_block());

        wait_stream_pc(64'h0);
        if (istream_halfword_valid != 6'h3f ||
            istream_data[15:0] != 16'h0001 ||
            istream_data[47:16] != 32'h00000013 ||
            istream_data[63:48] != 16'h0001)
            $fatal(1, "mixed raw halfword window mismatch");
        if (!istream_prediction_valid ||
            istream_control_pc != 64'h0a ||
            istream_control_end_pc != 64'h0e ||
            istream_prediction_successor != 64'h100 ||
            !istream_prediction_taken ||
            istream_prediction_token != 32'h55)
            $fatal(1, "active prediction metadata mismatch");

        // Model decode accepting C + 32-bit + C: four halfwords total.
        istream_consume_halfwords = 4'd4;
        tick();
        istream_consume_halfwords = 4'd0;
        if (stream_pc != 64'h8 || istream_halfword_valid != 6'h07 ||
            istream_data[15:0] != 16'h0001 ||
            istream_data[47:16] != 32'h00000063)
            $fatal(1, "exclusive control boundary did not clip suffix");

        istream_consume_halfwords = 4'd3;
        #1;
        if (!predicted_transfer_valid ||
            predicted_transfer_source_pc != 64'h0a ||
            predicted_transfer_target_pc != 64'h100 ||
            predicted_transfer_token != 32'h55)
            $fatal(1, "predicted transfer sideband mismatch");
        tick();
        istream_consume_halfwords = 4'd0;
        wait_stream_pc(64'h100);
        if (istream_data[15:0] != 16'h0001 ||
            istream_data[31:16] != 16'h0001 ||
            istream_data[63:32] != 32'h00000013)
            $fatal(1, "ready predicted target presentation mismatch");

        // A speculative redirect is not a context restart.  A resident target
        // must be presented immediately and the memory interface must not be
        // cancelled, otherwise every trained predictor correction creates a
        // refill bubble.
        redirect_pc = 64'h104;
        redirect = 1'b1;
        #1;
        if (cancel)
            $fatal(1, "speculative redirect asserted fetch cancellation");
        tick();
        redirect = 1'b0;
        if (!istream_valid || (stream_pc != 64'h104) ||
            (istream_data[31:0] != 32'h00000013))
            $fatal(1, "resident speculative redirect was not presented immediately");

        // A target in the final halfword of a resident sector must compose
        // with the following resident sector on the redirect edge.  Otherwise
        // every such trained transfer loses a decode-width cycle despite
        // having all of the instruction bytes locally.
        redirect_pc = 64'h10e;
        redirect = 1'b1;
        tick();
        redirect = 1'b0;
        if (!istream_valid || (stream_pc != 64'h10e) ||
            (istream_halfword_valid != 6'h3f) ||
            (istream_data != {6{16'h0001}}))
            $fatal(1,
                "resident cross-sector redirect did not present a full window");

        // Restart on a 32-bit instruction's final block halfword, but delay
        // the following block.  Decode consumes/stashes the lower halfword;
        // fetch then presents the upper halfword at the next stream PC.
        restart_pc = 64'h1e;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        wait_stream_pc(64'h1e);
        if (istream_halfword_valid != 6'h01 ||
            istream_data[15:0] != 16'h0013)
            $fatal(1, "partial 32-bit instruction was not exposed raw");
        partial_halfword = istream_data[15:0];
        istream_consume_halfwords = 4'd1;
        tick();
        istream_consume_halfwords = 4'd0;
        if (stream_pc != 64'h20 || istream_valid)
            $fatal(1, "partial halfword was not consumed into decode stash");

        wait_request(64'h20, 1'b0);
        return_block(64'h20, following_block());
        wait_stream_pc(64'h20);
        if ({istream_data[15:0], partial_halfword} != 32'h00000013)
            $fatal(1, "decode-side halfword stash cannot reassemble straddle");

        // Three compressed instructions consume half of the normal six-parcel
        // decode window while retaining the same three-instruction throughput.
        restart_pc = 64'h22;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        wait_stream_pc(64'h22);
        if (istream_halfword_valid != 6'h3f)
            $fatal(1, "all-C window is not full decode width");
        istream_advance_half = 1'b1;
        tick();
        istream_advance_half = 1'b0;
        if (stream_pc != 64'h28)
            $fatal(1, "advance_half did not consume three C instructions");

        // A stale BTB entry must not invent a control transfer.  Decode
        // rejects the claimed boundary, and fetch resumes sequentially from
        // its exclusive end after discarding the predicted suffix.
        restart_pc = 64'h0;
        btb_lookup_ready = 1'b0;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        stale_lookup_timeout = 0;
        while ((!btb_lookup_valid || (btb_lookup_pc != 64'h0)) &&
               (stale_lookup_timeout < 20)) begin
            tick();
            stale_lookup_timeout = stale_lookup_timeout + 1;
        end
        if (!btb_lookup_valid || (btb_lookup_pc != 64'h0))
            $fatal(1, "stale prediction lookup did not relaunch");
        btb_response_request_id = btb_lookup_request_id;
        btb_lookup_ready = 1'b1;
        tick();
        btb_response_valid = 1'b1;
        btb_response_hit = 1'b1;
        btb_response_control_pc = 64'h2;
        btb_response_control_end_pc = 64'h6;
        btb_response_successor_pc = 64'h300;
        btb_response_taken = 1'b1;
        btb_response_prediction_token = 32'h66;
        tick();
        btb_response_valid = 1'b0;
        wait_stream_pc(64'h0);
        istream_prediction_accept = 1'b0;
        istream_consume_halfwords = 4'd3;
        #1;
        if (!predicted_reject_valid || predicted_transfer_valid)
            $fatal(1, "stale control boundary was not rejected");
        tick();
        istream_consume_halfwords = 4'd0;
        istream_prediction_accept = 1'b1;
        if (stream_pc != 64'h6 || ftq_count != 1)
            $fatal(1, "rejected prediction did not resume sequentially");

        // A synchronous response can arrive on the edge decode consumes the
        // named control.  That hit is too late to steer and must not install a
        // boundary behind the post-consumption presentation PC.
        restart_pc = 64'h0;
        btb_lookup_ready = 1'b0;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        wait_stream_pc(64'h0);
        while (!btb_lookup_valid || (btb_lookup_pc != 64'h0)) tick();
        btb_response_request_id = btb_lookup_request_id;
        btb_lookup_ready = 1'b1;
        tick();
        istream_consume_halfwords = 4'd4;
        tick();
        istream_consume_halfwords = 4'd3;
        btb_response_valid = 1'b1;
        btb_response_hit = 1'b1;
        btb_response_control_pc = 64'h0a;
        btb_response_control_end_pc = 64'h0e;
        btb_response_successor_pc = 64'h100;
        tick();
        istream_consume_halfwords = 4'd0;
        btb_response_valid = 1'b0;
        if ((stream_pc != 64'h0e) || istream_prediction_valid ||
            (ftq_count != 1))
            $fatal(1, "late BTB response installed a consumed boundary");

        // Do not combinationally recurse through a second predicted segment.
        // That response may append normally, but the next lookup must observe
        // the registered FTQ topology.
        restart_pc = 64'h0;
        btb_lookup_ready = 1'b0;
        restart = 1'b1;
        tick();
        restart = 1'b0;
        while (!btb_lookup_valid || (btb_lookup_pc != 64'h0)) tick();
        btb_response_request_id = btb_lookup_request_id;
        btb_lookup_ready = 1'b1;
        tick();
        btb_response_valid = 1'b1;
        btb_response_hit = 1'b1;
        btb_response_control_pc = 64'h0a;
        btb_response_control_end_pc = 64'h0e;
        btb_response_successor_pc = 64'h100;
        #1;
        if (!btb_lookup_valid || (btb_lookup_pc != 64'h100))
            $fatal(1, "sole-entry hit did not chain in depth test");
        chained_lookup_request_id = btb_lookup_request_id;
        tick();
        btb_response_request_id = chained_lookup_request_id;
        btb_response_control_pc = 64'h10a;
        btb_response_control_end_pc = 64'h10e;
        btb_response_successor_pc = 64'h200;
        #1;
        if (btb_lookup_valid)
            $fatal(1, "BTB recursively chained through speculative FTQ state");
        tick();
        btb_response_valid = 1'b0;
        if (ftq_count != 3)
            $fatal(1, "registered second hit did not append normally");

        // Fetch preserves raw data and supplies fault qualification; decode
        // decides how to represent the fault and must not depend on fake NOPs.
        restart_pc = 64'h200;
        restart = 1'b1;
        invalidate = 1'b1;
        tick();
        restart = 1'b0;
        invalidate = 1'b0;
        wait_request(64'h200, 1'b0);
        return_access_fault(64'h200);
        wait_stream_pc(64'h200);
        if (!istream_access_fault[0] || istream_page_fault[0] ||
            istream_data[15:0] != 16'h0000)
            $fatal(1, "raw instruction access fault qualification mismatch");

        $display("PASS: fetch_istream supplies qualified raw halfword windows and half advance");
        $finish;
    end
endmodule
