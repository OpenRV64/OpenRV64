.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

/*
 * Enter the CoreMark-derived loop through a non-identity Sv39 mapping:
 *
 *   supervisor VA 0x40000000-0x4001ffff
 *       -> PA 0x80000000-0x8001ffff
 *
 * The boot code and page tables remain machine-mode physical objects.  The
 * virtual alias is deliberate: a missing or bypassed translation cannot fetch
 * the supervisor image from the physical RAM aperture.
 */
_start:
    la   t0, machine_trap
    csrw mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li   t0, 0x201fffff
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0

    la   t0, root_page_table
    srli t0, t0, 12
    li   t1, 8
    slli t1, t1, 60
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma x0, x0

    la   t0, supervisor_start
    csrw mepc, t0
    li   t0, 0x800
    csrw mstatus, t0
    mret

machine_trap:
    li   a0, 0x564d4641494c
    ebreak
.Lmachine_halt:
    j    .Lmachine_halt

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la   sp, __stack_top
    li   tp, 0
    call coremark_loop
    .globl coremark_vm_done
coremark_vm_done:
    addi x0, x0, 0
.Lsupervisor_halt:
    j    .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

/*
 * Three-level Sv39 tables.  The 128 KiB supervisor aperture uses 32 4 KiB
 * leaves with A/D preset because the current walker implements Svade
 * semantics.
 */
.section .page_table.root, "a", @progbits
.balign 4096
.globl root_page_table
root_page_table:
    .zero 8
    /* VPN[2] 1 -> physical 0x80021000. */
    .dword 0x0000000020008401
    .zero 4096 - 16

.section .page_table.level1, "a", @progbits
.balign 4096
level1_page_table:
    /* VPN[1] 0 -> physical 0x80022000. */
    .dword 0x0000000020008801
    .zero 4096 - 8

.section .page_table.level0, "a", @progbits
.balign 4096
level0_page_table:
    .set vm_leaf_pte, 0x00000000200000cf
    .rept 32
        .dword vm_leaf_pte
        .set vm_leaf_pte, vm_leaf_pte + 0x400
    .endr
    .zero (512 - 32) * 8
