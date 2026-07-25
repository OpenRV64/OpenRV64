/*
 * Enter the STREAM-style workload through a non-identity Sv39 mapping:
 *
 *   supervisor VA 0x40000000-0x4003ffff
 *       -> PA 0x80000000-0x8003ffff
 *
 * The boot page and page tables remain machine-mode physical objects.
 */

.section .text.boot, "ax", @progbits
.option norvc
.globl stream_vm_boot
.type stream_vm_boot, @function

stream_vm_boot:
    la      t0, machine_trap
    csrw    mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    /* Permit supervisor reads of the cycle shadow CSR. */
    li      t0, 1
    csrw    mcounteren, t0

    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    la      t0, _start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

machine_trap:
    csrr    t0, mcause
    li      t1, 3
    bne     t0, t1, machine_fail
    li      t1, 0x53545245414d4f4b
    bne     a0, t1, machine_fail
    j       stream_vm_done

machine_fail:
    li      a0, 0x564d4641494c

.globl stream_vm_done
stream_vm_done:
    nop
.Lmachine_halt:
    j       .Lmachine_halt

.size stream_vm_boot, .-stream_vm_boot

/*
 * Three-level Sv39 tables.  Sixty-four 4 KiB leaves map the complete 256 KiB
 * supervisor aperture.  A/D are preset for the current Svade semantics.
 */
.section .page_table.root, "a", @progbits
.balign 4096
.globl root_page_table
root_page_table:
    .zero 8
    /* VPN[2] 1 -> physical 0x80041000. */
    .dword 0x0000000020010401
    .zero 4096 - 16

.section .page_table.level1, "a", @progbits
.balign 4096
level1_page_table:
    /* VPN[1] 0 -> physical 0x80042000. */
    .dword 0x0000000020010801
    .zero 4096 - 8

.section .page_table.level0, "a", @progbits
.balign 4096
level0_page_table:
    .set vm_leaf_pte, 0x00000000200000cf
    .rept 64
        .dword vm_leaf_pte
        .set vm_leaf_pte, vm_leaf_pte + 0x400
    .endr
    .zero (512 - 64) * 8
