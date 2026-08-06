/*
 * Scalar memcpy size/alignment sweep for the native 3P L1D/ICX path.
 *
 * Each table entry is assigned a disjoint source/destination slot and is run
 * three times.  Repetition zero therefore starts without a prior access to
 * that slot, while repetitions one and two characterize the warm path.
 *
 * The default memcpy_scalar proxy assumes misaligned scalar accesses fault
 * and consequently uses:
 *
 *   - a byte prologue when source and destination have the same alignment,
 *   - aligned, eight-doubleword bulk iterations,
 *   - aligned doubleword and byte tails, and
 *   - the Linux kernel's byte-at-a-time fallback when source and destination
 *     alignments differ.
 *
 * MEMCPY_SWEEP_LINUX instead embeds memcpy-linux.S.  Its Zicclsm benchmark
 * build selects CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS, so differing
 * alignments exercise native misaligned loads and stores.
 *
 * The testbench watches memcpy_span_report and reports the architectural
 * a0-a7 values:
 *
 *   a0 case index, a1 repetition, a2 byte count, a3 source offset,
 *   a4 destination offset, a5 mcycle delta, a6 path (0=different alignment,
 *   1=same alignment), a7 minstret delta.
 *
 * Source generation and correctness checking are outside every timed span.
 * Each measured span includes the scalar function call and the final ordering
 * fence.  A zero-byte case provides a call/fence timing floor.
 */

.equ MEMCPY_SWEEP_PASS,       0x4d454d4350594f4b /* "MEMCPYOK" */
.equ MEMCPY_SWEEP_FAIL,       0x4d454d4350594244 /* "MEMCPYBD" */
.equ MEMCPY_SWEEP_REPEATS,    3
.equ MEMCPY_SWEEP_CASE_COUNT, 54
.equ MEMCPY_SWEEP_BUFFER_BYTES, 262144
.equ MEMCPY_SWEEP_SLOT_PAD,   1023

.macro MEMCPY_CASE bytes, src_offset, dst_offset
    .word \bytes
    .byte \src_offset
    .byte \dst_offset
    .hword 0
.endm

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    la      s0, memcpy_sweep_cases
    li      s1, 0                  /* case index */
    li      s2, 0                  /* packed buffer offset */

.Lcase:
    la      t0, memcpy_sweep_cases_end
    beq     s0, t0, .Lpass

    lwu     s4, 0(s0)              /* byte count */
    lbu     s5, 4(s0)              /* source alignment offset */
    lbu     s6, 5(s0)              /* destination alignment offset */
    addi    s0, s0, 8

    la      t0, memcpy_sweep_source
    add     t0, t0, s2
    add     s8, t0, s5
    la      t0, memcpy_sweep_destination
    add     t0, t0, s2
    add     s9, t0, s6

    xor     t0, s5, s6
    andi    t0, t0, 7
    seqz    s7, t0                 /* 1=source/destination alignments match */
    li      s3, 0                  /* repetition */

.Lrepeat:
    /*
     * Drain the preceding report/verification traffic before starting the
     * clock.  The final fence is inside the measurement to preserve memcpy's
     * software-visible completion boundary.
     */
    fence   rw, rw
    csrr    s10, mcycle
    csrr    gp, minstret
    mv      a0, s9
    mv      a1, s8
    mv      a2, s4
#ifdef MEMCPY_SWEEP_LINUX
    jal     ra, __memcpy
#else
    jal     ra, memcpy_scalar
#endif
    fence   rw, rw
    csrr    t0, mcycle
    csrr    t1, minstret
    sub     s11, t0, s10
    sub     tp, t1, gp

    mv      a0, s1
    mv      a1, s3
    mv      a2, s4
    mv      a3, s5
    mv      a4, s6
    mv      a5, s11
    mv      a6, s7
    mv      a7, tp

    /*
     * Keep the marker out of the same three-wide retirement group as the
     * report-register writes.  The testbench samples architectural GPRs when
     * the marker retires.
     */
    nop
    nop
    nop
    nop

.globl memcpy_span_report
memcpy_span_report:
    nop

    addi    s3, s3, 1
    li      t0, MEMCPY_SWEEP_REPEATS
    bltu    s3, t0, .Lrepeat

    /* Verify the final repetition outside all measured spans. */
    mv      t0, s8
    mv      t1, s9
    mv      t2, s4
