/*
 * Four-hart packed ticket-lock stress under one shared Sv39 address space.
 *
 * The lock matches the Linux/RISC-V ticket representation: the low halfword
 * is owner and the high halfword is next.  Every hart allocates tickets with
 * AMOADD.W, spins on owner, and updates one protected 64-bit counter until it
 * reaches OPENRV64_TICKET_LOCK_TARGET.  Work is not partitioned or ordered by
 * hart.  Small per-hart pseudo-random delays perturb reacquisition timing.
 *
 * Besides the terminal counter, hart 0 checks the sum of per-hart protected
 * increments, the final owner/next value, a critical-section exclusion guard,
 * and that every hart acquired the lock at least once.
 */

#ifndef OPENRV64_TICKET_LOCK_TARGET
#define OPENRV64_TICKET_LOCK_TARGET 50000
#endif

#if OPENRV64_TICKET_LOCK_TARGET <= 0
#error OPENRV64_TICKET_LOCK_TARGET must be positive
#endif

#if OPENRV64_TICKET_LOCK_TARGET > 65532
#error OPENRV64_TICKET_LOCK_TARGET leaves no room for four terminal tickets
#endif

.equ HART_COUNT,               4
.equ LOCK_TARGET,              OPENRV64_TICKET_LOCK_TARGET
.equ LOCK_FINAL_TICKET,        (LOCK_TARGET + HART_COUNT - 1)
.equ LOCK_NEXT_INCREMENT,      0x00010000

.equ PRIVATE_MAILBOX,          0
.equ PRIVATE_RESULT,           4
.equ PRIVATE_INCREMENT_COUNT,  8
.equ PRIVATE_LAST_TICKET,      16

.equ CONTROL_STATE,            0
.equ CONTROL_READY,            8
.equ CONTROL_EXITED,           40

.equ INIT_MAGIC,               0x544c494e49542121
.equ GO_MAGIC,                 0x544c474f474f2121
.equ EXIT_MAGIC,               0x544c455849540000
.equ RELEASE_MAGIC,            0x544c52454c532121

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
    li      t0, HART_COUNT
    bgeu    tp, t0, machine_trap

    /* All four harts install the same Sv39 root. */
    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    la      t0, supervisor_start
    csrw    mepc, t0
    li      t0, 0x800            /* MPP=S. */
    csrw    mstatus, t0
    mret

machine_trap:
    li      a0, 0x544c4d4641494c21 /* "TLMFAIL!" */
    ebreak
.Lmachine_halt:
    j       .Lmachine_halt

.size _start, .-_start

.section .text.startup, "ax", @progbits
.option norvc
.globl supervisor_start
.type supervisor_start, @function

supervisor_start:
    la      s1, ticket_lock_4h_private_pages
    slli    t0, tp, 12
    add     s0, s1, t0
    li      t0, 4096
    add     sp, s0, t0
    addi    sp, sp, -16

    la      s4, ticket_lock_4h_word
    la      s5, ticket_lock_4h_counter
    la      s6, ticket_lock_4h_guard
    la      s7, ticket_lock_4h_control
    li      s8, LOCK_TARGET
    li      s3, 0
    li      s9, 0

    /* Distinct deterministic jitter state; it does not assign turns. */
    li      s2, 0x6d2b79f5
    slli    t0, tp, 20
    xor     s2, s2, t0

    bnez    tp, .Lwait_initialized

    sw      zero, 0(s4)
    sd      zero, 0(s5)
    sw      zero, 0(s6)
    sd      zero, CONTROL_STATE(s7)
    li      t0, 0
.Lclear_control_slots:
    slli    t1, t0, 3
    addi    t2, s7, CONTROL_READY
    add     t2, t2, t1
    sd      zero, 0(t2)
    addi    t2, s7, CONTROL_EXITED
    add     t2, t2, t1
    sd      zero, 0(t2)
    addi    t0, t0, 1
    li      t1, HART_COUNT
    bltu    t0, t1, .Lclear_control_slots
    fence   rw, rw
    li      t0, INIT_MAGIC
    sd      t0, CONTROL_STATE(s7)
    fence   rw, rw
    j       .Lpublish_ready

.Lwait_initialized:
    li      t1, INIT_MAGIC
.Lwait_initialized_loop:
    ld      t0, CONTROL_STATE(s7)
    bne     t0, t1, .Lwait_initialized_loop
    fence   r, r

.Lpublish_ready:
    slli    t0, tp, 3
    addi    t1, s7, CONTROL_READY
    add     t1, t1, t0
    addi    t0, tp, 1
    sd      t0, 0(t1)
    fence   rw, rw
    bnez    tp, .Lwait_go

    li      t2, 0
.Lwait_all_ready:
    slli    t0, t2, 3
    addi    t1, s7, CONTROL_READY
    add     t1, t1, t0
    ld      t0, 0(t1)
    addi    t1, t2, 1
    bne     t0, t1, .Lwait_all_ready
    addi    t2, t2, 1
    li      t0, HART_COUNT
    bltu    t2, t0, .Lwait_all_ready
    fence   r, rw
    li      t0, GO_MAGIC
    sd      t0, CONTROL_STATE(s7)
    fence   rw, rw

.Lwait_go:
    li      t1, GO_MAGIC
.Lwait_go_loop:
    ld      t0, CONTROL_STATE(s7)
    bne     t0, t1, .Lwait_go_loop
    fence   r, r

.Lhammer:
    jal     ra, random_nop_jitter

    /* Allocate one packed ticket: old.next is this hart's ticket. */
    li      t0, LOCK_NEXT_INCREMENT
    amoadd.w.aq t1, t0, (s4)
    srliw   s9, t1, 16
    slli    t2, t1, 48
    srli    t2, t2, 48
    beq     t2, s9, .Lticket_acquired
