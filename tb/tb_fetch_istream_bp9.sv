`timescale 1ns/1ps

module tb_fetch_istream_bp9;
    logic clk;
    logic rst_n;
    logic cancel;
    logic enable;

    logic btb_valid;
    wire btb_ready;
    logic [31:0] btb_request_id;
    logic btb_hit;
    logic [63:0] btb_control_pc;
    logic [63:0] btb_control_end_pc;
    logic btb_conditional;
    logic [63:0] btb_target_pc;
    logic [63:0] btb_successor_pc;
    logic btb_taken;
    logic [31:0] btb_prediction_token;

    wire response_valid;
    logic response_ready;
    wire [31:0] response_request_id;
    wire response_hit;
    wire [63:0] response_control_pc;
    wire [63:0] response_control_end_pc;
    wire [63:0] response_successor_pc;
    wire response_taken;
    wire [31:0] response_prediction_token;

    wire tage_lookup_valid;
    logic tage_lookup_accept;
    wire [63:0] tage_lookup_pc;
    wire tage_lookup_backward;
    logic tage_response_valid;
    logic [63:0] tage_response_pc;
    logic tage_response_taken;

    wire diag_early_candidate;
    wire diag_early_lookup;
    wire diag_early_response;
    wire diag_early_taken;

    integer lookup_count;
    integer response_count;

    openrv64_fetch_istream_bp9 dut (
        .clk(clk), .rst_n(rst_n),
        .cancel_i(cancel),
        .enable_i(enable),
        .btb_valid_i(btb_valid),
        .btb_ready_o(btb_ready),
        .btb_request_id_i(btb_request_id),
        .btb_hit_i(btb_hit),
        .btb_control_pc_i(btb_control_pc),
        .btb_control_end_pc_i(btb_control_end_pc),
        .btb_conditional_i(btb_conditional),
        .btb_target_pc_i(btb_target_pc),
        .btb_successor_pc_i(btb_successor_pc),
        .btb_taken_i(btb_taken),
        .btb_prediction_token_i(btb_prediction_token),
        .response_valid_o(response_valid),
        .response_ready_i(response_ready),
        .response_request_id_o(response_request_id),
        .response_hit_o(response_hit),
        .response_control_pc_o(response_control_pc),
        .response_control_end_pc_o(response_control_end_pc),
        .response_successor_pc_o(response_successor_pc),
        .response_taken_o(response_taken),
        .response_prediction_token_o(response_prediction_token),
        .tage_lookup_valid_o(tage_lookup_valid),
        .tage_lookup_accept_i(tage_lookup_accept),
        .tage_lookup_pc_o(tage_lookup_pc),
        .tage_lookup_backward_o(tage_lookup_backward),
        .tage_response_valid_i(tage_response_valid),
        .tage_response_pc_i(tage_response_pc),
        .tage_response_taken_i(tage_response_taken),
        .diag_early_candidate_o(diag_early_candidate),
        .diag_early_lookup_o(diag_early_lookup),
        .diag_early_response_o(diag_early_response),
        .diag_early_taken_o(diag_early_taken)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n) begin
            if (diag_early_lookup)
                lookup_count <= lookup_count + 1;
            if (diag_early_response)
                response_count <= response_count + 1;
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic set_btb(
        input [31:0] request_id,
        input hit,
        input conditional,
        input [63:0] control_pc,
        input [63:0] control_end_pc,
        input [63:0] target_pc,
        input [63:0] btfnt_successor,
        input btfnt_taken
    );
        begin
            btb_valid = 1'b1;
            btb_request_id = request_id;
            btb_hit = hit;
            btb_conditional = conditional;
            btb_control_pc = control_pc;
            btb_control_end_pc = control_end_pc;
            btb_target_pc = target_pc;
            btb_successor_pc = btfnt_successor;
            btb_taken = btfnt_taken;
            btb_prediction_token = request_id;
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
        btb_control_pc = 0;
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
        lookup_count = 0;
        response_count = 0;

        repeat (3) tick();
        rst_n = 1'b1;

        // A BTB miss is passed through.  No TAGE read is useful without a
        // known conditional PC and target.
        set_btb(32'h10, 1'b0, 1'b0, 64'h100, 64'h100,
                64'd0, 64'd0, 1'b0);
        if (!response_valid || !btb_ready || tage_lookup_valid)
            $fatal(1, "BTB miss did not use immediate fallback path");
        tick();
        clear_btb();

        // A direct control also passes through without consuming TAGE.
        set_btb(32'h11, 1'b1, 1'b0, 64'h108, 64'h10c,
                64'h300, 64'h300, 1'b1);
        if (!response_valid || !btb_ready || tage_lookup_valid ||
            !response_hit || response_successor_pc != 64'h300 ||
            !response_taken)
            $fatal(1, "unconditional BTB hit did not pass through");
        tick();
        clear_btb();

        // Forward branch: the stored BTFNT successor is fallthrough, but the
        // early TAGE response selects taken.  Port denial must hold the BTB.
        set_btb(32'h12, 1'b1, 1'b1, 64'h200, 64'h204,
                64'h280, 64'h204, 1'b0);
        if (!tage_lookup_valid || tage_lookup_backward || response_valid ||
            btb_ready)
            $fatal(1, "conditional hit was not held for early TAGE");
        tick();
        if (!tage_lookup_valid || response_valid || btb_ready)
            $fatal(1, "denied TAGE request did not remain pending");
        tage_lookup_accept = 1'b1;
        #1;
        tick();
        tage_lookup_accept = 1'b0;
        if (tage_lookup_valid || response_valid || btb_ready)
            $fatal(1, "accepted TAGE lookup did not enter response wait");
        tage_response_pc = 64'h204;
        tage_response_taken = 1'b0;
        tage_response_valid = 1'b1;
        #1;
        if (response_valid)
            $fatal(1, "mismatched TAGE response released BTB entry");
        tick();
        tage_response_pc = 64'h200;
        tage_response_taken = 1'b1;
        response_ready = 1'b0;
        #1;
        if (!response_valid || btb_ready ||
            response_successor_pc != 64'h280 || !response_taken)
            $fatal(1, "TAGE taken decision did not override BTFNT");
        tick();
        tage_response_valid = 1'b0;
        #1;
        if (!response_valid || btb_ready ||
            response_successor_pc != 64'h280 || !response_taken)
            $fatal(1, "unaccepted TAGE result was not retained");
        response_ready = 1'b1;
        #1;
        if (!response_valid || !btb_ready)
            $fatal(1, "retained TAGE result did not release BTB entry");
        tick();
        clear_btb();

        // Backward branch: BTFNT says taken, but TAGE is allowed to select
        // fallthrough.  There must be only one accepted early lookup/result.
        set_btb(32'h13, 1'b1, 1'b1, 64'h400, 64'h404,
                64'h380, 64'h380, 1'b1);
        tage_lookup_accept = 1'b1;
        #1;
        if (!tage_lookup_valid || !tage_lookup_backward)
            $fatal(1, "backward conditional did not launch early TAGE");
        tick();
        tage_lookup_accept = 1'b0;
        tage_response_pc = 64'h400;
        tage_response_taken = 1'b0;
        tage_response_valid = 1'b1;
        #1;
        if (!response_valid || !btb_ready || response_taken ||
            response_successor_pc != 64'h404)
            $fatal(1, "TAGE not-taken decision did not override BTFNT");
        tick();
        tage_response_valid = 1'b0;
        clear_btb();

        // Cancellation drains the held BTB response without presenting it.
        set_btb(32'h14, 1'b1, 1'b1, 64'h500, 64'h504,
                64'h580, 64'h504, 1'b0);
        cancel = 1'b1;
        #1;
        if (response_valid || tage_lookup_valid || !btb_ready)
            $fatal(1, "cancel did not suppress and drain held response");
        tick();
        cancel = 1'b0;
        clear_btb();

        if (lookup_count != 2 || response_count != 2)
            $fatal(1, "early TAGE diagnostics mismatch l=%0d r=%0d",
                   lookup_count, response_count);

        $display("PASS: istream BP9 waits for one TAGE direction before FTQ admission");
        $finish;
    end
endmodule
