`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// Three-wide register ownership map.  A nonzero destination is busy from issue
// through retirement.  The default mode stalls both sources and destinations
// on an existing writer.  RELAX_WAW counts writers instead: ordered writers may
// coexist, while a source remains blocked until its youngest producer is
// unambiguous.  Experimental RELAX_HAZARDS permits a producer-tagged external
// map to identify that youngest writer directly and removes the synthetic read
// fanout limit.  Operand values are captured at issue, so WAR tracking is
// unnecessary.
module openrv64_dispatch_reg_map_3p #(
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer WRITER_COUNT_WIDTH = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         clear_i,

    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_branch_i,
    input  wire [2:0]                   candidate_uses_rs1_i,
    input  wire [2:0]                   candidate_uses_rs2_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs1_addr_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs2_addr_i,
    // Packed rs1,rs2 readiness for candidates 0,1,2.  A set bit means the
    // caller has already captured the exact operand value for this stable
    // queue entry, so an outstanding architectural writer cannot block it.
    input  wire [5:0]                   candidate_operand_ready_i,
    input  wire [2:0]                   candidate_reg_write_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rd_addr_i,
    input  wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe_i,
    input  wire [1:0]                   forward_valid_i,
    input  wire [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr_i,
    input  wire [2:0]                   completion_forward_valid_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0]
                                        completion_forward_rd_addr_i,
    input  wire [2:0]                   branch_completion_forward_valid_i,
    input  wire [31:0]                  forward_map_valid_i,
    output wire [2:0]                   candidate_hazard_free_o,
    output wire [2:0]                   raw_hazard_o,
    output wire [2:0]                   waw_hazard_o,
    output wire [2:0]                   read_port_hazard_o,
    input  wire [2:0]                   allocation_fire_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_reg_write_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_i,

    output wire [31:0]                  write_busy_o
);

    reg [31:0] write_busy_q;
    reg [WRITER_COUNT_WIDTH-1:0] writer_count_q [0:31];

    wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr0 =
        candidate_rs1_addr_i[0*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr1 =
        candidate_rs1_addr_i[1*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr2 =
        candidate_rs1_addr_i[2*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr0 =
        candidate_rs2_addr_i[0*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr1 =
        candidate_rs2_addr_i[1*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr2 =
        candidate_rs2_addr_i[2*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr0 =
        candidate_rd_addr_i[0*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr1 =
        candidate_rd_addr_i[1*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr2 =
        candidate_rd_addr_i[2*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH];

    function automatic [2:0] count_reads;
        input [`RV64_REG_ADDR_WIDTH-1:0] addr;
        input [2:0] include_mask;
        input [2:0] uses_rs1;
        input [2:0] uses_rs2;
        input [3*`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
        input [3*`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
        integer idx;
        begin
            count_reads = 3'd0;
            if (addr != `RV64_REG_X0) begin
                for (idx = 0; idx < 3; idx = idx + 1) begin
                    if (include_mask[idx] && uses_rs1[idx] &&
                        (rs1_addr[idx*`RV64_REG_ADDR_WIDTH +:
                                  `RV64_REG_ADDR_WIDTH] == addr)) begin
                        count_reads = count_reads + 3'd1;
                    end
                    if (include_mask[idx] && uses_rs2[idx] &&
                        (rs2_addr[idx*`RV64_REG_ADDR_WIDTH +:
                                  `RV64_REG_ADDR_WIDTH] == addr)) begin
                        count_reads = count_reads + 3'd1;
                    end
                end
            end
        end
    endfunction

    function automatic completion_forward_match;
        input [`RV64_REG_ADDR_WIDTH-1:0] source_addr;
        input [2:0] completion_valid;
        input [3*`RV64_REG_ADDR_WIDTH-1:0] completion_rd_addr;
        integer completion_idx;
        begin
            completion_forward_match = 1'b0;
            if (source_addr != `RV64_REG_X0) begin
                for (completion_idx = 0; completion_idx < 3;
                     completion_idx = completion_idx + 1) begin
                    if (completion_valid[completion_idx] &&
                        (completion_rd_addr[
                            completion_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] == source_addr))
                        completion_forward_match = 1'b1;
                end
            end
        end
    endfunction

    // The old narrow bypass accepts only the immediately preceding result on
    // the selected ALU pipe.  The live-completion match accepts a selected
    // completion port on any consumer pipe, while the full map additionally
    // retains arbitrary completed older producers until retirement.
    function automatic same_pipe_forward;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe;
        input [`RV64_REG_ADDR_WIDTH-1:0] source_addr;
        input [1:0] forward_valid;
        input [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr;
        begin
            same_pipe_forward = 1'b0;
            if (source_addr != `RV64_REG_X0) begin
                if ((candidate_pipe == `OPENRV64_EXEC_PIPE_EX0) &&
                    forward_valid[0] &&
                    (forward_rd_addr[0*`RV64_REG_ADDR_WIDTH +:
                                     `RV64_REG_ADDR_WIDTH] == source_addr))
                    same_pipe_forward = 1'b1;
                else if ((candidate_pipe == `OPENRV64_EXEC_PIPE_EX1) &&
                         forward_valid[1] &&
                         (forward_rd_addr[1*`RV64_REG_ADDR_WIDTH +:
                                         `RV64_REG_ADDR_WIDTH] == source_addr))
                    same_pipe_forward = 1'b1;
            end
        end
    endfunction

    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe0 =
        candidate_pipe_i[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe1 =
        candidate_pipe_i[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe2 =
        candidate_pipe_i[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];

    integer retire_port_idx;
    reg [31:0] retire_write_hot;
    reg [`RV64_REG_ADDR_WIDTH-1:0] retire_port_addr;
    always @* begin
        retire_write_hot = 32'd0;

        for (retire_port_idx = 0; retire_port_idx < 3;
             retire_port_idx = retire_port_idx + 1) begin
            retire_port_addr = retire_rd_addr_i[
                retire_port_idx*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH];
            if (retire_valid_i[retire_port_idx] &&
                retire_reg_write_i[retire_port_idx] &&
                (retire_port_addr != `RV64_REG_X0)) begin
                retire_write_hot[retire_port_addr] = 1'b1;
            end
        end
    end

    integer allocation_port_idx;
    reg [31:0] allocation_write_hot;
    reg [`RV64_REG_ADDR_WIDTH-1:0] allocation_port_addr;
    always @* begin
        allocation_write_hot = 32'd0;

        for (allocation_port_idx = 0; allocation_port_idx < 3;
             allocation_port_idx = allocation_port_idx + 1) begin
            allocation_port_addr = candidate_rd_addr_i[
                allocation_port_idx*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH];
            if (allocation_fire_i[allocation_port_idx] &&
                candidate_reg_write_i[allocation_port_idx] &&
                (allocation_port_addr != `RV64_REG_X0)) begin
                allocation_write_hot[allocation_port_addr] = 1'b1;
            end
        end
    end

    // The relaxed-WAW experiment counts outstanding writers so retiring an
    // older writer cannot accidentally clear ownership of a younger writer.
    // Normal forwarding remains conservative while multiple writers exist:
    // without a producer tag, the architectural rd alone cannot identify the
    // youngest value.  RELAX_HAZARDS promises that the external map is tagged
    // to that youngest producer and may therefore bypass this ambiguity test.
    integer count_comb_reg;
    integer count_comb_port;
    reg [2:0] count_comb_retiring;
    reg [31:0] count_busy_after_retire;
    reg [31:0] count_unambiguous_writer;
    always @* begin
        count_busy_after_retire = 32'd0;
        count_unambiguous_writer = 32'd0;
        count_comb_retiring = 3'd0;
        for (count_comb_reg = 1; count_comb_reg < 32;
             count_comb_reg = count_comb_reg + 1) begin
            count_comb_retiring = 3'd0;
            for (count_comb_port = 0; count_comb_port < 3;
                 count_comb_port = count_comb_port + 1) begin
                if (retire_valid_i[count_comb_port] &&
                    retire_reg_write_i[count_comb_port] &&
                    (retire_rd_addr_i[
                        count_comb_port*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH] == count_comb_reg))
                    count_comb_retiring = count_comb_retiring + 3'd1;
            end
            count_busy_after_retire[count_comb_reg] =
                writer_count_q[count_comb_reg] > count_comb_retiring;
            count_unambiguous_writer[count_comb_reg] =
                writer_count_q[count_comb_reg] == 1;
        end
    end

    wire [31:0] busy_after_retire = (RELAX_WAW != 0) ?
        count_busy_after_retire : (write_busy_q & ~retire_write_hot);

    wire writes0 = candidate_valid_i[0] && candidate_reg_write_i[0] &&
                   (rd_addr0 != `RV64_REG_X0);
    wire reads_rs10 = candidate_valid_i[0] && candidate_uses_rs1_i[0] &&
                      (rs1_addr0 != `RV64_REG_X0);
    wire reads_rs20 = candidate_valid_i[0] && candidate_uses_rs2_i[0] &&
                      (rs2_addr0 != `RV64_REG_X0);
    wire forward_rs10 = reads_rs10 &&
        (candidate_operand_ready_i[0] ||
         (candidate_branch_i[0] &&
          completion_forward_match(rs1_addr0,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs1_addr0]) &&
          (forward_map_valid_i[rs1_addr0] ||
           completion_forward_match(rs1_addr0,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe0, rs1_addr0,
                             forward_valid_i, forward_rd_addr_i))));
    wire forward_rs20 = reads_rs20 &&
        (candidate_operand_ready_i[1] ||
         (candidate_branch_i[0] &&
          completion_forward_match(rs2_addr0,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs2_addr0]) &&
          (forward_map_valid_i[rs2_addr0] ||
           completion_forward_match(rs2_addr0,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe0, rs2_addr0,
                             forward_valid_i, forward_rd_addr_i))));
    wire raw0 = (reads_rs10 && busy_after_retire[rs1_addr0] &&
                 !forward_rs10) ||
                (reads_rs20 && busy_after_retire[rs2_addr0] &&
                 !forward_rs20);
    wire waw0 = (RELAX_WAW == 0) && writes0 &&
                busy_after_retire[rd_addr0];
    wire [2:0] reads0_rs1 = count_reads(
        rs1_addr0, 3'b001 & {3{candidate_valid_i[0]}},
        candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads0_rs2 = count_reads(
        rs2_addr0, 3'b001 & {3{candidate_valid_i[0]}},
        candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port0 = (RELAX_HAZARDS == 0) && candidate_valid_i[0] &&
        ((reads_rs10 && (reads0_rs1 > MAX_READS_PER_REG)) ||
         (reads_rs20 && (reads0_rs2 > MAX_READS_PER_REG)));
    wire hazard_free0 = !(raw0 || waw0 || read_port0);
    wire accept0 = candidate_valid_i[0] && hazard_free0;
    wire [31:0] write_hot0 = (accept0 && writes0) ?
        (32'h0000_0001 << rd_addr0) : 32'd0;

    wire writes1 = candidate_valid_i[1] && candidate_reg_write_i[1] &&
                   (rd_addr1 != `RV64_REG_X0);
    wire reads_rs11 = candidate_valid_i[1] && candidate_uses_rs1_i[1] &&
                      (rs1_addr1 != `RV64_REG_X0);
    wire reads_rs21 = candidate_valid_i[1] && candidate_uses_rs2_i[1] &&
                      (rs2_addr1 != `RV64_REG_X0);
    wire forward_rs11 = reads_rs11 &&
        (candidate_operand_ready_i[2] ||
         (candidate_branch_i[1] &&
          completion_forward_match(rs1_addr1,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs1_addr1]) &&
          (forward_map_valid_i[rs1_addr1] ||
           completion_forward_match(rs1_addr1,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe1, rs1_addr1,
                             forward_valid_i, forward_rd_addr_i))));
    wire forward_rs21 = reads_rs21 &&
        (candidate_operand_ready_i[3] ||
         (candidate_branch_i[1] &&
          completion_forward_match(rs2_addr1,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs2_addr1]) &&
          (forward_map_valid_i[rs2_addr1] ||
           completion_forward_match(rs2_addr1,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe1, rs2_addr1,
                             forward_valid_i, forward_rd_addr_i))));
    wire raw_existing1 =
        (reads_rs11 && busy_after_retire[rs1_addr1] && !forward_rs11) ||
        (reads_rs21 && busy_after_retire[rs2_addr1] && !forward_rs21);
    // Never treat a same-bundle producer as the previous-cycle result.
    wire raw_bundle1 = (reads_rs11 && write_hot0[rs1_addr1]) ||
                       (reads_rs21 && write_hot0[rs2_addr1]);
    wire [31:0] busy_before1 = busy_after_retire | write_hot0;
    wire raw1 = candidate_valid_i[1] &&
                (raw_existing1 || raw_bundle1);
    wire waw1 = (RELAX_WAW == 0) && candidate_valid_i[1] && writes1 &&
                busy_before1[rd_addr1];
    wire [2:0] include1 = {1'b0, candidate_valid_i[1], accept0};
    wire [2:0] reads1_rs1 = count_reads(
        rs1_addr1, include1, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads1_rs2 = count_reads(
        rs2_addr1, include1, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port1 = (RELAX_HAZARDS == 0) && candidate_valid_i[1] &&
        ((reads_rs11 && (reads1_rs1 > MAX_READS_PER_REG)) ||
         (reads_rs21 && (reads1_rs2 > MAX_READS_PER_REG)));
    wire hazard_free1 = hazard_free0 && !(raw1 || waw1 || read_port1);
    wire accept1 = candidate_valid_i[1] && hazard_free1;
    wire [31:0] write_hot1 = (accept1 && writes1) ?
        (32'h0000_0001 << rd_addr1) : 32'd0;

    wire writes2 = candidate_valid_i[2] && candidate_reg_write_i[2] &&
                   (rd_addr2 != `RV64_REG_X0);
    wire reads_rs12 = candidate_valid_i[2] && candidate_uses_rs1_i[2] &&
                      (rs1_addr2 != `RV64_REG_X0);
    wire reads_rs22 = candidate_valid_i[2] && candidate_uses_rs2_i[2] &&
                      (rs2_addr2 != `RV64_REG_X0);
    wire forward_rs12 = reads_rs12 &&
        (candidate_operand_ready_i[4] ||
         (candidate_branch_i[2] &&
          completion_forward_match(rs1_addr2,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs1_addr2]) &&
          (forward_map_valid_i[rs1_addr2] ||
           completion_forward_match(rs1_addr2,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe2, rs1_addr2,
                             forward_valid_i, forward_rd_addr_i))));
    wire forward_rs22 = reads_rs22 &&
        (candidate_operand_ready_i[5] ||
         (candidate_branch_i[2] &&
          completion_forward_match(rs2_addr2,
              branch_completion_forward_valid_i,
              completion_forward_rd_addr_i)) ||
         (((RELAX_WAW == 0) || (RELAX_HAZARDS != 0) ||
           count_unambiguous_writer[rs2_addr2]) &&
          (forward_map_valid_i[rs2_addr2] ||
           completion_forward_match(rs2_addr2,
                                    completion_forward_valid_i,
                                    completion_forward_rd_addr_i) ||
           same_pipe_forward(candidate_pipe2, rs2_addr2,
                             forward_valid_i, forward_rd_addr_i))));
    wire raw_existing2 =
        (reads_rs12 && busy_after_retire[rs1_addr2] && !forward_rs12) ||
        (reads_rs22 && busy_after_retire[rs2_addr2] && !forward_rs22);
    wire raw_bundle2 =
        (reads_rs12 && (write_hot0[rs1_addr2] || write_hot1[rs1_addr2])) ||
        (reads_rs22 && (write_hot0[rs2_addr2] || write_hot1[rs2_addr2]));
    wire [31:0] busy_before2 = busy_after_retire | write_hot0 | write_hot1;
    wire raw2 = candidate_valid_i[2] &&
                (raw_existing2 || raw_bundle2);
    wire waw2 = (RELAX_WAW == 0) && candidate_valid_i[2] && writes2 &&
                busy_before2[rd_addr2];
    wire [2:0] include2 = {candidate_valid_i[2], accept1, accept0};
    wire [2:0] reads2_rs1 = count_reads(
        rs1_addr2, include2, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads2_rs2 = count_reads(
        rs2_addr2, include2, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port2 = (RELAX_HAZARDS == 0) && candidate_valid_i[2] &&
        ((reads_rs12 && (reads2_rs1 > MAX_READS_PER_REG)) ||
         (reads_rs22 && (reads2_rs2 > MAX_READS_PER_REG)));
    wire hazard_free2 = hazard_free1 && !(raw2 || waw2 || read_port2);

    assign raw_hazard_o = {raw2, raw1, raw0};
    assign waw_hazard_o = {waw2, waw1, waw0};
    assign read_port_hazard_o = {read_port2, read_port1, read_port0};
    assign candidate_hazard_free_o = {
        hazard_free2,
        hazard_free1,
        hazard_free0
    };
    assign write_busy_o = write_busy_q;

    integer writer_reg_idx;
    integer writer_port_idx;
    integer writer_alloc_count;
    integer writer_retire_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_busy_q <= 32'd0;
            for (writer_reg_idx = 0; writer_reg_idx < 32;
                 writer_reg_idx = writer_reg_idx + 1)
                writer_count_q[writer_reg_idx] <=
                    {WRITER_COUNT_WIDTH{1'b0}};
        end else if (clear_i) begin
            write_busy_q <= 32'd0;
            for (writer_reg_idx = 0; writer_reg_idx < 32;
                 writer_reg_idx = writer_reg_idx + 1)
                writer_count_q[writer_reg_idx] <=
                    {WRITER_COUNT_WIDTH{1'b0}};
        end else if (RELAX_WAW != 0) begin
            for (writer_reg_idx = 0; writer_reg_idx < 32;
                 writer_reg_idx = writer_reg_idx + 1) begin
                writer_alloc_count = 0;
                writer_retire_count = 0;
                for (writer_port_idx = 0; writer_port_idx < 3;
                     writer_port_idx = writer_port_idx + 1) begin
                    if (allocation_fire_i[writer_port_idx] &&
                        candidate_reg_write_i[writer_port_idx] &&
                        (candidate_rd_addr_i[
                            writer_port_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] == writer_reg_idx) &&
                        (writer_reg_idx != `RV64_REG_X0))
                        writer_alloc_count = writer_alloc_count + 1;
                    if (retire_valid_i[writer_port_idx] &&
                        retire_reg_write_i[writer_port_idx] &&
                        (retire_rd_addr_i[
                            writer_port_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] == writer_reg_idx) &&
                        (writer_reg_idx != `RV64_REG_X0))
                        writer_retire_count = writer_retire_count + 1;
                end
                writer_count_q[writer_reg_idx] <=
                    writer_count_q[writer_reg_idx] + writer_alloc_count -
                    writer_retire_count;
                write_busy_q[writer_reg_idx] <=
                    (writer_count_q[writer_reg_idx] + writer_alloc_count -
                     writer_retire_count) != 0;
            end
            writer_count_q[`RV64_REG_X0] <=
                {WRITER_COUNT_WIDTH{1'b0}};
            write_busy_q[`RV64_REG_X0] <= 1'b0;
        end else begin
            write_busy_q <= busy_after_retire | allocation_write_hot;
            write_busy_q[`RV64_REG_X0] <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    integer assert_writer_reg;
    integer assert_writer_port;
    integer assert_alloc_count;
    integer assert_retire_count;
    always @(posedge clk) begin
        if (rst_n && !clear_i) begin
            if ((allocation_fire_i & ~candidate_hazard_free_o) != 3'b000)
                $fatal(1, "3p register map allocated a hazardous candidate");
            if ((allocation_fire_i != 3'b000) &&
                (allocation_fire_i != 3'b001) &&
                (allocation_fire_i != 3'b011) &&
                (allocation_fire_i != 3'b111))
                $fatal(1, "3p register allocation must be a contiguous prefix");

            if (RELAX_WAW != 0) begin
                for (assert_writer_reg = 1; assert_writer_reg < 32;
                     assert_writer_reg = assert_writer_reg + 1) begin
                    assert_alloc_count = 0;
                    assert_retire_count = 0;
                    for (assert_writer_port = 0; assert_writer_port < 3;
                         assert_writer_port = assert_writer_port + 1) begin
                        if (allocation_fire_i[assert_writer_port] &&
                            candidate_reg_write_i[assert_writer_port] &&
                            (candidate_rd_addr_i[
                                assert_writer_port*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] == assert_writer_reg))
                            assert_alloc_count = assert_alloc_count + 1;
                        if (retire_valid_i[assert_writer_port] &&
                            retire_reg_write_i[assert_writer_port] &&
                            (retire_rd_addr_i[
                                assert_writer_port*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] == assert_writer_reg))
                            assert_retire_count = assert_retire_count + 1;
                    end
                    if ((writer_count_q[assert_writer_reg] +
                         assert_alloc_count) < assert_retire_count)
                        $fatal(1,
                               "3p relaxed WAW writer count underflow x%0d",
                               assert_writer_reg);
                    if ((writer_count_q[assert_writer_reg] +
                         assert_alloc_count - assert_retire_count) >=
                        (1 << WRITER_COUNT_WIDTH))
                        $fatal(1,
                               "3p relaxed WAW writer count overflow x%0d",
                               assert_writer_reg);
                end
            end
        end
    end
`endif

endmodule
