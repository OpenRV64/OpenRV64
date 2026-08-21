    .section .text.boot, "ax", @progbits
    .option norvc
    .globl _start
    .type _start, @function

#ifndef OPENRV64_COHERENCE_CASE
#define OPENRV64_COHERENCE_CASE 0
#endif

#ifndef OPENRV64_COHERENCE_ITERATIONS
#define OPENRV64_COHERENCE_ITERATIONS 64
#endif

#ifndef OPENRV64_COHERENCE_HARTS
#define OPENRV64_COHERENCE_HARTS 4
#endif

#if OPENRV64_COHERENCE_CASE < 0 || OPENRV64_COHERENCE_CASE > 22
#error OPENRV64_COHERENCE_CASE must be 0 through 22
#endif

#if OPENRV64_COHERENCE_ITERATIONS < 1
#error OPENRV64_COHERENCE_ITERATIONS must be positive
#endif

#if OPENRV64_COHERENCE_HARTS < 1 || OPENRV64_COHERENCE_HARTS > 4
#error OPENRV64_COHERENCE_HARTS must be 1 through 4
#endif

/*
 * One-to-four-hart shared-Sv39 L2-coherence performance payload.
 *
 * Cases are separate binaries so testbench coherence counters are attributable
 * to one sharing pattern:
 *   0: page-separated private lines, ordinary load/store control;
 *   1: one ordinary-store token line, strict ownership handoff;
 *   2: eight independent token lines in one 4 KiB page;
 *   3: eight independent token lines in eight distinct 4 KiB pages;
 *   4: one LR/SC token line, strict ownership handoff;
 *   5: a ticket lock protecting a separate shared counter;
 *   6: disjoint per-hart lines 1 KiB apart in one shared page.
 *   7-21: one-to-four-hart controls, loads/stores, fences, LR/SC, AMO, and a
 *         Linux-shaped rwsem writer pair. The one-hart form is uncontended;
 *         multiple harts deliberately contend on the same cacheline.
 *   22: four harts repeatedly walk four cacheline-separated locks using
 *       hand-over-hand locking. Each hart acquires the next lock before
 *       releasing the previous lock; no hart-number ordering is imposed.
 *
 * Every hart installs the same Sv39 root. Shared benchmark lines therefore
 * have identical VA and PA on all harts. Only the result/stack page is selected
 * with mhartid. A start barrier and all validation are outside the measured
 * interval; the final fence remains inside so every measured store/coherence
 * action has completed before the end counters are read.
 *
 * Result ABI, one 4 KiB page per hart:
 *   +0x00 u32 completion (hartid + 1)
 *   +0x04 u32 status     (zero on success)
 *   +0x08 u64 case signature
 *   +0x10 u64 start cycle
 *   +0x18 u64 end cycle
 *   +0x20 u64 elapsed cycles
 *   +0x28 u64 start instret
 *   +0x30 u64 end instret
 *   +0x38 u64 retired instructions
 */

    .equ HART_COUNT,              OPENRV64_COHERENCE_HARTS
    .equ RESULT_STRIDE,           4096
    .equ RESULT_DONE,             0x00
    .equ RESULT_STATUS,           0x04
    .equ RESULT_SIGNATURE,        0x08
    .equ RESULT_START_CYCLE,      0x10
    .equ RESULT_END_CYCLE,        0x18
    .equ RESULT_CYCLES,           0x20
    .equ RESULT_START_INSTRET,    0x28
    .equ RESULT_END_INSTRET,      0x30
    .equ RESULT_INSTRET,          0x38
    .equ CONTROL_INIT,            0x00
    .equ CONTROL_GO,              0x08
    .equ CONTROL_READY,           0x10
    .equ CONTROL_BYTES,           0x40
    .equ COHERENCE_LINE_BYTES,    64
    .equ COHERENCE_LINES,         8
    .equ LOCK_WALK_LOCKS,         4
    .equ PERF_ITERATIONS,         OPENRV64_COHERENCE_ITERATIONS
