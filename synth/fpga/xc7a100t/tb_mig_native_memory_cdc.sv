`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_mig_native_memory_cdc;
    logic core_clk = 1'b0;
    logic ui_clk = 1'b0;
    always #50 core_clk = !core_clk;
    always #5 ui_clk = !ui_clk;

    logic core_rst_n = 1'b0;
    logic ui_rst_n = 1'b0;
    logic calib = 1'b0;

    logic mem_valid = 1'b0;
    logic mem_ready;
    logic mem_write = 1'b0;
    logic [63:0] mem_addr = 64'd0;
    logic [63:0] mem_wdata = 64'd0;
    logic [7:0] mem_wstrb = 8'd0;
    logic [63:0] mem_rdata;

    logic ccx_req_valid = 1'b0;
    logic ccx_req_ready;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart = '0;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn = '0;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source = '0;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op = '0;
    logic ccx_req_lock = 1'b0;
    logic [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order = '0;
    logic [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind = '0;
    logic [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr = '0;
    logic [2:0] ccx_req_size = 3'd0;
    logic [63:0] ccx_req_addr = 64'd0;
    logic [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_len = '0;

    logic ccx_resp_valid;
    logic ccx_resp_ready = 1'b0;
    logic [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart;
    logic [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source;
    logic [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat;
    logic ccx_resp_last;
    logic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_data;
    logic ccx_resp_error;
    logic ccx_resp_sc_success;

    logic [27:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en;
    logic [255:0] app_wdata;
    logic app_wend;
    logic [31:0] app_wmask;
    logic app_wren;
    logic [255:0] app_rdata = '0;
    logic app_rend = 1'b0;
    logic app_rvalid = 1'b0;
    logic app_rdy = 1'b1;
    logic app_wrdy = 1'b1;

    openrv64_mig_native_memory_cdc dut (
        .core_clk_i(core_clk),
        .core_rst_ni(core_rst_n),
        .ui_clk_i(ui_clk),
        .ui_rst_ni(ui_rst_n),
        .calib_complete_i(calib),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .ccx_req_valid_i(ccx_req_valid),
        .ccx_req_ready_o(ccx_req_ready),
        .ccx_req_hart_id_i(ccx_req_hart),
        .ccx_req_txn_id_i(ccx_req_txn),
        .ccx_req_source_id_i(ccx_req_source),
        .ccx_req_op_i(ccx_req_op),
        .ccx_req_lock_i(ccx_req_lock),
        .ccx_req_order_i(ccx_req_order),
        .ccx_req_kind_i(ccx_req_kind),
        .ccx_req_attr_i(ccx_req_attr),
        .ccx_req_size_i(ccx_req_size),
        .ccx_req_addr_i(ccx_req_addr),
        .ccx_req_burst_len_i(ccx_req_len),
        .ccx_wdata_valid_i(1'b0),
        .ccx_wdata_ready_o(),
        .ccx_wdata_hart_id_i('0),
        .ccx_wdata_txn_id_i('0),
        .ccx_wdata_source_id_i('0),
        .ccx_wdata_beat_index_i('0),
        .ccx_wdata_last_i(1'b0),
        .ccx_wdata_i('0),
        .ccx_wstrb_i('0),
        .ccx_resp_valid_o(ccx_resp_valid),
        .ccx_resp_ready_i(ccx_resp_ready),
        .ccx_resp_hart_id_o(ccx_resp_hart),
        .ccx_resp_txn_id_o(ccx_resp_txn),
        .ccx_resp_source_id_o(ccx_resp_source),
        .ccx_resp_beat_index_o(ccx_resp_beat),
        .ccx_resp_last_o(ccx_resp_last),
        .ccx_resp_rdata_o(ccx_resp_data),
        .ccx_resp_error_o(ccx_resp_error),
        .ccx_resp_sc_success_o(ccx_resp_sc_success),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_wdf_data_o(app_wdata),
        .app_wdf_end_o(app_wend),
        .app_wdf_mask_o(app_wmask),
        .app_wdf_wren_o(app_wren),
        .app_rd_data_i(app_rdata),
        .app_rd_data_end_i(app_rend),
        .app_rd_data_valid_i(app_rvalid),
        .app_rdy_i(app_rdy),
        .app_wdf_rdy_i(app_wrdy)
    );

    task automatic return_read(input logic [255:0] data);
        begin
            @(negedge ui_clk);
            app_rdata = data;
            app_rvalid = 1'b1;
            app_rend = 1'b1;
            @(negedge ui_clk);
            app_rvalid = 1'b0;
            app_rend = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge ui_clk);
        ui_rst_n = 1'b1;
        calib = 1'b1;
        @(negedge core_clk);
        core_rst_n = 1'b1;

        // Scalar read: core request crosses to UI and the selected lane
        // returns across the independent clocks.
        @(negedge core_clk);
        mem_addr = 64'h10;
        mem_valid = 1'b1;
        wait (app_en);
        if ((app_cmd != 3'b001) || (app_addr != 28'd0))
            $fatal(1, "CDC scalar read command mismatch");
        @(posedge ui_clk);
        return_read({
            64'hffff_ffff_ffff_ffff,
            64'h1122_3344_5566_7788,
            64'heeee_eeee_eeee_eeee,
            64'hdddd_dddd_dddd_dddd
        });
        wait (mem_ready);
        if (mem_rdata != 64'h1122_3344_5566_7788)
            $fatal(1, "CDC scalar read response mismatch");
        @(posedge core_clk);
        #1 mem_valid = 1'b0;

        // Scalar write: MIG may accept the write-data beat before accepting
        // its command. The adapter must hold the command and issue each once.
        app_rdy = 1'b0;
        @(negedge core_clk);
        mem_write = 1'b1;
        mem_addr = 64'h18;
        mem_wdata = 64'h0123_4567_89ab_cdef;
        mem_wstrb = 8'h81;
        mem_valid = 1'b1;
        wait (app_wren);
        if (!app_wend || (app_addr != 28'd0) ||
            (app_cmd != 3'b000) ||
            (app_wdata[255:192] != 64'h0123_4567_89ab_cdef) ||
            (app_wmask != 32'h7eff_ffff))
            $fatal(1, "CDC scalar write-data mismatch");
        @(posedge ui_clk);
        #1;
        if (app_wren)
            $fatal(1, "CDC scalar write-data was accepted twice");
        repeat (2) @(posedge ui_clk);
        if (!app_en)
            $fatal(1, "CDC scalar write command was not held");
        app_rdy = 1'b1;
        @(posedge ui_clk);
        wait (mem_ready);
        @(posedge core_clk);
        #1;
        mem_valid = 1'b0;
        mem_write = 1'b0;

        // PTW line read: one core request becomes two MIG UI beats.
        wait (ccx_req_ready);
        @(negedge core_clk);
        ccx_req_hart = 4'h3;
        ccx_req_txn = 4'h7;
        ccx_req_source = `OPENRV64_CCX_SOURCE_PTW;
        ccx_req_op = `OPENRV64_CCX_OP_READ;
        ccx_req_size = 3'd6;
        ccx_req_addr = 64'h0000_0000_8000_0040;
        ccx_req_valid = 1'b1;
        @(posedge core_clk);
        #1 ccx_req_valid = 1'b0;

        wait (app_en);
        if (app_addr != 28'd16)
            $fatal(1, "CDC first line command mismatch");
        @(posedge ui_clk);
        return_read({4{64'haaaa_aaaa_aaaa_aaaa}});
        wait (app_en);
        if (app_addr != 28'd24)
            $fatal(1, "CDC second line command mismatch");
        @(posedge ui_clk);
        return_read({4{64'hbbbb_bbbb_bbbb_bbbb}});

        wait (ccx_resp_valid);
        if (ccx_resp_error || !ccx_resp_last ||
            (ccx_resp_hart != 4'h3) || (ccx_resp_txn != 4'h7) ||
            (ccx_resp_source != `OPENRV64_CCX_SOURCE_PTW) ||
            (ccx_resp_data[255:0] !=
                {4{64'haaaa_aaaa_aaaa_aaaa}}) ||
            (ccx_resp_data[511:256] !=
                {4{64'hbbbb_bbbb_bbbb_bbbb}}))
            $fatal(1, "CDC CCX response mismatch");
        repeat (2) @(posedge core_clk);
        if (!ccx_resp_valid)
            $fatal(1, "CDC CCX response did not hold under backpressure");
        ccx_resp_ready = 1'b1;
        @(posedge core_clk);

        $display("PASS: MYIR MIG native CDC adapter");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "CDC adapter test timeout");
    end

endmodule
