`ifndef OPENRV64_RV64_PRIV_V
`define OPENRV64_RV64_PRIV_V

`include "core/isa/rv64-i.v"

// Privileged trap-return instructions.
`define RV64_PRIV_FUNCT12_SRET 12'h102
`define RV64_PRIV_FUNCT12_MRET 12'h302
`define RV64_PRIV_FUNCT12_WFI  12'h105
`define RV64_INSTR_SRET 32'h1020_0073
`define RV64_INSTR_MRET 32'h3020_0073
`define RV64_INSTR_WFI  32'h1050_0073
`define RV64_PRIV_FUNCT7_SFENCE_VMA 7'b0001001
`define RV64_INSTR_SFENCE_VMA_MASK 32'hfe00_7fff
`define RV64_INSTR_SFENCE_VMA_MATCH 32'h1200_0073
`define RV64_IS_SFENCE_VMA(instr) \
    (((instr) & `RV64_INSTR_SFENCE_VMA_MASK) == \
     `RV64_INSTR_SFENCE_VMA_MATCH)

// Supervisor trap setup, handling, and address-translation CSRs.
`define RV64_CSR_SSTATUS    12'h100
`define RV64_CSR_SIE        12'h104
`define RV64_CSR_STVEC      12'h105
`define RV64_CSR_SCOUNTEREN 12'h106
`define RV64_CSR_SSCRATCH   12'h140
`define RV64_CSR_SEPC       12'h141
`define RV64_CSR_SCAUSE     12'h142
`define RV64_CSR_STVAL      12'h143
`define RV64_CSR_SIP        12'h144
`define RV64_CSR_SATP       12'h180

// Machine information and trap-setup CSRs.
`define RV64_CSR_MVENDORID  12'hf11
`define RV64_CSR_MARCHID    12'hf12
`define RV64_CSR_MIMPID     12'hf13
`define RV64_CSR_MHARTID    12'hf14
`define RV64_CSR_MCONFIGPTR 12'hf15
`define RV64_CSR_MSTATUS    12'h300
`define RV64_CSR_MISA       12'h301
`define RV64_CSR_MEDELEG    12'h302
`define RV64_CSR_MIDELEG    12'h303
`define RV64_CSR_MIE        12'h304
`define RV64_CSR_MTVEC      12'h305
`define RV64_CSR_MCOUNTEREN 12'h306
`define RV64_CSR_MCOUNTINHIBIT 12'h320
`define RV64_CSR_MHPMEVENT3  12'h323
`define RV64_CSR_MHPMEVENT31 12'h33f
`define RV64_CSR_MSCRATCH   12'h340
`define RV64_CSR_MEPC       12'h341
`define RV64_CSR_MCAUSE     12'h342
`define RV64_CSR_MTVAL      12'h343
`define RV64_CSR_MIP        12'h344
`define RV64_CSR_PMPCFG0    12'h3a0
`define RV64_CSR_PMPCFG2    12'h3a2
`define RV64_CSR_PMPADDR0   12'h3b0
`define RV64_CSR_PMPADDR1   12'h3b1
`define RV64_CSR_PMPADDR2   12'h3b2
`define RV64_CSR_PMPADDR3   12'h3b3
`define RV64_CSR_PMPADDR4   12'h3b4
`define RV64_CSR_PMPADDR5   12'h3b5
`define RV64_CSR_PMPADDR6   12'h3b6
`define RV64_CSR_PMPADDR7   12'h3b7
`define RV64_CSR_PMPADDR8   12'h3b8
`define RV64_CSR_PMPADDR9   12'h3b9
`define RV64_CSR_PMPADDR10  12'h3ba
`define RV64_CSR_PMPADDR11  12'h3bb
`define RV64_CSR_PMPADDR12  12'h3bc
`define RV64_CSR_PMPADDR13  12'h3bd
`define RV64_CSR_PMPADDR14  12'h3be
`define RV64_CSR_PMPADDR15  12'h3bf
`define RV64_CSR_MCYCLE     12'hb00
`define RV64_CSR_MINSTRET   12'hb02
`define RV64_CSR_MHPMCOUNTER3  12'hb03
`define RV64_CSR_MHPMCOUNTER31 12'hb1f
`define RV64_CSR_CYCLE      12'hc00
`define RV64_CSR_TIME       12'hc01
`define RV64_CSR_INSTRET    12'hc02
`define RV64_CSR_HPMCOUNTER3  12'hc03
`define RV64_CSR_HPMCOUNTER31 12'hc1f

