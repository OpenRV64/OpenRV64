`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_axi_bus #(
    parameter integer L1D_FILL_BUFFER_LINES = 8,
    parameter integer L1D_STORE_BUFFER_LINES = 8
);
    logic clk;
    logic rst_n;
    logic fetch_req_valid;
    wire fetch_req_ready;
    logic [63:0] fetch_req_addr;
    logic fetch_cancel;
    wire fetch_resp_valid;
    logic fetch_resp_ready;
    wire [63:0] fetch_resp_addr;
    wire [255:0] fetch_resp_data;
    wire fetch_resp_access_fault;
    wire fetch_resp_page_fault;

    logic lsu_valid;
    logic lsu_write;
    logic [63:0] lsu_addr;
    logic [63:0] lsu_wdata;
    logic [7:0] lsu_wstrb;
    logic [2:0] lsu_size;
    wire lsu_ready;
    wire [63:0] lsu_rdata;
    wire lsu_access_fault;
    wire lsu_page_fault;

    logic pipe_req_valid;
    logic pipe_req_lock;
    wire pipe_req_ready;
    logic [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_req_tag;
    logic pipe_req_write;
    logic [63:0] pipe_req_addr;
    logic [63:0] pipe_req_wdata;
    logic [7:0] pipe_req_wstrb;
    logic [2:0] pipe_req_size;
    logic [1:0] pipe_req_priv;
    logic [3:0] pipe_req_vm_mode;
    logic [43:0] pipe_req_root_ppn;
    logic pipe_cancel;
    wire pipe_resp_valid;
    logic pipe_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_resp_tag;
    wire [63:0] pipe_resp_rdata;
    wire pipe_resp_access_fault;
    wire pipe_resp_page_fault;

    wire pmp_valid;
    wire [63:0] pmp_addr;
    wire [1:0] pmp_priv;
    wire [2:0] pmp_size;
    wire pmp_write;
    wire pmp_exec;
    logic pmp_allow;

    wire [2:0] arid;
    wire [63:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    logic arready;
    logic [2:0] rid;
    logic [255:0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    wire rready;
    wire [2:0] awid;
    wire [63:0] awaddr;
    wire [2:0] awsize;
    wire awvalid;
    logic awready;
    wire [255:0] wdata;
    wire [31:0] wstrb;
    wire wlast;
    wire wvalid;
    logic wready;
    logic [2:0] bid;
    logic [1:0] bresp;
    logic bvalid;
    wire bready;

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [3:0] ccx_req_hart_id;
    wire [3:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [3:0] ccx_req_op;
    wire ccx_req_lock;
    wire [1:0] ccx_req_order;
    wire [1:0] ccx_req_kind;
    wire [3:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [3:0] ccx_wdata_hart_id;
    wire [3:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;
    logic ccx_resp_valid;
    wire ccx_resp_ready;
    logic [3:0] ccx_resp_hart_id;
    logic [3:0] ccx_resp_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    logic ccx_resp_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    logic ccx_resp_error;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_memory [0:63];
    logic ccx_cmd_pending;
    logic [3:0] ccx_cmd_hart_id;
    logic [3:0] ccx_cmd_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_cmd_source_id;
    logic [3:0] ccx_cmd_op;
    logic [2:0] ccx_cmd_size;
    logic [63:0] ccx_cmd_addr;
    logic ccx_data_pending;
    logic [3:0] ccx_data_hart_id;
    logic [3:0] ccx_data_txn_id;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_data_source_id;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_data;
    logic [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_data_strb;
    logic ccx_fail_enable;
    logic [63:0] ccx_fail_addr;
    logic ccx_allow_cmd;
    logic ccx_allow_wdata;
    integer ccx_reads;
    integer ccx_writes;
    integer ccx_locked_reads;
    integer ccx_locked_writes;
    integer ccx_byte;
    integer ccx_index;
    integer ccx_word_index;

    integer ar_count;
    integer wait_count;
    integer channel_wait;
    reg [63:0] locked_old_word;
    reg [2:0] seen_id [0:15];
    reg [63:0] seen_addr [0:15];

    openrv64_core_axi_bus #(
        .ENABLE_L1I(0),
        .L1D_FILL_BUFFER_LINES(L1D_FILL_BUFFER_LINES),
        .L1D_STORE_BUFFER_LINES(L1D_STORE_BUFFER_LINES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fetch_req_valid_i(fetch_req_valid),
        .fetch_req_ready_o(fetch_req_ready),
        .fetch_req_addr_i(fetch_req_addr),
        .fetch_req_stash_i(1'b0),
        .fetch_req_priv_i(`RV64_PRIV_M),
        .fetch_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .fetch_req_asid_i(16'd0), .fetch_req_root_ppn_i(44'd0),
        .fetch_req_sum_i(1'b0), .fetch_req_mxr_i(1'b0),
        .fetch_cancel_i(fetch_cancel),
        .fetch_cancel_stash_i(1'b1),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(fetch_resp_ready),
        .fetch_resp_addr_o(fetch_resp_addr),
        .fetch_resp_data_o(fetch_resp_data),
        .fetch_resp_access_fault_o(fetch_resp_access_fault),
        .fetch_resp_page_fault_o(fetch_resp_page_fault),
        .lsu_valid_i(lsu_valid), .lsu_lock_i(1'b0),
        .lsu_write_i(lsu_write),
        .lsu_addr_i(lsu_addr), .lsu_wdata_i(lsu_wdata),
        .lsu_wstrb_i(lsu_wstrb), .lsu_size_i(lsu_size),
        .lsu_priv_i(`RV64_PRIV_M),
        .lsu_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_asid_i(16'd0), .lsu_root_ppn_i(44'd0),
        .lsu_sum_i(1'b0), .lsu_mxr_i(1'b0),
        .lsu_ready_o(lsu_ready), .lsu_rdata_o(lsu_rdata),
        .lsu_access_fault_o(lsu_access_fault),
        .lsu_page_fault_o(lsu_page_fault), .tlbi_i(1'b0),
        .icache_invalidate_i(1'b0),
        .icache_prefetch_valid_i(1'b0),
        .icache_prefetch_taken_addr_i(64'd0),
        .icache_prefetch_fallthrough_addr_i(64'd0),
        .icache_age_valid_i(3'b000),
        .icache_age_addr_i(192'd0),
        .lsu_pipe_req_valid_i(pipe_req_valid),
        .lsu_pipe_req_ready_o(pipe_req_ready),
        .lsu_pipe_req_tag_i(pipe_req_tag),
        .lsu_pipe_req_lock_i(pipe_req_lock),
        .lsu_pipe_req_write_i(pipe_req_write),
        .lsu_pipe_req_addr_i(pipe_req_addr),
        .lsu_pipe_req_wdata_i(pipe_req_wdata),
        .lsu_pipe_req_wstrb_i(pipe_req_wstrb),
        .lsu_pipe_req_size_i(pipe_req_size),
        .lsu_pipe_req_priv_i(pipe_req_priv),
        .lsu_pipe_req_vm_mode_i(pipe_req_vm_mode),
        .lsu_pipe_req_asid_i(16'd0),
        .lsu_pipe_req_root_ppn_i(pipe_req_root_ppn),
        .lsu_pipe_req_sum_i(1'b0), .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_cancel_i(pipe_cancel),
        .lsu_pipe_resp_valid_o(pipe_resp_valid),
        .lsu_pipe_resp_ready_i(pipe_resp_ready),
        .lsu_pipe_resp_tag_o(pipe_resp_tag),
        .lsu_pipe_resp_rdata_o(pipe_resp_rdata),
        .lsu_pipe_resp_access_fault_o(pipe_resp_access_fault),
        .lsu_pipe_resp_page_fault_o(pipe_resp_page_fault),
        .pmp_valid_o(pmp_valid), .pmp_addr_o(pmp_addr),
        .pmp_priv_o(pmp_priv), .pmp_size_o(pmp_size),
        .pmp_write_o(pmp_write), .pmp_exec_o(pmp_exec),
        .pmp_allow_i(pmp_allow),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_lock_o(ccx_req_lock),
        .ccx_req_order_o(ccx_req_order),
        .ccx_req_kind_o(ccx_req_kind),
        .ccx_req_attr_o(ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(ccx_req_burst_len),
        .ccx_wdata_valid_o(ccx_wdata_valid),
        .ccx_wdata_ready_i(ccx_wdata_ready),
        .ccx_wdata_hart_id_o(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(ccx_wdata_beat_index),
        .ccx_wdata_last_o(ccx_wdata_last),
        .ccx_wdata_o(ccx_wdata),
        .ccx_wstrb_o(ccx_wstrb),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_beat_index_i(ccx_resp_beat_index),
        .ccx_resp_last_i(ccx_resp_last),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_error_i(ccx_resp_error),
        .ccx_resp_sc_success_i(1'b0),
        .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
        .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
        .m_axi_arburst_o(arburst), .m_axi_arlock_o(),
        .m_axi_arcache_o(), .m_axi_arprot_o(), .m_axi_arqos_o(),
        .m_axi_arvalid_o(arvalid), .m_axi_arready_i(arready),
        .m_axi_rid_i(rid), .m_axi_rdata_i(rdata),
        .m_axi_rresp_i(rresp), .m_axi_rlast_i(rlast),
        .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready),
        .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr),
        .m_axi_awlen_o(), .m_axi_awsize_o(awsize),
        .m_axi_awburst_o(), .m_axi_awlock_o(), .m_axi_awcache_o(),
        .m_axi_awprot_o(), .m_axi_awqos_o(),
        .m_axi_awvalid_o(awvalid), .m_axi_awready_i(awready),
        .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb),
        .m_axi_wlast_o(wlast), .m_axi_wvalid_o(wvalid),
        .m_axi_wready_i(wready), .m_axi_bid_i(bid),
        .m_axi_bresp_i(bresp), .m_axi_bvalid_i(bvalid),
        .m_axi_bready_o(bready)
    );

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n && arvalid && arready) begin
            seen_id[ar_count] <= arid;
            seen_addr[ar_count] <= araddr;
            ar_count <= ar_count + 1;
        end
    end

    assign ccx_req_ready = rst_n && ccx_allow_cmd &&
                           !ccx_cmd_pending && !ccx_resp_valid;
    assign ccx_wdata_ready = rst_n && ccx_allow_wdata &&
                              !ccx_data_pending && !ccx_resp_valid;

    function automatic [63:0] ccx_memory_word(input [63:0] addr);
        ccx_memory_word = ccx_memory[addr[11:6]][addr[5:3]*64 +: 64];
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_cmd_pending <= 1'b0;
            ccx_cmd_hart_id <= 4'd0;
            ccx_cmd_txn_id <= 4'd0;
            ccx_cmd_source_id <= 0;
            ccx_cmd_op <= 0;
            ccx_cmd_size <= 0;
            ccx_cmd_addr <= 0;
            ccx_data_pending <= 1'b0;
            ccx_data_hart_id <= 0;
            ccx_data_txn_id <= 0;
            ccx_data_source_id <= 0;
            ccx_data <= 0;
            ccx_data_strb <= 0;
            ccx_resp_valid <= 1'b0;
            ccx_resp_hart_id <= 4'd0;
            ccx_resp_txn_id <= 4'd0;
            ccx_resp_source_id <= 0;
            ccx_resp_beat_index <= 0;
            ccx_resp_last <= 1'b0;
            ccx_resp_rdata <= 0;
            ccx_resp_error <= 1'b0;
            ccx_reads <= 0;
            ccx_writes <= 0;
            ccx_locked_reads <= 0;
            ccx_locked_writes <= 0;
        end else begin
            if (ccx_resp_valid && ccx_resp_ready)
                ccx_resp_valid <= 1'b0;

            if (ccx_req_valid && ccx_req_ready) begin
                if (ccx_req_hart_id != 0 ||
                    ccx_req_source_id != `OPENRV64_CCX_SOURCE_DCACHE ||
                    ccx_req_order != `OPENRV64_CCX_ORDER_NONE ||
                    ccx_req_kind != `OPENRV64_CCX_KIND_DATA ||
                    ccx_req_burst_len != 0)
                    $fatal(1, "L1D emitted malformed CCX command");
                if ((ccx_req_attr == `OPENRV64_CCX_ATTR_CACHEABLE) &&
                    (ccx_req_op == `OPENRV64_CCX_OP_READ) &&
                    !ccx_req_lock &&
                    ((ccx_req_size != 3'd6) || (ccx_req_addr[5:0] != 0)))
                    $fatal(1, "L1D miss was not one aligned line read");
                if ((ccx_req_attr == `OPENRV64_CCX_ATTR_CACHEABLE) &&
                    (ccx_req_op == `OPENRV64_CCX_OP_WRITE) &&
                    !ccx_req_lock &&
                    ((ccx_req_size != 3'd6) || (ccx_req_addr[5:0] != 0)))
                    $fatal(1,
                           "posted L1D store was not one aligned masked line write");
                ccx_cmd_pending <= 1'b1;
                ccx_cmd_hart_id <= ccx_req_hart_id;
                ccx_cmd_txn_id <= ccx_req_txn_id;
                ccx_cmd_source_id <= ccx_req_source_id;
                ccx_cmd_op <= ccx_req_op;
                ccx_cmd_size <= ccx_req_size;
                ccx_cmd_addr <= ccx_req_addr;
                if (ccx_req_lock &&
                    (ccx_req_op == `OPENRV64_CCX_OP_READ)) begin
                    if ((ccx_req_addr != 64'h108) ||
                        (ccx_req_size != 3'd3))
                        $fatal(1,
                               "locked L1D read lost sub-line geometry addr=%h size=%0d",
                               ccx_req_addr, ccx_req_size);
                    ccx_locked_reads <= ccx_locked_reads + 1;
                end
                if (ccx_req_lock &&
                    (ccx_req_op == `OPENRV64_CCX_OP_WRITE))
                    ccx_locked_writes <= ccx_locked_writes + 1;
            end

            if (ccx_wdata_valid && ccx_wdata_ready) begin
                if (ccx_wdata_beat_index != 0 || !ccx_wdata_last)
                    $fatal(1, "L1D emitted malformed write-data beat");
                ccx_data_pending <= 1'b1;
                ccx_data_hart_id <= ccx_wdata_hart_id;
                ccx_data_txn_id <= ccx_wdata_txn_id;
                ccx_data_source_id <= ccx_wdata_source_id;
                ccx_data <= ccx_wdata;
                ccx_data_strb <= ccx_wstrb;
            end

            if (ccx_cmd_pending && !ccx_resp_valid &&
                ((ccx_cmd_op == `OPENRV64_CCX_OP_READ) ||
                 ((ccx_cmd_op == `OPENRV64_CCX_OP_WRITE) &&
                  ccx_data_pending))) begin
                if ((ccx_cmd_op == `OPENRV64_CCX_OP_WRITE) &&
                    ((ccx_data_hart_id != ccx_cmd_hart_id) ||
                     (ccx_data_txn_id != ccx_cmd_txn_id) ||
                     (ccx_data_source_id != ccx_cmd_source_id)))
                    $fatal(1, "CCX command/data identity mismatch");
                ccx_resp_valid <= 1'b1;
                ccx_resp_hart_id <= ccx_cmd_hart_id;
                ccx_resp_txn_id <= ccx_cmd_txn_id;
                ccx_resp_source_id <= ccx_cmd_source_id;
                ccx_resp_beat_index <= 0;
                ccx_resp_last <= 1'b1;
                ccx_resp_rdata <= ccx_memory[ccx_cmd_addr[11:6]];
                ccx_resp_error <= ccx_fail_enable &&
                                  (ccx_cmd_addr == ccx_fail_addr);
                ccx_cmd_pending <= 1'b0;
                if (ccx_cmd_op == `OPENRV64_CCX_OP_READ) begin
                    ccx_reads <= ccx_reads + 1;
                end else begin
                    ccx_writes <= ccx_writes + 1;
                    ccx_data_pending <= 1'b0;
                    if (!(ccx_fail_enable &&
                          (ccx_cmd_addr == ccx_fail_addr))) begin
                        for (ccx_byte = 0; ccx_byte < 64;
                             ccx_byte = ccx_byte + 1) begin
                            if (ccx_data_strb[ccx_byte])
                                ccx_memory[ccx_cmd_addr[11:6]]
                                    [8*ccx_byte +: 8] <=
                                    ccx_data[8*ccx_byte +: 8];
                        end
                    end
                end
            end
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic push_fetch(input [63:0] addr);
        begin
            fetch_req_addr = addr;
            fetch_req_valid = 1'b1;
            while (!fetch_req_ready) tick();
            tick();
            fetch_req_valid = 1'b0;
        end
    endtask

    task automatic push_pipe_request(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input write,
        input [63:0] addr,
        input [63:0] write_data,
        input [7:0] write_strobe
    );
        integer wait_cycles;
        reg completed;
        begin
            pipe_req_tag = tag;
            pipe_req_write = write;
            pipe_req_addr = addr;
            pipe_req_wdata = write_data;
            pipe_req_wstrb = write_strobe;
            pipe_req_valid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 100) begin
                @(posedge clk);
                if (pipe_req_ready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "tagged LSU request timeout tag=%0d ready=%b pmp=%b ccx=%b/%b",
                    tag, pipe_req_ready, pmp_allow,
                    ccx_req_valid, ccx_req_ready);
            pipe_req_valid = 1'b0;
        end
    endtask

    task automatic send_pipe_read_response(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input [255:0] response_data,
        input [63:0] expected_data
    );
        begin
            rid = {`OPENRV64_AXI_ID_WIDTH{1'b1}};
            rdata = response_data;
            rresp = 2'b00;
            rlast = 1'b1;
            rvalid = 1'b1;
            #1;
            if (!rready || !pipe_resp_valid || pipe_resp_tag != tag ||
                pipe_resp_rdata != expected_data ||
                pipe_resp_access_fault || pipe_resp_page_fault)
                $fatal(1,
                    "tagged response mismatch tag=%0d got_tag=%0d data=%h ready=%b",
                    tag, pipe_resp_tag, pipe_resp_rdata, rready);
            tick();
            rvalid = 1'b0;
        end
    endtask

    task automatic expect_pipe_response(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input [63:0] expected_data,
        input expected_access_fault,
        input expected_page_fault
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!pipe_resp_valid && wait_cycles < 300) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!pipe_resp_valid)
                $fatal(1, "tagged L1D response timeout tag=%0d", tag);
            if (pipe_resp_tag != tag ||
                pipe_resp_rdata != expected_data ||
                pipe_resp_access_fault != expected_access_fault ||
                pipe_resp_page_fault != expected_page_fault)
                $fatal(1,
                    "tagged L1D response mismatch tag=%0d got=%0d data=%h expected=%h faults=%b/%b expected=%b/%b",
                    tag, pipe_resp_tag, pipe_resp_rdata, expected_data,
                    pipe_resp_access_fault, pipe_resp_page_fault,
                    expected_access_fault, expected_page_fault);
            tick();
        end
    endtask

    task automatic send_read_response(
        input [2:0] response_id,
        input [255:0] response_data,
        input [1:0] response_code
    );
        integer wait_cycles;
        reg completed;
        begin
            rid = response_id;
            rdata = response_data;
            rresp = response_code;
            rlast = 1'b1;
            rvalid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 30) begin
                @(posedge clk);
                if (rready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "R channel timeout id=%0d phys=%0d fetch_count=%0d",
                    response_id, dut.phys_state_q, dut.fetch_count_q);
            rvalid = 1'b0;
        end
    endtask

    task automatic expect_fetch(
        input [63:0] addr,
        input [255:0] data,
        input access_fault
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!fetch_resp_valid && wait_cycles < 30) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "fetch response timeout count=%0d head=%0d",
                    dut.fetch_count_q, dut.fetch_head_q);
            if (fetch_resp_addr != addr || fetch_resp_data != data ||
                fetch_resp_access_fault != access_fault ||
                fetch_resp_page_fault)
                $fatal(1, "fetch response mismatch addr=%h data=%h fault=%b",
                       fetch_resp_addr, fetch_resp_data,
                       fetch_resp_access_fault);
            tick();
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        fetch_req_valid = 0;
        fetch_req_addr = 0;
        fetch_cancel = 0;
        fetch_resp_ready = 1;
        lsu_valid = 0;
        lsu_write = 0;
        lsu_addr = 0;
        lsu_wdata = 0;
        lsu_wstrb = 0;
        lsu_size = 3;
        pipe_req_valid = 0;
        pipe_req_lock = 0;
        pipe_req_tag = 0;
        pipe_req_write = 0;
        pipe_req_addr = 0;
        pipe_req_wdata = 0;
        pipe_req_wstrb = 0;
        pipe_req_size = 3;
        pipe_req_priv = `RV64_PRIV_M;
        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_root_ppn = 0;
        pipe_cancel = 0;
        pipe_resp_ready = 1;
        pmp_allow = 1;
        arready = 1;
        rid = 0;
        rdata = 0;
        rresp = 0;
        rlast = 1;
        rvalid = 0;
        awready = 1;
        wready = 1;
        bid = 3'b111;
        bresp = 0;
        bvalid = 0;
        ccx_resp_valid = 0;
        ccx_resp_hart_id = 0;
        ccx_resp_txn_id = 0;
        ccx_resp_source_id = 0;
        ccx_resp_beat_index = 0;
        ccx_resp_last = 0;
        ccx_resp_rdata = 0;
        ccx_resp_error = 0;
        ccx_fail_enable = 0;
        ccx_fail_addr = 0;
        ccx_allow_cmd = 1;
        ccx_allow_wdata = 1;
        for (ccx_index = 0; ccx_index < 64;
             ccx_index = ccx_index + 1) begin
            for (ccx_word_index = 0; ccx_word_index < 8;
                 ccx_word_index = ccx_word_index + 1)
                ccx_memory[ccx_index][ccx_word_index*64 +: 64] =
                    64'h0101_0101_0101_0101 *
                    (ccx_index * 8 + ccx_word_index);
        end
        ar_count = 0;
        repeat (3) tick();
        rst_n = 1;
        tick();

        // Four fetches enter before any response.  AXI may return them out of
        // order, while the frontend must still observe request order.
        fetch_resp_ready = 0;
        push_fetch(64'h0000);
        push_fetch(64'h0020);
        push_fetch(64'h0040);
        push_fetch(64'h0060);
        send_read_response(3'd2, 256'h3333, 2'b00);
        send_read_response(3'd0, 256'h1111, 2'b00);
        send_read_response(3'd3, 256'h4444, 2'b00);
        send_read_response(3'd1, 256'h2222, 2'b00);
        fetch_resp_ready = 1;
        expect_fetch(64'h0, 256'h1111, 0);
        expect_fetch(64'h20, 256'h2222, 0);
        expect_fetch(64'h40, 256'h3333, 0);
        expect_fetch(64'h60, 256'h4444, 0);
        if (ar_count != 4)
            $fatal(1, "expected four sequential AR requests, got %0d", ar_count);
        if (seen_addr[0] != 64'h0 || seen_addr[1] != 64'h20 ||
            seen_addr[2] != 64'h40 || seen_addr[3] != 64'h60 ||
            seen_id[0] != 0 || seen_id[1] != 1 ||
            seen_id[2] != 2 || seen_id[3] != 3)
            $fatal(1, "fetch AR address/ID sequence mismatch");
        if (arlen != 0 || arburst != 2'b01)
            $fatal(1, "AXI read must be a one-beat INCR transaction");

        // PMP denial terminates locally and never launches AR.
        pmp_allow = 0;
        fetch_resp_ready = 0;
        push_fetch(64'h0080);
        repeat (2) tick();
        if (ar_count != 4 || !fetch_resp_valid ||
            !fetch_resp_access_fault || fetch_resp_addr != 64'h80)
            $fatal(1, "fetch PMP denial did not become a local fault");
        tick();
        fetch_resp_ready = 1;
        pmp_allow = 1;

        // A miss is one native 512-bit CCX line read.  A second word in that
        // line is a local hit; scalar data must not leak onto AXI.
        wait_count = ccx_reads;
        locked_old_word = ccx_memory_word(64'h100);
        push_pipe_request(2'd0, 1'b0, 64'h100, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        if ((ccx_reads - wait_count) != 1)
            $fatal(1, "L1D miss used %0d CCX reads instead of 1",
                   ccx_reads - wait_count);

        wait_count = ccx_reads;
        locked_old_word = ccx_memory_word(64'h108);
        push_pipe_request(2'd1, 1'b0, 64'h108, 64'd0, 8'd0);
        expect_pipe_response(2'd1, locked_old_word, 1'b0, 1'b0);
        if (ccx_reads != wait_count)
            $fatal(1, "L1D hit unexpectedly reached CCX");
        if (ar_count != 4 || awvalid || wvalid)
            $fatal(1, "scalar LSU traffic leaked onto AXI");

        // A bring-up AMO phase must bypass and invalidate a resident L1D
        // line while retaining cacheable PMA attributes at CCX.
        wait_count = ccx_reads;
        ccx_allow_cmd = 1'b0;
        pipe_req_lock = 1'b1;
        locked_old_word = ccx_memory_word(64'h108);
        push_pipe_request(2'd2, 1'b0, 64'h108, 64'd0, 8'd0);
        pipe_req_lock = 1'b0;
        while (!ccx_req_valid) tick();
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        if (!ccx_req_valid || !ccx_req_lock)
            $fatal(1, "redirect cancelled an irrevocable locked read");
        ccx_allow_cmd = 1'b1;
        expect_pipe_response(2'd2, locked_old_word, 1'b0, 1'b0);
        if ((ccx_reads - wait_count) != 1 || ccx_locked_reads != 1)
            $fatal(1, "locked L1D read hit or lost its CCX lock marker");

        wait_count = ccx_reads;
        locked_old_word = ccx_memory_word(64'h108);
        push_pipe_request(2'd0, 1'b0, 64'h108, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        if ((ccx_reads - wait_count) != 1)
            $fatal(1, "locked L1D access did not invalidate resident line");

        wait_count = ccx_writes;
        locked_old_word = ccx_memory_word(64'h118);
        pipe_req_lock = 1'b1;
        push_pipe_request(2'd2, 1'b1, 64'h118,
                          64'hcafe_babe_dead_beef, 8'hff);
        pipe_req_lock = 1'b0;
        expect_pipe_response(2'd2, locked_old_word, 1'b0, 1'b0);
        if ((ccx_writes - wait_count) != 1 || ccx_locked_writes != 1)
            $fatal(1, "locked L1D write lost its CCX lock marker");

        // A tagged store is irrevocable after L1 admission.  Architectural
        // completion reports that admission, not the later CCX drain result.
        // Deferred write faults therefore cannot be attributed to the posted
        // LSU tag and are intentionally not returned on this interface.
        pipe_resp_ready = 0;
        ccx_fail_enable = 1;
        ccx_fail_addr = 64'h100;
        ccx_allow_cmd = 0;
        ccx_allow_wdata = 1;
        wait_count = ccx_writes;
        push_pipe_request(2'd1, 1'b1, 64'h114,
            64'haabb_ccdd_0000_0000, 8'hf0);
        channel_wait = 0;
        while (!ccx_data_pending && channel_wait < 50) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!ccx_data_pending)
            $fatal(1, "CCX write data did not advance independently");
        if (!ccx_req_valid)
            $fatal(1, "CCX command was not held after write data accepted");
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        while (!pipe_resp_valid)
            tick();
        if (pipe_resp_tag != 2'd1 || pipe_resp_access_fault ||
            pipe_resp_page_fault)
            $fatal(1, "posted store admission response changed across cancel");
        pipe_resp_ready = 1;
        tick();
        ccx_allow_cmd = 1;
        while ((ccx_writes - wait_count) != 1)
            tick();
        if ((ccx_writes - wait_count) != 1 || awvalid || wvalid)
            $fatal(1, "L1D store did not use exactly one CCX write");
        ccx_fail_enable = 0;

        // Stores complete architecturally at bus admission, then queue as
        // aligned 64-byte records with byte enables.  A stalled CCX command
        // must not prevent independent younger stores from reaching L1D.
        ccx_memory[6'h0c] = 512'd0;
        wait_count = ccx_writes;
        ccx_allow_cmd = 0;
        ccx_allow_wdata = 1;
        push_pipe_request(2'd0, 1'b1, 64'h300,
                          64'h1122_3344_5566_7788, 8'h0f);
        expect_pipe_response(2'd0, 64'd0, 1'b0, 1'b0);
        push_pipe_request(2'd1, 1'b1, 64'h308,
                          64'haabb_ccdd_eeff_0011, 8'hf0);
        expect_pipe_response(2'd1, 64'd0, 1'b0, 1'b0);
        push_pipe_request(2'd2, 1'b1, 64'h310,
                          64'h0123_4567_89ab_cdef, 8'h81);
        expect_pipe_response(2'd2, 64'd0, 1'b0, 1'b0);
        push_pipe_request(3'd3, 1'b1, 64'h318,
                          64'h1020_3040_5060_7080, 8'hff);
        expect_pipe_response(3'd3, 64'd0, 1'b0, 1'b0);
        push_pipe_request(3'd4, 1'b1, 64'h320,
                          64'hfedc_ba98_7654_3210, 8'h33);
        expect_pipe_response(3'd4, 64'd0, 1'b0, 1'b0);
        push_pipe_request(3'd5, 1'b1, 64'h328,
                          64'h0f1e_2d3c_4b5a_6978, 8'hcc);
        expect_pipe_response(3'd5, 64'd0, 1'b0, 1'b0);
        push_pipe_request(3'd6, 1'b1, 64'h330,
                          64'h8877_6655_4433_2211, 8'h55);
        expect_pipe_response(3'd6, 64'd0, 1'b0, 1'b0);
        push_pipe_request(3'd7, 1'b1, 64'h338,
                          64'h99aa_bbcc_ddee_ff00, 8'haa);
        expect_pipe_response(3'd7, 64'd0, 1'b0, 1'b0);
        channel_wait = 0;
        while ((dut.u_l1d.store_buffer_count_q != 8) &&
               channel_wait < 150) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (dut.u_l1d.store_buffer_count_q != 8)
            $fatal(1, "L1D did not retain eight stalled stores data=%0d",
                   dut.u_l1d.store_buffer_count_q);
        ccx_allow_cmd = 1;
        while ((ccx_writes - wait_count) != 8)
            tick();
        if ((ccx_writes - wait_count) != 8 ||
            ccx_memory_word(64'h300) != 64'h0000_0000_5566_7788 ||
            ccx_memory_word(64'h308) != 64'haabb_ccdd_0000_0000 ||
            ccx_memory_word(64'h310) != 64'h0100_0000_0000_00ef ||
            ccx_memory_word(64'h318) != 64'h1020_3040_5060_7080 ||
            ccx_memory_word(64'h320) != 64'h0000_ba98_0000_3210 ||
            ccx_memory_word(64'h328) != 64'h0f1e_0000_4b5a_0000 ||
            ccx_memory_word(64'h330) != 64'h0077_0055_0033_0011 ||
            ccx_memory_word(64'h338) != 64'h9900_bb00_dd00_ff00)
            $fatal(1, "L1D byte-masked store buffer drain mismatch");

        // Translated tagged traffic falls back to the precise PTW path and
        // returns the page fault under the original request tag.  An invalid
        // root PTE is sufficient to exercise the fallback without a full map.
        pipe_req_vm_mode = `RV64_SATP_MODE_SV39;
        pipe_req_priv = `RV64_PRIV_S;
        pipe_resp_ready = 0;
        push_pipe_request(2'd2, 1'b0, 64'h1000, 64'd0, 8'd0);
        wait_count = 0;
        while (!(arvalid && arready && arid == 3'b111) &&
               wait_count < 50) begin
            tick();
            wait_count = wait_count + 1;
        end
        if (wait_count == 50)
            $fatal(1,
                "translated PTW AR timeout lsu=%0d miss=%b phys=%0d fallback=%b",
                dut.lsu_state_q, dut.miss_active_q, dut.phys_state_q,
                dut.pipe_fallback_active_q);
        tick();
        send_read_response(3'b111, 256'd0, 2'b00);
        wait_count = 0;
        while (!pipe_resp_valid && wait_count < 50) begin
            tick();
            wait_count = wait_count + 1;
        end
        if (wait_count == 50)
            $fatal(1,
                "translated response timeout lsu=%0d miss=%b phys=%0d fallback=%b",
                dut.lsu_state_q, dut.miss_active_q, dut.phys_state_q,
                dut.pipe_fallback_active_q);
        if (pipe_resp_tag != 2'd2 || !pipe_resp_page_fault ||
            pipe_resp_access_fault)
            $fatal(1, "translated tagged LSU fallback mismatch");
        pipe_resp_ready = 1;
        tick();
        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_priv = `RV64_PRIV_M;

        // The legacy scalar LSU frontend now terminates at L1D as well.  Its
        // load selects one 64-bit word from the returned 512-bit line.
        wait_count = ccx_reads;
        lsu_addr = 64'h248;
        lsu_write = 0;
        lsu_size = 3;
        lsu_valid = 1;
        while (!lsu_ready) tick();
        if (lsu_rdata != ccx_memory_word(64'h248) ||
            lsu_access_fault || lsu_page_fault)
            $fatal(1, "LSU read lane steering mismatch: %h", lsu_rdata);
        if ((ccx_reads - wait_count) != 1 || awvalid || wvalid)
            $fatal(1, "scalar LSU load did not use one native CCX line read");
        tick();
        lsu_valid = 0;
        tick();

        // A scalar store is lane-positioned on the independent 512-bit CCX
        // write-data channel and never reaches AXI.
        ccx_memory[64'h250 >> 6][(64'h250 >> 3 & 7)*64 +: 64] = 64'd0;
        wait_count = ccx_writes;
        ccx_allow_cmd = 1;
        ccx_allow_wdata = 0;
        lsu_addr = 64'h254;
        lsu_write = 1;
        lsu_size = 2;
        lsu_wdata = 64'haabb_ccdd_0000_0000;
        lsu_wstrb = 8'hf0;
        lsu_valid = 1;
        channel_wait = 0;
        while (!ccx_cmd_pending && channel_wait < 50) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!ccx_cmd_pending)
            $fatal(1, "CCX command did not advance independently");
        if (!ccx_wdata_valid)
            $fatal(1, "CCX write data was not held after command accepted");
        ccx_allow_wdata = 1;
        while (!lsu_ready) tick();
        if (lsu_access_fault || (ccx_writes - wait_count) != 1 ||
            ccx_memory_word(64'h250) != 64'haabb_ccdd_0000_0000 ||
            awvalid || wvalid)
            $fatal(1, "scalar CCX write lane steering mismatch");
        tick();
        lsu_valid = 0;

        $display("PASS: AXI fetch/PTW plus native 512-bit CCX L1D traffic");
        $finish;
    end
endmodule
