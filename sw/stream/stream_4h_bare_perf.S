/*
 * Synchronized one-to-four-hart integer STREAM workload.
 *
 * Every active hart processes a disjoint STREAM_BYTES range of each array.
 * The common start barrier, result verification, and result publication are
 * outside the measured interval.  The final completion fence is measured so
 * all stores have reached the coherent hierarchy before the ending counters.
 */

#ifndef OPENRV64_STREAM_HARTS
#define OPENRV64_STREAM_HARTS 4
#endif

#ifndef OPENRV64_STREAM_KERNEL
#define OPENRV64_STREAM_KERNEL 3
#endif

#ifndef OPENRV64_STREAM_BYTES
#define OPENRV64_STREAM_BYTES 65536
#endif

#if OPENRV64_STREAM_HARTS < 1 || OPENRV64_STREAM_HARTS > 4
#error OPENRV64_STREAM_HARTS must be 1 through 4
#endif

#if OPENRV64_STREAM_KERNEL < 0 || OPENRV64_STREAM_KERNEL > 3
#error OPENRV64_STREAM_KERNEL must be 0 through 3
#endif

#if OPENRV64_STREAM_BYTES < 4096 || (OPENRV64_STREAM_BYTES % 64) != 0
#error OPENRV64_STREAM_BYTES must be at least 4096 and a multiple of 64
#endif

    .equ HART_COUNT,              OPENRV64_STREAM_HARTS
    .equ STREAM_KERNEL,           OPENRV64_STREAM_KERNEL
    .equ STREAM_BYTES,            OPENRV64_STREAM_BYTES
    .equ STREAM_WORDS,            STREAM_BYTES / 8
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

    .equ INIT_MAGIC,              0x5354524d494e4954
    .equ GO_MAGIC,                0x5354524d474f0000
    .equ READY_MAGIC,             0x5354524d52445900
    .equ STREAM_PASS,             0x53545245414d4f4b
    .equ FAILURE_STATUS,          1

    .section .text.boot, "ax", @progbits
    .option norvc
    .globl _start
    .type _start, @function

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

    li      t0, 0x5
    csrw    mcounteren, t0
    la      t0, supervisor_start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

machine_trap:
    li      a0, 0x5354524d4641494c
    ebreak
.Lmachine_halt:
    j       .Lmachine_halt

    .size _start, .-_start

    .section .text.startup, "ax", @progbits
    .option norvc
    .globl supervisor_start
    .type supervisor_start, @function

supervisor_start:
    la      s0, stream_4h_perf_results
    slli    t0, tp, 12
    add     s0, s0, t0
    li      t0, RESULT_STRIDE
    add     sp, s0, t0
    addi    sp, sp, -16

    /* Select disjoint per-hart source and destination ranges. */
    li      t0, STREAM_BYTES
    mul     t0, t0, tp
    la      s1, stream_4h_a
    add     s1, s1, t0
    la      s2, stream_4h_b
    add     s2, s2, t0
    la      s3, stream_4h_c
    add     s3, s3, t0
    la      s5, stream_4h_perf_control

    bnez    tp, .Lwait_init
    fence   rw, rw
    li      t0, INIT_MAGIC
    sd      t0, CONTROL_INIT(s5)

.Lwait_init:
    li      t1, INIT_MAGIC
.Lwait_init_loop:
    ld      t0, CONTROL_INIT(s5)
    bne     t0, t1, .Lwait_init_loop

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

    rdcycle s6
    rdinstret s7
    li      s4, STREAM_WORDS

    .globl stream_4h_perf_measure_start
stream_4h_perf_measure_start:
#if OPENRV64_STREAM_KERNEL == 0
.Lstream_loop:
    ld      t0, 0(s1)
    ld      t1, 8(s1)
    ld      t2, 16(s1)
    ld      t3, 24(s1)
    ld      t4, 32(s1)
    ld      t5, 40(s1)
    ld      t6, 48(s1)
    ld      a0, 56(s1)
    sd      t0, 0(s3)
    sd      t1, 8(s3)
    sd      t2, 16(s3)
    sd      t3, 24(s3)
    sd      t4, 32(s3)
    sd      t5, 40(s3)
    sd      t6, 48(s3)
    sd      a0, 56(s3)
    addi    s1, s1, 64
    addi    s3, s3, 64
    addi    s4, s4, -8
#elif OPENRV64_STREAM_KERNEL == 1
.Lstream_loop:
    ld      t0, 0(s1)
    ld      t1, 8(s1)
    ld      t2, 16(s1)
    ld      t3, 24(s1)
    slli    t4, t0, 1
    add     t0, t0, t4
    slli    t4, t1, 1
    add     t1, t1, t4
    slli    t4, t2, 1
    add     t2, t2, t4
    slli    t4, t3, 1
    add     t3, t3, t4
    sd      t0, 0(s3)
    sd      t1, 8(s3)
    sd      t2, 16(s3)
    sd      t3, 24(s3)
    addi    s1, s1, 32
    addi    s3, s3, 32
    addi    s4, s4, -4
