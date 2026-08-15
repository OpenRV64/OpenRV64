// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// One-pipe OpenRV64 platform, DDR3 boot copier, and native-MIG memory bridge.

`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "complex/protocol/defs.v"

module openrv64_fpga_opensbi_system #(
    parameter TRAMPOLINE_INIT_FILE = "",
    parameter FIRMWARE_INIT_FILE   = "",
    parameter FIRMWARE_TAIL_INIT_FILE = "",
    parameter PAYLOAD_INIT_FILE    = "",
    parameter FDT_INIT_FILE        = "",
    parameter integer TRAMPOLINE_WORDS = 1,
    parameter integer FIRMWARE_WORDS   = 1,
    parameter integer PAYLOAD_WORDS    = 1,
    parameter integer FDT_WORDS        = 1,
    parameter integer UART_LINUX_LOAD_ENABLE = 0,
    parameter integer STATUS_CLOCK_HZ = 100_000_000,
    parameter integer STATUS_BAUD = 115_200,
    parameter integer STATUS_FIRST_DELAY_CYCLES = 100_000,
    parameter integer STATUS_REPEAT_CYCLES = 100_000_000
) (
    input  logic         ui_clk_i,
    input  logic         ui_reset_i,
    input  logic         calib_complete_i,
    input  logic         core_clk_i,
    input  logic         core_clock_locked_i,

    input  logic         uart_rx_i,
    output logic         uart_tx_o,
    output logic         boot_release_o,
    output logic [63:0]  debug_pc_o,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    input  logic         app_rdy_i,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic         app_wdf_rdy_i,
    input  logic [255:0] app_rd_data_i,
    input  logic         app_rd_data_end_i,
    input  logic         app_rd_data_valid_i
);

    logic [27:0] loader_app_addr;
    logic [2:0] loader_app_cmd;
    logic loader_app_en;
    logic [255:0] loader_app_wdf_data;
    logic loader_app_wdf_end;
    logic [31:0] loader_app_wdf_mask;
    logic loader_app_wdf_wren;
    logic loader_done;
    logic loader_failed;

    logic [27:0] uart_loader_app_addr;
    logic [2:0] uart_loader_app_cmd;
    logic uart_loader_app_en;
    logic [255:0] uart_loader_app_wdf_data;
    logic uart_loader_app_wdf_end;
    logic [31:0] uart_loader_app_wdf_mask;
    logic uart_loader_app_wdf_wren;
    logic uart_loader_tx;
    logic uart_loader_active;
    logic uart_loader_done;
    logic uart_loader_failed;
    wire boot_image_done = loader_done &&
        (!UART_LINUX_LOAD_ENABLE || uart_loader_done);

    logic [27:0] scalar_app_addr;
    logic [2:0] scalar_app_cmd;
    logic scalar_app_en;
    logic [255:0] scalar_app_wdf_data;
    logic scalar_app_wdf_end;
    logic [31:0] scalar_app_wdf_mask;
    logic scalar_app_wdf_wren;

    logic [1:0] boot_status;
    logic status_uart_tx;
    logic pass_message_done;
    logic boot_release_q;

    logic [3:0] core_reset_sync_q;
    wire core_reset_async_n = !ui_reset_i && boot_release_q &&
                              calib_complete_i && core_clock_locked_i;
    wire platform_reset_n = &core_reset_sync_q;

    always_ff @(posedge core_clk_i or negedge core_reset_async_n) begin
        if (!core_reset_async_n)
            core_reset_sync_q <= 4'b0000;
        else
            core_reset_sync_q <= {core_reset_sync_q[2:0], 1'b1};
    end

    always_ff @(posedge ui_clk_i) begin
        if (ui_reset_i)
            boot_release_q <= 1'b0;
        else if (boot_image_done && pass_message_done)
            boot_release_q <= 1'b1;
    end

    always_comb begin
        if (loader_failed || uart_loader_failed)
            boot_status = 2'd3;
        else if (boot_image_done)
            boot_status = 2'd2;
        else if (calib_complete_i)
            boot_status = 2'd1;
        else
            boot_status = 2'd0;
    end

    openrv64_fpga_opensbi_boot_uart_status #(
        .CLOCK_HZ(STATUS_CLOCK_HZ),
        .BAUD(STATUS_BAUD),
        .FIRST_DELAY_CYCLES(STATUS_FIRST_DELAY_CYCLES),
        .REPEAT_CYCLES(STATUS_REPEAT_CYCLES)
    ) u_boot_status (
        .clk_i(ui_clk_i),
        .reset_i(ui_reset_i),
        .status_i(boot_status),
        .tx_o(status_uart_tx),
        .pass_message_done_o(pass_message_done)
    );

`ifdef OPENRV64_FPGA_LOADER_NETLIST
    (* DONT_TOUCH = "TRUE" *)
    openrv64_fpga_loader_fixed u_loader (
`else
    openrv64_fpga_ddr3_boot_loader #(
        .TRAMPOLINE_INIT_FILE(TRAMPOLINE_INIT_FILE),
        .FIRMWARE_INIT_FILE(FIRMWARE_INIT_FILE),
        .FIRMWARE_TAIL_INIT_FILE(FIRMWARE_TAIL_INIT_FILE),
        .PAYLOAD_INIT_FILE(PAYLOAD_INIT_FILE),
        .FDT_INIT_FILE(FDT_INIT_FILE),
        .TRAMPOLINE_WORDS(TRAMPOLINE_WORDS),
        .FIRMWARE_WORDS(FIRMWARE_WORDS),
        .PAYLOAD_WORDS(PAYLOAD_WORDS),
        .FDT_WORDS(FDT_WORDS)
    ) u_loader (
`endif
        .clk_i(ui_clk_i),
        .reset_i(ui_reset_i),
        .calib_complete_i(calib_complete_i),
        .app_addr_o(loader_app_addr),
        .app_cmd_o(loader_app_cmd),
        .app_en_o(loader_app_en),
        .app_rdy_i(app_rdy_i),
        .app_wdf_data_o(loader_app_wdf_data),
        .app_wdf_end_o(loader_app_wdf_end),
        .app_wdf_mask_o(loader_app_wdf_mask),
        .app_wdf_wren_o(loader_app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy_i),
        .done_o(loader_done),
        .failed_o(loader_failed)
    );

    openrv64_fpga_uart_ddr_loader #(
        .CLOCK_HZ(STATUS_CLOCK_HZ),
        .BAUD(STATUS_BAUD)
    ) u_uart_loader (
        .clk_i(ui_clk_i),
        .reset_i(ui_reset_i),
        .start_i(loader_done && UART_LINUX_LOAD_ENABLE),
        .calib_complete_i(calib_complete_i),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_loader_tx),
        .app_addr_o(uart_loader_app_addr),
        .app_cmd_o(uart_loader_app_cmd),
        .app_en_o(uart_loader_app_en),
        .app_rdy_i(app_rdy_i),
        .app_wdf_data_o(uart_loader_app_wdf_data),
        .app_wdf_end_o(uart_loader_app_wdf_end),
        .app_wdf_mask_o(uart_loader_app_wdf_mask),
        .app_wdf_wren_o(uart_loader_app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy_i),
        .active_o(uart_loader_active),
        .done_o(uart_loader_done),
        .failed_o(uart_loader_failed)
    );

    logic core_mem_valid;
    logic core_mem_ready;
    logic core_mem_write;
    logic [63:0] core_mem_addr;
    logic [63:0] core_mem_wdata;
    logic [7:0] core_mem_wstrb;
    logic [63:0] core_mem_rdata;
    logic core_mem_error;

    logic shared_mem_valid;
    logic shared_mem_ready;
    logic shared_mem_write;
    logic [63:0] shared_mem_addr;
    logic [63:0] shared_mem_wdata;
    logic [7:0] shared_mem_wstrb;
    logic [63:0] shared_mem_rdata;
    logic shared_mem_error;

    logic ui_req_valid;
    logic ui_req_ready;
    logic ui_req_write;
    logic [63:0] ui_req_addr;
    logic [63:0] ui_req_wdata;
    logic [7:0] ui_req_wstrb;
    logic ui_resp_valid;
    logic ui_resp_ready;
    logic [63:0] ui_resp_rdata;
    logic ui_resp_error;

    wire bridge_ui_reset = ui_reset_i || !boot_release_q;

    openrv64_fpga_scalar_mem_cdc u_memory_cdc (
        .core_clk_i(core_clk_i),
        .core_reset_i(!platform_reset_n),
        .core_mem_valid_i(shared_mem_valid),
        .core_mem_ready_o(shared_mem_ready),
        .core_mem_write_i(shared_mem_write),
        .core_mem_addr_i(shared_mem_addr),
        .core_mem_wdata_i(shared_mem_wdata),
        .core_mem_wstrb_i(shared_mem_wstrb),
        .core_mem_rdata_o(shared_mem_rdata),
        .core_mem_error_o(shared_mem_error),
        .ui_clk_i(ui_clk_i),
        .ui_reset_i(bridge_ui_reset),
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
        .MEMORY_BYTES(64'h0000_0000_1000_0000)
    ) u_scalar_bridge (
        .clk_i(ui_clk_i),
        .reset_i(bridge_ui_reset),
        .calib_complete_i(calib_complete_i),
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
        .app_addr_o(scalar_app_addr),
        .app_cmd_o(scalar_app_cmd),
        .app_en_o(scalar_app_en),
        .app_rdy_i(app_rdy_i),
        .app_wdf_data_o(scalar_app_wdf_data),
        .app_wdf_end_o(scalar_app_wdf_end),
        .app_wdf_mask_o(scalar_app_wdf_mask),
        .app_wdf_wren_o(scalar_app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy_i),
        .app_rd_data_i(app_rd_data_i),
        .app_rd_data_end_i(app_rd_data_end_i),
        .app_rd_data_valid_i(app_rd_data_valid_i)
    );

    always_comb begin
        if (!loader_done) begin
            app_addr_o = loader_app_addr;
            app_cmd_o = loader_app_cmd;
            app_en_o = loader_app_en;
            app_wdf_data_o = loader_app_wdf_data;
            app_wdf_end_o = loader_app_wdf_end;
            app_wdf_mask_o = loader_app_wdf_mask;
            app_wdf_wren_o = loader_app_wdf_wren;
        end else if (UART_LINUX_LOAD_ENABLE && !uart_loader_done) begin
            app_addr_o = uart_loader_app_addr;
            app_cmd_o = uart_loader_app_cmd;
            app_en_o = uart_loader_app_en;
            app_wdf_data_o = uart_loader_app_wdf_data;
            app_wdf_end_o = uart_loader_app_wdf_end;
            app_wdf_mask_o = uart_loader_app_wdf_mask;
            app_wdf_wren_o = uart_loader_app_wdf_wren;
        end else begin
            app_addr_o = scalar_app_addr;
            app_cmd_o = scalar_app_cmd;
            app_en_o = scalar_app_en;
            app_wdf_data_o = scalar_app_wdf_data;
            app_wdf_end_o = scalar_app_wdf_end;
            app_wdf_mask_o = scalar_app_wdf_mask;
            app_wdf_wren_o = scalar_app_wdf_wren;
        end
    end

    logic platform_uart_tx;

    logic ext_icx_req_valid;
    logic ext_icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ext_icx_req_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ext_icx_req_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ext_icx_req_source_id;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] ext_icx_req_op;
    logic ext_icx_req_lock;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] ext_icx_req_kind;
    logic [2:0] ext_icx_req_size;
    logic [63:0] ext_icx_req_addr;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        ext_icx_req_burst_len;
    logic ext_icx_resp_valid;
    logic ext_icx_resp_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] ext_icx_resp_hart_id;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] ext_icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] ext_icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        ext_icx_resp_beat_index;
    logic ext_icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] ext_icx_resp_rdata;
    logic ext_icx_resp_error;
    logic ext_icx_resp_sc_success;

    openrv64_fpga_scalar_icx_arbiter #(
        .MEMORY_BASE(64'h0000_0000_8000_0000),
        .MEMORY_BYTES(64'h0000_0000_1000_0000)
    ) u_memory_arbiter (
        .clk_i(core_clk_i),
        .reset_i(!platform_reset_n),
        .core_mem_valid_i(core_mem_valid),
        .core_mem_ready_o(core_mem_ready),
        .core_mem_write_i(core_mem_write),
        .core_mem_addr_i(core_mem_addr),
        .core_mem_wdata_i(core_mem_wdata),
        .core_mem_wstrb_i(core_mem_wstrb),
        .core_mem_rdata_o(core_mem_rdata),
        .core_mem_error_o(core_mem_error),
        .icx_req_valid_i(ext_icx_req_valid),
        .icx_req_ready_o(ext_icx_req_ready),
        .icx_req_hart_id_i(ext_icx_req_hart_id),
        .icx_req_txn_id_i(ext_icx_req_txn_id),
        .icx_req_source_id_i(ext_icx_req_source_id),
        .icx_req_op_i(ext_icx_req_op),
        .icx_req_lock_i(ext_icx_req_lock),
        .icx_req_kind_i(ext_icx_req_kind),
        .icx_req_size_i(ext_icx_req_size),
        .icx_req_addr_i(ext_icx_req_addr),
        .icx_req_burst_len_i(ext_icx_req_burst_len),
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
        .mem_valid_o(shared_mem_valid),
        .mem_ready_i(shared_mem_ready),
        .mem_write_o(shared_mem_write),
        .mem_addr_o(shared_mem_addr),
        .mem_wdata_o(shared_mem_wdata),
        .mem_wstrb_o(shared_mem_wstrb),
        .mem_rdata_i(shared_mem_rdata),
        .mem_error_i(shared_mem_error)
    );

    openrv64_platform #(
        .GPIO_WIDTH(1),
        .MEMORY_BYTES(256 * 1024 * 1024),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_1P),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64ZBB(1'b0),
        .ENABLE_RV64A(1'b1),
        .ENABLE_ZICCLSM(1'b1),
        .EXTERNAL_MEMORY_ENABLE(1'b1),
        // The one-pipe generic bus has one fully associative translation
        // cache, not the ICX path's L2 TLB. Four entries are enough for
        // bring-up; misses take the normal PTW path.
        .GENBUS_TLB_ENTRIES(4),
        // Keep the page-table walker functional but omit the optional non-leaf
        // PTE cache. The FPGA Sv39 payload deliberately validates this exact
        // zero-entry configuration; Linux should revisit the performance cost.
        .PTW_PTE_CACHE_ENTRIES(0),
        .ENABLE_TRACE(1'b0),
        .ENABLE_PREDECODE_TARGETS(1'b0),
        .BP_TYPE(`OPENRV64_BP_BIMODAL),
        .BP_RAS_ENABLE(1'b0),
        .BP_BIMODAL_ENTRIES(32)
    ) u_platform (
        .clk_i(core_clk_i),
        .rst_ni(platform_reset_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(platform_uart_tx),
        .gpio_in_i(1'b0),
        .gpio_out_o(),
        .external_irq_i(29'd0),
        .ext_mem_valid_o(core_mem_valid),
        .ext_mem_ready_i(core_mem_ready),
        .ext_mem_write_o(core_mem_write),
        .ext_mem_addr_o(core_mem_addr),
        .ext_mem_wdata_o(core_mem_wdata),
        .ext_mem_wstrb_o(core_mem_wstrb),
        .ext_mem_rdata_i(core_mem_rdata),
        .ext_icx_req_valid_o(ext_icx_req_valid),
        .ext_icx_req_ready_i(ext_icx_req_ready),
        .ext_icx_req_hart_id_o(ext_icx_req_hart_id),
        .ext_icx_req_txn_id_o(ext_icx_req_txn_id),
        .ext_icx_req_source_id_o(ext_icx_req_source_id),
        .ext_icx_req_op_o(ext_icx_req_op),
        .ext_icx_req_lock_o(ext_icx_req_lock),
        .ext_icx_req_order_o(),
        .ext_icx_req_kind_o(ext_icx_req_kind),
        .ext_icx_req_attr_o(),
        .ext_icx_req_size_o(ext_icx_req_size),
        .ext_icx_req_addr_o(ext_icx_req_addr),
        .ext_icx_req_burst_len_o(ext_icx_req_burst_len),
        .ext_icx_wdata_valid_o(),
        .ext_icx_wdata_ready_i(1'b0),
        .ext_icx_wdata_hart_id_o(),
        .ext_icx_wdata_txn_id_o(),
        .ext_icx_wdata_source_id_o(),
        .ext_icx_wdata_beat_index_o(),
        .ext_icx_wdata_last_o(),
        .ext_icx_wdata_o(),
        .ext_icx_wstrb_o(),
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
        .dbg_pc(debug_pc_o),
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

    assign boot_release_o = boot_release_q;
    assign uart_tx_o = boot_release_q ? platform_uart_tx :
        ((UART_LINUX_LOAD_ENABLE && loader_done && !uart_loader_done) ?
            uart_loader_tx : status_uart_tx);

endmodule
