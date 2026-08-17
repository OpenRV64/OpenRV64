/*
 * Single-hart Sv39 microbenchmark for the Linux/RISC-V ticket-spinlock path.
 *
 * The Linux-shaped helpers reproduce the uncontended fast path emitted in the
 * source-matched kernel for _raw_spin_lock{,_irqsave} and their unlock pairs:
 * preempt-count bookkeeping, packed ticket AMO, mmiowb nesting, release fence,
 * owner-halfword store, interrupt save/restore, and reschedule flag check.
 * The slow ticket wait loop is present for instruction fidelity but cannot be
 * entered by this single-hart uncontended benchmark.
 *
 * Returned registers:
 *   a0 pass signature       a1 iterations
 *   a2 baseline cycles      a3 bare ticket cycles
 *   a4 Linux raw cycles     a5 Linux irqsave cycles
 *   a6 baseline instret     a7 bare ticket instret
 *   s0 Linux raw instret    s1 Linux irqsave instret
 */

#ifndef OPENRV64_LINUX_SPINLOCK_ITERS
#define OPENRV64_LINUX_SPINLOCK_ITERS 1024
#endif

#if OPENRV64_LINUX_SPINLOCK_ITERS <= 0
#error OPENRV64_LINUX_SPINLOCK_ITERS must be positive
#endif

#if OPENRV64_LINUX_SPINLOCK_ITERS >= 32768
#error OPENRV64_LINUX_SPINLOCK_ITERS must keep signed ticket fields positive
#endif

.equ LINUX_SPINLOCK_ITERS, OPENRV64_LINUX_SPINLOCK_ITERS
.equ LINUX_SPINLOCK_WARM_ITERS, 64
.equ LINUX_SPINLOCK_NEXT, 0x00010000
.equ LINUX_SPINLOCK_PASS, 0x5350494e4f4b2121 /* "SPINOK!!" */
.equ LINUX_SPINLOCK_FAIL, 0x5350494e42414400 /* "SPINBAD\0" */

.equ RESULT_BASELINE_CYCLES, 0
.equ RESULT_TICKET_CYCLES, 8
.equ RESULT_RAW_CYCLES, 16
.equ RESULT_IRQSAVE_CYCLES, 24
.equ RESULT_BASELINE_INSTRET, 32
.equ RESULT_TICKET_INSTRET, 40
.equ RESULT_RAW_INSTRET, 48
.equ RESULT_IRQSAVE_INSTRET, 56

.section .text, "ax", @progbits
.option norvc

.macro LINUX_TICKET_ACQUIRE lockreg
    li      t0, LINUX_SPINLOCK_NEXT
    amoadd.w.aqrl t1, t0, (\lockreg)
    slli    t2, t1, 48
    srli    t2, t2, 48
    srliw   t1, t1, 16
    bne     t1, t2, .Lticket_wait_\@
    j       .Lticket_acquired_\@
.Lticket_relax_\@:
    /* This is the kernel's defined divide-by-zero cpu_relax fallback. */
    div     t2, t2, zero
    .word   0x0100000f          /* Zihintpause encoding: fence w, 0. */
.Lticket_wait_\@:
    lw      t2, 0(\lockreg)
    slli    t2, t2, 48
    srli    t2, t2, 48
    bne     t1, t2, .Lticket_relax_\@
    fence   r, r
    fence   rw, rw
.Lticket_acquired_\@:
.endm

.macro LINUX_TICKET_RELEASE lockreg
    lw      t0, 0(\lockreg)
    fence   rw, w
    addiw   t0, t0, 1
    sh      t0, 0(\lockreg)
.endm

.macro LINUX_MMI_LOCK
    lw      t3, 32(tp)
    la      t4, linux_spinlock_per_cpu_offset
    slli    t3, t3, 3
    add     t4, t4, t3
    ld      t4, 0(t4)
    la      t5, linux_spinlock_mmiowb_state
    add     t5, t5, t4
    lhu     t4, 0(t5)
    addiw   t4, t4, 1
    sh      t4, 0(t5)
