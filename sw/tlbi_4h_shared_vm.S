/*
 * Four-hart Sv39 shootdown, coherence-invalidate, and LR/SC interaction test.
 *
 * Hart 0 rewrites one leaf PTE after every hart has cached the old mapping.
 * Harts 1-3 prove the stale translation remains usable until they receive a
 * machine-software interrupt and execute SFENCE.VMA in the trap handler.
 *
 * Before the remap, harts 1-3 also establish LR reservations on one shared
 * line.  Hart 0 writes that line, forcing ordinary coherent D-cache probes.
 * The testbench observes both the probes and reservation-clear signals, while
 * software requires the later SC attempts to fail.
 */

.equ PHYSICAL_OFFSET,        0x40000000
.equ CLINT_MSIP_BASE,        0x02000000
.equ TRAP_SAVE_BASE,         0x8001a000

.equ TLBI_TARGET_VA,         0x40018000
.equ TLBI_PTE_ALIAS_VA,      0x4001f000
.equ TLBI_TARGET_PTE_OFFSET, (24 * 8)
.equ TLBI_NEW_PA,            0x8001c000
.equ TLBI_OLD_VALUE,         0x1111222233334444
.equ TLBI_NEW_VALUE,         0xaaaabbbbccccdddd

.equ PRIVATE_MAILBOX,        0
.equ PRIVATE_RESULT,         4
.equ PRIVATE_READY,          8
.equ PRIVATE_RESERVED,       12
.equ PRIVATE_STALE,          16
.equ PRIVATE_SHOOTDOWN_DONE, 20

.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    la      t0, machine_trap
    csrw    mtvec, t0

    /* 16 MiB NAPOT RAM region at 0x80000000. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    csrr    tp, mhartid
    li      t0, 4
    bgeu    tp, t0, machine_fail

    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    /* Machine software interrupts implement the remote shootdown request. */
    li      t0, (1 << 3)
    csrw    mie, t0

    la      t0, supervisor_start
    csrw    mepc, t0
    /* MPP=S, MPIE=1. */
    li      t0, 0x880
    csrw    mstatus, t0
    mret

/*
 * Save the caller-clobbered state used by this directed handler.  The save
 * pages are physical and hart-indexed because M-mode accesses do not use the
 * supervisor address translation.
 */
machine_trap:
    csrw    mscratch, t6
    csrr    t6, mhartid
    slli    t6, t6, 8
    li      t5, TRAP_SAVE_BASE
    add     t6, t6, t5
    sd      t0, 0(t6)
    sd      t1, 8(t6)
    sd      t2, 16(t6)
    sd      t3, 24(t6)
    sd      t4, 32(t6)
    sd      t5, 40(t6)
    csrr    t0, mscratch
    sd      t0, 48(t6)
    sd      ra, 56(t6)
    sd      a0, 64(t6)

    csrr    t0, mcause
    li      t1, 0x8000000000000003
    beq     t0, t1, machine_software_interrupt
    li      t1, 9
    beq     t0, t1, machine_shootdown_call
    j       machine_fail

machine_software_interrupt:
    /*
     * This is the remote half of the shootdown.  Completion is published only
     * after SFENCE.VMA retires and the hart's MSIP has been cleared.
     */
    sfence.vma x0, x0

    csrr    t0, mhartid
    slli    t0, t0, 2
    li      t1, CLINT_MSIP_BASE
    add     t0, t0, t1
    sw      x0, 0(t0)
    fence   w, w

    la      t0, tlbi_4h_private_pages
    li      t1, PHYSICAL_OFFSET
    add     t0, t0, t1
    csrr    t1, mhartid
    slli    t1, t1, 12
    add     t0, t0, t1
    li      t1, 1
    sw      t1, PRIVATE_SHOOTDOWN_DONE(t0)
    fence   w, w
    j       machine_trap_return

