/*
 * Single-hart Sv39 runtime for freestanding C workloads.
 *
 * The matching linker script maps supervisor VA 0x40000000-0x4003ffff to
 * physical 0x80000000-0x8003ffff. Page-table A/D bits are preset for Svade.
 * main() returns through an S-mode EBREAK; the M-mode terminal trap preserves
 * a0 for a normal return and replaces it on an unexpected exception.
 */

.equ OPENRV64_RUNTIME_TRAP_FAIL, 0x52554e544641494c /* "RUNTFAIL" */

.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    la      t0, openrv64_runtime_machine_trap
    csrw    mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    /* Permit supervisor reads of cycle and instret. */
    li      t0, 0x5
    csrw    mcounteren, t0

    la      t0, openrv64_runtime_root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    la      t0, openrv64_runtime_s_start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

openrv64_runtime_machine_trap:
    csrr    t0, mcause
    li      t1, 3
    beq     t0, t1, openrv64_runtime_done
    li      a0, OPENRV64_RUNTIME_TRAP_FAIL

.globl openrv64_runtime_done
openrv64_runtime_done:
    nop
.Lmachine_halt:
    j       .Lmachine_halt

.size _start, .-_start

.section .page_table.root, "a", @progbits
.balign 4096
.globl openrv64_runtime_root_page_table
openrv64_runtime_root_page_table:
    .zero 8
    /* VPN[2] 1 -> physical 0x80041000. */
    .dword 0x0000000020010401
    .zero 4096 - 16

.section .page_table.level1, "a", @progbits
.balign 4096
openrv64_runtime_level1_page_table:
    /* VPN[1] 0 -> physical 0x80042000. */
    .dword 0x0000000020010801
    .zero 4096 - 8

.section .page_table.level0, "a", @progbits
.balign 4096
openrv64_runtime_level0_page_table:
    /* Supervisor RWX leaves, global, with A/D preset. */
    .set openrv64_runtime_leaf_pte, 0x00000000200000cf
    .rept 64
        .dword openrv64_runtime_leaf_pte
        .set openrv64_runtime_leaf_pte, \
            openrv64_runtime_leaf_pte + 0x400
    .endr
    .zero (512 - 64) * 8

#include "c_start.inc"

OPENRV64_DEFINE_C_START openrv64_runtime_s_start, \
    openrv64_runtime_s_exit
