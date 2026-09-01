`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// Conservative banked-register-file front end for the strict 3P dispatcher.
// The dispatch queue remains three-wide at decode, but only its oldest two
// entries may issue.  Their four operands are held until the register file
// returns a response for every nonzero, non-busy source.
module openrv64_dispatch_3p_banked #(
    parameter integer QUEUE_DEPTH = 6,
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer FREE_BRANCHES = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING = 1,
    parameter integer DEFER_EQ_BRANCH_PAIRING = 0,
    parameter integer COUNT_WIDTH = $clog2(QUEUE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,

    output wire [4*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    output wire [3:0]                   gpr_read_req_o,
    input  wire [3:0]                   gpr_read_ack_i,
    input  wire [3:0]                   gpr_read_valid_i,
    input  wire [4*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0]
                                        allocation_meta_o,

    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src1_producer_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src1_producer_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src2_producer_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src2_producer_id_o,

    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_uses_rs1_i,
    input  wire [2:0]                   retire_uses_rs2_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_i,
    input  wire [2:0]                   retire_reg_write_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_i,
    input  wire [2:0]                   retire_hard_i,

    output wire                         barrier_active_o,
    output wire [2:0]                   raw_hazard_o,
    output wire [2:0]                   waw_hazard_o,
    output wire [2:0]                   read_port_hazard_o,
    output wire [31:0]                  write_busy_o,
    output wire [COUNT_WIDTH-1:0]       queue_count_o
);

    wire [6*`RV64_REG_ADDR_WIDTH-1:0] inner_gpr_read_addr;
    wire [6*`RV64_XLEN-1:0] inner_gpr_read_data;

    reg [3:0] read_done_q;
    reg [4*`RV64_XLEN-1:0] read_data_q;
    reg [3:0] read_pending_q;
    reg [3:0] read_pending_poison_q;
    reg [3:0] read_ack_q;
    reg [3:0] read_poison_q;
    reg [4*`RV64_REG_ADDR_WIDTH-1:0] read_addr_q;
    wire [3:0] read_ready;

    assign inner_gpr_read_data[4*`RV64_XLEN +: 2*`RV64_XLEN] =
        {2*`RV64_XLEN{1'b0}};

    genvar read_port;
    generate
        for (read_port = 0; read_port < 4;
             read_port = read_port + 1) begin : g_read_port
            wire [`RV64_REG_ADDR_WIDTH-1:0] read_addr =
                inner_gpr_read_addr[
                    read_port*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
            wire read_zero = (read_addr == `RV64_REG_X0);
            wire read_blocked = !read_zero && write_busy_o[read_addr];
            wire read_start = !flush_i && !squash_frontend_i &&
                !read_zero && !read_blocked &&
                !read_done_q[read_port] &&
                !read_pending_q[read_port] && !read_ack_q[read_port];

            assign gpr_read_req_o[read_port] =
                read_pending_q[read_port] || read_start;
            assign gpr_read_addr_o[
                read_port*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = read_pending_q[read_port] ?
                read_addr_q[
                    read_port*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] : read_addr;
            assign read_ready[read_port] = read_zero ||
                (!read_blocked &&
                 (read_done_q[read_port] ||
                  (read_ack_q[read_port] &&
                   !read_poison_q[read_port] &&
                   gpr_read_valid_i[read_port])));
            assign inner_gpr_read_data[
                read_port*`RV64_XLEN +: `RV64_XLEN] =
                read_done_q[read_port] ? read_data_q[
                    read_port*`RV64_XLEN +: `RV64_XLEN] :
                (read_ack_q[read_port] &&
                 !read_poison_q[read_port] &&
                 gpr_read_valid_i[read_port]) ? gpr_read_data_i[
                    read_port*`RV64_XLEN +: `RV64_XLEN] :
                {`RV64_XLEN{1'b0}};
        end
    endgenerate

    wire operands_ready = &read_ready;

    openrv64_dispatch_3p #(
        .QUEUE_DEPTH(QUEUE_DEPTH),
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .MAX_READS_PER_REG(MAX_READS_PER_REG),
        .RELAX_WAW(0),
        .RELAX_HAZARDS(0),
        .FREE_BRANCHES(FREE_BRANCHES),
        .ENABLE_EQ_BRANCH_PAIRING(ENABLE_EQ_BRANCH_PAIRING),
        .DEFER_EQ_BRANCH_PAIRING(DEFER_EQ_BRANCH_PAIRING),
        .MAX_ISSUE_LANES(2),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) u_dispatch (
        .gpr_read_addr_o(inner_gpr_read_addr),
        .rename_destination_request_o(),
        .gpr_read_data_i(inner_gpr_read_data),
        .candidate_operand_ready_i({2'b00, read_done_q}),
        .candidate_address_ready_i(3'b111),
        .allocation_ready_i(allocation_ready_i && operands_ready),
        .forward_valid_i(2'b00),
        .forward_rd_addr_i({2*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .completion_forward_valid_i(3'b000),
        .completion_forward_rd_addr_i(
            {3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .completion_forward_data_i({3*`RV64_XLEN{1'b0}}),
        .branch_completion_forward_valid_i(3'b000),
        .forward_map_valid_i(32'b0),
        .forward_map_data_i({32*`RV64_XLEN{1'b0}}),
        .recovery_valid_i(1'b0),
        .recovery_reg_write_i(1'b0),
        .recovery_rd_addr_i(`RV64_REG_X0),
        .*
    );

    integer response_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_done_q <= 4'b0000;
            read_data_q <= {4*`RV64_XLEN{1'b0}};
            read_pending_q <= 4'b0000;
            read_pending_poison_q <= 4'b0000;
            read_ack_q <= 4'b0000;
            read_poison_q <= 4'b0000;
            read_addr_q <=
                {4*`RV64_REG_ADDR_WIDTH{1'b0}};
        end else if (flush_i || squash_frontend_i ||
                     (|allocation_valid_o)) begin
            read_done_q <= 4'b0000;
            read_data_q <= {4*`RV64_XLEN{1'b0}};
            read_ack_q <= gpr_read_ack_i;
            read_poison_q <= (flush_i || squash_frontend_i) ?
                             gpr_read_ack_i :
                             (gpr_read_ack_i & read_pending_poison_q);
        end else begin
            read_ack_q <= gpr_read_ack_i;
            read_poison_q <= gpr_read_ack_i & read_pending_poison_q;
            for (response_port = 0; response_port < 4;
                 response_port = response_port + 1) begin
                if (read_ack_q[response_port] &&
                    !read_poison_q[response_port] &&
                    gpr_read_valid_i[response_port]) begin
                    read_done_q[response_port] <= 1'b1;
                    read_data_q[
                        response_port*`RV64_XLEN +: `RV64_XLEN] <=
                        gpr_read_data_i[
                            response_port*`RV64_XLEN +: `RV64_XLEN];
                end
            end
        end

        if (rst_n) begin
            for (response_port = 0; response_port < 4;
                 response_port = response_port + 1) begin
                if (gpr_read_ack_i[response_port]) begin
                    read_pending_q[response_port] <= 1'b0;
                    read_pending_poison_q[response_port] <= 1'b0;
                end else if (gpr_read_req_o[response_port]) begin
                    read_pending_q[response_port] <= 1'b1;
                    if (flush_i || squash_frontend_i)
                        read_pending_poison_q[response_port] <= 1'b1;
                    read_addr_q[
                        response_port*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH] <= gpr_read_addr_o[
                            response_port*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH];
                end
            end
        end
    end

endmodule
