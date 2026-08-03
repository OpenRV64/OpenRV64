`timescale 1ns/1ps

`include "core/backend/backend-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/exec/fpu/isa/rv64-d.v"
`include "core/exec/fpu/defs.v"

// Decoded-uop integration harness for the 4PF F/D path.
//
// The parent window, LSU, and retirement queue are deliberately small models;
// the F/D sidecar, architectural FPR, and pipelined FPU are the real RTL.  This
// is the last directed boundary before adding the
// 4PF fetch/decode top and executing a software image.
module tb_fd_uop_harness;
    localparam integer WINDOW_DEPTH = 8;
    localparam integer SW = 3;
    localparam integer IDW = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer BASEW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer FPUW = `OPENRV64_FPU_DECODE_PAYLOAD_WIDTH;
    localparam integer BRW = `OPENRV64_EXTENSION_BRANCH_COUNT;
    // Test helper packet only.  The real interface carries these three
    // domains separately so the parent never interprets FPU fields.
    localparam integer IW = BASEW + FPUW + BRW;

    localparam integer TAG_ID_LSB = 0;
    localparam integer TAG_SLOT_LSB = TAG_ID_LSB + IDW;
    localparam integer TAG_RD_LSB = TAG_SLOT_LSB + SW;
    localparam integer TAG_FP_WRITE_BIT = TAG_RD_LSB + 5;
    localparam integer TAG_INT_WRITE_BIT = TAG_FP_WRITE_BIT + 1;
    localparam integer TAG_FLAGS_WRITE_BIT = TAG_INT_WRITE_BIT + 1;
    localparam integer TAG_BRANCH_LSB = TAG_FLAGS_WRITE_BIT + 1;
    localparam integer TAGW = TAG_BRANCH_LSB + BRW;

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
    reg [3*BRW-1:0] allocation_branch_mask;
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
    wire [WINDOW_DEPTH*64-1:0] entry_mem_store_data;

    wire [14:0] fpr_read_addr;
    wire [191:0] fpr_read_data;
    wire [63:0] fpr_rs1_data;
    wire [63:0] fpr_rs2_data;
    wire [63:0] fpr_rs3_data;

    wire fpu_request_ready;
    wire fpu_request_valid;
    wire fpu_request_fire;
    wire [IDW-1:0] fpu_request_id;
    wire [SW-1:0] fpu_request_slot;
    wire [`OPENRV64_FP_OP_WIDTH-1:0] fpu_request_op;
    wire [1:0] fpu_request_fmt;
    wire [2:0] fpu_request_rm;
    wire [4:0] fpu_request_type;
    wire [63:0] fpu_request_src1;
    wire [63:0] fpu_request_src2;
    wire [63:0] fpu_request_src3;
    wire [4:0] fpu_request_rd;
    wire fpu_request_fp_write;
    wire fpu_request_int_write;
    wire fpu_request_flags_write;
    wire [BRW-1:0] fpu_request_branch_mask;
    wire [TAGW-1:0] fpu_request_tag;

    wire fpu_result_valid;
    reg fpu_result_sink_ready;
    wire fpu_result_dispatch_ready;
    wire fpu_result_ready = fpu_result_sink_ready &&
                            fpu_result_dispatch_ready;
    wire [TAGW-1:0] fpu_result_tag;
    wire fpu_result_is_int;
    wire [63:0] fpu_result_fp;
    wire [63:0] fpu_result_int;
    wire [4:0] fpu_result_flags;
    wire fpu_result_unsupported;

    wire [IDW-1:0] result_id =
        fpu_result_tag[TAG_ID_LSB +: IDW];
    wire [SW-1:0] result_slot =
        fpu_result_tag[TAG_SLOT_LSB +: SW];
    wire [4:0] result_rd = fpu_result_tag[TAG_RD_LSB +: 5];
    wire result_fp_write = fpu_result_tag[TAG_FP_WRITE_BIT];
    wire result_int_write = fpu_result_tag[TAG_INT_WRITE_BIT];
    wire [BRW-1:0] result_branch_mask =
        fpu_result_tag[TAG_BRANCH_LSB +:
                       BRW];

    reg fp_mem_issue_valid;
    reg fp_mem_issue_is_load;
    reg [IDW-1:0] fp_mem_issue_id;
    reg [SW-1:0] fp_mem_issue_slot;
    wire fp_mem_issue_ready = fp_mem_issue_is_load ? 1'b1 :
        entry_operand_ready[fp_mem_issue_slot];
    wire [63:0] fp_mem_store_data = entry_mem_store_data[
        fp_mem_issue_slot*64 +: 64];
    wire fp_mem_issue_fire = fp_mem_issue_valid && fp_mem_issue_ready;
    reg fp_load_assignment_valid;
    wire fp_load_assignment_match;
    reg [IDW-1:0] fp_load_assignment_id;
    reg [SW-1:0] fp_load_assignment_slot;
    reg [4:0] fp_load_assignment_rd;
    reg [2:0] fp_load_assignment_size;
    wire [4:0] fpr_store_read_addr;
    wire [63:0] fpr_store_read_data;

    reg fp_load_result_valid;
    wire fp_load_result_match;
    reg [IDW-1:0] fp_load_result_id;
    reg [SW-1:0] fp_load_result_slot;
    reg [63:0] fp_load_result_data;

    reg fp_mem_complete_valid;
    reg [IDW-1:0] fp_mem_complete_id;
    reg [SW-1:0] fp_mem_complete_slot;

    reg [2:0] retire_valid;
    wire [2:0] retire_accept;
    reg [3*IDW-1:0] retire_id;
    reg [3*SW-1:0] retire_slot;
    wire [2:0] retire_ready;
    wire [2:0] retire_load_data_valid;
    wire [191:0] retire_load_data;
    wire [2:0] retire_result_valid;
    wire [2:0] retire_private_write;
    wire [2:0] retire_gpr_write;
    wire [14:0] retire_result_rd;
    wire [191:0] retire_result_data;
    wire [2:0] retire_fflags_valid;
    wire [14:0] retire_fflags;
    wire [2:0] retire_unsupported;
    wire [31:0] fp_write_busy;

    reg parent_valid [0:WINDOW_DEPTH-1];
    reg [IDW-1:0] parent_id [0:WINDOW_DEPTH-1];
    reg [4:0] parent_rd [0:WINDOW_DEPTH-1];
    reg parent_fp_write [0:WINDOW_DEPTH-1];

    // Minimal parent retirement model: completion identity only.  All FPU
    // data, flags, and destination selection remain inside u_dispatch.
    reg parent_complete [0:WINDOW_DEPTH-1];
    wire extension_completion_valid;
    wire [IDW-1:0] extension_completion_id;
    wire [SW-1:0] extension_completion_slot;
    reg extension_completion_sink_ready;
    wire extension_completion_accept = extension_completion_valid &&
        extension_completion_sink_ready &&
        parent_valid[extension_completion_slot] &&
        (parent_id[extension_completion_slot] == extension_completion_id);

    reg [BRW-1:0] poisoned_branch_mask;
    reg [4:0] architectural_fflags;
    integer live_result_count;
    integer squashed_result_count;
    integer late_result_count;
    integer result_stall_cycles;

    reg init_fpr_write;
    reg [4:0] init_fpr_addr;
    reg [63:0] init_fpr_data;
    reg retire_fpr_write;
    reg [4:0] retire_fpr_addr;
    reg [63:0] retire_fpr_data;
    wire fpr_write = init_fpr_write || retire_fpr_write;
    wire [4:0] fpr_write_addr = init_fpr_write ?
                                init_fpr_addr : retire_fpr_addr;
    wire [63:0] fpr_write_data = init_fpr_write ?
                                  init_fpr_data : retire_fpr_data;

    assign fpr_read_data = {fpr_rs3_data, fpr_rs2_data, fpr_rs1_data};
    assign fpu_request_tag = {
        fpu_request_branch_mask,
        fpu_request_flags_write,
        fpu_request_int_write,
        fpu_request_fp_write,
        fpu_request_rd,
        fpu_request_slot,
        fpu_request_id
    };
    assign retire_accept = retire_valid & retire_ready;

    openrv64_fd_dispatch #(
        .WINDOW_DEPTH(WINDOW_DEPTH),
        .RETIRE_SLOT_WIDTH(SW)
    ) u_dispatch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(squash),
        .squash_id_i(squash_id),
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
        .entry_mem_store_data_o(entry_mem_store_data),
        .fp_mem_load_ready_o(),
        .fpr_read_addr_o(fpr_read_addr),
        .fpr_read_data_i(fpr_read_data),
        .fpr_store_read_addr_o(fpr_store_read_addr),
        .fpr_store_read_data_i(fpr_store_read_data),
        .fpu_ready_i(fpu_request_ready),
        .fpu_valid_o(fpu_request_valid),
        .fpu_fire_o(fpu_request_fire),
        .fpu_id_o(fpu_request_id),
        .fpu_slot_o(fpu_request_slot),
        .fpu_op_o(fpu_request_op),
        .fpu_fmt_o(fpu_request_fmt),
        .fpu_rm_o(fpu_request_rm),
        .fpu_type_o(fpu_request_type),
        .fpu_src1_o(fpu_request_src1),
        .fpu_src2_o(fpu_request_src2),
        .fpu_src3_o(fpu_request_src3),
        .fpu_rd_o(fpu_request_rd),
        .fpu_fp_reg_write_o(fpu_request_fp_write),
        .fpu_int_reg_write_o(fpu_request_int_write),
        .fpu_fflags_write_o(fpu_request_flags_write),
        .fpu_branch_mask_o(fpu_request_branch_mask),
        .fpu_result_valid_i(fpu_result_valid && fpu_result_sink_ready),
        .fpu_result_ready_o(fpu_result_dispatch_ready),
        .fpu_result_id_i(result_id),
        .fpu_result_slot_i(result_slot),
        .fpu_result_is_int_i(fpu_result_is_int),
        .fpu_result_fp_i(fpu_result_fp),
        .fpu_result_int_i(fpu_result_int),
        .fpu_result_fflags_i(fpu_result_flags),
        .fpu_result_unsupported_i(fpu_result_unsupported),
        .completion_valid_o(extension_completion_valid),
        .completion_accept_i(extension_completion_accept),
        .completion_id_o(extension_completion_id),
        .completion_slot_o(extension_completion_slot),
        .fp_load_assignment_valid_i(fp_load_assignment_valid),
        .fp_load_assignment_match_o(fp_load_assignment_match),
        .fp_load_assignment_id_i(fp_load_assignment_id),
        .fp_load_assignment_slot_i(fp_load_assignment_slot),
        .fp_load_assignment_rd_i(fp_load_assignment_rd),
        .fp_load_assignment_size_i(fp_load_assignment_size),
        .fp_load_result_valid_i(fp_load_result_valid),
        .fp_load_result_match_o(fp_load_result_match),
        .fp_load_result_id_i(fp_load_result_id),
        .fp_load_result_slot_i(fp_load_result_slot),
        .fp_load_result_data_i(fp_load_result_data),
        .fp_mem_fault_valid_i(1'b0),
        .fp_mem_fault_id_i({IDW{1'b0}}),
        .fp_mem_fault_slot_i({SW{1'b0}}),
        .retire_valid_i(retire_valid),
        .retire_accept_i(retire_accept),
        .retire_id_i(retire_id),
        .retire_slot_i(retire_slot),
        .retire_ready_o(retire_ready),
        .retire_load_data_valid_o(retire_load_data_valid),
        .retire_load_data_o(retire_load_data),
        .retire_result_valid_o(retire_result_valid),
        .retire_private_write_o(retire_private_write),
        .retire_gpr_write_o(retire_gpr_write),
        .retire_rd_o(retire_result_rd),
        .retire_result_data_o(retire_result_data),
        .retire_fflags_valid_o(retire_fflags_valid),
        .retire_fflags_o(retire_fflags),
        .retire_unsupported_o(retire_unsupported),
        .fp_write_busy_o(fp_write_busy)
    );

    openrv64_rv64fd_fpr u_fpr (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr_i(fpr_read_addr[0 +: 5]),
        .rs1_data_o(fpr_rs1_data),
        .rs2_addr_i(fpr_read_addr[5 +: 5]),
        .rs2_data_o(fpr_rs2_data),
        .rs3_addr_i(fpr_read_addr[10 +: 5]),
        .rs3_data_o(fpr_rs3_data),
        .store_addr_i(fpr_store_read_addr),
        .store_data_o(fpr_store_read_data),
        .rd_write_i(fpr_write),
        .rd_addr_i(fpr_write_addr),
        .rd_data_i(fpr_write_data)
    );

    openrv64_exec_fpu_rv64fd #(
        .TAG_WIDTH(TAGW)
    ) u_fpu (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .valid_i(fpu_request_valid),
        .ready_o(fpu_request_ready),
        .tag_i(fpu_request_tag),
        .op_i(fpu_request_op),
        .fmt_i(fpu_request_fmt),
        .rm_i(fpu_request_rm),
        .frm_i(`RV64_FP_RM_RNE),
        .type_i(fpu_request_type),
        .src1_i(fpu_request_src1),
        .src2_i(fpu_request_src2),
        .src3_i(fpu_request_src3),
        .result_valid_o(fpu_result_valid),
        .result_ready_i(fpu_result_ready),
        .result_tag_o(fpu_result_tag),
        .result_is_int_o(fpu_result_is_int),
        .fp_result_o(fpu_result_fp),
        .int_result_o(fpu_result_int),
        .fflags_o(fpu_result_flags),
        .unsupported_o(fpu_result_unsupported)
    );

    always #5 clk = ~clk;

    function automatic id_is_younger;
        input [IDW-1:0] candidate;
        input [IDW-1:0] reference;
        reg [IDW-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger = (distance != {IDW{1'b0}}) &&
                            !distance[IDW-1];
        end
    endfunction

    function automatic [IW-1:0] make_fp_load;
        input [4:0] rd;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[35 +: 5] = rd;
            packet[BASEW + `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_LOAD_BIT] = 1'b1;
            packet[16] = 1'b1;
            make_fp_load = packet;
        end
    endfunction

    function automatic [IW-1:0] make_fp_store;
        input [4:0] rs2;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[232 +: 5] = rs2;
            packet[BASEW + `OPENRV64_FPU_SRC2_PRIVATE_BIT] = 1'b1;
            packet[BASEW + `OPENRV64_FPU_STORE_BIT] = 1'b1;
            packet[15] = 1'b1;
            make_fp_store = packet;
        end
    endfunction

    function automatic [IW-1:0] make_fp_compute;
        input [`OPENRV64_FP_OP_WIDTH-1:0] op;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rs3;
        input [4:0] rd;
        input uses_rs3;
        input [BRW-1:0] branch_mask;
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
                   `OPENRV64_FP_OP_WIDTH] = op;
            packet[BASEW + `OPENRV64_FPU_FMT_LSB +: 2] = `RV64_FP_FMT_D;
            packet[BASEW + `OPENRV64_FPU_RM_LSB +: 3] = `RV64_FP_RM_RNE;
            packet[BASEW + FPUW +: BRW] = branch_mask;
            if (uses_rs3) begin
                packet[BASEW + `OPENRV64_FPU_USES_SRC3_BIT] = 1'b1;
                packet[BASEW + `OPENRV64_FPU_SRC3_PRIVATE_BIT] = 1'b1;
                packet[BASEW + `OPENRV64_FPU_RS3_ADDR_LSB +: 5] = rs3;
            end
            make_fp_compute = packet;
        end
    endfunction

    integer parent_slot_idx;
    integer parent_lane_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_eligible <= {WINDOW_DEPTH{1'b0}};
            window_issued <= {WINDOW_DEPTH{1'b0}};
            for (parent_slot_idx = 0; parent_slot_idx < WINDOW_DEPTH;
                 parent_slot_idx = parent_slot_idx + 1) begin
                parent_valid[parent_slot_idx] <= 1'b0;
                parent_complete[parent_slot_idx] <= 1'b0;
                parent_id[parent_slot_idx] <= {IDW{1'b0}};
                parent_rd[parent_slot_idx] <= 5'd0;
                parent_fp_write[parent_slot_idx] <= 1'b0;
            end
        end else if (flush) begin
            window_eligible <= {WINDOW_DEPTH{1'b0}};
            window_issued <= {WINDOW_DEPTH{1'b0}};
            for (parent_slot_idx = 0; parent_slot_idx < WINDOW_DEPTH;
                 parent_slot_idx = parent_slot_idx + 1) begin
                parent_valid[parent_slot_idx] <= 1'b0;
                parent_complete[parent_slot_idx] <= 1'b0;
            end
        end else begin
            if (squash) begin
                for (parent_slot_idx = 0; parent_slot_idx < WINDOW_DEPTH;
                     parent_slot_idx = parent_slot_idx + 1) begin
                    if (parent_valid[parent_slot_idx] &&
                        id_is_younger(parent_id[parent_slot_idx], squash_id)) begin
                        parent_valid[parent_slot_idx] <= 1'b0;
                        parent_complete[parent_slot_idx] <= 1'b0;
                        window_eligible[parent_slot_idx] <= 1'b0;
                        window_issued[parent_slot_idx] <= 1'b0;
                    end
                end
            end

            for (parent_lane_idx = 0; parent_lane_idx < 3;
                 parent_lane_idx = parent_lane_idx + 1) begin
                if (retire_accept[parent_lane_idx] &&
                    parent_valid[retire_slot[parent_lane_idx*SW +: SW]] &&
                    (parent_id[retire_slot[parent_lane_idx*SW +: SW]] ==
                     retire_id[parent_lane_idx*IDW +: IDW])) begin
                    parent_valid[retire_slot[parent_lane_idx*SW +: SW]] <=
                        1'b0;
                    parent_complete[
                        retire_slot[parent_lane_idx*SW +: SW]] <= 1'b0;
                    window_eligible[
                        retire_slot[parent_lane_idx*SW +: SW]] <= 1'b0;
                    window_issued[
                        retire_slot[parent_lane_idx*SW +: SW]] <= 1'b0;
                end
            end

            for (parent_lane_idx = 0; parent_lane_idx < 3;
                 parent_lane_idx = parent_lane_idx + 1) begin
                if (allocation_valid[parent_lane_idx]) begin
                    parent_valid[
                        allocation_slot[parent_lane_idx*SW +: SW]] <= 1'b1;
                    parent_id[
                        allocation_slot[parent_lane_idx*SW +: SW]] <=
                        allocation_id[parent_lane_idx*IDW +: IDW];
                    parent_complete[
                        allocation_slot[parent_lane_idx*SW +: SW]] <= 1'b0;
                    parent_rd[
                        allocation_slot[parent_lane_idx*SW +: SW]] <=
                        allocation_base_payload[
                            parent_lane_idx*BASEW + 35 +: 5];
                    parent_fp_write[
                        allocation_slot[parent_lane_idx*SW +: SW]] <=
                        allocation_payload[parent_lane_idx*FPUW +
                            `OPENRV64_FPU_PRIVATE_REG_WRITE_BIT];
                    window_eligible[
                        allocation_slot[parent_lane_idx*SW +: SW]] <= 1'b1;
                    window_issued[
                        allocation_slot[parent_lane_idx*SW +: SW]] <= 1'b0;
                end
            end

            if (fpu_request_fire)
                window_issued[fpu_request_slot] <= 1'b1;
            if (fp_mem_issue_fire)
                window_issued[fp_mem_issue_slot] <= 1'b1;
            if (extension_completion_accept)
                parent_complete[extension_completion_slot] <= 1'b1;
            // The ordinary LSU owns memory completion.  The sidecar only
            // retains the private result value; it does not emit a second
            // completion token for the same load/store uop.
            if (fp_load_result_valid && fp_load_result_match &&
                parent_valid[fp_load_result_slot] &&
                (parent_id[fp_load_result_slot] == fp_load_result_id))
                parent_complete[fp_load_result_slot] <= 1'b1;
            if (fp_mem_complete_valid &&
                parent_valid[fp_mem_complete_slot] &&
                (parent_id[fp_mem_complete_slot] == fp_mem_complete_id))
                parent_complete[fp_mem_complete_slot] <= 1'b1;
        end
    end

    // Observe the raw FPU stream only to check redirect behavior.  This block
    // does not retain result data or participate in retirement.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live_result_count <= 0;
            squashed_result_count <= 0;
            late_result_count <= 0;
        end else begin
            if (fpu_result_valid && fpu_result_ready) begin
                if ((result_branch_mask & poisoned_branch_mask) != 0) begin
                    squashed_result_count <= squashed_result_count + 1;
                end else if (parent_valid[result_slot] &&
                             (parent_id[result_slot] == result_id)) begin
                    if (fpu_result_unsupported)
                        $fatal(1, "live FPU result reported unsupported");
                    if (fpu_result_is_int || result_int_write)
                        $fatal(1,
                            "unexpected integer FPU result in harness data=%016x",
                            fpu_result_int);
                    if ((result_rd != parent_rd[result_slot]) ||
                        (result_fp_write != parent_fp_write[result_slot]))
                        $fatal(1,
                            "FPU completion metadata disagreed with parent slot");
                    live_result_count <= live_result_count + 1;
                end else begin
                    late_result_count <= late_result_count + 1;
                end
            end
        end
    end

    integer flags_lane_idx;
    reg [4:0] retiring_fflags;
    always @* begin
        retiring_fflags = 5'd0;
        for (flags_lane_idx = 0; flags_lane_idx < 3;
             flags_lane_idx = flags_lane_idx + 1) begin
            if (retire_accept[flags_lane_idx] &&
                retire_fflags_valid[flags_lane_idx])
                retiring_fflags = retiring_fflags |
                    retire_fflags[flags_lane_idx*5 +: 5];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            architectural_fflags <= 5'd0;
        else
            architectural_fflags <= architectural_fflags | retiring_fflags;
    end

    integer retire_write_lane;
    always @* begin
        retire_fpr_write = 1'b0;
        retire_fpr_addr = 5'd0;
        retire_fpr_data = 64'd0;
        for (retire_write_lane = 0; retire_write_lane < 3;
             retire_write_lane = retire_write_lane + 1) begin
            if (retire_accept[retire_write_lane] &&
                retire_result_valid[retire_write_lane] &&
                retire_private_write[retire_write_lane]) begin
                retire_fpr_write = 1'b1;
                retire_fpr_addr = retire_result_rd[
                    retire_write_lane*5 +: 5];
                retire_fpr_data = retire_result_data[
                    retire_write_lane*64 +: 64];
            end
        end
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

    task automatic clear_all_inputs;
        begin
            allocation_valid = 3'b000;
            allocation_id = {3*IDW{1'b0}};
            allocation_slot = {3*SW{1'b0}};
            allocation_base_payload = {3*BASEW{1'b0}};
            allocation_payload = {3*FPUW{1'b0}};
            allocation_branch_mask = {3*BRW{1'b0}};
            allocation_uses_rs1 = 3'b000;
            allocation_uses_rs2 = 3'b000;
            fp_mem_issue_valid = 1'b0;
            fp_mem_issue_is_load = 1'b0;
            fp_mem_issue_id = {IDW{1'b0}};
            fp_mem_issue_slot = {SW{1'b0}};
            fp_load_assignment_valid = 1'b0;
            fp_load_assignment_id = {IDW{1'b0}};
            fp_load_assignment_slot = {SW{1'b0}};
            fp_load_assignment_rd = 5'd0;
            fp_load_assignment_size = 3'd0;
            fp_load_result_valid = 1'b0;
            fp_load_result_id = {IDW{1'b0}};
            fp_load_result_slot = {SW{1'b0}};
            fp_load_result_data = 64'd0;
            fp_mem_complete_valid = 1'b0;
            fp_mem_complete_id = {IDW{1'b0}};
            fp_mem_complete_slot = {SW{1'b0}};
            retire_valid = 3'b000;
            retire_id = {3*IDW{1'b0}};
            retire_slot = {3*SW{1'b0}};
        end
    endtask

    task automatic initialize_fpr;
        input [4:0] address;
        input [63:0] data;
        begin
            init_fpr_write = 1'b1;
            init_fpr_addr = address;
            init_fpr_data = data;
            tick();
            init_fpr_write = 1'b0;
            #1;
            if (u_fpr.regs[address] !== data)
                fail("architectural FPR initialization failed");
        end
    endtask

    task automatic allocate_one;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [IW-1:0] packet;
        input uses_rs1;
        input uses_rs2;
        begin
            allocation_valid = 3'b001;
            allocation_id[0 +: IDW] = id;
            allocation_slot[0 +: SW] = slot;
            allocation_base_payload[0 +: BASEW] = packet[0 +: BASEW];
            allocation_payload[0 +: FPUW] = packet[BASEW +: FPUW];
            allocation_branch_mask[0 +: BRW] =
                packet[BASEW + FPUW +: BRW];
            allocation_uses_rs1[0] = uses_rs1;
            allocation_uses_rs2[0] = uses_rs2;
            tick();
            allocation_valid = 3'b000;
            allocation_uses_rs1 = 3'b000;
            allocation_uses_rs2 = 3'b000;
            allocation_base_payload = {3*BASEW{1'b0}};
            allocation_payload = {3*FPUW{1'b0}};
            allocation_branch_mask = {3*BRW{1'b0}};
            #1;
            if (!entry_fp_valid[slot] || !window_eligible[slot])
                fail("decoded FP uop was not admitted into both window views");
            if ((entry_fp_load[slot] !==
                 packet[BASEW + `OPENRV64_FPU_LOAD_BIT]) ||
                (entry_fp_store[slot] !==
                 packet[BASEW + `OPENRV64_FPU_STORE_BIT]) ||
                (entry_fp_compute[slot] !==
                 (!packet[BASEW + `OPENRV64_FPU_LOAD_BIT] &&
                  !packet[BASEW + `OPENRV64_FPU_STORE_BIT])))
                fail("sidecar classified decoded FP uop incorrectly");
        end
    endtask

    task automatic issue_load;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        begin
            fp_mem_issue_valid = 1'b1;
            fp_mem_issue_is_load = 1'b1;
            fp_mem_issue_id = id;
            fp_mem_issue_slot = slot;
            fp_load_assignment_valid = 1'b1;
            fp_load_assignment_id = id;
            fp_load_assignment_slot = slot;
            fp_load_assignment_rd = parent_rd[slot];
            fp_load_assignment_size = {1'b0, `RV64_LSU_SIZE_WORD};
            #1;
            if (!fp_mem_issue_ready || !fp_load_assignment_match)
                fail("expected FP load did not confirm its LSU assignment");
            tick();
            fp_mem_issue_valid = 1'b0;
            fp_load_assignment_valid = 1'b0;
            #1;
            if (!window_issued[slot])
                fail("parent window did not record FP load issue");
        end
    endtask

    task automatic return_load;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [63:0] data;
        begin
            fp_load_result_valid = 1'b1;
            fp_load_result_id = id;
            fp_load_result_slot = slot;
            fp_load_result_data = data;
            #1;
            if (!fp_load_result_match)
                fail("exact-tag FP load response did not match reservation");
            tick();
            fp_load_result_valid = 1'b0;
        end
    endtask

    task automatic expect_fpu_issue;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [BRW-1:0] branch_mask;
        integer cycles;
        begin
            cycles = 0;
            while (!(fpu_request_valid && fpu_request_ready) &&
                   (cycles < 40)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!(fpu_request_valid && fpu_request_ready))
                fail("timed out waiting for expected FPU request");
            if ((fpu_request_id != id) ||
                (fpu_request_slot != slot) ||
                (fpu_request_branch_mask != branch_mask)) begin
                $display("FPU ISSUE expected id=%0d slot=%0d mask=%b; got id=%0d slot=%0d mask=%b eligible=%b issued=%b next=%0d",
                    id, slot, branch_mask, fpu_request_id,
                    fpu_request_slot, fpu_request_branch_mask,
                    window_eligible, window_issued, next_retire_slot);
                fail("FPU request tag or age selection was incorrect");
            end
            tick();
            if (!window_issued[slot])
                fail("parent window did not record FPU request issue");
        end
    endtask

    reg [TAGW-1:0] held_result_tag;
    reg [63:0] held_result_data;
    reg [4:0] held_result_flags;
    reg held_result_unsupported;
    task automatic accept_stalled_result;
        input [IDW-1:0] expected_id;
        input [SW-1:0] expected_slot;
        input [63:0] expected_data;
        integer cycles;
        integer hold_cycle;
        begin
            cycles = 0;
            while (!fpu_result_valid && (cycles < 80)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!fpu_result_valid)
                fail("timed out waiting for backpressured FPU result");
            if ((result_id != expected_id) ||
                (result_slot != expected_slot) ||
                (fpu_result_fp != expected_data))
                fail("backpressured FPU result identity or data was wrong");
            held_result_tag = fpu_result_tag;
            held_result_data = fpu_result_fp;
            held_result_flags = fpu_result_flags;
            held_result_unsupported = fpu_result_unsupported;
            for (hold_cycle = 0; hold_cycle < 3;
                 hold_cycle = hold_cycle + 1) begin
                tick();
                result_stall_cycles = result_stall_cycles + 1;
                if (!fpu_result_valid ||
                    (fpu_result_tag !== held_result_tag) ||
                    (fpu_result_fp !== held_result_data) ||
                    (fpu_result_flags !== held_result_flags) ||
                    (fpu_result_unsupported !== held_result_unsupported))
                    fail("FPU result changed under output backpressure");
            end
            extension_completion_sink_ready = 1'b0;
            fpu_result_sink_ready = 1'b1;
            cycles = 0;
            while (!extension_completion_valid && (cycles < 20)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!extension_completion_valid ||
                (extension_completion_id != expected_id) ||
                (extension_completion_slot != expected_slot))
                fail("FPU scoreboard did not expose exact completion identity");
            repeat (2) begin
                tick();
                if (!extension_completion_valid ||
                    (extension_completion_id != expected_id) ||
                    (extension_completion_slot != expected_slot))
                    fail("FPU completion identity changed under backpressure");
            end
            extension_completion_sink_ready = 1'b1;
            cycles = 0;
            while (!parent_complete[expected_slot] && (cycles < 20)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!parent_complete[expected_slot] ||
                (parent_id[expected_slot] != expected_id))
                fail("released FPU result did not complete parent identity");
        end
    endtask

    task automatic retire_load;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [4:0] rd;
        input [63:0] expected_data;
        integer cycles;
        begin
            cycles = 0;
            while (!parent_complete[slot] && (cycles < 20)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!parent_complete[slot])
                fail("FP load completion identity did not reach retirement");
            retire_valid = 3'b001;
            retire_id[0 +: IDW] = id;
            retire_slot[0 +: SW] = slot;
            #1;
            if (!retire_ready[0] || !retire_load_data_valid[0] ||
                !retire_result_valid[0] || !retire_fpr_write ||
                (retire_fpr_addr != rd) ||
                (retire_fpr_data != expected_data) ||
                retire_unsupported[0])
                fail("FP load was not ready for exact ordered retirement");
            tick();
            retire_valid = 3'b000;
            #1;
            if (u_fpr.regs[rd] !== expected_data)
                fail("retired FP load did not update architectural FPR");
        end
    endtask

    task automatic retire_compute;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [4:0] rd;
        input [63:0] expected_data;
        begin
            if (!parent_complete[slot] || (parent_id[slot] != id))
                fail("expected compute completion identity was absent");
            retire_valid = 3'b001;
            retire_id[0 +: IDW] = id;
            retire_slot[0 +: SW] = slot;
            #1;
            if (!retire_ready[0] || !retire_result_valid[0] ||
                !retire_fpr_write || (retire_fpr_addr != rd) ||
                (retire_fpr_data != expected_data) ||
                retire_unsupported[0])
                fail("compute result was not selected for ordered FPR write");
            tick();
            retire_valid = 3'b000;
            #1;
            if (u_fpr.regs[rd] !== expected_data)
                fail("retired compute did not update architectural FPR");
        end
    endtask

    task automatic issue_store;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        input [63:0] expected_data;
        integer cycles;
        begin
            cycles = 0;
            while (!entry_operand_ready[slot] && (cycles < 20)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!entry_operand_ready[slot])
                fail("timed out waiting for FP store operand");
            fp_mem_issue_valid = 1'b1;
            fp_mem_issue_is_load = 1'b0;
            fp_mem_issue_id = id;
            fp_mem_issue_slot = slot;
            #1;
            if (!fp_mem_issue_ready ||
                (fp_mem_store_data != expected_data))
                fail("FP store did not present exact FPR operand to LSU");
            tick();
            fp_mem_issue_valid = 1'b0;
            #1;
            if (!window_issued[slot])
                fail("parent window did not record FP store issue");
            fp_mem_complete_valid = 1'b1;
            fp_mem_complete_id = id;
            fp_mem_complete_slot = slot;
            tick();
            fp_mem_complete_valid = 1'b0;
            cycles = 0;
            while (!parent_complete[slot] && (cycles < 20)) begin
                tick();
                cycles = cycles + 1;
            end
            if (!parent_complete[slot])
                fail("FP store completion identity did not reach retirement");
        end
    endtask

    task automatic retire_no_write;
        input [IDW-1:0] id;
        input [SW-1:0] slot;
        begin
            retire_valid = 3'b001;
            retire_id[0 +: IDW] = id;
            retire_slot[0 +: SW] = slot;
            #1;
            if (!parent_complete[slot] || !retire_ready[0] ||
                !retire_result_valid[0] || retire_fpr_write ||
                retire_gpr_write[0])
                fail("non-writing FP uop attempted architectural FPR write");
            tick();
            retire_valid = 3'b000;
        end
    endtask

    integer wait_cycles;
    integer branch_squash_base;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        squash_id = {IDW{1'b0}};
        window_src1_data = {WINDOW_DEPTH*64{1'b0}};
        window_src2_data = {WINDOW_DEPTH*64{1'b0}};
        next_retire_slot = SW'(0);
        fpu_result_sink_ready = 1'b1;
        extension_completion_sink_ready = 1'b1;
        poisoned_branch_mask = {BRW{1'b0}};
        result_stall_cycles = 0;
        init_fpr_write = 1'b0;
        init_fpr_addr = 5'd0;
        init_fpr_data = 64'd0;
        clear_all_inputs();

        repeat (4) tick();
        rst_n = 1'b1;
        tick();

        initialize_fpr(5'd10, 64'h4000_0000_0000_0000); // alpha=2.0

        // One DAXPY-shaped dependency chain plus a next-iteration load.
        allocate_one(IDW'(10), SW'(0), make_fp_load(5'd1), 1'b1, 1'b0);
        allocate_one(IDW'(11), SW'(1), make_fp_load(5'd2), 1'b1, 1'b0);
        allocate_one(IDW'(12), SW'(2),
            make_fp_compute(`OPENRV64_FP_OP_MADD, 5'd10, 5'd1,
                            5'd2, 5'd4, 1'b1, 4'b0000),
            1'b1, 1'b1);
        allocate_one(IDW'(13), SW'(3), make_fp_load(5'd8), 1'b1, 1'b0);

        if (entry_operand_ready[2])
            fail("FMADD became ready before either FP load retired");

        issue_load(IDW'(10), SW'(0));
        issue_load(IDW'(11), SW'(1));
        issue_load(IDW'(13), SW'(3));

        return_load(IDW'(10), SW'(0), 64'h3ff0_0000_0000_0000);
        if (entry_operand_ready[2])
            fail("FMADD woke after only one exact load result arrived");
        fpu_result_sink_ready = 1'b0;
        return_load(IDW'(11), SW'(1), 64'h3fe0_0000_0000_0000);
        if (!entry_operand_ready[2])
            fail("FMADD did not wake from both exact tagged load results");
        expect_fpu_issue(IDW'(12), SW'(2), 4'b0000);
        return_load(IDW'(13), SW'(3), 64'hc008_0000_0000_0000);
        allocate_one(IDW'(14), SW'(4), make_fp_store(5'd4),
                     1'b1, 1'b1);
        if (entry_operand_ready[4])
            fail("FP store captured unretired FMADD result");

        accept_stalled_result(IDW'(12), SW'(2),
                              64'h4004_0000_0000_0000);
        if (!entry_operand_ready[4])
            fail("FP store did not wake from exact tagged FMADD result");
        issue_store(IDW'(14), SW'(4), 64'h4004_0000_0000_0000);

        retire_load(IDW'(10), SW'(0), 5'd1,
                    64'h3ff0_0000_0000_0000);
        next_retire_slot = SW'(1);
        retire_load(IDW'(11), SW'(1), 5'd2,
                    64'h3fe0_0000_0000_0000);
        next_retire_slot = SW'(2);
        retire_compute(IDW'(12), SW'(2), 5'd4,
                       64'h4004_0000_0000_0000);
        next_retire_slot = SW'(3);
        retire_load(IDW'(13), SW'(3), 5'd8,
                    64'hc008_0000_0000_0000);
        next_retire_slot = SW'(4);
        retire_no_write(IDW'(14), SW'(4));
        next_retire_slot = SW'(5);

        if ((u_fpr.regs[4] !== 64'h4004_0000_0000_0000) ||
            (u_fpr.regs[8] !== 64'hc008_0000_0000_0000) ||
            (architectural_fflags != 5'd0) ||
            (result_stall_cycles != 3))
            fail("DAXPY-shaped chain final architectural state was wrong");

        // Branch recovery: two divides enter the FPU around branch ID 21.
        // ID 20 is older and must finish. ID 22 is younger, tagged with branch
        // bit zero, and must be discarded after redirect. Slot 2 is reused by
        // correct-path ID 23 before the killed divide returns.
        next_retire_slot = SW'(0);
        allocate_one(IDW'(20), SW'(0),
            make_fp_compute(`OPENRV64_FP_OP_DIV, 5'd10, 5'd1,
                            5'd0, 5'd5, 1'b0, 4'b0000),
            1'b1, 1'b1);
        expect_fpu_issue(IDW'(20), SW'(0), 4'b0000);
        allocate_one(IDW'(22), SW'(2),
            make_fp_compute(`OPENRV64_FP_OP_DIV, 5'd10, 5'd2,
                            5'd0, 5'd6, 1'b0, 4'b0001),
            1'b1, 1'b1);
        expect_fpu_issue(IDW'(22), SW'(2), 4'b0001);

        branch_squash_base = squashed_result_count;
        poisoned_branch_mask = 4'b0001;
        squash_id = IDW'(21);
        squash = 1'b1;
        tick();
        squash = 1'b0;
        if (entry_fp_valid[2] || fp_write_busy[6])
            fail("selective redirect retained younger FP ownership");
        if (!entry_fp_valid[0])
            fail("selective redirect removed older in-flight FP operation");

        allocate_one(IDW'(23), SW'(2),
            make_fp_compute(`OPENRV64_FP_OP_ADD, 5'd1, 5'd1,
                            5'd0, 5'd6, 1'b0, 4'b0000),
            1'b1, 1'b1);
        expect_fpu_issue(IDW'(23), SW'(2), 4'b0000);

        wait_cycles = 0;
        while ((!parent_complete[0] ||
                (parent_id[0] != IDW'(20)) ||
                !parent_complete[2] ||
                (parent_id[2] != IDW'(23)) ||
                (squashed_result_count == branch_squash_base)) &&
               (wait_cycles < 120)) begin
            tick();
            wait_cycles = wait_cycles + 1;
        end
        if (wait_cycles >= 120)
            fail("timed out draining live and selectively killed FPU results");
        if (late_result_count != 0)
            fail("killed FPU result escaped branch-mask filtering");

        retire_compute(IDW'(20), SW'(0), 5'd5,
                       64'h4000_0000_0000_0000);
        next_retire_slot = SW'(2);
        retire_compute(IDW'(23), SW'(2), 5'd6,
                       64'h4000_0000_0000_0000);

        if ((u_fpr.regs[5] !== 64'h4000_0000_0000_0000) ||
            (u_fpr.regs[6] !== 64'h4000_0000_0000_0000) ||
            (squashed_result_count != (branch_squash_base + 1)) ||
            (architectural_fflags != 5'd0) ||
            (live_result_count != 3) || (late_result_count != 0))
            fail("selective branch recovery architectural state was wrong");

        $display("FD UOP SUMMARY live_results=%0d squashed_results=%0d late_results=%0d stalled_result_cycles=%0d f4=%016x f5=%016x f6=%016x",
            live_result_count, squashed_result_count, late_result_count,
            result_stall_cycles, u_fpr.regs[4], u_fpr.regs[5],
            u_fpr.regs[6]);
        $display("PASS: decoded-uop F/D harness: tagged result bypass, unified LSU completion, FPU backpressure, and selective redirect");
        $finish;
    end

    initial begin
        #20000;
        fail("decoded-uop F/D harness timed out");
    end

endmodule
