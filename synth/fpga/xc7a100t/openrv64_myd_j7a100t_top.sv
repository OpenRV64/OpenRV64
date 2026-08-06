`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "complex/protocol/defs.v"

// MYIR MYD-J7A100T board boundary using the vendor DDR3 MIG configuration.
module openrv64_myd_j7a100t_top #(
    parameter integer DDR3_BYTES = 512 * 1024 * 1024,
    // The core clock is 10 MHz; MIG retains its 100 MHz native UI clock.
    // A divisor of 10 therefore produces the intended 1 MHz timebase tick.
    parameter int unsigned MTIME_DIVISOR = 10
) (
    input  logic sys_clk_p,
    input  logic sys_clk_n,
    input  logic rst_n,
    input  logic uart_rx_i,
    output logic uart_tx_o,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);

    localparam int unsigned MTIME_COUNTER_WIDTH =
        (MTIME_DIVISOR <= 1) ? 1 : $clog2(MTIME_DIVISOR);

    wire sys_clk;
    wire mig_sys_clk;
    wire core_clk;
    wire mig_clock_locked;

    IBUFDS u_sys_clk_ibuf (
        .O(sys_clk),
        .I(sys_clk_p),
        .IB(sys_clk_n)
    );

    // One MMCM supplies both domains. R4 cannot legally drive two MMCMs
    // under the board's required BACKBONE clock-routing constraint.
    myir_mig_clk_wiz u_clock_wizard (
        .clk_out1(mig_sys_clk),
        .clk_out2(core_clk),
        .locked(mig_clock_locked),
        .clk_in1(sys_clk)
    );

    wire [27:0]  app_addr;
    wire [2:0]   app_cmd;
    wire         app_en;
    wire [255:0] app_wdf_data;
    wire         app_wdf_end;
    wire [31:0]  app_wdf_mask;
    wire         app_wdf_wren;
    wire [255:0] app_rd_data;
    wire         app_rd_data_end;
    wire         app_rd_data_valid;
    wire         app_rdy;
    wire         app_wdf_rdy;
    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         init_calib_complete;

    wire mig_sys_rst_n = rst_n && mig_clock_locked;

    mig_7series_0 u_mig (
        .ddr3_addr(ddr3_addr),
        .ddr3_ba(ddr3_ba),
        .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n),
        .ddr3_ck_p(ddr3_ck_p),
        .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt),
        .init_calib_complete(init_calib_complete),
        .app_addr(app_addr),
        .app_cmd(app_cmd),
        .app_en(app_en),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end(app_wdf_end),
        .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data),
        .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rdy(app_rdy),
        .app_wdf_rdy(app_wdf_rdy),
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(),
        .app_ref_ack(),
        .app_zq_ack(),
        .ui_clk(ui_clk),
        .ui_clk_sync_rst(ui_clk_sync_rst),
        .app_wdf_mask(app_wdf_mask),
        .sys_clk_i(mig_sys_clk),
        .device_temp(),
        .sys_rst(mig_sys_rst_n)
    );

    // MIG's UI reset is synchronous to ui_clk. Convert it into a reset
    // sourced by a flip-flop rather than using calibration/reset logic as a
    // combinational asynchronous reset tree for the adapter.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] ui_adapter_reset_sync_q;
    always_ff @(posedge ui_clk or negedge rst_n) begin
        if (!rst_n)
            ui_adapter_reset_sync_q <= 2'b00;
        else if (ui_clk_sync_rst)
            ui_adapter_reset_sync_q <= 2'b00;
        else
            ui_adapter_reset_sync_q <= {
                ui_adapter_reset_sync_q[0], 1'b1
            };
    end
    wire ui_adapter_rst_ni = ui_adapter_reset_sync_q[1];

    // Synchronize calibration release into the slow core domain. Holding the
    // SoC in reset prevents the ROM jump to DDR from outrunning calibration.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] platform_release_sync_q;
    always_ff @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            platform_release_sync_q <= 2'b00;
        end else if (!mig_clock_locked) begin
            platform_release_sync_q <= 2'b00;
        end else begin
            platform_release_sync_q <= {
                platform_release_sync_q[0],
                init_calib_complete
            };
        end
    end
    wire platform_rst_ni = platform_release_sync_q[1];

    logic [MTIME_COUNTER_WIDTH-1:0] mtime_counter_q;
    logic mtime_tick;

    generate
        if (MTIME_DIVISOR <= 1) begin : g_mtime_every_cycle
            always_comb mtime_tick = platform_rst_ni;
        end else begin : g_mtime_divided
            always_ff @(posedge core_clk or negedge platform_rst_ni) begin
                if (!platform_rst_ni) begin
                    mtime_counter_q <= '0;
                    mtime_tick <= 1'b0;
                end else if (mtime_counter_q == MTIME_DIVISOR - 1) begin
                    mtime_counter_q <= '0;
                    mtime_tick <= 1'b1;
                end else begin
                    mtime_counter_q <= mtime_counter_q + 1'b1;
                    mtime_tick <= 1'b0;
                end
            end
        end
    endgenerate

    wire        ext_mem_valid;
    wire        ext_mem_ready;
    wire        ext_mem_write;
    wire [63:0] ext_mem_addr;
    wire [63:0] ext_mem_wdata;
    wire [7:0]  ext_mem_wstrb;
    wire [63:0] ext_mem_rdata;

    wire ext_icx_req_valid;
    wire ext_icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ext_icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ext_icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ext_icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] ext_icx_req_op;
    wire ext_icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] ext_icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] ext_icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] ext_icx_req_attr;
    wire [2:0] ext_icx_req_size;
    wire [63:0] ext_icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] ext_icx_req_burst_len;

    wire ext_icx_wdata_valid;
    wire ext_icx_wdata_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ext_icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ext_icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ext_icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        ext_icx_wdata_beat_index;
    wire ext_icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] ext_icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] ext_icx_wstrb;

    wire ext_icx_resp_valid;
    wire ext_icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ext_icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ext_icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ext_icx_resp_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        ext_icx_resp_beat_index;
    wire ext_icx_resp_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] ext_icx_resp_rdata;
    wire ext_icx_resp_error;
    wire ext_icx_resp_sc_success;

    openrv64_mig_native_memory_cdc #(
        .MEM_BYTES(DDR3_BYTES)
    ) u_memory_adapter (
        .core_clk_i(core_clk),
        .core_rst_ni(platform_rst_ni),
        .ui_clk_i(ui_clk),
        .ui_rst_ni(ui_adapter_rst_ni),
        .calib_complete_i(init_calib_complete),
        .mem_valid_i(ext_mem_valid),
        .mem_ready_o(ext_mem_ready),
        .mem_write_i(ext_mem_write),
        .mem_addr_i(ext_mem_addr),
        .mem_wdata_i(ext_mem_wdata),
        .mem_wstrb_i(ext_mem_wstrb),
        .mem_rdata_o(ext_mem_rdata),
        .icx_req_valid_i(ext_icx_req_valid),
        .icx_req_ready_o(ext_icx_req_ready),
        .icx_req_hart_id_i(ext_icx_req_hart_id),
        .icx_req_txn_id_i(ext_icx_req_txn_id),
        .icx_req_source_id_i(ext_icx_req_source_id),
        .icx_req_op_i(ext_icx_req_op),
        .icx_req_lock_i(ext_icx_req_lock),
        .icx_req_order_i(ext_icx_req_order),
        .icx_req_kind_i(ext_icx_req_kind),
        .icx_req_attr_i(ext_icx_req_attr),
        .icx_req_size_i(ext_icx_req_size),
        .icx_req_addr_i(ext_icx_req_addr),
        .icx_req_burst_len_i(ext_icx_req_burst_len),
        .icx_wdata_valid_i(ext_icx_wdata_valid),
        .icx_wdata_ready_o(ext_icx_wdata_ready),
        .icx_wdata_hart_id_i(ext_icx_wdata_hart_id),
        .icx_wdata_txn_id_i(ext_icx_wdata_txn_id),
        .icx_wdata_source_id_i(ext_icx_wdata_source_id),
        .icx_wdata_beat_index_i(ext_icx_wdata_beat_index),
        .icx_wdata_last_i(ext_icx_wdata_last),
        .icx_wdata_i(ext_icx_wdata),
        .icx_wstrb_i(ext_icx_wstrb),
        .icx_resp_valid_o(ext_icx_resp_valid),
        .icx_resp_ready_i(ext_icx_resp_ready),
        .icx_resp_hart_id_o(ext_icx_resp_hart_id),
        .icx_resp_txn_id_o(ext_icx_resp_txn_id),
        .icx_resp_source_id_o(ext_icx_resp_source_id),
        .icx_resp_beat_index_o(ext_icx_resp_beat_index),
        .icx_resp_last_o(ext_icx_resp_last),
        .icx_resp_rdata_o(ext_icx_resp_rdata),
        .icx_resp_error_o(ext_icx_resp_error),
        .icx_resp_sc_success_o(ext_icx_resp_sc_success),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid),
        .app_rdy_i(app_rdy),
        .app_wdf_rdy_i(app_wdf_rdy)
    );

    openrv64_platform #(
        .MEMORY_BYTES(DDR3_BYTES),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_1P),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64A(1'b1),
        .EXTERNAL_MEMORY_ENABLE(1'b1),
        .DDR3_ENABLE(1'b0),
        .L1D_PREFETCH_ENABLE(1'b0),
        .FETCH_CAROUSEL(1'b0),
        .FETCH_ALT_LOOKASIDE(0),
        .BP_TYPE(`OPENRV64_BP_GSHARE_BTB),
        .ENABLE_TRACE(1'b0)
    ) u_platform (
        .clk_i(core_clk),
        .rst_ni(platform_rst_ni),
        .mtime_tick_i(mtime_tick),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_tx_o),
        .gpio_in_i(32'h0000_0000),
        .gpio_out_o(),
        .external_irq_i(29'h0000_0000),
        .ext_mem_valid_o(ext_mem_valid),
        .ext_mem_ready_i(ext_mem_ready),
        .ext_mem_write_o(ext_mem_write),
        .ext_mem_addr_o(ext_mem_addr),
        .ext_mem_wdata_o(ext_mem_wdata),
        .ext_mem_wstrb_o(ext_mem_wstrb),
        .ext_mem_rdata_i(ext_mem_rdata),
        .ext_icx_req_valid_o(ext_icx_req_valid),
        .ext_icx_req_ready_i(ext_icx_req_ready),
        .ext_icx_req_hart_id_o(ext_icx_req_hart_id),
        .ext_icx_req_txn_id_o(ext_icx_req_txn_id),
        .ext_icx_req_source_id_o(ext_icx_req_source_id),
        .ext_icx_req_op_o(ext_icx_req_op),
        .ext_icx_req_lock_o(ext_icx_req_lock),
        .ext_icx_req_order_o(ext_icx_req_order),
        .ext_icx_req_kind_o(ext_icx_req_kind),
        .ext_icx_req_attr_o(ext_icx_req_attr),
        .ext_icx_req_size_o(ext_icx_req_size),
        .ext_icx_req_addr_o(ext_icx_req_addr),
        .ext_icx_req_burst_len_o(ext_icx_req_burst_len),
        .ext_icx_wdata_valid_o(ext_icx_wdata_valid),
        .ext_icx_wdata_ready_i(ext_icx_wdata_ready),
        .ext_icx_wdata_hart_id_o(ext_icx_wdata_hart_id),
        .ext_icx_wdata_txn_id_o(ext_icx_wdata_txn_id),
        .ext_icx_wdata_source_id_o(ext_icx_wdata_source_id),
        .ext_icx_wdata_beat_index_o(ext_icx_wdata_beat_index),
        .ext_icx_wdata_last_o(ext_icx_wdata_last),
        .ext_icx_wdata_o(ext_icx_wdata),
        .ext_icx_wstrb_o(ext_icx_wstrb),
        .ext_icx_resp_valid_i(ext_icx_resp_valid),
        .ext_icx_resp_ready_o(ext_icx_resp_ready),
        .ext_icx_resp_hart_id_i(ext_icx_resp_hart_id),
        .ext_icx_resp_txn_id_i(ext_icx_resp_txn_id),
        .ext_icx_resp_source_id_i(ext_icx_resp_source_id),
        .ext_icx_resp_beat_index_i(ext_icx_resp_beat_index),
        .ext_icx_resp_last_i(ext_icx_resp_last),
        .ext_icx_resp_rdata_i(ext_icx_resp_rdata),
        .ext_icx_resp_error_i(ext_icx_resp_error),
        .ext_icx_resp_sc_success_i(ext_icx_resp_sc_success),
        .soc_rst_no(),
        .core_rst_no(),
        .dbg_pc(),
        .dbg_instr(),
        .dbg_halted(),
        .trace_cycle(),
        .trace_valid(),
        .trace_stall(),
        .trace_flush(),
        .trace_advance(),
        .trace_ids(),
        .trace_pcs(),
        .trace_instrs(),
        .trace_events(),
        .trace_stall_causes(),
        .trace_retire_valid(),
        .trace_retire_arch(),
        .trace_retire_exception(),
        .trace_retire_cause(),
        .trace_retire_next_pc(),
        .trace_retire_rd_write(),
        .trace_retire_rd(),
        .trace_retire_wdata()
    );

endmodule