#if OPENRV64_COHERENCE_CASE == 2 || OPENRV64_COHERENCE_CASE == 3
    .equ PERF_OPERATIONS,         PERF_ITERATIONS * HART_COUNT * COHERENCE_LINES
#elif OPENRV64_COHERENCE_CASE == 22
    .equ PERF_OPERATIONS,         PERF_ITERATIONS * HART_COUNT * LOCK_WALK_LOCKS
#else
    .equ PERF_OPERATIONS,         PERF_ITERATIONS * HART_COUNT
#endif
#if OPENRV64_COHERENCE_CASE == 0 || OPENRV64_COHERENCE_CASE == 3
    .equ TEST_LINE_SHIFT,         12
#elif OPENRV64_COHERENCE_CASE == 6
    .equ TEST_LINE_SHIFT,         10
#else
    .equ TEST_LINE_SHIFT,         6
#endif

    .equ INIT_MAGIC,              0x434f48494e495400
    .equ GO_MAGIC,                0x434f48474f000000
    .equ READY_MAGIC,             0x434f485245414400
    .equ DONE_MAGIC,              0x434f48444f4e4500
    .equ RELEASE_MAGIC,           0x434f4852454c5300
    .equ FAILURE_DONE,            0xdead0000
    .equ FAILURE_STATUS,          1

_start:
    la      t0, machine_trap
    csrw    mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    csrr    tp, mhartid
    li      t0, HART_COUNT
    bgeu    tp, t0, machine_trap

    /* Every hart installs exactly the same root and ASID. */
    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    /* Permit S-mode cycle and instret reads. */
    li      t0, 0x5
    csrw    mcounteren, t0

    la      t0, supervisor_start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

machine_trap:
    li      a0, 0x434f484641494c00
    ebreak
.Lmachine_halt:
    j       .Lmachine_halt

    .size _start, .-_start

    .section .text.startup, "ax", @progbits
    .option norvc
    .globl supervisor_start
    .type supervisor_start, @function

supervisor_start:
    la      s0, coherence_4h_perf_results
    slli    t0, tp, 12
    add     s0, s0, t0
    li      t0, RESULT_STRIDE
    add     sp, s0, t0
    addi    sp, sp, -16

#if OPENRV64_COHERENCE_CASE == 0 || OPENRV64_COHERENCE_CASE == 3
    la      s4, coherence_4h_perf_page_lines
#elif OPENRV64_COHERENCE_CASE == 5
    la      s4, coherence_4h_perf_ticket_lines
#else
    la      s4, coherence_4h_perf_lines
#endif
    la      s5, coherence_4h_perf_control

    /* Publish deterministic initialization after the zero-filled image. */
    bnez    tp, .Lwait_init
    fence   rw, rw
    li      t0, INIT_MAGIC
    sd      t0, CONTROL_INIT(s5)

.Lwait_init:
    li      t1, INIT_MAGIC
.Lwait_init_loop:
    ld      t0, CONTROL_INIT(s5)
    bne     t0, t1, .Lwait_init_loop

    /*
     * Establish a deterministic hot starting state outside the interval.
     * Private mode warms only the hart-private line. Shared modes warm every
     * tested line in every active L1D, making the first writer invalidate the
     * complete initial sharer set instead of measuring a backing-memory miss.
     */
#if OPENRV64_COHERENCE_CASE == 0 || OPENRV64_COHERENCE_CASE == 6
    slli    t0, tp, TEST_LINE_SHIFT
    add     t0, s4, t0
    ld      t1, 0(t0)
#elif OPENRV64_COHERENCE_CASE == 2 || OPENRV64_COHERENCE_CASE == 3 || \
      OPENRV64_COHERENCE_CASE == 22
    li      t0, 0
.Lwarm_shared_lines:
    slli    t1, t0, TEST_LINE_SHIFT
    add     t1, s4, t1
    ld      t2, 0(t1)
    addi    t0, t0, 1
#if OPENRV64_COHERENCE_CASE == 22
    li      t1, LOCK_WALK_LOCKS
#else
    li      t1, COHERENCE_LINES
#endif
    bltu    t0, t1, .Lwarm_shared_lines
