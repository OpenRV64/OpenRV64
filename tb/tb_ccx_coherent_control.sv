`timescale 1ns/1ps
`include "complex/coherent/protocol/defs.v"

module tb_ccx_coherent_control #(
    parameter integer NUM_HARTS = 2
);

    localparam integer DIRECTORY_ENTRIES = 16;
    localparam integer DIRECTORY_INDEX_WIDTH = 4;

    logic clk;
    logic rst_n;

    logic dir_read_entry_valid;
    logic [DIRECTORY_INDEX_WIDTH-1:0] dir_read_index;
    wire [NUM_HARTS-1:0] dir_read_i_sharers;
    wire [NUM_HARTS-1:0] dir_read_d_sharers;

    logic dir_update_valid;
    wire dir_update_ready;
    logic dir_update_clear_entry;
    logic [DIRECTORY_INDEX_WIDTH-1:0] dir_update_index;
    logic [NUM_HARTS-1:0] dir_update_add_i_sharers;
    logic [NUM_HARTS-1:0] dir_update_add_d_sharers;
    logic [NUM_HARTS-1:0] dir_update_clear_i_sharers;
    logic [NUM_HARTS-1:0] dir_update_clear_d_sharers;

    logic inv_valid;
    wire inv_ready;
    logic [DIRECTORY_INDEX_WIDTH-1:0] inv_dir_index;
    logic [NUM_HARTS-1:0] inv_target_harts;
    logic [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] inv_probe_id;
    logic [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0] inv_cache_mask;
    logic [63:0] inv_line_addr;
    wire inv_done_valid;
    logic inv_done_ready;
    wire [DIRECTORY_INDEX_WIDTH-1:0] inv_done_dir_index;
    wire [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] inv_done_probe_id;

    wire [NUM_HARTS-1:0] probe_valid;
    logic [NUM_HARTS-1:0] probe_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_id;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CMD_WIDTH-1:0]
        probe_command;
    wire [NUM_HARTS*`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0]
        probe_cache_mask;
    wire [NUM_HARTS*64-1:0] probe_line_addr;
    logic [NUM_HARTS-1:0] probe_ack_valid;
    wire [NUM_HARTS-1:0] probe_ack_ready;
    logic [NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH-1:0]
        probe_ack_id;

    logic protocol_error_clear;
    wire protocol_error;

    integer hart_index;
    integer wait_cycles;
    logic [NUM_HARTS-1:0] initial_i_sharers;
    logic [NUM_HARTS-1:0] initial_d_sharers;
    logic [NUM_HARTS-1:0] target_harts;

    generate
        if (NUM_HARTS == 2) begin : g_2h
            openrv64_ccx_2h_control #(
                .DIRECTORY_ENTRIES(DIRECTORY_ENTRIES),
                .DIRECTORY_INDEX_WIDTH(DIRECTORY_INDEX_WIDTH)
            ) dut (
                .clk_i(clk),
                .rst_ni(rst_n),
                .dir_read_entry_valid_i(dir_read_entry_valid),
                .dir_read_index_i(dir_read_index),
                .dir_read_i_sharers_o(dir_read_i_sharers),
                .dir_read_d_sharers_o(dir_read_d_sharers),
                .dir_update_valid_i(dir_update_valid),
                .dir_update_ready_o(dir_update_ready),
                .dir_update_clear_entry_i(dir_update_clear_entry),
                .dir_update_index_i(dir_update_index),
                .dir_update_add_i_sharers_i(dir_update_add_i_sharers),
                .dir_update_add_d_sharers_i(dir_update_add_d_sharers),
                .dir_update_clear_i_sharers_i(
                    dir_update_clear_i_sharers),
                .dir_update_clear_d_sharers_i(
                    dir_update_clear_d_sharers),
                .inv_valid_i(inv_valid),
                .inv_ready_o(inv_ready),
                .inv_dir_index_i(inv_dir_index),
                .inv_target_harts_i(inv_target_harts),
                .inv_probe_id_i(inv_probe_id),
                .inv_cache_mask_i(inv_cache_mask),
                .inv_line_addr_i(inv_line_addr),
                .inv_done_valid_o(inv_done_valid),
                .inv_done_ready_i(inv_done_ready),
                .inv_done_dir_index_o(inv_done_dir_index),
                .inv_done_probe_id_o(inv_done_probe_id),
                .probe_valid_o(probe_valid),
                .probe_ready_i(probe_ready),
                .probe_id_o(probe_id),
                .probe_command_o(probe_command),
                .probe_cache_mask_o(probe_cache_mask),
                .probe_line_addr_o(probe_line_addr),
                .probe_ack_valid_i(probe_ack_valid),
                .probe_ack_ready_o(probe_ack_ready),
                .probe_ack_id_i(probe_ack_id),
                .protocol_error_clear_i(protocol_error_clear),
                .protocol_error_o(protocol_error)
            );
        end else if (NUM_HARTS == 4) begin : g_4h
            openrv64_ccx_4h_control #(
                .DIRECTORY_ENTRIES(DIRECTORY_ENTRIES),
                .DIRECTORY_INDEX_WIDTH(DIRECTORY_INDEX_WIDTH)
            ) dut (
                .clk_i(clk),
                .rst_ni(rst_n),
                .dir_read_entry_valid_i(dir_read_entry_valid),
                .dir_read_index_i(dir_read_index),
                .dir_read_i_sharers_o(dir_read_i_sharers),
                .dir_read_d_sharers_o(dir_read_d_sharers),
                .dir_update_valid_i(dir_update_valid),
                .dir_update_ready_o(dir_update_ready),
                .dir_update_clear_entry_i(dir_update_clear_entry),
                .dir_update_index_i(dir_update_index),
                .dir_update_add_i_sharers_i(dir_update_add_i_sharers),
                .dir_update_add_d_sharers_i(dir_update_add_d_sharers),
                .dir_update_clear_i_sharers_i(
                    dir_update_clear_i_sharers),
                .dir_update_clear_d_sharers_i(
                    dir_update_clear_d_sharers),
                .inv_valid_i(inv_valid),
                .inv_ready_o(inv_ready),
                .inv_dir_index_i(inv_dir_index),
                .inv_target_harts_i(inv_target_harts),
                .inv_probe_id_i(inv_probe_id),
                .inv_cache_mask_i(inv_cache_mask),
                .inv_line_addr_i(inv_line_addr),
                .inv_done_valid_o(inv_done_valid),
                .inv_done_ready_i(inv_done_ready),
                .inv_done_dir_index_o(inv_done_dir_index),
                .inv_done_probe_id_o(inv_done_probe_id),
                .probe_valid_o(probe_valid),
                .probe_ready_i(probe_ready),
                .probe_id_o(probe_id),
                .probe_command_o(probe_command),
                .probe_cache_mask_o(probe_cache_mask),
                .probe_line_addr_o(probe_line_addr),
                .probe_ack_valid_i(probe_ack_valid),
                .probe_ack_ready_o(probe_ack_ready),
                .probe_ack_id_i(probe_ack_id),
                .protocol_error_clear_i(protocol_error_clear),
                .protocol_error_o(protocol_error)
            );
        end else begin : g_bad_harts
            initial
                $fatal(1, "test supports NUM_HARTS=2 or 4");
        end
    endgenerate

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic write_directory;
        input [DIRECTORY_INDEX_WIDTH-1:0] entry_index;
        input logic clear_entry;
        input logic [NUM_HARTS-1:0] add_i;
        input logic [NUM_HARTS-1:0] add_d;
        input logic [NUM_HARTS-1:0] clear_i;
        input logic [NUM_HARTS-1:0] clear_d;
        begin
            @(negedge clk);
            dir_update_valid = 1'b1;
            dir_update_clear_entry = clear_entry;
            dir_update_index = entry_index;
            dir_update_add_i_sharers = add_i;
            dir_update_add_d_sharers = add_d;
            dir_update_clear_i_sharers = clear_i;
            dir_update_clear_d_sharers = clear_d;
            while (!dir_update_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            dir_update_valid = 1'b0;
            dir_update_clear_entry = 1'b0;
            dir_update_add_i_sharers = {NUM_HARTS{1'b0}};
            dir_update_add_d_sharers = {NUM_HARTS{1'b0}};
            dir_update_clear_i_sharers = {NUM_HARTS{1'b0}};
            dir_update_clear_d_sharers = {NUM_HARTS{1'b0}};
        end
    endtask

    task automatic run_invalidation;
        input [DIRECTORY_INDEX_WIDTH-1:0] entry_index;
        input logic [NUM_HARTS-1:0] targets;
        input logic [`OPENRV64_CCX_PROBE_CACHE_WIDTH-1:0] cache_mask;
        input logic [`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] probe_tag;
        input logic [63:0] line_address;
        begin
            @(negedge clk);
            inv_valid = 1'b1;
            inv_dir_index = entry_index;
            inv_target_harts = targets;
            inv_probe_id = probe_tag;
            inv_cache_mask = cache_mask;
            inv_line_addr = line_address;
            while (!inv_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            inv_valid = 1'b0;

            if (probe_valid !== targets)
                $fatal(1,
                       "N=%0d probe target mismatch got=%b expected=%b",
                       NUM_HARTS, probe_valid, targets);
            for (hart_index = 0; hart_index < NUM_HARTS;
                 hart_index = hart_index + 1) begin
                if (targets[hart_index]) begin
                    if (probe_id[
                            hart_index*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                            `OPENRV64_CCX_PROBE_ID_WIDTH] !== probe_tag)
                        $fatal(1, "N=%0d probe ID mismatch", NUM_HARTS);
                    if (probe_command[
                            hart_index*`OPENRV64_CCX_PROBE_CMD_WIDTH +:
                            `OPENRV64_CCX_PROBE_CMD_WIDTH] !==
                        `OPENRV64_CCX_PROBE_INV)
                        $fatal(1, "N=%0d probe command mismatch",
                               NUM_HARTS);
                    if (probe_cache_mask[
                            hart_index*`OPENRV64_CCX_PROBE_CACHE_WIDTH +:
                            `OPENRV64_CCX_PROBE_CACHE_WIDTH] !==
                        cache_mask)
                        $fatal(1, "N=%0d probe cache mask mismatch",
                               NUM_HARTS);
                    if (probe_line_addr[hart_index*64 +: 64] !==
                        line_address)
                        $fatal(1, "N=%0d probe address mismatch",
                               NUM_HARTS);
                end
            end

            // Accept every probe, then return acknowledgements one hart at a
            // time.  Completion must not occur after only a subset responds.
            probe_ready = targets;
            @(posedge clk);
            @(negedge clk);
            probe_ready = {NUM_HARTS{1'b0}};
            if (probe_valid !== {NUM_HARTS{1'b0}})
                $fatal(1, "N=%0d accepted probe remained valid",
                       NUM_HARTS);

            for (hart_index = NUM_HARTS - 1; hart_index >= 0;
                 hart_index = hart_index - 1) begin
                if (targets[hart_index]) begin
                    probe_ack_valid[hart_index] = 1'b1;
                    probe_ack_id[
                        hart_index*`OPENRV64_CCX_PROBE_ID_WIDTH +:
                        `OPENRV64_CCX_PROBE_ID_WIDTH] = probe_tag;
                    if (!probe_ack_ready[hart_index])
                        $fatal(1, "N=%0d ACK lane not ready", NUM_HARTS);
                    @(posedge clk);
                    @(negedge clk);
                    probe_ack_valid[hart_index] = 1'b0;
                    if ((hart_index != 0) && inv_done_valid)
                        $fatal(1,
                               "N=%0d invalidation completed before all ACKs",
                               NUM_HARTS);
                end
            end

            wait_cycles = 0;
            while (!inv_done_valid && (wait_cycles < 8)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!inv_done_valid)
                $fatal(1, "N=%0d invalidation completion timeout",
                       NUM_HARTS);
            if ((inv_done_dir_index !== entry_index) ||
                (inv_done_probe_id !== probe_tag))
                $fatal(1, "N=%0d invalidation completion identity mismatch",
                       NUM_HARTS);

            // Completion is a real decoupled channel and must remain asserted
            // while its consumer is stalled.
            @(posedge clk);
            @(negedge clk);
            if (!inv_done_valid)
                $fatal(1, "N=%0d completion was not held", NUM_HARTS);
            inv_done_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            inv_done_ready = 1'b0;
            if (inv_done_valid)
                $fatal(1, "N=%0d completion did not retire", NUM_HARTS);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        dir_read_entry_valid = 1'b0;
        dir_read_index = {DIRECTORY_INDEX_WIDTH{1'b0}};
        dir_update_valid = 1'b0;
        dir_update_clear_entry = 1'b0;
        dir_update_index = {DIRECTORY_INDEX_WIDTH{1'b0}};
        dir_update_add_i_sharers = {NUM_HARTS{1'b0}};
        dir_update_add_d_sharers = {NUM_HARTS{1'b0}};
        dir_update_clear_i_sharers = {NUM_HARTS{1'b0}};
        dir_update_clear_d_sharers = {NUM_HARTS{1'b0}};
        inv_valid = 1'b0;
        inv_dir_index = {DIRECTORY_INDEX_WIDTH{1'b0}};
        inv_target_harts = {NUM_HARTS{1'b0}};
        inv_probe_id = {`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
        inv_cache_mask =
            {`OPENRV64_CCX_PROBE_CACHE_WIDTH{1'b0}};
        inv_line_addr = 64'd0;
        inv_done_ready = 1'b0;
        probe_ready = {NUM_HARTS{1'b0}};
        probe_ack_valid = {NUM_HARTS{1'b0}};
        probe_ack_id =
            {NUM_HARTS*`OPENRV64_CCX_PROBE_ID_WIDTH{1'b0}};
        protocol_error_clear = 1'b0;
        initial_i_sharers = {NUM_HARTS{1'b0}};
        initial_d_sharers = {NUM_HARTS{1'b1}};
        target_harts = {NUM_HARTS{1'b1}};
        initial_i_sharers[0] = 1'b1;
        initial_i_sharers[NUM_HARTS-1] = 1'b1;
        target_harts[0] = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Invalid L2 entries suppress stale, unreset directory SRAM contents.
        dir_read_index = 4'd3;
        #1;
        if ((dir_read_i_sharers !== {NUM_HARTS{1'b0}}) ||
            (dir_read_d_sharers !== {NUM_HARTS{1'b0}}))
            $fatal(1, "N=%0d invalid entry exposed directory state",
                   NUM_HARTS);

        write_directory(4'd3, 1'b1,
                        initial_i_sharers, initial_d_sharers,
                        {NUM_HARTS{1'b0}}, {NUM_HARTS{1'b0}});
        dir_read_entry_valid = 1'b1;
        #1;
        if ((dir_read_i_sharers !== initial_i_sharers) ||
            (dir_read_d_sharers !== initial_d_sharers))
            $fatal(1, "N=%0d directory allocation mismatch", NUM_HARTS);

        run_invalidation(4'd3, target_harts,
                         `OPENRV64_CCX_PROBE_CACHE_BOTH, 4'ha,
                         64'h0000_0000_8000_0140);
        #1;
        if (dir_read_i_sharers !==
            (initial_i_sharers & ~target_harts))
            $fatal(1, "N=%0d I-sharer invalidation mismatch", NUM_HARTS);
        if (dir_read_d_sharers !==
            (initial_d_sharers & ~target_harts))
            $fatal(1, "N=%0d D-sharer invalidation mismatch", NUM_HARTS);

        // Cache selection is explicit: a D-only probe must preserve all I$
        // sharers for the same L2 entry.
        write_directory(4'd3, 1'b1,
                        {NUM_HARTS{1'b1}}, {NUM_HARTS{1'b1}},
                        {NUM_HARTS{1'b0}}, {NUM_HARTS{1'b0}});
        run_invalidation(4'd3, {NUM_HARTS{1'b1}},
                         `OPENRV64_CCX_PROBE_CACHE_D, 4'hb,
                         64'h0000_0000_8000_0140);
        #1;
        if (dir_read_i_sharers !== {NUM_HARTS{1'b1}})
            $fatal(1, "N=%0d D probe cleared I sharers", NUM_HARTS);
        if (dir_read_d_sharers !== {NUM_HARTS{1'b0}})
            $fatal(1, "N=%0d D probe did not clear D sharers", NUM_HARTS);

        // A cache with an absent line may acknowledge in the same cycle that
        // it accepts the probe.  The tracker must not lose that zero-latency
        // acknowledgement.
        dir_read_index = 4'd4;
        write_directory(4'd4, 1'b1,
                        {NUM_HARTS{1'b1}}, {NUM_HARTS{1'b0}},
                        {NUM_HARTS{1'b0}}, {NUM_HARTS{1'b0}});
        @(negedge clk);
        inv_valid = 1'b1;
        inv_dir_index = 4'd4;
        inv_target_harts = {{(NUM_HARTS-1){1'b0}}, 1'b1};
        inv_probe_id = 4'hc;
        inv_cache_mask = `OPENRV64_CCX_PROBE_CACHE_I;
        inv_line_addr = 64'h0000_0000_8000_0180;
        while (!inv_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        inv_valid = 1'b0;
        if (!probe_valid[0])
            $fatal(1, "N=%0d zero-latency probe was not issued",
                   NUM_HARTS);
        probe_ready[0] = 1'b1;
        probe_ack_valid[0] = 1'b1;
        probe_ack_id[`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] = 4'hc;
        @(posedge clk);
        @(negedge clk);
        probe_ready[0] = 1'b0;
        probe_ack_valid[0] = 1'b0;
        wait_cycles = 0;
        while (!inv_done_valid && (wait_cycles < 8)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!inv_done_valid)
            $fatal(1, "N=%0d zero-latency ACK was lost", NUM_HARTS);
        if (dir_read_i_sharers[0])
            $fatal(1, "N=%0d zero-latency ACK did not clear sharer",
                   NUM_HARTS);
        inv_done_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        inv_done_ready = 1'b0;

        // An unsolicited acknowledgement is consumed as a protocol fault,
        // never mistaken for progress on a later probe.
        probe_ack_valid[0] = 1'b1;
        probe_ack_id[`OPENRV64_CCX_PROBE_ID_WIDTH-1:0] = 4'hf;
        @(posedge clk);
        @(negedge clk);
        probe_ack_valid[0] = 1'b0;
        if (!protocol_error)
            $fatal(1, "N=%0d unsolicited ACK was not reported", NUM_HARTS);
        protocol_error_clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        protocol_error_clear = 1'b0;
        if (protocol_error)
            $fatal(1, "N=%0d protocol error did not clear", NUM_HARTS);

        $display("PASS: %0d-hart directory and probe/ACK control", NUM_HARTS);
        $finish;
    end

    initial begin
        repeat (300) @(posedge clk);
        $fatal(1, "N=%0d coherent-control test timeout", NUM_HARTS);
    end

endmodule
