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
    output wire [`RV64_XLEN-1:0]            mem_wdata_o,
    output wire [7:0]                       mem_wstrb_o,
    input  wire [`RV64_XLEN-1:0]            mem_rdata_i,

    output wire                             decode_valid_o,
    input  wire                             decode_ready_i,
    output wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    output wire [`RV64_XLEN-1:0]            decode_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0]     decode_instr_o
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_WAIT = 2'd1;
    localparam [1:0] STATE_HELD = 2'd2;

    reg [1:0] state_q;
    reg [`RV64_XLEN-1:0] req_pc_q;
    reg [`RV64_XLEN-1:0] req_addr_q;
    reg [`RV64_XLEN-1:0] decode_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] decode_instr_q;

    wire [`RV64_INSTR_WIDTH-1:0] fetched_instr =
        req_pc_q[2] ? mem_rdata_i[63:32] : mem_rdata_i[31:0];

    assign pc_ready_o = (state_q == STATE_IDLE);

    assign mem_valid_o = (state_q == STATE_WAIT);
    assign mem_write_o = 1'b0;
    assign mem_addr_o  = req_addr_q;
    assign mem_wdata_o = {`RV64_XLEN{1'b0}};
    assign mem_wstrb_o = 8'h00;

    assign decode_valid_o = (state_q == STATE_HELD);
    assign decode_pc_o = decode_pc_q;
    assign decode_instr_o = decode_instr_q;
    assign decode_bus_o = {decode_pc_q, decode_instr_q};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= STATE_IDLE;
            req_pc_q       <= {`RV64_XLEN{1'b0}};
            req_addr_q     <= {`RV64_XLEN{1'b0}};
            decode_pc_q    <= {`RV64_XLEN{1'b0}};
            decode_instr_q <= `RV64_INSTR_NOP;
        end else if (flush_i) begin
            state_q        <= STATE_IDLE;
            req_pc_q       <= {`RV64_XLEN{1'b0}};
            req_addr_q     <= {`RV64_XLEN{1'b0}};
            decode_pc_q    <= {`RV64_XLEN{1'b0}};
            decode_instr_q <= `RV64_INSTR_NOP;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (pc_valid_i) begin
                        req_pc_q   <= pc_i;
                        req_addr_q <= {pc_i[`RV64_XLEN-1:3], 3'b000};
                        state_q    <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (mem_ready_i) begin
                        decode_pc_q    <= req_pc_q;
                        decode_instr_q <= fetched_instr;
                        state_q        <= STATE_HELD;
                    end
                end

                STATE_HELD: begin
                    if (decode_ready_i) begin
                        state_q <= STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
