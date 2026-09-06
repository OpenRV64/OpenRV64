`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_istream_bp9;
    logic clk, rst_n, cancel, enable;
    logic btb_valid;
    wire btb_ready;
    logic [31:0] btb_request_id;
    logic [63:0] btb_stream_pc;
    logic btb_hit;
    logic [63:0] btb_control_pc, btb_control_end_pc;
    logic [2:0] btb_control_class;
    logic btb_conditional;
    logic [63:0] btb_target_pc, btb_successor_pc;
    logic btb_taken;
    logic [31:0] btb_prediction_token;
    wire response_valid;
    logic response_ready;
    wire [31:0] response_request_id;
    wire [63:0] response_stream_pc;
    wire response_hit;
    wire [63:0] response_control_pc, response_control_end_pc;
    wire [2:0] response_control_class;
    wire [63:0] response_successor_pc;
    wire response_taken;
    wire [31:0] response_prediction_token;
    wire tage_lookup_valid;
    logic tage_lookup_accept;
    wire [63:0] tage_lookup_pc;
    wire tage_lookup_backward;
    wire tage_lookup_taken;
    wire [31:0] tage_lookup_token;
    logic tage_response_valid;
    logic [63:0] tage_response_pc;
    logic tage_response_taken;
    wire refinement_valid;
    wire [31:0] refinement_prediction_token;
    wire [63:0] refinement_control_pc;
    wire refinement_taken;
    wire [63:0] refinement_successor_pc;
    wire diag_early_candidate, diag_early_lookup;
    wire diag_early_response, diag_early_taken, diag_early_busy_skip;
    wire [3:0] diag_early_queue_count;

    integer candidate_count, lookup_count, refinement_count, busy_skip_count;

    openrv64_fetch_istream_bp9 dut (
        .clk(clk), .rst_n(rst_n), .cancel_i(cancel), .enable_i(enable),
        .btb_valid_i(btb_valid), .btb_ready_o(btb_ready),
        .btb_request_id_i(btb_request_id),
        .btb_stream_pc_i(btb_stream_pc),
        .btb_hit_i(btb_hit), .btb_control_pc_i(btb_control_pc),
        .btb_control_end_pc_i(btb_control_end_pc),
        .btb_control_class_i(btb_control_class),
        .btb_conditional_i(btb_conditional),
        .btb_target_pc_i(btb_target_pc),
        .btb_successor_pc_i(btb_successor_pc),
        .btb_taken_i(btb_taken),
        .btb_prediction_token_i(btb_prediction_token),
        .response_valid_o(response_valid),
        .response_ready_i(response_ready),
        .response_request_id_o(response_request_id),
        .response_stream_pc_o(response_stream_pc),
        .response_hit_o(response_hit),
        .response_control_pc_o(response_control_pc),
        .response_control_end_pc_o(response_control_end_pc),
        .response_control_class_o(response_control_class),
        .response_successor_pc_o(response_successor_pc),
        .response_taken_o(response_taken),
        .response_prediction_token_o(response_prediction_token),
        .tage_lookup_valid_o(tage_lookup_valid),
        .tage_lookup_accept_i(tage_lookup_accept),
        .tage_lookup_pc_o(tage_lookup_pc),
        .tage_lookup_backward_o(tage_lookup_backward),
        .tage_lookup_taken_o(tage_lookup_taken),
        .tage_lookup_token_o(tage_lookup_token),
        .tage_response_valid_i(tage_response_valid),
        .tage_response_pc_i(tage_response_pc),
        .tage_response_taken_i(tage_response_taken),
        .refinement_valid_o(refinement_valid),
        .refinement_prediction_token_o(refinement_prediction_token),
        .refinement_control_pc_o(refinement_control_pc),
        .refinement_taken_o(refinement_taken),
        .refinement_successor_pc_o(refinement_successor_pc),
        .diag_early_candidate_o(diag_early_candidate),
        .diag_early_lookup_o(diag_early_lookup),
        .diag_early_response_o(diag_early_response),
        .diag_early_taken_o(diag_early_taken),
        .diag_early_busy_skip_o(diag_early_busy_skip),
        .diag_early_queue_count_o(diag_early_queue_count)
    );

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n) begin
            if (diag_early_candidate) candidate_count <= candidate_count + 1;
            if (diag_early_lookup) lookup_count <= lookup_count + 1;
            if (diag_early_response) refinement_count <= refinement_count + 1;
            if (diag_early_busy_skip) busy_skip_count <= busy_skip_count + 1;
        end
    end

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic set_btb(
        input [31:0] request_id,
        input hit,
        input conditional,
        input [63:0] stream_pc,
        input [63:0] control_pc,
        input [63:0] control_end_pc,
        input [63:0] target_pc,
        input [63:0] fast_successor,
        input fast_taken
    );
        begin
            btb_valid = 1'b1;
            btb_request_id = request_id;
            btb_stream_pc = stream_pc;
            btb_hit = hit;
            btb_conditional = conditional;
            btb_control_pc = control_pc;
            btb_control_end_pc = control_end_pc;
            btb_control_class = conditional ?
                `OPENRV64_STREAM_CONTROL_CONDITIONAL :
                `OPENRV64_STREAM_CONTROL_DIRECT_JUMP;
            btb_target_pc = target_pc;
            btb_successor_pc = fast_successor;
            btb_taken = fast_taken;
            btb_prediction_token = request_id + 32'h100;
            #1;
        end
    endtask

    task automatic clear_btb;
        begin
            btb_valid = 1'b0;
            btb_hit = 1'b0;
            btb_conditional = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cancel = 1'b0;
        enable = 1'b1;
        clear_btb();
        btb_request_id = 0;
        btb_stream_pc = 0;
        btb_control_pc = 0;
        btb_control_class = `OPENRV64_STREAM_CONTROL_CONDITIONAL;
        btb_control_end_pc = 0;
        btb_target_pc = 0;
        btb_successor_pc = 0;
        btb_taken = 1'b0;
        btb_prediction_token = 0;
        response_ready = 1'b1;
        tage_lookup_accept = 1'b0;
        tage_response_valid = 1'b0;
        tage_response_pc = 0;
        tage_response_taken = 1'b0;
        candidate_count = 0;
        lookup_count = 0;
        refinement_count = 0;
        busy_skip_count = 0;

        repeat (3) tick();
        rst_n = 1'b1;

        set_btb(32'h10, 1'b0, 1'b0, 64'h100, 64'h100, 64'h100,
                64'd0, 64'd0, 1'b0);
        if (!response_valid || !btb_ready || tage_lookup_valid ||
            response_stream_pc != 64'h100)
            $fatal(1, "RLE miss did not pass through immediately");
        tick();
        clear_btb();

        set_btb(32'h11, 1'b1, 1'b0, 64'h108, 64'h10c, 64'h110,
                64'h300, 64'h300, 1'b1);
        if (!response_valid || !btb_ready || tage_lookup_valid ||
            response_successor_pc != 64'h300 || !response_taken)
            $fatal(1, "unconditional RLE hit did not pass through");
        tick();
        clear_btb();

        // A denied BP9 port cannot hold the RLE response.  The candidate is
        // retained after its fast fallthrough is already admitted.
        set_btb(32'h12, 1'b1, 1'b1, 64'h200, 64'h220, 64'h224,
                64'h280, 64'h224, 1'b0);
        if (!response_valid || !btb_ready || tage_lookup_valid ||
            response_successor_pc != 64'h224 || response_taken)
            $fatal(1, "conditional RLE response was blocked by BP9");
        tick();
        clear_btb();
        if (!tage_lookup_valid || tage_lookup_pc != 64'h220)
            $fatal(1, "denied BP9 candidate was not retained");
        tage_lookup_accept = 1'b1;
        tick();
        tage_lookup_accept = 1'b0;
        if (tage_lookup_valid)
            $fatal(1, "accepted BP9 read did not enter response wait");

        // Bursty output queues while the optional refinement request is
        // inflight; it still cannot hold the RLE response.
        set_btb(32'h13, 1'b1, 1'b1, 64'h300, 64'h320, 64'h324,
                64'h380, 64'h324, 1'b0);
        if (!response_valid || !btb_ready || tage_lookup_valid ||
            diag_early_busy_skip)
            $fatal(1, "queued refinement blocked the RLE stream");
        tick();
        clear_btb();

        tage_response_valid = 1'b1;
        tage_response_pc = 64'h204;
        tage_response_taken = 1'b1;
        #1;
        if (refinement_valid)
            $fatal(1, "mismatched BP9 response refined an FTQ entry");
        tick();
        tage_response_pc = 64'h220;
        tage_lookup_accept = 1'b1;
        #1;
        if (!refinement_valid ||
            refinement_prediction_token != 32'h112 ||
            refinement_control_pc != 64'h220 ||
            refinement_successor_pc != 64'h280 || !refinement_taken ||
            !tage_lookup_valid || tage_lookup_pc != 64'h320)
            $fatal(1, "taken BP9 result did not produce tagged refinement");
        tick();
        tage_lookup_accept = 1'b0;

        tage_response_pc = 64'h320;
        tage_response_taken = 1'b0;
        #1;
        if (!refinement_valid ||
            refinement_prediction_token != 32'h113 ||
            refinement_control_pc != 64'h320 ||
            refinement_successor_pc != 64'h324 || refinement_taken)
            $fatal(1, "queued BP9 refinement mismatch");
        tick();
        tage_response_valid = 1'b0;

        tage_lookup_accept = 1'b1;
        set_btb(32'h14, 1'b1, 1'b1, 64'h400, 64'h420, 64'h424,
                64'h380, 64'h380, 1'b1);
        if (!response_valid || !response_taken || tage_lookup_valid)
            $fatal(1, "backward candidate did not pass into pipeline");
        tick();
        clear_btb();
        if (!tage_lookup_valid || !tage_lookup_backward ||
            !tage_lookup_taken)
            $fatal(1, "registered backward candidate did not launch");
        tick();
        tage_lookup_accept = 1'b0;
        tage_response_valid = 1'b1;
        tage_response_pc = 64'h420;
        tage_response_taken = 1'b0;
        #1;
        if (!refinement_valid || refinement_taken ||
            refinement_successor_pc != 64'h424)
            $fatal(1, "not-taken BP9 refinement mismatch");
        tick();
        tage_response_valid = 1'b0;

        set_btb(32'h15, 1'b1, 1'b1, 64'h500, 64'h520, 64'h524,
                64'h580, 64'h524, 1'b0);
        cancel = 1'b1;
        #1;
        if (response_valid || tage_lookup_valid || !btb_ready)
            $fatal(1, "cancel did not suppress and drain RLE response");
        tick();
        cancel = 1'b0;
        clear_btb();

        if (candidate_count != 3 || lookup_count != 3 ||
            refinement_count != 3 || busy_skip_count != 0)
            $fatal(1,
                "nonblocking BP9 diagnostics mismatch c=%0d l=%0d r=%0d b=%0d",
                candidate_count, lookup_count, refinement_count,
                busy_skip_count);

        $display("PASS: istream BP9 refines RLE directions without blocking FTQ admission");
        $finish;
    end
endmodule
