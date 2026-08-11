/*
 * Four-hart WFI/mailbox ordering test under one shared Sv39 map.
 *
 * Hart 0 selects one of harts 1..3 with a reproducible xorshift generator,
 * publishes a sequence number and its complement to that hart's cacheable
 * mailbox, fences the publication, and requests an MSIP through a minimal
 * M-mode handler.  The selected worker must wake from WFI, observe the exact
 * mailbox payload, publish an acknowledgement to hart 0, fence it, and send
 * an MSIP back.  Hart 0 validates every acknowledgement before starting the
 * next round.  Three final stop exchanges let every worker acknowledge and
 * complete without polling while asleep.
 *
 * This is specifically a lost-wakeup test: an interrupt becoming visible
 * before the preceding cacheable mailbox stores is a hard failure, not a
 * condition that the worker is allowed to poll through.
 */

#ifndef OPENRV64_WFI_MAILBOX_ROUNDS
#define OPENRV64_WFI_MAILBOX_ROUNDS 1024
#endif

.equ PHYSICAL_OFFSET,        0x40000000
.equ CLINT_MSIP_BASE,        0x02000000
.equ MAILBOX_ROUNDS,         OPENRV64_WFI_MAILBOX_ROUNDS
.equ STOP_SEQUENCE,          0xffffffff
.equ MAX_RECEIVE_COUNT,      (MAILBOX_ROUNDS + 3)

.equ PRIVATE_MAILBOX,        0
.equ PRIVATE_RESULT,         4
.equ PRIVATE_READY,          8
.equ PRIVATE_WAKE_SEQUENCE,  16
.equ PRIVATE_WAKE_INVERSE,   20
.equ PRIVATE_ACK_SEQUENCE,   24
.equ PRIVATE_ACK_HART,       28
.equ PRIVATE_WORK_COUNT,     32

/*
 * Keep interrupt bookkeeping off the cache line carrying the publication.
 * Otherwise the handler's RX_COUNT read-modify-write can acquire/refill the
 * payload line after MSIP delivery and hide a stale wake or acknowledgement.
 */
.equ PRIVATE_RX_COUNT,       64

.equ TRAP_FRAME_SHIFT,       8

.section .text.boot, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    csrr    tp, mhartid
    li      t0, 4
    bgeu    tp, t0, machine_fail_bad_hart

    la      t0, machine_trap
    csrw    mtvec, t0

    /* Give each hart a physical, 256-byte M-mode trap frame. */
    la      t0, wfi_mailbox_4h_trap_frames
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

/* Preserve every temporary touched by an asynchronous MSIP handler. */
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
    /*
     * Clear the level source before recording receipt.  Do not place a full
     * cache fence in this receive path: that could make the sender's payload
     * visible and mask the ordering failure this test is intended to catch.
     */
    csrr    t0, mhartid
    slli    t1, t0, 2
    li      t2, CLINT_MSIP_BASE
    add     t1, t1, t2
    sw      x0, 0(t1)

    la      t1, wfi_mailbox_4h_private_pages
    li      t2, PHYSICAL_OFFSET
    add     t1, t1, t2
    slli    t0, t0, 12
    add     t1, t1, t0
    lw      t2, PRIVATE_RX_COUNT(t1)
    li      t3, MAX_RECEIVE_COUNT
    bgeu    t2, t3, machine_fail_duplicate
    addi    t2, t2, 1
    sw      t2, PRIVATE_RX_COUNT(t1)
    j       machine_trap_return

machine_send_ipi:
    /* a0 is the target hart ID supplied by supervisor software. */
    li      t0, 4
    bgeu    a0, t0, machine_fail_bad_target
    csrr    t0, mhartid
    beq     a0, t0, machine_fail_bad_target
    slli    t0, a0, 2
    li      t1, CLINT_MSIP_BASE
    add     t0, t0, t1
    lw      t2, 0(t0)
    bnez    t2, machine_fail_busy_target

    /* The supervisor caller fenced its cacheable publication. */
    li      t1, 1
    sw      t1, 0(t0)

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
    li      a0, 0x5746494241444841 /* "WFIBADHA" */
    j       machine_fail
machine_fail_bad_cause:
    li      a0, 0x5746494241444341 /* "WFIBADCA" */
    j       machine_fail