// Current privilege encoding.
`define RV64_PRIV_WIDTH 2
`define RV64_PRIV_U 2'b00
`define RV64_PRIV_S 2'b01
`define RV64_PRIV_M 2'b11

// Implemented mstatus/sstatus fields.
`define RV64_MSTATUS_SIE_BIT 1
`define RV64_MSTATUS_MIE_BIT 3
`define RV64_MSTATUS_SPIE_BIT 5
`define RV64_MSTATUS_MPIE_BIT 7
`define RV64_MSTATUS_SPP_BIT 8
`define RV64_MSTATUS_MPP_BITS 12:11
`define RV64_MSTATUS_MPRV_BIT 17
`define RV64_MSTATUS_SUM_BIT 18
`define RV64_MSTATUS_MXR_BIT 19
`define RV64_MSTATUS_TVM_BIT 20
`define RV64_MSTATUS_TW_BIT 21
`define RV64_MSTATUS_TSR_BIT 22
`define RV64_MSTATUS_UXL_BITS 33:32
`define RV64_MSTATUS_SXL_BITS 35:34
`define RV64_MSTATUS_MPP_U 2'b00
`define RV64_MSTATUS_MPP_S 2'b01
`define RV64_MSTATUS_MPP_M 2'b11
`define RV64_MSTATUS_UXL_64 2'b10
`define RV64_MSTATUS_SXL_64 2'b10

// Machine counter control bits.
`define RV64_MCOUNTER_CY_BIT 0
`define RV64_MCOUNTER_TM_BIT 1
`define RV64_MCOUNTER_IR_BIT 2

// Physical memory protection configuration byte fields.
`define RV64_PMP_CFG_R_BIT 0
`define RV64_PMP_CFG_W_BIT 1
`define RV64_PMP_CFG_X_BIT 2
`define RV64_PMP_CFG_A_BITS 4:3
`define RV64_PMP_CFG_L_BIT 7
`define RV64_PMP_A_OFF   2'b00
`define RV64_PMP_A_TOR   2'b01
`define RV64_PMP_A_NA4   2'b10
`define RV64_PMP_A_NAPOT 2'b11

// Machine interrupt enable/pending bits and interrupt cause codes.
`define RV64_MIP_SSIP_BIT 1
`define RV64_MIP_MSIP_BIT 3
`define RV64_MIP_STIP_BIT 5
`define RV64_MIP_MTIP_BIT 7
`define RV64_MIP_SEIP_BIT 9
`define RV64_MIP_MEIP_BIT 11
`define RV64_IRQ_CAUSE_SUPERVISOR_SOFTWARE 5'd1
`define RV64_IRQ_CAUSE_MACHINE_SOFTWARE 5'd3
`define RV64_IRQ_CAUSE_SUPERVISOR_TIMER 5'd5
`define RV64_IRQ_CAUSE_MACHINE_TIMER 5'd7
`define RV64_IRQ_CAUSE_SUPERVISOR_EXTERNAL 5'd9
`define RV64_IRQ_CAUSE_MACHINE_EXTERNAL 5'd11

// Supervisor address translation context.
`define RV64_SATP_MODE_BITS 63:60
`define RV64_SATP_MODE_WIDTH 4
`define RV64_SATP_MODE_BARE 4'd0
`define RV64_SATP_MODE_SV39 4'd8
`define RV64_SATP_ASID_BITS 59:44
`define RV64_SATP_ASID_WIDTH 16
`define RV64_SATP_PPN_BITS 43:0
`define RV64_SATP_PPN_WIDTH 44

// Sv39 page-table entry fields and page levels.
`define RV64_PTE_V_BIT 0
`define RV64_PTE_R_BIT 1
`define RV64_PTE_W_BIT 2
`define RV64_PTE_X_BIT 3
`define RV64_PTE_U_BIT 4
`define RV64_PTE_G_BIT 5
`define RV64_PTE_A_BIT 6
`define RV64_PTE_D_BIT 7
`define RV64_PTE_PPN_BITS 53:10
`define RV64_PTE_RESERVED_BITS 63:54
`define RV64_PAGE_LEVEL_WIDTH 2
`define RV64_PAGE_LEVEL_4K 2'd0
`define RV64_PAGE_LEVEL_2M 2'd1
`define RV64_PAGE_LEVEL_1G 2'd2

`endif
