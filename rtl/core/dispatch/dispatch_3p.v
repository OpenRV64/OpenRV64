`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

// Three-pipe dispatch with a small decoded-instruction queue.  Frontend input
// is three-wide; the queue can present the oldest three entries to issue.  All
// issue/allocation is one strict program-order prefix.
module openrv64_dispatch_3p #(
    parameter integer QUEUE_DEPTH = 6,
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer MAX_READS_PER_REG = 2,
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

    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*64-1:0]              allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0] allocation_meta_o,

    input  wire [2:0]                   pipe_ready_i,
    input  wire [1:0]                   forward_valid_i,
    input  wire [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr_i,
    output wire [2:0]                   pipe_valid_o,
    output wire [3*64-1:0]              pipe_id_o,
    output wire [3*RETIRE_SLOT_WIDTH-1:0] pipe_slot_o,
    output wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,

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

    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        payload_q [0:QUEUE_DEPTH-1];
    reg uses_rs1_q [0:QUEUE_DEPTH-1];
    reg uses_rs2_q [0:QUEUE_DEPTH-1];
    reg [COUNT_WIDTH-1:0] count_q;

    wire [2:0] candidate_valid = {
        (count_q > 2),
        (count_q > 1),
        (count_q > 0)
    };
    wire [2:0] candidate_uses_rs1 = {
        (count_q > 2) ? uses_rs1_q[2] : 1'b0,
        (count_q > 1) ? uses_rs1_q[1] : 1'b0,
        (count_q > 0) ? uses_rs1_q[0] : 1'b0
    };
    wire [2:0] candidate_uses_rs2 = {
        (count_q > 2) ? uses_rs2_q[2] : 1'b0,
        (count_q > 1) ? uses_rs2_q[1] : 1'b0,
        (count_q > 0) ? uses_rs2_q[0] : 1'b0
    };

    reg [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] candidate_payload;
    integer payload_idx;
    always_comb begin
        candidate_payload =
            {3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        for (payload_idx = 0; payload_idx < 3; payload_idx = payload_idx + 1) begin
            if (count_q > payload_idx) begin
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[payload_idx];
                // Six selectors are packed rs1,rs2 for candidate 0, then 1,2.
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 168 +: 64] =
                    gpr_read_data_i[(payload_idx*2+0)*`RV64_XLEN +: `RV64_XLEN];
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 104 +: 64] =
                    gpr_read_data_i[(payload_idx*2+1)*`RV64_XLEN +: `RV64_XLEN];
            end
        end
    end

    genvar read_lane;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_read_addr
            assign gpr_read_addr_o[
                (read_lane*2+0)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = candidate_payload[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +:
                `RV64_REG_ADDR_WIDTH];
            assign gpr_read_addr_o[
                (read_lane*2+1)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = candidate_payload[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +:
                `RV64_REG_ADDR_WIDTH];
        end
    endgenerate

    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs1_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5]
    };
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs2_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5]
    };
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rd_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5]
    };
    wire [2:0] candidate_reg_write = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17]
    };
    wire [2:0] candidate_hazard_free;
    wire [2:0] candidate_fire;

    function automatic [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed_pipe;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            if (payload[16] || payload[15]) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_MEM;
            end else if (payload[10] || payload[9] || payload[8] ||
                         payload[7] || payload[6] || payload[5] ||
                         payload[4] || payload[14] || payload[13]) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (payload[34:32] == `RV64_ALU_EXT_M) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_EX1;
            end else begin
                fixed_pipe = 2'd3;
            end
        end
    endfunction

    function automatic [`OPENRV64_EXEC_PIPE_WIDTH-1:0] choose_base_pipe;
        input [2:0] used;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] next_fixed;
        input preferred_valid;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] preferred_pipe;
        begin
            if (preferred_valid) begin
                choose_base_pipe = preferred_pipe;
            end else if (!used[0] && !used[1]) begin
                if (next_fixed == `OPENRV64_EXEC_PIPE_EX0)
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX1;
                else if (next_fixed == `OPENRV64_EXEC_PIPE_EX1)
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
                else
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (!used[0]) begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (!used[1]) begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX1;
            end else begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end
        end
    endfunction

    function automatic [1:0] forward_match;
        input uses_rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
        input uses_rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
        input [1:0] forward_valid;
        input [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr;
        integer forward_idx;
        reg [`RV64_REG_ADDR_WIDTH-1:0] forward_rd;
        begin
            forward_match = 2'b00;
            for (forward_idx = 0; forward_idx < 2;
                 forward_idx = forward_idx + 1) begin
                forward_rd = forward_rd_addr[
                    forward_idx*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
                if (forward_valid[forward_idx] &&
                    (forward_rd != `RV64_REG_X0) &&
                    ((uses_rs1 && (rs1_addr == forward_rd)) ||
                     (uses_rs2 && (rs2_addr == forward_rd)))) begin
                    forward_match[forward_idx] = 1'b1;
                end
            end
        end
    endfunction

    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload0 =
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload1 =
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload2 =
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed0 = fixed_pipe(payload0);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed1 = fixed_pipe(payload1);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed2 = fixed_pipe(payload2);
    wire [1:0] forward_match0 = forward_match(
        candidate_uses_rs1[0],
        candidate_rs1_addr[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[0],
        candidate_rs2_addr[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire [1:0] forward_match1 = forward_match(
        candidate_uses_rs1[1],
        candidate_rs1_addr[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[1],
        candidate_rs2_addr[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire [1:0] forward_match2 = forward_match(
        candidate_uses_rs1[2],
        candidate_rs1_addr[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[2],
        candidate_rs2_addr[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire forward_preferred0 = (forward_match0 == 2'b01) ||
                              (forward_match0 == 2'b10);
    wire forward_preferred1 = (forward_match1 == 2'b01) ||
                              (forward_match1 == 2'b10);
    wire forward_preferred2 = (forward_match2 == 2'b01) ||
                              (forward_match2 == 2'b10);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe0 =
        forward_match0[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe1 =
        forward_match1[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe2 =
        forward_match2[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected0 =
        (fixed0 != 2'd3) ? fixed0 :
        choose_base_pipe(3'b000, fixed1,
                         forward_preferred0, forward_pipe0);
    wire [2:0] used0 = candidate_valid[0] ?
        (3'b001 << selected0) : 3'b000;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected1 =
        (fixed1 != 2'd3) ? fixed1 :
        choose_base_pipe(used0, fixed2,
                         forward_preferred1, forward_pipe1);
    wire [2:0] used1 = used0 | (candidate_valid[1] ?
        (3'b001 << selected1) : 3'b000);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected2 =
        (fixed2 != 2'd3) ? fixed2 :
        choose_base_pipe(used1, 2'd3,
                         forward_preferred2, forward_pipe2);
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe = {
        selected2,
        selected1,
        selected0
    };

    openrv64_dispatch_reg_map_3p #(
        .MAX_READS_PER_REG(MAX_READS_PER_REG)
    ) u_reg_map (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(flush_i),
        .candidate_valid_i(candidate_valid),
        .candidate_uses_rs1_i(candidate_uses_rs1),
        .candidate_uses_rs2_i(candidate_uses_rs2),
        .candidate_rs1_addr_i(candidate_rs1_addr),
        .candidate_rs2_addr_i(candidate_rs2_addr),
        .candidate_reg_write_i(candidate_reg_write),
        .candidate_rd_addr_i(candidate_rd_addr),
        .candidate_pipe_i(candidate_pipe),
        .forward_valid_i(forward_valid_i),
        .forward_rd_addr_i(forward_rd_addr_i),
        .candidate_hazard_free_o(candidate_hazard_free),
        .raw_hazard_o(raw_hazard_o),
        .waw_hazard_o(waw_hazard_o),
        .read_port_hazard_o(read_port_hazard_o),
        .allocation_fire_i(candidate_fire),
        .retire_valid_i(retire_valid_i),
        .retire_reg_write_i(retire_reg_write_i),
        .retire_rd_addr_i(retire_rd_addr_i),
        .write_busy_o(write_busy_o)
    );

    wire [2:0] candidate_hard;
    openrv64_dispatch_control_3p #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH)
    ) u_control (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .candidate_valid_i(candidate_valid),
        .candidate_hazard_free_i(candidate_hazard_free),
        .candidate_pipe_i(candidate_pipe),
        .candidate_id_i(allocation_id_i),
        .candidate_slot_i(allocation_slot_i),
        .candidate_payload_i(candidate_payload),
        .allocation_ready_i(allocation_ready_i),
        .pipe_ready_i(pipe_ready_i),
        .retire_valid_i(retire_valid_i),
        .retire_hard_i(retire_hard_i),
        .candidate_hard_o(candidate_hard),
        .candidate_fire_o(candidate_fire),
        .barrier_active_o(barrier_active_o),
        .pipe_valid_o(pipe_valid_o),
        .pipe_id_o(pipe_id_o),
        .pipe_slot_o(pipe_slot_o),
        .pipe_payload_o(pipe_payload_o)
    );

    assign allocation_valid_o = candidate_fire;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_meta
            assign allocation_meta_o[
                read_lane*`OPENRV64_RETIRE_META_WIDTH +:
                `OPENRV64_RETIRE_META_WIDTH] = {
                candidate_hard[read_lane],
                candidate_uses_rs2[read_lane],
                candidate_uses_rs1[read_lane],
                candidate_payload[
                    read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]
            };
        end
    endgenerate

    wire [2:0] issue_count =
        {2'd0, candidate_fire[0]} +
        {2'd0, candidate_fire[1]} +
        {2'd0, candidate_fire[2]};
    wire [COUNT_WIDTH-1:0] remaining_count = count_q - issue_count;
    wire [COUNT_WIDTH:0] free_after_issue = QUEUE_DEPTH - remaining_count;
    assign decode_ready_o[0] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 1);
    assign decode_ready_o[1] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 2);
    assign decode_ready_o[2] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 3);
    wire decode_fire0 = decode_valid_i[0] && decode_ready_o[0];
    wire decode_fire1 = decode_valid_i[1] && decode_ready_o[1] && decode_fire0;
    wire decode_fire2 = decode_valid_i[2] && decode_ready_o[2] && decode_fire1;
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};

    integer queue_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                payload_q[queue_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[queue_idx] <= 1'b0;
                uses_rs2_q[queue_idx] <= 1'b0;
            end
        end else if (flush_i || squash_frontend_i) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                payload_q[queue_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[queue_idx] <= 1'b0;
                uses_rs2_q[queue_idx] <= 1'b0;
            end
        end else begin
            count_q <= remaining_count + decode_count;

            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                if (queue_idx < remaining_count) begin
                    payload_q[queue_idx] <= payload_q[queue_idx + issue_count];
                    uses_rs1_q[queue_idx] <=
                        uses_rs1_q[queue_idx + issue_count];
                    uses_rs2_q[queue_idx] <=
                        uses_rs2_q[queue_idx + issue_count];
                end else if (decode_fire0 &&
                             (queue_idx == remaining_count)) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[0];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[0];
                end else if (decode_fire1 &&
                             (queue_idx == (remaining_count + 1))) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[1];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[1];
                end else if (decode_fire2 &&
                             (queue_idx == (remaining_count + 2))) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[2];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[2];
                end else begin
                    payload_q[queue_idx] <=
                        {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                    uses_rs1_q[queue_idx] <= 1'b0;
                    uses_rs2_q[queue_idx] <= 1'b0;
                end
            end
        end
    end

    assign queue_count_o = count_q;
    wire unused_release_sources = |{
        retire_uses_rs1_i,
        retire_uses_rs2_i,
        retire_rs1_addr_i,
        retire_rs2_addr_i
    };

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i && !squash_frontend_i) begin
            if ((decode_valid_i != 3'b000) &&
                (decode_valid_i != 3'b001) &&
                (decode_valid_i != 3'b011) &&
                (decode_valid_i != 3'b111))
                $fatal(1, "3p decode input must be a contiguous prefix");
            if ((count_q + decode_count - issue_count) > QUEUE_DEPTH)
                $fatal(1, "3p dispatch queue overflow");
        end
    end
`endif

endmodule