.endm

.macro LINUX_MMI_UNLOCK
    lw      t3, 32(tp)
    la      t4, linux_spinlock_per_cpu_offset
    slli    t3, t3, 3
    add     t4, t4, t3
    ld      t4, 0(t4)
    la      t5, linux_spinlock_mmiowb_state
    add     t5, t5, t4
    lhu     t4, 2(t5)
    bnez    t4, .Lmmiowb_pending_\@
.Lmmiowb_continue_\@:
    lhu     t4, 0(t5)
    addiw   t4, t4, -1
    sh      t4, 0(t5)
    j       .Lmmiowb_done_\@
.Lmmiowb_pending_\@:
    sh      zero, 2(t5)
    fence   o, w
    j       .Lmmiowb_continue_\@
.Lmmiowb_done_\@:
.endm

.macro LINUX_PREEMPT_DISABLE
    lw      t0, 8(tp)
    addiw   t0, t0, 1
    sw      t0, 8(tp)
.endm

.macro LINUX_PREEMPT_ENABLE
    lw      t0, 8(tp)
    addiw   t0, t0, -1
    sw      t0, 8(tp)
    bnez    t0, .Lpreempt_done_\@
    ld      t0, 0(tp)
    srli    t0, t0, 4
    andi    t0, t0, 1
    beqz    t0, .Lpreempt_done_\@
    /* need_resched is kept clear; reaching this is a benchmark failure. */
    ebreak
.Lpreempt_done_\@:
.endm

.balign 64
.globl linux_ticket_spin_lock
.type linux_ticket_spin_lock, @function
linux_ticket_spin_lock:
    LINUX_TICKET_ACQUIRE a0
    ret
.size linux_ticket_spin_lock, .-linux_ticket_spin_lock

.balign 32
.globl linux_ticket_spin_unlock
.type linux_ticket_spin_unlock, @function
linux_ticket_spin_unlock:
    LINUX_TICKET_RELEASE a0
    ret
.size linux_ticket_spin_unlock, .-linux_ticket_spin_unlock

.balign 64
.globl linux_raw_spin_lock
.type linux_raw_spin_lock, @function
linux_raw_spin_lock:
    LINUX_PREEMPT_DISABLE
    LINUX_TICKET_ACQUIRE a0
    LINUX_MMI_LOCK
    ret
.size linux_raw_spin_lock, .-linux_raw_spin_lock

.balign 32
.globl linux_raw_spin_unlock
.type linux_raw_spin_unlock, @function
linux_raw_spin_unlock:
    LINUX_MMI_UNLOCK
    LINUX_TICKET_RELEASE a0
    LINUX_PREEMPT_ENABLE
    ret
.size linux_raw_spin_unlock, .-linux_raw_spin_unlock

.balign 64
.globl linux_raw_spin_lock_irqsave
.type linux_raw_spin_lock_irqsave, @function
linux_raw_spin_lock_irqsave:
    mv      t6, a0
    csrrci  a0, sstatus, 2
    LINUX_PREEMPT_DISABLE
    LINUX_TICKET_ACQUIRE t6
    LINUX_MMI_LOCK
    ret
.size linux_raw_spin_lock_irqsave, .-linux_raw_spin_lock_irqsave

.balign 32
.globl linux_raw_spin_unlock_irqrestore
.type linux_raw_spin_unlock_irqrestore, @function
linux_raw_spin_unlock_irqrestore:
    LINUX_MMI_UNLOCK
    LINUX_TICKET_RELEASE a0
    andi    a1, a1, 2
    csrs    sstatus, a1
    LINUX_PREEMPT_ENABLE
    ret
.size linux_raw_spin_unlock_irqrestore, .-linux_raw_spin_unlock_irqrestore