.Lverify:
    beqz    t2, .Lcase_done
    lbu     t3, 0(t0)
    lbu     t4, 0(t1)
    bne     t3, t4, .Lfail
    addi    t0, t0, 1
    addi    t1, t1, 1
    addi    t2, t2, -1
    j       .Lverify

.Lcase_done:
    /*
     * Pack cases into distinct 64-byte-aligned slots.  The pad covers the
     * largest alignment offset and leaves roughly 16 cache lines between
     * adjacent logical spans.  That exceeds the default maximum prefetch
     * distance of four lines.
     */
    addi    t0, s4, MEMCPY_SWEEP_SLOT_PAD
    andi    t0, t0, -64
    add     s2, s2, t0
    li      t1, MEMCPY_SWEEP_BUFFER_BYTES
    bgeu    s2, t1, .Lfail
    addi    s1, s1, 1
    j       .Lcase

.Lpass:
    li      t0, MEMCPY_SWEEP_CASE_COUNT
    bne     s1, t0, .Lfail
    li      a0, MEMCPY_SWEEP_PASS
    ebreak

.Lfail:
    li      a0, MEMCPY_SWEEP_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start

#ifdef MEMCPY_SWEEP_LINUX
.section .text.memcpy_linux, "ax", @progbits
.balign 64
#include "memcpy-linux.S"
#else
/*
 * void *memcpy_scalar(void *dst, const void *src, size_t bytes)
 *
 * This routine deliberately remains RV64I-only.  It never issues a naturally
 * misaligned access wider than one byte.
 */
.section .text.memcpy_scalar, "ax", @progbits
.balign 64
.globl memcpy_scalar
.type memcpy_scalar, @function
memcpy_scalar:
    beqz    a2, .Lcopy_done

    xor     t0, a0, a1
    andi    t0, t0, 7
    bnez    t0, .Lcopy_bytes

.Lcopy_align:
    andi    t0, a0, 7
    beqz    t0, .Lcopy_lines
    lbu     t1, 0(a1)
    sb      t1, 0(a0)
    addi    a0, a0, 1
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, .Lcopy_align
    ret

.Lcopy_lines:
    li      t0, 64
    bltu    a2, t0, .Lcopy_words

    ld      t0, 0(a1)
    ld      t1, 8(a1)
    ld      t2, 16(a1)
    ld      t3, 24(a1)
    ld      t4, 32(a1)
    ld      t5, 40(a1)
    ld      t6, 48(a1)
    ld      a3, 56(a1)

    sd      t0, 0(a0)
    sd      t1, 8(a0)
    sd      t2, 16(a0)
    sd      t3, 24(a0)
    sd      t4, 32(a0)
    sd      t5, 40(a0)
    sd      t6, 48(a0)
    sd      a3, 56(a0)

    addi    a0, a0, 64
    addi    a1, a1, 64
    addi    a2, a2, -64
    j       .Lcopy_lines

.Lcopy_words:
    li      t0, 8
    bltu    a2, t0, .Lcopy_bytes
    ld      t1, 0(a1)
    sd      t1, 0(a0)
    addi    a0, a0, 8
    addi    a1, a1, 8
    addi    a2, a2, -8
    j       .Lcopy_words

.Lcopy_bytes:
    /*
     * Match the slow-access path in arch/riscv/lib/memcpy.S: one byte load,
     * one byte store, and one loop branch for every copied byte.  This is
     * intentionally not unrolled so the sweep characterizes the kernel
     * implementation rather than a locally optimized substitute.
     */
    beqz    a2, .Lcopy_done
    add     a3, a1, a2
.Lcopy_byte_loop:
    lb      t0, 0(a1)
    addi    a1, a1, 1
    sb      t0, 0(a0)
    addi    a0, a0, 1
    bltu    a1, a3, .Lcopy_byte_loop

.Lcopy_done:
    ret

.size memcpy_scalar, .-memcpy_scalar
#endif

