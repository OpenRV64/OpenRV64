`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

// Directed reproduction of the FPGA fetch sequence seen in the JTAG trace:
// an outstanding fall-through line is cancelled by a resolved redirect while
// the generic bus has its four-stage final-access pipeline enabled.  The new
// target is held at the fetch boundary while the cancelled response drains.
module tb_fetch_redirect_pipeline;

    localparam [63:0] OLD_PC = 64'hffff_ffff_8011_c360;
    localparam [63:0] TARGET_PC = 64'hffff_ffff_8011_c4f0;
    localparam [63:0] OLD_PA = 64'h0000_0000_8031_c360;
    localparam [63:0] TARGET_PA = 64'h0000_0000_8031_c4f0;
    localparam [63:0] OLD_LINE = 64'h01b1_3423_0541_3023;
    localparam [63:0] TARGET_LINE = 64'hf9df_f06f_fff0_0c93;
    localparam [43:0] ROOT_PPN = 44'h0000_080001;

    logic clk;
    logic ui_clk;
    logic rst_n;
    logic flush;
    logic redirect;
    logic pc_valid;
    logic [63:0] pc;

    wire pc_ready;
    wire fetch_mem_valid;
    wire fetch_mem_next_valid;
    wire [63:0] fetch_mem_addr;
    wire [63:0] fetch_mem_exec_addr;
    wire fetch_mem_ready;
    wire [63:0] fetch_mem_rdata;
    wire fetch_mem_access_fault;
    wire fetch_mem_page_fault;
    wire decode_valid;
    wire [63:0] decode_pc;
    wire [31:0] decode_instr;

    wire req_valid;
    wire req_ready;
    wire req_write;
    wire [63:0] req_addr;
    wire [63:0] req_wdata;
    wire [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;

    wire icx_req_valid;
    logic icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire icx_req_lock;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    wire icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    wire icx_resp_error;
    wire icx_resp_sc_success;

    openrv64_fetch #(
        .ENABLE_TRACE(0),
        .ENABLE_PREDECODE_TARGETS(0),
        .DECODE_WIDTH(1)
    ) u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .redirect_i(redirect),
        .redirect_replay_i(1'b0),
        .redirect_pc_i(TARGET_PC),
        .redirect_replay_o(),
        .pc_ready_o(pc_ready),
        .pc_valid_i(pc_valid),
        .pc_i(pc),
        .mem_valid_o(fetch_mem_valid),
        .mem_next_valid_o(fetch_mem_next_valid),
        .mem_ready_i(fetch_mem_ready),
        .mem_write_o(),
        .mem_addr_o(fetch_mem_addr),
        .mem_exec_addr_o(fetch_mem_exec_addr),
        .mem_wdata_o(),
        .mem_wstrb_o(),
        .mem_rdata_i(fetch_mem_rdata),
        .mem_fault_i(fetch_mem_access_fault),
        .mem_page_fault_i(fetch_mem_page_fault),
        .decode_valid_o(decode_valid),
        .decode_ready_i(1'b1),
        .decode_bus_o(),
        .decode_pc_o(decode_pc),
        .decode_instr_o(decode_instr),
        .decode_fault_o(),
        .decode_page_fault_o(),
        .trace_id_i(64'd0),
        .trace_id_o(),
        .decode_valid1_o(),
        .decode_ready1_i(1'b0),
        .decode_bus1_o(),
        .decode_pc1_o(),
        .decode_instr1_o(),
        .decode_fault1_o(),
        .decode_page_fault1_o(),
        .trace_id1_o()
    );

    openrv64_core_bus #(
        .PIPE_GEN_MEM_4_STAGE(1)
    ) u_bus (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_valid_i(fetch_mem_valid),
        .fetch_cancel_i(flush || redirect),
        .fetch_addr_i(fetch_mem_addr),
        .fetch_priv_i(`RV64_PRIV_S),
        .fetch_vm_mode_i(`RV64_SATP_MODE_SV39),
        .fetch_asid_i(16'd0),
        .fetch_root_ppn_i(ROOT_PPN),
        .fetch_sum_i(1'b0),
        .fetch_mxr_i(1'b0),
        .fetch_ready_o(fetch_mem_ready),
        .fetch_rdata_o(fetch_mem_rdata),
        .fetch_access_fault_o(fetch_mem_access_fault),
        .fetch_page_fault_o(fetch_mem_page_fault),
        .fetch_next_valid_i(fetch_mem_next_valid),
        .fetch_next_addr_i(pc),

        .fetch_pipe_req_valid_i(1'b0),
        .fetch_pipe_req_addr_i(64'd0),
        .fetch_pipe_req_stash_i(1'b0),
        .fetch_pipe_req_demand_i(1'b0),
        .fetch_pipe_req_priv_i(`RV64_PRIV_M),
        .fetch_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .fetch_pipe_req_asid_i(16'd0),
        .fetch_pipe_req_root_ppn_i(44'd0),
        .fetch_pipe_req_sum_i(1'b0),
        .fetch_pipe_req_mxr_i(1'b0),
        .fetch_pipe_resp_ready_i(1'b0),
        .fetch_pipe_cancel_stash_i(1'b1),

        .lsu_valid_i(1'b0),
        .lsu_lock_i(1'b0),
        .lsu_write_i(1'b0),
        .lsu_addr_i(64'd0),
        .lsu_wdata_i(64'd0),
        .lsu_wstrb_i(8'd0),
        .lsu_size_i(3'd3),
        .lsu_priv_i(`RV64_PRIV_M),
        .lsu_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_asid_i(16'd0),
        .lsu_root_ppn_i(44'd0),
        .lsu_sum_i(1'b0),
        .lsu_mxr_i(1'b0),

        .lsu_pipe_req_valid_i(1'b0),
        .lsu_pipe_req_tag_i('0),
        .lsu_pipe_req_xlate_only_i(1'b0),
        .lsu_pipe_req_physical_i(1'b0),
        .lsu_pipe_req_pmp_checked_i(1'b0),
        .lsu_pipe_req_lock_i(1'b0),
        .lsu_pipe_req_write_i(1'b0),
        .lsu_pipe_req_addr_i(64'd0),
        .lsu_pipe_req_wdata_i(64'd0),
        .lsu_pipe_req_wstrb_i(8'd0),
        .lsu_pipe_req_size_i(3'd0),
        .lsu_pipe_req_priv_i(`RV64_PRIV_M),
        .lsu_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_pipe_req_asid_i(16'd0),
        .lsu_pipe_req_root_ppn_i(44'd0),
        .lsu_pipe_req_sum_i(1'b0),
        .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_cancel_i(1'b0),
        .lsu_pipe_resp_ready_i(1'b0),
        .lsu_pipe_store_done_ready_i(1'b0),

        .lsu_xlate_req_valid_i(1'b0),
        .lsu_xlate_req_tag_i('0),
        .lsu_xlate_req_write_i(1'b0),
        .lsu_xlate_req_size_i(3'd0),
        .lsu_xlate_req_vaddr_i(64'd0),
        .lsu_xlate_req_priv_i(`RV64_PRIV_M),
        .lsu_xlate_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_xlate_req_asid_i(16'd0),
        .lsu_xlate_req_root_ppn_i(44'd0),
        .lsu_xlate_req_sum_i(1'b0),
        .lsu_xlate_req_mxr_i(1'b0),
        .lsu_xlate_resp_ready_i(1'b1),

        .tlbi_i(1'b0),
        .context_flush_i(1'b0),
        .fetch_context_change_i(1'b0),
        .page_screen_csr_clear_i(1'b0),
        .pmp_update_i(1'b0),
        .store_barrier_i(1'b0),
        .icache_invalidate_i(1'b0),
        .icache_prefetch_valid_i(1'b0),
        .icache_prefetch_taken_addr_i(64'd0),
        .icache_prefetch_fallthrough_addr_i(64'd0),
        .icache_age_valid_i(3'd0),
        .icache_age_addr_i(192'd0),
        .l1d_probe_valid_i(1'b0),
        .l1d_probe_addr_i(64'd0),
        .l1d_sleep_i(1'b0),

        .req_valid_o(req_valid),
        .req_ready_i(req_ready),
        .req_write_o(req_write),
        .req_addr_o(req_addr),
        .req_wdata_o(req_wdata),
        .req_wstrb_o(req_wstrb),
        .req_rdata_i(req_rdata),
        .req_error_i(req_error),
        .pmp_allow_i(1'b1),

        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(icx_req_lock),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_ready_i(1'b0),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(icx_resp_beat_index),
        .icx_resp_last_i(icx_resp_last),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error),
        .icx_resp_sc_success_i(icx_resp_sc_success),

        .m_axi_arready_i(1'b0),
        .m_axi_rid_i('0),
        .m_axi_rdata_i('0),
        .m_axi_rresp_i(2'd0),
        .m_axi_rlast_i(1'b0),
        .m_axi_rvalid_i(1'b0),
        .m_axi_awready_i(1'b0),
        .m_axi_wready_i(1'b0),
        .m_axi_bid_i('0),
        .m_axi_bresp_i(2'd0),
        .m_axi_bvalid_i(1'b0)
    );

    // Match the FPGA transport after the SoC decoder: scalar accesses have
    // already been rebased to DDR offset zero, while PTW ICX addresses remain
    // physical and are rebased by the arbiter.
    wire shared_mem_valid;
    wire shared_mem_ready;
    wire shared_mem_write;
    wire [63:0] shared_mem_addr;
    wire [63:0] shared_mem_wdata;
    wire [7:0] shared_mem_wstrb;
    wire [63:0] shared_mem_rdata;
    wire shared_mem_error;

    wire ui_req_valid;
    wire ui_req_ready;
    wire ui_req_write;
    wire [63:0] ui_req_addr;
    wire [63:0] ui_req_wdata;
    wire [7:0] ui_req_wstrb;
    wire ui_resp_valid;
    wire ui_resp_ready;
    wire [63:0] ui_resp_rdata;
    wire ui_resp_error;

    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    wire [255:0] app_wdf_data;
    wire app_wdf_end;
    wire [31:0] app_wdf_mask;
    wire app_wdf_wren;
    logic [255:0] app_rd_data;
    logic app_rd_data_end;
    logic app_rd_data_valid;

    openrv64_fpga_scalar_icx_arbiter #(
        .MEMORY_BASE(64'h0000_0000_8000_0000),
        .MEMORY_BYTES(64'h0000_0000_1000_0000)
    ) u_scalar_arbiter (
        .clk_i(clk),
        .reset_i(!rst_n),
        .core_mem_valid_i(req_valid),
        .core_mem_ready_o(req_ready),
        .core_mem_write_i(req_write),
        .core_mem_addr_i(req_addr - 64'h0000_0000_8000_0000),
        .core_mem_wdata_i(req_wdata),
        .core_mem_wstrb_i(req_wstrb),
        .core_mem_rdata_o(req_rdata),
        .core_mem_error_o(req_error),
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart_id),
        .icx_req_txn_id_i(icx_req_txn_id),
        .icx_req_source_id_i(icx_req_source_id),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_burst_len),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart_id),
        .icx_resp_txn_id_o(icx_resp_txn_id),
        .icx_resp_source_id_o(icx_resp_source_id),
        .icx_resp_beat_index_o(icx_resp_beat_index),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_rdata),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
        .mem_valid_o(shared_mem_valid),
        .mem_ready_i(shared_mem_ready),
        .mem_write_o(shared_mem_write),
        .mem_addr_o(shared_mem_addr),
        .mem_wdata_o(shared_mem_wdata),
        .mem_wstrb_o(shared_mem_wstrb),
        .mem_rdata_i(shared_mem_rdata),
        .mem_error_i(shared_mem_error)
    );

    openrv64_fpga_scalar_mem_cdc u_scalar_cdc (
        .core_clk_i(clk),
        .core_reset_i(!rst_n),
        .core_mem_valid_i(shared_mem_valid),
        .core_mem_ready_o(shared_mem_ready),
        .core_mem_write_i(shared_mem_write),
        .core_mem_addr_i(shared_mem_addr),
        .core_mem_wdata_i(shared_mem_wdata),
        .core_mem_wstrb_i(shared_mem_wstrb),
        .core_mem_rdata_o(shared_mem_rdata),
        .core_mem_error_o(shared_mem_error),
        .ui_clk_i(ui_clk),
        .ui_reset_i(!rst_n),
        .ui_req_valid_o(ui_req_valid),
        .ui_req_ready_i(ui_req_ready),
        .ui_req_write_o(ui_req_write),
        .ui_req_addr_o(ui_req_addr),
        .ui_req_wdata_o(ui_req_wdata),
        .ui_req_wstrb_o(ui_req_wstrb),
        .ui_resp_valid_i(ui_resp_valid),
        .ui_resp_ready_o(ui_resp_ready),
        .ui_resp_rdata_i(ui_resp_rdata),
        .ui_resp_error_i(ui_resp_error)
    );

    openrv64_fpga_mig_scalar_bridge #(
        .MEMORY_BYTES(64'h0000_0000_1000_0000),
        .CACHE_ENABLE(1),
        .CACHE_BYTES(1024)
    ) u_scalar_bridge (
        .clk_i(ui_clk),
        .reset_i(!rst_n),
        .calib_complete_i(1'b1),
        .req_valid_i(ui_req_valid),
        .req_ready_o(ui_req_ready),
        .req_write_i(ui_req_write),
        .req_addr_i(ui_req_addr),
        .req_wdata_i(ui_req_wdata),
        .req_wstrb_i(ui_req_wstrb),
        .resp_valid_o(ui_resp_valid),
        .resp_ready_i(ui_resp_ready),
        .resp_rdata_o(ui_resp_rdata),
        .resp_error_o(ui_resp_error),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(1'b1),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(1'b1),
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid),
        .debug_cache_index_i(10'd0),
        .debug_cache_req_toggle_i(1'b0),
        .debug_cache_ack_toggle_o(),
        .debug_cache_result_index_o(),
        .debug_cache_valid_o(),
        .debug_cache_tag_o(),
        .debug_cache_data_o()
    );

    logic hold_old_response;
    logic release_old_response;
    logic old_read_waiting;
    logic read_pending_q;
    logic [2:0] read_delay_q;
    logic [27:0] read_app_addr_q;

    function automatic [255:0] native_read_data(input [27:0] address);
        reg [63:0] byte_address;
        reg [255:0] line;
        begin
            byte_address = {34'd0, address, 2'b00};
            line = 256'd0;
            case (byte_address)
                64'h0000_0000_0000_1fe0:
                    line[191:128] = 64'h0000_0000_2000_0801;
                64'h0000_0000_0000_2000:
                    line[63:0] = 64'h0000_0000_2008_00cb;
                64'h0000_0000_0031_c360:
                    line[63:0] = OLD_LINE;
                64'h0000_0000_0031_c4e0: begin
                    line[191:128] = TARGET_LINE;
                    line[255:192] = 64'h0331_3423_fb01_0113;
                end
                default: line = 256'd0;
            endcase
            native_read_data = line;
        end
    endfunction

    always_ff @(posedge ui_clk) begin
        if (!rst_n) begin
            app_rd_data <= 256'd0;
            app_rd_data_end <= 1'b0;
            app_rd_data_valid <= 1'b0;
            old_read_waiting <= 1'b0;
            read_pending_q <= 1'b0;
            read_delay_q <= 3'd0;
            read_app_addr_q <= 28'd0;
        end else begin
            app_rd_data_end <= 1'b0;
            app_rd_data_valid <= 1'b0;

            if (app_en && (app_cmd == 3'b001)) begin
                read_pending_q <= 1'b1;
                read_delay_q <= 3'd2;
                read_app_addr_q <= app_addr;
                if (hold_old_response &&
                    ({34'd0, app_addr, 2'b00} ==
                     64'h0000_0000_0031_c360))
                    old_read_waiting <= 1'b1;
            end

            if (read_pending_q) begin
                if (old_read_waiting) begin
                    if (release_old_response) begin
                        app_rd_data <= native_read_data(read_app_addr_q);
                        app_rd_data_end <= 1'b1;
                        app_rd_data_valid <= 1'b1;
                        old_read_waiting <= 1'b0;
                        read_pending_q <= 1'b0;
                    end
                end else if (read_delay_q != 0) begin
                    read_delay_q <= read_delay_q - 3'd1;
                    if (read_delay_q == 3'd1) begin
                        app_rd_data <= native_read_data(read_app_addr_q);
                        app_rd_data_end <= 1'b1;
                        app_rd_data_valid <= 1'b1;
                        read_pending_q <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        ui_clk = 1'b0;
        forever #3 ui_clk = ~ui_clk;
    end

    // This is the exact corruption signature from hardware: the redirected
    // target tag completes with the cancelled fall-through line's payload.
    always @(posedge clk) begin
        if (rst_n && !flush && u_fetch.req_complete &&
            (u_fetch.req_addr_q == {TARGET_PC[63:3], 3'b000}) &&
            (fetch_mem_rdata == OLD_LINE)) begin
            $fatal(1, "redirect target completed with stale fall-through data");
        end
    end

    task automatic wait_for_external_request(input [63:0] expected_addr);
        integer cycles;
        begin
            cycles = 0;
            while (!req_valid && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!req_valid || req_addr !== expected_addr)
                $fatal(1, "external request mismatch: valid=%b addr=%016x expected=%016x",
                       req_valid, req_addr, expected_addr);
        end
    endtask

    task automatic wait_for_old_transport_read;
        integer cycles;
        begin
            cycles = 0;
            while (!old_read_waiting && cycles < 1000) begin
                @(negedge ui_clk);
                cycles = cycles + 1;
            end
            #1;
            if (!old_read_waiting)
                $fatal(1, "old scalar read did not reach the MIG transport");
        end
    endtask

    task automatic wait_for_external_completion;
        integer cycles;
        begin
            cycles = 0;
            while (!req_ready && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!req_ready)
                $fatal(1, "scalar response did not return through CDC");
        end
    endtask

    task automatic pulse_redirect(input bit invalidate_resident_lines);
        begin
            flush = invalidate_resident_lines;
            redirect = 1'b1;
            @(posedge clk);
            @(negedge clk);
            flush = 1'b0;
            redirect = 1'b0;
            pc = TARGET_PC;
            pc_valid = 1'b1;
            #1;
            if (!pc_ready)
                $fatal(1, "target PC was not accepted after redirect");
            @(posedge clk);
            @(negedge clk);
            pc_valid = 1'b0;
        end
    endtask

    task automatic run_case(
        input integer cancel_phase,
        input bit invalidate_resident_lines
    );
        integer cycles;
        begin
            rst_n = 1'b0;
            flush = 1'b0;
            redirect = 1'b0;
            pc_valid = 1'b0;
            pc = OLD_PC;
            hold_old_response = 1'b1;
            release_old_response = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;

            pc_valid = 1'b1;
            #1;
            if (!pc_ready)
                $fatal(1, "old PC was not accepted");
            @(posedge clk);
            @(negedge clk);
            pc_valid = 1'b0;
            wait_for_external_request(OLD_PA);
            wait_for_old_transport_read();

            if (cancel_phase < 0) begin
                pulse_redirect(invalidate_resident_lines);
            end

            release_old_response = 1'b1;
            wait_for_external_completion();
            if (cancel_phase == 0) begin
                pulse_redirect(invalidate_resident_lines);
            end else begin
                @(posedge clk);
                @(negedge clk);
            end

            if (cancel_phase > 0) begin
                repeat (cancel_phase - 1) begin
                    @(posedge clk);
                    @(negedge clk);
                end
                pulse_redirect(invalidate_resident_lines);
            end

            wait_for_external_request(TARGET_PA);

            cycles = 0;
            while (!decode_valid && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!decode_valid || decode_pc !== TARGET_PC ||
                decode_instr !== TARGET_LINE[31:0]) begin
                $fatal(1,
                       "phase %0d delivered pc/instr=%016x/%08x expected=%016x/%08x",
                       cancel_phase, decode_pc, decode_instr,
                       TARGET_PC, TARGET_LINE[31:0]);
            end
            $display("PASS %s phase %0d: target %016x delivered %08x",
                     invalidate_resident_lines ? "flush+redirect" :
                                                 "redirect-only",
                     cancel_phase, decode_pc, decode_instr);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        // Normal 1P redirects preserve address-tagged resident lines.
        run_case(-1, 1'b0); // old physical request stalled
        run_case(0, 1'b0);  // old external completion
        run_case(1, 1'b0);  // response stage
        run_case(2, 1'b0);  // completion/resume handoff
        // DEBUG_SERIALIZE_ALL_1P deliberately also invalidates the resident
        // fetch window on a resolved redirect. This is the FPGA failure mode.
        run_case(-1, 1'b1);
        run_case(0, 1'b1);
        run_case(1, 1'b1);
        run_case(2, 1'b1);
        $display("PASS: FPGA four-stage fetch redirect drains stale response");
        $finish;
    end

endmodule
