`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_dispatch_reg_map #(
    parameter ENABLE_FORWARDING = 0
) (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             clear_i,

    input  wire                             alloc_valid_i,
    input  wire                             alloc_fire_i,
    input  wire                             alloc_uses_rs1_i,
    input  wire                             alloc_uses_rs2_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] alloc_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] alloc_rs2_addr_i,
    input  wire                             alloc_reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] alloc_rd_addr_i,
    input  wire [31:0]                      alloc_read_hot_i,
    // Separate one-hot stage ownership marks preserve producer identity.
    // ORing these together would make "one of the owners is forwardable"
    // indistinguishable from "the sole owner is forwardable."
    input  wire [31:0]                      forward_ex_write_hot_i,
    input  wire [31:0]                      forward_mem_write_hot_i,
    output wire [31:0]                      alloc_read_hot_o,

    input  wire                             retire_valid_i,
    input  wire                             retire_uses_rs1_i,
    input  wire                             retire_uses_rs2_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_i,
    input  wire                             retire_reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_i,

    input  wire                             rollback_valid_i,
    input  wire                             rollback_uses_rs1_i,
    input  wire                             rollback_uses_rs2_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rollback_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rollback_rs2_addr_i,
    input  wire                             rollback_reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rollback_rd_addr_i,

    output wire                             raw_hazard_o,
    output wire                             war_hazard_o,
    output wire                             waw_hazard_o,
    output wire                             read_full_hazard_o,
    output wire                             can_allocate_o
);

    localparam [3:0] READ_COUNT_MAX = 4'hf;
    localparam [3:0] WRITE_COUNT_MAX = 4'hf;

    // Forwarding permits multiple in-flight writers to the same architectural
    // register, so a busy bit is insufficient: an older retirement must not
    // clear a younger writer's reservation. Reads remain counted for the
    // conservative non-forwarding mode.
    reg [3:0] read_count_q [0:31];
    reg [3:0] write_count_q [0:31];

    wire alloc_reads_rs1 = alloc_valid_i &&
                           alloc_uses_rs1_i &&
                           (alloc_rs1_addr_i != `RV64_REG_X0);
    wire alloc_reads_rs2 = alloc_valid_i &&
                           alloc_uses_rs2_i &&
                           (alloc_rs2_addr_i != `RV64_REG_X0);
    wire alloc_writes_rd = alloc_valid_i &&
                           alloc_reg_write_i &&
                           (alloc_rd_addr_i != `RV64_REG_X0);

    wire [3:0] rs1_read_count_after_retire =
        read_count_after_releases(
            alloc_rs1_addr_i,
            retire_valid_i,
            retire_uses_rs1_i,
            retire_uses_rs2_i,
            retire_rs1_addr_i,
            retire_rs2_addr_i,
            rollback_valid_i,
            rollback_uses_rs1_i,
            rollback_uses_rs2_i,
            rollback_rs1_addr_i,
            rollback_rs2_addr_i);
    wire [3:0] rs2_read_count_after_retire =
        read_count_after_releases(
            alloc_rs2_addr_i,
            retire_valid_i,
            retire_uses_rs1_i,
            retire_uses_rs2_i,
            retire_rs1_addr_i,
            retire_rs2_addr_i,
            rollback_valid_i,
            rollback_uses_rs1_i,
            rollback_uses_rs2_i,
            rollback_rs1_addr_i,
            rollback_rs2_addr_i);
    wire [3:0] rd_read_count_after_retire =
        read_count_after_releases(
            alloc_rd_addr_i,
            retire_valid_i,
            retire_uses_rs1_i,
            retire_uses_rs2_i,
            retire_rs1_addr_i,
            retire_rs2_addr_i,
            rollback_valid_i,
            rollback_uses_rs1_i,
            rollback_uses_rs2_i,
            rollback_rs1_addr_i,
            rollback_rs2_addr_i);
    wire [3:0] rs1_write_count_after_retire =
        write_count_after_releases(
            alloc_rs1_addr_i,
            retire_valid_i,
            retire_reg_write_i,
            retire_rd_addr_i,
            rollback_valid_i,
            rollback_reg_write_i,
            rollback_rd_addr_i);
    wire [3:0] rs2_write_count_after_retire =
        write_count_after_releases(
            alloc_rs2_addr_i,
            retire_valid_i,
            retire_reg_write_i,
            retire_rd_addr_i,
            rollback_valid_i,
            rollback_reg_write_i,
            rollback_rd_addr_i);
    wire [3:0] rd_write_count_after_retire =
        write_count_after_releases(
            alloc_rd_addr_i,
            retire_valid_i,
            retire_reg_write_i,
            retire_rd_addr_i,
            rollback_valid_i,
            rollback_reg_write_i,
            rollback_rd_addr_i);
    wire [1:0] rs1_alloc_read_add = alloc_read_count_for_addr(
        alloc_rs1_addr_i,
        alloc_reads_rs1,
        alloc_reads_rs2,
        alloc_rs1_addr_i,
        alloc_rs2_addr_i);
    wire [1:0] rs2_alloc_read_add = alloc_read_count_for_addr(
        alloc_rs2_addr_i,
        alloc_reads_rs1,
        alloc_reads_rs2,
        alloc_rs1_addr_i,
        alloc_rs2_addr_i);
    wire rd_read_hot_before_allocate = alloc_read_hot_i[alloc_rd_addr_i];

    assign alloc_read_hot_o = (alloc_reads_rs1 ?
                               (32'h0000_0001 << alloc_rs1_addr_i) :
                               32'h0000_0000) |
                              (alloc_reads_rs2 ?
                               (32'h0000_0001 << alloc_rs2_addr_i) :
                               32'h0000_0000);

    wire [1:0] rs1_forward_owner_marks = {
        forward_mem_write_hot_i[alloc_rs1_addr_i],
        forward_ex_write_hot_i[alloc_rs1_addr_i]
    };
    wire [1:0] rs2_forward_owner_marks = {
        forward_mem_write_hot_i[alloc_rs2_addr_i],
        forward_ex_write_hot_i[alloc_rs2_addr_i]
    };
    wire rs1_has_one_forward_owner = ^rs1_forward_owner_marks;
    wire rs2_has_one_forward_owner = ^rs2_forward_owner_marks;
    wire rs1_forwardable = ENABLE_FORWARDING &&
                           (rs1_write_count_after_retire == 4'd1) &&
                           rs1_has_one_forward_owner;
    wire rs2_forwardable = ENABLE_FORWARDING &&
                           (rs2_write_count_after_retire == 4'd1) &&
                           rs2_has_one_forward_owner;

    assign raw_hazard_o = alloc_valid_i &&
                          ((alloc_reads_rs1 &&
                            (rs1_write_count_after_retire != 4'd0) &&
                            !rs1_forwardable) ||
                           (alloc_reads_rs2 &&
                            (rs2_write_count_after_retire != 4'd0) &&
                            !rs2_forwardable));
    // Issue and retirement are in order. Once forwarding is enabled, an older
    // instruction reads its operands before a younger writer can execute, so
    // WAR is not a pipeline hazard. WAW is limited only by counter capacity.
    assign war_hazard_o = !ENABLE_FORWARDING && alloc_writes_rd &&
                          ((rd_read_count_after_retire != 4'd0) ||
                           rd_read_hot_before_allocate);
    assign waw_hazard_o = alloc_writes_rd &&
                          (ENABLE_FORWARDING ?
                           (rd_write_count_after_retire == WRITE_COUNT_MAX) :
                           (rd_write_count_after_retire != 4'd0));
    // With forwarding enabled, operand reads are consumed in issue order and
    // have no later architectural ownership.  WAR checking is consequently
    // disabled above, so retaining read counters only to detect their
    // saturation is both unnecessary and expensive: it feeds retirement
    // release through a count decrement, indexed comparison, and decode
    // backpressure in one cycle.  Keep read accounting only for the
    // conservative non-forwarding configuration.
    assign read_full_hazard_o = !ENABLE_FORWARDING && alloc_valid_i &&
                                ((alloc_reads_rs1 &&
                                  ({1'b0, rs1_read_count_after_retire} +
                                   {3'b000, rs1_alloc_read_add}) >
                                  {1'b0, READ_COUNT_MAX}) ||
                                 (alloc_reads_rs2 &&
                                  ({1'b0, rs2_read_count_after_retire} +
                                   {3'b000, rs2_alloc_read_add}) >
                                  {1'b0, READ_COUNT_MAX}));
    assign can_allocate_o = !(raw_hazard_o ||
                              war_hazard_o ||
                              waw_hazard_o ||
                              read_full_hazard_o);

    function [1:0] alloc_read_count_for_addr;
        input [`RV64_REG_ADDR_WIDTH-1:0] addr;
        input alloc_reads_rs1_arg;
        input alloc_reads_rs2_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] alloc_rs1_addr_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] alloc_rs2_addr_arg;
        begin
            alloc_read_count_for_addr = 2'd0;

            if (addr != `RV64_REG_X0) begin
                if (alloc_reads_rs1_arg && (alloc_rs1_addr_arg == addr)) begin
                    alloc_read_count_for_addr = alloc_read_count_for_addr + 2'd1;
                end

                if (alloc_reads_rs2_arg && (alloc_rs2_addr_arg == addr)) begin
                    alloc_read_count_for_addr = alloc_read_count_for_addr + 2'd1;
                end
            end
        end
    endfunction

    function [3:0] read_count_after_releases;
        input [`RV64_REG_ADDR_WIDTH-1:0] addr;
        input retire_valid_arg;
        input retire_uses_rs1_arg;
        input retire_uses_rs2_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_arg;
        input rollback_valid_arg;
        input rollback_uses_rs1_arg;
        input rollback_uses_rs2_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] rollback_rs1_addr_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] rollback_rs2_addr_arg;
        reg [4:0] read_count;
        begin
            read_count = {1'b0, read_count_q[addr]};

            if (addr != `RV64_REG_X0) begin
                if (retire_valid_arg &&
                    retire_uses_rs1_arg &&
                    (retire_rs1_addr_arg == addr) &&
                    (read_count != 5'd0)) begin
                    read_count = read_count - 5'd1;
                end

                if (retire_valid_arg &&
                    retire_uses_rs2_arg &&
                    (retire_rs2_addr_arg == addr) &&
                    (read_count != 5'd0)) begin
                    read_count = read_count - 5'd1;
                end

                if (rollback_valid_arg &&
                    rollback_uses_rs1_arg &&
                    (rollback_rs1_addr_arg == addr) &&
                    (read_count != 5'd0)) begin
                    read_count = read_count - 5'd1;
                end

                if (rollback_valid_arg &&
                    rollback_uses_rs2_arg &&
                    (rollback_rs2_addr_arg == addr) &&
                    (read_count != 5'd0)) begin
                    read_count = read_count - 5'd1;
                end
            end else begin
                read_count = 5'd0;
            end

            read_count_after_releases = read_count[3:0];
        end
    endfunction

    function [3:0] write_count_after_releases;
        input [`RV64_REG_ADDR_WIDTH-1:0] addr;
        input retire_valid_arg;
        input retire_reg_write_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_arg;
        input rollback_valid_arg;
        input rollback_reg_write_arg;
        input [`RV64_REG_ADDR_WIDTH-1:0] rollback_rd_addr_arg;
        begin
            if (addr == `RV64_REG_X0) begin
                write_count_after_releases = 4'd0;
            end else begin
                write_count_after_releases = write_count_q[addr];

                if (retire_valid_arg &&
                    retire_reg_write_arg &&
                    (retire_rd_addr_arg == addr) &&
                    (write_count_after_releases != 4'd0)) begin
                    write_count_after_releases =
                        write_count_after_releases - 4'd1;
                end

                if (rollback_valid_arg &&
                    rollback_reg_write_arg &&
                    (rollback_rd_addr_arg == addr) &&
                    (write_count_after_releases != 4'd0)) begin
                    write_count_after_releases =
                        write_count_after_releases - 4'd1;
                end
            end
        end
    endfunction

    integer reg_idx;
    reg [4:0] read_count_next;
    reg [4:0] write_count_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) begin
                read_count_q[reg_idx] <= 4'd0;
                write_count_q[reg_idx] <= 4'd0;
            end
        end else if (clear_i) begin
            for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) begin
                read_count_q[reg_idx] <= 4'd0;
                write_count_q[reg_idx] <= 4'd0;
            end
        end else begin
            for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) begin
                if (reg_idx == `RV64_REG_X0) begin
                    read_count_q[reg_idx] <= 4'd0;
                    write_count_q[reg_idx] <= 4'd0;
                end else begin
                    read_count_next = {1'b0, read_count_q[reg_idx]};
                    write_count_next = {1'b0, write_count_q[reg_idx]};

                    if (retire_valid_i &&
                        retire_uses_rs1_i &&
                        (retire_rs1_addr_i == reg_idx) &&
                        (read_count_next != 5'd0)) begin
                        read_count_next = read_count_next - 5'd1;
                    end

                    if (retire_valid_i &&
                        retire_uses_rs2_i &&
                        (retire_rs2_addr_i == reg_idx) &&
                        (read_count_next != 5'd0)) begin
                        read_count_next = read_count_next - 5'd1;
                    end

                    if (rollback_valid_i &&
                        rollback_uses_rs1_i &&
                        (rollback_rs1_addr_i == reg_idx) &&
                        (read_count_next != 5'd0)) begin
                        read_count_next = read_count_next - 5'd1;
                    end

                    if (rollback_valid_i &&
                        rollback_uses_rs2_i &&
                        (rollback_rs2_addr_i == reg_idx) &&
                        (read_count_next != 5'd0)) begin
                        read_count_next = read_count_next - 5'd1;
                    end

                    if (retire_valid_i &&
                        retire_reg_write_i &&
                        (retire_rd_addr_i == reg_idx) &&
                        (write_count_next != 5'd0)) begin
                        write_count_next = write_count_next - 5'd1;
                    end

                    if (rollback_valid_i &&
                        rollback_reg_write_i &&
                        (rollback_rd_addr_i == reg_idx) &&
                        (write_count_next != 5'd0)) begin
                        write_count_next = write_count_next - 5'd1;
                    end

                    if (alloc_fire_i) begin
                        if (alloc_uses_rs1_i &&
                            (alloc_rs1_addr_i == reg_idx) &&
                            (read_count_next != {1'b0, READ_COUNT_MAX})) begin
                            read_count_next = read_count_next + 5'd1;
                        end

                        if (alloc_uses_rs2_i &&
                            (alloc_rs2_addr_i == reg_idx) &&
                            (read_count_next != {1'b0, READ_COUNT_MAX})) begin
                            read_count_next = read_count_next + 5'd1;
                        end

                        if (alloc_reg_write_i &&
                            (alloc_rd_addr_i == reg_idx) &&
                            (write_count_next != {1'b0, WRITE_COUNT_MAX})) begin
                            write_count_next = write_count_next + 5'd1;
                        end
                    end

                    read_count_q[reg_idx] <= read_count_next[3:0];
                    write_count_q[reg_idx] <= write_count_next[3:0];
                end
            end
        end
    end

endmodule
