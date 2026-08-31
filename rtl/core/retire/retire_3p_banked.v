`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/except/except-defs.v"

// Initial banked retirement boundary.  At most two queue entries retire, and
// their GPR writes are held until the two logical write ports report valid.
// The underlying retirement module still owns exceptions, CSRs, trace, and
// architectural release; this wrapper only delays its acceptance boundary.
module openrv64_retire_3p_banked #(
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter integer META_WIDTH =
        `OPENRV64_RETIRE_ALLOC_FIXED_WIDTH + 2*PHYS_REG_ADDR_WIDTH,
    parameter integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH,
    parameter integer ENABLE_EXTENSION = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   queue_valid_i,
    input  wire [3*META_WIDTH-1:0]      queue_meta_i,
    input  wire [3*RESULT_WIDTH-1:0]    queue_result_i,
    input  wire [3*64-1:0]              queue_trace_id_i,
    output wire [2:0]                   queue_accept_o,

    input  wire [2:0]                   extension_ready_i,
    input  wire [2:0]                   extension_gpr_result_valid_i,
    input  wire [3*`RV64_XLEN-1:0]      extension_gpr_result_i,
    input  wire [2:0]                   extension_exception_i,
    input  wire [3*`RV64_EXCEPT_CAUSE_WIDTH-1:0]
                                        extension_cause_i,
    input  wire [3*`RV64_XLEN-1:0]      extension_tval_i,

    input  wire                         csr_write_ready_i,
    input  wire                         irq_pending_i,
    input  wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause_i,

    output wire [2:0]                   retire_arch_o,
    output wire [1:0]                   retire_count_o,
    output wire [2:0]                   retire_hard_o,

    output wire [2:0]                   release_valid_o,
    output wire [2:0]                   release_uses_rs1_o,
    output wire [2:0]                   release_uses_rs2_o,
    output wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs1_addr_o,
    output wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs2_addr_o,
    output wire [2:0]                   release_reg_write_o,
    output wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rd_addr_o,

    output wire [1:0]                   gpr_write_o,
    output wire [2*PHYS_REG_ADDR_WIDTH-1:0] gpr_rd_addr_o,
    output wire [2*`RV64_XLEN-1:0]      gpr_rd_data_o,
    input  wire [1:0]                   gpr_write_valid_i,

    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    output wire [`RV64_FUNCT3_WIDTH-1:0] csr_op_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,

    output wire                         exception_o,
    output wire                         halt_o,
    output wire                         irq_o,
    output wire                         mret_o,
    output wire                         sret_o,
    output wire                         fence_i_o,
    output wire                         sfence_vma_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output wire [`RV64_XLEN-1:0]        pc_o,
    output wire [`RV64_XLEN-1:0]        next_pc_o,
    output wire [`RV64_XLEN-1:0]        tval_o,

    output wire [63:0]                  trace_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] instr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] trace_rd_o,
    output wire [`RV64_XLEN-1:0]        trace_wdata_o
);

    localparam integer META_HARD = `OPENRV64_RETIRE_ALLOC_HARD_BIT;
    localparam integer META_NEW_PHYS =
        `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB;
    localparam integer RESULT_CSR_WRITE =
        `OPENRV64_RETIRE_RESULT_CSR_WRITE_BIT;
    localparam integer RESULT_HALT = `OPENRV64_RETIRE_RESULT_HALT_BIT;
    localparam integer RESULT_EXCEPTION =
        `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT;
    localparam integer RESULT_DATA = `OPENRV64_RETIRE_RESULT_DATA_LSB;

    wire [2:0] extension_ready = (ENABLE_EXTENSION != 0) ?
                                 extension_ready_i : 3'b111;
    wire [2:0] extension_result_valid = (ENABLE_EXTENSION != 0) ?
                                        extension_gpr_result_valid_i :
                                        3'b000;
    wire [2:0] extension_exception = (ENABLE_EXTENSION != 0) ?
                                     extension_exception_i : 3'b000;

    wire hard0 = queue_meta_i[0*META_WIDTH + META_HARD];
    wire exception0 = queue_result_i[
        0*RESULT_WIDTH + RESULT_EXCEPTION] || extension_exception[0];
    wire exception1 = queue_result_i[
        1*RESULT_WIDTH + RESULT_EXCEPTION] || extension_exception[1];
    wire halt0 = queue_result_i[0*RESULT_WIDTH + RESULT_HALT];
    wire csr_pending0 = queue_valid_i[0] && !exception0 &&
        queue_result_i[0*RESULT_WIDTH + RESULT_CSR_WRITE];
    wire csr_pending1 = queue_valid_i[1] && !exception1 &&
        queue_result_i[1*RESULT_WIDTH + RESULT_CSR_WRITE];

    reg csr_done_q;
    wire csr_ready = csr_done_q || csr_write_ready_i;

    wire candidate0 = queue_valid_i[0] && extension_ready[0] &&
                      (!csr_pending0 || csr_ready);
    wire candidate1 = queue_valid_i[1] && candidate0 &&
                      !exception0 && !halt0 && !hard0 &&
                      extension_ready[1] &&
                      (!csr_pending1 || csr_ready);

    wire issue_reg_write0 = queue_meta_i[
        0*META_WIDTH + `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
    wire issue_reg_write1 = queue_meta_i[
        1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
    wire [`RV64_REG_ADDR_WIDTH-1:0] issue_rd0 = queue_meta_i[
        0*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RD_LSB +:
        `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] issue_rd1 = queue_meta_i[
        1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RD_LSB +:
        `RV64_REG_ADDR_WIDTH];

    wire [1:0] write_mask_now = {
        candidate1 && !exception1 && issue_reg_write1 &&
            (issue_rd1 != `RV64_REG_X0),
        candidate0 && !exception0 && issue_reg_write0 &&
            (issue_rd0 != `RV64_REG_X0)
    };
    wire [2*PHYS_REG_ADDR_WIDTH-1:0] write_addr_now = {
        queue_meta_i[1*META_WIDTH + META_NEW_PHYS +:
                     PHYS_REG_ADDR_WIDTH],
        queue_meta_i[0*META_WIDTH + META_NEW_PHYS +:
                     PHYS_REG_ADDR_WIDTH]
    };
    wire [2*`RV64_XLEN-1:0] write_data_now = {
        extension_result_valid[1] ? extension_gpr_result_i[
            1*`RV64_XLEN +: `RV64_XLEN] : queue_result_i[
            1*RESULT_WIDTH + RESULT_DATA +: `RV64_XLEN],
        extension_result_valid[0] ? extension_gpr_result_i[
            0*`RV64_XLEN +: `RV64_XLEN] : queue_result_i[
            0*RESULT_WIDTH + RESULT_DATA +: `RV64_XLEN]
    };

    reg write_active_q;
    reg [1:0] write_mask_q;
    reg [1:0] write_done_q;
    reg [2*PHYS_REG_ADDR_WIDTH-1:0] write_addr_q;
    reg [2*`RV64_XLEN-1:0] write_data_q;

    assign gpr_write_o = write_mask_q &
                         ~write_done_q &
                         {2{write_active_q}};
    assign gpr_rd_addr_o = write_addr_q;
    assign gpr_rd_data_o = write_data_q;

    wire writes_complete = write_active_q &&
        &((~write_mask_q) | write_done_q | gpr_write_valid_i);
    wire commit_ready = write_active_q ? writes_complete :
                        !(|write_mask_now);

    wire [2:0] inner_queue_valid = {1'b0, queue_valid_i[1:0]};
    wire [2:0] inner_extension_ready =
        extension_ready & {3{commit_ready}};
    wire [2:0] inner_extension_result_valid = extension_result_valid;
    wire [2:0] inner_extension_exception = extension_exception;
    wire [3*`RV64_EXCEPT_CAUSE_WIDTH-1:0] inner_extension_cause =
        (ENABLE_EXTENSION != 0) ? extension_cause_i :
        {3*`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    wire [3*`RV64_XLEN-1:0] inner_extension_tval =
        (ENABLE_EXTENSION != 0) ? extension_tval_i :
        {3*`RV64_XLEN{1'b0}};

    wire [2:0] unused_inner_gpr_write;
    wire [3*PHYS_REG_ADDR_WIDTH-1:0] unused_inner_gpr_addr;
    wire [3*`RV64_XLEN-1:0] unused_inner_gpr_data;
    wire inner_csr_write;

    // A CSR request may complete before the banked GPR writes.  Remember that
    // completion and suppress repeated CSR side effects while the write group
    // drains; the inner retire block sees the remembered completion as ready.
    assign csr_write_o = inner_csr_write && !csr_done_q;

    openrv64_retire_3p #(
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .META_WIDTH(META_WIDTH),
        .RESULT_WIDTH(RESULT_WIDTH),
        .ENABLE_EXTENSION(1)
    ) u_retire (
        .queue_valid_i(inner_queue_valid),
        .extension_ready_i(inner_extension_ready),
        .extension_gpr_result_valid_i(inner_extension_result_valid),
        .extension_exception_i(inner_extension_exception),
        .extension_cause_i(inner_extension_cause),
        .extension_tval_i(inner_extension_tval),
        .csr_write_ready_i(csr_ready),
        .gpr_write_o(unused_inner_gpr_write),
        .gpr_rd_addr_o(unused_inner_gpr_addr),
        .gpr_rd_data_o(unused_inner_gpr_data),
        .csr_write_o(inner_csr_write),
        .*
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_active_q <= 1'b0;
            write_mask_q <= 2'b00;
            write_done_q <= 2'b00;
            write_addr_q <= {2*PHYS_REG_ADDR_WIDTH{1'b0}};
            write_data_q <= {2*`RV64_XLEN{1'b0}};
        end else if (flush_i || (|queue_accept_o)) begin
            write_active_q <= 1'b0;
            write_mask_q <= 2'b00;
            write_done_q <= 2'b00;
            write_addr_q <= {2*PHYS_REG_ADDR_WIDTH{1'b0}};
            write_data_q <= {2*`RV64_XLEN{1'b0}};
        end else if (!write_active_q && (|write_mask_now)) begin
            write_active_q <= 1'b1;
            write_mask_q <= write_mask_now;
            write_done_q <= 2'b00;
            write_addr_q <= write_addr_now;
            write_data_q <= write_data_now;
        end else if (write_active_q) begin
            write_done_q <= write_done_q | gpr_write_valid_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            csr_done_q <= 1'b0;
        else if (flush_i || (|queue_accept_o))
            csr_done_q <= 1'b0;
        else if (csr_write_o && csr_write_ready_i)
            csr_done_q <= 1'b1;
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i) begin
            if (queue_accept_o[2])
                $fatal(1, "banked retirement accepted a third lane");
            if (write_active_q && (write_mask_q == 2'b00))
                $fatal(1, "banked retirement has an empty write group");
        end
    end
`endif

endmodule