machine_shootdown_call:
    /*
     * Hart 0 models the SBI/firmware half of an S-mode shootdown request by
     * setting the remote MSIP bits.  Other harts must never issue this ecall.
     */
    csrr    t0, mhartid
    bnez    t0, machine_fail
    li      t0, CLINT_MSIP_BASE
    li      t1, 1
    sw      t1, 4(t0)
    sw      t1, 8(t0)
    sw      t1, 12(t0)
    fence   w, w
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

machine_trap_return:
    ld      a0, 64(t6)
    ld      ra, 56(t6)
    ld      t0, 48(t6)
    csrw    mscratch, t0
    ld      t0, 0(t6)
    ld      t1, 8(t6)
    ld      t2, 16(t6)
    ld      t3, 24(t6)
    ld      t4, 32(t6)
    ld      t5, 40(t6)
    csrr    t6, mscratch
    mret

machine_fail:
    li      a0, 0x544c42494d464149 /* "TLBIMFAI" */
.Lmachine_fail:
    j       .Lmachine_fail

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la      s4, tlbi_4h_private_pages
    slli    t0, tp, 12
    add     s4, s4, t0
    li      t0, 4096
    add     sp, s4, t0
    addi    sp, sp, -16

    /* Warm the old translation and physical cache line on every hart. */
    li      s0, TLBI_TARGET_VA
    ld      t0, 0(s0)
    li      t1, TLBI_OLD_VALUE
    bne     t0, t1, supervisor_fail_old
    li      t0, 1
    sw      t0, PRIVATE_READY(s4)
    fence   w, w

    beqz    tp, hart0_coordinator

remote_hart:
    la      s1, tlbi_phase
.Lremote_wait_arm:
    lw      t0, 0(s1)
    li      t1, 1
    blt     t0, t1, .Lremote_wait_arm

    /*
     * The hart-0 store to this line must revoke both the private D-cache copy
     * and the LR reservation before the eventual SC.
     */
    la      s2, tlbi_reservation_line
    lr.w    t0, (s2)
    sw      t1, PRIVATE_RESERVED(s4)
    fence   w, w

.Lremote_wait_stale:
    lw      t0, 0(s1)
    li      t1, 2
    blt     t0, t1, .Lremote_wait_stale

    /* No local SFENCE.VMA yet: the old translation must still be resident. */
    ld      t0, 0(s0)
    li      t1, TLBI_OLD_VALUE
    bne     t0, t1, supervisor_fail_stale
    li      t0, 1
    sw      t0, PRIVATE_STALE(s4)
    fence   w, w

.Lremote_wait_shootdown:
    lw      t0, PRIVATE_SHOOTDOWN_DONE(s4)
    bnez    t0, .Lremote_after_shootdown
    wfi
    j       .Lremote_wait_shootdown

.Lremote_after_shootdown:
    ld      t0, 0(s0)
    li      t1, TLBI_NEW_VALUE
    bne     t0, t1, supervisor_fail_new

    /*
     * The ordinary coherent invalidate sent before the shootdown must have
     * cleared this hart's reservation.  SC success is therefore a failure.
     */
    li      t0, 7
    sc.w    t1, t0, (s2)
    beqz    t1, supervisor_fail_sc
    li      t0, 1
    sw      t0, PRIVATE_RESULT(s4)
    addi    t0, tp, 1
    sw      t0, PRIVATE_MAILBOX(s4)
    fence   rw, rw
    j       tlbi_4h_shared_vm_done

hart0_coordinator:
    la      s1, tlbi_4h_private_pages
    li      t0, 4096
    add     s5, s1, t0
    add     s6, s5, t0
    add     s7, s6, t0

.Lhart0_wait_ready:
    lw      t0, PRIVATE_READY(s1)
    lw      t1, PRIVATE_READY(s5)
    lw      t2, PRIVATE_READY(s6)
    lw      t3, PRIVATE_READY(s7)
    and     t0, t0, t1
    and     t2, t2, t3
    and     t0, t0, t2
    beqz    t0, .Lhart0_wait_ready

    la      s2, tlbi_phase
    li      t0, 1
    sw      t0, 0(s2)
    fence   w, w

