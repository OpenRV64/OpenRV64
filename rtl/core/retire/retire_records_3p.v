`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Canonical slot-indexed retirement payload storage.
//
// The ordering queue owns only IDs and control bits.  It supplies selectors
// for the three retirement reads and qualifies completion writes against the
// live ID in each slot.  Payload arrays are intentionally unreset: queue
// validity is authoritative, and clearing hundreds of dead data bits prevents
// useful memory/register-file implementations.
module openrv64_retire_records_3p #(
    parameter integer DEPTH = 16,
    parameter integer SLOT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter integer ALLOC_WIDTH = `OPENRV64_RETIRE_ALLOC_WIDTH,
    parameter integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH,
    parameter integer ENABLE_TRACE = 1
) (
    input  wire                         clk,

    input  wire [2:0]                   alloc_valid_i,
    input  wire [3*SLOT_WIDTH-1:0]      alloc_slot_i,
    input  wire [3*ALLOC_WIDTH-1:0]     alloc_record_i,
    input  wire [2:0]                   alloc_complete_i,
    // Write the ordinary result/control bank without marking the ordering
    // entry complete.  Out-of-line extensions use this to initialize next-PC
    // while keeping private result data in extension-owned storage.
    input  wire [2:0]                   alloc_result_valid_i,
    input  wire [3*RESULT_WIDTH-1:0]    alloc_result_i,
    input  wire [3*64-1:0]              alloc_trace_i,

    input  wire [2:0]                   complete_valid_i,
    input  wire [3*SLOT_WIDTH-1:0]      complete_slot_i,
    input  wire [3*RESULT_WIDTH-1:0]    complete_result_i,

    input  wire [3*SLOT_WIDTH-1:0]      read_slot_i,
    output wire [3*ALLOC_WIDTH-1:0]     read_record_o,
    output wire [3*RESULT_WIDTH-1:0]    read_result_o,
    output wire [3*64-1:0]              read_trace_o,

    // Completion-side allocation-record lookup.  The physical-writeback
    // path uses the ROB-qualified completion slot to recover its destination
    // tag without widening every execution packet.
    input  wire [3*SLOT_WIDTH-1:0]      complete_read_slot_i,
    output wire [3*ALLOC_WIDTH-1:0]     complete_read_record_o
);

    // The current interface is three asynchronous reads and up to three
    // completion plus three allocation writes.  That is a multiport register
    // file, not a credible single/dual-port SRAM contract; force an honest
    // standard-cell implementation until completion backpressure/banking
    // reduces the port count.
    (* mem2reg *)
    reg [ALLOC_WIDTH-1:0] alloc_q [0:DEPTH-1];
    (* mem2reg *)
    reg [RESULT_WIDTH-1:0] result_q [0:DEPTH-1];

    integer write_port;
    reg [SLOT_WIDTH-1:0] write_slot;
    always @(posedge clk) begin
        // Completion writes occur first.  If a retiring slot is reused on this
        // edge, the younger allocation below owns the final payload.
        for (write_port = 0; write_port < 3;
             write_port = write_port + 1) begin
            write_slot = complete_slot_i[
                write_port*SLOT_WIDTH +: SLOT_WIDTH];
            if (complete_valid_i[write_port])
                result_q[write_slot] <= complete_result_i[
                    write_port*RESULT_WIDTH +: RESULT_WIDTH];
        end

        for (write_port = 0; write_port < 3;
             write_port = write_port + 1) begin
            write_slot = alloc_slot_i[
                write_port*SLOT_WIDTH +: SLOT_WIDTH];
            if (alloc_valid_i[write_port]) begin
                alloc_q[write_slot] <= alloc_record_i[
                    write_port*ALLOC_WIDTH +: ALLOC_WIDTH];
                if (alloc_complete_i[write_port] ||
                    alloc_result_valid_i[write_port])
                    result_q[write_slot] <= alloc_result_i[
                        write_port*RESULT_WIDTH +: RESULT_WIDTH];
            end
        end
    end

    genvar read_port;
    generate
        for (read_port = 0; read_port < 3;
             read_port = read_port + 1) begin : g_read
            wire [SLOT_WIDTH-1:0] read_slot = read_slot_i[
                read_port*SLOT_WIDTH +: SLOT_WIDTH];
            assign read_record_o[
                read_port*ALLOC_WIDTH +: ALLOC_WIDTH] =
                alloc_q[read_slot];
            assign read_result_o[
                read_port*RESULT_WIDTH +: RESULT_WIDTH] =
                result_q[read_slot];
        end
    endgenerate

    genvar complete_read_port;
    generate
        for (complete_read_port = 0; complete_read_port < 3;
             complete_read_port = complete_read_port + 1) begin :
                g_complete_read
            wire [SLOT_WIDTH-1:0] complete_read_slot =
                complete_read_slot_i[
                    complete_read_port*SLOT_WIDTH +: SLOT_WIDTH];
            assign complete_read_record_o[
                complete_read_port*ALLOC_WIDTH +: ALLOC_WIDTH] =
                alloc_q[complete_read_slot];
        end
    endgenerate

    generate
        if (ENABLE_TRACE != 0) begin : g_trace
            (* mem2reg *)
            reg [63:0] trace_q [0:DEPTH-1];
            integer trace_write_port;
            reg [SLOT_WIDTH-1:0] trace_write_slot;
            always @(posedge clk) begin
                for (trace_write_port = 0; trace_write_port < 3;
                     trace_write_port = trace_write_port + 1) begin
                    trace_write_slot = alloc_slot_i[
                        trace_write_port*SLOT_WIDTH +: SLOT_WIDTH];
                    if (alloc_valid_i[trace_write_port])
                        trace_q[trace_write_slot] <= alloc_trace_i[
                            trace_write_port*64 +: 64];
                end
            end

            genvar trace_read_port;
            for (trace_read_port = 0; trace_read_port < 3;
                 trace_read_port = trace_read_port + 1) begin :
                    g_trace_read
                wire [SLOT_WIDTH-1:0] trace_read_slot = read_slot_i[
                    trace_read_port*SLOT_WIDTH +: SLOT_WIDTH];
                assign read_trace_o[
                    trace_read_port*64 +: 64] =
                    trace_q[trace_read_slot];
            end
        end else begin : g_no_trace
            assign read_trace_o = 192'd0;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1)
            $fatal(1, "retirement record depth must be positive");
    end
`endif

endmodule
