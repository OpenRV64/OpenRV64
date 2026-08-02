/*
 * Two-hart bare-metal IPI test under one shared, non-identity Sv39 map.
 *
 * Supervisor code sends through an ecall into a minimal M-mode firmware
 * handler.  The handler sets the peer's CLINT MSIP bit.  The peer wakes from
 * WFI, takes a machine-software interrupt, clears MSIP before returning, and
 * increments its private receive count.  Harts ping-pong exactly
 * OPENRV64_IPI_ROUNDS interrupts in each direction.
 *
 * This deliberately covers the path used by firmware IPIs rather than merely
 * writing CLINT from M-mode in a polling loop.  Completion requires exact
 * receive counts on both harts; an uncleared or spuriously retriggered MSIP is
 * therefore a failure.  A reproducible per-hart PRNG inserts 0..31 NOPs
 * before each send so interrupt arrival is not locked to one cycle phase.
 */

#ifndef OPENRV64_IPI_ROUNDS
#define OPENRV64_IPI_ROUNDS 4096
#endif

.equ PHYSICAL_OFFSET,        0x40000000
.equ CLINT_MSIP_BASE,        0x02000000
.equ IPI_ROUNDS,             OPENRV64_IPI_ROUNDS

.equ PRIVATE_MAILBOX,        0
.equ PRIVATE_RESULT,         4
.equ PRIVATE_READY,          8
.equ PRIVATE_RX_COUNT,       12

.equ TRAP_FRAME_SHIFT,       8

.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    csrr    tp, mhartid
    li      t0, 2
    bgeu    tp, t0, machine_fail_bad_hart

    la      t0, machine_trap
    csrw    mtvec, t0

    /* Give each hart a physical, 256-byte M-mode trap frame. */
    la      t0, ipi_2h_trap_frames
    li      t1, PHYSICAL_OFFSET
    add     t0, t0, t1
    slli    t1, tp, TRAP_FRAME_SHIFT
    add     t0, t0, t1
    csrw    mscratch, t0

    /* 16 MiB NAPOT RAM region at 0x80000000. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    /* CLINT MSIP is handled in M-mode. */
    li      t0, (1 << 3)
    csrw    mie, t0

    la      t0, supervisor_start
    csrw    mepc, t0
    /* MPP=S and MPIE=1. */
    li      t0, 0x880
    csrw    mstatus, t0
    mret

/*
 * Swap t6 with the per-hart trap-frame pointer in mscratch.  The handler
 * preserves every register it modifies because an MSIP can interrupt any
 * supervisor instruction.
 */
machine_trap:
    csrrw   t6, mscratch, t6
    sd      t0, 0(t6)
    sd      t1, 8(t6)
    sd      t2, 16(t6)
    sd      t3, 24(t6)
    sd      t4, 32(t6)
    sd      t5, 40(t6)
    sd      ra, 48(t6)
    sd      a0, 56(t6)
    sd      a1, 64(t6)

    csrr    t0, mcause
    li      t1, 0x8000000000000003
    beq     t0, t1, machine_software_interrupt
    li      t1, 9
    beq     t0, t1, machine_send_ipi
    j       machine_fail_bad_cause

machine_software_interrupt:
    /* Clear the level source before publishing receipt or returning. */
    csrr    t0, mhartid
    slli    t1, t0, 2
    li      t2, CLINT_MSIP_BASE
    add     t1, t1, t2
    sw      x0, 0(t1)
    fence   iorw, iorw

    la      t1, ipi_2h_private_pages
    li      t2, PHYSICAL_OFFSET
    add     t1, t1, t2
    slli    t0, t0, 12
    add     t1, t1, t0
    lw      t2, PRIVATE_RX_COUNT(t1)
    li      t3, IPI_ROUNDS
    bgeu    t2, t3, machine_fail_duplicate
    addi    t2, t2, 1
    sw      t2, PRIVATE_RX_COUNT(t1)
    fence   rw, rw
    j       machine_trap_return

machine_send_ipi:
    /* a0 is the target hart ID supplied by supervisor software. */
    li      t0, 2
    bgeu    a0, t0, machine_fail_bad_target
    csrr    t0, mhartid
    beq     a0, t0, machine_fail_bad_target
    slli    t0, a0, 2
    li      t1, CLINT_MSIP_BASE
    add     t0, t0, t1
    li      t1, 1
    sw      t1, 0(t0)
    fence   iorw, iorw

    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