machine_fail_bad_target:
    li      a0, 0x5746494241445447 /* "WFIBADTG" */
    j       machine_fail
machine_fail_busy_target:
    li      a0, 0x5746494255535921 /* "WFIBUSY!" */
    j       machine_fail
machine_fail_duplicate:
    li      a0, 0x5746494455504c21 /* "WFIDUPL!" */
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
    la      s5, wfi_mailbox_4h_private_pages
    slli    t0, tp, 12
    add     s4, s5, t0
    li      t0, 4096
    add     sp, s4, t0
    addi    sp, sp, -16

    sw      x0, PRIVATE_RX_COUNT(s4)
    sw      x0, PRIVATE_WAKE_SEQUENCE(s4)
    sw      x0, PRIVATE_WAKE_INVERSE(s4)
    sw      x0, PRIVATE_ACK_SEQUENCE(s4)
    sw      x0, PRIVATE_ACK_HART(s4)
    sw      x0, PRIVATE_WORK_COUNT(s4)

    /* Reproducible, distinct timing state on each hart. */
    li      s1, 0x6d2b79f5
    slli    t0, tp, 20
    xor     s1, s1, t0

    li      t0, 1
    sw      t0, PRIVATE_READY(s4)
    fence   rw, rw

    beqz    tp, hart0_coordinator
    j       worker_loop_start

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

/* Harts 1..3 sleep until selected, validate publication, and acknowledge. */
worker_loop_start:
    li      s0, 0                  /* Last accepted global sequence. */
    li      s2, 0                  /* Expected local interrupt count. */
    li      s3, 0                  /* Completed normal wakeups. */
.Lworker_wait_next:
    addi    s2, s2, 1
.Lworker_wait:
    lw      t0, PRIVATE_RX_COUNT(s4)
    bltu    t0, s2, .Lworker_sleep
    bne     t0, s2, supervisor_fail_count

    lwu     t1, PRIVATE_WAKE_SEQUENCE(s4)
    lwu     t2, PRIVATE_WAKE_INVERSE(s4)
    not     t3, t1
    slli    t3, t3, 32
    srli    t3, t3, 32
    bne     t2, t3, supervisor_fail_wake_inverse
    li      t0, STOP_SEQUENCE
    beq     t1, t0, .Lworker_stop
    beqz    t1, supervisor_fail_wake_zero
    bleu    t1, s0, supervisor_fail_wake_order
    li      t0, MAILBOX_ROUNDS
    bgtu    t1, t0, supervisor_fail_wake_range
    mv      s0, t1
    addi    s3, s3, 1

    jal     ra, random_nop_jitter
    sw      t1, PRIVATE_ACK_SEQUENCE(s5)
    sw      tp, PRIVATE_ACK_HART(s5)
    fence   rw, ow
    li      a0, 0
    ecall
    j       .Lworker_wait_next

.Lworker_sleep:
    wfi
    j       .Lworker_wait

.Lworker_stop:
    /* The stop message is also acknowledged before this hart completes. */
    sw      t1, PRIVATE_ACK_SEQUENCE(s5)
    sw      tp, PRIVATE_ACK_HART(s5)
    sw      s3, PRIVATE_WORK_COUNT(s4)
    fence   rw, ow
    li      a0, 0
    ecall
    j       supervisor_success

/* Hart 0 waits for all workers, then drives 1,024 serialized random wakes. */
hart0_coordinator:
    li      t0, 1
.Lhart0_ready_loop:
    li      t1, 4
    bgeu    t0, t1, .Lhart0_ready_done
    slli    t2, t0, 12
    add     t2, s5, t2
    lw      t3, PRIVATE_READY(t2)
    beqz    t3, .Lhart0_ready_loop
    addi    t0, t0, 1
    j       .Lhart0_ready_loop
.Lhart0_ready_done:
    li      s0, 0                  /* Global sequence. */
    li      s3, 0                  /* Expected acknowledgements. */

