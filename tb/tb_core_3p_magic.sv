`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"

// Core-only performance harness.  The frontend and tagged LSU use independent
// ports on a compact 256-bit SRAM model.  Both ports accept every cycle and
// return the corresponding read/ack one cycle later.  No cache, translation,
// AXI fabric, CCX home, peripheral, or DRAM timing is modeled.
module tb_core_3p_magic #(
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_DEFAULT,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter integer ENABLE_FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer SRAM_BYTES = 64 * 1024
);
    localparam integer SRAM_WORDS = SRAM_BYTES / 32;
    localparam integer SRAM_INDEX_WIDTH = $clog2(SRAM_WORDS);
    localparam [63:0] SRAM_BASE = `OPENRV64_SOC_MEMORY_BASE;

    reg clk;
    reg rst_n;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] araddr;
    wire arvalid;
    wire arready;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] rid_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata_q;
    reg [1:0] rresp_q;
    reg rvalid_q;
    wire rready;

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;
    reg ccx_resp_valid_q;
    wire ccx_resp_ready;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata_q;
    reg ccx_resp_error_q;

    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;

    wire pair512_req_valid;
    wire pair512_req_ready = rst_n;
    wire [63:0] pair512_req_predicted_addr;
    wire [63:0] pair512_req_unpredicted_addr;
    reg pair512_resp_valid_q;
    reg [63:0] pair512_resp_predicted_addr_q;
    reg [255:0] pair512_resp_predicted_data_q;
    reg [63:0] pair512_resp_unpredicted_addr_q;
    reg [255:0] pair512_resp_unpredicted_data_q;
    wire pair1024_req_valid;
    wire pair1024_req_ready = rst_n;
    wire [63:0] pair1024_req_predicted_addr;
    wire [63:0] pair1024_req_unpredicted_addr;
    reg pair1024_resp_valid_q;
    reg [63:0] pair1024_resp_predicted_addr_q;
    reg [511:0] pair1024_resp_predicted_data_q;
    reg [63:0] pair1024_resp_unpredicted_addr_q;
    reg [511:0] pair1024_resp_unpredicted_data_q;

    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] sram_q [0:SRAM_WORDS-1];
    string memh_path;
    string underflow_trace_path;
    integer underflow_trace_fd;
    integer init_index;
    integer write_byte;
    integer cycles;
    integer max_cycles;
    integer retired;
    integer resolved_branches;
    integer resolved_conditional_branches;
    integer direction_corrections;
    integer target_corrections;
    integer btb_lookups;
    integer btb_hits;
    integer btb_misses;
    integer btb_wrong_targets;
    integer ras_lookups;
    integer ras_hits;
    integer ras_misses;
    integer ras_wrong_targets;
    integer lookaside_restart_hits;
    integer weak_branch_pairs;
    integer stashed_pair_halves_suppressed;
    integer fetch_requests;
    integer pair_fetch_requests;
    integer pair512_requests;
    integer pair1024_requests;
    integer frontend_empty_cycles;
    integer frontend_underflow_cycles;
    integer frontend_underflow_refill_wait;
    integer frontend_underflow_no_request;
    reg [63:0] expected_a0;
    reg expected_a0_valid;
    real ipc;

    wire ar_in_range = (araddr >= SRAM_BASE) &&
                       (araddr < (SRAM_BASE + SRAM_BYTES));
    wire [SRAM_INDEX_WIDTH-1:0] ar_index =
        araddr[SRAM_INDEX_WIDTH+4:5];
    wire ar_fire = arvalid && arready;
    assign arready = rst_n && (!rvalid_q || rready);

    wire ccx_in_range = (ccx_req_addr >= SRAM_BASE) &&
                        (ccx_req_addr < (SRAM_BASE + SRAM_BYTES));
    wire [SRAM_INDEX_WIDTH-1:0] ccx_index =
        ccx_req_addr[SRAM_INDEX_WIDTH+4:5];
    wire [1:0] ccx_lane = ccx_req_addr[4:3];
    wire [63:0] ccx_read_data =
        sram_q[ccx_index] >> {ccx_lane, 6'b000000};
    wire ccx_write = ccx_req_op == `OPENRV64_CCX_OP_WRITE;
    wire ccx_slot_ready =
        rst_n && (!ccx_resp_valid_q || ccx_resp_ready);
    assign ccx_req_ready = ccx_slot_ready;
    assign ccx_wdata_ready = ccx_slot_ready;
    wire ccx_fire = ccx_req_valid && ccx_req_ready;
    wire pair512_predicted_in_range =
        (pair512_req_predicted_addr >= SRAM_BASE) &&
        (pair512_req_predicted_addr < (SRAM_BASE + SRAM_BYTES));
    wire pair512_unpredicted_in_range =
        (pair512_req_unpredicted_addr >= SRAM_BASE) &&
        (pair512_req_unpredicted_addr < (SRAM_BASE + SRAM_BYTES));
    wire [SRAM_INDEX_WIDTH-1:0] pair512_predicted_index =
        pair512_req_predicted_addr[SRAM_INDEX_WIDTH+4:5];
    wire [SRAM_INDEX_WIDTH-1:0] pair512_unpredicted_index =
        pair512_req_unpredicted_addr[SRAM_INDEX_WIDTH+4:5];
    wire pair1024_predicted_in_range =
        (pair1024_req_predicted_addr >= SRAM_BASE) &&
        ((pair1024_req_predicted_addr + 64) <=
         (SRAM_BASE + SRAM_BYTES));
    wire pair1024_unpredicted_in_range =
        (pair1024_req_unpredicted_addr >= SRAM_BASE) &&
        ((pair1024_req_unpredicted_addr + 64) <=
         (SRAM_BASE + SRAM_BYTES));
    wire [SRAM_INDEX_WIDTH-1:0] pair1024_predicted_index =
        pair1024_req_predicted_addr[SRAM_INDEX_WIDTH+4:5];
    wire [SRAM_INDEX_WIDTH-1:0] pair1024_unpredicted_index =
        pair1024_req_unpredicted_addr[SRAM_INDEX_WIDTH+4:5];

    openrv64_rv64_top_3p #(
        .RESET_VECTOR(SRAM_BASE),
        .BUS_CONFIG(`OPENRV64_BUS_AXI),
        .ENABLE_RV64M(1'b1),
        .COMPLETION_FORWARD_MASK(COMPLETION_FORWARD_MASK),
        .BRANCH_COMPLETION_FORWARD_MASK(
            BRANCH_COMPLETION_FORWARD_MASK),
        .ENABLE_FULL_FORWARDING(ENABLE_FULL_FORWARDING),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .SPEC_LOAD_BASE(SRAM_BASE),
        .SPEC_LOAD_SIZE(SRAM_BYTES),
        .ENABLE_MAGIC_MEMORY(1'b1),
        .ENABLE_TRACE(1'b0),
        .ENABLE_FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
        .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
            FETCH_ALT_CONFIDENCE_GATE),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(1'b1),
        .BP_RAS_DEPTH(8),
        .BP_BIMODAL_ENTRIES(32),
        .BP_BIMODAL_COUNTER_BITS(3),
        .BP_BIMODAL_UPDATE_DEPTH(4),
        .BP_GSHARE_ENTRIES(256),
        .BP_GSHARE_COUNTER_BITS(3),
        .BP_BTB_ENTRIES(256),
        .BP_BTB_TAG_BITS(16),
        .BP_INFLIGHT_DEPTH(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_ready(1'b0),
        .mem_rdata(64'd0),
        .mem_error(1'b0),
        .pair512_req_valid(pair512_req_valid),
        .pair512_req_ready(pair512_req_ready),
        .pair512_req_predicted_addr(pair512_req_predicted_addr),
        .pair512_req_unpredicted_addr(pair512_req_unpredicted_addr),
        .pair512_resp_valid(pair512_resp_valid_q),
        .pair512_resp_predicted_addr(
            pair512_resp_predicted_addr_q),
        .pair512_resp_predicted_data(
            pair512_resp_predicted_data_q),
        .pair512_resp_unpredicted_addr(
            pair512_resp_unpredicted_addr_q),
        .pair512_resp_unpredicted_data(
            pair512_resp_unpredicted_data_q),
        .pair1024_req_valid(pair1024_req_valid),
        .pair1024_req_ready(pair1024_req_ready),
        .pair1024_req_predicted_addr(pair1024_req_predicted_addr),
        .pair1024_req_unpredicted_addr(pair1024_req_unpredicted_addr),
        .pair1024_resp_valid(pair1024_resp_valid_q),
        .pair1024_resp_predicted_addr(
            pair1024_resp_predicted_addr_q),
        .pair1024_resp_predicted_data(
            pair1024_resp_predicted_data_q),
        .pair1024_resp_unpredicted_addr(
            pair1024_resp_unpredicted_addr_q),
        .pair1024_resp_unpredicted_data(
            pair1024_resp_unpredicted_data_q),
        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rid(rid_q),
        .m_axi_rdata(rdata_q),
        .m_axi_rresp(rresp_q),
        .m_axi_rlast(1'b1),
        .m_axi_rvalid(rvalid_q),
        .m_axi_rready(rready),
        .m_axi_awready(1'b0),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .ccx_req_valid(ccx_req_valid),
        .ccx_req_ready(ccx_req_ready),
        .ccx_req_hart_id(ccx_req_hart_id),
        .ccx_req_txn_id(ccx_req_txn_id),
        .ccx_req_source_id(ccx_req_source_id),
        .ccx_req_op(ccx_req_op),
        .ccx_req_size(ccx_req_size),
        .ccx_req_addr(ccx_req_addr),
        .ccx_wdata_valid(ccx_wdata_valid),
        .ccx_wdata_ready(ccx_wdata_ready),
        .ccx_wdata_hart_id(ccx_wdata_hart_id),
        .ccx_wdata_txn_id(ccx_wdata_txn_id),
        .ccx_wdata_source_id(ccx_wdata_source_id),
        .ccx_wdata(ccx_wdata),
        .ccx_wstrb(ccx_wstrb),
        .ccx_resp_valid(ccx_resp_valid_q),
        .ccx_resp_ready(ccx_resp_ready),
        .ccx_resp_hart_id(ccx_resp_hart_id_q),
        .ccx_resp_txn_id(ccx_resp_txn_id_q),
        .ccx_resp_source_id(ccx_resp_source_id_q),
        .ccx_resp_beat_index(
            {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}),
        .ccx_resp_last(1'b1),
        .ccx_resp_rdata(ccx_resp_rdata_q),
        .ccx_resp_error(ccx_resp_error_q),
        .ccx_resp_sc_success(1'b0),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    always #5 clk = ~clk;

    initial begin
        for (init_index = 0; init_index < SRAM_WORDS;
             init_index = init_index + 1)
            sram_q[init_index] = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "tb_core_3p_magic requires +memh=<256-bit image>");
        $readmemh(memh_path, sram_q);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rid_q <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            rdata_q <= {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            rresp_q <= 2'b00;
            rvalid_q <= 1'b0;
        end else begin
            if (rvalid_q && rready)
                rvalid_q <= 1'b0;
            if (ar_fire) begin
                rid_q <= arid;
                rdata_q <= ar_in_range ?
                           sram_q[ar_index] :
                           {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
                rresp_q <= ar_in_range ? 2'b00 : 2'b10;
                rvalid_q <= 1'b1;
            end
        end
    end

    // Experimental two-address, one-cycle full-line model.  Each side reads
    // two adjacent 256-bit SRAM words and returns a complete 512-bit line.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair1024_resp_valid_q <= 1'b0;
            pair1024_resp_predicted_addr_q <= 64'd0;
            pair1024_resp_predicted_data_q <= 512'd0;
            pair1024_resp_unpredicted_addr_q <= 64'd0;
            pair1024_resp_unpredicted_data_q <= 512'd0;
        end else begin
            pair1024_resp_valid_q <= 1'b0;
            if (pair1024_req_valid && pair1024_req_ready) begin
                pair1024_resp_valid_q <= 1'b1;
                pair1024_resp_predicted_addr_q <=
                    pair1024_req_predicted_addr;
                pair1024_resp_predicted_data_q <=
                    pair1024_predicted_in_range ?
                    {sram_q[pair1024_predicted_index + 1'b1],
                     sram_q[pair1024_predicted_index]} : 512'd0;
                pair1024_resp_unpredicted_addr_q <=
                    pair1024_req_unpredicted_addr;
                pair1024_resp_unpredicted_data_q <=
                    pair1024_unpredicted_in_range ?
                    {sram_q[pair1024_unpredicted_index + 1'b1],
                     sram_q[pair1024_unpredicted_index]} : 512'd0;
            end
        end
    end

    // Experimental two-address, one-cycle L1I model.  A request samples two
    // independent 256-bit SRAM words and returns them together as 512 bits.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair512_resp_valid_q <= 1'b0;
            pair512_resp_predicted_addr_q <= 64'd0;
            pair512_resp_predicted_data_q <= 256'd0;
            pair512_resp_unpredicted_addr_q <= 64'd0;
            pair512_resp_unpredicted_data_q <= 256'd0;
        end else begin
            pair512_resp_valid_q <= 1'b0;
            if (pair512_req_valid && pair512_req_ready) begin
                pair512_resp_valid_q <= 1'b1;
                pair512_resp_predicted_addr_q <=
                    pair512_req_predicted_addr;
                pair512_resp_predicted_data_q <=
                    pair512_predicted_in_range ?
                    sram_q[pair512_predicted_index] : 256'd0;
                pair512_resp_unpredicted_addr_q <=
                    pair512_req_unpredicted_addr;
                pair512_resp_unpredicted_data_q <=
                    pair512_unpredicted_in_range ?
                    sram_q[pair512_unpredicted_index] : 256'd0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_resp_valid_q <= 1'b0;
            ccx_resp_hart_id_q <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            ccx_resp_txn_id_q <=
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            ccx_resp_source_id_q <=
                {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
            ccx_resp_rdata_q <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            ccx_resp_error_q <= 1'b0;
        end else begin
            if (ccx_resp_valid_q && ccx_resp_ready)
                ccx_resp_valid_q <= 1'b0;
            if (ccx_fire) begin
                ccx_resp_valid_q <= 1'b1;
                ccx_resp_hart_id_q <= ccx_req_hart_id;
                ccx_resp_txn_id_q <= ccx_req_txn_id;
                ccx_resp_source_id_q <= ccx_req_source_id;
                ccx_resp_rdata_q <= ccx_write ? 512'd0 :
                    {{(`OPENRV64_CCX_LINE_DATA_WIDTH-64){1'b0}},
                     ccx_read_data};
                ccx_resp_error_q <= !ccx_in_range;
                if (ccx_write && ccx_in_range) begin
                    if (!ccx_wdata_valid ||
                        (ccx_wdata_hart_id != ccx_req_hart_id) ||
                        (ccx_wdata_txn_id != ccx_req_txn_id) ||
                        (ccx_wdata_source_id != ccx_req_source_id))
                        $fatal(1, "magic SRAM write identity mismatch");
                    for (write_byte = 0; write_byte < 8;
                         write_byte = write_byte + 1) begin
                        if (ccx_wstrb[write_byte])
                            sram_q[ccx_index][
                                ccx_lane*64 + write_byte*8 +: 8] <=
                                ccx_wdata[write_byte*8 +: 8];
                    end
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        max_cycles = 250000;
        expected_a0 = 64'd0;
        expected_a0_valid = 1'b0;
        retired = 0;
        resolved_branches = 0;
        resolved_conditional_branches = 0;
        direction_corrections = 0;
        target_corrections = 0;
        btb_lookups = 0;
        btb_hits = 0;
        btb_misses = 0;
        btb_wrong_targets = 0;
        ras_lookups = 0;
        ras_hits = 0;
        ras_misses = 0;
        ras_wrong_targets = 0;
        lookaside_restart_hits = 0;
        weak_branch_pairs = 0;
        stashed_pair_halves_suppressed = 0;
        fetch_requests = 0;
        pair_fetch_requests = 0;
        pair512_requests = 0;
        pair1024_requests = 0;
        frontend_empty_cycles = 0;
        frontend_underflow_cycles = 0;
        frontend_underflow_refill_wait = 0;
        frontend_underflow_no_request = 0;
        underflow_trace_fd = 0;
        if ($value$plusargs("underflow_trace=%s",
                            underflow_trace_path)) begin
            underflow_trace_fd = $fopen(underflow_trace_path, "w");
            if (underflow_trace_fd == 0)
                $fatal(1, "cannot open underflow trace %s",
                       underflow_trace_path);
            $fwrite(underflow_trace_fd,
                "cycle,consume_pc,debug_pc,pending,fetch_count,req_valid,req_ready,req_addr,resp_valid,resp_addr,refill_wait,pair1024_resp,pair_predicted_addr,pair_unpredicted_addr,pair_match,alt_restart_hit\n");
        end
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 250000;
        if ($value$plusargs("expect_a0=%h", expected_a0))
            expected_a0_valid = 1'b1;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (cycles = 0; (cycles < max_cycles) && !dbg_halted;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            retired = retired +
                dut.backend_retire_count;
            if (dut.branch_resolved)
                resolved_branches = resolved_branches + 1;
            if (dut.branch_resolved && dut.branch_conditional)
                resolved_conditional_branches =
                    resolved_conditional_branches + 1;
            if (dut.backend_redirect)
                direction_corrections = direction_corrections + 1;
            if (dut.bp_target_mispredict)
                target_corrections = target_corrections + 1;
            if (dut.u_bp.diag_btb_lookup)
                btb_lookups = btb_lookups + 1;
            if (dut.u_bp.diag_btb_hit)
                btb_hits = btb_hits + 1;
            if (dut.u_bp.diag_btb_miss)
                btb_misses = btb_misses + 1;
            if (dut.u_bp.diag_btb_wrong_target)
                btb_wrong_targets = btb_wrong_targets + 1;
            if (dut.u_bp.diag_ras_lookup)
                ras_lookups = ras_lookups + 1;
            if (dut.u_bp.diag_ras_hit)
                ras_hits = ras_hits + 1;
            if (dut.u_bp.diag_ras_miss)
                ras_misses = ras_misses + 1;
            if (dut.u_bp.diag_ras_wrong_target)
                ras_wrong_targets = ras_wrong_targets + 1;
            if (dut.fetch_alt_restart_hit)
                lookaside_restart_hits =
                    lookaside_restart_hits + 1;
            if (dut.icache_prefetch_valid) begin
                weak_branch_pairs = weak_branch_pairs + 1;
                if (dut.g_fetch_axi.u_fetch.
                    branch_predicted_stashed_r)
                    stashed_pair_halves_suppressed =
                        stashed_pair_halves_suppressed + 1;
                if (dut.g_fetch_axi.u_fetch.
                    branch_unpredicted_stashed_r)
                    stashed_pair_halves_suppressed =
                        stashed_pair_halves_suppressed + 1;
            end
            if (dut.fetch_pipe_req_valid &&
                dut.fetch_pipe_req_ready) begin
                fetch_requests = fetch_requests + 1;
                if (dut.fetch_pipe_req_stash)
                    pair_fetch_requests = pair_fetch_requests + 1;
            end
            if (pair512_req_valid && pair512_req_ready)
                pair512_requests = pair512_requests + 1;
            if (pair1024_req_valid && pair1024_req_ready)
                pair1024_requests = pair1024_requests + 1;
            if (dut.fetch_decode_valid == 0)
                frontend_empty_cycles = frontend_empty_cycles + 1;
            if ((dut.fetch_decode_valid == 0) &&
                dut.backend_decode_ready[0] &&
                dut.frontend_decode_enable &&
                dut.g_fetch_axi.u_fetch.active_q &&
                !dut.fetch3_restart &&
                !dut.fetch3_invalidate &&
                !dut.g_fetch_axi.u_fetch.stall_i) begin
                frontend_underflow_cycles =
                    frontend_underflow_cycles + 1;
                if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                    (dut.g_fetch_axi.u_fetch.pending_valid_q ||
                     (dut.u_bus.g_magic.magic_fetch_count_q != 0)))
                    frontend_underflow_refill_wait =
                        frontend_underflow_refill_wait + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit)
                    frontend_underflow_no_request =
                        frontend_underflow_no_request + 1;
                if (underflow_trace_fd != 0)
                    $fwrite(underflow_trace_fd,
                        "%0d,%016h,%016h,%0d,%0d,%0d,%0d,%016h,%0d,%016h,%0d,%0d,%016h,%016h,%0d,%0d\n",
                        cycles,
                        dut.g_fetch_axi.u_fetch.consume_pc_q,
                        dbg_pc,
                        dut.g_fetch_axi.u_fetch.pending_valid_q,
                        dut.u_bus.g_magic.magic_fetch_count_q,
                        dut.fetch_pipe_req_valid,
                        dut.fetch_pipe_req_ready,
                        dut.fetch_pipe_req_addr,
                        dut.fetch_pipe_resp_valid,
                        dut.fetch_pipe_resp_addr,
                        dut.g_fetch_axi.u_fetch.pending_valid_q ||
                            (dut.u_bus.g_magic.magic_fetch_count_q != 0),
                        pair1024_resp_valid_q,
                        pair1024_resp_predicted_addr_q,
                        pair1024_resp_unpredicted_addr_q,
                        pair1024_resp_valid_q &&
                            ((pair1024_resp_predicted_addr_q[63:6] ==
                              dut.g_fetch_axi.u_fetch.consume_pc_q[63:6]) ||
                             (pair1024_resp_unpredicted_addr_q[63:6] ==
                              dut.g_fetch_axi.u_fetch.consume_pc_q[63:6])),
                        dut.fetch_alt_restart_hit);
            end
        end

        if (!dbg_halted) begin
            $display(
                "MAGIC_TIMEOUT fetch_req=%b/%b addr=%h fetch_resp=%b/%b count=%0d r=%b/%b lsu_req=%b/%b tag=%0d write=%b ccx=%b/%b resp=%b/%b tag_state=%b/%b sp=%h",
                dut.fetch_pipe_req_valid,
                dut.fetch_pipe_req_ready,
                dut.fetch_pipe_req_addr,
                dut.fetch_pipe_resp_valid,
                dut.fetch_pipe_resp_ready,
                dut.u_bus.g_magic.magic_fetch_count_q,
                rvalid_q, rready,
                dut.backend_mem_valid,
                dut.backend_mem_ready,
                dut.backend_mem_tag,
                dut.backend_mem_write,
                ccx_req_valid, ccx_req_ready,
                ccx_resp_valid_q, ccx_resp_ready,
                dut.u_bus.g_magic.magic_lsu_inflight_q[
                    dut.backend_mem_tag],
                dut.u_bus.g_magic.magic_lsu_cancelled_q[
                    dut.backend_mem_tag],
                dut.u_backend.u_gpr.regs[2]);
            $fatal(1, "magic core timeout pc=%h instr=%h", dbg_pc,
                   dbg_instr);
        end
        if (expected_a0_valid &&
            (dut.u_backend.u_gpr.regs[10] !=
             expected_a0))
            $fatal(1, "magic core a0=%h expected=%h",
                dut.u_backend.u_gpr.regs[10],
                expected_a0);
        ipc = (cycles != 0) ? $itor(retired) / $itor(cycles) : 0.0;
        $display(
            "PERF_MAGIC_CONFIG retire_depth=%0d issue_window=%0d speculation_window=%0d",
            RETIRE_DEPTH, ISSUE_WINDOW, SPECULATION_WINDOW);
        $display(
            "PERF_MAGIC mode=%0d confidence_gate=%0d bp=%0d cycles=%0d retired=%0d IPC=%0.4f a0=%016h branches=%0d conditional_branches=%0d direction_corrections=%0d target_corrections=%0d lookaside_restart_hits=%0d weak_branch_pairs=%0d stashed_pair_halves_suppressed=%0d fetch_requests=%0d pair_fetch_requests=%0d pair512_requests=%0d pair1024_requests=%0d",
            FETCH_ALT_LOOKASIDE, FETCH_ALT_CONFIDENCE_GATE, BP_TYPE,
            cycles, retired, ipc,
            dut.u_backend.u_gpr.regs[10],
            resolved_branches, resolved_conditional_branches,
            direction_corrections, target_corrections,
            lookaside_restart_hits, weak_branch_pairs,
            stashed_pair_halves_suppressed,
            fetch_requests, pair_fetch_requests, pair512_requests,
            pair1024_requests);
        $display(
            "PERF_MAGIC_BP_TARGET btb_lookups=%0d btb_hits=%0d btb_misses=%0d btb_wrong_targets=%0d ras_lookups=%0d ras_hits=%0d ras_misses=%0d ras_wrong_targets=%0d",
            btb_lookups, btb_hits, btb_misses, btb_wrong_targets,
            ras_lookups, ras_hits, ras_misses, ras_wrong_targets);
        $display(
            "PERF_MAGIC_FETCH_EMPTY empty_cycles=%0d underflow_cycles=%0d refill_wait=%0d no_request=%0d",
            frontend_empty_cycles, frontend_underflow_cycles,
            frontend_underflow_refill_wait,
            frontend_underflow_no_request);
        if (underflow_trace_fd != 0)
            $fclose(underflow_trace_fd);
        $display("PASS: core-only one-cycle fetch/LSU SRAM");
        $finish;
    end
endmodule
