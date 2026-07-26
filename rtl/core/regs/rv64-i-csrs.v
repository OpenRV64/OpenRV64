`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"
`include "core/cmu/defs.v"

module openrv64_rv64i_csrs #(
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_RV64A = 1,
    parameter integer HPM_COUNTERS = 8,
    parameter [`RV64_XLEN-1:0] HART_ID = {`RV64_XLEN{1'b0}}
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_FUNCT12_WIDTH-1:0]  csr_addr_i,
    output reg  [`RV64_XLEN-1:0]           csr_rdata_o,
    output reg                              csr_valid_o,
    output reg                              csr_writable_o,
    input  wire                             csr_write_i,
    input  wire [`RV64_XLEN-1:0]           csr_wdata_i,

    input  wire                             trap_enter_i,
    input  wire                             trap_interrupt_i,
    input  wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trap_cause_i,
    input  wire [`RV64_XLEN-1:0]           trap_pc_i,
    input  wire [`RV64_XLEN-1:0]           trap_tval_i,
    input  wire                             mret_i,
    input  wire                             sret_i,
    input  wire [1:0]                       retire_count_i,
    input  wire [`OPENRV64_CMU_EVENT_COUNT-1:0] perf_events_i,

    input  wire                             irq_software_i,
    input  wire                             irq_timer_i,
    input  wire                             irq_external_i,
    input  wire                             irq_s_software_i,
    input  wire                             irq_s_timer_i,
    input  wire                             irq_s_external_i,
    output reg                              irq_pending_o,
    output reg  [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause_o,
    output wire [`RV64_XLEN-1:0]           trap_vector_o,
    output wire                             trap_to_s_o,
    output wire [`RV64_XLEN-1:0]           mepc_o,
    output wire [`RV64_XLEN-1:0]           sepc_o,

    output wire [`RV64_PRIV_WIDTH-1:0]     priv_mode_o,
    output wire [`RV64_PRIV_WIDTH-1:0]     data_priv_mode_o,
    output wire                             sret_allowed_o,
    output wire                             sfence_vma_allowed_o,
    output wire [`RV64_SATP_MODE_WIDTH-1:0] satp_mode_o,
    output wire [`RV64_SATP_ASID_WIDTH-1:0] satp_asid_o,
    output wire [`RV64_SATP_PPN_WIDTH-1:0] satp_root_ppn_o,
    output wire                             status_sum_o,
    output wire                             status_mxr_o,
    input  wire [`RV64_XLEN-1:0]           pmp_instr_addr_i,
    output wire                             pmp_instr_allow_o,
    input  wire                             pmp_data_valid_i,
    input  wire [`RV64_XLEN-1:0]           pmp_data_addr_i,
    input  wire [2:0]                       pmp_data_size_i,
    input  wire                             pmp_data_write_i,
    output wire                             pmp_data_allow_o,
    input  wire                             pmp_bus_valid_i,
    input  wire [`RV64_XLEN-1:0]           pmp_bus_addr_i,
    input  wire [2:0]                       pmp_bus_size_i,
    input  wire                             pmp_bus_write_i,
    input  wire                             pmp_bus_exec_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]     pmp_bus_priv_mode_i,
    output wire                             pmp_bus_allow_o
);

    localparam [`RV64_XLEN-1:0] BIT_SSIP = 64'd1 << `RV64_MIP_SSIP_BIT;
    localparam [`RV64_XLEN-1:0] BIT_MSIP = 64'd1 << `RV64_MIP_MSIP_BIT;
    localparam [`RV64_XLEN-1:0] BIT_STIP = 64'd1 << `RV64_MIP_STIP_BIT;
    localparam [`RV64_XLEN-1:0] BIT_MTIP = 64'd1 << `RV64_MIP_MTIP_BIT;
    localparam [`RV64_XLEN-1:0] BIT_SEIP = 64'd1 << `RV64_MIP_SEIP_BIT;
    localparam [`RV64_XLEN-1:0] BIT_MEIP = 64'd1 << `RV64_MIP_MEIP_BIT;
    localparam [`RV64_XLEN-1:0] MIP_S_MASK = BIT_SSIP | BIT_STIP | BIT_SEIP;
    localparam [`RV64_XLEN-1:0] MIP_M_MASK = BIT_MSIP | BIT_MTIP | BIT_MEIP;
    localparam [`RV64_XLEN-1:0] MIP_MASK = MIP_S_MASK | MIP_M_MASK;
    // M-mode firmware uses mip.STIP to inject an SBI timer event into S-mode.
    localparam [`RV64_XLEN-1:0] MIP_SW_WRITABLE_MASK =
        BIT_SSIP | BIT_MSIP | BIT_STIP;
    localparam [`RV64_XLEN-1:0] MEDELEG_MASK =
        (64'd1 << `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED) |
        (64'd1 << `RV64_EXCEPT_CAUSE_INSTR_ACCESS_FAULT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR) |
        (64'd1 << `RV64_EXCEPT_CAUSE_BREAKPOINT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_LOAD_ADDR_MISALIGNED) |
        (64'd1 << `RV64_EXCEPT_CAUSE_LOAD_ACCESS_FAULT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED) |
        (64'd1 << `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_ECALL_U) |
        (64'd1 << `RV64_EXCEPT_CAUSE_ECALL_S) |
        (64'd1 << `RV64_EXCEPT_CAUSE_INSTR_PAGE_FAULT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_LOAD_PAGE_FAULT) |
        (64'd1 << `RV64_EXCEPT_CAUSE_STORE_PAGE_FAULT);
    localparam [`RV64_XLEN-1:0] MIDELEG_MASK = MIP_S_MASK;
    localparam [`RV64_XLEN-1:0] SSTATUS_RW_MASK =
        (64'd1 << `RV64_MSTATUS_SIE_BIT) |
        (64'd1 << `RV64_MSTATUS_SPIE_BIT) |
        (64'd1 << `RV64_MSTATUS_SPP_BIT) |
        (64'd1 << `RV64_MSTATUS_SUM_BIT) |
        (64'd1 << `RV64_MSTATUS_MXR_BIT);
    localparam [`RV64_XLEN-1:0] SSTATUS_READ_MASK =
        SSTATUS_RW_MASK | (64'd3 << 32);
    localparam [`RV64_XLEN-1:0] MISA_VALUE =
        (64'd2 << 62) |
        (ENABLE_RV64A ? (64'd1 << 0) : 64'd0) |
        (64'd1 << 8) |
        (ENABLE_RV64M ? (64'd1 << 12) : 64'd0) |
        (64'd1 << 18) |
        (64'd1 << 20);

    reg [`RV64_XLEN-1:0] mstatus_q;
    reg [`RV64_XLEN-1:0] medeleg_q;
    reg [`RV64_XLEN-1:0] mideleg_q;
    reg [`RV64_XLEN-1:0] mie_q;
    reg [`RV64_XLEN-1:0] mtvec_q;
    reg [`RV64_XLEN-1:0] mscratch_q;
    reg [`RV64_XLEN-1:0] mepc_q;
    reg [`RV64_XLEN-1:0] mcause_q;
    reg [`RV64_XLEN-1:0] mtval_q;
    reg [`RV64_XLEN-1:0] mip_sw_q;
    reg [`RV64_XLEN-1:0] stvec_q;
    reg [`RV64_XLEN-1:0] sscratch_q;
    reg [`RV64_XLEN-1:0] sepc_q;
    reg [`RV64_XLEN-1:0] scause_q;
    reg [`RV64_XLEN-1:0] stval_q;
    reg [`RV64_XLEN-1:0] satp_q;
    reg [`RV64_PRIV_WIDTH-1:0] priv_mode_q;

    wire [`RV64_XLEN-1:0] pmp_csr_rdata;
    wire pmp_csr_match;
    wire pmp_csr_writable;
    wire [`RV64_XLEN-1:0] cmu_csr_rdata;
    wire cmu_csr_match;
    wire cmu_csr_valid;
    wire cmu_csr_writable;

    wire [`RV64_XLEN-1:0] mip_external =
        (irq_s_software_i ? BIT_SSIP : 64'd0) |
        (irq_software_i ? BIT_MSIP : 64'd0) |
        (irq_s_timer_i ? BIT_STIP : 64'd0) |
        (irq_timer_i ? BIT_MTIP : 64'd0) |
        (irq_s_external_i ? BIT_SEIP : 64'd0) |
        (irq_external_i ? BIT_MEIP : 64'd0);
    wire [`RV64_XLEN-1:0] mip_value = (mip_sw_q | mip_external) & MIP_MASK;
    wire [`RV64_XLEN-1:0] enabled_pending = mie_q & mip_value;
    wire trap_delegated = (priv_mode_q != `RV64_PRIV_M) &&
                           (trap_interrupt_i ? mideleg_q[trap_cause_i] :
                                               medeleg_q[trap_cause_i]);
    wire [`RV64_XLEN-1:0] selected_tvec = trap_delegated ? stvec_q : mtvec_q;
    wire selected_tvec_vectored = (selected_tvec[1:0] == 2'b01);
    wire [`RV64_XLEN-1:0] selected_tvec_base =
        {selected_tvec[`RV64_XLEN-1:2], 2'b00};
    wire [`RV64_XLEN-1:0] trap_offset =
        {{(`RV64_XLEN-`RV64_EXCEPT_CAUSE_WIDTH-2){1'b0}},
         trap_cause_i, 2'b00};
    wire [`RV64_PRIV_WIDTH-1:0] mpp_value =
        (mstatus_q[`RV64_MSTATUS_MPP_BITS] == 2'b10) ?
        `RV64_PRIV_U : mstatus_q[`RV64_MSTATUS_MPP_BITS];
    wire [`RV64_PRIV_WIDTH-1:0] pmp_data_priv =
        ((priv_mode_q == `RV64_PRIV_M) &&
         mstatus_q[`RV64_MSTATUS_MPRV_BIT]) ? mpp_value : priv_mode_q;
    wire csr_privilege_ok =
        (priv_mode_q >= csr_addr_i[9:8]);
    wire satp_access_ok = !((csr_addr_i == `RV64_CSR_SATP) &&
                            (priv_mode_q == `RV64_PRIV_S) &&
                            mstatus_q[`RV64_MSTATUS_TVM_BIT]);

    assign trap_vector_o = selected_tvec_base +
                           ((trap_interrupt_i && selected_tvec_vectored) ?
                            trap_offset : 64'd0);
    assign trap_to_s_o = trap_delegated;
    assign mepc_o = mepc_q;
    assign sepc_o = sepc_q;
    assign priv_mode_o = priv_mode_q;
    assign data_priv_mode_o = pmp_data_priv;
    assign sret_allowed_o = (priv_mode_q == `RV64_PRIV_M) ||
                            ((priv_mode_q == `RV64_PRIV_S) &&
                             !mstatus_q[`RV64_MSTATUS_TSR_BIT]);
    assign sfence_vma_allowed_o = (priv_mode_q == `RV64_PRIV_M) ||
        ((priv_mode_q == `RV64_PRIV_S) &&
         !mstatus_q[`RV64_MSTATUS_TVM_BIT]);
    assign satp_mode_o = satp_q[`RV64_SATP_MODE_BITS];
    assign satp_asid_o = satp_q[`RV64_SATP_ASID_BITS];
    assign satp_root_ppn_o = satp_q[`RV64_SATP_PPN_BITS];
    assign status_sum_o = mstatus_q[`RV64_MSTATUS_SUM_BIT];
    assign status_mxr_o = mstatus_q[`RV64_MSTATUS_MXR_BIT];

    openrv64_cmu #(
        .HPM_COUNTERS(HPM_COUNTERS)
    ) u_cmu (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(csr_addr_i),
        .csr_write_i(csr_write_i),
        .csr_wdata_i(csr_wdata_i),
        .priv_mode_i(priv_mode_q),
        .csr_rdata_o(cmu_csr_rdata),
        .csr_match_o(cmu_csr_match),
        .csr_valid_o(cmu_csr_valid),
        .csr_writable_o(cmu_csr_writable),
        .retire_count_i(retire_count_i),
        .event_pulses_i(perf_events_i)
    );

    openrv64_rv64i_pmp u_pmp (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(csr_addr_i),
        .csr_rdata_o(pmp_csr_rdata),
        .csr_match_o(pmp_csr_match),
        .csr_writable_o(pmp_csr_writable),
        .csr_write_i(csr_write_i && csr_valid_o && csr_writable_o &&
                     pmp_csr_match && pmp_csr_writable),
        .csr_wdata_i(csr_wdata_i),
        .instr_priv_mode_i(priv_mode_q),
        .data_priv_mode_i(pmp_data_priv),
        .instr_addr_i(pmp_instr_addr_i),
        .instr_allow_o(pmp_instr_allow_o),
        .data_valid_i(pmp_data_valid_i),
        .data_addr_i(pmp_data_addr_i),
        .data_size_i(pmp_data_size_i),
        .data_write_i(pmp_data_write_i),
        .data_allow_o(pmp_data_allow_o),
        .bus_valid_i(pmp_bus_valid_i),
        .bus_addr_i(pmp_bus_addr_i),
        .bus_size_i(pmp_bus_size_i),
        .bus_write_i(pmp_bus_write_i),
        .bus_exec_i(pmp_bus_exec_i),
        .bus_priv_mode_i(pmp_bus_priv_mode_i),
        .bus_allow_o(pmp_bus_allow_o)
    );

    function irq_eligible;
        input [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
        input [`RV64_XLEN-1:0] interrupt_delegation;
        input [`RV64_PRIV_WIDTH-1:0] current_privilege;
        input [`RV64_XLEN-1:0] current_status;
        reg delegated;
        begin
            delegated = interrupt_delegation[cause];
            if (delegated) begin
                irq_eligible = (current_privilege != `RV64_PRIV_M) &&
                    ((current_privilege == `RV64_PRIV_U) ||
                     current_status[`RV64_MSTATUS_SIE_BIT]);
            end else begin
                irq_eligible = (current_privilege != `RV64_PRIV_M) ||
                    current_status[`RV64_MSTATUS_MIE_BIT];
            end
        end
    endfunction

    always @* begin
        irq_pending_o = 1'b0;
        irq_cause_o = `RV64_IRQ_CAUSE_MACHINE_TIMER;

        if (enabled_pending[`RV64_MIP_MEIP_BIT] &&
            irq_eligible(`RV64_IRQ_CAUSE_MACHINE_EXTERNAL,
                         mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_MACHINE_EXTERNAL;
        end else if (enabled_pending[`RV64_MIP_MSIP_BIT] &&
                     irq_eligible(`RV64_IRQ_CAUSE_MACHINE_SOFTWARE,
                                  mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_MACHINE_SOFTWARE;
        end else if (enabled_pending[`RV64_MIP_MTIP_BIT] &&
                     irq_eligible(`RV64_IRQ_CAUSE_MACHINE_TIMER,
                                  mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_MACHINE_TIMER;
        end else if (enabled_pending[`RV64_MIP_SEIP_BIT] &&
                     irq_eligible(`RV64_IRQ_CAUSE_SUPERVISOR_EXTERNAL,
                                  mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_SUPERVISOR_EXTERNAL;
        end else if (enabled_pending[`RV64_MIP_SSIP_BIT] &&
                     irq_eligible(`RV64_IRQ_CAUSE_SUPERVISOR_SOFTWARE,
                                  mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_SUPERVISOR_SOFTWARE;
        end else if (enabled_pending[`RV64_MIP_STIP_BIT] &&
                     irq_eligible(`RV64_IRQ_CAUSE_SUPERVISOR_TIMER,
                                  mideleg_q, priv_mode_q, mstatus_q)) begin
            irq_pending_o = 1'b1;
            irq_cause_o = `RV64_IRQ_CAUSE_SUPERVISOR_TIMER;
        end
    end

    always @* begin
        csr_rdata_o = {`RV64_XLEN{1'b0}};
        csr_valid_o = 1'b1;
        csr_writable_o = 1'b1;

        case (csr_addr_i)
            `RV64_CSR_SSTATUS: csr_rdata_o = mstatus_q & SSTATUS_READ_MASK;
            `RV64_CSR_SIE: csr_rdata_o = mie_q & mideleg_q & MIP_S_MASK;
            `RV64_CSR_STVEC: csr_rdata_o = stvec_q;
            `RV64_CSR_SSCRATCH: csr_rdata_o = sscratch_q;
            `RV64_CSR_SEPC: csr_rdata_o = sepc_q;
            `RV64_CSR_SCAUSE: csr_rdata_o = scause_q;
            `RV64_CSR_STVAL: csr_rdata_o = stval_q;
            `RV64_CSR_SIP: csr_rdata_o = mip_value & mideleg_q & MIP_S_MASK;
            `RV64_CSR_SATP: csr_rdata_o = satp_q;

            `RV64_CSR_MSTATUS: csr_rdata_o = mstatus_q;
            `RV64_CSR_MISA: begin
                csr_rdata_o = MISA_VALUE;
                csr_writable_o = 1'b0;
            end
            `RV64_CSR_MEDELEG: csr_rdata_o = medeleg_q;
            `RV64_CSR_MIDELEG: csr_rdata_o = mideleg_q;
            `RV64_CSR_MIE: csr_rdata_o = mie_q;
            `RV64_CSR_MTVEC: csr_rdata_o = mtvec_q;
            `RV64_CSR_MSCRATCH: csr_rdata_o = mscratch_q;
            `RV64_CSR_MEPC: csr_rdata_o = mepc_q;
            `RV64_CSR_MCAUSE: csr_rdata_o = mcause_q;
            `RV64_CSR_MTVAL: csr_rdata_o = mtval_q;
            `RV64_CSR_MIP: csr_rdata_o = mip_value;

            `RV64_CSR_MVENDORID,
            `RV64_CSR_MARCHID,
            `RV64_CSR_MIMPID,
            `RV64_CSR_MCONFIGPTR: begin
                csr_rdata_o = {`RV64_XLEN{1'b0}};
                csr_writable_o = 1'b0;
            end
            `RV64_CSR_MHARTID: begin
                csr_rdata_o = HART_ID;
                csr_writable_o = 1'b0;
            end

            default: begin
                if (cmu_csr_match) begin
                    csr_rdata_o = cmu_csr_rdata;
                    csr_valid_o = cmu_csr_valid;
                    csr_writable_o = cmu_csr_writable;
                end else if (pmp_csr_match) begin
                    csr_rdata_o = pmp_csr_rdata;
                    csr_writable_o = pmp_csr_writable;
                end else begin
                    csr_valid_o = 1'b0;
                    csr_writable_o = 1'b0;
                end
            end
        endcase

        if (!csr_privilege_ok || !satp_access_ok) begin
            csr_rdata_o = {`RV64_XLEN{1'b0}};
            csr_valid_o = 1'b0;
            csr_writable_o = 1'b0;
        end

        if (csr_addr_i[11:10] == 2'b11) begin
            csr_writable_o = 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_q <= (64'd2 << 34) |
                         (64'd2 << 32) |
                         (64'd3 << 11);
            medeleg_q <= 64'd0;
            mideleg_q <= 64'd0;
            mie_q <= 64'd0;
            mtvec_q <= 64'd0;
            mscratch_q <= 64'd0;
            mepc_q <= 64'd0;
            mcause_q <= 64'd0;
            mtval_q <= 64'd0;
            mip_sw_q <= 64'd0;
            stvec_q <= 64'd0;
            sscratch_q <= 64'd0;
            sepc_q <= 64'd0;
            scause_q <= 64'd0;
            stval_q <= 64'd0;
            satp_q <= 64'd0;
            priv_mode_q <= `RV64_PRIV_M;
        end else if (trap_enter_i) begin
            if (trap_delegated) begin
                mstatus_q[`RV64_MSTATUS_SPIE_BIT] <=
                    mstatus_q[`RV64_MSTATUS_SIE_BIT];
                mstatus_q[`RV64_MSTATUS_SIE_BIT] <= 1'b0;
                mstatus_q[`RV64_MSTATUS_SPP_BIT] <=
                    (priv_mode_q == `RV64_PRIV_S);
                priv_mode_q <= `RV64_PRIV_S;
                sepc_q <= {trap_pc_i[`RV64_XLEN-1:2], 2'b00};
                scause_q <= {trap_interrupt_i,
                    {(`RV64_XLEN-`RV64_EXCEPT_CAUSE_WIDTH-1){1'b0}},
                    trap_cause_i};
                stval_q <= trap_tval_i;
            end else begin
                mstatus_q[`RV64_MSTATUS_MPIE_BIT] <=
                    mstatus_q[`RV64_MSTATUS_MIE_BIT];
                mstatus_q[`RV64_MSTATUS_MIE_BIT] <= 1'b0;
                mstatus_q[`RV64_MSTATUS_MPP_BITS] <= priv_mode_q;
                priv_mode_q <= `RV64_PRIV_M;
                mepc_q <= {trap_pc_i[`RV64_XLEN-1:2], 2'b00};
                mcause_q <= {trap_interrupt_i,
                    {(`RV64_XLEN-`RV64_EXCEPT_CAUSE_WIDTH-1){1'b0}},
                    trap_cause_i};
                mtval_q <= trap_tval_i;
            end
        end else if (mret_i) begin
            mstatus_q[`RV64_MSTATUS_MIE_BIT] <=
                mstatus_q[`RV64_MSTATUS_MPIE_BIT];
            mstatus_q[`RV64_MSTATUS_MPIE_BIT] <= 1'b1;
            mstatus_q[`RV64_MSTATUS_MPP_BITS] <= `RV64_MSTATUS_MPP_U;
            if (mpp_value != `RV64_PRIV_M) begin
                mstatus_q[`RV64_MSTATUS_MPRV_BIT] <= 1'b0;
            end
            priv_mode_q <= mpp_value;
        end else if (sret_i) begin
            mstatus_q[`RV64_MSTATUS_SIE_BIT] <=
                mstatus_q[`RV64_MSTATUS_SPIE_BIT];
            mstatus_q[`RV64_MSTATUS_SPIE_BIT] <= 1'b1;
            mstatus_q[`RV64_MSTATUS_SPP_BIT] <= 1'b0;
            mstatus_q[`RV64_MSTATUS_MPRV_BIT] <= 1'b0;
            priv_mode_q <= mstatus_q[`RV64_MSTATUS_SPP_BIT] ?
                `RV64_PRIV_S : `RV64_PRIV_U;
        end else if (csr_write_i && csr_valid_o && csr_writable_o) begin
            case (csr_addr_i)
                `RV64_CSR_SSTATUS: begin
                    mstatus_q <= (mstatus_q & ~SSTATUS_RW_MASK) |
                                 (csr_wdata_i & SSTATUS_RW_MASK);
                end
                `RV64_CSR_SIE: begin
                    mie_q <= (mie_q & ~MIP_S_MASK) |
                             (csr_wdata_i & mideleg_q & MIP_S_MASK);
                end
                `RV64_CSR_STVEC: begin
                    stvec_q <= {csr_wdata_i[`RV64_XLEN-1:2],
                        (csr_wdata_i[1:0] == 2'b01) ? 2'b01 : 2'b00};
                end
                `RV64_CSR_SSCRATCH: sscratch_q <= csr_wdata_i;
                `RV64_CSR_SEPC: sepc_q <= {csr_wdata_i[`RV64_XLEN-1:2], 2'b00};
                `RV64_CSR_SCAUSE: scause_q <= csr_wdata_i;
                `RV64_CSR_STVAL: stval_q <= csr_wdata_i;
                `RV64_CSR_SIP: begin
                    mip_sw_q <= (mip_sw_q & ~BIT_SSIP) |
                        (csr_wdata_i & mideleg_q & BIT_SSIP);
                end
                `RV64_CSR_SATP: begin
                    case (csr_wdata_i[`RV64_SATP_MODE_BITS])
                        `RV64_SATP_MODE_BARE: satp_q <= 64'd0;
                        `RV64_SATP_MODE_SV39: satp_q <= csr_wdata_i;
                        default: begin
                        end
                    endcase
                end

                `RV64_CSR_MSTATUS: begin
                    mstatus_q[`RV64_MSTATUS_SIE_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_SIE_BIT];
                    mstatus_q[`RV64_MSTATUS_MIE_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_MIE_BIT];
                    mstatus_q[`RV64_MSTATUS_SPIE_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_SPIE_BIT];
                    mstatus_q[`RV64_MSTATUS_MPIE_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_MPIE_BIT];
                    mstatus_q[`RV64_MSTATUS_SPP_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_SPP_BIT];
                    mstatus_q[`RV64_MSTATUS_MPRV_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_MPRV_BIT];
                    mstatus_q[`RV64_MSTATUS_SUM_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_SUM_BIT];
                    mstatus_q[`RV64_MSTATUS_MXR_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_MXR_BIT];
                    mstatus_q[`RV64_MSTATUS_TVM_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_TVM_BIT];
                    mstatus_q[`RV64_MSTATUS_TW_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_TW_BIT];
                    mstatus_q[`RV64_MSTATUS_TSR_BIT] <=
                        csr_wdata_i[`RV64_MSTATUS_TSR_BIT];
                    case (csr_wdata_i[`RV64_MSTATUS_MPP_BITS])
                        `RV64_PRIV_U,
                        `RV64_PRIV_S,
                        `RV64_PRIV_M:
                            mstatus_q[`RV64_MSTATUS_MPP_BITS] <=
                                csr_wdata_i[`RV64_MSTATUS_MPP_BITS];
                        default:
                            mstatus_q[`RV64_MSTATUS_MPP_BITS] <= `RV64_PRIV_U;
                    endcase
                    mstatus_q[`RV64_MSTATUS_SXL_BITS] <= `RV64_MSTATUS_SXL_64;
                    mstatus_q[`RV64_MSTATUS_UXL_BITS] <= `RV64_MSTATUS_UXL_64;
                end
                `RV64_CSR_MEDELEG: medeleg_q <= csr_wdata_i & MEDELEG_MASK;
                `RV64_CSR_MIDELEG: mideleg_q <= csr_wdata_i & MIDELEG_MASK;
                `RV64_CSR_MIE: mie_q <= csr_wdata_i & MIP_MASK;
                `RV64_CSR_MTVEC: begin
                    mtvec_q <= {csr_wdata_i[`RV64_XLEN-1:2],
                        (csr_wdata_i[1:0] == 2'b01) ? 2'b01 : 2'b00};
                end
                `RV64_CSR_MSCRATCH: mscratch_q <= csr_wdata_i;
                `RV64_CSR_MEPC: mepc_q <= {csr_wdata_i[`RV64_XLEN-1:2], 2'b00};
                `RV64_CSR_MCAUSE: mcause_q <= csr_wdata_i;
                `RV64_CSR_MTVAL: mtval_q <= csr_wdata_i;
                `RV64_CSR_MIP: begin
                    mip_sw_q <= csr_wdata_i & MIP_SW_WRITABLE_MASK;
                end
                default: begin
                end
            endcase
        end
    end

endmodule
