`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"

module tb_exec_bp_tage;
    localparam integer BASE_ENTRIES = 8;
    localparam integer TABLE_ENTRIES = 8;
    localparam integer HISTORY_BITS = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic flush;
    logic squash;
    logic lookup_valid;
    logic lookup_branch;
    logic lookup_jump;
    logic lookup_indirect;
    logic lookup_backward;
    logic [31:0] lookup_instr;
    logic [63:0] lookup_pc;
    logic [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_id;
    logic lookup_allocate;
    logic resolve_valid;
    logic resolve_branch;
    logic resolve_taken;
    logic [31:0] resolve_instr;
    logic [63:0] resolve_pc;
    logic [63:0] resolve_target;
    logic [`OPENRV64_INSTR_ID_WIDTH-1:0] resolve_id;
    wire prediction_taken;
    wire prediction_weak;
    wire prediction_target_valid;
    wire [63:0] prediction_target;
    wire target_mispredict;
    wire update_overflow;
    wire fetch_stall;
    wire decode_stall;

    always #5 clk = ~clk;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_TAGE_BTB),
        .ENABLE_RAS(1),
        .RAS_DEPTH(4),
        .TAGE_BASE_ENTRIES(BASE_ENTRIES),
        .TAGE_TABLE_ENTRIES(TABLE_ENTRIES),
        .TAGE_HISTORY_BITS(HISTORY_BITS),
        .TAGE_HISTORY0_BITS(2),
        .TAGE_HISTORY1_BITS(4),
        .TAGE_HISTORY2_BITS(8),
        .TAGE_HISTORY3_BITS(16),
        .TAGE_TAG0_BITS(4),
        .TAGE_TAG1_BITS(5),
        .TAGE_TAG2_BITS(6),
        .TAGE_TAG3_BITS(7),
        .TAGE_AGE_INTERVAL(8),
        .BTB_ENTRIES(8),
        .BTB_TAG_BITS(8),
        .INFLIGHT_DEPTH(4),
        .ENABLE_TAGGED_RESOLUTION(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_i(squash),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(1'b0),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr), .lookup_pc_i(lookup_pc),
        .lookup_id_i(lookup_id), .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr), .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target), .resolve_id_i(resolve_id),
        .train_valid_i(3'b000), .train_branch_i(3'b000),
        .train_taken_i(3'b000), .train_pc_i(192'd0),
        .prediction_taken_o(prediction_taken),
        .prediction_weak_o(prediction_weak),
        .prediction_target_valid_o(prediction_target_valid),
        .prediction_target_o(prediction_target),
        .target_mispredict_o(target_mispredict),
        .update_overflow_o(update_overflow),
        .fetch_stall_o(fetch_stall), .decode_stall_o(decode_stall)
    );

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic clear_inputs;
        begin
            flush = 1'b0;
            squash = 1'b0;
            lookup_valid = 1'b0;
            lookup_branch = 1'b0;
            lookup_jump = 1'b0;
            lookup_indirect = 1'b0;
            lookup_backward = 1'b0;
            lookup_instr = 32'h0000_0063;
            lookup_pc = 64'd0;
            lookup_id = '0;
            lookup_allocate = 1'b0;
            resolve_valid = 1'b0;
            resolve_branch = 1'b0;
            resolve_taken = 1'b0;
            resolve_instr = 32'h0000_0063;
            resolve_pc = 64'd0;
            resolve_target = 64'd0;
            resolve_id = '0;
        end
    endtask

    task automatic reset_dut;
        begin
            clear_inputs();
            rst_n = 1'b0;
            tick();
            tick();
            rst_n = 1'b1;
            tick();
        end
    endtask

    task automatic present_branch(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic backward,
        input logic allocate
    );
        begin
            lookup_valid = 1'b1;
            lookup_branch = 1'b1;
            lookup_backward = backward;
            lookup_instr = 32'h0000_0063;
            lookup_pc = pc;
            lookup_id = id;
            lookup_allocate = allocate;
            #1;
        end
    endtask

    task automatic resolve_conditional(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic taken,
        input logic do_squash
    );
        begin
            resolve_valid = 1'b1;
            resolve_branch = 1'b1;
            resolve_taken = taken;
            resolve_instr = 32'h0000_0063;
            resolve_pc = pc;
            resolve_id = id;
            squash = do_squash;
            tick();
            resolve_valid = 1'b0;
            resolve_branch = 1'b0;
            resolve_taken = 1'b0;
            squash = 1'b0;
            #1;
        end
    endtask

    task automatic present_indirect(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic allocate
    );
        begin
            lookup_valid = 1'b1;
            lookup_jump = 1'b1;
            lookup_indirect = 1'b1;
            lookup_instr = 32'h0000_00e7;
            lookup_pc = pc;
            lookup_id = id;
            lookup_allocate = allocate;
            #1;
        end
    endtask

    task automatic resolve_indirect(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic [63:0] target
    );
        begin
            resolve_valid = 1'b1;
            resolve_taken = 1'b1;
            resolve_instr = 32'h0000_00e7;
            resolve_pc = pc;
            resolve_target = target;
            resolve_id = id;
            tick();
            clear_inputs();
        end
    endtask

    task automatic present_control(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic [31:0] instr,
        input logic indirect,
        input logic allocate
    );
        begin
            lookup_valid = 1'b1;
            lookup_jump = 1'b1;
            lookup_indirect = indirect;
            lookup_instr = instr;
            lookup_pc = pc;
            lookup_id = id;
            lookup_allocate = allocate;
            #1;
        end
    endtask

    task automatic resolve_control(
        input logic [63:0] pc,
        input logic [`OPENRV64_INSTR_ID_WIDTH-1:0] id,
        input logic [31:0] instr,
        input logic [63:0] target,
        input logic do_squash
    );
        begin
            resolve_valid = 1'b1;
            resolve_taken = 1'b1;
            resolve_instr = instr;
            resolve_pc = pc;
            resolve_target = target;
            resolve_id = id;
            squash = do_squash;
            tick();
            clear_inputs();
        end
    endtask

    integer i0;
    integer i1;
    integer i3;
    integer base_index_young;
    integer table0_index_young;
    logic [6:0] tag3;
    logic [4:0] tag1;

    initial begin
        reset_dut();

        // A conditional lookup first stalls for the synchronous table read.
        // Once the response is registered, cold state uses BTFNT through the
        // base predictor.
        present_branch(64'h100, 64'd1, 1'b1, 1'b0);
        if (!decode_stall)
            $fatal(1, "BP9 conditional lookup did not wait for BRAM");
        tick();
        if (!prediction_taken || !prediction_weak ||
            decode_stall || (dut.diag_tage_provider != 3'd0))
            $fatal(1, "cold backward BRAM response is not weak taken");

        // The eventual backend ID may change while the PC-indexed RAM response
        // is retained behind frontend compaction.  Allocation must accept the
        // existing response and record the final ID rather than reread or
        // retain the provisional ID.
        lookup_id = 64'd2;
        lookup_allocate = 1'b1;
        #1;
        if (decode_stall)
            $fatal(1, "BP9 rejected a retained response after ID projection changed");

        // A base miss allocates the shortest tagged table.  Tagged resolution
        // marks the record first; ordered training occurs on the next edge.
        i0 = dut.g_tage.u_tage.lookup_table0_index_q;
        tick();
        clear_inputs();
        resolve_conditional(64'h100, 64'd2, 1'b0, 1'b1);
        if (!dut.diag_tage_train ||
            !dut.diag_tage_train_mispredict ||
            (dut.diag_tage_allocation != 3'd1))
            $fatal(1, "base miss did not schedule ordered T0 allocation");
        tick();
        if (!dut.g_tage.u_tage.table0_valid_q[i0] ||
            dut.g_tage.u_tage.u_table0.mem_q[i0][2])
            $fatal(1, "T0 allocation did not install weak not-taken");

        present_branch(64'h100, 64'd2, 1'b1, 1'b0);
        tick();
        if ((dut.diag_tage_provider != 3'd1) || prediction_taken)
            $fatal(1, "new T0 entry is not the direction provider");
        clear_inputs();

        // Construct three matching tables.  The longest match must provide;
        // the next-longest match must be the alternate.
        present_branch(64'h200, 64'd10, 1'b0, 1'b0);
        i0 = dut.g_tage.u_tage.launch_table0_index;
        i1 = dut.g_tage.u_tage.launch_table1_index;
        i3 = dut.g_tage.u_tage.launch_table3_index;
        tag1 = dut.g_tage.u_tage.launch_table1_tag;
        tag3 = dut.g_tage.u_tage.launch_table3_tag;
        dut.g_tage.u_tage.table0_valid_q[i0] = 1'b1;
        dut.g_tage.u_tage.u_table0.mem_q[i0] = {
            dut.g_tage.u_tage.launch_table0_tag, 3'b111};
        dut.g_tage.u_tage.table0_useful_q[i0] = 2'b01;
        dut.g_tage.u_tage.table1_valid_q[i1] = 1'b1;
        dut.g_tage.u_tage.u_table1.mem_q[i1] = {tag1, 3'b000};
        dut.g_tage.u_tage.table1_useful_q[i1] = 2'b01;
        dut.g_tage.u_tage.table3_valid_q[i3] = 1'b1;
        dut.g_tage.u_tage.u_table3.mem_q[i3] = {tag3, 3'b111};
        dut.g_tage.u_tage.table3_useful_q[i3] = 2'b01;
        tick();
        if ((dut.diag_tage_provider != 3'd4) ||
            (dut.diag_tage_alternate != 3'd2) || !prediction_taken)
            $fatal(1, "TAGE longest provider/alternate selection failed");

        // A useful weak provider may be overridden by the alternate only when
        // the use-alt meta-counter has crossed its threshold.
        dut.g_tage.u_tage.u_table3.mem_q[i3] = {tag3, 3'b011};
        dut.g_tage.u_tage.table3_useful_q[i3] = 2'b00;
        dut.g_tage.u_tage.u_table1.mem_q[i1] = {tag1, 3'b111};
        dut.g_tage.u_tage.use_alt_q = 4'b1000;
        tick();
        if (!prediction_taken || !dut.diag_tage_use_alt)
            $fatal(1, "weak new provider did not select trained alternate");

        // A correct provider that disagrees with its alternate earns useful
        // state.  Disable use-alt so the provider supplies the prediction.
        dut.g_tage.u_tage.u_table3.mem_q[i3] = {tag3, 3'b111};
        dut.g_tage.u_tage.table3_useful_q[i3] = 2'b01;
        dut.g_tage.u_tage.u_table1.mem_q[i1] = {tag1, 3'b000};
        dut.g_tage.u_tage.use_alt_q = 4'b0000;
        tick();
        lookup_allocate = 1'b1;
        tick();
        clear_inputs();
        resolve_conditional(64'h200, 64'd10, 1'b1, 1'b0);
        if (!dut.diag_tage_train || dut.diag_tage_train_mispredict)
            $fatal(1, "correct T3 prediction was not queued for training");
        tick();
        if (dut.g_tage.u_tage.table3_useful_q[i3] != 2'b10)
            $fatal(1, "correct disagreeing T3 provider did not gain usefulness");

        // Aging is incremental and halves one useful counter per idle cycle.
        dut.g_tage.u_tage.table0_valid_q[i0] = 1'b1;
        dut.g_tage.u_tage.table0_useful_q[i0] = 2'b11;
        dut.g_tage.u_tage.age_active_q = 1'b1;
        dut.g_tage.u_tage.age_table_q = 2'd0;
        dut.g_tage.u_tage.age_index_q = i0;
        tick();
        if (dut.g_tage.u_tage.table0_useful_q[i0] != 2'b01)
            $fatal(1, "incremental useful-bit aging failed");

        // A younger out-of-order resolution must not update predictor state.
        // An older redirect then discards that younger record permanently.
        reset_dut();
        present_branch(64'h300, 64'd20, 1'b0, 1'b1);
        lookup_allocate = 1'b0;
        tick();
        lookup_allocate = 1'b1;
        tick();
        clear_inputs();
        present_branch(64'h304, 64'd21, 1'b0, 1'b1);
        lookup_allocate = 1'b0;
        base_index_young = dut.g_tage.u_tage.launch_base_index;
        table0_index_young = dut.g_tage.u_tage.launch_table0_index;
        tick();
        lookup_allocate = 1'b1;
        tick();
        clear_inputs();
        resolve_conditional(64'h304, 64'd21, 1'b1, 1'b1);
        if (dut.diag_tage_train ||
            dut.g_tage.u_tage.base_valid_q[base_index_young] ||
            dut.g_tage.u_tage.table0_valid_q[table0_index_young])
            $fatal(1, "younger resolved branch trained before ordered commit");
        resolve_conditional(64'h300, 64'd20, 1'b1, 1'b1);
        if (!dut.diag_tage_train ||
            (dut.g_tage.u_tage.inflight_count_q != 1))
            $fatal(1, "older redirect was not retained for ordered training");
        tick();
        if (dut.g_tage.u_tage.inflight_count_q != 0)
            $fatal(1, "ordered training queue did not drain");
        if (dut.g_tage.u_tage.base_valid_q[base_index_young] ||
            dut.g_tage.u_tage.table0_valid_q[table0_index_young])
            $fatal(1, "squashed younger branch polluted TAGE tables");

        // The large tag+target BTB is synchronous as well.  A cold miss may
        // allocate after the read response, then interlocks fetch until the
        // JALR resolves.  A trained hit supplies its target after one cycle.
        present_indirect(64'h400, 64'd30, 1'b0);
        if (!decode_stall)
            $fatal(1, "BP9 indirect lookup did not wait for BTB BRAM");
        tick();
        if (decode_stall || prediction_target_valid || !fetch_stall)
            $fatal(1, "cold synchronous BTB response is not a miss");
        lookup_allocate = 1'b1;
        tick();
        clear_inputs();
        resolve_indirect(64'h400, 64'd30, 64'h1234_5678_9abc_def0);
        tick();

        present_indirect(64'h400, 64'd31, 1'b0);
        if (!decode_stall)
            $fatal(1, "trained BTB lookup skipped synchronous read");
        tick();
        if (decode_stall || fetch_stall || !prediction_target_valid ||
            (prediction_target != 64'h1234_5678_9abc_def0))
            $fatal(1, "trained synchronous BTB target lookup failed");
        lookup_id = 64'd32;
        lookup_allocate = 1'b1;
        #1;
        if (decode_stall)
            $fatal(1, "BP9 BTB rejected a retained response after ID changed");
        tick();
        clear_inputs();
        resolve_indirect(64'h400, 64'd32, 64'h1234_5678_9abc_def0);
        tick();

        // RAS actions use the existing ordered TAGE inflight records.  A
        // younger call may resolve before an older return, but it must not
        // push until the older return has popped the prior top.
        reset_dut();
        present_control(64'h500, 64'd40, 32'h0000_00ef, 1'b0, 1'b1);
        tick();
        clear_inputs();
        resolve_control(64'h500, 64'd40, 32'h0000_00ef, 64'h900, 1'b0);
        tick();
        if ((dut.g_ras.u_ras.count_q != 1) ||
            (dut.g_ras.u_ras.stack_q[0] != 64'h504))
            $fatal(1, "ordered RAS seed call did not push PC+4");

        present_control(64'h600, 64'd41, 32'h0000_8067, 1'b1, 1'b1);
        if (!prediction_target_valid || (prediction_target != 64'h504))
            $fatal(1, "RAS did not predict seeded return address");
        tick();
        clear_inputs();
        present_control(64'h700, 64'd42, 32'h0000_00ef, 1'b0, 1'b1);
        tick();
        clear_inputs();

        // The unresolved younger call is already part of the logical return
        // stack.  A following return must see that speculative push instead
        // of waiting for either control to execute in order.
        present_control(64'h800, 64'd43, 32'h0000_8067, 1'b1, 1'b0);
        if (!prediction_target_valid || (prediction_target != 64'h704) ||
            fetch_stall)
            $fatal(1, "return did not use unresolved speculative RAS push");
        clear_inputs();

        resolve_control(64'h700, 64'd42, 32'h0000_00ef, 64'ha00, 1'b0);
        if ((dut.g_ras.u_ras.count_q != 1) ||
            (dut.g_ras.u_ras.stack_q[0] != 64'h504))
            $fatal(1, "younger resolved call updated RAS out of order");

        present_control(64'h800, 64'd43, 32'h0000_8067, 1'b1, 1'b0);
        if (!prediction_target_valid || (prediction_target != 64'h704) ||
            fetch_stall)
            $fatal(1, "return did not use resolved speculative RAS push");
        clear_inputs();

        resolve_control(64'h600, 64'd41, 32'h0000_8067, 64'h504, 1'b0);
        tick();
        if (dut.g_ras.u_ras.count_q != 0)
            $fatal(1, "older return did not pop before younger call push");
        tick();
        if ((dut.g_ras.u_ras.count_q != 1) ||
            (dut.g_ras.u_ras.stack_q[0] != 64'h704))
            $fatal(1, "ordered RAS call did not push after older return");

        present_control(64'h804, 64'd44, 32'h0000_8067, 1'b1, 1'b0);
        if (!prediction_target_valid || (prediction_target != 64'h704))
            $fatal(1, "ordered RAS state produced wrong final target");
        clear_inputs();

        // A redirecting older return must discard a younger, already-resolved
        // call before that call can change the RAS.
        present_control(64'h810, 64'd45, 32'h0000_8067, 1'b1, 1'b1);
        tick();
        clear_inputs();
        present_control(64'h900, 64'd46, 32'h0000_00ef, 1'b0, 1'b1);
        tick();
        clear_inputs();
        resolve_control(64'h900, 64'd46, 32'h0000_00ef, 64'hb00, 1'b0);

        // Before the redirect, the speculative younger call legitimately
        // supplies the projected top.
        present_control(64'h920, 64'd47, 32'h0000_8067, 1'b1, 1'b0);
        if (!prediction_target_valid || (prediction_target != 64'h904))
            $fatal(1, "younger speculative RAS push was not visible");
        clear_inputs();

        resolve_control(64'h810, 64'd45, 32'h0000_8067, 64'h704, 1'b1);
        // The younger call was discarded, while the redirecting return's pop
        // survives.  The projected stack is therefore empty before commit.
        present_control(64'h920, 64'd47, 32'h0000_8067, 1'b1, 1'b0);
        if (prediction_target_valid || !fetch_stall)
            $fatal(1, "squashed younger RAS update remained visible");
        clear_inputs();
        tick();
        if ((dut.g_ras.u_ras.count_q != 0) ||
            (dut.g_tage.u_tage.inflight_count_q != 0))
            $fatal(1, "squashed younger call polluted ordered RAS");

        // Two unresolved calls followed by consecutive returns exercise the
        // read-before-enqueue rule directly.  The first return observes the
        // newest call; only after it is accepted may the second return observe
        // the next older call.
        reset_dut();
        present_control(64'ha00, 64'd50, 32'h0000_00ef, 1'b0, 1'b1);
        tick();
        clear_inputs();
        present_control(64'hb00, 64'd51, 32'h0000_00ef, 1'b0, 1'b1);
        tick();
        clear_inputs();
        present_control(64'hc00, 64'd52, 32'h0000_8067, 1'b1, 1'b1);
        if (!prediction_target_valid || (prediction_target != 64'hb04))
            $fatal(1, "first speculative return consumed its own pop");
        tick();
        clear_inputs();
        present_control(64'hc04, 64'd53, 32'h0000_8067, 1'b1, 1'b0);
        if (!prediction_target_valid || (prediction_target != 64'ha04))
            $fatal(1, "consecutive return missed older speculative call");
        clear_inputs();
        #1;
        if (update_overflow || fetch_stall || decode_stall ||
            prediction_target_valid || target_mispredict)
            $fatal(1, "unexpected BP9 wrapper side effect");

        $display("PASS: BP9 compact TAGE provider, training, RAS ordering, aging, and recovery");
        $finish;
    end

    initial begin
        repeat (260) @(posedge clk);
        $fatal(1, "timeout in BP9 compact TAGE test");
    end
endmodule