#elif OPENRV64_COHERENCE_CASE != 5
    ld      t0, 0(s4)
#else
    ld      t0, 0(s4)
    ld      t0, COHERENCE_LINE_BYTES(s4)
    ld      t0, 2*COHERENCE_LINE_BYTES(s4)
#endif
    fence   r, r

    /* One distinct ready slot per hart; this line is outside the benchmark. */
    li      t0, READY_MAGIC
    or      t0, t0, tp
    slli    t1, tp, 3
    addi    t1, t1, CONTROL_READY
    add     t1, t1, s5
    sd      t0, 0(t1)
    fence   rw, rw

    bnez    tp, .Lwait_go
    li      t2, 0
.Lwait_all_ready:
    slli    t0, t2, 3
    addi    t0, t0, CONTROL_READY
    add     t0, t0, s5
    ld      t1, 0(t0)
    li      t3, READY_MAGIC
    or      t3, t3, t2
    bne     t1, t3, .Lwait_all_ready
    addi    t2, t2, 1
    li      t0, HART_COUNT
    bltu    t2, t0, .Lwait_all_ready
    fence   rw, rw
    li      t0, GO_MAGIC
    sd      t0, CONTROL_GO(s5)

.Lwait_go:
    li      t1, GO_MAGIC
.Lwait_go_loop:
    ld      t0, CONTROL_GO(s5)
    bne     t0, t1, .Lwait_go_loop
    fence   rw, rw

    .globl coherence_4h_perf_measure_start
coherence_4h_perf_measure_start:
    rdcycle s1
    rdinstret s2

#if OPENRV64_COHERENCE_CASE == 0 || OPENRV64_COHERENCE_CASE == 6
    /* Disjoint-line controls: same store count without cross-hart sharing. */
    slli    t0, tp, TEST_LINE_SHIFT
    add     s6, s4, t0
    li      s3, PERF_ITERATIONS
.Lprivate_loop:
    ld      t0, 0(s6)
    addi    t0, t0, 1
    sd      t0, 0(s6)
    addi    s3, s3, -1
    bnez    s3, .Lprivate_loop

#elif OPENRV64_COHERENCE_CASE == 1
    /* One ordinary-store token line: exactly one eligible writer per turn. */
    li      s3, PERF_ITERATIONS
    mv      s6, tp
.Lhandoff1_retry:
    ld      t0, 0(s4)
    bne     t0, s6, .Lhandoff1_retry
    addi    t0, t0, 1
    sd      t0, 0(s4)
    /* Force this ownership transfer out before waiting for its return. */
    fence   rw, rw
    addi    s6, s6, HART_COUNT
    addi    s3, s3, -1
    bnez    s3, .Lhandoff1_retry

#elif OPENRV64_COHERENCE_CASE == 2 || OPENRV64_COHERENCE_CASE == 3
    /* Eight independent tokens expose line-level L2/coherence concurrency. */
    li      s3, 0
    mv      s6, tp
.Lhandoff8_pass:
    addi    s7, s6, 1
    li      s8, 0
.Lhandoff8_line:
    slli    t0, s8, TEST_LINE_SHIFT
    add     t1, s4, t0
.Lhandoff8_retry:
    ld      t2, 0(t1)
    bne     t2, s6, .Lhandoff8_retry
    sd      s7, 0(t1)
    addi    s8, s8, 1
    li      t0, COHERENCE_LINES
    bltu    s8, t0, .Lhandoff8_line
    /* Publish the eight independent transfers as one coherence batch. */
    fence   rw, rw
    addi    s6, s6, HART_COUNT
    addi    s3, s3, 1
    li      t0, PERF_ITERATIONS
    bltu    s3, t0, .Lhandoff8_pass

#elif OPENRV64_COHERENCE_CASE == 4
    /* LR/SC handoff keeps the same schedule but exercises reservations. */
    li      s3, PERF_ITERATIONS
    mv      s6, tp
.Llrsc1_retry:
    lr.w.aq t0, (s4)
    bne     t0, s6, .Llrsc1_retry
    addi    t2, t0, 1
    sc.w.rl t3, t2, (s4)
    bnez    t3, .Llrsc1_retry
    addi    s6, s6, HART_COUNT
    addi    s3, s3, -1
    bnez    s3, .Llrsc1_retry

