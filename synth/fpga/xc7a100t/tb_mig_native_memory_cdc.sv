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

    logic icx_req_valid = 1'b0;
    logic icx_req_ready;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart = '0;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn = '0;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source = '0;
    logic [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op = '0;
    logic icx_req_lock = 1'b0;
    logic [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order = '0;
    logic [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind = '0;
    logic [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr = '0;
    logic [2:0] icx_req_size = 3'd0;
    logic [63:0] icx_req_addr = 64'd0;
    logic [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_len = '0;

    logic icx_resp_valid;
    logic icx_resp_ready = 1'b0;
    logic [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart;
    logic [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_data;
    logic icx_resp_error;
    logic icx_resp_sc_success;

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
        .icx_req_valid_i(icx_req_valid),
        .icx_req_ready_o(icx_req_ready),
        .icx_req_hart_id_i(icx_req_hart),
        .icx_req_txn_id_i(icx_req_txn),
        .icx_req_source_id_i(icx_req_source),
        .icx_req_op_i(icx_req_op),
        .icx_req_lock_i(icx_req_lock),
        .icx_req_order_i(icx_req_order),
        .icx_req_kind_i(icx_req_kind),
        .icx_req_attr_i(icx_req_attr),
        .icx_req_size_i(icx_req_size),
        .icx_req_addr_i(icx_req_addr),
        .icx_req_burst_len_i(icx_req_len),
        .icx_wdata_valid_i(1'b0),
        .icx_wdata_ready_o(),
        .icx_wdata_hart_id_i('0),
        .icx_wdata_txn_id_i('0),
        .icx_wdata_source_id_i('0),
        .icx_wdata_beat_index_i('0),
        .icx_wdata_last_i(1'b0),
        .icx_wdata_i('0),
        .icx_wstrb_i('0),
        .icx_resp_valid_o(icx_resp_valid),
        .icx_resp_ready_i(icx_resp_ready),
        .icx_resp_hart_id_o(icx_resp_hart),
        .icx_resp_txn_id_o(icx_resp_txn),
        .icx_resp_source_id_o(icx_resp_source),
        .icx_resp_beat_index_o(icx_resp_beat),
        .icx_resp_last_o(icx_resp_last),
        .icx_resp_rdata_o(icx_resp_data),
        .icx_resp_error_o(icx_resp_error),
        .icx_resp_sc_success_o(icx_resp_sc_success),
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
        wait (icx_req_ready);
        @(negedge core_clk);
        icx_req_hart = 4'h3;
        icx_req_txn = 4'h7;
        icx_req_source = `OPENRV64_ICX_SOURCE_PTW;
        icx_req_op = `OPENRV64_ICX_OP_READ;
        icx_req_size = 3'd6;
        icx_req_addr = 64'h0000_0000_8000_0040;
        icx_req_valid = 1'b1;
        @(posedge core_clk);
        #1 icx_req_valid = 1'b0;

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

        wait (icx_resp_valid);
        if (icx_resp_error || !icx_resp_last ||
            (icx_resp_hart != 4'h3) || (icx_resp_txn != 4'h7) ||
            (icx_resp_source != `OPENRV64_ICX_SOURCE_PTW) ||
            (icx_resp_data[255:0] !=
                {4{64'haaaa_aaaa_aaaa_aaaa}}) ||
            (icx_resp_data[511:256] !=
                {4{64'hbbbb_bbbb_bbbb_bbbb}}))
            $fatal(1, "CDC ICX response mismatch");
        repeat (2) @(posedge core_clk);
        if (!icx_resp_valid)
            $fatal(1, "CDC ICX response did not hold under backpressure");
        icx_resp_ready = 1'b1;
        @(posedge core_clk);

        $display("PASS: MYIR MIG native CDC adapter");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "CDC adapter test timeout");
    end

endmodule
