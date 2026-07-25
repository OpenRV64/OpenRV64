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
        `OPENRV64_DISPATCH_META_WIDTH + 2*PHYS_REG_ADDR_WIDTH
) (
    input  wire [2:0]                   queue_valid_i,
    input  wire [3*META_WIDTH-1:0]      queue_meta_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        queue_result_i,
    output wire [2:0]                   queue_accept_o,

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

    localparam integer META_PAYLOAD_LSB = 0;
    localparam integer META_USES_RS1 = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer META_USES_RS2 = META_USES_RS1 + 1;
    localparam integer META_HARD = META_USES_RS2 + 1;
    localparam integer META_NEW_PHYS = META_HARD + 1;

    localparam integer RESULT_CSR_WDATA = 0;
    localparam integer RESULT_CSR_ADDR = 64;
    localparam integer RESULT_CSR_WRITE = 76;
    localparam integer RESULT_SRET = 77;
    localparam integer RESULT_MRET = 78;
    localparam integer RESULT_TVAL = 79;
    localparam integer RESULT_CAUSE = 143;
    localparam integer RESULT_HALT = 148;
    localparam integer RESULT_EXCEPTION = 149;
    localparam integer RESULT_REG_WRITE = 153;
    localparam integer RESULT_RD = 154;
    localparam integer RESULT_RS2 = 159;
    localparam integer RESULT_RS1 = 164;
    localparam integer RESULT_DATA = 169;
    localparam integer RESULT_INSTR = 233;
    localparam integer RESULT_NEXT_PC = 265;
    localparam integer RESULT_PC = 329;
    localparam integer RESULT_TRACE = 393;

    wire hard0 = queue_meta_i[0*META_WIDTH + META_HARD];
    wire hard1 = queue_meta_i[1*META_WIDTH + META_HARD];
    wire hard2 = queue_meta_i[2*META_WIDTH + META_HARD];
    wire exception0 = queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_EXCEPTION];
    wire exception1 = queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_EXCEPTION];
    wire exception2 = queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_EXCEPTION];
    wire halt0 = queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_HALT];
    wire halt1 = queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_HALT];
    wire halt2 = queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_HALT];

    wire accept0 = queue_valid_i[0];
    wire accept1 = queue_valid_i[1] && accept0 &&
                   !exception0 && !halt0 && !hard0;
    wire accept2 = queue_valid_i[2] && accept1 &&
                   !exception1 && !halt1 && !hard1;
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
                META_PAYLOAD_LSB + 17];
            wire [`RV64_REG_ADDR_WIDTH-1:0] issue_rd = queue_meta_i[
                lane*META_WIDTH +
                META_PAYLOAD_LSB + 35 +: `RV64_REG_ADDR_WIDTH];
            wire result_reg_write = queue_result_i[
                lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                RESULT_REG_WRITE];
            wire [`RV64_REG_ADDR_WIDTH-1:0] result_rd = queue_result_i[
                lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                RESULT_RD +: `RV64_REG_ADDR_WIDTH];
            wire [PHYS_REG_ADDR_WIDTH-1:0] new_phys =
                queue_meta_i[
                    lane*META_WIDTH + META_NEW_PHYS +:
                    PHYS_REG_ADDR_WIDTH];

            assign release_valid_o[lane] = queue_accept_o[lane];
            assign release_uses_rs1_o[lane] = queue_accept_o[lane] && uses_rs1;
            assign release_uses_rs2_o[lane] = queue_accept_o[lane] && uses_rs2;
            assign release_rs1_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                queue_result_i[
                    lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    RESULT_RS1 +: `RV64_REG_ADDR_WIDTH];
            assign release_rs2_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] =
                queue_result_i[
                    lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    RESULT_RS2 +: `RV64_REG_ADDR_WIDTH];
            assign release_reg_write_o[lane] = queue_accept_o[lane] &&
                                                issue_reg_write &&
                                                (issue_rd != `RV64_REG_X0);
            assign release_rd_addr_o[
                lane*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH] = issue_rd;

            assign gpr_write_o[lane] = retire_arch_o[lane] &&
                                       result_reg_write &&
                                       (result_rd != `RV64_REG_X0);
            assign gpr_rd_addr_o[
                lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = new_phys;
            assign gpr_rd_data_o[lane*`RV64_XLEN +: `RV64_XLEN] =
                queue_result_i[
                    lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    RESULT_DATA +: `RV64_XLEN];
        end
    endgenerate

    wire csr_write0 = arch0 && queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WRITE];
    wire csr_write1 = arch1 && queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WRITE];
    wire csr_write2 = arch2 && queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WRITE];
    assign csr_write_o = csr_write0 || csr_write1 || csr_write2;
    assign csr_addr_o = csr_write0 ? queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH] :
        csr_write1 ? queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH] : queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_ADDR +:
        `RV64_FUNCT12_WIDTH];
    assign csr_wdata_o = csr_write0 ? queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN] :
        csr_write1 ? queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN] : queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_CSR_WDATA +:
        `RV64_XLEN];

    wire exception_event0 = accept0 && exception0;
    wire exception_event1 = accept1 && exception1;
    wire exception_event2 = accept2 && exception2;
    assign exception_o = exception_event0 || exception_event1 ||
                         exception_event2;
    assign halt_o = (accept0 && halt0) || (accept1 && halt1) ||
                    (accept2 && halt2);

    wire mret0 = arch0 && queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_MRET];
    wire mret1 = arch1 && queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_MRET];
    wire mret2 = arch2 && queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_MRET];
    wire sret0 = arch0 && queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_SRET];
    wire sret1 = arch1 && queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_SRET];
    wire sret2 = arch2 && queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_SRET];
    assign mret_o = mret0 || mret1 || mret2;
    assign sret_o = sret0 || sret1 || sret2;

    wire [`RV64_INSTR_WIDTH-1:0] instr0 = queue_result_i[
        0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_INSTR +:
        `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr1 = queue_result_i[
        1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_INSTR +:
        `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr2 = queue_result_i[
        2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + RESULT_INSTR +:
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
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] event_result =
        queue_result_i[event_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                       `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
    assign cause_o = irq_o ? irq_cause_i :
        event_result[RESULT_CAUSE +: `RV64_EXCEPT_CAUSE_WIDTH];
    assign pc_o = event_result[RESULT_PC +: `RV64_XLEN];
    assign next_pc_o = event_result[RESULT_NEXT_PC +: `RV64_XLEN];
    assign tval_o = exception_o ?
        event_result[RESULT_TVAL +: `RV64_XLEN] : {`RV64_XLEN{1'b0}};
    assign trace_id_o = event_result[RESULT_TRACE +: 64];
    assign instr_o = event_result[RESULT_INSTR +: `RV64_INSTR_WIDTH];
    assign trace_rd_o = event_result[RESULT_RD +: `RV64_REG_ADDR_WIDTH];
    assign trace_wdata_o = event_result[RESULT_DATA +: `RV64_XLEN];

endmodule