#elif OPENRV64_COHERENCE_CASE == 5
    /*
     * Ticket lock: AMOADD allocates a unique ticket, an acquire spin waits on
     * the serving line, and the lock protects an ordinary shared counter on a
     * third cache line. Release is a store-release after the protected write.
     */
    addi    s6, s4, COHERENCE_LINE_BYTES
    addi    s7, s4, 2*COHERENCE_LINE_BYTES
    li      s3, PERF_ITERATIONS
    li      t6, 1
.Lticket_acquire:
    amoadd.d.aq s8, t6, (s4)
.Lticket_wait:
    ld      t0, 0(s6)
    bne     t0, s8, .Lticket_wait
    ld      t1, 0(s7)
    addi    t1, t1, 1
    sd      t1, 0(s7)
    fence   rw, w
    addi    t0, s8, 1
    sd      t0, 0(s6)
    addi    s3, s3, -1
    bnez    s3, .Lticket_acquire

#elif OPENRV64_COHERENCE_CASE == 7
    /* Three-instruction loop control for load/store/LR/AMO cases. */
    li      s3, PERF_ITERATIONS
.Latomic_ctrl3_loop:
    addi    x0, x0, 0
    addi    s3, s3, -1
    bnez    s3, .Latomic_ctrl3_loop

#elif OPENRV64_COHERENCE_CASE == 8
    /* Four-instruction loop control for fence+memory cases. */
    li      s3, PERF_ITERATIONS
.Latomic_ctrl4_loop:
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    s3, s3, -1
    bnez    s3, .Latomic_ctrl4_loop

#elif OPENRV64_COHERENCE_CASE == 9
    /* Six-instruction loop control for a successful LR/SC attempt. */
    li      s3, PERF_ITERATIONS
.Latomic_ctrl6_loop:
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    s3, s3, -1
    bnez    s3, .Latomic_ctrl6_loop

#elif OPENRV64_COHERENCE_CASE == 10
    li      s3, PERF_ITERATIONS
.Latomic_fence_acquire_loop:
    fence   r, rw
    addi    s3, s3, -1
    bnez    s3, .Latomic_fence_acquire_loop

#elif OPENRV64_COHERENCE_CASE == 11
    li      s3, PERF_ITERATIONS
.Latomic_fence_release_loop:
    fence   rw, w
    addi    s3, s3, -1
    bnez    s3, .Latomic_fence_release_loop

#elif OPENRV64_COHERENCE_CASE == 12
    li      s3, PERF_ITERATIONS
.Latomic_fence_full_loop:
    fence   rw, rw
    addi    s3, s3, -1
    bnez    s3, .Latomic_fence_full_loop

#elif OPENRV64_COHERENCE_CASE == 13
    li      s3, PERF_ITERATIONS
.Latomic_load_loop:
    ld      t0, 0(s4)
    addi    s3, s3, -1
    bnez    s3, .Latomic_load_loop

#elif OPENRV64_COHERENCE_CASE == 14
    li      s3, PERF_ITERATIONS
.Latomic_store_loop:
    sd      s3, 0(s4)
    addi    s3, s3, -1
    bnez    s3, .Latomic_store_loop

#elif OPENRV64_COHERENCE_CASE == 15
    li      s3, PERF_ITERATIONS
.Latomic_store_release_loop:
    sd      s3, 0(s4)
    fence   rw, w
    addi    s3, s3, -1
    bnez    s3, .Latomic_store_release_loop

#elif OPENRV64_COHERENCE_CASE == 16
    li      s3, PERF_ITERATIONS
.Latomic_lr_loop:
    lr.d    t0, (s4)
    addi    s3, s3, -1
    bnez    s3, .Latomic_lr_loop

#elif OPENRV64_COHERENCE_CASE == 17 || OPENRV64_COHERENCE_CASE == 18
    li      s3, PERF_ITERATIONS