machine_trap_return:
    ld      t0, 0(t6)
    ld      t1, 8(t6)
    ld      t2, 16(t6)
    ld      t3, 24(t6)
    ld      t4, 32(t6)
    ld      t5, 40(t6)
    ld      ra, 48(t6)
    ld      a0, 56(t6)
    ld      a1, 64(t6)
    csrrw   t6, mscratch, t6
    mret

machine_fail_bad_hart:
    li      a0, 0x4950494241444841 /* "IPIBADHA" */
    j       machine_fail
machine_fail_bad_cause:
    li      a0, 0x4950494241444341 /* "IPIBADCA" */
    j       machine_fail
machine_fail_bad_target:
    li      a0, 0x4950494241445447 /* "IPIBADTG" */
    j       machine_fail
machine_fail_duplicate:
    li      a0, 0x4950494455504c21 /* "IPIDUPL!" */
machine_fail:
    ebreak
.Lmachine_fail:
    j       .Lmachine_fail

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la      s4, ipi_2h_private_pages
    slli    t0, tp, 12
    add     s4, s4, t0
    li      t0, 4096
    add     sp, s4, t0
    addi    sp, sp, -16

    /*
     * Reproducible per-hart PRNG state for send-side timing jitter.  The
     * generated delay is 0..31 architectural NOPs before every IPI request.
     */
    li      s1, 0x6d2b79f5
    slli    t0, tp, 16
    xor     s1, s1, t0

    li      t0, 1
    sw      t0, PRIVATE_READY(s4)
    fence   rw, rw

    beqz    tp, hart0_ping
    j       hart1_pong

/* Advance a xorshift state and execute 0..31 NOPs. */
random_nop_jitter:
    slli    t0, s1, 13
    xor     s1, s1, t0
    srli    t0, s1, 7
    xor     s1, s1, t0
    slli    t0, s1, 17
    xor     s1, s1, t0
    andi    t0, s1, 31
    beqz    t0, .Ljitter_done
.Ljitter_loop:
    addi    x0, x0, 0
    addi    t0, t0, -1
    bnez    t0, .Ljitter_loop
.Ljitter_done:
    jalr    x0, 0(ra)

/* Hart 1 receives a token, then returns it to hart 0. */
hart1_pong:
    li      s0, 0
.Lhart1_round:
    addi    s0, s0, 1
.Lhart1_wait:
    lw      t0, PRIVATE_RX_COUNT(s4)
    bltu    t0, s0, .Lhart1_sleep
    bne     t0, s0, supervisor_fail_count

    li      a0, 0
    jal     ra, random_nop_jitter
    ecall
    li      t0, IPI_ROUNDS
    bltu    s0, t0, .Lhart1_round
    j       supervisor_success
.Lhart1_sleep:
    wfi
    j       .Lhart1_wait

/* Hart 0 waits for hart 1 to enter S-mode before sending the first token. */
hart0_ping:
    la      s5, ipi_2h_private_pages
    li      t0, 4096
    add     s5, s5, t0
.Lhart0_wait_ready:
    lw      t0, PRIVATE_READY(s5)
    beqz    t0, .Lhart0_wait_ready

    li      s0, 0
    li      a0, 1
    jal     ra, random_nop_jitter
    ecall
.Lhart0_round:
    addi    s0, s0, 1
.Lhart0_wait:
    lw      t0, PRIVATE_RX_COUNT(s4)
    bltu    t0, s0, .Lhart0_sleep
    bne     t0, s0, supervisor_fail_count

    li      t0, IPI_ROUNDS
    beq     s0, t0, supervisor_success
    li      a0, 1
    jal     ra, random_nop_jitter
    ecall
    j       .Lhart0_round
.Lhart0_sleep:
    wfi
    j       .Lhart0_wait

supervisor_fail_count:
    li      a0, 0x495049424144434e /* "IPIBADCN" */
    ebreak
.Lsupervisor_fail:
    j       .Lsupervisor_fail

supervisor_success:
    lw      t0, PRIVATE_RX_COUNT(s4)
    li      t1, IPI_ROUNDS
    bne     t0, t1, supervisor_fail_count
    sw      t0, PRIVATE_RESULT(s4)
    addi    t0, tp, 1
    sw      t0, PRIVATE_MAILBOX(s4)
    fence   rw, rw

.globl ipi_2h_shared_vm_done
ipi_2h_shared_vm_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .bss, "aw", @nobits
.balign 256
.globl ipi_2h_trap_frames
ipi_2h_trap_frames:
    .zero 512

.section .hart_private, "aw", @nobits
.balign 4096
.globl ipi_2h_private_pages
ipi_2h_private_pages:
    .zero 16384
.globl ipi_2h_result_base
.set ipi_2h_result_base, ipi_2h_private_pages + PRIVATE_RESULT

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