.type linux_spinlock_reset, @function
linux_spinlock_reset:
    la      t0, linux_spinlock_word
    sw      zero, 0(t0)
    la      t0, linux_spinlock_counter
    sd      zero, 0(t0)
    sw      zero, 8(tp)
    sd      zero, 0(tp)
    la      t0, linux_spinlock_mmiowb_state
    sw      zero, 0(t0)
    fence   rw, rw
    ret
.size linux_spinlock_reset, .-linux_spinlock_reset

/* a0=expected packed lock word, a1=expected protected counter; a0=error. */
.type linux_spinlock_validate, @function
linux_spinlock_validate:
    la      t0, linux_spinlock_word
    lw      t1, 0(t0)
    bne     t1, a0, .Lvalidate_lock
    la      t0, linux_spinlock_counter
    ld      t1, 0(t0)
    bne     t1, a1, .Lvalidate_counter
    lw      t1, 8(tp)
    bnez    t1, .Lvalidate_preempt
    la      t0, linux_spinlock_mmiowb_state
    lw      t1, 0(t0)
    bnez    t1, .Lvalidate_mmiowb
    li      a0, 0
    ret
.Lvalidate_lock:
    li      a0, 1
    ret
.Lvalidate_counter:
    li      a0, 2
    ret
.Lvalidate_preempt:
    li      a0, 3
    ret
.Lvalidate_mmiowb:
    li      a0, 4
    ret
.size linux_spinlock_validate, .-linux_spinlock_validate

.macro SAVE_MEASUREMENT cycle_offset, instret_offset
    csrr    t0, instret
    csrr    t1, cycle
    sub     t0, t0, s7
    sub     t1, t1, s6
    la      t2, linux_spinlock_results
    sd      t1, \cycle_offset(t2)
    sd      t0, \instret_offset(t2)
.endm

.macro START_MEASUREMENT
    csrr    s6, cycle
    csrr    s7, instret
.endm

.section .text.startup, "ax", @progbits
.balign 64
.globl main
.type main, @function
main:
    addi    sp, sp, -16
    sd      ra, 0(sp)

    la      tp, linux_spinlock_percpu
    la      s3, linux_spinlock_word
    la      s4, linux_spinlock_counter
    csrr    s10, sstatus

    /* Matched critical-section control: one protected-counter increment. */
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_ITERS
    START_MEASUREMENT
.Lbaseline_loop:
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    addi    s5, s5, -1
    bnez    s5, .Lbaseline_loop
    SAVE_MEASUREMENT RESULT_BASELINE_CYCLES, RESULT_BASELINE_INSTRET
    li      a0, 0
    li      a1, LINUX_SPINLOCK_ITERS
    call    linux_spinlock_validate
    bnez    a0, .Lbenchmark_fail

    /* Bare Linux ticket acquire/release, excluding raw-lock bookkeeping. */
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_WARM_ITERS
.Lticket_warm:
    mv      a0, s3
    call    linux_ticket_spin_lock
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    call    linux_ticket_spin_unlock
    addi    s5, s5, -1
    bnez    s5, .Lticket_warm
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_ITERS
    START_MEASUREMENT
.Lticket_loop:
    mv      a0, s3
    call    linux_ticket_spin_lock
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    call    linux_ticket_spin_unlock
    addi    s5, s5, -1
    bnez    s5, .Lticket_loop
    SAVE_MEASUREMENT RESULT_TICKET_CYCLES, RESULT_TICKET_INSTRET
    li      a0, ((LINUX_SPINLOCK_ITERS << 16) | LINUX_SPINLOCK_ITERS)
    li      a1, LINUX_SPINLOCK_ITERS
    call    linux_spinlock_validate
    bnez    a0, .Lbenchmark_fail

    /* Full uncontended _raw_spin_lock/_raw_spin_unlock shape. */
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_WARM_ITERS
.Lraw_warm:
    mv      a0, s3
    call    linux_raw_spin_lock
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    call    linux_raw_spin_unlock
    addi    s5, s5, -1
    bnez    s5, .Lraw_warm
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_ITERS
    START_MEASUREMENT
