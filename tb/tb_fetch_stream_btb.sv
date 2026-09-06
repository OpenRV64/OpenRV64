`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_fetch_stream_btb;
    logic clk;
    logic rst_n;
    logic cancel;
    logic lookup_valid;
    wire lookup_ready;
    logic [63:0] lookup_pc;
    logic [31:0] lookup_request_id;
    wire response_valid;
    logic response_ready;
    wire [31:0] response_request_id;
    wire [63:0] response_stream_pc;
    wire response_hit;
    wire [63:0] response_control_pc;
    wire [63:0] response_control_end_pc;
    wire [2:0] response_control_class;
    wire response_conditional;
    wire [63:0] response_target_pc;
    wire [63:0] response_successor_pc;
    wire response_taken;
    wire [31:0] response_prediction_token;
    logic train_valid;
    logic [63:0] train_stream_pc;
    logic train_conditional;
    logic train_taken;
    logic train_length_32;
    logic train_fused_direct;
    logic [31:0] train_instr;
    logic [63:0] train_pc;
    logic [63:0] train_next_pc;
    wire diag_lookup_fire;
    wire diag_root_lookup;
    wire diag_chain_lookup;
    wire diag_response_fire;
    wire diag_response_hit;
    wire diag_response_way1;
    wire diag_queue_enqueue;
    wire diag_queue_dequeue;
    wire diag_queue_full_stall;
    wire [2:0] diag_queue_count;
    wire diag_train_fire;
    wire diag_train_update;
    wire diag_train_insert;
    wire diag_train_replacement;
    wire diag_train_shorter;
    wire diag_train_later_ignored;
    wire diag_train_run_overflow;
    wire diag_train_conditional;
    wire diag_train_taken;

    integer train_updates;
    integer train_inserts;
    integer train_replacements;
    integer train_shorter;
    integer train_later_ignored;
    integer train_overflows;
    integer conditional_trains;
    integer taken_trains;

    openrv64_fetch_stream_btb #(
        .ENTRIES(8),
        .RUN_HALFWORD_WIDTH(4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .cancel_i(cancel),
        .lookup_valid_i(lookup_valid),
        .lookup_ready_o(lookup_ready),
        .lookup_pc_i(lookup_pc),
        .lookup_request_id_i(lookup_request_id),
        .response_valid_o(response_valid),
        .response_ready_i(response_ready),
        .response_request_id_o(response_request_id),
        .response_stream_pc_o(response_stream_pc),
        .response_hit_o(response_hit),
        .response_control_pc_o(response_control_pc),
        .response_control_end_pc_o(response_control_end_pc),
        .response_control_class_o(response_control_class),
        .response_conditional_o(response_conditional),
        .response_target_pc_o(response_target_pc),
        .response_successor_pc_o(response_successor_pc),
        .response_taken_o(response_taken),
        .response_prediction_token_o(response_prediction_token),
        .train_valid_i(train_valid),
        .train_stream_pc_i(train_stream_pc),
        .train_conditional_i(train_conditional),
        .train_taken_i(train_taken),
        .train_length_32_i(train_length_32),
        .train_fused_direct_i(train_fused_direct),
        .train_instr_i(train_instr),
        .train_pc_i(train_pc),
        .train_next_pc_i(train_next_pc),
        .diag_lookup_fire_o(diag_lookup_fire),
        .diag_root_lookup_o(diag_root_lookup),
        .diag_chain_lookup_o(diag_chain_lookup),
        .diag_response_fire_o(diag_response_fire),
        .diag_response_hit_o(diag_response_hit),
        .diag_response_way1_o(diag_response_way1),
        .diag_queue_enqueue_o(diag_queue_enqueue),
        .diag_queue_dequeue_o(diag_queue_dequeue),
        .diag_queue_full_stall_o(diag_queue_full_stall),
        .diag_queue_count_o(diag_queue_count),
        .diag_train_fire_o(diag_train_fire),
        .diag_train_update_o(diag_train_update),
        .diag_train_insert_o(diag_train_insert),
        .diag_train_replacement_o(diag_train_replacement),
        .diag_train_shorter_o(diag_train_shorter),
        .diag_train_later_ignored_o(diag_train_later_ignored),
        .diag_train_run_overflow_o(diag_train_run_overflow),
        .diag_train_conditional_o(diag_train_conditional),
        .diag_train_taken_o(diag_train_taken)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n) begin
            if (diag_train_update)
                train_updates <= train_updates + 1;
            if (diag_train_insert)
                train_inserts <= train_inserts + 1;
            if (diag_train_replacement)
                train_replacements <= train_replacements + 1;
            if (diag_train_shorter)
                train_shorter <= train_shorter + 1;
            if (diag_train_later_ignored)
                train_later_ignored <= train_later_ignored + 1;
            if (diag_train_run_overflow)
                train_overflows <= train_overflows + 1;
            if (diag_train_conditional)
                conditional_trains <= conditional_trains + 1;
            if (diag_train_taken)
                taken_trains <= taken_trains + 1;
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic train_control(
        input [63:0] stream_pc,
        input [63:0] control_pc,
        input conditional,
        input taken,
        input fused_direct,
        input [31:0] instr,
        input [63:0] next_pc
    );
        begin
            train_stream_pc = stream_pc;
            train_pc = control_pc;
            train_conditional = conditional;
            train_taken = taken;
            train_length_32 = 1'b1;
            train_fused_direct = fused_direct;
            train_instr = instr;
            train_next_pc = next_pc;
            train_valid = 1'b1;
            tick();
            train_valid = 1'b0;
            tick();
        end
    endtask

    task automatic query(
        input [63:0] pc,
        input [31:0] request_id
    );
        begin
            while (!lookup_ready)
                tick();
            lookup_pc = pc;
            lookup_request_id = request_id;
            lookup_valid = 1'b1;
            tick();
            lookup_valid = 1'b0;
            if (!response_valid)
                $fatal(1, "stream RLE did not return synchronously");
            if (response_request_id != request_id ||
                response_prediction_token == 0)
                $fatal(1, "stream RLE request identity mismatch");
            if (response_stream_pc != pc)
                $fatal(1, "stream RLE response lost its stream key");
        end
    endtask

    task automatic cancel_chain;
        begin
            cancel = 1'b1;
            tick();
            cancel = 1'b0;
        end
    endtask

    initial begin
        reg [31:0] backward_branch;
        reg [63:0] backward_target;

        clk = 1'b0;
        rst_n = 1'b0;
        cancel = 1'b0;
        lookup_valid = 1'b0;
        lookup_pc = 64'd0;
        lookup_request_id = 32'd0;
        response_ready = 1'b1;
        train_valid = 1'b0;
        train_stream_pc = 64'd0;
        train_conditional = 1'b0;
        train_taken = 1'b0;
        train_length_32 = 1'b1;
        train_fused_direct = 1'b0;
        train_instr = 32'd0;
        train_pc = 64'd0;
        train_next_pc = 64'd0;
        train_updates = 0;
        train_inserts = 0;
        train_replacements = 0;
        train_shorter = 0;
        train_later_ignored = 0;
        train_overflows = 0;
        conditional_trains = 0;
        taken_trains = 0;
        backward_branch = 32'hfe000ce3;
        backward_target = 64'h108 + `RV64_IMM_B(backward_branch);

        repeat (3) tick();
        rst_n = 1'b1;

        query(64'h100, 32'h10);
        if (response_hit)
            $fatal(1, "cold stream RLE lookup unexpectedly hit");
        cancel_chain();

        // The stream starts at 0x100 and runs four halfwords to the branch.
        // The first actual outcome initializes the local fast direction.
        train_control(64'h100, 64'h108, 1'b1, 1'b1, 1'b0,
                      backward_branch, 64'h10c);
        query(64'h100, 32'h11);
        if (!response_hit || response_control_pc != 64'h108 ||
            response_control_end_pc != 64'h10c ||
            response_control_class != 3'd0 || !response_conditional ||
            response_target_pc != backward_target ||
            response_successor_pc != backward_target || !response_taken)
            $fatal(1, "conditional stream-run response mismatch");
        cancel_chain();

        // A later control observed for the same cold open stream cannot
        // replace its first control.
        train_control(64'h100, 64'h10c, 1'b0, 1'b1, 1'b0,
                      32'h0000006f, 64'h300);
        query(64'h100, 32'h15);
        if (!response_hit || response_control_pc != 64'h108)
            $fatal(1, "later control replaced the stream boundary");
        cancel_chain();

        // Resolution may arrive out of order.  A newly observed earlier
        // control must shorten the stored run.
        train_control(64'h120, 64'h12c, 1'b0, 1'b1, 1'b0,
                      32'h0000006f, 64'h300);
        train_control(64'h120, 64'h124, 1'b0, 1'b1, 1'b0,
                      32'h0000006f, 64'h280);
        query(64'h120, 32'h16);
        if (!response_hit || response_control_pc != 64'h124 ||
            response_successor_pc != 64'h280)
            $fatal(1, "earlier resolved control did not shorten stream");
        cancel_chain();

        // This is an exact stream-start lookup, not a lower-bound sector scan.
        query(64'h102, 32'h12);
        if (response_hit)
            $fatal(1, "non-start PC aliased a stream RLE entry");
        cancel_chain();

        // One contrary outcome moves weak-taken to weak-not-taken.
        train_control(64'h100, 64'h108, 1'b1, 1'b0, 1'b0,
                      backward_branch, 64'h10c);
        query(64'h100, 32'h13);
        if (!response_hit || response_taken ||
            response_successor_pc != 64'h10c)
            $fatal(1, "stream RLE fast direction did not update");
        cancel_chain();

        // These keys map to the same set in this deliberately tiny table and
        // exercise replacement after the two ways are occupied.
        train_control(64'h108, 64'h10c, 1'b0, 1'b1, 1'b0,
                      32'h000000ef, 64'h200);
        query(64'h108, 32'h14);
        if (!response_hit || response_control_pc != 64'h10c ||
            response_control_class != 3'd2 || response_conditional ||
            response_successor_pc != 64'h200 || !response_taken)
            $fatal(1, "direct-call stream-run response mismatch");
        cancel_chain();

        // AUIPC/JALR fusion makes the resolved JALR target static.  The raw
        // instruction remains JALR for architectural trace and RAS handling,
        // but the trained stream boundary may splice like a direct call.
        train_control(64'h108, 64'h10c, 1'b0, 1'b1, 1'b1,
                      32'h000300e7, 64'h200);
        query(64'h108, 32'h17);
        if (!response_hit || response_control_pc != 64'h10c ||
            response_control_class != 3'd2 || response_conditional ||
            response_successor_pc != 64'h200 || !response_taken)
            $fatal(1, "fused JALR did not train as a direct call");
        cancel_chain();

        train_control(64'h110, 64'h114, 1'b0, 1'b1, 1'b0,
                      32'h0000006f, 64'h300);

        // Four-bit halfword length cannot encode this 32-halfword run.
        train_control(64'h200, 64'h240, 1'b0, 1'b1, 1'b0,
                      32'h0000006f, 64'h300);

        if (train_updates != 2 || train_inserts != 2 ||
            train_replacements != 2 || train_shorter != 1 ||
            train_later_ignored != 1 || train_overflows != 1 ||
            conditional_trains != 2 || taken_trains != 7)
            $fatal(1,
                "stream RLE diagnostics mismatch u=%0d i=%0d r=%0d s=%0d l=%0d o=%0d c=%0d t=%0d",
                train_updates, train_inserts, train_replacements,
                train_shorter, train_later_ignored, train_overflows,
                conditional_trains, taken_trains);

        $display("PASS: stream RLE predicts one run per control from its stream start");
        $finish;
    end
endmodule
