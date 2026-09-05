`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_fetch_stream_btb;
    logic clk;
    logic rst_n;
    logic lookup_valid;
    wire lookup_ready;
    logic [63:0] lookup_pc;
    logic [31:0] lookup_request_id;
    wire response_valid;
    logic response_ready;
    wire [31:0] response_request_id;
    wire response_hit;
    wire [63:0] response_control_pc;
    wire [63:0] response_control_end_pc;
    wire response_conditional;
    wire [63:0] response_target_pc;
    wire [63:0] response_successor_pc;
    wire response_taken;
    wire [31:0] response_prediction_token;
    logic train_valid;
    logic train_conditional;
    logic train_length_32;
    logic [31:0] train_instr;
    logic [63:0] train_pc;
    logic [63:0] train_next_pc;
    wire diag_lookup_fire;
    wire diag_response_fire;
    wire diag_response_hit;
    wire diag_response_way1;
    wire diag_train_fire;
    wire diag_train_update;
    wire diag_train_insert;
    wire diag_train_replacement;
    wire diag_train_same_sector_second;
    wire diag_train_same_sector_overflow;

    integer train_updates;
    integer train_inserts;
    integer train_replacements;
    integer same_sector_seconds;
    integer same_sector_overflows;

    openrv64_fetch_stream_btb #(.ENTRIES(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .lookup_valid_i(lookup_valid),
        .lookup_ready_o(lookup_ready),
        .lookup_pc_i(lookup_pc),
        .lookup_request_id_i(lookup_request_id),
        .response_valid_o(response_valid),
        .response_ready_i(response_ready),
        .response_request_id_o(response_request_id),
        .response_hit_o(response_hit),
        .response_control_pc_o(response_control_pc),
        .response_control_end_pc_o(response_control_end_pc),
        .response_conditional_o(response_conditional),
        .response_target_pc_o(response_target_pc),
        .response_successor_pc_o(response_successor_pc),
        .response_taken_o(response_taken),
        .response_prediction_token_o(response_prediction_token),
        .train_valid_i(train_valid),
        .train_conditional_i(train_conditional),
        .train_length_32_i(train_length_32),
        .train_instr_i(train_instr),
        .train_pc_i(train_pc),
        .train_next_pc_i(train_next_pc),
        .diag_lookup_fire_o(diag_lookup_fire),
        .diag_response_fire_o(diag_response_fire),
        .diag_response_hit_o(diag_response_hit),
        .diag_response_way1_o(diag_response_way1),
        .diag_train_fire_o(diag_train_fire),
        .diag_train_update_o(diag_train_update),
        .diag_train_insert_o(diag_train_insert),
        .diag_train_replacement_o(diag_train_replacement),
        .diag_train_same_sector_second_o(
            diag_train_same_sector_second),
        .diag_train_same_sector_overflow_o(
            diag_train_same_sector_overflow)
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
            if (diag_train_same_sector_second)
                same_sector_seconds <= same_sector_seconds + 1;
            if (diag_train_same_sector_overflow)
                same_sector_overflows <= same_sector_overflows + 1;
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic train_control(
        input [63:0] pc,
        input conditional,
        input [31:0] instr,
        input [63:0] next_pc
    );
        begin
            train_pc = pc;
            train_conditional = conditional;
            train_length_32 = 1'b1;
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
                $fatal(1, "stream BTB did not return synchronously");
            if (response_request_id != request_id ||
                response_prediction_token != request_id)
                $fatal(1, "stream BTB request identity mismatch");
        end
    endtask

    initial begin
        reg [31:0] backward_branch;
        reg [63:0] backward_target;

        clk = 1'b0;
        rst_n = 1'b0;
        lookup_valid = 1'b0;
        lookup_pc = 64'd0;
        lookup_request_id = 32'd0;
        response_ready = 1'b1;
        train_valid = 1'b0;
        train_conditional = 1'b0;
        train_length_32 = 1'b1;
        train_instr = 32'd0;
        train_pc = 64'd0;
        train_next_pc = 64'd0;
        train_updates = 0;
        train_inserts = 0;
        train_replacements = 0;
        same_sector_seconds = 0;
        same_sector_overflows = 0;
        backward_branch = 32'hfe000ce3;
        backward_target = 64'h108 + `RV64_IMM_B(backward_branch);

        repeat (3) tick();
        rst_n = 1'b1;

        query(64'h100, 32'h10);
        if (response_hit)
            $fatal(1, "cold stream BTB lookup unexpectedly hit");
        tick();

        // The supplied next PC is fallthrough; the encoded B-immediate must
        // provide the target used by BTFNT.
        train_control(64'h108, 1'b1, backward_branch, 64'h10c);
        query(64'h100, 32'h11);
        if (!response_hit || response_control_pc != 64'h108 ||
            response_control_end_pc != 64'h10c ||
            !response_conditional || response_target_pc != backward_target ||
            response_successor_pc != backward_target || !response_taken)
            $fatal(1, "backward conditional BTFNT response mismatch");
        tick();

        train_control(64'h10c, 1'b0, 32'h0000006f, 64'h200);
        query(64'h10a, 32'h12);
        if (!response_hit || response_control_pc != 64'h10c ||
            response_conditional || response_target_pc != 64'h200 ||
            response_successor_pc != 64'h200 || !response_taken)
            $fatal(1, "same-sector second control selection mismatch");
        tick();

        query(64'h10e, 32'h13);
        if (response_hit)
            $fatal(1, "lower-bound query returned a control behind it");
        tick();

        train_control(64'h10c, 1'b0, 32'h0000006f, 64'h300);
        query(64'h10c, 32'h14);
        if (!response_hit || response_successor_pc != 64'h300)
            $fatal(1, "stream BTB target update mismatch");
        tick();

        train_control(64'h104, 1'b0, 32'h0000006f, 64'h400);
        if (same_sector_seconds != 1 || same_sector_overflows != 1 ||
            train_updates != 1 || train_inserts != 2 ||
            train_replacements != 1)
            $fatal(1,
                "stream BTB diagnostics mismatch u=%0d i=%0d r=%0d s=%0d o=%0d",
                train_updates, train_inserts, train_replacements,
                same_sector_seconds, same_sector_overflows);

        $display("PASS: stream BTB provides synchronous bounded next-control steering");
        $finish;
    end
endmodule