.Lhart0_round:
    li      t0, MAILBOX_ROUNDS
    bgeu    s0, t0, .Lhart0_stop_workers
    addi    s0, s0, 1

    /* xorshift64, then map the state to target hart 1..3. */
    slli    t0, s1, 13
    xor     s1, s1, t0
    srli    t0, s1, 7
    xor     s1, s1, t0
    slli    t0, s1, 17
    xor     s1, s1, t0
    li      t0, 3
    remu    s2, s1, t0
    addi    s2, s2, 1

    slli    t0, s2, 12
    add     s6, s5, t0
    sw      s0, PRIVATE_WAKE_SEQUENCE(s6)
    not     t0, s0
    sw      t0, PRIVATE_WAKE_INVERSE(s6)
    fence   rw, ow
    mv      a0, s2
    ecall

    addi    s3, s3, 1
    jal     ra, hart0_wait_ack
    j       .Lhart0_round

.Lhart0_stop_workers:
    li      s7, 1
.Lhart0_stop_loop:
    li      t0, 4
    bgeu    s7, t0, supervisor_success
    slli    t0, s7, 12
    add     s6, s5, t0
    li      t1, STOP_SEQUENCE
    sw      t1, PRIVATE_WAKE_SEQUENCE(s6)
    sw      x0, PRIVATE_WAKE_INVERSE(s6)
    fence   rw, ow
    mv      a0, s7
    ecall

    addi    s3, s3, 1
    mv      s2, s7
    jal     ra, hart0_wait_ack
    addi    s7, s7, 1
    j       .Lhart0_stop_loop

/* Wait for exactly one acknowledgement and validate both published words. */
hart0_wait_ack:
.Lhart0_ack_wait:
    lw      t0, PRIVATE_RX_COUNT(s4)
    bltu    t0, s3, .Lhart0_ack_sleep
    bne     t0, s3, supervisor_fail_count
    lwu     t1, PRIVATE_ACK_SEQUENCE(s4)
    lwu     t2, PRIVATE_ACK_HART(s4)
    bne     t2, s2, supervisor_fail_ack_hart
    li      t0, MAILBOX_ROUNDS
    bleu    s3, t0, .Lhart0_normal_ack
    li      t0, STOP_SEQUENCE
    bne     t1, t0, supervisor_fail_stop_ack
    jalr    x0, 0(ra)
.Lhart0_normal_ack:
    bne     t1, s0, supervisor_fail_normal_ack
    jalr    x0, 0(ra)
.Lhart0_ack_sleep:
    wfi
    j       .Lhart0_ack_wait

supervisor_fail_count:
    li      t0, 0x100
    j       supervisor_fail_report
supervisor_fail_wake_inverse:
    li      t0, 0x201
    j       supervisor_fail_report
supervisor_fail_wake_zero:
    li      t0, 0x202
    j       supervisor_fail_report
supervisor_fail_wake_order:
    li      t0, 0x203
    j       supervisor_fail_report
supervisor_fail_wake_range:
    /* Preserve the impossible observed sequence for the harness report. */
    mv      t0, t1
    j       supervisor_fail_report
supervisor_fail_ack_hart:
    li      t0, 0x205
    j       supervisor_fail_report
supervisor_fail_stop_ack:
    li      t0, 0x206
    j       supervisor_fail_report
supervisor_fail_normal_ack:
    li      t0, 0x207
supervisor_fail_report:
    /* The harness reports the precise failure code before the breakpoint. */
    sw      t0, PRIVATE_RESULT(s4)
    fence   rw, rw
    ebreak
.Lsupervisor_fail:
    j       .Lsupervisor_fail

supervisor_success:
    li      t0, MAILBOX_ROUNDS
    sw      t0, PRIVATE_RESULT(s4)
    addi    t0, tp, 1
    sw      t0, PRIVATE_MAILBOX(s4)
    fence   rw, rw

.globl wfi_mailbox_4h_shared_vm_done
wfi_mailbox_4h_shared_vm_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

.size supervisor_start, .-supervisor_start

.section .bss, "aw", @nobits
.balign 256
.globl wfi_mailbox_4h_trap_frames
wfi_mailbox_4h_trap_frames:
    .zero 1024

.section .hart_private, "aw", @nobits
.balign 4096
.globl wfi_mailbox_4h_private_pages
wfi_mailbox_4h_private_pages:
    .zero 16384
.globl wfi_mailbox_4h_result_base
.set wfi_mailbox_4h_result_base, wfi_mailbox_4h_private_pages + PRIVATE_RESULT

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
