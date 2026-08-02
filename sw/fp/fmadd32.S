/*
 * Same-register RV64D FMADD pipeline microbenchmark.
 *
 * The measured loop contains exactly thirty-two consecutive copies of:
 *
 *     fmadd.d f0, f1, f2, f3, rne
 *
 * and repeats that body FMADD32_LOOPS times.  Because f0 is not a source,
 * these operations have a WAW relationship but no arithmetic RAW dependency.
 * The sequence therefore isolates FPU acceptance, result buffering, and
 * same-destination retirement from FP load/store traffic.
 *
 * At the final EBREAK:
 *   a0 = FMADD32_PASS on success
 *   a1 = address of {cycle_delta, instret_delta}
 *   a2 = loop count
 *   a3 = total FMADD instruction count
 */

.equ MSTATUS_FS_INITIAL, 0x2000
.equ FMADD32_LOOPS,       32
.equ FMADD32_OPS,         (32 * FMADD32_LOOPS)
.equ FMADD32_PASS,        0x464d33325f4f4b21 /* "FM32_OK!" */
.equ FMADD32_FAIL_DATA,   0x464d33325f424144 /* "FM32_BAD" */
.equ FMADD32_FAIL_FLAGS,  0x464d33325f464c47 /* "FM32_FLG" */

.section .text.startup, "ax", @progbits
.align 3
.globl _start
.type _start, @function
_start:
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    csrw    fflags, zero

    la      t0, fmadd32_operands
    fld     f1, 0(t0)                  /* 2.0 */
    fld     f2, 8(t0)                  /* 3.0 */
    fld     f3, 16(t0)                 /* 4.0 */

    li      s4, 1                     /* testbench performance phase */
    li      t0, FMADD32_LOOPS
    rdcycle s0
    rdinstret s1

.Lfmadd32_loop:
    .rept 32
    fmadd.d f0, f1, f2, f3, rne
    .endr
    addi    t0, t0, -1
    bnez    t0, .Lfmadd32_loop

    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, fmadd32_perf
    sd      s2, 0(t0)
    sd      s3, 8(t0)

    frflags t0
    bnez    t0, .Lfmadd32_fail_flags

    la      t0, fmadd32_result
    fsd     f0, 0(t0)
    ld      t1, 0(t0)
    li      t2, 0x4024000000000000    /* 10.0 */
    bne     t1, t2, .Lfmadd32_fail_data

    la      a1, fmadd32_perf
    li      a2, FMADD32_LOOPS
    li      a3, FMADD32_OPS
    li      a0, FMADD32_PASS
.globl fmadd32_done
fmadd32_done:
    ebreak
    j       .

.Lfmadd32_fail_data:
    mv      a1, t1
    mv      a2, t2
    li      a0, FMADD32_FAIL_DATA
    ebreak
    j       .

.Lfmadd32_fail_flags:
    mv      a1, t0
    li      a0, FMADD32_FAIL_FLAGS
    ebreak
    j       .
.size _start, .-_start

.section .rodata, "a", @progbits
.align 3
fmadd32_operands:
    .dword 0x4000000000000000         /* 2.0 */
    .dword 0x4008000000000000         /* 3.0 */
    .dword 0x4010000000000000         /* 4.0 */

.section .bss, "aw", @nobits
.align 3
fmadd32_perf:
    .zero 16
fmadd32_result:
    .zero 8