.Latomic_lrsc_loop:
    lr.d    t0, (s4)
    addi    t1, t0, 1
    sc.d    t2, t1, (s4)
    bnez    t2, .Latomic_lrsc_loop
#if OPENRV64_COHERENCE_CASE == 18
    fence   r, rw
#endif
    addi    s3, s3, -1
    bnez    s3, .Latomic_lrsc_loop

#elif OPENRV64_COHERENCE_CASE == 19
    li      s3, PERF_ITERATIONS
    li      t1, 1
.Latomic_amoadd_loop:
    amoadd.d t0, t1, (s4)
    addi    s3, s3, -1
    bnez    s3, .Latomic_amoadd_loop

#elif OPENRV64_COHERENCE_CASE == 20
    li      s3, PERF_ITERATIONS
    li      t1, 1
.Latomic_release_amoadd_loop:
    fence   rw, w
    amoadd.d t0, t1, (s4)
    addi    s3, s3, -1
    bnez    s3, .Latomic_release_amoadd_loop

#elif OPENRV64_COHERENCE_CASE == 21
    /*
     * Uncontended Linux writer-rwsem shape:
     *   down_write: LR.D/SC.D, acquire fence, owner store
     *   up_write:   owner clear, release fence, AMOADD.D(-1)
     * The owner and count fields deliberately occupy the same cache line.
     */
    li      s3, PERF_ITERATIONS
    li      s7, 1
    li      s8, -1
.Latomic_rwsem_loop:
    lr.d    t0, (s4)
#if OPENRV64_COHERENCE_HARTS == 1
    bnez    t0, .Lperf_failure
#else
    bnez    t0, .Latomic_rwsem_loop
#endif
    sc.d    t1, s7, (s4)
    bnez    t1, .Latomic_rwsem_loop
    fence   r, rw
    sd      s0, 8(s4)
    sd      zero, 8(s4)
    fence   rw, w
    amoadd.d t2, s8, (s4)
    bne     t2, s7, .Lperf_failure
    addi    s3, s3, -1
    bnez    s3, .Latomic_rwsem_loop

#else
    /*
     * Four cacheline-separated locks, traversed in one global order so the
     * hand-over-hand protocol cannot form a lock-order cycle. All harts enter
     * at lock 0 and contention determines their order through the pipeline.
     */
    li      s3, PERF_ITERATIONS
    li      s7, 1
.Llock_walk_pass:
    mv      s6, s4
.Llock_walk_acquire_first:
    lr.d    t0, (s6)
    bnez    t0, .Llock_walk_acquire_first
    sc.d    t1, s7, (s6)
    bnez    t1, .Llock_walk_acquire_first
    fence   r, rw

    li      s8, 1
.Llock_walk_next:
    slli    t2, s8, 6
    add     t2, s4, t2
.Llock_walk_acquire_next:
    lr.d    t0, (t2)
    bnez    t0, .Llock_walk_acquire_next
    sc.d    t1, s7, (t2)
    bnez    t1, .Llock_walk_acquire_next
    fence   r, rw
    fence   rw, w
    sd      zero, 0(s6)
    mv      s6, t2
    addi    s8, s8, 1
    li      t3, LOCK_WALK_LOCKS
    bltu    s8, t3, .Llock_walk_next

    fence   rw, w
    sd      zero, 0(s6)
    addi    s3, s3, -1
    bnez    s3, .Llock_walk_pass
#endif

    /* Include architectural and coherent completion of every measured store. */
    fence   rw, rw

    .globl coherence_4h_perf_measure_end
coherence_4h_perf_measure_end:
    rdinstret s3
    rdcycle s6

    sub     t0, s6, s1
    sub     t1, s3, s2
    sd      s1, RESULT_START_CYCLE(s0)
    sd      s6, RESULT_END_CYCLE(s0)
    sd      t0, RESULT_CYCLES(s0)
    sd      s2, RESULT_START_INSTRET(s0)
    sd      s3, RESULT_END_INSTRET(s0)
    sd      t1, RESULT_INSTRET(s0)

    /* Post-measurement barrier before common-state validation. */
    li      t0, DONE_MAGIC
    or      t0, t0, tp
    slli    t1, tp, 3
    addi    t1, t1, CONTROL_READY
    add     t1, t1, s5
    sd      t0, 0(t1)
    fence   rw, rw

    bnez    tp, .Lwait_release
    li      t2, 0