.Lraw_loop:
    mv      a0, s3
    call    linux_raw_spin_lock
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    call    linux_raw_spin_unlock
    addi    s5, s5, -1
    bnez    s5, .Lraw_loop
    SAVE_MEASUREMENT RESULT_RAW_CYCLES, RESULT_RAW_INSTRET
    li      a0, ((LINUX_SPINLOCK_ITERS << 16) | LINUX_SPINLOCK_ITERS)
    li      a1, LINUX_SPINLOCK_ITERS
    call    linux_spinlock_validate
    bnez    a0, .Lbenchmark_fail

    /* IRQ-save variant, with the same disabled-SIE state as runtime entry. */
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_WARM_ITERS
.Lirqsave_warm:
    mv      a0, s3
    call    linux_raw_spin_lock_irqsave
    mv      s8, a0
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    mv      a1, s8
    call    linux_raw_spin_unlock_irqrestore
    addi    s5, s5, -1
    bnez    s5, .Lirqsave_warm
    call    linux_spinlock_reset
    li      s5, LINUX_SPINLOCK_ITERS
    START_MEASUREMENT
.Lirqsave_loop:
    mv      a0, s3
    call    linux_raw_spin_lock_irqsave
    mv      s8, a0
    ld      t0, 0(s4)
    addi    t0, t0, 1
    sd      t0, 0(s4)
    mv      a0, s3
    mv      a1, s8
    call    linux_raw_spin_unlock_irqrestore
    addi    s5, s5, -1
    bnez    s5, .Lirqsave_loop
    SAVE_MEASUREMENT RESULT_IRQSAVE_CYCLES, RESULT_IRQSAVE_INSTRET
    li      a0, ((LINUX_SPINLOCK_ITERS << 16) | LINUX_SPINLOCK_ITERS)
    li      a1, LINUX_SPINLOCK_ITERS
    call    linux_spinlock_validate
    bnez    a0, .Lbenchmark_fail
    csrr    t0, sstatus
    xor     t0, t0, s10
    andi    t0, t0, 2
    bnez    t0, .Lbenchmark_sstatus_fail

    la      t0, linux_spinlock_results
    li      a0, LINUX_SPINLOCK_PASS
    li      a1, LINUX_SPINLOCK_ITERS
    ld      a2, RESULT_BASELINE_CYCLES(t0)
    ld      a3, RESULT_TICKET_CYCLES(t0)
    ld      a4, RESULT_RAW_CYCLES(t0)
    ld      a5, RESULT_IRQSAVE_CYCLES(t0)
    ld      a6, RESULT_BASELINE_INSTRET(t0)
    ld      a7, RESULT_TICKET_INSTRET(t0)
    ld      s0, RESULT_RAW_INSTRET(t0)
    ld      s1, RESULT_IRQSAVE_INSTRET(t0)
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

.Lbenchmark_sstatus_fail:
    li      a0, 5
.Lbenchmark_fail:
    li      t0, LINUX_SPINLOCK_FAIL
    or      a0, a0, t0
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret
.size main, .-main

.section .data, "aw", @progbits
.balign 64
.globl linux_spinlock_word
linux_spinlock_word:
    .word 0
    .zero 60

.balign 64
linux_spinlock_counter:
    .dword 0
    .zero 56

.balign 64
linux_spinlock_percpu:
    .dword 0                   /* thread-info flags at tp + 0. */
    .word 0                    /* preempt count at tp + 8. */
    .zero 20
    .word 0                    /* CPU number at tp + 32. */
    .zero 28

.balign 64
linux_spinlock_per_cpu_offset:
    .dword 0
    .zero 56

.balign 64
linux_spinlock_mmiowb_state:
    .half 0                    /* nesting count. */
    .half 0                    /* pending flag. */
    .zero 60

.balign 64
linux_spinlock_results:
    .zero 64
