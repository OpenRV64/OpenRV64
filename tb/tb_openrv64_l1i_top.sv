`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/isa/rv64-priv.v"

module tb_openrv64_l1i_top #(
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer WAYS = 4,
    parameter integer PREFETCH_SLOTS = 8
);

    localparam logic [63:0] IMAGE_BASE = 64'h0000_0000_8000_0000;
    localparam integer IMAGE_BYTES = 2048;
    localparam integer MEMORY_LINES = IMAGE_BYTES / 64;
    localparam integer EXCERPT_LENGTH = 128;

    logic clk;
    logic rst_n;

    logic fetch_req_valid;
    wire fetch_req_ready;
    logic fetch_req_cacheable;
    logic [63:0] fetch_req_vaddr;
    logic [63:0] fetch_req_paddr;
    wire fetch_resp_valid;
    logic fetch_resp_ready;
    wire [255:0] fetch_resp_data;
    wire fetch_resp_error;

    logic prefetch_valid;
    logic [63:0] prefetch_taken_vaddr;
    logic [63:0] prefetch_fallthrough_vaddr;
    logic [2:0] retire_age_valid;
    logic [191:0] retire_age_vaddr;
    logic prefetch_flush;

    wire xlate_req_valid;
    logic xlate_req_ready;
    wire [63:0] xlate_req_vaddr;
    wire [`RV64_PRIV_WIDTH-1:0] xlate_req_priv;
    wire [`RV64_SATP_MODE_WIDTH-1:0] xlate_req_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] xlate_req_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] xlate_req_root_ppn;
    wire xlate_req_sum;
    wire xlate_req_mxr;
    logic xlate_resp_valid;
    wire xlate_resp_ready;
    logic [63:0] xlate_resp_paddr;

    logic invalidate_valid;
    wire invalidate_ready;

    wire ccx_req_valid;
    logic ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    logic ccx_resp_valid;
    wire ccx_resp_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;

    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        memory [0:MEMORY_LINES-1];
    logic [95:0] excerpt [0:EXCERPT_LENGTH-1];
    string memory_file;

    logic ccx_pending_q;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_pending_hart_q;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_pending_source_q;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_pending_txn_q;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_pending_data_q;
    logic [MEMORY_LINES-1:0] filled_lines_q;
    integer ccx_fill_count_q;
    integer branch_hint_count_q;

    openrv64_l1i_top #(
        .CACHE_BYTES(CACHE_BYTES),
        .WAYS(WAYS),
        .PREFETCH_SLOTS(PREFETCH_SLOTS)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .fetch_req_valid_i(fetch_req_valid),
        .fetch_req_ready_o(fetch_req_ready),
        .fetch_req_cacheable_i(fetch_req_cacheable),
        .fetch_req_vaddr_i(fetch_req_vaddr),
        .fetch_req_paddr_i(fetch_req_paddr),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(fetch_resp_ready),
        .fetch_resp_data_o(fetch_resp_data),
        .fetch_resp_error_o(fetch_resp_error),
        .prefetch_valid_i(prefetch_valid),
        .prefetch_taken_vaddr_i(prefetch_taken_vaddr),
        .prefetch_fallthrough_vaddr_i(prefetch_fallthrough_vaddr),
        .current_priv_i(`RV64_PRIV_M),
        .current_vm_mode_i(`RV64_SATP_MODE_BARE),
        .current_asid_i(16'd0),
        .current_root_ppn_i(44'd0),
        .current_sum_i(1'b0),
        .current_mxr_i(1'b0),
        .retire_age_valid_i(retire_age_valid),
        .retire_age_vaddr_i(retire_age_vaddr),
        .prefetch_flush_i(prefetch_flush),
        .xlate_req_valid_o(xlate_req_valid),
        .xlate_req_ready_i(xlate_req_ready),
        .xlate_req_vaddr_o(xlate_req_vaddr),
        .xlate_req_priv_o(xlate_req_priv),
        .xlate_req_vm_mode_o(xlate_req_vm_mode),
        .xlate_req_asid_o(xlate_req_asid),
        .xlate_req_root_ppn_o(xlate_req_root_ppn),
        .xlate_req_sum_o(xlate_req_sum),
        .xlate_req_mxr_o(xlate_req_mxr),
        .xlate_resp_valid_i(xlate_resp_valid),
        .xlate_resp_ready_o(xlate_resp_ready),
        .xlate_resp_paddr_i(xlate_resp_paddr),
        .xlate_resp_fault_i(1'b0),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(1'b1),
        .invalidate_paddr_i(64'd0),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_order_o(ccx_req_order),
        .ccx_req_kind_o(ccx_req_kind),
        .ccx_req_attr_o(ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(ccx_req_burst_len),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_beat_index_i('0),
        .ccx_resp_last_i(1'b1),
        .ccx_resp_error_i(1'b0),
        .ccx_resp_sc_success_i(1'b0)
    );

    always #5 clk = ~clk;

    assign xlate_req_ready = !xlate_resp_valid;
    assign ccx_req_ready = !ccx_pending_q && !ccx_resp_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xlate_resp_valid <= 1'b0;
            xlate_resp_paddr <= 64'd0;
        end else begin
            if (xlate_resp_valid && xlate_resp_ready)
                xlate_resp_valid <= 1'b0;
            if (xlate_req_valid && xlate_req_ready) begin
                if (xlate_req_priv != `RV64_PRIV_M ||
                    xlate_req_vm_mode != `RV64_SATP_MODE_BARE ||
                    xlate_req_asid != 0 || xlate_req_root_ppn != 0 ||
                    xlate_req_sum || xlate_req_mxr)
                    $fatal(1, "unexpected CoreMark translation context");
                xlate_resp_valid <= 1'b1;
                xlate_resp_paddr <= xlate_req_vaddr;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_pending_q <= 1'b0;
            ccx_pending_hart_q <= '0;
            ccx_pending_source_q <= '0;
            ccx_pending_txn_q <= '0;
            ccx_pending_data_q <= '0;
            ccx_resp_valid <= 1'b0;
            ccx_resp_hart_id <= '0;
            ccx_resp_source_id <= '0;
            ccx_resp_txn_id <= '0;
            ccx_resp_rdata <= '0;
            filled_lines_q <= '0;
            ccx_fill_count_q <= 0;
        end else begin
            if (ccx_resp_valid && ccx_resp_ready)
                ccx_resp_valid <= 1'b0;

            if (ccx_pending_q && (!ccx_resp_valid || ccx_resp_ready)) begin
                ccx_pending_q <= 1'b0;
                ccx_resp_valid <= 1'b1;
                ccx_resp_hart_id <= ccx_pending_hart_q;
                ccx_resp_source_id <= ccx_pending_source_q;
                ccx_resp_txn_id <= ccx_pending_txn_q;
                ccx_resp_rdata <= ccx_pending_data_q;
            end

            if (ccx_req_valid && ccx_req_ready) begin
                if (ccx_req_hart_id != 0 ||
                    ccx_req_source_id != `OPENRV64_CCX_SOURCE_ICACHE ||
                    ccx_req_op != `OPENRV64_CCX_OP_READ ||
                    ccx_req_order != `OPENRV64_CCX_ORDER_NONE ||
                    ccx_req_kind != `OPENRV64_CCX_KIND_FETCH ||
                    ccx_req_size != 3'd6 || ccx_req_addr[5:0] != 0 ||
                    ccx_req_burst_len != 0 ||
                    (ccx_req_attr & (`OPENRV64_CCX_ATTR_CACHEABLE |
                                     `OPENRV64_CCX_ATTR_EXECUTABLE)) !=
                    (`OPENRV64_CCX_ATTR_CACHEABLE |
                     `OPENRV64_CCX_ATTR_EXECUTABLE))
                    $fatal(1, "L1I emitted a non-line CCX command");
                if (ccx_req_addr < IMAGE_BASE ||
                    ccx_req_addr >= IMAGE_BASE + IMAGE_BYTES)
                    $fatal(1, "L1I CCX address outside CoreMark image: %h",
                           ccx_req_addr);
                if (filled_lines_q[ccx_req_addr[10:6]])
                    $fatal(1, "duplicate CoreMark line refill: %h",
                           ccx_req_addr);
                ccx_pending_q <= 1'b1;
                ccx_pending_hart_q <= ccx_req_hart_id;
                ccx_pending_source_q <= ccx_req_source_id;
                ccx_pending_txn_q <= ccx_req_txn_id;
                ccx_pending_data_q <= memory[ccx_req_addr[10:6]];
                filled_lines_q[ccx_req_addr[10:6]] <= 1'b1;
                ccx_fill_count_q <= ccx_fill_count_q + 1;
            end
        end
    end

    function automatic [63:0] branch_target;
        input [63:0] pc;
        input [31:0] instruction;
        reg [63:0] immediate;
        begin
            immediate = {{51{instruction[31]}}, instruction[31],
                         instruction[7], instruction[30:25],
                         instruction[11:8], 1'b0};
            branch_target = pc + immediate;
        end
    endfunction

    task automatic issue_fetch;
        input [63:0] pc;
        input [31:0] expected_instruction;
        reg [255:0] expected_block;
        reg [31:0] returned_instruction;
        integer cycles;
        begin
            expected_block = pc[5] ? memory[pc[10:6]][511:256] :
                                     memory[pc[10:6]][255:0];
            @(negedge clk);
            while (!fetch_req_ready)
                @(negedge clk);
            fetch_req_valid = 1'b1;
            fetch_req_vaddr = pc;
            fetch_req_paddr = pc;
            @(posedge clk);
            @(negedge clk);
            fetch_req_valid = 1'b0;
            fetch_req_vaddr = 64'd0;
            fetch_req_paddr = 64'd0;

            cycles = 0;
            while (!fetch_resp_valid && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "CoreMark fetch timeout at pc=%h", pc);
            returned_instruction =
                fetch_resp_data[pc[4:2]*32 +: 32];
            if (fetch_resp_error || fetch_resp_data !== expected_block ||
                returned_instruction !== expected_instruction)
                $fatal(1,
                    "CoreMark fetch mismatch pc=%h got=%h expected=%h",
                    pc, returned_instruction, expected_instruction);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic pulse_prefetch_pair;
        input [63:0] taken_vaddr;
        input [63:0] fallthrough_vaddr;
        begin
            @(negedge clk);
            prefetch_valid = 1'b1;
            prefetch_taken_vaddr = taken_vaddr;
            prefetch_fallthrough_vaddr = fallthrough_vaddr;
            @(posedge clk);
            @(negedge clk);
            prefetch_valid = 1'b0;
            prefetch_taken_vaddr = 64'd0;
            prefetch_fallthrough_vaddr = 64'd0;
            branch_hint_count_q = branch_hint_count_q + 1;
        end
    endtask

    task automatic pulse_retire_age;
        input [63:0] losing_vaddr;
        begin
            @(negedge clk);
            retire_age_valid = 3'b001;
            retire_age_vaddr = {128'd0, losing_vaddr};
            @(posedge clk);
            @(negedge clk);
            retire_age_valid = 3'b000;
            retire_age_vaddr = 192'd0;
        end
    endtask

    task automatic replay_excerpt;
        integer index;
        reg [63:0] pc;
        reg [63:0] next_pc;
        reg [63:0] taken_pc;
        reg [63:0] fallthrough_pc;
        reg [63:0] losing_pc;
        reg [31:0] instruction;
        begin
            for (index = 0; index < EXCERPT_LENGTH; index = index + 1) begin
                pc = excerpt[index][95:32];
                instruction = excerpt[index][31:0];
                issue_fetch(pc, instruction);
                if ((instruction[6:0] == 7'b1100011) &&
                    (index + 1 < EXCERPT_LENGTH)) begin
                    next_pc = excerpt[index + 1][95:32];
                    taken_pc = branch_target(pc, instruction);
                    fallthrough_pc = pc + 64'd4;
                    if (next_pc == taken_pc)
                        losing_pc = fallthrough_pc;
                    else if (next_pc == fallthrough_pc)
                        losing_pc = taken_pc;
                    else
                        $fatal(1,
                            "CoreMark trace branch successor mismatch pc=%h next=%h",
                            pc, next_pc);
                    pulse_prefetch_pair(taken_pc, fallthrough_pc);
                    if (taken_pc[63:6] != fallthrough_pc[63:6])
                        pulse_retire_age(losing_pc);
                end
            end
        end
    endtask

    integer cold_fills;
    integer warm_start_fills;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        fetch_req_valid = 1'b0;
        fetch_req_cacheable = 1'b1;
        fetch_req_vaddr = 64'd0;
        fetch_req_paddr = 64'd0;
        fetch_resp_ready = 1'b1;
        prefetch_valid = 1'b0;
        prefetch_taken_vaddr = 64'd0;
        prefetch_fallthrough_vaddr = 64'd0;
        retire_age_valid = 3'b000;
        retire_age_vaddr = 192'd0;
        prefetch_flush = 1'b0;
        invalidate_valid = 1'b0;
        branch_hint_count_q = 0;

        if (!$value$plusargs("memh=%s", memory_file))
            memory_file = "sim/coremark-l1i-512.memh";
        $readmemh(memory_file, memory);
        $readmemh("tb/data/coremark_l1i_excerpt.memh", excerpt);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        replay_excerpt();
        repeat (300) @(posedge clk);
        cold_fills = ccx_fill_count_q;
        if (cold_fills == 0)
            $fatal(1, "CoreMark cold replay produced no L1I fills");

        warm_start_fills = ccx_fill_count_q;
        replay_excerpt();
        repeat (300) @(posedge clk);
        if (ccx_fill_count_q != warm_start_fills)
            $fatal(1,
                "warm CoreMark replay missed: before=%0d after=%0d",
                warm_start_fills, ccx_fill_count_q);

        $display(
            "PASS: L1I bytes=%0d ways=%0d prefetch_slots=%0d CoreMark excerpt_length=%0d replays=2 checked_instructions=%0d branch_pairs=%0d cold_line_fills=%0d warm_line_fills=0",
            CACHE_BYTES, WAYS, PREFETCH_SLOTS, EXCERPT_LENGTH,
            2 * EXCERPT_LENGTH, branch_hint_count_q, cold_fills);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "standalone L1I CoreMark test timeout");
    end

endmodule
