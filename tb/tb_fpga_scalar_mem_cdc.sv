`timescale 1ns/1ps

module tb_fpga_scalar_mem_cdc #(
    parameter integer CACHE_ENABLE = 1
);

    logic core_clk = 1'b0;
    logic ui_clk = 1'b0;
    logic core_reset = 1'b1;
    logic ui_reset = 1'b1;
    always #18.5 core_clk = ~core_clk;
    always #5 ui_clk = ~ui_clk;

    logic core_valid = 1'b0;
    logic core_ready;
    logic core_write = 1'b0;
    logic [63:0] core_addr = 64'd0;
    logic [63:0] core_wdata = 64'd0;
    logic [7:0] core_wstrb = 8'd0;
    logic [63:0] core_rdata;
    logic core_error;

    logic req_valid;
    logic req_ready;
    logic req_write;
    logic [63:0] req_addr;
    logic [63:0] req_wdata;
    logic [7:0] req_wstrb;
    logic resp_valid;
    logic resp_ready;
    logic [63:0] resp_rdata;
    logic resp_error;

    logic [27:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en;
    logic app_rdy;
    logic [255:0] app_wdf_data;
    logic app_wdf_end;
    logic [31:0] app_wdf_mask;
    logic app_wdf_wren;
    logic app_wdf_rdy;
    logic [255:0] app_rd_data = 256'd0;
    logic app_rd_data_end = 1'b0;
    logic app_rd_data_valid = 1'b0;
    logic [9:0] debug_cache_index = 10'd0;
    logic debug_cache_req_toggle = 1'b0;
    logic debug_cache_ack_toggle;
    logic [9:0] debug_cache_result_index;
    logic debug_cache_valid;
    logic [63:0] debug_cache_tag;
    logic [255:0] debug_cache_data;

    openrv64_fpga_scalar_mem_cdc u_cdc (
        .core_clk_i(core_clk),
        .core_reset_i(core_reset),
        .core_mem_valid_i(core_valid),
        .core_mem_ready_o(core_ready),
        .core_mem_write_i(core_write),
        .core_mem_addr_i(core_addr),
        .core_mem_wdata_i(core_wdata),
        .core_mem_wstrb_i(core_wstrb),
        .core_mem_rdata_o(core_rdata),
        .core_mem_error_o(core_error),
        .ui_clk_i(ui_clk),
        .ui_reset_i(ui_reset),
        .ui_req_valid_o(req_valid),
        .ui_req_ready_i(req_ready),
        .ui_req_write_o(req_write),
        .ui_req_addr_o(req_addr),
        .ui_req_wdata_o(req_wdata),
        .ui_req_wstrb_o(req_wstrb),
        .ui_resp_valid_i(resp_valid),
        .ui_resp_ready_o(resp_ready),
        .ui_resp_rdata_i(resp_rdata),
        .ui_resp_error_i(resp_error)
    );

    openrv64_fpga_mig_scalar_bridge #(
        .MEMORY_BYTES(64'h100),
        .CACHE_ENABLE(CACHE_ENABLE),
        .CACHE_BYTES(64)
    ) u_bridge (
        .clk_i(ui_clk),
        .reset_i(ui_reset),
        .calib_complete_i(1'b1),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_write_i(req_write),
        .req_addr_i(req_addr),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_rdata_o(resp_rdata),
        .resp_error_o(resp_error),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(app_rdy),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy),
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid),
        .debug_cache_index_i(debug_cache_index),
        .debug_cache_req_toggle_i(debug_cache_req_toggle),
        .debug_cache_ack_toggle_o(debug_cache_ack_toggle),
        .debug_cache_result_index_o(debug_cache_result_index),
        .debug_cache_valid_o(debug_cache_valid),
        .debug_cache_tag_o(debug_cache_tag),
        .debug_cache_data_o(debug_cache_data)
    );

    logic [255:0] memory [0:31];
    logic [7:0] ui_cycle = 8'd0;
    logic command_pending = 1'b0;
    logic data_pending = 1'b0;
    logic [27:0] pending_addr;
    logic [255:0] pending_data;
    logic [31:0] pending_mask;
    logic [2:0] read_delay = 3'd0;
    logic [27:0] read_addr_q;
    integer memory_index;
    integer write_byte;
    integer read_command_count = 0;
    integer write_command_count = 0;

    always_comb begin
        app_rdy = (ui_cycle[1:0] != 2'd1);
        app_wdf_rdy = (ui_cycle[2:0] != 3'd5);
    end

    always_ff @(posedge ui_clk) begin : mig_model
        logic command_fire;
        logic data_fire;
        logic [27:0] completed_addr;
        logic [255:0] completed_data;
        logic [31:0] completed_mask;

        ui_cycle <= ui_cycle + 8'd1;
        app_rd_data_valid <= 1'b0;
        app_rd_data_end <= 1'b0;
        command_fire = app_en && app_rdy;
        data_fire = app_wdf_wren && app_wdf_rdy;

        if (command_fire && app_cmd == 3'b001)
            read_command_count <= read_command_count + 1;
        if (command_fire && app_cmd == 3'b000)
            write_command_count <= write_command_count + 1;

        if (command_fire && app_cmd == 3'b001) begin
            read_addr_q <= app_addr;
            read_delay <= 3'd3;
        end else if (read_delay != 3'd0) begin
            read_delay <= read_delay - 3'd1;
            if (read_delay == 3'd1) begin
                app_rd_data <= memory[read_addr_q >> 3];
                app_rd_data_valid <= 1'b1;
                app_rd_data_end <= 1'b1;
            end
        end

        completed_addr = command_pending ? pending_addr : app_addr;
        completed_data = data_pending ? pending_data : app_wdf_data;
        completed_mask = data_pending ? pending_mask : app_wdf_mask;
        if ((command_pending || (command_fire && app_cmd == 3'b000)) &&
            (data_pending || data_fire)) begin
            memory_index = completed_addr >> 3;
            for (write_byte = 0; write_byte < 32;
                 write_byte = write_byte + 1) begin
                if (!completed_mask[write_byte])
                    memory[memory_index][write_byte*8 +: 8] <=
                        completed_data[write_byte*8 +: 8];
            end
            command_pending <= 1'b0;
            data_pending <= 1'b0;
        end else begin
            if (command_fire && app_cmd == 3'b000) begin
                command_pending <= 1'b1;
                pending_addr <= app_addr;
            end
            if (data_fire) begin
                data_pending <= 1'b1;
                pending_data <= app_wdf_data;
                pending_mask <= app_wdf_mask;
            end
        end
    end

    task automatic core_access(
        input logic write_request,
        input logic [63:0] address,
        input logic [63:0] write_data,
        input logic [7:0] write_strobe,
        output logic [63:0] read_data,
        output logic error
    );
        begin
            @(negedge core_clk);
            core_write = write_request;
            core_addr = address;
            core_wdata = write_data;
            core_wstrb = write_strobe;
            core_valid = 1'b1;
            while (!core_ready)
                @(posedge core_clk);
            read_data = core_rdata;
            error = core_error;
            @(negedge core_clk);
            core_valid = 1'b0;
        end
    endtask

    logic [63:0] observed_data;
    logic observed_error;
    integer init_index;

    initial begin
        for (init_index = 0; init_index < 32; init_index = init_index + 1)
            memory[init_index] = 256'd0;

        repeat (5) @(posedge ui_clk);
        ui_reset = 1'b0;
        repeat (3) @(posedge core_clk);
        core_reset = 1'b0;

        core_access(1'b1, 64'h18, 64'h0123456789abcdef, 8'hff,
                    observed_data, observed_error);
        if (observed_error || write_command_count != 1)
            $fatal(1, "full write returned an error");
        core_access(1'b0, 64'h18, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'h0123456789abcdef ||
            read_command_count != 1)
            $fatal(1, "full readback mismatch");

        core_access(1'b0, 64'h18, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'h0123456789abcdef ||
            read_command_count != (CACHE_ENABLE ? 1 : 2))
            $fatal(1, "cached read issued a second MIG read");

        // The debug read reuses the bridge cache's synchronous read port and
        // must return while the core-facing side is idle.
        debug_cache_index = 10'd0;
        debug_cache_req_toggle = 1'b1;
        wait (debug_cache_ack_toggle == debug_cache_req_toggle);
        @(posedge ui_clk);
        if (debug_cache_result_index !== 10'd0 ||
            (CACHE_ENABLE &&
             (!debug_cache_valid || debug_cache_tag !== 64'd0 ||
              debug_cache_data[255:192] !== 64'h0123456789abcdef)) ||
            (!CACHE_ENABLE && debug_cache_valid))
            $fatal(1, "indexed bridge-cache debug readback mismatch");

        core_access(1'b0, 64'h10, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'd0 ||
            read_command_count != (CACHE_ENABLE ? 1 : 3))
            $fatal(1, "same-line read missed the native-beat fill");

        core_access(1'b1, 64'h18, 64'hfedcba9876543210, 8'hff,
                    observed_data, observed_error);
        if (observed_error || write_command_count != 2)
            $fatal(1, "write-through store did not reach MIG");
        core_access(1'b0, 64'h18, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'hfedcba9876543210 ||
            read_command_count != (CACHE_ENABLE ? 2 : 4))
            $fatal(1, "store did not invalidate its cache line");

        core_access(1'b1, 64'h08, 64'h0000000000aa0000, 8'h04,
                    observed_data, observed_error);
        if (observed_error || write_command_count != 3)
            $fatal(1, "masked store did not write through");
        core_access(1'b0, 64'h08, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'h0000000000aa0000 ||
            read_command_count != (CACHE_ENABLE ? 3 : 5))
            $fatal(1, "masked write/readback mismatch");

        core_access(1'b0, 64'h18, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'hfedcba9876543210 ||
            read_command_count != (CACHE_ENABLE ? 3 : 6))
            $fatal(1, "post-store line fill did not cache the full beat");

        core_access(1'b1, 64'h58, 64'h1122334455667788, 8'hff,
                    observed_data, observed_error);
        if (observed_error || write_command_count != 4)
            $fatal(1, "conflict-address store did not write through");
        core_access(1'b0, 64'h58, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'h1122334455667788 ||
            read_command_count != (CACHE_ENABLE ? 4 : 7))
            $fatal(1, "conflict-address fill failed");
        core_access(1'b0, 64'h18, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (observed_error || observed_data !== 64'hfedcba9876543210 ||
            read_command_count != (CACHE_ENABLE ? 5 : 8))
            $fatal(1, "direct-mapped conflict did not evict old line");

        core_access(1'b0, 64'h100, 64'd0, 8'd0,
                    observed_data, observed_error);
        if (!observed_error ||
            read_command_count != (CACHE_ENABLE ? 5 : 8) ||
            write_command_count != 4)
            $fatal(1, "out-of-range request did not return an error");

        $display("OPENRV64 FPGA SCALAR MIG CDC PASS");
        $finish;
    end

endmodule
