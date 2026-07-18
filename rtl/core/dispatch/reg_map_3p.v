`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

// Conservative three-wide register ownership map.  A nonzero destination is
// busy from issue through retirement.  Sources and destinations stall on any
// busy writer, and younger candidates also see writers accepted earlier in
// the same bundle.  Operand values are captured at issue, so WAR tracking is
// unnecessary.
module openrv64_dispatch_reg_map_3p #(
    parameter integer MAX_READS_PER_REG = 2
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         clear_i,

    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_uses_rs1_i,
    input  wire [2:0]                   candidate_uses_rs2_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs1_addr_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs2_addr_i,
    input  wire [2:0]                   candidate_reg_write_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rd_addr_i,
    input  wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe_i,
    input  wire [1:0]                   forward_valid_i,
    input  wire [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr_i,
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

    // A busy source is readable only when the selected execution pipe itself
    // owns the immediately preceding completion for that architectural rd.
    // This compares control metadata only; result data remains inside EX0/EX1.
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

    integer port_idx;
    reg [31:0] retire_write_hot;
    reg [31:0] allocation_write_hot;
    reg [`RV64_REG_ADDR_WIDTH-1:0] port_addr;
    always @* begin
        retire_write_hot = 32'd0;
        allocation_write_hot = 32'd0;

        for (port_idx = 0; port_idx < 3; port_idx = port_idx + 1) begin
            port_addr = retire_rd_addr_i[
                port_idx*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH];
            if (retire_valid_i[port_idx] &&
                retire_reg_write_i[port_idx] &&
                (port_addr != `RV64_REG_X0)) begin
                retire_write_hot[port_addr] = 1'b1;
            end

            port_addr = candidate_rd_addr_i[
                port_idx*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH];
            if (allocation_fire_i[port_idx] &&
                candidate_reg_write_i[port_idx] &&
                (port_addr != `RV64_REG_X0)) begin
                allocation_write_hot[port_addr] = 1'b1;
            end
        end
    end

    wire [31:0] busy_after_retire = write_busy_q & ~retire_write_hot;

    wire writes0 = candidate_valid_i[0] && candidate_reg_write_i[0] &&
                   (rd_addr0 != `RV64_REG_X0);
    wire reads_rs10 = candidate_valid_i[0] && candidate_uses_rs1_i[0] &&
                      (rs1_addr0 != `RV64_REG_X0);
    wire reads_rs20 = candidate_valid_i[0] && candidate_uses_rs2_i[0] &&
                      (rs2_addr0 != `RV64_REG_X0);
    wire forward_rs10 = reads_rs10 &&
        same_pipe_forward(candidate_pipe0, rs1_addr0,
                          forward_valid_i, forward_rd_addr_i);
    wire forward_rs20 = reads_rs20 &&
        same_pipe_forward(candidate_pipe0, rs2_addr0,
                          forward_valid_i, forward_rd_addr_i);
    wire raw0 = (reads_rs10 && busy_after_retire[rs1_addr0] &&
                 !forward_rs10) ||
                (reads_rs20 && busy_after_retire[rs2_addr0] &&
                 !forward_rs20);
    wire waw0 = writes0 && busy_after_retire[rd_addr0];
    wire [2:0] reads0_rs1 = count_reads(
        rs1_addr0, 3'b001 & {3{candidate_valid_i[0]}},
        candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads0_rs2 = count_reads(
        rs2_addr0, 3'b001 & {3{candidate_valid_i[0]}},
        candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port0 = candidate_valid_i[0] &&
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
        same_pipe_forward(candidate_pipe1, rs1_addr1,
                          forward_valid_i, forward_rd_addr_i);
    wire forward_rs21 = reads_rs21 &&
        same_pipe_forward(candidate_pipe1, rs2_addr1,
                          forward_valid_i, forward_rd_addr_i);
    wire raw_existing1 =
        (reads_rs11 && busy_after_retire[rs1_addr1] && !forward_rs11) ||
        (reads_rs21 && busy_after_retire[rs2_addr1] && !forward_rs21);
    // Never treat a same-bundle producer as the previous-cycle result.
    wire raw_bundle1 = (reads_rs11 && write_hot0[rs1_addr1]) ||
                       (reads_rs21 && write_hot0[rs2_addr1]);
    wire [31:0] busy_before1 = busy_after_retire | write_hot0;
    wire raw1 = candidate_valid_i[1] &&
                (raw_existing1 || raw_bundle1);
    wire waw1 = candidate_valid_i[1] && writes1 &&
                busy_before1[rd_addr1];
    wire [2:0] include1 = {1'b0, candidate_valid_i[1], accept0};
    wire [2:0] reads1_rs1 = count_reads(
        rs1_addr1, include1, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads1_rs2 = count_reads(
        rs2_addr1, include1, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port1 = candidate_valid_i[1] &&
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
        same_pipe_forward(candidate_pipe2, rs1_addr2,
                          forward_valid_i, forward_rd_addr_i);
    wire forward_rs22 = reads_rs22 &&
        same_pipe_forward(candidate_pipe2, rs2_addr2,
                          forward_valid_i, forward_rd_addr_i);
    wire raw_existing2 =
        (reads_rs12 && busy_after_retire[rs1_addr2] && !forward_rs12) ||
        (reads_rs22 && busy_after_retire[rs2_addr2] && !forward_rs22);
    wire raw_bundle2 =
        (reads_rs12 && (write_hot0[rs1_addr2] || write_hot1[rs1_addr2])) ||
        (reads_rs22 && (write_hot0[rs2_addr2] || write_hot1[rs2_addr2]));
    wire [31:0] busy_before2 = busy_after_retire | write_hot0 | write_hot1;
    wire raw2 = candidate_valid_i[2] &&
                (raw_existing2 || raw_bundle2);
    wire waw2 = candidate_valid_i[2] && writes2 &&
                busy_before2[rd_addr2];
    wire [2:0] include2 = {candidate_valid_i[2], accept1, accept0};
    wire [2:0] reads2_rs1 = count_reads(
        rs1_addr2, include2, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire [2:0] reads2_rs2 = count_reads(
        rs2_addr2, include2, candidate_uses_rs1_i, candidate_uses_rs2_i,
        candidate_rs1_addr_i, candidate_rs2_addr_i);
    wire read_port2 = candidate_valid_i[2] &&
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_busy_q <= 32'd0;
        end else if (clear_i) begin
            write_busy_q <= 32'd0;
        end else begin
            write_busy_q <= busy_after_retire | allocation_write_hot;
            write_busy_q[`RV64_REG_X0] <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !clear_i) begin
            if ((allocation_fire_i & ~candidate_hazard_free_o) != 3'b000)
                $fatal(1, "3p register map allocated a hazardous candidate");
            if ((allocation_fire_i != 3'b000) &&
                (allocation_fire_i != 3'b001) &&
                (allocation_fire_i != 3'b011) &&
                (allocation_fire_i != 3'b111))
                $fatal(1, "3p register allocation must be a contiguous prefix");
        end
    end
`endif

endmodule