.Lwait_all_done:
    slli    t0, t2, 3
    addi    t0, t0, CONTROL_READY
    add     t0, t0, s5
    ld      t1, 0(t0)
    li      t3, DONE_MAGIC
    or      t3, t3, t2
    bne     t1, t3, .Lwait_all_done
    addi    t2, t2, 1
    li      t0, HART_COUNT
    bltu    t2, t0, .Lwait_all_done
    fence   rw, rw
    li      t0, RELEASE_MAGIC
    sd      t0, CONTROL_GO(s5)

.Lwait_release:
    li      t1, RELEASE_MAGIC
.Lwait_release_loop:
    ld      t0, CONTROL_GO(s5)
    bne     t0, t1, .Lwait_release_loop
    fence   rw, rw

    /* Validate only after timing and publish one common case signature. */
#if OPENRV64_COHERENCE_CASE == 0 || OPENRV64_COHERENCE_CASE == 6
    slli    t0, tp, TEST_LINE_SHIFT
    add     t0, s4, t0
    ld      t1, 0(t0)
    li      t2, PERF_ITERATIONS
    bne     t1, t2, .Lperf_failure
    li      t6, 0x4350524956415445
    .if OPENRV64_COHERENCE_CASE == 6
    li      t6, 0x434f484449464c4e
    .endif
#elif OPENRV64_COHERENCE_CASE == 1
    ld      t1, 0(s4)
    li      t2, PERF_ITERATIONS * HART_COUNT
    bne     t1, t2, .Lperf_failure
    li      t6, 0x434f483148414e44
#elif OPENRV64_COHERENCE_CASE == 2 || OPENRV64_COHERENCE_CASE == 3
    li      t2, PERF_ITERATIONS * HART_COUNT
    li      t3, 0
.Lvalidate_handoff8:
    slli    t0, t3, TEST_LINE_SHIFT
    add     t0, s4, t0
    ld      t1, 0(t0)
    bne     t1, t2, .Lperf_failure
    addi    t3, t3, 1
    li      t0, COHERENCE_LINES
    bltu    t3, t0, .Lvalidate_handoff8
    li      t6, 0x434f483848414e44
    .if OPENRV64_COHERENCE_CASE == 3
    li      t6, 0x434f485041474553
    .endif
#elif OPENRV64_COHERENCE_CASE == 4
    lw      t1, 0(s4)
    li      t2, PERF_ITERATIONS * HART_COUNT
    bne     t1, t2, .Lperf_failure
    li      t6, 0x434f48314c525343
#elif OPENRV64_COHERENCE_CASE == 5
    li      t2, PERF_OPERATIONS
    ld      t1, 0(s4)
    bne     t1, t2, .Lperf_failure
    ld      t1, COHERENCE_LINE_BYTES(s4)
    bne     t1, t2, .Lperf_failure
    ld      t1, 2*COHERENCE_LINE_BYTES(s4)
    bne     t1, t2, .Lperf_failure
    li      t6, 0x434f485449434b54
#elif OPENRV64_COHERENCE_CASE == 14 || OPENRV64_COHERENCE_CASE == 15
    ld      t1, 0(s4)
    li      t2, 1
    bne     t1, t2, .Lperf_failure
    li      t6, 0x41544f4d00000000 + OPENRV64_COHERENCE_CASE
#elif OPENRV64_COHERENCE_CASE >= 17 && OPENRV64_COHERENCE_CASE <= 20
    ld      t1, 0(s4)
    li      t2, PERF_OPERATIONS
    bne     t1, t2, .Lperf_failure
    li      t6, 0x41544f4d00000000 + OPENRV64_COHERENCE_CASE