.section .rodata.memcpy_sweep_cases, "a", @progbits
.balign 64
.globl memcpy_sweep_cases
memcpy_sweep_cases:
    /* Aligned boundary sweep, including a zero-byte timing floor. */
    MEMCPY_CASE 0,     0, 0
    MEMCPY_CASE 1,     0, 0
    MEMCPY_CASE 2,     0, 0
    MEMCPY_CASE 3,     0, 0
    MEMCPY_CASE 4,     0, 0
    MEMCPY_CASE 7,     0, 0
    MEMCPY_CASE 8,     0, 0
    MEMCPY_CASE 15,    0, 0
    MEMCPY_CASE 16,    0, 0
    MEMCPY_CASE 31,    0, 0
    MEMCPY_CASE 32,    0, 0
    MEMCPY_CASE 63,    0, 0
    MEMCPY_CASE 64,    0, 0
    MEMCPY_CASE 65,    0, 0
    MEMCPY_CASE 127,   0, 0
    MEMCPY_CASE 128,   0, 0
    MEMCPY_CASE 255,   0, 0
    MEMCPY_CASE 256,   0, 0
    MEMCPY_CASE 511,   0, 0
    MEMCPY_CASE 512,   0, 0
    MEMCPY_CASE 1024,  0, 0
    MEMCPY_CASE 4096,  0, 0
    MEMCPY_CASE 65536, 0, 0

    /* Same unaligned offset: byte prologue, then aligned bulk copy. */
    MEMCPY_CASE 1,     1, 1
    MEMCPY_CASE 7,     1, 1
    MEMCPY_CASE 8,     1, 1
    MEMCPY_CASE 15,    1, 1
    MEMCPY_CASE 16,    1, 1
    MEMCPY_CASE 63,    1, 1
    MEMCPY_CASE 64,    1, 1
    MEMCPY_CASE 65,    1, 1
    MEMCPY_CASE 70,    1, 1
    MEMCPY_CASE 71,    1, 1
    MEMCPY_CASE 72,    1, 1
    MEMCPY_CASE 255,   1, 1
    MEMCPY_CASE 256,   1, 1
    MEMCPY_CASE 4096,  1, 1
    MEMCPY_CASE 65536, 1, 1

    /* Different alignments: portable byte fallback in each direction. */
    MEMCPY_CASE 8,     1, 0
    MEMCPY_CASE 64,    1, 0
    MEMCPY_CASE 256,   1, 0
    MEMCPY_CASE 4096,  1, 0
    MEMCPY_CASE 8,     0, 1
    MEMCPY_CASE 64,    0, 1
    MEMCPY_CASE 256,   0, 1
    MEMCPY_CASE 4096,  0, 1

    /* Nontrivial offset pairs and the other end of the 8-byte alignment. */
    MEMCPY_CASE 64,    3, 5
    MEMCPY_CASE 256,   3, 5
    MEMCPY_CASE 4096,  3, 5
    MEMCPY_CASE 63,    7, 7
    MEMCPY_CASE 64,    7, 7
    MEMCPY_CASE 65,    7, 7
    MEMCPY_CASE 256,   7, 7
    MEMCPY_CASE 4096,  7, 7

.globl memcpy_sweep_cases_end
memcpy_sweep_cases_end:

.if (((memcpy_sweep_cases_end - memcpy_sweep_cases) / 8) != MEMCPY_SWEEP_CASE_COUNT)
.error "MEMCPY_SWEEP_CASE_COUNT does not match the case table"
.endif

.section .rodata.memcpy_sweep_source, "a", @progbits
.balign 64
.globl memcpy_sweep_source
.type memcpy_sweep_source, @object
memcpy_sweep_source:
    .set source_line, 0
    .rept (MEMCPY_SWEEP_BUFFER_BYTES / 64)
        .quad 0x0123456789abcdef + source_line
        .quad 0xfedcba9876543210 + source_line
        .quad 0x0f1e2d3c4b5a6978 + source_line
        .quad 0x8877665544332211 + source_line
        .quad 0x55aa55aa55aa55aa + source_line
        .quad 0xaa55aa55aa55aa55 + source_line
        .quad 0x13579bdf2468ace0 + source_line
        .quad 0xc001d00d5eedface + source_line
        .set source_line, source_line + 1
    .endr
.size memcpy_sweep_source, .-memcpy_sweep_source

.section .bss.memcpy_sweep_destination, "aw", @nobits
.balign 64
.globl memcpy_sweep_destination
.type memcpy_sweep_destination, @object
memcpy_sweep_destination:
    .skip MEMCPY_SWEEP_BUFFER_BYTES
.size memcpy_sweep_destination, .-memcpy_sweep_destination
