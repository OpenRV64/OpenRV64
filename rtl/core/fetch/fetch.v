`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

module openrv64_fetch (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             flush_i,

    output wire                             pc_ready_o,
    input  wire                             pc_valid_i,
    input  wire [`RV64_XLEN-1:0]            pc_i,

    output wire                             mem_valid_o,
    input  wire                             mem_ready_i,
    output wire                             mem_write_o,
    output wire [`RV64_XLEN-1:0]            mem_addr_o,
    output wire [`RV64_XLEN-1:0]            mem_exec_addr_o,
    output wire [`RV64_XLEN-1:0]            mem_wdata_o,
    output wire [7:0]                       mem_wstrb_o,
    input  wire [`RV64_XLEN-1:0]            mem_rdata_i,
    input  wire                             mem_fault_i,
    input  wire                             mem_page_fault_i,

    output wire                             decode_valid_o,
    input  wire                             decode_ready_i,
    output wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    output wire [`RV64_XLEN-1:0]            decode_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0]     decode_instr_o,
    output wire                             decode_fault_o,
    output wire                             decode_page_fault_o,
    input  wire [63:0]                      trace_id_i,
    output wire [63:0]                      trace_id_o
);

    localparam integer BUFFER_COUNT = 4;
    localparam integer BUFFER_INDEX_WIDTH = 2;

    // Four 8-byte buffers form a circular queue.  Each buffer holds the two
    // 32-bit instructions from one aligned fetch line.  A redirect to the
    // upper half of a line puts only that instruction in slot zero; the next
    // request starts at the following aligned line.
    reg [`RV64_INSTR_WIDTH-1:0] buffer_instr0_q [0:BUFFER_COUNT-1];
    reg [`RV64_INSTR_WIDTH-1:0] buffer_instr1_q [0:BUFFER_COUNT-1];
    reg [`RV64_XLEN-1:0]        buffer_pc0_q [0:BUFFER_COUNT-1];
    reg [`RV64_XLEN-1:0]        buffer_pc1_q [0:BUFFER_COUNT-1];
    reg [63:0]                  buffer_trace0_q [0:BUFFER_COUNT-1];
    reg [63:0]                  buffer_trace1_q [0:BUFFER_COUNT-1];
    reg                         buffer_fault_q [0:BUFFER_COUNT-1];
    reg                         buffer_page_fault_q [0:BUFFER_COUNT-1];
    reg [1:0]                   buffer_count_q [0:BUFFER_COUNT-1];

    reg [BUFFER_INDEX_WIDTH-1:0] read_bank_q;
    reg read_slot_q;
    reg [BUFFER_INDEX_WIDTH-1:0] write_bank_q;

    reg                         req_active_q;
    reg [BUFFER_INDEX_WIDTH-1:0] req_bank_q;
    reg [`RV64_XLEN-1:0]        req_pc_q;
    reg [`RV64_XLEN-1:0]        req_addr_q;
    reg [63:0]                  req_trace_id_q;

    wire decode_fire = decode_valid_o && decode_ready_i;
    wire read_bank_will_empty = decode_fire &&
                                (buffer_count_q[read_bank_q] == 2'd1);

    // A completed request advances the write side around the four-bank ring.
    // Permit the next PC to be accepted on that same edge when the next bank
    // is empty (or is consuming its final slot on this edge).
    wire [BUFFER_INDEX_WIDTH-1:0] req_successor_bank =
        req_bank_q + {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1};
    wire [BUFFER_INDEX_WIDTH-1:0] next_req_bank =
        req_active_q ? req_successor_bank : write_bank_q;
    wire next_req_bank_empty =
        (buffer_count_q[next_req_bank] == 2'd0) ||
        (read_bank_will_empty && (read_bank_q == next_req_bank));
    wire req_complete = req_active_q && mem_ready_i;

    assign pc_ready_o = !flush_i && next_req_bank_empty &&
                        (!req_active_q || req_complete);

    assign mem_valid_o = req_active_q;
    assign mem_write_o = 1'b0;
    assign mem_addr_o = req_addr_q;
    assign mem_exec_addr_o = req_pc_q;
    assign mem_wdata_o = {`RV64_XLEN{1'b0}};
    assign mem_wstrb_o = 8'h00;

    assign decode_valid_o = !flush_i &&
                            (buffer_count_q[read_bank_q] != 2'd0);
    assign decode_pc_o = read_slot_q ? buffer_pc1_q[read_bank_q] :
                                      buffer_pc0_q[read_bank_q];
    assign decode_instr_o = read_slot_q ? buffer_instr1_q[read_bank_q] :
                                         buffer_instr0_q[read_bank_q];
    assign decode_fault_o = buffer_fault_q[read_bank_q];
    assign decode_page_fault_o = buffer_page_fault_q[read_bank_q];
    assign trace_id_o = decode_valid_o ?
                        (read_slot_q ? buffer_trace1_q[read_bank_q] :
                                       buffer_trace0_q[read_bank_q]) :
                        req_trace_id_q;
    assign decode_bus_o = {
        decode_page_fault_o, decode_fault_o,
        decode_pc_o, decode_instr_o
    };

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            read_slot_q <= 1'b0;
            write_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_active_q <= 1'b0;
            req_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_pc_q <= {`RV64_XLEN{1'b0}};
            req_addr_q <= {`RV64_XLEN{1'b0}};
            req_trace_id_q <= 64'd0;

            for (i = 0; i < BUFFER_COUNT; i = i + 1) begin
                buffer_instr0_q[i] <= `RV64_INSTR_NOP;
                buffer_instr1_q[i] <= `RV64_INSTR_NOP;
                buffer_pc0_q[i] <= {`RV64_XLEN{1'b0}};
                buffer_pc1_q[i] <= {`RV64_XLEN{1'b0}};
                buffer_trace0_q[i] <= 64'd0;
                buffer_trace1_q[i] <= 64'd0;
                buffer_fault_q[i] <= 1'b0;
                buffer_page_fault_q[i] <= 1'b0;
                buffer_count_q[i] <= 2'd0;
            end
        end else if (flush_i) begin
            read_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            read_slot_q <= 1'b0;
            write_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_active_q <= 1'b0;
            req_bank_q <= {BUFFER_INDEX_WIDTH{1'b0}};
            req_pc_q <= {`RV64_XLEN{1'b0}};
            req_addr_q <= {`RV64_XLEN{1'b0}};
            req_trace_id_q <= 64'd0;

            for (i = 0; i < BUFFER_COUNT; i = i + 1) begin
                buffer_instr0_q[i] <= `RV64_INSTR_NOP;
                buffer_instr1_q[i] <= `RV64_INSTR_NOP;
                buffer_pc0_q[i] <= {`RV64_XLEN{1'b0}};
                buffer_pc1_q[i] <= {`RV64_XLEN{1'b0}};
                buffer_trace0_q[i] <= 64'd0;
                buffer_trace1_q[i] <= 64'd0;
                buffer_fault_q[i] <= 1'b0;
                buffer_page_fault_q[i] <= 1'b0;
                buffer_count_q[i] <= 2'd0;
            end
        end else begin
            if (decode_fire) begin
                if (buffer_count_q[read_bank_q] == 2'd1) begin
                    buffer_count_q[read_bank_q] <= 2'd0;
                    read_slot_q <= 1'b0;
                    read_bank_q <= read_bank_q +
                                   {{(BUFFER_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end else begin
                    buffer_count_q[read_bank_q] <=
                        buffer_count_q[read_bank_q] - 2'd1;
                    read_slot_q <= 1'b1;
                end
            end

            if (req_complete) begin
                buffer_instr0_q[req_bank_q] <=
                    (mem_fault_i || mem_page_fault_i) ?
                    `RV64_INSTR_NOP :
                    (req_pc_q[2] ? mem_rdata_i[63:32] :
                                   mem_rdata_i[31:0]);
                buffer_instr1_q[req_bank_q] <=
                    (mem_fault_i || mem_page_fault_i) ?
                    `RV64_INSTR_NOP : mem_rdata_i[63:32];
                buffer_pc0_q[req_bank_q] <= req_pc_q;
                buffer_pc1_q[req_bank_q] <= req_pc_q + 64'd4;
                buffer_trace0_q[req_bank_q] <= req_trace_id_q;
                buffer_trace1_q[req_bank_q] <= req_trace_id_q + 64'd1;
                buffer_fault_q[req_bank_q] <= mem_fault_i;
                buffer_page_fault_q[req_bank_q] <= mem_page_fault_i;
                buffer_count_q[req_bank_q] <= req_pc_q[2] ? 2'd1 : 2'd2;
                write_bank_q <= req_successor_bank;

                if (pc_valid_i && pc_ready_o) begin
                    req_active_q <= 1'b1;
                    req_bank_q <= req_successor_bank;
                    req_pc_q <= pc_i;
                    req_addr_q <= {pc_i[`RV64_XLEN-1:3], 3'b000};
                    req_trace_id_q <= trace_id_i;
                end else begin
                    req_active_q <= 1'b0;
                end
            end else if (!req_active_q && pc_valid_i && pc_ready_o) begin
                req_active_q <= 1'b1;
                req_bank_q <= write_bank_q;
                req_pc_q <= pc_i;
                req_addr_q <= {pc_i[`RV64_XLEN-1:3], 3'b000};
                req_trace_id_q <= trace_id_i;
            end
        end
    end

endmodule