.Lticket_wait:
    lhu     t2, 0(s4)
    bne     t2, s9, .Lticket_wait
.Lticket_acquired:
    fence   r, r

    /* A second independent invariant catches overlapping critical sections. */
    lw      t2, 0(s6)
    bnez    t2, .Lfail_guard_busy
    addi    t3, tp, 1
    sw      t3, 0(s6)
    fence   rw, rw
    lw      t2, 0(s6)
    bne     t2, t3, .Lfail_guard_owner

    ld      t4, 0(s5)
    bgeu    t4, s8, .Lrelease_terminal
    addi    t4, t4, 1
    sd      t4, 0(s5)
    addi    s3, s3, 1

.Lrelease_terminal:
    lw      t2, 0(s6)
    bne     t2, t3, .Lfail_guard_owner
    sw      zero, 0(s6)

    /* Linux-style store-release of the low owner halfword. */
    fence   rw, w
    addi    t0, s9, 1
    sh      t0, 0(s4)

    bgeu    t4, s8, .Lwork_complete
    j       .Lhammer

.Lwork_complete:
    sd      s3, PRIVATE_INCREMENT_COUNT(s0)
    sd      s9, PRIVATE_LAST_TICKET(s0)

    slli    t0, tp, 3
    addi    t1, s7, CONTROL_EXITED
    add     t1, t1, t0
    li      t0, EXIT_MAGIC
    or      t0, t0, tp
    sd      t0, 0(t1)
    fence   rw, rw
    bnez    tp, .Lwait_release

    li      t2, 0
.Lwait_all_exited:
    slli    t0, t2, 3
    addi    t1, s7, CONTROL_EXITED
    add     t1, t1, t0
    ld      t0, 0(t1)
    li      t1, EXIT_MAGIC
    or      t1, t1, t2
    bne     t0, t1, .Lwait_all_exited
    addi    t2, t2, 1
    li      t0, HART_COUNT
    bltu    t2, t0, .Lwait_all_exited
    fence   r, rw

    ld      t0, 0(s5)
    bne     t0, s8, .Lfail_counter
    lw      t0, 0(s6)
    bnez    t0, .Lfail_guard_busy

    li      t1, LOCK_FINAL_TICKET
    slli    t0, t1, 16
    or      t0, t0, t1
    lwu     t2, 0(s4)
    bne     t2, t0, .Lfail_final_lock

    li      t2, 0
    li      t3, 0
.Lsum_increment_counts:
    slli    t0, t2, 12
    add     t1, s1, t0
    ld      t0, PRIVATE_INCREMENT_COUNT(t1)
    beqz    t0, .Lfail_starved_hart
    add     t3, t3, t0
    addi    t2, t2, 1
    li      t0, HART_COUNT
    bltu    t2, t0, .Lsum_increment_counts
    bne     t3, s8, .Lfail_increment_sum

    li      t0, RELEASE_MAGIC
    sd      t0, CONTROL_STATE(s7)
    fence   rw, rw

.Lwait_release:
    li      t1, RELEASE_MAGIC
.Lwait_release_loop:
    ld      t0, CONTROL_STATE(s7)
    bne     t0, t1, .Lwait_release_loop
    fence   r, r

    /* Publish success only after hart 0 validates all shared invariants. */
    sw      zero, PRIVATE_RESULT(s0)
    addi    t0, tp, 1
    sw      t0, PRIVATE_MAILBOX(s0)
    fence   rw, rw

    .globl ticket_lock_4h_shared_vm_done
ticket_lock_4h_shared_vm_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

/* Advance xorshift state and execute 0..31 NOPs. */
random_nop_jitter:
    slli    t0, s2, 13
    xor     s2, s2, t0
    srli    t0, s2, 7
    xor     s2, s2, t0
    slli    t0, s2, 17
    xor     s2, s2, t0
    andi    t0, s2, 31
    beqz    t0, .Ljitter_done
.Ljitter_loop:
    addi    x0, x0, 0
    addi    t0, t0, -1
    bnez    t0, .Ljitter_loop
.Ljitter_done:
    jalr    x0, 0(ra)

.Lfail_guard_busy:
    li      a0, 1
    j       supervisor_fail
.Lfail_guard_owner:
    li      a0, 2
    j       supervisor_fail
.Lfail_counter:
    li      a0, 3
    j       supervisor_fail
.Lfail_final_lock:
    li      a0, 4
    j       supervisor_fail
.Lfail_starved_hart:
    li      a0, 5
    j       supervisor_fail
.Lfail_increment_sum:
    li      a0, 6

supervisor_fail:
    sw      a0, PRIVATE_RESULT(s0)
    addi    t0, tp, 1
    sw      t0, PRIVATE_MAILBOX(s0)
    fence   rw, rw
    ebreak
.Lsupervisor_fail_halt:
    j       .Lsupervisor_fail_halt

.size supervisor_start, .-supervisor_start

.section .data, "aw", @progbits
.balign 64
.globl ticket_lock_4h_word
ticket_lock_4h_word:
    .word 0
    .zero 60

.balign 64
.globl ticket_lock_4h_counter
ticket_lock_4h_counter:
    .dword 0
    .zero 56

.balign 64
.globl ticket_lock_4h_guard
ticket_lock_4h_guard:
    .word 0
    .zero 60

.balign 64
.globl ticket_lock_4h_control
ticket_lock_4h_control:
    .zero 128

.section .hart_private, "aw", @nobits
.balign 4096
.globl ticket_lock_4h_private_pages
ticket_lock_4h_private_pages:
    .zero 16384
.globl ticket_lock_4h_result_base
.set ticket_lock_4h_result_base, ticket_lock_4h_private_pages + PRIVATE_RESULT

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
