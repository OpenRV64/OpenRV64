`timescale 1ns/1ps
`include "core/exec/vec/defs.v"

// Private vector load/store engine with a tagged, exclusive memory stream.
// The stream is intentionally one small layer above AXI: it keeps the vector
// unit independent of AXI ID allocation and, unlike AXI RRESP/BRESP, has an
// explicit retry response.  A future adapter can map requests to an exclusive
// AXI master without changing vector register or replay behavior.
//
// One DATAPATH_WIDTH beat may launch every cycle. QUEUE_DEPTH commands and
// all their register-group load results remain inside this unit until the
// matching retirement event.  A retry clears only the affected beat's sent
// bit; dispatch never has to resend the vector instruction.
module openrv64_exec_vec_lsu #(
    parameter integer VLEN = 256,
    parameter integer DATAPATH_WIDTH = 64,
    parameter integer ADDR_WIDTH = 64,
    parameter integer REG_ADDR_WIDTH = 5,
    parameter integer TAG_WIDTH = 8,
    parameter integer MEM_TAG_WIDTH = 8,
    // The vector register file remains sliced at DATAPATH_WIDTH. A wider
    // cache-side port packs/unpacks several slices per tagged request.
    parameter integer MEM_DATA_WIDTH = DATAPATH_WIDTH,
    parameter integer QUEUE_DEPTH = 4,
    // The secondary LSU is a load pipe. Store dispatch remains well-defined
    // but completes as unsupported when this parameter is set.
    parameter integer READ_ONLY = 0,
    parameter integer NUM_REGS = 32,
    parameter integer MAX_LMUL = 8,
    parameter integer LMUL_WIDTH = 2,
    parameter integer SLICE_ADDR_WIDTH =
        ((VLEN / DATAPATH_WIDTH) <= 1) ? 1 :
        $clog2(VLEN / DATAPATH_WIDTH)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         dispatch_valid_i,
    output wire                         dispatch_ready_o,
    input  wire [TAG_WIDTH-1:0]         dispatch_tag_i,
    input  wire [`OPENRV64_VEC_LSU_OP_WIDTH-1:0] dispatch_op_i,
    input  wire [REG_ADDR_WIDTH-1:0]    dispatch_base_gpr_i,
    input  wire [REG_ADDR_WIDTH-1:0]    dispatch_vreg_i,
    input  wire [`OPENRV64_VEC_VTYPE_WIDTH-1:0] dispatch_vtype_i,

    // Scalar pointer sideband. The LSU owns and retries this read after
    // dispatch, so a GPR-port conflict never requires redispatch.
    output wire                         gpr_read_valid_o,
    input  wire                         gpr_read_ready_i,
    output wire [REG_ADDR_WIDTH-1:0]    gpr_read_addr_o,
    input  wire [ADDR_WIDTH-1:0]        gpr_read_data_i,

    output wire                         rf_read_valid_o,
    input  wire                         rf_read_ready_i,
    output wire [REG_ADDR_WIDTH-1:0]    rf_read_addr_o,
    output wire [SLICE_ADDR_WIDTH-1:0]  rf_read_slice_o,
    input  wire [DATAPATH_WIDTH-1:0]    rf_read_data_i,
    input  wire                         operands_ready_i,

    // Stores become externally visible only after their tag is the ordered
    // retirement head.  Loads may issue speculatively and remain private.
    input  wire                         ordered_valid_i,
    input  wire [TAG_WIDTH-1:0]         ordered_tag_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [TAG_WIDTH-1:0]         complete_tag_o,
    output wire                         complete_fault_o,
    output wire [ADDR_WIDTH-1:0]        complete_fault_addr_o,
    output wire                         complete_unsupported_o,

    input  wire                         retire_valid_i,
    output wire                         retire_ready_o,
    input  wire [TAG_WIDTH-1:0]         retire_tag_i,
    input  wire                         retire_kill_i,

    output wire                         rf_write_valid_o,
    input  wire                         rf_write_ready_i,
    output wire [REG_ADDR_WIDTH-1:0]    rf_write_addr_o,
    output wire [SLICE_ADDR_WIDTH-1:0]  rf_write_slice_o,
    output wire [DATAPATH_WIDTH-1:0]    rf_write_data_o,

    output wire                         mem_req_valid_o,
    input  wire                         mem_req_ready_i,
    output wire [MEM_TAG_WIDTH-1:0]     mem_req_tag_o,
    output wire                         mem_req_write_o,
    output wire [ADDR_WIDTH-1:0]        mem_req_addr_o,
    output wire [MEM_DATA_WIDTH-1:0]    mem_req_wdata_o,
    output wire [(MEM_DATA_WIDTH/8)-1:0] mem_req_wstrb_o,

    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [MEM_TAG_WIDTH-1:0]     mem_resp_tag_i,
    input  wire [MEM_DATA_WIDTH-1:0]    mem_resp_rdata_i,
    input  wire                         mem_resp_error_i,
    input  wire                         mem_resp_retry_i,

    output wire                         replay_o,
    output wire                         busy_o
);

    localparam integer MEM_BYTES = MEM_DATA_WIDTH / 8;
    localparam integer GROUP_WIDTH = VLEN * MAX_LMUL;
    localparam integer MAX_BEATS = GROUP_WIDTH / MEM_DATA_WIDTH;
    localparam integer BASE_SLICES = VLEN / DATAPATH_WIDTH;
    localparam integer MAX_SLICES = GROUP_WIDTH / DATAPATH_WIDTH;
    localparam integer RF_SLICES_PER_BEAT =
        MEM_DATA_WIDTH / DATAPATH_WIDTH;
    localparam integer SLICE_INDEX_WIDTH =
        (MAX_SLICES <= 1) ? 1 : $clog2(MAX_SLICES);
    localparam integer SLOT_INDEX_WIDTH =
        (QUEUE_DEPTH <= 1) ? 1 : $clog2(QUEUE_DEPTH);
    localparam integer BEAT_INDEX_WIDTH =
        (MAX_BEATS <= 1) ? 1 : $clog2(MAX_BEATS);
    localparam integer ADDR_ALIGN_BITS =
        (MEM_BYTES <= 1) ? 1 : $clog2(MEM_BYTES);

    function automatic [SLOT_INDEX_WIDTH-1:0] next_slot;
        input [SLOT_INDEX_WIDTH-1:0] slot;
        begin
            next_slot = (slot == QUEUE_DEPTH - 1) ?
                        {SLOT_INDEX_WIDTH{1'b0}} : slot + 1'b1;
        end
    endfunction

    reg pending_valid_q;
    reg [TAG_WIDTH-1:0] pending_tag_q;
    reg [`OPENRV64_VEC_LSU_OP_WIDTH-1:0] pending_op_q;
    reg [REG_ADDR_WIDTH-1:0] pending_base_gpr_q;
    reg [REG_ADDR_WIDTH-1:0] pending_vreg_q;
    reg [`OPENRV64_VEC_VTYPE_WIDTH-1:0] pending_vtype_q;

    reg slot_valid_q [0:QUEUE_DEPTH-1];
    reg slot_killed_q [0:QUEUE_DEPTH-1];
    reg slot_notified_q [0:QUEUE_DEPTH-1];
    reg slot_ordered_q [0:QUEUE_DEPTH-1];
    reg slot_fault_q [0:QUEUE_DEPTH-1];
    reg slot_unsupported_q [0:QUEUE_DEPTH-1];
    reg [TAG_WIDTH-1:0] slot_tag_q [0:QUEUE_DEPTH-1];
    reg [`OPENRV64_VEC_LSU_OP_WIDTH-1:0]
        slot_op_q [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] slot_addr_q [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] slot_fault_addr_q [0:QUEUE_DEPTH-1];
    reg [REG_ADDR_WIDTH-1:0] slot_vreg_q [0:QUEUE_DEPTH-1];
    reg [LMUL_WIDTH-1:0] slot_lmul_q [0:QUEUE_DEPTH-1];
    reg slot_gather_done_q [0:QUEUE_DEPTH-1];
    reg [SLICE_INDEX_WIDTH-1:0] slot_gather_index_q [0:QUEUE_DEPTH-1];
    reg [SLICE_INDEX_WIDTH-1:0] slot_write_index_q [0:QUEUE_DEPTH-1];
    reg [DATAPATH_WIDTH-1:0]
        slot_store_slice_q [0:QUEUE_DEPTH-1][0:MAX_SLICES-1];
    reg [DATAPATH_WIDTH-1:0]
        slot_load_slice_q [0:QUEUE_DEPTH-1][0:MAX_SLICES-1];
    reg [MAX_BEATS-1:0] slot_beat_sent_q [0:QUEUE_DEPTH-1];
    reg [MAX_BEATS-1:0] slot_beat_done_q [0:QUEUE_DEPTH-1];

    reg [SLOT_INDEX_WIDTH-1:0] allocate_tail_q;
    reg replay_pulse_q;

    wire pending_is_load = pending_op_q == `OPENRV64_VEC_LSU_LOAD;
    wire pending_is_store = pending_op_q == `OPENRV64_VEC_LSU_STORE;
    wire [2:0] pending_vlmul = pending_vtype_q[
        `OPENRV64_VEC_VTYPE_VLMUL_LSB +: 3];
    wire [LMUL_WIDTH-1:0] pending_lmul =
        pending_vlmul[LMUL_WIDTH-1:0];
    wire [REG_ADDR_WIDTH:0] pending_group_count =
        {{REG_ADDR_WIDTH{1'b0}}, 1'b1} << pending_lmul;
    wire [REG_ADDR_WIDTH:0] pending_group_mask =
        pending_group_count - 1'b1;
    wire pending_group_valid =
        (({1'b0, pending_vreg_q} & pending_group_mask) == 0) &&
        (({1'b0, pending_vreg_q} + pending_group_count) <= NUM_REGS);
    wire pending_vtype_valid =
        !pending_vtype_q[`OPENRV64_VEC_VTYPE_VILL_BIT] &&
        (pending_vtype_q[62:11] == 0) && !pending_vlmul[2];
    wire pending_unsupported =
        (!pending_is_load && !pending_is_store) ||
        ((READ_ONLY != 0) && pending_is_store) ||
        !pending_vtype_valid || !pending_group_valid;
    wire kill_pending = retire_valid_i && retire_kill_i &&
                        pending_valid_q &&
                        (retire_tag_i == pending_tag_q);
    wire allocate_available = !slot_valid_q[allocate_tail_q];
    assign gpr_read_valid_o = pending_valid_q && !kill_pending &&
                              operands_ready_i && allocate_available;
    assign gpr_read_addr_o = pending_base_gpr_q;
    wire gpr_read_fire = gpr_read_valid_o && gpr_read_ready_i;
    wire pending_misaligned =
        |gpr_read_data_i[ADDR_ALIGN_BITS-1:0];
    wire pending_promote = gpr_read_fire;

    // A promotion and a new dispatch may share an edge, giving the input a
    // one-command skid buffer without reducing steady-state request rate.
    assign dispatch_ready_o = !pending_valid_q || pending_promote;
    wire dispatch_fire = dispatch_valid_i && dispatch_ready_o;

    wire slot_all_done [0:QUEUE_DEPTH-1];
    genvar done_index;
    generate
        for (done_index = 0; done_index < QUEUE_DEPTH;
             done_index = done_index + 1) begin : g_done
            assign slot_all_done[done_index] =
                &slot_beat_done_q[done_index];
        end
    endgenerate

    // Store operands are gathered through one DATAPATH_WIDTH RF slice port.
    // The exclusive memory request uses that same width.
    reg gather_found;
    reg [SLOT_INDEX_WIDTH-1:0] gather_slot;
    integer gather_scan;
    always @* begin
        gather_found = 1'b0;
        gather_slot = {SLOT_INDEX_WIDTH{1'b0}};
        for (gather_scan = 0; gather_scan < QUEUE_DEPTH;
             gather_scan = gather_scan + 1) begin
            if (!gather_found && slot_valid_q[gather_scan] &&
                !slot_killed_q[gather_scan] &&
                !slot_fault_q[gather_scan] &&
                !slot_unsupported_q[gather_scan] &&
                (slot_op_q[gather_scan] == `OPENRV64_VEC_LSU_STORE) &&
                !slot_gather_done_q[gather_scan]) begin
                gather_found = 1'b1;
                gather_slot = gather_scan[SLOT_INDEX_WIDTH-1:0];
            end
        end
    end

    wire [SLICE_INDEX_WIDTH-1:0] gather_index =
        slot_gather_index_q[gather_slot];
    assign rf_read_valid_o = gather_found;
    assign rf_read_addr_o = slot_vreg_q[gather_slot] +
                            (gather_index / BASE_SLICES);
    assign rf_read_slice_o = gather_index % BASE_SLICES;
    wire rf_read_fire = rf_read_valid_o && rf_read_ready_i;
    wire [SLICE_INDEX_WIDTH:0] gather_slice_count =
        BASE_SLICES << slot_lmul_q[gather_slot];
    wire gather_last = gather_index == gather_slice_count - 1'b1;

    reg request_found;
    reg [SLOT_INDEX_WIDTH-1:0] request_slot;
    reg [BEAT_INDEX_WIDTH-1:0] request_beat;
    integer request_slot_scan;
    integer request_beat_scan;
    always @* begin
        request_found = 1'b0;
        request_slot = {SLOT_INDEX_WIDTH{1'b0}};
        request_beat = {BEAT_INDEX_WIDTH{1'b0}};
        for (request_slot_scan = 0; request_slot_scan < QUEUE_DEPTH;
             request_slot_scan = request_slot_scan + 1) begin
            for (request_beat_scan = 0; request_beat_scan < MAX_BEATS;
                 request_beat_scan = request_beat_scan + 1) begin
                if (!request_found && slot_valid_q[request_slot_scan] &&
                    !slot_killed_q[request_slot_scan] &&
                    !slot_fault_q[request_slot_scan] &&
                    !slot_unsupported_q[request_slot_scan] &&
                    !slot_beat_sent_q[request_slot_scan][request_beat_scan] &&
                    !slot_beat_done_q[request_slot_scan][request_beat_scan] &&
                    ((slot_op_q[request_slot_scan] ==
                      `OPENRV64_VEC_LSU_LOAD) ||
                     ((slot_op_q[request_slot_scan] ==
                       `OPENRV64_VEC_LSU_STORE) &&
                      slot_gather_done_q[request_slot_scan] &&
                      (slot_ordered_q[request_slot_scan] ||
                       (ordered_valid_i &&
                        (ordered_tag_i == slot_tag_q[request_slot_scan])))))) begin
                    request_found = 1'b1;
                    request_slot = request_slot_scan[SLOT_INDEX_WIDTH-1:0];
                    request_beat = request_beat_scan[BEAT_INDEX_WIDTH-1:0];
                end
            end
        end
    end

    wire [MEM_TAG_WIDTH-1:0] request_linear_tag =
        request_slot * MAX_BEATS + request_beat;
    assign mem_req_valid_o = request_found;
    assign mem_req_tag_o = request_linear_tag;
    assign mem_req_write_o = request_found &&
        (slot_op_q[request_slot] == `OPENRV64_VEC_LSU_STORE);
    assign mem_req_addr_o = slot_addr_q[request_slot] +
                            request_beat * MEM_BYTES;
    reg [MEM_DATA_WIDTH-1:0] request_wdata;
    reg [(MEM_DATA_WIDTH/8)-1:0] request_wstrb;
    integer request_strobe_scan;
    integer request_slice_scan;
    always @* begin
        request_wdata = {MEM_DATA_WIDTH{1'b0}};
        request_wstrb = {(MEM_DATA_WIDTH/8){1'b0}};
        for (request_slice_scan = 0;
             request_slice_scan < RF_SLICES_PER_BEAT;
             request_slice_scan = request_slice_scan + 1) begin
            request_wdata[request_slice_scan*DATAPATH_WIDTH +:
                          DATAPATH_WIDTH] = slot_store_slice_q[request_slot]
                [request_beat*RF_SLICES_PER_BEAT + request_slice_scan];
        end
        for (request_strobe_scan = 0;
             request_strobe_scan < (MEM_DATA_WIDTH/8);
             request_strobe_scan = request_strobe_scan + 1) begin
            if (((request_beat * MEM_BYTES) + request_strobe_scan) <
                ((VLEN / 8) << slot_lmul_q[request_slot]))
                request_wstrb[request_strobe_scan] = 1'b1;
        end
    end
    assign mem_req_wdata_o = request_wdata;
    assign mem_req_wstrb_o = mem_req_write_o ? request_wstrb :
                             {(MEM_DATA_WIDTH/8){1'b0}};
    wire mem_req_fire = mem_req_valid_o && mem_req_ready_i;

    assign mem_resp_ready_o = 1'b1;
    wire mem_resp_fire = mem_resp_valid_i && mem_resp_ready_o;
    wire response_tag_in_range =
        mem_resp_tag_i < (QUEUE_DEPTH * MAX_BEATS);
    wire [SLOT_INDEX_WIDTH-1:0] response_slot =
        mem_resp_tag_i / MAX_BEATS;
    wire [BEAT_INDEX_WIDTH-1:0] response_beat =
        mem_resp_tag_i % MAX_BEATS;
    wire response_expected = response_tag_in_range &&
        slot_valid_q[response_slot] &&
        slot_beat_sent_q[response_slot][response_beat] &&
        !slot_beat_done_q[response_slot][response_beat];

    reg complete_found;
    reg [SLOT_INDEX_WIDTH-1:0] complete_slot;
    integer complete_scan;
    always @* begin
        complete_found = 1'b0;
        complete_slot = {SLOT_INDEX_WIDTH{1'b0}};
        for (complete_scan = 0; complete_scan < QUEUE_DEPTH;
             complete_scan = complete_scan + 1) begin
            if (!complete_found && slot_valid_q[complete_scan] &&
                !slot_killed_q[complete_scan] &&
                !slot_notified_q[complete_scan] &&
                slot_all_done[complete_scan]) begin
                complete_found = 1'b1;
                complete_slot = complete_scan[SLOT_INDEX_WIDTH-1:0];
            end
        end
    end

    assign complete_valid_o = complete_found;
    assign complete_tag_o = slot_tag_q[complete_slot];
    assign complete_fault_o = complete_found &&
                              slot_fault_q[complete_slot];
    assign complete_fault_addr_o = slot_fault_addr_q[complete_slot];
    assign complete_unsupported_o = complete_found &&
                                    slot_unsupported_q[complete_slot];
    wire complete_fire = complete_valid_o && complete_ready_i;

    reg retire_slot_found;
    reg [SLOT_INDEX_WIDTH-1:0] retire_slot;
    integer retire_scan;
    always @* begin
        retire_slot_found = 1'b0;
        retire_slot = {SLOT_INDEX_WIDTH{1'b0}};
        for (retire_scan = 0; retire_scan < QUEUE_DEPTH;
             retire_scan = retire_scan + 1) begin
            if (!retire_slot_found && slot_valid_q[retire_scan] &&
                (slot_tag_q[retire_scan] == retire_tag_i)) begin
                retire_slot_found = 1'b1;
                retire_slot = retire_scan[SLOT_INDEX_WIDTH-1:0];
            end
        end
    end

    wire retire_kill_slot = retire_valid_i && retire_kill_i &&
                            retire_slot_found;
    wire retire_commit_slot = retire_valid_i && !retire_kill_i &&
        retire_slot_found && slot_notified_q[retire_slot] &&
        slot_all_done[retire_slot] && !slot_killed_q[retire_slot];
    wire retire_load_write = retire_commit_slot &&
        (slot_op_q[retire_slot] == `OPENRV64_VEC_LSU_LOAD) &&
        !slot_fault_q[retire_slot] && !slot_unsupported_q[retire_slot];

    wire [SLICE_INDEX_WIDTH-1:0] retire_write_index =
        slot_write_index_q[retire_slot];
    wire [SLICE_INDEX_WIDTH:0] retire_slice_count =
        BASE_SLICES << slot_lmul_q[retire_slot];
    assign rf_write_valid_o = retire_load_write;
    assign rf_write_addr_o = slot_vreg_q[retire_slot] +
                             (retire_write_index / BASE_SLICES);
    assign rf_write_slice_o = retire_write_index % BASE_SLICES;
    assign rf_write_data_o =
        slot_load_slice_q[retire_slot][retire_write_index];
    wire rf_write_fire = rf_write_valid_o && rf_write_ready_i;
    wire retire_write_last =
        retire_write_index == retire_slice_count - 1'b1;
    assign retire_ready_o = kill_pending || retire_kill_slot ||
        (retire_commit_slot &&
         (!retire_load_write || (rf_write_fire && retire_write_last)));
    wire retire_commit_fire = retire_commit_slot && retire_ready_o;

    reg any_slot_valid;
    integer busy_scan;
    always @* begin
        any_slot_valid = 1'b0;
        for (busy_scan = 0; busy_scan < QUEUE_DEPTH;
             busy_scan = busy_scan + 1)
            any_slot_valid = any_slot_valid || slot_valid_q[busy_scan];
    end
    assign busy_o = pending_valid_q || any_slot_valid;
    assign replay_o = replay_pulse_q ||
        (pending_valid_q &&
         (!operands_ready_i || !allocate_available ||
          (gpr_read_valid_o && !gpr_read_ready_i))) ||
        (gather_found && !rf_read_ready_i);

    integer slot_index;
    integer beat_index;
    integer slice_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid_q <= 1'b0;
            pending_tag_q <= {TAG_WIDTH{1'b0}};
            pending_op_q <= `OPENRV64_VEC_LSU_INVALID;
            pending_base_gpr_q <= {REG_ADDR_WIDTH{1'b0}};
            pending_vreg_q <= {REG_ADDR_WIDTH{1'b0}};
            pending_vtype_q <= {`OPENRV64_VEC_VTYPE_WIDTH{1'b0}};
            allocate_tail_q <= {SLOT_INDEX_WIDTH{1'b0}};
            replay_pulse_q <= 1'b0;
            for (slot_index = 0; slot_index < QUEUE_DEPTH;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_killed_q[slot_index] <= 1'b0;
                slot_notified_q[slot_index] <= 1'b0;
                slot_ordered_q[slot_index] <= 1'b0;
                slot_fault_q[slot_index] <= 1'b0;
                slot_unsupported_q[slot_index] <= 1'b0;
                slot_tag_q[slot_index] <= {TAG_WIDTH{1'b0}};
                slot_op_q[slot_index] <= `OPENRV64_VEC_LSU_INVALID;
                slot_addr_q[slot_index] <= {ADDR_WIDTH{1'b0}};
                slot_fault_addr_q[slot_index] <= {ADDR_WIDTH{1'b0}};
                slot_vreg_q[slot_index] <= {REG_ADDR_WIDTH{1'b0}};
                slot_lmul_q[slot_index] <= {LMUL_WIDTH{1'b0}};
                slot_gather_done_q[slot_index] <= 1'b0;
                slot_gather_index_q[slot_index] <=
                    {SLICE_INDEX_WIDTH{1'b0}};
                slot_write_index_q[slot_index] <=
                    {SLICE_INDEX_WIDTH{1'b0}};
                slot_beat_sent_q[slot_index] <= {MAX_BEATS{1'b0}};
                slot_beat_done_q[slot_index] <= {MAX_BEATS{1'b0}};
                for (slice_index = 0; slice_index < MAX_SLICES;
                     slice_index = slice_index + 1) begin
                    slot_store_slice_q[slot_index][slice_index] <=
                        {DATAPATH_WIDTH{1'b0}};
                    slot_load_slice_q[slot_index][slice_index] <=
                        {DATAPATH_WIDTH{1'b0}};
                end
            end
        end else begin
            replay_pulse_q <= 1'b0;

            if (pending_promote) begin
                slot_valid_q[allocate_tail_q] <= 1'b1;
                slot_killed_q[allocate_tail_q] <= 1'b0;
                slot_notified_q[allocate_tail_q] <= 1'b0;
                slot_ordered_q[allocate_tail_q] <=
                    pending_is_store && ordered_valid_i &&
                    (ordered_tag_i == pending_tag_q);
                slot_fault_q[allocate_tail_q] <= pending_misaligned;
                slot_unsupported_q[allocate_tail_q] <= pending_unsupported;
                slot_tag_q[allocate_tail_q] <= pending_tag_q;
                slot_op_q[allocate_tail_q] <= pending_op_q;
                slot_addr_q[allocate_tail_q] <= gpr_read_data_i;
                slot_fault_addr_q[allocate_tail_q] <= gpr_read_data_i;
                slot_vreg_q[allocate_tail_q] <= pending_vreg_q;
                slot_lmul_q[allocate_tail_q] <= pending_lmul;
                slot_gather_done_q[allocate_tail_q] <=
                    !pending_is_store || pending_misaligned ||
                    pending_unsupported;
                slot_gather_index_q[allocate_tail_q] <=
                    {SLICE_INDEX_WIDTH{1'b0}};
                slot_write_index_q[allocate_tail_q] <=
                    {SLICE_INDEX_WIDTH{1'b0}};
                for (beat_index = 0; beat_index < MAX_BEATS;
                     beat_index = beat_index + 1) begin
                    slot_beat_sent_q[allocate_tail_q][beat_index] <= 1'b0;
                    slot_beat_done_q[allocate_tail_q][beat_index] <=
                        pending_misaligned || pending_unsupported ||
                        (beat_index >=
                         (((VLEN << pending_lmul) + MEM_DATA_WIDTH - 1) /
                          MEM_DATA_WIDTH));
                end
                allocate_tail_q <= next_slot(allocate_tail_q);
                pending_valid_q <= 1'b0;
            end

            if (dispatch_fire) begin
                pending_valid_q <= 1'b1;
                pending_tag_q <= dispatch_tag_i;
                pending_op_q <= dispatch_op_i;
                pending_base_gpr_q <= dispatch_base_gpr_i;
                pending_vreg_q <= dispatch_vreg_i;
                pending_vtype_q <= dispatch_vtype_i;
            end
            if (kill_pending)
                pending_valid_q <= 1'b0;

            if (rf_read_fire) begin
                slot_store_slice_q[gather_slot][gather_index] <=
                    rf_read_data_i;
                if (gather_last) begin
                    slot_gather_done_q[gather_slot] <= 1'b1;
                end else begin
                    slot_gather_index_q[gather_slot] <=
                        gather_index + 1'b1;
                end
            end

            for (slot_index = 0; slot_index < QUEUE_DEPTH;
                 slot_index = slot_index + 1) begin
                if (slot_valid_q[slot_index] &&
                    (slot_op_q[slot_index] == `OPENRV64_VEC_LSU_STORE) &&
                    ordered_valid_i &&
                    (ordered_tag_i == slot_tag_q[slot_index]))
                    slot_ordered_q[slot_index] <= 1'b1;

                if (slot_valid_q[slot_index] &&
                    slot_killed_q[slot_index] &&
                    slot_all_done[slot_index]) begin
                    slot_valid_q[slot_index] <= 1'b0;
                    slot_killed_q[slot_index] <= 1'b0;
                end
            end

            if (mem_req_fire)
                slot_beat_sent_q[request_slot][request_beat] <= 1'b1;

            if (mem_resp_fire && response_expected) begin
                if (mem_resp_retry_i) begin
                    if (slot_killed_q[response_slot]) begin
                        slot_beat_done_q[response_slot][response_beat] <= 1'b1;
                    end else begin
                        slot_beat_sent_q[response_slot][response_beat] <= 1'b0;
                        replay_pulse_q <= 1'b1;
                    end
                end else begin
                    slot_beat_done_q[response_slot][response_beat] <= 1'b1;
                    if (mem_resp_error_i) begin
                        slot_fault_q[response_slot] <= 1'b1;
                        slot_fault_addr_q[response_slot] <=
                            slot_addr_q[response_slot] +
                            response_beat * MEM_BYTES;
                        for (beat_index = 0; beat_index < MAX_BEATS;
                             beat_index = beat_index + 1) begin
                            if (!slot_beat_sent_q[response_slot][beat_index])
                                slot_beat_done_q[response_slot][beat_index] <=
                                    1'b1;
                        end
                    end else if (slot_op_q[response_slot] ==
                                 `OPENRV64_VEC_LSU_LOAD) begin
                        for (slice_index = 0;
                             slice_index < RF_SLICES_PER_BEAT;
                             slice_index = slice_index + 1) begin
                            slot_load_slice_q[response_slot]
                                [response_beat*RF_SLICES_PER_BEAT +
                                 slice_index] <= mem_resp_rdata_i[
                                    slice_index*DATAPATH_WIDTH +:
                                    DATAPATH_WIDTH];
                        end
                    end
                end
            end

            if (complete_fire)
                slot_notified_q[complete_slot] <= 1'b1;

            if (retire_kill_slot) begin
                slot_killed_q[retire_slot] <= 1'b1;
                slot_notified_q[retire_slot] <= 1'b1;
                for (beat_index = 0; beat_index < MAX_BEATS;
                     beat_index = beat_index + 1) begin
                    if (!slot_beat_sent_q[retire_slot][beat_index])
                        slot_beat_done_q[retire_slot][beat_index] <= 1'b1;
                end
            end

            if (rf_write_fire && !retire_write_last)
                slot_write_index_q[retire_slot] <=
                    retire_write_index + 1'b1;

            if (retire_commit_fire) begin
                slot_valid_q[retire_slot] <= 1'b0;
                slot_killed_q[retire_slot] <= 1'b0;
                slot_notified_q[retire_slot] <= 1'b0;
                slot_ordered_q[retire_slot] <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    integer tag_bits_required;
    initial begin
        tag_bits_required = (QUEUE_DEPTH * MAX_BEATS <= 1) ? 1 :
                            $clog2(QUEUE_DEPTH * MAX_BEATS);
        if ((MEM_DATA_WIDTH < 8) || ((MEM_DATA_WIDTH % 8) != 0))
            $fatal(1, "vector LSU memory width must be byte granular");
        if (DATAPATH_WIDTH != 64)
            $fatal(1, "initial vector LSU datapath must be 64 bits");
        if ((MEM_DATA_WIDTH < DATAPATH_WIDTH) ||
            ((MEM_DATA_WIDTH % DATAPATH_WIDTH) != 0))
            $fatal(1,
                "vector LSU cache width must contain whole RF slices");
        if ((MEM_BYTES & (MEM_BYTES - 1)) != 0)
            $fatal(1, "vector LSU memory width must be a power of two bytes");
        if ((GROUP_WIDTH < MEM_DATA_WIDTH) ||
            ((GROUP_WIDTH % MEM_DATA_WIDTH) != 0))
            $fatal(1,
                "maximum vector group must be a multiple of MEM_DATA_WIDTH");
        if (MEM_TAG_WIDTH < tag_bits_required)
            $fatal(1, "vector LSU memory tag is too narrow");
        if (QUEUE_DEPTH < 1)
            $fatal(1, "vector LSU queue must have at least one entry");
        if (MAX_LMUL != 8)
            $fatal(1, "initial vector LSU requires MAX_LMUL=8");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (mem_resp_fire && !response_expected)
                $fatal(1, "vector LSU received an unknown memory response tag");
            if (mem_resp_fire && mem_resp_retry_i && mem_resp_error_i)
                $fatal(1, "vector LSU response cannot be retry and error");
        end
    end
`endif

endmodule
