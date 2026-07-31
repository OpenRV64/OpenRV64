    .section .text.boot, "ax", @progbits
    .option norvc
    .globl _start
    .type _start, @function

#ifndef OPENRV64_4H_PERF_ITERATIONS
#define OPENRV64_4H_PERF_ITERATIONS 16
#endif

#if OPENRV64_4H_PERF_ITERATIONS < 1
#error OPENRV64_4H_PERF_ITERATIONS must be positive
#endif

/*
 * Four-hart bare-address performance payload.
 *
 * All harts share text and read-only data, but select separate 4 KiB result
 * and stack pages with mhartid. The measured region contains only repeated
 * calls to the CoreMark-derived parser loop. Startup, synchronization, result
 * publication, and completion polling are outside the cycle/instret window.
 *
 * Result ABI, one 4 KiB page per hart:
 *   +0x00 u32 completion (hartid + 1)
 *   +0x04 u32 status     (zero on success)
 *   +0x08 u64 result signature
 *   +0x10 u64 start cycle
 *   +0x18 u64 end cycle
 *   +0x20 u64 elapsed cycles
 *   +0x28 u64 start instret
 *   +0x30 u64 end instret
 *   +0x38 u64 retired instructions
 *   +0x80 u32 private parser sink
 *
 * The dedicated linker retains zero-filled control/result storage in the flat
 * image, so synchronization has a deterministic cold-start state.
 */

    .equ HART_COUNT,              4
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
    .equ RESULT_PRIVATE_SINK,     0x80
    .equ CONTROL_INIT,            0x00
    .equ CONTROL_GO,              0x08
    .equ CONTROL_READY,           0x10
    .equ CONTROL_BYTES,           0x40

    .equ INIT_MAGIC,              0x344850455246494e
    .equ GO_MAGIC,                0x344850455246474f
    .equ READY_MAGIC,             0x3448504552465200
    .equ INITIAL_SINK,            0x6d5a56a9
    .equ SIGNATURE_SEED,          0x243f6a8885a308d3
    .equ SIGNATURE_ADD,           0x9e3779b97f4a7c15
    .equ FAILURE_DONE,            0xdead0000
    .equ FAILURE_STATUS,          1
    .equ PERF_ITERATIONS,         OPENRV64_4H_PERF_ITERATIONS

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

    /* Permit S-mode cycle and instret reads used by the measured region. */
    li      t0, 0x5
    csrw    mcounteren, t0

    la      t0, supervisor_start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

machine_trap:
    li      a0, 0x504552464641494c
    ebreak
.Lmachine_halt:
    j       .Lmachine_halt

    .size _start, .-_start

    .section .text.startup, "ax", @progbits
    .option norvc
    .globl supervisor_start
    .type supervisor_start, @function

supervisor_start:
    /* Select this hart's result page and private stack. */
    la      s0, coremark_4h_bare_perf_results
    slli    t0, tp, 12
    add     s0, s0, t0
    li      t0, RESULT_STRIDE
    add     sp, s0, t0
    addi    sp, sp, -16

    la      s5, coremark_4h_bare_perf_control

    /* Hart 0 publishes initialization after the zero-filled image is live. */
    bnez    tp, .Lwait_init
    fence   rw, rw
    li      t0, INIT_MAGIC
    sd      t0, CONTROL_INIT(s5)

.Lwait_init:
    li      t1, INIT_MAGIC
.Lwait_init_loop:
    ld      t0, CONTROL_INIT(s5)
    bne     t0, t1, .Lwait_init_loop

    /* Initialize the private parser state before the timed region. */
    addi    s4, s0, RESULT_PRIVATE_SINK
    li      t0, INITIAL_SINK
    sw      t0, 0(s4)

    /* Each hart publishes readiness in a distinct 64-bit slot. */
    li      t0, READY_MAGIC
    or      t0, t0, tp
    slli    t1, tp, 3
    addi    t1, t1, CONTROL_READY
    add     t1, t1, s5
    sd      t0, 0(t1)
    fence   rw, rw

    /* Hart 0 releases the common start only after all four ready records. */
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

    /*
     * Timed region. Keep the initial and final counters in callee-saved
     * registers so the C workload cannot overwrite them.
     */
    rdcycle s1
    rdinstret s2
    li      s3, PERF_ITERATIONS
    li      s7, SIGNATURE_SEED
.Lperf_loop:
    mv      a0, s4
    call    coremark_loop_with_sink
    slli    a0, a0, 32
    srli    a0, a0, 32
    xor     s7, s7, a0
    slli    t0, s7, 9
    srli    t1, s7, 55
    or      s7, t0, t1
    li      t0, SIGNATURE_ADD
    add     s7, s7, t0
    addi    s3, s3, -1
    bnez    s3, .Lperf_loop
    rdinstret s3
    rdcycle s6

    /* Publish the deterministic signature and raw measurements. */
    sub     t0, s6, s1
    sub     t1, s3, s2
    sw      zero, RESULT_STATUS(s0)
    sd      s7, RESULT_SIGNATURE(s0)
    sd      s1, RESULT_START_CYCLE(s0)
    sd      s6, RESULT_END_CYCLE(s0)
    sd      t0, RESULT_CYCLES(s0)
    sd      s2, RESULT_START_INSTRET(s0)
    sd      s3, RESULT_END_INSTRET(s0)
    sd      t1, RESULT_INSTRET(s0)
    fence   rw, rw

    /*
     * Secondaries publish completion and park. Hart 0 waits for them, checks
     * identical deterministic signatures, and publishes its own completion
     * last.
     * A mismatch deliberately writes an invalid mailbox value.
     */
    beqz    tp, .Lprimary_validate
    addi    t0, tp, 1
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw
    j       coremark_4h_bare_perf_done

.Lprimary_validate:
    la      t0, coremark_4h_bare_perf_results
    ld      t6, RESULT_SIGNATURE(t0)
    li      t1, 1
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

    li      t0, 1
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw
    j       coremark_4h_bare_perf_done

.Lperf_failure:
    li      t0, FAILURE_STATUS
    sw      t0, RESULT_STATUS(s0)
    li      t0, FAILURE_DONE
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw

    .globl coremark_4h_bare_perf_done
coremark_4h_bare_perf_done:
    addi    x0, x0, 0
.Lsupervisor_halt:
    j       .Lsupervisor_halt

    .size supervisor_start, .-supervisor_start

    .section .data, "aw", @progbits
    .balign 64
    .globl coremark_4h_bare_perf_control
coremark_4h_bare_perf_control:
    .zero CONTROL_BYTES

    .section .hart_private, "aw", @progbits
    .balign 4096
    .globl coremark_4h_bare_perf_results
coremark_4h_bare_perf_results:
    .zero 16384
    .globl coremark_4h_bare_perf_status
    .set coremark_4h_bare_perf_status, coremark_4h_bare_perf_results + 4