#elif OPENRV64_STREAM_KERNEL == 2
.Lstream_loop:
    ld      t0, 0(s1)
    ld      t1, 8(s1)
    ld      t2, 16(s1)
    ld      t3, 24(s1)
    ld      t4, 0(s2)
    ld      t5, 8(s2)
    ld      t6, 16(s2)
    ld      a0, 24(s2)
    add     t0, t0, t4
    add     t1, t1, t5
    add     t2, t2, t6
    add     t3, t3, a0
    sd      t0, 0(s3)
    sd      t1, 8(s3)
    sd      t2, 16(s3)
    sd      t3, 24(s3)
    addi    s1, s1, 32
    addi    s2, s2, 32
    addi    s3, s3, 32
    addi    s4, s4, -4
#else
.Lstream_loop:
    ld      t0, 0(s1)
    ld      t1, 8(s1)
    ld      t2, 16(s1)
    ld      t3, 24(s1)
    ld      t4, 0(s2)
    ld      t5, 8(s2)
    ld      t6, 16(s2)
    ld      a0, 24(s2)
    slli    a1, t4, 1
    add     t0, t0, a1
    add     t0, t0, t4
    slli    a1, t5, 1
    add     t1, t1, a1
    add     t1, t1, t5
    slli    a1, t6, 1
    add     t2, t2, a1
    add     t2, t2, t6
    slli    a1, a0, 1
    add     t3, t3, a1
    add     t3, t3, a0
    sd      t0, 0(s3)
    sd      t1, 8(s3)
    sd      t2, 16(s3)
    sd      t3, 24(s3)
    addi    s1, s1, 32
    addi    s2, s2, 32
    addi    s3, s3, 32
    addi    s4, s4, -4
#endif
    bnez    s4, .Lstream_loop

    /* Include visibility of every destination store in the measurement. */
    fence   rw, rw
    .globl stream_4h_perf_measure_end
stream_4h_perf_measure_end:
    rdinstret s9
    rdcycle s8
    sub     s10, s8, s6
    sub     s11, s9, s7

    /* Full per-hart result verification is outside the timed interval. */
    li      t0, STREAM_BYTES
    mul     t0, t0, tp
    la      s1, stream_4h_a
    add     s1, s1, t0
    la      s2, stream_4h_b
    add     s2, s2, t0
    la      s3, stream_4h_c
    add     s3, s3, t0
    li      s4, STREAM_WORDS

.Lverify:
    ld      t0, 0(s1)
#if OPENRV64_STREAM_KERNEL == 1
    slli    t1, t0, 1
    add     t0, t0, t1
#elif OPENRV64_STREAM_KERNEL == 2
    ld      t1, 0(s2)
    add     t0, t0, t1
    addi    s2, s2, 8
#elif OPENRV64_STREAM_KERNEL == 3
    ld      t1, 0(s2)
    slli    t2, t1, 1
    add     t0, t0, t2
    add     t0, t0, t1
    addi    s2, s2, 8
#endif
    ld      t1, 0(s3)
    bne     t0, t1, .Lfailure
    addi    s1, s1, 8
    addi    s3, s3, 8
    addi    s4, s4, -1
    bnez    s4, .Lverify
    li      t0, 0
    j       .Lpublish

.Lfailure:
    li      t0, FAILURE_STATUS

.Lpublish:
    sw      t0, RESULT_STATUS(s0)
    li      t0, STREAM_PASS
    sd      t0, RESULT_SIGNATURE(s0)
    sd      s6, RESULT_START_CYCLE(s0)
    sd      s8, RESULT_END_CYCLE(s0)
    sd      s10, RESULT_CYCLES(s0)
    sd      s7, RESULT_START_INSTRET(s0)
    sd      s9, RESULT_END_INSTRET(s0)
    sd      s11, RESULT_INSTRET(s0)
    fence   rw, rw
    addi    t0, tp, 1
    sw      t0, RESULT_DONE(s0)
    fence   rw, rw

    .globl stream_4h_perf_done
stream_4h_perf_done:
    addi    x0, x0, 0
.Lhalt:
    j       .Lhalt

    .size supervisor_start, .-supervisor_start

    .section .data, "aw", @progbits
    .balign 64
    .globl stream_4h_perf_control
stream_4h_perf_control:
    .zero CONTROL_BYTES

    .section .rodata.stream_a, "a", @progbits
    .balign 4096
    .globl stream_4h_a
stream_4h_a:
    .set stream_index, 0
    .rept HART_COUNT * STREAM_WORDS
        .quad 0x100000000 + stream_index
        .set stream_index, stream_index + 1
    .endr

    .section .rodata.stream_b, "a", @progbits
    .balign 4096
    .globl stream_4h_b
stream_4h_b:
    .set stream_index, 0
    .rept HART_COUNT * STREAM_WORDS
        .quad 0x200000000 + stream_index
        .set stream_index, stream_index + 1
    .endr

    .section .bss.stream_c, "aw", @nobits
    .balign 4096
    .globl stream_4h_c
stream_4h_c:
    .skip HART_COUNT * STREAM_BYTES

    .section .hart_private, "aw", @progbits
    .balign 4096
    .globl stream_4h_perf_results
stream_4h_perf_results:
    .zero 16384
    .globl stream_4h_perf_status
    .set stream_4h_perf_status, stream_4h_perf_results + RESULT_STATUS

