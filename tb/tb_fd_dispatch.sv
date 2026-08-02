`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/fpu/isa/rv64-d.v"
`include "core/exec/fpu/defs.v"

module tb_fd_dispatch;
    localparam integer WINDOW_DEPTH = 4;
    localparam integer TRANSFER_DEPTH = 2;
    localparam integer SW = 2;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer BASEW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer FPUW = `OPENRV64_FPU_DECODE_PAYLOAD_WIDTH;
    localparam integer IW = BASEW + FPUW;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg [IDW-1:0] squash_id;
    reg [2:0] allocation_valid;
    reg [3*IDW-1:0] allocation_id;
    reg [3*SW-1:0] allocation_slot;
    reg [3*BASEW-1:0] allocation_base_payload;
    reg [3*FPUW-1:0] allocation_payload;
    reg [3*`OPENRV64_EXTENSION_BRANCH_COUNT-1:0]
        allocation_branch_mask;
    reg [2:0] allocation_uses_rs1;
    reg [2:0] allocation_uses_rs2;
    reg [WINDOW_DEPTH-1:0] window_eligible;
    reg [WINDOW_DEPTH-1:0] window_issued;
    reg [WINDOW_DEPTH*64-1:0] window_src1_data;
    reg [WINDOW_DEPTH*64-1:0] window_src2_data;
    reg [SW-1:0] next_retire_slot;
    wire [WINDOW_DEPTH-1:0] entry_fp_valid;
    wire [WINDOW_DEPTH-1:0] entry_fp_compute;
    wire [WINDOW_DEPTH-1:0] entry_fp_load;
    wire [WINDOW_DEPTH-1:0] entry_fp_store;
    wire [WINDOW_DEPTH-1:0] entry_operand_ready;
    wire [14:0] fpr_read_addr;
    reg [191:0] fpr_read_data;
    reg fpu_ready;
    wire fpu_valid;
    wire fpu_fire;
    wire [IDW-1:0] fpu_id;
    wire [SW-1:0] fpu_slot;
    wire [`OPENRV64_FP_OP_WIDTH-1:0] fpu_op;
    wire [1:0] fpu_fmt;
    wire [2:0] fpu_rm;
    wire [4:0] fpu_type;
    wire [63:0] fpu_src1;
    wire [63:0] fpu_src2;
    wire [63:0] fpu_src3;
    wire [4:0] fpu_rd;
    wire fpu_fp_reg_write;
    wire fpu_int_reg_write;
    wire fpu_fflags_write;
    wire [`OPENRV64_EXTENSION_BRANCH_COUNT-1:0] fpu_branch_mask;
    reg fpu_result_valid;
    wire fpu_result_ready;
    reg [IDW-1:0] fpu_result_id;
    reg [SW-1:0] fpu_result_slot;
    reg fpu_result_is_int;
    reg [63:0] fpu_result_fp;
    reg [63:0] fpu_result_int;
    reg [4:0] fpu_result_fflags;
    reg fpu_result_unsupported;
    reg fp_mem_issue_valid;
    reg fp_mem_issue_is_load;
    reg [IDW-1:0] fp_mem_issue_id;
    reg [SW-1:0] fp_mem_issue_slot;
    wire fp_mem_issue_ready;
    wire [63:0] fp_mem_store_data;
    reg fp_load_result_valid;
    wire fp_load_result_match;
    reg [IDW-1:0] fp_load_result_id;
    reg [SW-1:0] fp_load_result_slot;
    reg [63:0] fp_load_result_data;
    reg [2:0] retire_valid;
    reg [3*IDW-1:0] retire_id;
    reg [3*SW-1:0] retire_slot;
    wire [2:0] retire_ready;
    wire [2:0] retire_accept = retire_valid & retire_ready;
    wire [2:0] retire_load_data_valid;
    wire [191:0] retire_load_data;
    wire [31:0] fp_write_busy;
    wire [1:0] transfer_count;

    openrv64_fd_dispatch #(
        .WINDOW_DEPTH(WINDOW_DEPTH),
        .TRANSFER_DEPTH(TRANSFER_DEPTH),
        .RETIRE_SLOT_WIDTH(SW)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .squash_i(squash), .squash_id_i(squash_id),
        .allocation_valid_i(allocation_valid),
        .allocation_id_i(allocation_id),
        .allocation_slot_i(allocation_slot),
        .allocation_base_payload_i(allocation_base_payload),
        .allocation_payload_i(allocation_payload),
        .allocation_branch_mask_i(allocation_branch_mask),
        .window_eligible_i(window_eligible),
        .window_issued_i(window_issued),
        .window_src1_data_i(window_src1_data),
        .window_src2_data_i(window_src2_data),
        .next_retire_slot_i(next_retire_slot),
        .entry_fp_valid_o(entry_fp_valid),
        .entry_fp_compute_o(entry_fp_compute),
        .entry_fp_load_o(entry_fp_load),
        .entry_fp_store_o(entry_fp_store),
        .entry_operand_ready_o(entry_operand_ready),
        .entry_mem_store_data_o(),
        .fp_mem_load_ready_o(),
        .fpr_read_addr_o(fpr_read_addr),
        .fpr_read_data_i(fpr_read_data),
        .fpu_ready_i(fpu_ready), .fpu_valid_o(fpu_valid),
        .fpu_fire_o(fpu_fire), .fpu_id_o(fpu_id),
        .fpu_slot_o(fpu_slot), .fpu_op_o(fpu_op),
        .fpu_fmt_o(fpu_fmt), .fpu_rm_o(fpu_rm),
        .fpu_type_o(fpu_type), .fpu_src1_o(fpu_src1),
        .fpu_src2_o(fpu_src2), .fpu_src3_o(fpu_src3),
        .fpu_rd_o(fpu_rd), .fpu_fp_reg_write_o(fpu_fp_reg_write),
        .fpu_int_reg_write_o(fpu_int_reg_write),
        .fpu_fflags_write_o(fpu_fflags_write),
        .fpu_branch_mask_o(fpu_branch_mask),
        .fpu_result_valid_i(fpu_result_valid),
        .fpu_result_ready_o(fpu_result_ready),
        .fpu_result_id_i(fpu_result_id),
        .fpu_result_slot_i(fpu_result_slot),
        .fpu_result_is_int_i(fpu_result_is_int),
        .fpu_result_fp_i(fpu_result_fp),
        .fpu_result_int_i(fpu_result_int),
        .fpu_result_fflags_i(fpu_result_fflags),
        .fpu_result_unsupported_i(fpu_result_unsupported),
        .completion_valid_o(),
        .completion_accept_i(1'b1),
        .completion_id_o(),
        .completion_slot_o(),
        .fp_mem_issue_valid_i(fp_mem_issue_valid),
        .fp_mem_issue_fire_i(fp_mem_issue_valid && fp_mem_issue_ready),
        .fp_mem_issue_is_load_i(fp_mem_issue_is_load),
        .fp_mem_issue_id_i(fp_mem_issue_id),
        .fp_mem_issue_slot_i(fp_mem_issue_slot),
        .fp_mem_issue_ready_o(fp_mem_issue_ready),
        .fp_mem_store_data_o(fp_mem_store_data),
        .fp_load_result_valid_i(fp_load_result_valid),
        .fp_load_result_match_o(fp_load_result_match),
        .fp_load_result_id_i(fp_load_result_id),
        .fp_load_result_slot_i(fp_load_result_slot),
        .fp_load_result_data_i(fp_load_result_data),
        .fp_mem_complete_valid_i(1'b0),
        .fp_mem_complete_id_i({IDW{1'b0}}),
        .fp_mem_complete_slot_i({SW{1'b0}}),
        .fp_mem_fault_valid_i(1'b0),
        .fp_mem_fault_id_i({IDW{1'b0}}),
        .fp_mem_fault_slot_i({SW{1'b0}}),
        .retire_valid_i(retire_valid), .retire_accept_i(retire_accept),
        .retire_id_i(retire_id),
        .retire_slot_i(retire_slot),
        .retire_ready_o(retire_ready),
        .retire_load_data_valid_o(retire_load_data_valid),
        .retire_load_data_o(retire_load_data),
        .retire_result_valid_o(),
        .retire_private_write_o(),
        .retire_gpr_write_o(),
        .retire_rd_o(),
        .retire_result_data_o(),
        .retire_fflags_valid_o(),
        .retire_fflags_o(),
        .retire_unsupported_o(),
        .fp_write_busy_o(fp_write_busy),
        .transfer_count_o(transfer_count)
    );

    always #5 clk = ~clk;

    // Simple combinational architectural FPR model.  It makes the selected
    // addresses visible in returned data without hiding an extra value path.
    always @* begin
        fpr_read_data[0*64 +: 64] = 64'hf000_0000_0000_0000 |
            {{59{1'b0}}, fpr_read_addr[0*5 +: 5]};
        fpr_read_data[1*64 +: 64] = 64'hf000_0000_0000_0000 |
            {{59{1'b0}}, fpr_read_addr[1*5 +: 5]};
        fpr_read_data[2*64 +: 64] = 64'hf000_0000_0000_0000 |
            {{59{1'b0}}, fpr_read_addr[2*5 +: 5]};
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic clear_cycle_inputs;
        begin
            allocation_valid = 3'b000;
            allocation_id = {3*IDW{1'b0}};
            allocation_slot = {3*SW{1'b0}};
            allocation_base_payload = {3*BASEW{1'b0}};
            allocation_payload = {3*FPUW{1'b0}};
            allocation_branch_mask =
                {3*`OPENRV64_EXTENSION_BRANCH_COUNT{1'b0}};
            allocation_uses_rs1 = 3'b000;
            allocation_uses_rs2 = 3'b000;
            fp_mem_issue_valid = 1'b0;
            fp_mem_issue_is_load = 1'b0;
            fp_mem_issue_id = {IDW{1'b0}};
            fp_mem_issue_slot = {SW{1'b0}};
            fp_load_result_valid = 1'b0;
            fp_load_result_id = {IDW{1'b0}};
            fp_load_result_slot = {SW{1'b0}};
            fp_load_result_data = 64'd0;
            fpu_result_valid = 1'b0;
            fpu_result_id = {IDW{1'b0}};
            fpu_result_slot = {SW{1'b0}};
            fpu_result_is_int = 1'b0;
            fpu_result_fp = 64'd0;
            fpu_result_int = 64'd0;
            fpu_result_fflags = 5'd0;
            fpu_result_unsupported = 1'b0;
            retire_valid = 3'b000;
            retire_id = {3*IDW{1'b0}};
            retire_slot = {3*SW{1'b0}};
        end
    endtask

    function automatic [IW-1:0] fp_binary;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[237 +: 5] = rs1;
            packet[232 +: 5] = rs2;
            packet[35 +: 5] = rd;
            packet[BASEW + `OPENRV64_FPU_SRC1_PRIVATE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_SRC2_PRIVATE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_STATE_WRITE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_OP_LSB +:
                   `OPENRV64_FP_OP_WIDTH] = `OPENRV64_FP_OP_ADD;
            packet[BASEW + `OPENRV64_FPU_FMT_LSB +: 2] =
                `RV64_FP_FMT_D;
            packet[BASEW + `OPENRV64_FPU_RM_LSB +: 3] =
                `RV64_FP_RM_RNE;
            fp_binary = packet;
        end
    endfunction

    function automatic [IW-1:0] fp_store;
        input [4:0] fp_rs2;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[232 +: 5] = fp_rs2;
            packet[BASEW + `OPENRV64_FPU_SRC2_PRIVATE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_STORE_BIT] = 1'b1;
            packet[15] = 1'b1;
            fp_store = packet;
        end
    endfunction

    function automatic [IW-1:0] int_to_fp;
        input [4:0] gp_rs1;
        input [4:0] fp_rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[237 +: 5] = gp_rs1;
            packet[35 +: 5] = fp_rd;
            packet[BASEW + `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_OP_LSB +:
                   `OPENRV64_FP_OP_WIDTH] = `OPENRV64_FP_OP_CVT_FROM_INT;
            packet[BASEW + `OPENRV64_FPU_FMT_LSB +: 2] =
                `RV64_FP_FMT_D;
            packet[BASEW + `OPENRV64_FPU_RM_LSB +: 3] =
                `RV64_FP_RM_RNE;
            int_to_fp = packet;
        end
    endfunction

    function automatic [IW-1:0] fp_load;
        input [4:0] fp_rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[35 +: 5] = fp_rd;
            packet[BASEW + `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_LOAD_BIT] = 1'b1;
            packet[16] = 1'b1;
            fp_load = packet;
        end
    endfunction

    reg [IW-1:0] packet0;
    reg [IW-1:0] packet1;

    task automatic set_allocation_lane;
        input integer lane;
        input [IW-1:0] packet;
        begin
            allocation_base_payload[lane*BASEW +: BASEW] =
                packet[0 +: BASEW];
            allocation_payload[lane*FPUW +: FPUW] =
                packet[BASEW +: FPUW];
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        squash_id = {IDW{1'b0}};
        window_eligible = {WINDOW_DEPTH{1'b0}};
        window_issued = {WINDOW_DEPTH{1'b0}};
        window_src1_data = {WINDOW_DEPTH*64{1'b0}};
        window_src2_data = {WINDOW_DEPTH*64{1'b0}};
        next_retire_slot = {SW{1'b0}};
        fpu_ready = 1'b0;
        clear_cycle_inputs();

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // Same-bundle FPR dependency: slot 1 consumes f3 written by slot 0.
        packet0 = fp_binary(5'd1, 5'd2, 5'd3);
        packet1 = fp_binary(5'd3, 5'd4, 5'd5);
        allocation_valid = 3'b011;
        allocation_id = {IDW'(0), IDW'(2), IDW'(1)};
        allocation_slot = {SW'(0), SW'(1), SW'(0)};
        set_allocation_lane(0, packet0);
        set_allocation_lane(1, packet1);
        allocation_uses_rs1 = 3'b011;
        allocation_uses_rs2 = 3'b011;
        tick();
        clear_cycle_inputs();
        window_eligible = 4'b0011;
        #1;
        if (!entry_operand_ready[0] || entry_operand_ready[1])
            fail("same-bundle FPR producer was not tracked separately");
        if (!fpu_valid || fpu_id != IDW'(1) || fpu_slot != SW'(0) ||
            fpr_read_addr[0 +: 5] != 5'd1 ||
            fpr_read_addr[5 +: 5] != 5'd2 ||
            fpu_src1 != 64'hf000_0000_0000_0001 ||
            fpu_src2 != 64'hf000_0000_0000_0002)
            fail("oldest FP request or FPR operands were incorrect");
        if (fpu_fire)
            fail("FPU request ignored input backpressure");

        fpu_ready = 1'b1;
        #1;
        if (!fpu_fire)
            fail("FPU request did not handshake after ready");
        tick();
        window_issued[0] = 1'b1;
        #1;
        if (fpu_valid)
            fail("dependent FPR consumer woke before producer retirement");

        fpu_result_valid = 1'b1;
        fpu_result_id = IDW'(1);
        fpu_result_slot = SW'(0);
        fpu_result_fp = 64'h3ff0_0000_0000_0000;
        #1;
        if (!fpu_result_ready)
            fail("live FPU result was not accepted by the sidecar scoreboard");
        tick();
        clear_cycle_inputs();

        retire_valid = 3'b001;
        retire_id[0 +: IDW] = IDW'(1);
        retire_slot[0 +: SW] = SW'(0);
        #1;
        if (entry_operand_ready[1])
            fail("retirement wake became combinational FPR forwarding");
        tick();
        clear_cycle_inputs();
        #1;
        if (!entry_operand_ready[1] || !fpu_valid ||
            fpu_id != IDW'(2) || fpr_read_addr[0 +: 5] != 5'd3)
            fail("matching retirement did not release FPR consumer");

        // Cross-domain conversion gets its integer operand from the parent
        // window; fd_dispatch must not reinterpret x6 as f6.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        window_eligible = 4'b0000;
        window_issued = 4'b0000;
        window_src1_data[0 +: 64] = 64'h8000_0000_0000_0006;
        packet0 = int_to_fp(5'd6, 5'd9);
        allocation_valid = 3'b001;
        allocation_id[0 +: IDW] = IDW'(3);
        allocation_slot[0 +: SW] = SW'(0);
        set_allocation_lane(0, packet0);
        allocation_uses_rs1 = 3'b001;
        tick();
        clear_cycle_inputs();
        window_eligible = 4'b0001;
        #1;
        if (!fpu_valid || fpu_id != IDW'(3) ||
            fpu_src1 != 64'h8000_0000_0000_0006 ||
            fpr_read_addr[0 +: 5] != 5'd0 || !fpu_fp_reg_write ||
            fpu_int_reg_write)
            fail("cross-domain integer source was read from the FPR domain");

        // Start a transfer test with two stores.  Their data is captured into
        // the two tagged entries while no FPU request owns the read ports.
        flush = 1'b1;
        tick();
        flush = 1'b0;
        window_eligible = 4'b0000;
        window_issued = 4'b0000;
        packet0 = fp_store(5'd6);
        packet1 = fp_store(5'd7);
        allocation_valid = 3'b011;
        allocation_id = {IDW'(0), IDW'(11), IDW'(10)};
        allocation_slot = {SW'(0), SW'(1), SW'(0)};
        set_allocation_lane(0, packet0);
        set_allocation_lane(1, packet1);
        allocation_uses_rs2 = 3'b011;
        tick();
        clear_cycle_inputs();
        #1;
        if (fpr_read_addr[5 +: 5] != 5'd6)
            fail("oldest FP store was not selected for data capture");
        tick();
        #1;
        if (transfer_count != 1 || !entry_operand_ready[0] ||
            fpr_read_addr[5 +: 5] != 5'd7)
            fail("first FP store transfer was not captured");
        tick();
        #1;
        if (transfer_count != 2 || !entry_operand_ready[1])
            fail("two-entry FP transfer buffer did not fill");

        fp_mem_issue_valid = 1'b1;
        fp_mem_issue_is_load = 1'b0;
        fp_mem_issue_id = IDW'(10);
        fp_mem_issue_slot = SW'(0);
        #1;
        if (!fp_mem_issue_ready ||
            fp_mem_store_data != 64'hf000_0000_0000_0006)
            fail("captured FP store data was not offered to LSU");
        tick();
        clear_cycle_inputs();
        window_issued[0] = 1'b1;
        #1;
        if (transfer_count != 1)
            fail("LSU store acceptance did not release transfer entry");

        // Reserve the freed entry for a load.  A third transfer must then
        // backpressure until one of the two exact-tagged entries is consumed.
        packet0 = fp_load(5'd8);
        allocation_valid = 3'b001;
        allocation_id[0 +: IDW] = IDW'(12);
        allocation_slot[0 +: SW] = SW'(2);
        set_allocation_lane(0, packet0);
        tick();
        clear_cycle_inputs();
        fp_mem_issue_valid = 1'b1;
        fp_mem_issue_is_load = 1'b1;
        fp_mem_issue_id = IDW'(12);
        fp_mem_issue_slot = SW'(2);
        #1;
        if (!fp_mem_issue_ready)
            fail("FP load could not reserve the freed transfer entry");
        tick();
        clear_cycle_inputs();
        #1;
        if (transfer_count != 2)
            fail("FP load transfer reservation was not retained");

        fp_mem_issue_valid = 1'b1;
        fp_mem_issue_is_load = 1'b1;
        fp_mem_issue_id = IDW'(13);
        fp_mem_issue_slot = SW'(3);
        #1;
        if (fp_mem_issue_ready)
            fail("full two-entry transfer buffer did not backpressure load");
        clear_cycle_inputs();

        fp_load_result_valid = 1'b1;
        fp_load_result_id = IDW'(13);
        fp_load_result_slot = SW'(2);
        fp_load_result_data = 64'hbad0;
        #1;
        if (fp_load_result_match)
            fail("mismatched load ID was accepted by retirement slot alone");
        tick();
        clear_cycle_inputs();

        fp_load_result_valid = 1'b1;
        fp_load_result_id = IDW'(12);
        fp_load_result_slot = SW'(2);
        fp_load_result_data = 64'h1234_5678_9abc_def0;
        #1;
        if (!fp_load_result_match)
            fail("matching FP load response was rejected");
        tick();
        clear_cycle_inputs();

        retire_valid = 3'b001;
        retire_id[0 +: IDW] = IDW'(12);
        retire_slot[0 +: SW] = SW'(2);
        #1;
        if (!retire_load_data_valid[0] ||
            retire_load_data[0 +: 64] != 64'h1234_5678_9abc_def0)
            fail("filled FP load data was not presented at retirement");
        tick();
        clear_cycle_inputs();
        if (transfer_count != 1)
            fail("retiring FP load did not consume its transfer entry");

        // Squash the remaining younger transfer and prove a late response is
        // dropped even if its physical slot is subsequently reused.
        fp_mem_issue_valid = 1'b1;
        fp_mem_issue_is_load = 1'b1;
        fp_mem_issue_id = IDW'(13);
        fp_mem_issue_slot = SW'(3);
        tick();
        clear_cycle_inputs();
        squash_id = IDW'(12);
        squash = 1'b1;
        tick();
        squash = 1'b0;
        if (transfer_count != 1)
            fail("selective squash removed older store or retained load");
        fp_load_result_valid = 1'b1;
        fp_load_result_id = IDW'(13);
        fp_load_result_slot = SW'(3);
        fp_load_result_data = 64'hdead_beef;
        #1;
        if (fp_load_result_match)
            fail("late squashed FP load response matched reused state");

        $display("PASS: F/D sidecar retire-only dependencies, FPU backpressure, and two tagged transfers");
        $finish;
    end
endmodule
