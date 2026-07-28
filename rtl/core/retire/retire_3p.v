`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zifencei.v"
`include "core/except/except-defs.v"

// Commit logic for the maximal contiguous ready prefix.  Normal instructions
// may retire three-wide.  The first exception or hard-order instruction ends
// the group; an exception entry is consumed to release ownership but does not
// perform architectural writes or increment minstret.
module openrv64_retire_3p #(
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter integer META_WIDTH =
        `OPENRV64_RETIRE_ALLOC_FIXED_WIDTH + 2*PHYS_REG_ADDR_WIDTH,
    parameter integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH
) (
    input  wire [2:0]                   queue_valid_i,
    input  wire [3*META_WIDTH-1:0]      queue_meta_i,
    input  wire [3*RESULT_WIDTH-1:0]    queue_result_i,
    input  wire [3*64-1:0]              queue_trace_id_i,
    output wire [2:0]                   queue_accept_o,

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

    output wire [2:0]                   gpr_write_o,
    output wire [3*PHYS_REG_ADDR_WIDTH-1:0] gpr_rd_addr_o,
    output wire [3*`RV64_XLEN-1:0]      gpr_rd_data_o,

    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
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

    localparam integer META_USES_RS1 =
        `OPENRV64_RETIRE_ALLOC_USES_RS1_BIT;
    localparam integer META_USES_RS2 =
        `OPENRV64_RETIRE_ALLOC_USES_RS2_BIT;
    localparam integer META_HARD = `OPENRV64_RETIRE_ALLOC_HARD_BIT;
    localparam integer META_NEW_PHYS =
        `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB;

    localparam integer RESULT_CSR_WDATA =
        `OPENRV64_RETIRE_RESULT_CSR_WDATA_LSB;
    localparam integer RESULT_CSR_ADDR =
        `OPENRV64_RETIRE_RESULT_CSR_ADDR_LSB;
    localparam integer RESULT_CSR_WRITE =
        `OPENRV64_RETIRE_RESULT_CSR_WRITE_BIT;
    localparam integer RESULT_SRET = `OPENRV64_RETIRE_RESULT_SRET_BIT;
    localparam integer RESULT_MRET = `OPENRV64_RETIRE_RESULT_MRET_BIT;
    localparam integer RESULT_TVAL = `OPENRV64_RETIRE_RESULT_TVAL_LSB;
    localparam integer RESULT_CAUSE = `OPENRV64_RETIRE_RESULT_CAUSE_LSB;
    localparam integer RESULT_HALT = `OPENRV64_RETIRE_RESULT_HALT_BIT;
    localparam integer RESULT_EXCEPTION =
        `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT;
    localparam integer RESULT_DATA = `OPENRV64_RETIRE_RESULT_DATA_LSB;
    localparam integer RESULT_NEXT_PC =
        `OPENRV64_RETIRE_RESULT_NEXT_PC_LSB;

    wire hard0 = queue_meta_i[0*META_WIDTH + META_HARD];
    wire hard1 = queue_meta_i[1*META_WIDTH + META_HARD];
    wire hard2 = queue_meta_i[2*META_WIDTH + META_HARD];
    wire exception0 = queue_result_i[
        0*RESULT_WIDTH + RESULT_EXCEPTION];
    wire exception1 = queue_result_i[
        1*RESULT_WIDTH + RESULT_EXCEPTION];
    wire exception2 = queue_result_i[
        2*RESULT_WIDTH + RESULT_EXCEPTION];
    wire halt0 = queue_result_i[
        0*RESULT_WIDTH + RESULT_HALT];
    wire halt1 = queue_result_i[
        1*RESULT_WIDTH + RESULT_HALT];
    wire halt2 = queue_result_i[
        2*RESULT_WIDTH + RESULT_HALT];
    wire csr_pending0 = queue_valid_i[0] && !exception0 &&
        queue_result_i[0*RESULT_WIDTH + RESULT_CSR_WRITE];
    wire csr_pending1 = queue_valid_i[1] && !exception1 &&
        queue_result_i[1*RESULT_WIDTH + RESULT_CSR_WRITE];
    wire csr_pending2 = queue_valid_i[2] && !exception2 &&
        queue_result_i[2*RESULT_WIDTH + RESULT_CSR_WRITE];

    wire accept0 = queue_valid_i[0] &&
                   (!csr_pending0 || csr_write_ready_i);
    wire accept1 = queue_valid_i[1] && accept0 &&
                   !exception0 && !halt0 && !hard0 &&
                   (!csr_pending1 || csr_write_ready_i);
    wire accept2 = queue_valid_i[2] && accept1 &&
                   !exception1 && !halt1 && !hard1 &&
                   (!csr_pending2 || csr_write_ready_i);
    assign queue_accept_o = {accept2, accept1, accept0};

    wire arch0 = accept0 && !exception0;
    wire arch1 = accept1 && !exception1;
    wire arch2 = accept2 && !exception2;
    assign retire_arch_o = {arch2, arch1, arch0};
    assign retire_count_o = {1'b0, arch0} +
                            {1'b0, arch1} +
                            {1'b0, arch2};
    assign retire_hard_o = queue_accept_o & {hard2, hard1, hard0};

    genvar lane;
    generate
        for (lane = 0; lane < 3; lane = lane + 1) begin : g_release
            wire uses_rs1 = queue_meta_i[
                lane*META_WIDTH + META_USES_RS1];
            wire uses_rs2 = queue_meta_i[
                lane*META_WIDTH + META_USES_RS2];
            wire issue_reg_write = queue_meta_i[
                lane*META_WIDTH +
                `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
            wire [`RV64_REG_ADDR_WIDTH-1:0] issue_rd = queue_meta_i[
                lane*META_WIDTH +
                `OPENRV64_RETIRE_ALLOC_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            wire [PHYS_REG_ADDR_WIDTH-1:0] new_phys =
                queue_meta_i[
                    lane*META_WIDTH + META_NEW_PHYS +:
                    PHYS_REG_ADDR_WIDTH];

            assign release_valid_o[lane] = queue_accept_o[lane];
            assign release_uses_rs1_o[lane] = queue_accept_o[lane] && uses_rs1;
            assign release_uses_rs2_o[lane] = queue_accept_o[lane] && uses_rs2;
            assign release_rs1_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                queue_meta_i[
                    lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RS1_LSB +:
                    `RV64_REG_ADDR_WIDTH];
            assign release_rs2_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                queue_meta_i[
                    lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RS2_LSB +:
                    `RV64_REG_ADDR_WIDTH];
            assign release_reg_write_o[lane] = queue_accept_o[lane] &&
                                                issue_reg_write &&
                                                (issue_rd != `RV64_REG_X0);
            assign release_rd_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] = issue_rd;

            assign gpr_write_o[lane] = retire_arch_o[lane] &&
                                       issue_reg_write &&
                                       (issue_rd != `RV64_REG_X0);
            assign gpr_rd_addr_o[
                lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = new_phys;
            assign gpr_rd_data_o[lane*`RV64_XLEN +: `RV64_XLEN] =
                queue_result_i[
                    lane*RESULT_WIDTH +
                    RESULT_DATA +: `RV64_XLEN];
        end
    endgenerate

    // csr_write_o is a held request, not merely an acceptance pulse.  A slow
    // CSR unit may lower csr_write_ready_i, consume this stable request, and
    // let the hard-order retirement entry commit only after its work is done.
    wire csr_write0 = csr_pending0;
    wire csr_write1 = csr_pending1 && queue_valid_i[0] &&
                      !exception0 && !halt0 && !hard0;
    wire csr_write2 = csr_pending2 && queue_valid_i[0] &&
                      queue_valid_i[1] &&
                      !exception0 && !halt0 && !hard0 &&
                      !exception1 && !halt1 && !hard1;
    assign csr_write_o = csr_write0 || csr_write1 || csr_write2;
    assign csr_addr_o = csr_write0 ? queue_result_i[
        0*RESULT_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH] :
        csr_write1 ? queue_result_i[
        1*RESULT_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH] : queue_result_i[
        2*RESULT_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH];
    assign csr_wdata_o = csr_write0 ? queue_result_i[
        0*RESULT_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN] :
        csr_write1 ? queue_result_i[
        1*RESULT_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN] : queue_result_i[
        2*RESULT_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN];

    wire exception_event0 = accept0 && exception0;
    wire exception_event1 = accept1 && exception1;
    wire exception_event2 = accept2 && exception2;
    assign exception_o = exception_event0 || exception_event1 ||
                         exception_event2;
    assign halt_o = (accept0 && halt0) || (accept1 && halt1) ||
                    (accept2 && halt2);

    wire mret0 = arch0 && queue_result_i[
        0*RESULT_WIDTH + RESULT_MRET];
    wire mret1 = arch1 && queue_result_i[
        1*RESULT_WIDTH + RESULT_MRET];
    wire mret2 = arch2 && queue_result_i[
        2*RESULT_WIDTH + RESULT_MRET];
    wire sret0 = arch0 && queue_result_i[
        0*RESULT_WIDTH + RESULT_SRET];
    wire sret1 = arch1 && queue_result_i[
        1*RESULT_WIDTH + RESULT_SRET];
    wire sret2 = arch2 && queue_result_i[
        2*RESULT_WIDTH + RESULT_SRET];
    assign mret_o = mret0 || mret1 || mret2;
    assign sret_o = sret0 || sret1 || sret2;

    wire [`RV64_INSTR_WIDTH-1:0] instr0 = queue_meta_i[
        0*META_WIDTH + `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
        `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr1 = queue_meta_i[
        1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
        `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr2 = queue_meta_i[
        2*META_WIDTH + `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
        `RV64_INSTR_WIDTH];
    wire fence_i0 = arch0 &&
        (`RV64_OPCODE(instr0) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(instr0) == `RV64_ZIFENCEI_FUNCT3_FENCE_I);
    wire fence_i1 = arch1 &&
        (`RV64_OPCODE(instr1) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(instr1) == `RV64_ZIFENCEI_FUNCT3_FENCE_I);
    wire fence_i2 = arch2 &&
        (`RV64_OPCODE(instr2) == `RV64_OPCODE_MISC_MEM) &&
        (`RV64_FUNCT3(instr2) == `RV64_ZIFENCEI_FUNCT3_FENCE_I);
    wire sfence0 = arch0 && `RV64_IS_SFENCE_VMA(instr0);
    wire sfence1 = arch1 && `RV64_IS_SFENCE_VMA(instr1);
    wire sfence2 = arch2 && `RV64_IS_SFENCE_VMA(instr2);
    assign fence_i_o = fence_i0 || fence_i1 || fence_i2;
    assign sfence_vma_o = sfence0 || sfence1 || sfence2;

    wire control_event = exception_o || halt_o || mret_o || sret_o ||
                         fence_i_o || sfence_vma_o;
    // The CSR file has one architectural write/update transaction per cycle.
    // Defer an interrupt at a retiring CSR write rather than dropping that
    // write behind trap-entry priority; it will be reconsidered at the next
    // retirement boundary.
    assign irq_o = irq_pending_i && (|retire_arch_o) && !control_event &&
                   !csr_write_o;

    wire [1:0] event_lane = exception_event0 ? 2'd0 :
                            exception_event1 ? 2'd1 :
                            exception_event2 ? 2'd2 :
                            arch2 ? 2'd2 :
                            arch1 ? 2'd1 : 2'd0;
    wire [META_WIDTH-1:0] event_meta =
        queue_meta_i[event_lane*META_WIDTH +: META_WIDTH];
    wire [RESULT_WIDTH-1:0] event_result =
        queue_result_i[event_lane*RESULT_WIDTH +: RESULT_WIDTH];
    assign cause_o = irq_o ? irq_cause_i :
        event_result[RESULT_CAUSE +: `RV64_EXCEPT_CAUSE_WIDTH];
    assign pc_o = event_meta[
        `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
    assign next_pc_o = event_result[RESULT_NEXT_PC +: `RV64_XLEN];
    assign tval_o = exception_o ?
        event_result[RESULT_TVAL +: `RV64_XLEN] : {`RV64_XLEN{1'b0}};
    assign trace_id_o =
        queue_trace_id_i[event_lane*64 +: 64];
    assign instr_o = event_meta[
        `OPENRV64_RETIRE_ALLOC_INSTR_LSB +: `RV64_INSTR_WIDTH];
    assign trace_rd_o = event_meta[
        `OPENRV64_RETIRE_ALLOC_RD_LSB +: `RV64_REG_ADDR_WIDTH];
    assign trace_wdata_o = event_result[RESULT_DATA +: `RV64_XLEN];

endmodule