#elif OPENRV64_COHERENCE_CASE == 21
    ld      t1, 0(s4)
    bnez    t1, .Lperf_failure
    ld      t1, 8(s4)
    bnez    t1, .Lperf_failure
    li      t6, 0x41544f4d00000000 + OPENRV64_COHERENCE_CASE
#elif OPENRV64_COHERENCE_CASE == 22
    li      t2, 0
.Lvalidate_lock_walk:
    slli    t0, t2, 6
    add     t0, s4, t0
    ld      t1, 0(t0)
    bnez    t1, .Lperf_failure
    addi    t2, t2, 1
    li      t0, LOCK_WALK_LOCKS
    bltu    t2, t0, .Lvalidate_lock_walk
    li      t6, 0x41544f4d00000000 + OPENRV64_COHERENCE_CASE
#else
    /* Controls, fences, ordinary loads, and LR-only leave data unchanged. */
    ld      t1, 0(s4)
    bnez    t1, .Lperf_failure
    li      t6, 0x41544f4d00000000 + OPENRV64_COHERENCE_CASE
#endif

    sw      zero, RESULT_STATUS(s0)
    sd      t6, RESULT_SIGNATURE(s0)
    fence   rw, rw

    /* Hart 0 publishes completion last after checking every peer. */
    beqz    tp, .Lprimary_validate
    addi    t0, tp, 1
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw
    j       .Lreport_registers

.Lprimary_validate:
    la      t0, coherence_4h_perf_results
    ld      t6, RESULT_SIGNATURE(t0)
    li      t1, 1
    li      t2, HART_COUNT
    bgeu    t1, t2, .Lprimary_publish
.Lwait_secondary_done:
    slli    t2, t1, 12
    add     t3, t0, t2
    lw      t4, RESULT_DONE(t3)
    addi    t5, t1, 1
    bne     t4, t5, .Lwait_secondary_done
    lw      t4, RESULT_STATUS(t3)
    bnez    t4, .Lperf_failure
    ld      t4, RESULT_SIGNATURE(t3)
    bne     t4, t6, .Lperf_failure
    addi    t1, t1, 1
    li      t2, HART_COUNT
    bltu    t1, t2, .Lwait_secondary_done

.Lprimary_publish:
    li      t0, 1
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw
    j       .Lreport_registers

.Lperf_failure:
    li      t0, FAILURE_STATUS
    sw      t0, RESULT_STATUS(s0)
    li      t0, FAILURE_DONE
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw

    /* One-hart harness register ABI; the four-hart harness uses memory. */
.Lreport_registers:
    ld      a0, RESULT_SIGNATURE(s0)
    ld      a1, RESULT_CYCLES(s0)
    ld      a2, RESULT_INSTRET(s0)
    li      a3, PERF_OPERATIONS
    lw      a4, RESULT_STATUS(s0)
    li      a5, OPENRV64_COHERENCE_CASE

    /*
     * The single-hart harness samples the architectural register file when
     * the done PC retires.  Leave enough retirement distance for the final
     * a5 write to be visible in that same observation scheme.
     */
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0

    .globl coherence_4h_perf_done
coherence_4h_perf_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

    .size supervisor_start, .-supervisor_start

    .section .data, "aw", @progbits
    .balign 64
    .globl coherence_4h_perf_control
coherence_4h_perf_control:
    .zero CONTROL_BYTES

    .balign 64
    .globl coherence_4h_perf_lines
coherence_4h_perf_lines:
    /* Four 1-KiB-spaced slots, ending before the next 4 KiB boundary. */
    .zero 3 * 1024 + COHERENCE_LINE_BYTES

    .balign 4096
    .globl coherence_4h_perf_page_lines
coherence_4h_perf_page_lines:
    .zero COHERENCE_LINES * 4096

    .balign 64
    .globl coherence_4h_perf_ticket_lines
coherence_4h_perf_ticket_lines:
    .zero 3 * COHERENCE_LINE_BYTES

    .section .hart_private, "aw", @nobits
    .balign 4096
    .globl coherence_4h_perf_results
coherence_4h_perf_results:
    .zero 16384
    .globl coherence_4h_perf_status
    .set coherence_4h_perf_status, coherence_4h_perf_results + 4

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