.Lhart0_wait_reserved:
    lw      t0, PRIVATE_RESERVED(s5)
    lw      t1, PRIVATE_RESERVED(s6)
    lw      t2, PRIVATE_RESERVED(s7)
    and     t0, t0, t1
    and     t0, t0, t2
    beqz    t0, .Lhart0_wait_reserved

    /* Force normal coherence probes against all three remote reservations. */
    la      s3, tlbi_reservation_line
    li      t0, 1
    sw      t0, 0(s3)
    fence   w, w

    /*
     * Rewrite target VPN 24 through the writable page-table alias, publish
     * the PTE store, and invalidate hart 0's own translation.
     */
    li      t0, TLBI_NEW_PA
    srli    t0, t0, 12
    slli    t0, t0, 10
    ori     t0, t0, 0xcf
    li      t1, TLBI_PTE_ALIAS_VA + TLBI_TARGET_PTE_OFFSET
    sd      t0, 0(t1)
    fence   w, w
    sfence.vma s0, x0

    ld      t0, 0(s0)
    li      t1, TLBI_NEW_VALUE
    bne     t0, t1, supervisor_fail_new

    li      t0, 2
    sw      t0, 0(s2)
    fence   w, w

.Lhart0_wait_stale:
    lw      t0, PRIVATE_STALE(s5)
    lw      t1, PRIVATE_STALE(s6)
    lw      t2, PRIVATE_STALE(s7)
    and     t0, t0, t1
    and     t0, t0, t2
    beqz    t0, .Lhart0_wait_stale

    /* Enter M-mode firmware, which raises MSIP for harts 1-3. */
    ecall

.Lhart0_wait_shootdown:
    lw      t0, PRIVATE_SHOOTDOWN_DONE(s5)
    lw      t1, PRIVATE_SHOOTDOWN_DONE(s6)
    lw      t2, PRIVATE_SHOOTDOWN_DONE(s7)
    and     t0, t0, t1
    and     t0, t0, t2
    beqz    t0, .Lhart0_wait_shootdown

.Lhart0_wait_results:
    lw      t0, PRIVATE_RESULT(s5)
    lw      t1, PRIVATE_RESULT(s6)
    lw      t2, PRIVATE_RESULT(s7)
    and     t0, t0, t1
    and     t0, t0, t2
    beqz    t0, .Lhart0_wait_results

    li      t0, 1
    sw      t0, PRIVATE_RESULT(s4)
    sw      t0, PRIVATE_MAILBOX(s4)
    fence   rw, rw
    j       tlbi_4h_shared_vm_done

supervisor_fail_old:
    li      a0, 0x544c42494f4c4421 /* "TLBIOLD!" */
    j       .Lsupervisor_fail
supervisor_fail_stale:
    li      a0, 0x544c42495354414c /* "TLBISTAL" */
    j       .Lsupervisor_fail
supervisor_fail_new:
    li      a0, 0x544c42494e455721 /* "TLBINEW!" */
    j       .Lsupervisor_fail
supervisor_fail_sc:
    li      a0, 0x544c424953432121 /* "TLBISC!!" */
.Lsupervisor_fail:
    j       .Lsupervisor_fail

.globl tlbi_4h_shared_vm_done
tlbi_4h_shared_vm_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .data, "aw", @progbits
.balign 64
.globl tlbi_phase
tlbi_phase:
    .word 0
    .zero 60

.balign 64
.globl tlbi_reservation_line
tlbi_reservation_line:
    .word 0
    .zero 60

.section .hart_private, "aw", @nobits
.balign 4096
.globl tlbi_4h_private_pages
tlbi_4h_private_pages:
    .zero 16384
.globl tlbi_4h_result_base
.set tlbi_4h_result_base, tlbi_4h_private_pages + PRIVATE_RESULT

.section .page_table.root, "a", @progbits
.balign 4096
.globl root_page_table
root_page_table:
    .zero 4096

.section .page_table.level1, "a", @progbits
.balign 4096
level1_page_table:
    .zero 4096

.section .page_table.level0, "a", @progbits
.balign 4096
level0_page_table:
    .zero 4096
